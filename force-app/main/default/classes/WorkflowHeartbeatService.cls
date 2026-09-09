/**
 * @description Sequences the watchdog heartbeat: the fixed-order body that
 * WorkflowEngine.processWatchdogHeartbeat() delegates to. Runs the timeout,
 * deadline, sleep-resume, unrouted-signal, schedule, debounce, concurrency-
 * reconcile, transient-retry-rescue, orphan-reclaim, and stall-detection phases
 * in strict order, then publishes deferred lifecycle events LAST so a best-effort
 * publish can never spend a DML statement a required section needs.
 *
 * Extracted from WorkflowEngine; the public entry stays on WorkflowEngine as a
 * thin facade so its callers are untouched. All DML and SOQL run in system mode
 * so the engine can drive workflows regardless of the invoking user's object
 * permissions.
 */
public inherited sharing class WorkflowHeartbeatService {
  /**
   * @description Evaluates and resumes suspended workflows that have exceeded
   * their sleep time, and terminates active steps that have exceeded their
   * timeout limits. Runs every section in a strict fixed order; the deferred
   * lifecycle publish is always last.
   */
  public static void runWatchdogHeartbeat() {
    Datetime now = WorkflowEngine.mockNow != null
      ? WorkflowEngine.mockNow
      : System.now();

    // Terminal instances finalized by the timed-out-steps / deadline sections
    // below. Their lifecycle events are published once at the very END of the
    // heartbeat, after ALL required work (including the sleep-resume section) is
    // done, so the best-effort publish can never spend a DML statement the
    // resume section needs.
    List<Workflow_Instance__c> watchdogTerminalInstances = new List<Workflow_Instance__c>();

    // 1. Process timed-out steps.
    WorkflowTimeoutSweep.processTimedOutSteps(now, watchdogTerminalInstances);

    // 1b. Process exceeded execution deadlines (bounded per heartbeat).
    WorkflowDeadlineSweep.processExceededDeadlines(
      now,
      watchdogTerminalInstances
    );

    // 2. Process sleep resumptions (bounded per heartbeat).
    WorkflowSleepResumeSweep.processSleepResumptions(now);

    // 2b. Sweep Suspended instances for matching Unrouted signals (safety net).
    WorkflowUnroutedSweep.sweepUnroutedSuspendedSignals();

    // 3. Process due recurring schedules (0-slot: runs inside the watchdog
    // heartbeat, so enabling N Workflow_Schedule__c records adds 0 scheduled-job
    // slots).
    try {
      WorkflowScheduleSweeper.sweep();
    } catch (Exception ignored) {
      // Best-effort sweep; a failure here must not abort the watchdog heartbeat.
    }

    // 3b. Process due debounced starts (0-slot: runs inside the watchdog heartbeat).
    try {
      WorkflowDebouncer.sweep();
    } catch (Exception ignored) {
      // Best-effort sweep; a failure here must not abort the watchdog heartbeat.
    }

    // 4. Reconcile concurrency slot counters. Recomputes each configured
    // workflow's in-flight count from the true number of non-terminal
    // slot-holding instances, reclaiming any slot leaked by an instance that
    // died without releasing (crash, killed transaction) so a parked instance is
    // never starved indefinitely.
    try {
      ConcurrencyGate.reconcileAll();
    } catch (Exception ignored) {
      // Best-effort reconcile; a failure here must not abort the watchdog heartbeat.
    }

    // 4b. Reconcile circuit breakers: flip every Open breaker whose open duration
    // has elapsed to Half-Open, so a dependency that opened and then went quiet still
    // recovers within one heartbeat cadence with zero live traffic to drive the
    // on-demand transition in tryAdmit.
    try {
      CircuitBreakerGate.sweepHalfOpen();
    } catch (Exception ignored) {
      // Best-effort sweep; a failure here must not abort the watchdog heartbeat.
    }

    // 5. Rescue transient-lock retry branches orphaned when a parallel sibling
    // that completed during the backoff flipped the parent out of Suspended.
    WorkflowOrphanReclaimSweep.rescueOrphanedTransientRetryBranches(now);

    // 6. Auto-reclaim orphaned instances.
    WorkflowOrphanReclaimSweep.autoReclaimOrphanedInstances(now);

    // Run proactive stall detection and alerting hook
    try {
      WorkflowAlertManager.detectAndAlertStalls();
    } catch (Exception ignored) {
      // Best-effort stall detection; a failure here must not abort the watchdog heartbeat.
    }

    // All required heartbeat work (timed-out-step failures, sleep resumptions,
    // and schedule sweeps) is now done, so the best-effort lifecycle publish
    // runs last with no risk of starving a required update/enqueue of its DML budget.
    WorkflowLifecyclePublisher.publish(watchdogTerminalInstances);
  }
}
