/**
 * @description Prepares the compensation invocation: resolves the current step's
 * `CompensatableStep` instance (auto-marking a non-compensatable step Compensated
 * and advancing the stack), builds its `StepContext`, and derives the attempt/
 * max-attempts and capture-once map from the locked step-execution and retry
 * policy. All DML and SOQL run in system mode.
 */
public inherited sharing class WorkflowCompensationContext {
  /**
   * @description Resolves the compensatable step instance. Returns null (after
   * auto-marking the step Compensated and advancing the stack) for
   * non-compensatable steps. Public so the runner's drive can obtain the step to
   * compensate.
   * @param run the compensation run accumulator for the current step
   * @return the resolved `CompensatableStep`, or null when the step was
   * auto-compensated (non-compensatable)
   */
  public static CompensatableStep resolveCompensatableStep(
    WorkflowCompensationRunner.CompensationRun run
  ) {
    Workflow_Instance__c instance = run.instance;
    Type stepType = WorkflowTypeResolver.resolve(
      run.activeStepName,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    if (stepType == null) {
      throw new WorkflowEngine.WorkflowException(
        'Could not resolve class for step compensation: ' + run.activeStepName
      );
    }

    Object stepInstanceObj = stepType.newInstance();
    if (!(stepInstanceObj instanceof CompensatableStep)) {
      Workflow_Step_Execution__c stepExec = run.stepExec;
      stepExec.Status__c = 'Compensated';
      WorkflowEngine.saveStepExec(stepExec);

      List<String> stack = run.stack;
      stack.remove(stack.size() - 1);
      instance.Compensation_Stack__c = JSON.serialize(stack);
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);

      if (!stack.isEmpty()) {
        WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
      }

      WorkflowCompensationRunner.enqueueCompensationOrchestrator(instance.Id);
      return null;
    }

    return (CompensatableStep) stepInstanceObj;
  }

  /**
   * @description Builds the `StepContext` for the compensate() invocation,
   * resolving the previous step output, retry state, and capture-once values.
   * Public so the runner's drive can construct the context it passes to
   * compensate().
   * @param run the compensation run accumulator for the current step
   * @param compensatableStepInstance the resolved step whose retry policy is read
   * @return the assembled `StepContext` for the compensate() call
   */
  public static StepContext buildCompensationContext(
    WorkflowCompensationRunner.CompensationRun run,
    CompensatableStep compensatableStepInstance
  ) {
    Workflow_Instance__c instance = run.instance;
    Workflow_Step_Execution__c stepExec = run.stepExec;

    String prevOutput = null;
    List<Workflow_Step_Execution__c> completedBefore = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :run.forwardSourceInstanceId
        AND Status__c IN ('Completed', 'OperatorSkipped')
        AND Step_Name__c != :run.activeStepName
        AND Step_Name__c != :run.compensationStepLogName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (!completedBefore.isEmpty()) {
      prevOutput = completedBefore[0].Output__c;
    }

    resolveCompensationRetryState(run, compensatableStepInstance);

    return new StepContext.Builder()
      .instanceId(instance.Id)
      .workflowName(instance.Workflow_Name__c)
      .stepName(run.compensationStepLogName)
      .inputJson(WorkflowPayloadOffload.resolvePayload(stepExec.Input__c))
      .previousStepOutput(WorkflowPayloadOffload.resolvePayload(prevOutput))
      .stepStateJson(WorkflowPayloadOffload.resolvePayload(stepExec.Output__c))
      .workflowInputJson(
        WorkflowPayloadOffload.resolvePayload(instance.Input__c)
      )
      .workflowVersion(
        instance.Definition_Version__c != null
          ? (Integer) instance.Definition_Version__c
          : 1
      )
      .stepVisit(run.compensateVisit)
      .signalSource(new WorkflowSignalSources.PendingSignalSource(instance.Id))
      .previousRunAt(instance.Previous_Run_At__c)
      .capturedValuesMap(run.capturesMap)
      .attempt(run.attempt)
      .maxAttempts(run.maxAttempts)
      .build();
  }

  // Derive attempt/maxAttempts and captured-values map for the compensation.
  private static void resolveCompensationRetryState(
    WorkflowCompensationRunner.CompensationRun run,
    CompensatableStep compensatableStepInstance
  ) {
    Workflow_Step_Execution__c stepExec = run.stepExec;
    run.attempt = stepExec.Retry_Count__c != null
      ? (Integer) stepExec.Retry_Count__c + 1
      : 1;
    Integer maxAttempts = 1;
    Map<String, Object> capturesMap = new Map<String, Object>();
    if (compensatableStepInstance instanceof RetryConfigurable) {
      RetryPolicy policy = WorkflowEngine.sanitizePolicy(
        ((RetryConfigurable) compensatableStepInstance).getRetryPolicy()
      );
      maxAttempts = policy.maximumAttempts;
    }
    if (String.isNotBlank(stepExec.Captured_Values__c)) {
      String resolvedCaptures = WorkflowPayloadOffload.resolvePayload(
        stepExec.Captured_Values__c
      );
      if (String.isNotBlank(resolvedCaptures)) {
        try {
          capturesMap = (Map<String, Object>) JSON.deserializeUntyped(
            resolvedCaptures
          );
          maxAttempts = resolveCapturedMaxAttempts(
            compensatableStepInstance,
            capturesMap,
            maxAttempts
          );
        } catch (Exception ignored) {
          // Malformed captured values; retain the default maxAttempts.
        }
      }
    }
    run.maxAttempts = maxAttempts;
    run.capturesMap = capturesMap;
  }

  // For a non-RetryConfigurable compensation step, honor a persisted
  // '__maxAttempts' captured value; otherwise keep the supplied default.
  private static Integer resolveCapturedMaxAttempts(
    CompensatableStep compensatableStepInstance,
    Map<String, Object> capturesMap,
    Integer defaultMaxAttempts
  ) {
    if (compensatableStepInstance instanceof RetryConfigurable) {
      return defaultMaxAttempts;
    }
    if (!capturesMap.containsKey('__maxAttempts')) {
      return defaultMaxAttempts;
    }
    return Integer.valueOf(capturesMap.get('__maxAttempts'));
  }
}
