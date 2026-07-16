/**
 * @description Runs the compensation step's `compensate()` under the deferred-DML
 * ordering: commits the re-asserted status and timeout for an ordinary step
 * before the call, but LEAVES them uncommitted for a `CalloutStep` so its
 * payload-driven callout stays legal (the outcome handler writes them after).
 * Honors test fault injection and reconciles the timeout in a finally block. All
 * DML and SOQL run in system mode.
 */
public inherited sharing class WorkflowCompensationInvoke {
  /**
   * @description Commits the pre-execution step status/timeout so the watchdog can
   * detect timeouts. Deferred for a `CalloutStep` so its payload-driven callout is
   * legal (the outcome handler writes the instance afterward). Public so the
   * runner's drive can commit the re-asserted state before invoking compensate().
   * @param run the compensation run accumulator whose pre-exec state is committed
   * @param compensatableStepInstance the step whose CalloutStep/TimeoutConfigurable
   * traits decide the deferral and timeout
   */
  public static void commitPreCompensationState(
    WorkflowCompensationRunner.CompensationRun run,
    CompensatableStep compensatableStepInstance
  ) {
    Workflow_Instance__c instance = run.instance;
    Workflow_Step_Execution__c stepExec = run.stepExec;
    // Save/Commit step execution status and set Timeout_At__c before executing compensation so watchdog can detect timeouts.
    // As in the forward execute() path, a CalloutStep performs a synchronous,
    // payload-driven callout inside compensate() and Salesforce forbids a
    // callout once the transaction holds pending DML, so defer this timeout
    // write past compensate() for a CalloutStep. The step's Timeout_At__c and
    // scheduled job were already committed when it was queued, so the watchdog
    // stays armed; the finally block reconciles the timeout afterward.
    Boolean deferPreExecDml = compensatableStepInstance instanceof CalloutStep;
    run.deferPreExecDml = deferPreExecDml;
    // Persist the compensating status that runStep re-asserted in memory. For an
    // ordinary step commit it now (matching the prior commit-before-compensate()
    // behavior); for a CalloutStep leave it uncommitted so the payload-driven
    // callout in compensate() below stays legal -- handleCompensationStepResult
    // writes the instance after compensate() returns. The earlier early-return
    // branches (already-terminal exec, non-CompensatableStep) commit the status
    // via their own update, so a pending re-assert is never dropped.
    if (run.reassertedStatus != null && !deferPreExecDml) {
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    }
    stepExec.Status__c = 'Running';
    Integer timeoutSeconds = null;
    if (compensatableStepInstance instanceof TimeoutConfigurable) {
      timeoutSeconds = ((TimeoutConfigurable) compensatableStepInstance)
        .getTimeoutSeconds();
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
    run.timeoutSeconds = timeoutSeconds;
  }

  /**
   * @description Executes compensate() (honoring test fault injection), reconciling
   * the timeout in the finally block. Returns false when the step failed and the
   * failure was already handled; otherwise stores the result on the run. Public so
   * the runner's drive can invoke compensate() as part of the exactly-once sequence.
   * @param run the compensation run accumulator that receives the step result
   * @param compensatableStepInstance the step whose compensate() is executed
   * @param context the `StepContext` passed to compensate()
   * @return true when the result was captured; false when the failure was already
   * handled and the caller must stop
   */
  public static Boolean invokeCompensation(
    WorkflowCompensationRunner.CompensationRun run,
    CompensatableStep compensatableStepInstance,
    StepContext context
  ) {
    Workflow_Instance__c instance = run.instance;
    Workflow_Step_Execution__c stepExec = run.stepExec;
    String compensationStepLogName = run.compensationStepLogName;
    Integer timeoutSeconds = run.timeoutSeconds;
    StepResult result;
    try {
      result = resolveInjectedCompensationFault(run, compensatableStepInstance);
      if (result == null) {
        result = compensatableStepInstance.compensate(context);
      }
    } catch (Exception ex) {
      WorkflowEngine.StepOutcomeContext crashOutcome = new WorkflowEngine.StepOutcomeContext();
      crashOutcome.instance = instance;
      crashOutcome.stepExec = stepExec;
      crashOutcome.context = context;
      WorkflowBreadcrumbs.persistStepBreadcrumbs(crashOutcome);
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c =
        ex.getMessage() +
        '\n' +
        ex.getStackTraceString();
      WorkflowEngine.saveStepExec(stepExec);
      WorkflowEngine.failWorkflowInstance(
        instance.Id,
        compensationStepLogName,
        ex.getMessage()
      );
      return false;
    } finally {
      if (timeoutSeconds != null && timeoutSeconds > 0) {
        stepExec.Timeout_At__c = null;
        WorkflowEngine.saveStepExec(stepExec);
        WorkflowTimeoutScheduler.cancelTimeoutJob(
          instance.Id,
          compensationStepLogName
        );
      }
    }
    run.result = result;
    return true;
  }

  // Return an injected fault result for the compensation when test fault
  // injection is armed for this step; otherwise null (run compensate normally).
  private static StepResult resolveInjectedCompensationFault(
    WorkflowCompensationRunner.CompensationRun run,
    CompensatableStep compensatableStepInstance
  ) {
    if (!(Test.isRunningTest() && WorkflowFaultInjection.hasArmedFaults())) {
      return null;
    }
    Workflow_Instance__c instance = run.instance;
    String compensationStepLogName = run.compensationStepLogName;
    Id rootId = WorkflowFaultInjection.getRootInstanceId(instance.Id);
    String compKey =
      (rootId != null ? String.valueOf(rootId) : '') +
      ':' +
      compensationStepLogName.toLowerCase();
    if (WorkflowFaultInjection.hasFaultForKey(compKey)) {
      return WorkflowFaultInjection.checkAndInjectFault(
        instance.Id,
        compensationStepLogName,
        compensatableStepInstance
      );
    }
    return WorkflowFaultInjection.checkAndInjectFault(
      instance.Id,
      run.activeStepName,
      compensatableStepInstance
    );
  }
}
