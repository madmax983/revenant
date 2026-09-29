/**
 * @description Global slot counter of the admission brake (issue #136). The
 * count lives on one reserved `Concurrency_State__c` row, `$global`. A `$` is
 * not legal in an Apex class name, so no definition counter can use this key.
 * The engine changes the row only under a `FOR UPDATE` lock, as for the #91
 * counters.
 *
 * - Acquire: at the first hop of a new start, under the instance lock.
 * - Release: on the first terminal transition. Continue-As-New moves the slot
 *   to the successor, so it does not release.
 * - Operator retry of a failed instance: takes a slot and does not park.
 * - Reconcile: the watchdog heartbeat sets the count to the number of
 *   non-terminal holders. It also records emergency stop changes.
 *
 * Lock order: the instance row, then the definition row, then `$global` last.
 * A lock that fails admits the start as Held; the next reconcile corrects the
 * count (fail open). The brake writes no step row and does not change the
 * compensation stack.
 */
public inherited sharing class GlobalAdmissionGate {
  /** @description The reserved counter key. */
  public static final String COUNTER_KEY = '$global';
  /** @description Workflow_Name__c of the emergency stop audit rows. */
  public static final String AUDIT_NAME = 'GlobalAdmissionBrake';

  // Test hook. When true, the counter lock throws.
  @TestVisible
  private static Boolean failLock = false;

  // In the heartbeat, releases wait for the reconcile at the end, so the
  // heartbeat does not hold `$global` while it locks instance rows.
  private static Boolean deferRelease = false;

  private static final Set<String> TERMINAL_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled',
    'ContinuedAsNew'
  };

  // A rollback never waits for admission.
  private static final Set<String> ROLLBACK_STATUSES = new Set<String>{
    'Compensating',
    'Cancelling'
  };

  private class GateLockException extends Exception {
  }

  /** @description Outcome of an acquire. */
  public class AcquireResult {
    /** @description True when the start may run. */
    public Boolean admitted = false;
    /**
     * @description True when the start holds a global slot. After a failed
     * lock it is also true: the next reconcile counts the slot.
     */
    public Boolean slotConsumed = false;
  }

  /**
   * @description Reads the global slot count. No lock. 1 SOQL.
   * @return The count. 0 when the row does not exist.
   */
  public static Integer readInFlight() {
    List<Concurrency_State__c> rows = [
      SELECT In_Flight_Count__c
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c = :COUNTER_KEY
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (rows.isEmpty() || rows[0].In_Flight_Count__c == null) {
      return 0;
    }
    return rows[0].In_Flight_Count__c.intValue();
  }

  /**
   * @description Takes one global slot when the count is below the ceiling.
   * @param ceiling The ceiling, or null for no ceiling.
   * @return Admitted with a slot, admitted with no slot (no ceiling, or the
   * lock failed), or not admitted (ceiling full).
   */
  public static AcquireResult tryAcquire(Integer ceiling) {
    AcquireResult r = new AcquireResult();
    r.admitted = true;
    if (ceiling == null) {
      return r;
    }
    try {
      if (failLock) {
        throw new GateLockException('Test: counter lock failed');
      }
      Concurrency_State__c state = ConcurrencyGate.lockOrProvision(COUNTER_KEY);
      Integer inFlight = state.In_Flight_Count__c == null
        ? 0
        : state.In_Flight_Count__c.intValue();
      if (inFlight >= ceiling) {
        r.admitted = false;
        return r;
      }
      state.In_Flight_Count__c = inFlight + 1;
      update as system state;
      r.slotConsumed = true;
    } catch (Exception ex) {
      // Fail open: admit. The brake must not drop the chain. Mark the start
      // Held, so the next reconcile counts it and the release stays correct.
      r.slotConsumed = true;
    }
    return r;
  }

  /**
   * @description Takes a global slot for an operator retry of a failed
   * top-level instance. It never parks: the count can go above the ceiling
   * until work completes. No-op with no ceiling, for a child and for an engine
   * workflow.
   * @param instance The instance, with Parent_Instance__c, Workflow_Name__c
   * and Global_Admission__c. The method sets Global_Admission__c in memory.
   */
  public static void countRetry(Workflow_Instance__c instance) {
    Integer ceiling = GlobalAdmissionBrake.configuredCeiling();
    if (
      ceiling == null ||
      instance.Parent_Instance__c != null ||
      instance.Global_Admission__c == GlobalAdmissionPolicy.STATE_HELD ||
      WorkflowPauseGate.isEngineWorkflow(instance.Workflow_Name__c)
    ) {
      return;
    }
    try {
      Concurrency_State__c state = ConcurrencyGate.lockOrProvision(COUNTER_KEY);
      state.In_Flight_Count__c =
        (state.In_Flight_Count__c == null
          ? 0
          : state.In_Flight_Count__c.intValue()) + 1;
      update as system state;
    } catch (Exception ex) {
      // Fail open: the next reconcile counts the slot.
      instance.Global_Admission__c = GlobalAdmissionPolicy.STATE_HELD;
      return;
    }
    instance.Global_Admission__c = GlobalAdmissionPolicy.STATE_HELD;
  }

  /**
   * @description Parks a new start at the gate. It uses the #91 park fields
   * and no timer job: the watchdog sleep sweep re-drives it after the brake
   * opens. It writes no step row.
   * @param instance The instance. The method also sets the fields in memory.
   */
  public static void parkStart(Workflow_Instance__c instance) {
    instance.Status__c = 'Suspended';
    instance.Concurrency_Parked__c = true;
    instance.Concurrency_Slot_Held__c = false;
    instance.Global_Admission__c = GlobalAdmissionPolicy.STATE_PARKED;
    instance.Sleep_Until__c = DateTime.now();
    instance.Async_Job_Id__c = null;
    Database.update(
      new Workflow_Instance__c(
        Id = instance.Id,
        Status__c = instance.Status__c,
        Concurrency_Parked__c = true,
        Concurrency_Slot_Held__c = false,
        Global_Admission__c = instance.Global_Admission__c,
        Sleep_Until__c = instance.Sleep_Until__c,
        Async_Job_Id__c = null
      ),
      true,
      AccessLevel.SYSTEM_MODE
    );
  }

  /**
   * @description Before-save step of the instance trigger. Clears the marker
   * on the first terminal transition, and on a rollback of a start that
   * waits. No DML.
   * @param row The saved row.
   * @param firstTerminal True on the first transition into a terminal status.
   * @return 1 when the row gives back a global slot, else 0.
   */
  public static Integer onSave(
    Workflow_Instance__c row,
    Boolean firstTerminal
  ) {
    String state = row.Global_Admission__c;
    if (state == null) {
      return 0;
    }
    if (firstTerminal) {
      row.Global_Admission__c = null;
      // Continue-As-New moves the slot to the successor.
      return state == GlobalAdmissionPolicy.STATE_HELD &&
        row.Status__c != 'ContinuedAsNew'
        ? 1
        : 0;
    }
    if (
      GlobalAdmissionPolicy.isAwaiting(state) &&
      ROLLBACK_STATUSES.contains(row.Status__c)
    ) {
      row.Global_Admission__c = null;
    }
    return 0;
  }

  /**
   * @description Gives back global slots. The count does not go below 0. In
   * the heartbeat, the reconcile at the end applies the release.
   * @param count The number of slots.
   */
  public static void release(Integer count) {
    if (count == null || count <= 0 || deferRelease) {
      return;
    }
    ConcurrencyGate.release(COUNTER_KEY, count);
  }

  /**
   * @description Starts the heartbeat mode: `release` does not lock
   * `$global`. Call `reconcile` at the end of the heartbeat.
   */
  public static void deferReleasesToReconcile() {
    deferRelease = true;
  }

  /**
   * @description Last heartbeat step. Sets the count to the non-terminal
   * holders, so it also applies the releases of this transaction. Records an
   * emergency stop change. With no row and no emergency stop, it uses 1 SOQL
   * and stops.
   */
  public static void reconcile() {
    deferRelease = false;
    Boolean stop = GlobalAdmissionBrake.emergencyStopConfigured();
    List<Concurrency_State__c> rows = [
      SELECT Id, In_Flight_Count__c, Emergency_Stop_Seen__c
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c = :COUNTER_KEY
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    // A fail-open admit can mark a start Held with no row. With a ceiling, the
    // reconcile makes the row and counts it.
    if (
      rows.isEmpty() &&
      !stop &&
      GlobalAdmissionBrake.configuredCeiling() == null
    ) {
      return;
    }
    Concurrency_State__c row = rows.isEmpty()
      ? ConcurrencyGate.lockOrProvision(COUNTER_KEY)
      : rows[0];
    Integer truth = [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE
        Global_Admission__c = :GlobalAdmissionPolicy.STATE_HELD
        AND Status__c NOT IN :TERMINAL_STATUSES
      WITH SYSTEM_MODE
    ];
    Boolean changed = false;
    if (
      row.In_Flight_Count__c == null ||
      row.In_Flight_Count__c.intValue() != truth
    ) {
      row.In_Flight_Count__c = truth;
      changed = true;
    }
    Boolean stopChanged = row.Emergency_Stop_Seen__c != stop;
    if (stopChanged) {
      row.Emergency_Stop_Seen__c = stop;
      changed = true;
    }
    if (changed) {
      update as system row;
    }
    // After the row update: if the update fails, no audit row is written, and
    // the next sweep writes it one time.
    if (stopChanged) {
      writeStopAudit(stop);
    }
  }

  // One OperatorIntervention row for each emergency stop change.
  private static void writeStopAudit(Boolean engaged) {
    String msg = engaged
      ? 'Emergency stop engaged. New starts park. In-flight instances continue.'
      : 'Emergency stop released. The next sweep sends parked starts to the gate.';
    msg +=
      ' The watchdog saw the change at ' +
      DateTime.now().formatGmt('yyyy-MM-dd HH:mm:ss') +
      ' GMT. Setup Audit Trail shows the user who changed Revenant Config.';
    Database.insert(
      new Workflow_Log__c(
        Workflow_Name__c = AUDIT_NAME,
        Log_Type__c = 'OperatorIntervention',
        Message__c = msg,
        Outcome__c = engaged ? 'Engaged' : 'Released',
        Level__c = engaged ? 'Warn' : 'INFO',
        Fire_Time__c = DateTime.now()
      ),
      true,
      AccessLevel.SYSTEM_MODE
    );
  }
}
