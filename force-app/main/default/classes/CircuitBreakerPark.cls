/**
 * CircuitBreakerPark — parks a guarded step whose circuit breaker is Open, fast-
 * failing it without executing (issue #128). Kept in its own class (rather than on
 * `WorkflowStepAdmission`, where the concurrency park lives) so the breaker park's
 * logic does not push the admission class over the class-level complexity threshold;
 * the admission hook in `WorkflowStepInvoke` calls it directly.
 *
 * Re-admission signaling — design choice: unlike a concurrency park, this does NOT
 * set a `Concurrency_Parked__c`-style flag and needs NO branch in
 * `WorkflowSleepResumeSweep`. A concurrency park must stay Suspended on wake (it has
 * not won a slot, and flipping it to Running would violate the no-Running-without-slot
 * invariant), so the sweep special-cases it. A breaker park has no such invariant: the
 * instance already passed admission (it holds any concurrency slot), so the ordinary
 * "Suspended + due Sleep_Until__c -> Running -> re-run current step" resume is exactly
 * right — the re-run re-hits the breaker gate in `WorkflowStepInvoke` (re-parking if
 * still Open, running as a probe once Half-Open). Reusing the vanilla sleep/watchdog
 * resume keeps the chain handoff intact and adds ZERO new scheduled-job slots.
 *
 * Observability — a breaker park writes a distinct Warn `Workflow_Log__c` line naming
 * the dependency key so an operator/dashboard can tell a fast-failed, self-healing
 * breaker park apart from a plain durable sleep (which would otherwise look like a
 * hang). A concurrency park is distinguished by its `Concurrency_Parked__c` flag; this
 * is the breaker's analogous, distinct marker. All DML and SOQL run in system mode.
 */
public inherited sharing class CircuitBreakerPark {
  // Fallback base wake (seconds) for a breaker park when the remaining open window
  // cannot be determined, plus a jitter band so a fleet parked on one open dependency
  // does not wake in lockstep and re-hit the gate as a thundering herd.
  @TestVisible
  private static Integer parkFallbackSeconds = 30;
  private static final Integer PARK_JITTER_SECONDS = 15;

  /**
   * @description Parks a guarded step whose breaker is Open: resets the current step
   * to Pending (clearing any stale deadline so the watchdog cannot fail a parked
   * step), suspends the instance until the breaker is due to admit probes, schedules
   * the plain sleep resume, and emits the distinct breaker-park signal.
   * @param instance the instance whose guarded step is being fast-failed
   * @param resolvedStep name of the current guarded step being parked
   * @param dependencyKey the open breaker's dependency key (for the wake time and log)
   */
  public static void parkForCircuitBreaker(
    Workflow_Instance__c instance,
    String resolvedStep,
    String dependencyKey
  ) {
    resetPendingStep(instance.Id);

    Integer sleepSeconds = resolveSleepSeconds(dependencyKey);
    instance.Status__c = 'Suspended';
    instance.Sleep_Until__c = DateTime.now().addSeconds(sleepSeconds);
    instance.Async_Job_Id__c = WorkflowRetrySleepScheduler.scheduleSleepResume(
      instance.Id,
      resolvedStep,
      sleepSeconds
    );
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    // Distinct, dashboard-readable signal that this suspend is a breaker fast-fail,
    // not a plain sleep. Best-effort (WorkflowLog swallows insert failures).
    WorkflowLog.warn(
      'CircuitBreaker',
      'parked by circuit breaker ' + dependencyKey,
      instance.Id
    );
  }

  // Reset the current step's pre-execution state so a re-park is always clean
  // (mirrors WorkflowStepAdmission.parkForConcurrency): an external resume() can have
  // flipped the not-yet-executed step to Running and stamped a deadline. Put it back
  // to Pending and clear Timeout_At__c so the watchdog cannot fail a parked step.
  private static void resetPendingStep(Id instanceId) {
    List<Workflow_Step_Execution__c> pending = [
      SELECT Id, Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Status__c IN ('Pending', 'Running')
        AND Timeout_At__c != NULL
      WITH SYSTEM_MODE
    ];
    if (pending.isEmpty()) {
      return;
    }
    for (Workflow_Step_Execution__c step : pending) {
      step.Status__c = 'Pending';
      step.Timeout_At__c = null;
    }
    Database.update(pending, true, AccessLevel.SYSTEM_MODE);
  }

  // Sleep the parked step exactly until the breaker is due to admit probes, plus a
  // jitter band; fall back to a sane default when the remaining open window is
  // indeterminate. The remaining window is a lower bound on when a probe can run, so
  // the herd cannot wake early and stampede the still-open gate.
  private static Integer resolveSleepSeconds(String dependencyKey) {
    Integer base = CircuitBreakerGate.secondsUntilHalfOpen(dependencyKey);
    if (base == null || base <= 0) {
      base = parkFallbackSeconds;
    }
    return base + (Integer) Math.floor(Math.random() * PARK_JITTER_SECONDS);
  }
}
