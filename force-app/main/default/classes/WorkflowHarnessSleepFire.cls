/**
 * Test-only affordance that deterministically wakes a sleep/retry wait for the
 * WorkflowTestHarness: locates the parked instance, resumes it through the engine's
 * own runStep resume path (the path WorkflowSleepJob / WorkflowRetryJob enqueue),
 * then drives to the next stable state.
 */
@IsTest
public inherited sharing class WorkflowHarnessSleepFire {
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
