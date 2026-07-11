/**
 * Test-only low-level operations shared by the WorkflowTestHarness collaborators:
 * event delivery, the engine-faithful runStep/handleCrash hop, callout-step
 * detection, the cached instance-tree scan, single-instance lookup, and assembly of
 * the inspectable Result snapshot. All record access is explicit system mode.
 */
@IsTest
public inherited sharing class WorkflowHarnessCore {
  private static final Set<String> TERMINAL_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled',
    'ContinuedAsNew'
  };

  public static void deliverEvents() {
    // Safe to call even with nothing queued; flushes published Workflow_Event__e
    // records through WorkflowEventTrigger (signals, child completions).
    Test.getEventBus().deliver();
  }

  /**
   * Invokes the engine the way WorkflowOrchestrator does, and rescues a thrown
   * step exactly as WorkflowFinalizer / SagaWorkflowExampleTest do — a synchronous
   * catch that hands off to WorkflowEngine.handleCrash. (An earlier version wrapped
   * each hop in a Database savepoint for production-faithful rollback, but that
   * leaks one unreleased savepoint per successful hop; this matches the engine's
   * own proven crash-driving pattern instead.)
   */
  public static void runStepSafely(
    WorkflowHarnessContext ctx,
    Id instanceId,
    String stepName
  ) {
    ctx.scannedInstanceIds.remove(instanceId);
    ctx.totalHops++;
    try {
      WorkflowEngine.runStep(instanceId, stepName);
    } catch (Exception ex) {
      WorkflowEngine.handleCrash(instanceId, stepName, ex);
    }
  }

  public static Boolean isCalloutStep(String stepName) {
    if (String.isBlank(stepName)) {
      return false;
    }
    try {
      Type stepType = WorkflowTypeResolver.resolve(stepName);
      if (stepType != null) {
        return stepType.newInstance() instanceof CalloutStep;
      }
    } catch (Exception e) {
      return false;
    }
    return false;
  }

  /**
   * Root instance plus all live descendants (children spawned via START_CHILD).
   *
   * Stays frugal with SOQL — the whole drive runs inside the caller's one
   * governor-limit budget. The known-instance set is cached across hops, so the
   * common case costs a single status query per hop. The descendant scan only runs
   * when some instance is parked in a non-sleep suspend (the state a START_CHILD
   * leaves its parent in), which is the only way a new child can have appeared.
   */
  public static List<Workflow_Instance__c> collectTree(
    WorkflowHarnessContext ctx
  ) {
    Map<Id, Workflow_Instance__c> byId = new Map<Id, Workflow_Instance__c>(
      [
        SELECT Id, Status__c, Current_Step__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id IN :ctx.knownInstanceIds
        WITH SYSTEM_MODE
      ]
    );

    if (maybeSpawnedChild(byId.values())) {
      scanForChildren(ctx, byId);
    }
    return byId.values();
  }

  private static Boolean maybeSpawnedChild(
    List<Workflow_Instance__c> instances
  ) {
    for (Workflow_Instance__c inst : instances) {
      if (inst.Status__c == 'Suspended' && inst.Sleep_Until__c == null) {
        return true;
      }
    }
    return false;
  }

  private static void scanForChildren(
    WorkflowHarnessContext ctx,
    Map<Id, Workflow_Instance__c> byId
  ) {
    Set<Id> unscannedIds = new Set<Id>();
    for (Id instId : ctx.knownInstanceIds) {
      if (!ctx.scannedInstanceIds.contains(instId)) {
        unscannedIds.add(instId);
      }
    }
    if (unscannedIds.isEmpty()) {
      return;
    }

    List<Workflow_Instance__c> children = [
      SELECT Id, Status__c, Current_Step__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE
        Parent_Instance__c IN :unscannedIds
        AND Id NOT IN :ctx.knownInstanceIds
      WITH SYSTEM_MODE
    ];
    for (Workflow_Instance__c child : children) {
      byId.put(child.Id, child);
      ctx.knownInstanceIds.add(child.Id);
    }
    ctx.scannedInstanceIds.addAll(unscannedIds);
  }

  public static Workflow_Instance__c queryInstance(Id instanceId) {
    List<Workflow_Instance__c> results = [
      SELECT Id, Status__c, Current_Step__c, Sleep_Until__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (results.isEmpty()) {
      throw new WorkflowTestHarness.HarnessException(
        'Workflow instance ' + instanceId + ' not found in the database.'
      );
    }
    return results[0];
  }

  public static WorkflowTestHarness.Result buildResult(
    WorkflowHarnessContext ctx
  ) {
    Workflow_Instance__c root = queryInstance(ctx.rootInstanceId);

    WorkflowTestHarness.Result r = new WorkflowTestHarness.Result();
    r.instanceId = ctx.rootInstanceId;
    r.status = root.Status__c;
    r.output = WorkflowEngine.resolvePayload(root.Output__c);
    r.hops = ctx.totalHops;
    r.isTerminal = TERMINAL_STATUSES.contains(root.Status__c);
    r.isSuspended = root.Status__c == 'Suspended';
    r.executedSteps = new List<String>();
    r.completedSteps = new List<String>();
    r.compensatedSteps = new List<String>();

    Map<String, String> stepLatestStatus = new Map<String, String>();

    for (Workflow_Step_Execution__c se : [
      SELECT Step_Name__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :ctx.rootInstanceId
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
    ]) {
      r.executedSteps.add(se.Step_Name__c);
      if (se.Status__c == 'Completed') {
        r.completedSteps.add(se.Step_Name__c);
      } else if (se.Status__c == 'Compensated') {
        r.compensatedSteps.add(se.Step_Name__c);
      }
      stepLatestStatus.put(se.Step_Name__c.toLowerCase(), se.Status__c);
    }

    r.isSleeping = false;
    r.isAwaitingRetry = false;
    applySleepRetryFlags(r, root, stepLatestStatus);
    return r;
  }

  private static void applySleepRetryFlags(
    WorkflowTestHarness.Result r,
    Workflow_Instance__c root,
    Map<String, String> stepLatestStatus
  ) {
    if (root.Status__c != 'Suspended' || root.Sleep_Until__c == null) {
      return;
    }
    for (String step : activeStepNames(root.Current_Step__c)) {
      markSleepOrRetry(r, step, stepLatestStatus);
    }
    if (!r.isSleeping && !r.isAwaitingRetry) {
      r.isSleeping = true;
    }
  }

  private static List<String> activeStepNames(String currentStep) {
    List<String> steps = new List<String>();
    if (String.isBlank(currentStep)) {
      return steps;
    }
    for (String s : currentStep.split(',')) {
      steps.add(s.trim());
    }
    return steps;
  }

  private static void markSleepOrRetry(
    WorkflowTestHarness.Result r,
    String step,
    Map<String, String> stepLatestStatus
  ) {
    String forwardKey = step.toLowerCase();
    String compensateKey = forwardKey + '_compensate';
    String status = stepLatestStatus.containsKey(compensateKey)
      ? stepLatestStatus.get(compensateKey)
      : stepLatestStatus.get(forwardKey);
    if (status == 'Retrying') {
      r.isAwaitingRetry = true;
    } else if (status == 'Pending') {
      r.isSleeping = true;
    }
  }
}
