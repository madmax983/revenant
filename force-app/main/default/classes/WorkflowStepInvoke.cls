/**
 * @description Execute phase of the durable step-execution sequence: the final
 * step of the runStep orchestration. Resolves and instantiates the `WorkflowStep`,
 * asks `WorkflowStepContext` to hydrate the step's `StepContext`, executes the
 * step under its timeout bookkeeping (honoring test fault injection), and hands
 * the resulting `StepResult` to `WorkflowStepOutcome.handleStepResult`. All DML
 * and SOQL run in system mode.
 */
public inherited sharing class WorkflowStepInvoke {
  /**
   * @description §5/§6. Invoke the step (with fault injection and timeout
   * bookkeeping) and route its outcome through handleStepResult.
   * @param ctx the run context carrying the locked instance and step-execution
   * @param prevOutput the previous step's output to feed the step context
   */
  public static void invokeStepAndHandleOutcome(
    WorkflowStepRunner.RunStepContext ctx,
    String prevOutput
  ) {
    WorkflowStep stepInstance = resolveStepInstance(
      ctx.instance,
      ctx.activeStepName
    );

    // Circuit-breaker admission (issue #128): when the step is CircuitBreakerGuarded
    // and its dependency's breaker is Open, fast-fail by parking instead of executing.
    // The unguarded hot path short-circuits with 0 SOQL / 0 DML (see parkedByBreaker).
    if (parkedByBreaker(ctx, stepInstance)) {
      return;
    }

    StepContext context = WorkflowStepContext.buildStepContext(
      ctx,
      stepInstance,
      prevOutput
    );
    StepResult result = executeStepWithTimeout(ctx, stepInstance, context);

    // 6. Handle Step Outcome
    WorkflowEngine.StepOutcomeContext outcome = new WorkflowEngine.StepOutcomeContext();
    outcome.instance = ctx.instance;
    outcome.stepExec = ctx.stepExec;
    outcome.result = result;
    outcome.context = context;
    WorkflowStepOutcome.handleStepResult(outcome);
  }

  // Circuit-breaker admission gate (issue #128): parks the delivery (returns true)
  // when the step is CircuitBreakerGuarded, its dependency is configured, and the
  // breaker denies admission. The `instanceof` guard short-circuits the entire gate
  // for an unguarded step, so the hot path — and every unguarded step in a mixed
  // batch — incurs 0 SOQL / 0 DML. The already-resolved stepInstance is reused (the
  // step is never resolved twice). Flattened with early returns to avoid deep nesting.
  private static Boolean parkedByBreaker(
    WorkflowStepRunner.RunStepContext ctx,
    WorkflowStep stepInstance
  ) {
    if (!(stepInstance instanceof CircuitBreakerGuarded)) {
      return false;
    }
    String depKey = ((CircuitBreakerGuarded) stepInstance).dependencyKey();
    if (String.isBlank(depKey) || !CircuitBreakerGate.isConfigured(depKey)) {
      return false;
    }
    if (CircuitBreakerGate.tryAdmit(depKey).admitted) {
      return false;
    }
    CircuitBreakerPark.parkForCircuitBreaker(
      ctx.instance,
      ctx.activeStepName,
      depKey
    );
    return true;
  }

  // Resolve and instantiate the WorkflowStep for the active step.
  private static WorkflowStep resolveStepInstance(
    Workflow_Instance__c instance,
    String activeStepName
  ) {
    Type stepType = WorkflowTypeResolver.resolve(
      activeStepName,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    if (stepType == null) {
      throw new WorkflowEngine.WorkflowException(
        'Could not resolve class for step: ' + activeStepName
      );
    }
    return (WorkflowStep) stepType.newInstance();
  }

  // Set the pre-exec Running status and Timeout_At__c (deferring the DML write for
  // a CalloutStep), returning the resolved timeout seconds for the finally block.
  private static Integer applyPreExecTimeout(
    Workflow_Step_Execution__c stepExec,
    WorkflowStep stepInstance
  ) {
    // A CalloutStep performs a synchronous, payload-driven HTTP callout inside
    // execute(), and Salesforce forbids a callout once the transaction holds
    // pending DML, so defer this timeout-bookkeeping write past execute() for one.
    // The step's Timeout_At__c and scheduled timeout job were already committed
    // when it was queued, so the watchdog stays armed across the callout; the
    // finally block reconciles the timeout once execute() returns.
    Boolean deferPreExecDml = stepInstance instanceof CalloutStep;
    stepExec.Status__c = 'Running';
    Integer timeoutSeconds = null;
    if (stepInstance instanceof TimeoutConfigurable) {
      timeoutSeconds = ((TimeoutConfigurable) stepInstance).getTimeoutSeconds();
    }
    if (timeoutSeconds != null && timeoutSeconds > 0) {
      stepExec.Timeout_At__c = DateTime.now().addSeconds(timeoutSeconds);
      if (!deferPreExecDml) {
        WorkflowStepExecStore.saveStepExec(stepExec);
      }
    } else {
      stepExec.Timeout_At__c = null;
      if (stepExec.Id == null && !deferPreExecDml) {
        WorkflowStepExecStore.saveStepExec(stepExec);
      }
    }
    return timeoutSeconds;
  }

  // Execute the step (honoring test fault injection) and reconcile its timeout in
  // a finally block.
  private static StepResult executeStepWithTimeout(
    WorkflowStepRunner.RunStepContext ctx,
    WorkflowStep stepInstance,
    StepContext context
  ) {
    Workflow_Step_Execution__c stepExec = ctx.stepExec;
    Integer timeoutSeconds = applyPreExecTimeout(stepExec, stepInstance);

    StepResult result;
    try {
      if (Test.isRunningTest() && WorkflowFaultInjection.hasArmedFaults()) {
        result = WorkflowFaultInjection.checkAndInjectFault(
          ctx.instanceId,
          ctx.activeStepName,
          stepInstance
        );
      }
      if (result == null) {
        result = stepInstance.execute(context);
      }
    } finally {
      if (timeoutSeconds != null && timeoutSeconds > 0) {
        stepExec.Timeout_At__c = null;
        WorkflowStepExecStore.saveStepExec(stepExec);
        WorkflowTimeoutScheduler.cancelTimeoutJob(
          ctx.instanceId,
          ctx.activeStepName
        );
      }
    }
    return result;
  }
}
