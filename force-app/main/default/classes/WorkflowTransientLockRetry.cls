/**
 * @description Transient row-lock (UNABLE_TO_LOCK_ROW) retry policy for the Revenant
 * engine. Classifies transient row-lock contention errors and re-drives the affected
 * step after a bounded, jittered exponential backoff instead of failing the workflow.
 * Extracted from `WorkflowCrashHandler` to keep each class within the per-class
 * complexity budget; `WorkflowCrashHandler.processCrash` calls into this class. All
 * SOQL/DML executes in system mode.
 */
public inherited sharing class WorkflowTransientLockRetry {
  // Transient row-lock contention (UNABLE_TO_LOCK_ROW) is retried a bounded number
  // of times before the crash handler gives up and fails the workflow — e.g. a fan-in
  // where many child-completion signals lock the shared parent row at
  // once. These are CONSECUTIVE retries (reset on the next successful drive), so the
  // cap need only outlast a contention burst, not the whole fan-in.
  @TestVisible
  private static Integer maxTransientLockRetries = 12;
  private static final Integer TRANSIENT_LOCK_BASE_DELAY_SECONDS = 5;
  private static final Integer TRANSIENT_LOCK_MAX_DELAY_SECONDS = 60;
  private static final Integer TRANSIENT_LOCK_JITTER_SECONDS = 5;

  /**
   * True when the exception is a transient row-lock contention error
   * (UNABLE_TO_LOCK_ROW / "record currently unavailable") rather than a genuine
   * crash. These resolve on their own once the competing transaction commits, so
   * the crash handler re-drives the step instead of failing the workflow.
   * @param ex the exception to classify
   * @return true when the exception is a transient row-lock contention error
   */
  public static Boolean isTransientLockError(Exception ex) {
    if (ex == null) {
      return false;
    }
    if (ex instanceof DmlException) {
      try {
        DmlException de = (DmlException) ex;
        for (Integer i = 0; i < de.getNumDml(); i++) {
          if (de.getDmlType(i) == StatusCode.UNABLE_TO_LOCK_ROW) {
            return true;
          }
        }
      } catch (Exception ignored) {
        // Safeguard against programmatically constructed DmlExceptions in tests
      }
    }
    String msg = ex.getMessage();
    if (String.isBlank(msg)) {
      return false;
    }
    String lower = msg.toLowerCase();
    return lower.contains('unable_to_lock_row') ||
      lower.contains('unable to lock row') ||
      lower.contains('unable to obtain exclusive access') ||
      lower.contains('record currently unavailable') ||
      lower.contains('currently being modified by another');
  }

  /**
   * Determines whether an instance is already terminal for transient-retry gating.
   * @param instance the instance whose status is checked
   * @return true when the instance is in a terminal state that must not be
   *   resurrected by a transient-lock retry (excludes CompensationFailed, which is
   *   recoverable via operator resume)
   */
  private static Boolean isInstanceTerminalForRetry(
    Workflow_Instance__c instance
  ) {
    return instance.Status__c == 'Completed' ||
      instance.Status__c == 'Failed' ||
      instance.Status__c == 'Compensated' ||
      instance.Status__c == 'Cancelled' ||
      instance.Status__c == 'ContinuedAsNew';
  }

  /**
   * Re-drives a step after a transient row-lock error, bounded by the step's
   * CONSECUTIVE Transient_Retry_Count__c (reset to 0 on the next successful drive in
   * handleStepResult). Returns true when a retry was scheduled — the caller then
   * skips the fail path; returns false when the budget is spent or there is no step
   * row to retry against, so the caller fails the workflow as usual. Mirrors the
   * RETRY action's suspend + scheduleRetry handoff so the watchdog/sleep plumbing
   * re-drives even when dynamic scheduling is off.
   * @param instance the instance whose step is re-driven
   * @param stepName name of the step to retry against
   * @return true when a retry was scheduled; false when the budget is spent or
   * there is no step row to retry
   */
  public static Boolean scheduleTransientLockRetry(
    Workflow_Instance__c instance,
    String stepName
  ) {
    // Never resurrect an already-terminal instance: a stray late crash must fall
    // through to the (idempotent) fail path, not flip a finished run back to Suspended.
    if (isInstanceTerminalForRetry(instance)) {
      return false;
    }

    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Status__c, Transient_Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instance.Id AND Step_Name__c = :stepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (stepExecs.isEmpty()) {
      return false;
    }
    Workflow_Step_Execution__c stepExec = stepExecs[0];
    Integer attempts = (stepExec.Transient_Retry_Count__c == null)
      ? 0
      : (Integer) stepExec.Transient_Retry_Count__c;
    if (attempts >= maxTransientLockRetries) {
      return false; // budget spent -> caller fails the workflow
    }

    // The crash rolled back any in-flight status change, so keep the step
    // re-runnable and record the consecutive transient attempt without touching the
    // business Retry_Count__c budget.
    stepExec.Transient_Retry_Count__c = attempts + 1;
    if (stepExec.Status__c == 'Failed') {
      stepExec.Status__c = 'Pending';
    }
    // Clear the step's watchdog deadline for the duration of the backoff. The crash
    // left the row Running/Pending carrying its pre-crash Timeout_At__c; once the
    // sleep flips the parent back to Running, a now-stale (already-past) deadline
    // would let the watchdog timeout batch fail the step before the retry worker
    // re-drives it. runStep re-stamps a fresh deadline before execute() on the
    // re-drive, mirroring how the RETRY action parks its step out of the timeout batch.
    stepExec.Timeout_At__c = null;
    Database.update(stepExec, true, AccessLevel.SYSTEM_MODE);

    // Exponential backoff (capped) with jitter so the contention wave drains before
    // the re-drive and a fan-in of re-drives does not re-synchronize into a new storm.
    Double exponent = Math.min(attempts, 4); // widen Integer -> Double for Math.pow
    Integer delay =
      TRANSIENT_LOCK_BASE_DELAY_SECONDS * (Integer) Math.pow(2, exponent);
    delay = Math.min(delay, TRANSIENT_LOCK_MAX_DELAY_SECONDS);
    delay += (Integer) Math.floor(
      Math.random() * TRANSIENT_LOCK_JITTER_SECONDS
    );

    String jobId = WorkflowRetrySleepScheduler.scheduleRetry(
      instance.Id,
      stepName,
      delay
    );
    instance.Status__c = 'Suspended';
    instance.Sleep_Until__c = DateTime.now().addSeconds(delay);
    instance.Async_Job_Id__c = jobId;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    if (jobId == null) {
      // No delayed job was created (dynamic scheduling off, or async limit), so this
      // retry relies entirely on the watchdog heartbeat to re-drive after the backoff.
      // Ensure the watchdog singleton is alive — the removed immediate re-drive used to
      // restart a dead watchdog via enqueueOrchestrator's bootstrap() call.
      WorkflowWatchdog.bootstrap();
    }

    // No immediate re-drive when jobId is null. The branch target is durably persisted
    // as its Pending step row carrying Transient_Retry_Count__c > 0 (set above), and
    // the watchdog sleep-resume re-drives exactly those branches BY NAME once
    // Sleep_Until__c is due (see processWatchdogHeartbeat). Enqueuing the branch
    // immediately here would bypass the backoff just written and, under a sustained
    // UNABLE_TO_LOCK_ROW fan-in, burn through maxTransientLockRetries before the
    // contending transactions clear — failing the very workflow the backoff exists to
    // wait out. A single-step instance is still resolved by the watchdog's blank-name
    // resume; only the parallel branch needed a name-carrying path, now the watchdog's.
    return true;
  }
}
