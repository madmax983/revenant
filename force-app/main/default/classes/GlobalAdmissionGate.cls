/**
 * @description Global slot counter of the admission brake (issue #136). The
 * count lives on one reserved `Concurrency_State__c` row, `$global`. A `$` is
 * not legal in an Apex class name, so no definition counter can use this key.
 * The row is changed only under `FOR UPDATE`, as the #91 counters are.
 *
 * - Acquire: at the first hop of a new start, under the instance lock.
 * - Release: on the first terminal transition. Continue-As-New moves the slot
 *   to the successor, so it does not release.
 * - Reconcile: the watchdog heartbeat resets the count to the true number of
 *   non-terminal holders. It also records emergency stop changes.
 *
 * A lock that fails admits with no slot (fail open). The brake writes no step
 * row and does not touch the compensation stack.
 */
public inherited sharing class GlobalAdmissionGate {
  /** @description The reserved counter key. */
  public static final String COUNTER_KEY = '$global';
  /** @description Workflow_Name__c of the emergency stop audit rows. */
  public static final String AUDIT_NAME = 'GlobalAdmissionBrake';

  // Test hook. When true, the counter lock throws.
  @TestVisible
  private static Boolean failLock = false;

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
    /** @description True when the start took a global slot. */
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
      // Fail open: admit with no slot. The brake must not drop the chain.
      r.slotConsumed = false;
    }
    return r;
  }

  /**
   * @description Parks a new start at the gate. It uses the #91 park fields
   * and no timer job: the watchdog sleep sweep re-drives it after the brake
   * opens. It writes no step row.
   * @param instance The instance. The fields are also set in memory.
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
   * @description Gives back global slots (floored at 0).
   * @param count The number of slots.
   */
  public static void release(Integer count) {
    if (count == null || count <= 0) {
      return;
    }
    ConcurrencyGate.release(COUNTER_KEY, count);
  }

  /**
   * @description Heartbeat step. Resets the count to the non-terminal holders
   * and records an emergency stop change. With no row and no emergency stop,
   * it does nothing more than 1 SOQL.
   */
  public static void reconcile() {
    Boolean stop = GlobalAdmissionBrake.emergencyStopConfigured();
    List<Concurrency_State__c> rows = [
      SELECT Id, In_Flight_Count__c, Emergency_Stop_Seen__c
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c = :COUNTER_KEY
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (rows.isEmpty() && !stop) {
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
    if (row.Emergency_Stop_Seen__c != stop) {
      row.Emergency_Stop_Seen__c = stop;
      changed = true;
      writeStopAudit(stop);
    }
    if (changed) {
      update as system row;
    }
  }

  // One OperatorIntervention row for each emergency stop change.
  private static void writeStopAudit(Boolean engaged) {
    String msg = engaged
      ? 'Emergency stop engaged. New starts park. In-flight instances continue.'
      : 'Emergency stop released. Parked starts are admitted again.';
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
