/**
 * @description Single-branch advancement and shared terminal/enqueue phase for
 * the operator "resume past step" intervention. Resolves the workflow definition,
 * dispatches to the single-branch or parallel advancement path, advances a
 * non-parallel branch to its next step (or completes the workflow), and owns the
 * shared "drive to Completed" and "enqueue next orchestrator" helpers used by
 * both the single-branch and parallel-join paths. All DML and SOQL run in system
 * mode. Split out of {@link WorkflowOperatorSkip} so each cohesive phase stays
 * within its own complexity budget; the parallel paths live on
 * {@link WorkflowOperatorSkipParallel} and
 * {@link WorkflowOperatorSkipParallelResume}.
 */
public inherited sharing class WorkflowOperatorSkipAdvance {
  /**
   * @description Resolve the workflow definition and dispatch to the
   * single-branch or parallel-branch advancement path.
   * @param run the resume-past-step accumulator
   */
  public static void advanceAfterSkip(WorkflowOperatorSkip.ResumeSkipRun run) {
    Workflow_Instance__c instance = run.instance;
    Type wflowType = WorkflowTypeResolver.resolve(
      instance.Workflow_Name__c,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    if (wflowType == null) {
      throw new WorkflowEngine.WorkflowException(
        'Could not resolve workflow definition class: ' +
        instance.Workflow_Name__c
      );
    }
    run.def = (WorkflowDefinition) wflowType.newInstance();

    Boolean isParallel =
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',');

    if (!isParallel) {
      advanceSingleBranchSkip(run);
    } else {
      WorkflowOperatorSkipParallel.advanceParallelSkip(run);
    }
  }

  /**
   * @description Advance a single (non-parallel) branch after an operator skip.
   * @param run the resume-past-step accumulator
   */
  private static void advanceSingleBranchSkip(
    WorkflowOperatorSkip.ResumeSkipRun run
  ) {
    Workflow_Instance__c instance = run.instance;
    String stepName = run.stepName;
    String suppliedOutputJson = run.suppliedOutputJson;

    StepResult mockResult = new StepResult();
    mockResult.directive().action = StepResult.ActionType.COMPLETE;
    mockResult.directive().nextStepName = 'SENTINEL_NEXT_STEP';
    mockResult.directive().outputJson = suppliedOutputJson;
    String nextStepName;
    if (run.def instanceof VersionedWorkflow) {
      nextStepName = ((VersionedWorkflow) run.def)
        .getNextStep(
          stepName,
          mockResult,
          instance.Definition_Version__c != null
            ? (Integer) instance.Definition_Version__c
            : 1
        );
    } else {
      nextStepName = run.def.getNextStep(stepName, mockResult);
    }

    if (nextStepName == 'SENTINEL_NEXT_STEP') {
      throw new WorkflowEngine.WorkflowException(
        'Skip is not supported for dynamic-next step definitions.'
      );
    }

    if (String.isBlank(nextStepName)) {
      // Workflow is completed
      markSkipInstanceCompleted(run, suppliedOutputJson, 'Output_Final');
      return;
    }

    // Advance to next step
    instance.Current_Step__c = nextStepName;
    instance.Status__c = 'Running';
    instance.Error_Message__c = null;
    instance.Failure_Category__c = null;
    Boolean deferTimeoutForConcurrency = ConcurrencyGate.isConfigured(
      instance.Workflow_Name__c
    );
    if (deferTimeoutForConcurrency) {
      instance.Concurrency_Parked__c = true;
    }
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    Workflow_Step_Execution__c nextStepExec = new Workflow_Step_Execution__c();
    nextStepExec.Workflow_Instance__c = instance.Id;
    nextStepExec.Step_Name__c = nextStepName;
    nextStepExec.Status__c = 'Pending';
    nextStepExec.Input__c = run.skipExec.Output__c;
    nextStepExec.Retry_Count__c = 0;
    Database.insert(nextStepExec, true, AccessLevel.SYSTEM_MODE);

    if (!deferTimeoutForConcurrency) {
      WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
    }
    enqueueSkipOrchestrator(instance.Id);
  }

  /**
   * @description Drive an instance to `Completed` terminal state after an
   * operator skip. Shared by the single-branch and parallel-join paths.
   * @param run the resume-past-step accumulator
   * @param outputJson the final/join output JSON
   * @param payloadName the payload document name for offload
   */
  public static void markSkipInstanceCompleted(
    WorkflowOperatorSkip.ResumeSkipRun run,
    String outputJson,
    String payloadName
  ) {
    Workflow_Instance__c instance = run.instance;
    instance.Status__c = 'Completed';
    instance.Terminal_At__c = DateTime.now();
    instance.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      run.instanceId,
      outputJson,
      payloadName
    );
    instance.Current_Step__c = null;
    instance.Error_Message__c = null;
    instance.Failure_Category__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    WorkflowParentNotifier.notifyParentCompletion(instance);
    WorkflowLifecyclePublisher.publish(instance);
  }

  /**
   * @description Enqueue the next orchestrator pass after a single/join skip
   * advancement. Shared by the single-branch and parallel-join paths.
   * @param instanceId Id of the instance to drive
   */
  public static void enqueueSkipOrchestrator(Id instanceId) {
    if (Test.isRunningTest() && WorkflowEngine.disableQueueableInTest) {
      System.enqueueJob(new WorkflowOrchestrator(instanceId));
    } else {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(instanceId, null);
    }
  }
}
