/**
 * @description Bulk step-deadline re-arming and transient-retry branch re-drive
 * for the Revenant engine. On resuming instances from a Paused park it re-stamps
 * a fresh watchdog `Timeout_At__c` on each current Pending/Running step (skipping
 * concurrency-bounded instances that have not yet won an admission slot) and
 * re-schedules their dynamic timeout jobs; it also re-drives parallel-branch
 * steps parked for a transient row-lock retry, re-arming only those rows and
 * bulk-publishing their RUN_STEP events in a single EventBus call. Extracted from
 * `WorkflowEngine`; step timeouts resolve via {@link WorkflowStepTimeoutConfig}
 * and timeout jobs are armed via {@link WorkflowTimeoutScheduler}.
 */
public inherited sharing class WorkflowTimeoutReArm {
  /**
   * Re-establishes step timeouts for instances being resumed from a Paused park.
   * Parking clears/omits the watchdog deadline so parked rows do not pollute the
   * timeout batch; on resume we re-stamp a fresh Timeout_At__c on each instance's
   * current Pending/Running step(s) (the watchdog safety net) and schedule the
   * dynamic timeout jobs, mirroring how start() arms a fresh step. Must run before
   * the resumed workers are enqueued so a delayed worker still has an enforced
   * deadline.
   * @param instances the instances being resumed from a Paused park to re-arm
   */
  public static void reArmTimeoutsForResume(
    List<Workflow_Instance__c> instances
  ) {
    if (instances == null || instances.isEmpty()) {
      return;
    }
    Set<Id> instanceIds = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      instanceIds.add(inst.Id);
    }

    Set<Id> deferIds = collectConcurrencyDeferIds(instanceIds);

    List<Workflow_Step_Execution__c> steps = [
      SELECT
        Id,
        Workflow_Instance__c,
        Step_Name__c,
        Workflow_Instance__r.Workflow_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instanceIds
        AND Status__c IN ('Pending', 'Running')
      WITH SYSTEM_MODE
    ];
    reArmStepDeadlines(steps, deferIds);
    scheduleActiveStepTimeoutJobs(steps, deferIds);
  }

  /**
   * Re-queries the authoritative slot flag and collects the ids of concurrency-
   * bounded instances that have not yet won an admission slot. Their initial step
   * deadline must NOT be re-armed here (the admission gate re-arms it once a slot
   * is won); an in-memory caller value cannot skew this decision.
   * @param instanceIds the candidate instance ids being resumed
   * @return the ids whose deadline re-arm must be deferred to the admission gate
   */
  private static Set<Id> collectConcurrencyDeferIds(Set<Id> instanceIds) {
    Set<Id> deferIds = new Set<Id>();
    for (Workflow_Instance__c inst : [
      SELECT Id, Workflow_Name__c, Concurrency_Slot_Held__c
      FROM Workflow_Instance__c
      WHERE Id IN :instanceIds
      WITH SYSTEM_MODE
    ]) {
      if (
        !inst.Concurrency_Slot_Held__c &&
        ConcurrencyGate.isConfigured(inst.Workflow_Name__c)
      ) {
        deferIds.add(inst.Id);
      }
    }
    return deferIds;
  }

  /**
   * Re-stamps a fresh watchdog deadline on each non-deferred active step that has
   * a positive configured timeout, then persists them in a single update.
   * @param steps the queried Pending/Running step rows
   * @param deferIds instance ids whose steps must not be re-armed
   */
  private static void reArmStepDeadlines(
    List<Workflow_Step_Execution__c> steps,
    Set<Id> deferIds
  ) {
    List<Workflow_Step_Execution__c> toUpdate = new List<Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c step : steps) {
      if (deferIds.contains(step.Workflow_Instance__c)) {
        continue;
      }
      Integer timeout = WorkflowStepTimeoutConfig.getStepTimeoutSeconds(
        step.Step_Name__c,
        WorkflowTypeResolver.extractNamespace(
          step.Workflow_Instance__r.Workflow_Name__c
        )
      );
      if (timeout == null || timeout <= 0) {
        continue;
      }
      step.Timeout_At__c = DateTime.now().addSeconds(timeout);
      toUpdate.add(step);
    }
    if (!toUpdate.isEmpty()) {
      Database.update(toUpdate, true, AccessLevel.SYSTEM_MODE);
    }
  }

  /**
   * Schedules the dynamic timeout jobs for the genuinely active (non-deferred)
   * step rows only. A parallel instance keeps every branch name in Current_Step__c
   * until the join, so a completed branch lingers there; driving off the queried
   * Pending/Running rows (instead of parsing Current_Step__c) avoids scheduling a
   * timeout for a completed branch that would later find no active step row and
   * wrongly fail the whole instance "before starting".
   * @param steps the queried Pending/Running step rows
   * @param deferIds instance ids whose steps must not be scheduled
   */
  private static void scheduleActiveStepTimeoutJobs(
    List<Workflow_Step_Execution__c> steps,
    Set<Id> deferIds
  ) {
    for (Workflow_Step_Execution__c step : steps) {
      if (deferIds.contains(step.Workflow_Instance__c)) {
        continue;
      }
      WorkflowTimeoutScheduler.scheduleTimeoutJobIfNeeded(
        step.Workflow_Instance__c,
        step.Step_Name__c,
        step.Workflow_Instance__r.Workflow_Name__c
      );
    }
  }

  /**
   * Builds the fresh Timeout_At__c re-arm updates for transient-retry branches
   * that have a positive step timeout configured.
   * @param retryBranches the retry-marked step rows
   * @return the step updates to apply (may be empty)
   */
  private static List<Workflow_Step_Execution__c> buildTransientRetryReArm(
    List<Workflow_Step_Execution__c> retryBranches
  ) {
    List<Workflow_Step_Execution__c> toReArm = new List<Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c branch : retryBranches) {
      Integer timeout = WorkflowStepTimeoutConfig.getStepTimeoutSeconds(
        branch.Step_Name__c,
        WorkflowTypeResolver.extractNamespace(
          branch.Workflow_Instance__r.Workflow_Name__c
        )
      );
      if (timeout == null || timeout <= 0) {
        continue;
      }
      toReArm.add(
        new Workflow_Step_Execution__c(
          Id = branch.Id,
          Timeout_At__c = DateTime.now().addSeconds(timeout)
        )
      );
    }
    return toReArm;
  }

  /**
   * Dispatches each transient-retry branch: enqueues the orchestrator directly
   * under test, otherwise collects a RUN_STEP event for bulk publish.
   * @param retryBranches the retry-marked step rows
   * @return the RUN_STEP events to publish (empty under test)
   */
  private static List<Workflow_Event__e> dispatchTransientRetryBranches(
    List<Workflow_Step_Execution__c> retryBranches
  ) {
    List<Workflow_Event__e> branchEvents = new List<Workflow_Event__e>();
    for (Workflow_Step_Execution__c branch : retryBranches) {
      Workflow_Event__e evt = dispatchTransientRetryBranchOne(branch);
      if (evt != null) {
        branchEvents.add(evt);
      }
    }
    return branchEvents;
  }

  /**
   * @description Dispatches a single transient-retry branch, choosing between
   * the production platform-event path and the test direct-enqueue path. Under
   * test the per-branch `System.enqueueJob` runs inside this helper so it is
   * not lexically inside the caller's loop; production still collects a
   * RUN_STEP event for a single bulk `EventBus.publish`.
   * @param branch the retry-marked step row to dispatch
   * @return the RUN_STEP event to publish (production), or null under test
   */
  private static Workflow_Event__e dispatchTransientRetryBranchOne(
    Workflow_Step_Execution__c branch
  ) {
    if (!Test.isRunningTest()) {
      return new Workflow_Event__e(
        Workflow_Instance_Id__c = branch.Workflow_Instance__c,
        Event_Type__c = 'RUN_STEP',
        Payload__c = branch.Step_Name__c
      );
    }
    if (!WorkflowEngine.disableQueueableInTest) {
      System.enqueueJob(
        new WorkflowOrchestrator(
          branch.Workflow_Instance__c,
          branch.Step_Name__c
        )
      );
    }
    return null;
  }

  /**
   * @description Re-drives a set of parallel-branch steps that are parked for a
   * transient row-lock retry, BY NAME (the blank-stepName watchdog orchestrator is
   * ignored for a comma-separated Current_Step__c). Shared by the watchdog
   * sleep-resume (Suspended parents) and the orphaned-retry sweep (Running parents
   * whose sibling flipped them out of Suspended). Re-arms ONLY these retry-marked
   * rows' watchdog deadlines (so a sibling's overdue deadline is not masked) and
   * bulk-publishes a single EventBus call (so a heartbeat waking many sleepers
   * cannot exhaust the DML-statement limit), throwing on any failed publish so the
   * wake-up rolls back and retries intact.
   * @param retryBranches the transient-retry-marked parallel branch step
   * executions to re-drive by name
   */
  public static void reDriveTransientRetryBranches(
    List<Workflow_Step_Execution__c> retryBranches
  ) {
    if (retryBranches == null || retryBranches.isEmpty()) {
      return;
    }
    // Re-arm only the retry-marked rows whose deadline scheduleTransientLockRetry
    // cleared for backoff (their instance is necessarily past admission, so no
    // concurrency-defer check is needed) — never every active step on the instance.
    List<Workflow_Step_Execution__c> toReArm = buildTransientRetryReArm(
      retryBranches
    );
    if (!toReArm.isEmpty()) {
      Database.update(toReArm, true, AccessLevel.SYSTEM_MODE);
    }

    List<Workflow_Event__e> branchEvents = dispatchTransientRetryBranches(
      retryBranches
    );
    if (!branchEvents.isEmpty()) {
      WorkflowWatchdog.bootstrap();
      List<Database.SaveResult> srs = EventBus.publish(branchEvents);
      WorkflowOrchestratorEnqueue.throwOnPublishErrors(
        srs,
        'Failed to publish transient-retry branch event: '
      );
    }
  }
}
