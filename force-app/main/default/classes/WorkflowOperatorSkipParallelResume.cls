/**
 * @description Parallel-branch resume phase for the operator "resume past step"
 * intervention. When, after an operator skip, one or more parallel branches are
 * still incomplete, this class transitions the instance (Suspended when a
 * sibling is parked, otherwise Running), resets the resumable failed/undriven
 * sibling branches and re-enqueues the branches that need to be driven. All DML
 * and SOQL run in system mode. Split out of {@link WorkflowOperatorSkip} so each
 * cohesive phase stays within its own complexity budget; the join path lives on
 * {@link WorkflowOperatorSkipParallel}.
 */
public inherited sharing class WorkflowOperatorSkipParallelResume {
  /**
   * @description Not all parallel branches are done: re-drive the incomplete
   * siblings.
   * @param run the resume-past-step accumulator
   */
  public static void resumeIncompleteParallel(
    WorkflowOperatorSkip.ResumeSkipRun run
  ) {
    Workflow_Instance__c instance = run.instance;
    Boolean hasParkedSibling = hasParkedParallelSibling(run);

    instance.Status__c = hasParkedSibling ? 'Suspended' : 'Running';
    instance.Error_Message__c = null;
    instance.Failure_Category__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    Set<String> stepsToEnqueue = new Set<String>();
    List<Workflow_Step_Execution__c> stepsToReset = new List<Workflow_Step_Execution__c>();
    collectParallelResumeSteps(run, stepsToEnqueue, stepsToReset);
    if (!stepsToReset.isEmpty()) {
      Database.update(stepsToReset, true, AccessLevel.SYSTEM_MODE);
    }

    for (String ps : stepsToEnqueue) {
      enqueueParallelResumeStep(run.instanceId, ps);
    }
  }

  /**
   * @description Enqueues a single parallel-resume step, direct-enqueue under
   * test and via the standard `enqueueOrchestrator` path otherwise. Kept as a
   * helper so the test-only per-step `System.enqueueJob` is not lexically
   * inside the caller's loop. Test-only enqueue continues to honor
   * `disableQueueableInTest`.
   * @param instanceId the parent workflow instance to resume
   * @param stepName the parallel-sibling step name to drive
   */
  private static void enqueueParallelResumeStep(
    Id instanceId,
    String stepName
  ) {
    if (Test.isRunningTest()) {
      if (!WorkflowEngine.disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instanceId, stepName));
      }
    } else {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(instanceId, stepName);
    }
  }

  /**
   * @description True when a non-skipped sibling branch is parked (`Retrying`, or
   * `Pending` with recorded CPU time), meaning the instance should stay
   * `Suspended`.
   * @param run the resume-past-step accumulator
   * @return true when a sibling branch is parked
   */
  private static Boolean hasParkedParallelSibling(
    WorkflowOperatorSkip.ResumeSkipRun run
  ) {
    for (String ps : run.activeParallelSteps) {
      if (ps.equalsIgnoreCase(run.stepName)) {
        continue;
      }
      Workflow_Step_Execution__c pe = run.latestParallelMap.get(ps);
      if (
        pe != null &&
        (pe.Status__c == 'Retrying' ||
        (pe.Status__c == 'Pending' &&
        pe.CPU_Time_Ms__c != null))
      ) {
        return true;
      }
    }
    return false;
  }

  /**
   * @description Determine which sibling branches to reset/enqueue for parallel
   * resume.
   * @param run the resume-past-step accumulator
   * @param stepsToEnqueue out: sibling step names to enqueue
   * @param stepsToReset out: sibling step executions to reset
   */
  private static void collectParallelResumeSteps(
    WorkflowOperatorSkip.ResumeSkipRun run,
    Set<String> stepsToEnqueue,
    List<Workflow_Step_Execution__c> stepsToReset
  ) {
    for (String ps : run.activeParallelSteps) {
      if (ps.equalsIgnoreCase(run.stepName)) {
        continue;
      }
      Workflow_Step_Execution__c pe = run.latestParallelMap.get(ps);
      if (pe == null) {
        stepsToEnqueue.add(ps);
      } else if (pe.Status__c == 'Failed') {
        pe.Status__c = 'Pending';
        pe.Retry_Count__c = 0;
        pe.Error_Details__c = null;
        stepsToReset.add(pe);
        stepsToEnqueue.add(ps);
      } else if (pe.Status__c == 'Pending' && pe.CPU_Time_Ms__c == null) {
        // Initial/undriven pending branch: enqueue it directly after re-arming/clearing timeout
        Integer timeout = WorkflowStepTimeoutConfig.getStepTimeoutSeconds(
          ps,
          WorkflowTypeResolver.extractNamespace(run.instance.Workflow_Name__c)
        );
        if (timeout != null && timeout > 0) {
          pe.Timeout_At__c = DateTime.now().addSeconds(timeout);
        } else {
          pe.Timeout_At__c = null;
        }
        stepsToReset.add(pe);
        stepsToEnqueue.add(ps);
      }
    }
  }
}
