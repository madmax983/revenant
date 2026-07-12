/**
 * Test-only affordance that deterministically wakes a sleep/retry wait for the
 * WorkflowTestHarness: locates the parked instance, resumes it through the engine's
 * own runStep resume path (the path WorkflowSleepJob / WorkflowRetryJob enqueue),
 * then drives to the next stable state.
 */
@IsTest
public inherited sharing class WorkflowHarnessSleepFire {
  /**
   * @description Deterministically wakes an instance parked in a sleep wait at
   * the given step, resumes it through the engine, and drives to the next stable state.
   * @param ctx The harness context identifying the workflow instance under test.
   * @param stepName The name of the step currently sleeping.
   * @param maxHops The maximum number of step transitions to drive after waking.
   * @return The harness result after resuming and driving the instance.
   */
  public static WorkflowTestHarness.Result fireSleep(
    WorkflowHarnessContext ctx,
    String stepName,
    Integer maxHops
  ) {
    WorkflowHarnessContext.requireStep(stepName);
    WorkflowHarnessContext.requirePositiveHops(maxHops);
    Workflow_Instance__c inst = WorkflowHarnessWaitFinder.findSleeping(
      ctx,
      stepName
    );
    if (inst == null) {
      throw new WorkflowTestHarness.HarnessException(
        'Step ' + stepName + ' is not currently sleeping.'
      );
    }
    runWake(ctx, inst.Id, stepName);
    return WorkflowHarnessDriver.drive(ctx, maxHops);
  }

  /**
   * @description Deterministically wakes an instance awaiting a retry backoff at
   * the given step, resumes it through the engine, and drives to the next stable state.
   * @param ctx The harness context identifying the workflow instance under test.
   * @param stepName The name of the step currently awaiting retry.
   * @param maxHops The maximum number of step transitions to drive after waking.
   * @return The harness result after resuming and driving the instance.
   */
  public static WorkflowTestHarness.Result fireRetry(
    WorkflowHarnessContext ctx,
    String stepName,
    Integer maxHops
  ) {
    WorkflowHarnessContext.requireStep(stepName);
    WorkflowHarnessContext.requirePositiveHops(maxHops);
    Workflow_Instance__c inst = WorkflowHarnessWaitFinder.findRetrying(
      ctx,
      stepName
    );
    if (inst == null) {
      throw new WorkflowTestHarness.HarnessException(
        'Step ' + stepName + ' is not currently awaiting retry.'
      );
    }
    runWake(ctx, inst.Id, stepName);
    return WorkflowHarnessDriver.drive(ctx, maxHops);
  }

  private static void runWake(
    WorkflowHarnessContext ctx,
    Id instanceId,
    String stepName
  ) {
    Boolean isCallout = WorkflowHarnessCore.isCalloutStep(stepName);
    if (!isCallout) {
      WorkflowHarnessSleep.clearSleepMarkers(instanceId);
    }
    WorkflowHarnessCore.runStepSafely(ctx, instanceId, stepName);
    if (isCallout) {
      WorkflowHarnessSleep.clearStaleSleepMarkers(instanceId);
    }
  }
}
