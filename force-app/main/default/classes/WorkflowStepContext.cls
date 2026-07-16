/**
 * @description StepContext hydration for the durable step-execution sequence.
 * Builds the `StepContext` a step executes against: chooses the claiming or
 * non-claiming signal source, strips the engine-internal `$timeoutResume` /
 * `$timeoutStep` markers, and resolves the captured-values map and effective
 * retry/attempt state. All DML and SOQL run in system mode.
 */
public inherited sharing class WorkflowStepContext {
  private class CaptureContext {
    Map<String, Object> capturesMap = new Map<String, Object>();
    Integer maxAttempts = 1;
  }

  /**
   * @description Hydrates the StepContext for this execution, stripping
   * engine-internal markers and resolving captures/retry state.
   * @param ctx the run context carrying the locked instance and step-execution
   * @param stepInstance the step being executed
   * @param prevOutput the previous step's output to feed the context
   * @return the fully-built StepContext for the step to run against
   */
  public static StepContext buildStepContext(
    WorkflowStepRunner.RunStepContext ctx,
    WorkflowStep stepInstance,
    String prevOutput
  ) {
    Workflow_Instance__c instance = ctx.instance;
    Workflow_Step_Execution__c stepExec = ctx.stepExec;

    StepContext.SignalSource signalSrc = resolveSignalSource(ctx, stepInstance);

    // Detect and strip the $timeoutResume marker (issue #35): the watchdog sets it
    // in Input__c of the fallback exec to durably signal the timeout-triggered
    // path. Strip it before passing inputJson to the context so the author step
    // never sees the engine-internal key.
    String resolvedInput = WorkflowPayloadOffload.resolvePayload(
      stepExec.Input__c
    );
    Boolean isTimeoutResume =
      String.isNotBlank(resolvedInput) &&
      resolvedInput.contains('$timeoutResume') &&
      'true'
        .equalsIgnoreCase(
          WorkflowPayloadOffload.readJsonMapKey(resolvedInput, '$timeoutResume')
        );
    if (isTimeoutResume) {
      resolvedInput = stripJsonMapKey(resolvedInput, '$timeoutResume');
      // Persist the cleaned input back to the locked record so the engine marker
      // does not linger in the durable audit row (saved with the exec below).
      stepExec.Input__c = resolvedInput;
    }

    Integer attempt = stepExec.Retry_Count__c != null
      ? (Integer) stepExec.Retry_Count__c + 1
      : 1;
    CaptureContext cc = resolveCaptureContext(stepInstance, stepExec);

    StepContext.Builder contextBuilder = new StepContext.Builder()
      .instanceId(ctx.instanceId)
      .workflowName(instance.Workflow_Name__c)
      .stepName(ctx.activeStepName)
      .inputJson(resolvedInput)
      .previousStepOutput(WorkflowPayloadOffload.resolvePayload(prevOutput))
      .stepStateJson(resolveStepStateJson(stepExec))
      .workflowInputJson(
        WorkflowPayloadOffload.resolvePayload(instance.Input__c)
      )
      .workflowVersion(resolveWorkflowVersion(instance))
      .stepVisit(ctx.stepVisit)
      .signalSource(signalSrc)
      .previousRunAt(instance.Previous_Run_At__c)
      .capturedValuesMap(cc.capturesMap)
      .attempt(attempt)
      .maxAttempts(cc.maxAttempts);
    if (isTimeoutResume) {
      contextBuilder.markTimeoutResume();
    }
    return contextBuilder.build();
  }

  // Choose the signal source: a parallel branch claims signals at read time
  // (Received -> Processing) so siblings cannot double-process them. That claim is
  // uncommitted DML, which would make a payload-driven callout illegal, so a
  // CalloutStep opts out of claiming and reads at-least-once instead.
  private static StepContext.SignalSource resolveSignalSource(
    WorkflowStepRunner.RunStepContext ctx,
    WorkflowStep stepInstance
  ) {
    Boolean isParallelBranchStep =
      String.isNotBlank(ctx.stepName) &&
      String.isNotBlank(ctx.instance.Current_Step__c) &&
      ctx.instance.Current_Step__c.contains(',');
    Boolean claimSignals =
      isParallelBranchStep && !(stepInstance instanceof CalloutStep);
    return claimSignals
      ? (StepContext.SignalSource) new WorkflowSignalSources.ParallelBranchSignalSource(
          ctx.instanceId
        )
      : (StepContext.SignalSource) new WorkflowSignalSources.PendingSignalSource(
          ctx.instanceId
        );
  }

  // Strip the engine-internal $timeoutStep marker from the state JSON a timed wait
  // persisted in Output__c, so a signal-win resume that re-runs the wait step does
  // not surface the reserved key to the author via stepStateJson.
  private static String resolveStepStateJson(
    Workflow_Step_Execution__c stepExec
  ) {
    String resolvedState = WorkflowPayloadOffload.resolvePayload(
      stepExec.Output__c
    );
    if (
      String.isNotBlank(resolvedState) && resolvedState.contains('$timeoutStep')
    ) {
      resolvedState = stripJsonMapKey(resolvedState, '$timeoutStep');
    }
    return resolvedState;
  }

  // The instance's definition version, defaulting to 1.
  private static Integer resolveWorkflowVersion(Workflow_Instance__c instance) {
    return instance.Definition_Version__c != null
      ? (Integer) instance.Definition_Version__c
      : 1;
  }

  // Resolve the captured-values map and the effective max attempts (from a
  // RetryConfigurable policy, or a persisted __maxAttempts, defaulting to 1).
  private static CaptureContext resolveCaptureContext(
    WorkflowStep stepInstance,
    Workflow_Step_Execution__c stepExec
  ) {
    CaptureContext cc = new CaptureContext();
    if (stepInstance instanceof RetryConfigurable) {
      RetryPolicy policy = WorkflowEngine.sanitizePolicy(
        ((RetryConfigurable) stepInstance).getRetryPolicy()
      );
      cc.maxAttempts = policy.maximumAttempts;
    }
    applyCapturedValues(cc, stepInstance, stepExec);
    return cc;
  }

  /**
   * @description Merges the step's persisted captured-values map into the capture
   * context and, for a non-RetryConfigurable step, adopts a persisted
   * __maxAttempts override.
   * @param cc the capture context to populate
   * @param stepInstance the step being executed
   * @param stepExec the step execution row carrying Captured_Values__c
   */
  private static void applyCapturedValues(
    CaptureContext cc,
    WorkflowStep stepInstance,
    Workflow_Step_Execution__c stepExec
  ) {
    if (String.isBlank(stepExec.Captured_Values__c)) {
      return;
    }
    String resolvedCaptures = WorkflowPayloadOffload.resolvePayload(
      stepExec.Captured_Values__c
    );
    if (String.isBlank(resolvedCaptures)) {
      return;
    }
    try {
      cc.capturesMap = (Map<String, Object>) JSON.deserializeUntyped(
        resolvedCaptures
      );
      if (
        !(stepInstance instanceof RetryConfigurable) &&
        cc.capturesMap.containsKey('__maxAttempts')
      ) {
        cc.maxAttempts = Integer.valueOf(cc.capturesMap.get('__maxAttempts'));
      }
    } catch (Exception ignored) {
      // Malformed captured values; retain the default maxAttempts.
    }
  }

  // Removes a reserved $-key from a JSON-object string, returning the cleaned
  // JSON (null when the map is empty after removal). Returns the original string
  // for blank/missing-key input, non-object JSON, and parse failures.
  private static String stripJsonMapKey(String jsonText, String key) {
    if (String.isBlank(jsonText) || !jsonText.contains(key)) {
      return jsonText;
    }
    try {
      Object parsed = JSON.deserializeUntyped(jsonText);
      if (!(parsed instanceof Map<String, Object>)) {
        return jsonText;
      }
      Map<String, Object> m = (Map<String, Object>) parsed;
      m.remove(key);
      return m.isEmpty() ? null : JSON.serialize(m);
    } catch (Exception e) {
      return jsonText;
    }
  }
}
