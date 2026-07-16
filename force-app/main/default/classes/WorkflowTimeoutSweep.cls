/**
 * @description Timeout→fail sweep orchestration for the watchdog heartbeat (§1).
 * Selects the bounded batch of steps whose watchdog deadline has passed, locks
 * their parents and step rows, finalizes each timed-out step (via
 * WorkflowTimeoutStepFailer), pre-creates compensation steps, and flushes all
 * accumulated DML in a single transition-then-DML batch. Preserves the
 * transition-then-DML batch order and the bounded LIMIT.
 *
 * Extracted from WorkflowEngine; the watchdog entry stays on WorkflowEngine as a
 * thin facade and this sweep is driven by WorkflowHeartbeatService. All DML and
 * SOQL run in system mode so the engine can drive workflows regardless of the
 * invoking user's object permissions.
 */
public inherited sharing class WorkflowTimeoutSweep {
  // Max number of timed-out steps a single watchdog heartbeat will fail. Each failure
  // triggers failWorkflowInstance() (its own SOQL/DML + optional alert queries), so this
  // bounds the heartbeat's governor usage. Remaining timeouts drain on the next heartbeat.
  @TestVisible
  private static Integer watchdogTimeoutBatchSize = 50;

  /**
   * @description Mutable accumulator for the timed-out-steps section (§1).
   * Bundled so the per-step helpers stay under the parameter-count limit while
   * still sharing the collections the section finalizes and flushes. Public
   * fields so WorkflowTimeoutStepFailer can populate the per-step transition
   * results, called qualified.
   */
  public class TimedOutStepContext {
    public Map<Id, Workflow_Instance__c> parents;
    public Map<Id, Workflow_Step_Execution__c> lockedSteps;
    public Map<String, Boolean> isRoutingWflow;
    public Map<String, Integer> latestRetryCounts;
    public List<Workflow_Step_Execution__c> stepsToUpdate = new List<Workflow_Step_Execution__c>();
    public Map<Id, Workflow_Instance__c> instancesToUpdate = new Map<Id, Workflow_Instance__c>();
    public List<Workflow_Step_Execution__c> compensationStepsToInsert = new List<Workflow_Step_Execution__c>();
    public List<Id> orchestratorInstanceIds = new List<Id>();
    public Set<Id> instancesNeedingCompensationInfo = new Set<Id>();
    public Set<String> activeStepNamesForComp = new Set<String>();
  }

  /**
   * @description §1. Process Timed-out Steps. Exclude steps whose parent is
   * Paused: a parked parent is not runnable, so its step rows (e.g. parallel
   * branch rows the SPLIT path stamped with Timeout_At__c before their RUN_STEP
   * reached the gate, or a parked initial step) would otherwise be selected and
   * skipped, wasting the bounded batch and delaying real timeouts in other
   * workflows. Resume re-arms these deadlines (see reArmTimeoutsForResume).
   * @param now the heartbeat evaluation instant
   * @param watchdogTerminalInstances accumulates parents transitioned to a
   * terminal state, for the deferred end-of-heartbeat lifecycle publish
   */
  public static void processTimedOutSteps(
    Datetime now,
    List<Workflow_Instance__c> watchdogTerminalInstances
  ) {
    List<Workflow_Step_Execution__c> timedOutSteps = [
      SELECT Id, Workflow_Instance__c, Step_Name__c, Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE
        Status__c IN ('Running', 'Pending')
        AND Timeout_At__c <= :now
        AND Workflow_Instance__r.Status__c != 'Paused'
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT :watchdogTimeoutBatchSize
    ];

    if (timedOutSteps.isEmpty()) {
      return;
    }

    Set<Id> stepIds = new Set<Id>();
    Set<Id> instanceIds = new Set<Id>();
    for (Workflow_Step_Execution__c step : timedOutSteps) {
      stepIds.add(step.Id);
      instanceIds.add(step.Workflow_Instance__c);
    }

    // Lock parent instances
    Map<Id, Workflow_Instance__c> parents = new Map<Id, Workflow_Instance__c>(
      [
        SELECT
          Id,
          Name,
          Status__c,
          Current_Step__c,
          Compensation_Stack__c,
          Error_Message__c,
          Workflow_Name__c,
          Correlation_Key__c,
          Root_Correlation_Key__c,
          Failure_Category__c,
          Concurrency_Parked__c,
          Concurrency_Slot_Held__c
        FROM Workflow_Instance__c
        WHERE Id IN :instanceIds
        WITH SYSTEM_MODE
        FOR UPDATE
      ]
    );

    // Lock step executions
    Map<Id, Workflow_Step_Execution__c> lockedSteps = new Map<Id, Workflow_Step_Execution__c>(
      [
        SELECT
          Id,
          Status__c,
          Error_Details__c,
          Timeout_At__c,
          Step_Name__c,
          Workflow_Instance__c
        FROM Workflow_Step_Execution__c
        WHERE Id IN :stepIds
        WITH SYSTEM_MODE
        FOR UPDATE
      ]
    );

    TimedOutStepContext ctx = new TimedOutStepContext();
    ctx.parents = parents;
    ctx.lockedSteps = lockedSteps;
    ctx.isRoutingWflow = WorkflowTimeoutSupport.classifyRoutingWorkflows(
      parents
    );
    ctx.latestRetryCounts = WorkflowTimeoutSupport.loadLatestRetryCounts(
      parents,
      ctx.isRoutingWflow
    );

    for (Workflow_Step_Execution__c step : timedOutSteps) {
      WorkflowTimeoutStepFailer.finalizeTimedOutStep(step, ctx);
    }

    createCompensationStepsForTimedOut(ctx);
    flushTimedOutStepResults(ctx, watchdogTerminalInstances);
  }

  // Pre-create the first compensation step-exec log for each instance entering
  // compensation from a timed-out step.
  private static void createCompensationStepsForTimedOut(
    TimedOutStepContext ctx
  ) {
    Map<String, Workflow_Step_Execution__c> existingCompSteps = buildExistingCompSteps(
      ctx.instancesNeedingCompensationInfo
    );
    Map<String, Workflow_Step_Execution__c> originalStepsMap = buildOriginalStepExecs(
      ctx.instancesNeedingCompensationInfo,
      ctx.activeStepNamesForComp
    );

    for (Id instId : ctx.instancesNeedingCompensationInfo) {
      Workflow_Instance__c parent = ctx.parents.get(instId);
      List<String> stack = (List<String>) JSON.deserialize(
        parent.Compensation_Stack__c,
        List<String>.class
      );
      String activeStepName = stack[stack.size() - 1];
      String compensationStepLogName = activeStepName + '_Compensate';

      if (
        existingCompSteps.containsKey(parent.Id + ':' + compensationStepLogName)
      ) {
        continue;
      }

      Workflow_Step_Execution__c orig = originalStepsMap.get(
        parent.Id + ':' + activeStepName
      );

      Workflow_Step_Execution__c compStepExec = new Workflow_Step_Execution__c();
      compStepExec.Workflow_Instance__c = parent.Id;
      compStepExec.Step_Name__c = compensationStepLogName;
      compStepExec.Status__c = 'Pending';
      compStepExec.Input__c = (orig != null) ? orig.Input__c : null;
      compStepExec.Output__c = (orig != null) ? orig.Output__c : null;
      compStepExec.Retry_Count__c = 0;
      ctx.compensationStepsToInsert.add(compStepExec);
      ctx.orchestratorInstanceIds.add(parent.Id);
    }
  }

  // Map of "<instanceId>:<stepName>_Compensate" -> existing compensation step
  // for the instances entering compensation (avoids duplicating a comp step).
  private static Map<String, Workflow_Step_Execution__c> buildExistingCompSteps(
    Set<Id> instancesNeedingCompensationInfo
  ) {
    Map<String, Workflow_Step_Execution__c> existingCompSteps = new Map<String, Workflow_Step_Execution__c>();
    if (instancesNeedingCompensationInfo.isEmpty()) {
      return existingCompSteps;
    }
    // Bind the LIKE pattern so the escaped underscore ('\_', matching a
    // literal '_') lives in an Apex string literal rather than inline SOQL.
    String compensateSuffixPattern = '%\\_Compensate';
    for (Workflow_Step_Execution__c e : [
      SELECT Id, Workflow_Instance__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instancesNeedingCompensationInfo
        AND Step_Name__c LIKE :compensateSuffixPattern
      WITH SYSTEM_MODE
    ]) {
      existingCompSteps.put(e.Workflow_Instance__c + ':' + e.Step_Name__c, e);
    }
    return existingCompSteps;
  }

  // Map of "<instanceId>:<stepName>" -> most recent original step exec, used to
  // seed the compensation step's Input/Output.
  private static Map<String, Workflow_Step_Execution__c> buildOriginalStepExecs(
    Set<Id> instancesNeedingCompensationInfo,
    Set<String> activeStepNamesForComp
  ) {
    Map<String, Workflow_Step_Execution__c> originalStepsMap = new Map<String, Workflow_Step_Execution__c>();
    if (instancesNeedingCompensationInfo.isEmpty()) {
      return originalStepsMap;
    }
    for (Workflow_Step_Execution__c o : [
      SELECT Workflow_Instance__c, Step_Name__c, Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instancesNeedingCompensationInfo
        AND Step_Name__c IN :activeStepNamesForComp
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      String key = o.Workflow_Instance__c + ':' + o.Step_Name__c;
      if (!originalStepsMap.containsKey(key)) {
        originalStepsMap.put(key, o);
      }
    }
    return originalStepsMap;
  }

  // Flush all accumulated DML for the timed-out-steps section, publish alerts,
  // enqueue orchestrators, and record terminal instances for the deferred
  // lifecycle publish.
  private static void flushTimedOutStepResults(
    TimedOutStepContext ctx,
    List<Workflow_Instance__c> watchdogTerminalInstances
  ) {
    if (!ctx.stepsToUpdate.isEmpty()) {
      Database.update(ctx.stepsToUpdate, true, AccessLevel.SYSTEM_MODE);
    }
    if (!ctx.compensationStepsToInsert.isEmpty()) {
      Database.insert(
        ctx.compensationStepsToInsert,
        true,
        AccessLevel.SYSTEM_MODE
      );
    }
    if (!ctx.instancesToUpdate.isEmpty()) {
      Database.update(
        ctx.instancesToUpdate.values(),
        true,
        AccessLevel.SYSTEM_MODE
      );
      WorkflowTimeoutSupport.notifyTerminalFailures(
        ctx.instancesToUpdate.values()
      );
    }

    for (Workflow_Instance__c parent : ctx.instancesToUpdate.values()) {
      WorkflowAlertManager.sendAlert(parent, parent.Error_Message__c);
    }

    WorkflowTimeoutSupport.enqueueOrchestratorsBounded(
      ctx.orchestratorInstanceIds
    );

    // Defer lifecycle publishing to the end of the heartbeat. Only the parents
    // transitioned to a terminal state (Failed) emit — Compensating parents are
    // skipped by the publisher.
    watchdogTerminalInstances.addAll(ctx.instancesToUpdate.values());
  }
}
