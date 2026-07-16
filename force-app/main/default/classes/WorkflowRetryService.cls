/**
 * @description Operator/redrive retry entry point for the Revenant engine.
 * Resumes a `Failed` `Workflow_Instance__c` from the step (or parallel branch
 * set) where it failed: it reloads and locks the instance, resolves the target
 * steps from the current step or the compensation stack, resets those step
 * executions to `Pending` (clearing their retry counters), flips the instance
 * back to `Running`/`Compensating`, and re-enqueues the orchestrator(s) so
 * execution continues. All DML and SOQL run in system mode so a redrive
 * proceeds regardless of the invoking user's object permissions. Extracted from
 * `WorkflowEngine`; callers invoke {@link WorkflowRetryService#retryWorkflow}
 * directly. Shared scheduling/enqueue primitives remain on `WorkflowEngine` and
 * on {@link WorkflowOrchestratorEnqueue} and are called through unchanged.
 */
public inherited sharing class WorkflowRetryService {
  /**
   * @description Resumes a failed workflow instance from the step where it
   * failed, resetting its state and retry counter.
   * @param instanceId Id of the failed instance to retry
   */
  public static void retryWorkflow(Id instanceId) {
    Workflow_Instance__c instance = loadInstanceForRetry(instanceId);

    List<String> stack = parseCompensationStack(instance);
    Boolean hasCompensations = !stack.isEmpty();

    List<String> targetStepNames = resolveRetryTargetSteps(
      instance,
      stack,
      hasCompensations
    );

    // Reset the failed step's execution status to let it execute again. Bulk-load the
    // latest execution per target step in ONE query (was one SOQL per step in a loop),
    // build a name->latest map, then update the resettable ones together.
    Map<String, Workflow_Step_Execution__c> latestStepByName = resetRetryTargetSteps(
      instanceId,
      targetStepNames
    );

    if (hasCompensations) {
      instance.Status__c = 'Compensating';
    } else {
      instance.Status__c = 'Running';
    }
    instance.Error_Message__c = null;
    instance.Failure_Category__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    // Enqueue the orchestrator to resume execution
    if (
      hasCompensations ||
      String.isBlank(instance.Current_Step__c) ||
      !instance.Current_Step__c.contains(',')
    ) {
      WorkflowOrchestratorEnqueue.enqueueOrchestratorForInstance(instanceId);
      return;
    }

    enqueueParallelBranchRetries(instanceId, targetStepNames, latestStepByName);
  }

  /**
   * @description Fetches and locks (FOR UPDATE) the instance to retry, requiring
   * it to be in `Failed` status.
   * @param instanceId Id of the instance being retried
   * @return the locked `Failed` instance
   */
  private static Workflow_Instance__c loadInstanceForRetry(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Status__c,
        Current_Step__c,
        Error_Message__c,
        Compensation_Stack__c,
        Workflow_Name__c,
        Failure_Category__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      throw new WorkflowEngine.WorkflowException(
        'Workflow instance not found: ' + instanceId
      );
    }
    Workflow_Instance__c instance = instances[0];
    if (instance.Status__c != 'Failed') {
      throw new WorkflowEngine.WorkflowException(
        'Workflow instance is not in Failed status. Current status: ' +
        instance.Status__c
      );
    }
    return instance;
  }

  /**
   * @description Deserializes the compensation stack (empty when blank). Unlike
   * the reclaim path this intentionally lets malformed JSON surface, matching the
   * original retry semantics.
   * @param instance the instance whose compensation stack is parsed
   * @return the compensation stack, or an empty list when blank
   */
  private static List<String> parseCompensationStack(
    Workflow_Instance__c instance
  ) {
    if (String.isBlank(instance.Compensation_Stack__c)) {
      return new List<String>();
    }
    return (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
  }

  /**
   * @description Resolves the target step names to reset for the retry: the top
   * of the compensation stack when compensating, otherwise the current (possibly
   * comma-separated parallel) step, falling back to the definition's initial step.
   * @param instance the instance being retried
   * @param stack the parsed compensation stack
   * @param hasCompensations true when the stack is non-empty
   * @return the target step names to reset and drive
   */
  private static List<String> resolveRetryTargetSteps(
    Workflow_Instance__c instance,
    List<String> stack,
    Boolean hasCompensations
  ) {
    List<String> targetStepNames = new List<String>();
    if (hasCompensations) {
      targetStepNames.add(stack[stack.size() - 1] + '_Compensate');
    } else if (String.isNotBlank(instance.Current_Step__c)) {
      if (instance.Current_Step__c.contains(',')) {
        for (String pStep : instance.Current_Step__c.split(',')) {
          targetStepNames.add(pStep.trim());
        }
      } else {
        targetStepNames.add(instance.Current_Step__c);
      }
    }
    applyRetryInitialStepFallback(instance, targetStepNames, hasCompensations);
    return targetStepNames;
  }

  /**
   * @description When a Failed instance has no current step and no compensations,
   * resolves the workflow's initial step so retry has a concrete step to drive.
   * Mutates `instance.Current_Step__c` and appends to `targetStepNames` in place.
   * @param instance the instance being retried
   * @param targetStepNames accumulator appended with the resolved initial step
   * @param hasCompensations true when the instance carries pending compensations
   */
  private static void applyRetryInitialStepFallback(
    Workflow_Instance__c instance,
    List<String> targetStepNames,
    Boolean hasCompensations
  ) {
    if (!(String.isBlank(instance.Current_Step__c) && !hasCompensations)) {
      return;
    }
    Type wflowType = WorkflowTypeResolver.resolve(
      instance.Workflow_Name__c,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    if (wflowType == null) {
      return;
    }
    Object defObj = wflowType.newInstance();
    if (defObj instanceof WorkflowDefinition) {
      instance.Current_Step__c = ((WorkflowDefinition) defObj).getInitialStep();
      targetStepNames.add(instance.Current_Step__c);
    }
  }

  /**
   * @description Bulk-loads the latest execution per target step and resets the
   * resettable ones (not `Completed`/`OperatorSkipped`) to `Pending`, clearing
   * their retry counters and error details.
   * @param instanceId Id of the instance being retried
   * @param targetStepNames the target step names to reset
   * @return the latest step execution per target step name
   */
  private static Map<String, Workflow_Step_Execution__c> resetRetryTargetSteps(
    Id instanceId,
    List<String> targetStepNames
  ) {
    Map<String, Workflow_Step_Execution__c> latestStepByName = new Map<String, Workflow_Step_Execution__c>();
    if (!targetStepNames.isEmpty()) {
      for (Workflow_Step_Execution__c se : [
        SELECT Id, Step_Name__c, Status__c, Retry_Count__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c IN :targetStepNames
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
      ]) {
        if (!latestStepByName.containsKey(se.Step_Name__c)) {
          latestStepByName.put(se.Step_Name__c, se);
        }
      }
    }

    List<Workflow_Step_Execution__c> stepsToReset = new List<Workflow_Step_Execution__c>();
    for (String targetStepName : targetStepNames) {
      Workflow_Step_Execution__c stepExec = latestStepByName.get(
        targetStepName
      );
      if (
        stepExec != null &&
        stepExec.Status__c != 'Completed' &&
        stepExec.Status__c != 'OperatorSkipped'
      ) {
        stepExec.Status__c = 'Pending';
        stepExec.Retry_Count__c = 0; // reset retry counter
        stepExec.Error_Details__c = null;
        stepsToReset.add(stepExec);
      }
    }
    if (!stepsToReset.isEmpty()) {
      Database.update(stepsToReset, true, AccessLevel.SYSTEM_MODE);
    }
    return latestStepByName;
  }

  /**
   * @description Parallel forward execution retry: enqueue only incomplete
   * branches. Reuses the already-loaded step map (reset steps are now `Pending`
   * in memory) instead of re-querying once per branch. The per-branch enqueue is
   * delegated to `enqueueParallelBranchRetryOne` so it is not lexically inside
   * this loop.
   * @param instanceId Id of the instance being retried
   * @param targetStepNames the parallel branch step names to consider
   * @param latestStepByName the latest step execution per target step name
   */
  private static void enqueueParallelBranchRetries(
    Id instanceId,
    List<String> targetStepNames,
    Map<String, Workflow_Step_Execution__c> latestStepByName
  ) {
    for (String targetStepName : targetStepNames) {
      Workflow_Step_Execution__c stepExec = latestStepByName.get(
        targetStepName
      );
      Boolean incomplete =
        stepExec == null ||
        (stepExec.Status__c != 'Completed' &&
        stepExec.Status__c != 'OperatorSkipped');
      if (!incomplete) {
        continue;
      }
      enqueueParallelBranchRetryOne(instanceId, targetStepName);
    }
  }

  /**
   * @description Enqueues a single parallel-branch retry, direct-enqueue under
   * test and via the standard `enqueueOrchestrator` path otherwise. Kept as a
   * helper so the test-only per-branch `System.enqueueJob` is not lexically
   * inside `enqueueParallelBranchRetries`'s loop. Test-only enqueue continues
   * to honor `disableQueueableInTest`.
   * @param instanceId the parent workflow instance to resume
   * @param targetStepName the target branch step name to drive
   */
  private static void enqueueParallelBranchRetryOne(
    Id instanceId,
    String targetStepName
  ) {
    if (!Test.isRunningTest()) {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(
        instanceId,
        targetStepName
      );
      return;
    }
    if (!WorkflowEngine.disableQueueableInTest) {
      System.enqueueJob(new WorkflowOrchestrator(instanceId, targetStepName));
    }
  }
}
