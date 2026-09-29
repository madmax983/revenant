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
 * - Operator retry of a failed instance: marked Held, does not park. The
 *   reconcile counts it.
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

  // In the heartbeat, releases wait for the reconcile near the end, so the
  // heartbeat does not hold `$global` while it locks instance rows.
  private static Boolean deferRelease = false;
  private static Integer deferredCount = 0;
  // Budget that reconcile needs: 4 SOQL (row lock, provision re-read, race
  // re-read, count) and 5 DML (provision insert, savepoint, row update, audit
  // insert, rollback).
  private static final Integer RECONCILE_SOQL = 4;
  private static final Integer RECONCILE_DML = 5;
  // Query rows that the reconcile and a deferred release leave for the rest of
  // the transaction (the watchdog step commit).
  private static final Integer QUERY_ROW_RESERVE = 5000;
  // Budget that a deferred release needs: 1 SOQL and 1 DML, plus 1 DML left
  // for the watchdog step commit.
  private static final Integer RELEASE_SOQL = 1;
  private static final Integer RELEASE_DML = 2;

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
   * @description Marks an operator retry of a failed top-level instance as
   * Held. It never parks: the count can go above the ceiling until work
   * completes. The next reconcile adds it to the count. No-op with no
   * ceiling, for a child and for an engine workflow.
   * @param instance The instance, with Parent_Instance__c, Workflow_Name__c
   * and Global_Admission__c. The method sets Global_Admission__c in memory.
   */
  public static void countRetry(Workflow_Instance__c instance) {
    if (
      GlobalAdmissionBrake.configuredCeiling() == null ||
      instance.Parent_Instance__c != null ||
      instance.Global_Admission__c == GlobalAdmissionPolicy.STATE_HELD ||
      WorkflowPauseGate.isEngineWorkflow(instance.Workflow_Name__c)
    ) {
      return;
    }
    // No counter lock here: a bulk redrive retries many rows in one
    // transaction, and a lock would break the lock order. The next reconcile
    // counts the slot.
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
   * the heartbeat, the engine keeps the count and the reconcile applies it.
   * @param count The number of slots.
   */
  public static void release(Integer count) {
    if (count == null || count <= 0) {
      return;
    }
    if (deferRelease) {
      deferredCount += count;
      return;
    }
    ConcurrencyGate.release(COUNTER_KEY, count);
  }

  /**
   * @description Starts the heartbeat mode: `release` does not lock
   * `$global`. Call `reconcile`, then `endDeferral` in a finally block.
   */
  public static void deferReleasesToReconcile() {
    deferRelease = true;
    deferredCount = 0;
  }

  /**
   * @description Stops the heartbeat mode. If the reconcile did not apply the
   * deferred releases, this applies them. Best effort: it does not throw.
   */
  public static void endDeferral() {
    Integer pending = deferredCount;
    deferRelease = false;
    deferredCount = 0;
    if (pending <= 0 || !hasBudget(RELEASE_SOQL, RELEASE_DML)) {
      // With no budget, the next reconcile corrects the count.
      return;
    }
    try {
      ConcurrencyGate.release(COUNTER_KEY, pending);
    } catch (Exception ex) {
      // The next reconcile corrects the count.
      return;
    }
  }

  /**
   * @description Heartbeat step. Sets the count to the non-terminal holders,
   * so it also applies the releases of this heartbeat. Records an emergency
   * stop change. With no row, no emergency stop and no ceiling, it uses 1 SOQL
   * and stops. It stops with no change when the transaction has too little
   * SOQL, DML or query-row budget left.
   */
  public static void reconcile() {
    if (!hasBudget(RECONCILE_SOQL, RECONCILE_DML)) {
      return;
    }
    Boolean stop = GlobalAdmissionBrake.emergencyStopConfigured();
    List<Concurrency_State__c> rows = [
      SELECT Id, In_Flight_Count__c, Emergency_Stop_Seen__c
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c = :COUNTER_KEY
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    // A fail-open admit or a retry can mark a start Held with no row. With a
    // ceiling, the reconcile makes the row and counts it.
    if (
      rows.isEmpty() &&
      !stop &&
      GlobalAdmissionBrake.configuredCeiling() == null
    ) {
      deferredCount = 0;
      return;
    }
    Concurrency_State__c row = rows.isEmpty()
      ? ConcurrencyGate.lockOrProvision(COUNTER_KEY)
      : rows[0];
    Integer rowsLeft =
      Limits.getLimitQueryRows() -
      Limits.getQueryRows() -
      QUERY_ROW_RESERVE;
    Integer truth = [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE
        Global_Admission__c = :GlobalAdmissionPolicy.STATE_HELD
        AND Status__c NOT IN :TERMINAL_STATUSES
      WITH SYSTEM_MODE
      LIMIT :rowsLeft
    ];
    Boolean countKnown = truth < rowsLeft;
    Boolean changed = false;
    if (
      countKnown &&
      (row.In_Flight_Count__c == null ||
      row.In_Flight_Count__c.intValue() != truth)
    ) {
      row.In_Flight_Count__c = truth;
      changed = true;
    }
    Boolean stopChanged = row.Emergency_Stop_Seen__c != stop;
    if (stopChanged) {
      row.Emergency_Stop_Seen__c = stop;
      changed = true;
    }
    saveReconcile(row, changed, stopChanged, stop);
    if (countKnown) {
      // The true count includes the releases of this heartbeat.
      deferredCount = 0;
    }
  }

  // True when the transaction has this SOQL and DML budget left, and the
  // query-row reserve.
  private static Boolean hasBudget(Integer soql, Integer dml) {
    return Limits.getQueries() + soql <= Limits.getLimitQueries() &&
      Limits.getDmlStatements() + dml <= Limits.getLimitDmlStatements() &&
      Limits.getQueryRows() + QUERY_ROW_RESERVE < Limits.getLimitQueryRows();
  }

  // The row update and the audit row go together. If one fails, both roll
  // back, so the next sweep sees the change again and writes the audit row.
  private static void saveReconcile(
    Concurrency_State__c row,
    Boolean changed,
    Boolean stopChanged,
    Boolean stop
  ) {
    if (!changed) {
      return;
    }
    Savepoint sp = Database.setSavepoint();
    try {
      update as system row;
      if (stopChanged) {
        writeStopAudit(stop);
      }
    } catch (Exception ex) {
      Database.rollback(sp);
      throw ex;
    } finally {
      Database.releaseSavepoint(sp);
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
