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
        WorkflowEngine.saveStepExec(stepExec);
      }
    } else {
      stepExec.Timeout_At__c = null;
      if (stepExec.Id == null && !deferPreExecDml) {
        WorkflowEngine.saveStepExec(stepExec);
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
        WorkflowEngine.saveStepExec(stepExec);
        WorkflowTimeoutScheduler.cancelTimeoutJob(
          ctx.instanceId,
          ctx.activeStepName
        );
      }
    }
    return result;
  }
}
