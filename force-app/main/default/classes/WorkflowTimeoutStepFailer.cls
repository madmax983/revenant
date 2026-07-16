/**
 * @description Per-step failure decision logic for the timeout→fail sweep (§1).
 * For a single timed-out step it enforces the operator pause gate, routes
 * error-routing workflows to their configured error step, and otherwise fails
 * the step and applies the parent-instance transition (recoverable
 * rollback-incomplete, terminal Failed, or start compensation) into the shared
 * WorkflowTimeoutSweep.TimedOutStepContext accumulator.
 *
 * Extracted from WorkflowEngine as part of the watchdog decomposition; driven by
 * WorkflowTimeoutSweep. All DML and SOQL run in system mode so the engine can
 * drive workflows regardless of the invoking user's object permissions.
 */
public inherited sharing class WorkflowTimeoutStepFailer {
  /**
   * @description Process a single timed-out step: enforce the pause gate, route
   * to an error step if configured, otherwise mark the step Failed and
   * transition the parent.
   * @param step the timed-out step exec to finalize
   * @param ctx the shared timed-out-steps accumulator
   */
  public static void finalizeTimedOutStep(
    Workflow_Step_Execution__c step,
    WorkflowTimeoutSweep.TimedOutStepContext ctx
  ) {
    Workflow_Instance__c parent = ctx.parents.get(step.Workflow_Instance__c);
    if (parent == null) {
      return;
    }
    if (!WorkflowTimeoutSupport.isTimedOutParentActionable(parent)) {
      return;
    }

    Workflow_Step_Execution__c lockedStep = ctx.lockedSteps.get(step.Id);
    if (lockedStep == null) {
      return;
    }
    if (!WorkflowTimeoutSupport.isRunnableStepStatus(lockedStep)) {
      return;
    }

    if (holdPausedPendingStep(parent, lockedStep, ctx)) {
      return;
    }

    String errorMsg = (lockedStep.Status__c == 'Running')
      ? 'Step execution timed out.'
      : 'Step execution timed out before starting.';

    String errorStepName = resolveTimeoutErrorRouting(step, errorMsg, ctx);

    if (String.isNotBlank(errorStepName)) {
      routeTimedOutStepFailure(step, errorMsg, ctx);
      return;
    }

    lockedStep.Status__c = 'Failed';
    lockedStep.Error_Details__c = errorMsg;
    lockedStep.Timeout_At__c = null;
    ctx.stepsToUpdate.add(lockedStep);

    if (!ctx.instancesToUpdate.containsKey(parent.Id)) {
      applyTimedOutInstanceTransition(step, errorMsg, ctx);
    }
  }

  // Operator pause gate (mirrors WorkflowTimeoutJob): if the definition is
  // paused while the parent is still Pending/Running (handoff armed the deadline
  // before the delayed RUN_STEP reached the gate), only hold pre-start Pending
  // steps — clear their deadline so a post-resume heartbeat cannot fire
  // instantly; re-armed on park/re-run. Running (stuck) steps are NOT held: the
  // instance stays Running so reArmTimeoutsForResume will not re-arm them on
  // resume; clearing their deadline here would leave them permanently
  // unenforceable. Compensating/Cancelling bypass the pause gate normally.
  // Returns true when the step was held (and the caller must skip it).
  private static Boolean holdPausedPendingStep(
    Workflow_Instance__c parent,
    Workflow_Step_Execution__c lockedStep,
    WorkflowTimeoutSweep.TimedOutStepContext ctx
  ) {
    if (
      (parent.Status__c == 'Pending' ||
      parent.Status__c == 'Running') &&
      WorkflowPauseGate.anyPaused() &&
      WorkflowPauseGate.isDefinitionPaused(parent.Workflow_Name__c)
    ) {
      if (lockedStep.Status__c == 'Pending') {
        lockedStep.Timeout_At__c = null;
        ctx.stepsToUpdate.add(lockedStep);
        return true;
      }
      // Running step — fall through to enforce the timeout normally
    }
    return false;
  }

  // Check if error routing is defined for this timed-out step; returns the error
  // step name to route to, or null/blank when no routing applies.
  private static String resolveTimeoutErrorRouting(
    Workflow_Step_Execution__c step,
    String errorMsg,
    WorkflowTimeoutSweep.TimedOutStepContext ctx
  ) {
    Workflow_Instance__c parent = ctx.parents.get(step.Workflow_Instance__c);
    if (
      !(ctx.isRoutingWflow.containsKey(parent.Workflow_Name__c) &&
      ctx.isRoutingWflow.get(parent.Workflow_Name__c))
    ) {
      return null;
    }
    Type wflowType = WorkflowTypeResolver.resolve(
      parent.Workflow_Name__c,
      WorkflowTypeResolver.extractNamespace(parent.Workflow_Name__c)
    );
    if (wflowType == null) {
      return null;
    }
    WorkflowDefinition def = (WorkflowDefinition) wflowType.newInstance();
    String key = parent.Id + ':' + step.Step_Name__c;
    Integer attemptCount =
      (ctx.latestRetryCounts.containsKey(key)
        ? ctx.latestRetryCounts.get(key)
        : 0) + 1;
    StepError err = new StepError(step.Step_Name__c, errorMsg, attemptCount);
    return ((ErrorRoutingWorkflow) def).getErrorStep(step.Step_Name__c, err);
  }

  // A routed timed-out step: mark it Failed immediately and fail the instance
  // through the resolved-error path.
  private static void routeTimedOutStepFailure(
    Workflow_Step_Execution__c step,
    String errorMsg,
    WorkflowTimeoutSweep.TimedOutStepContext ctx
  ) {
    Workflow_Instance__c parent = ctx.parents.get(step.Workflow_Instance__c);
    Workflow_Step_Execution__c lockedStep = ctx.lockedSteps.get(step.Id);

    lockedStep.Status__c = 'Failed';
    lockedStep.Error_Details__c = errorMsg;
    lockedStep.Timeout_At__c = null;
    Database.update(lockedStep, true, AccessLevel.SYSTEM_MODE);

    String key = parent.Id + ':' + step.Step_Name__c;
    Integer attemptCount =
      (ctx.latestRetryCounts.containsKey(key)
        ? ctx.latestRetryCounts.get(key)
        : 0) + 1;

    WorkflowEngine.FailInstanceRequest timeoutFailReq = new WorkflowEngine.FailInstanceRequest();
    timeoutFailReq.instance = parent;
    timeoutFailReq.stepName = step.Step_Name__c;
    timeoutFailReq.errorMessage = errorMsg;
    timeoutFailReq.failureCategory = WorkflowEngine.CAT_TIMEOUT;
    timeoutFailReq.attemptCount = attemptCount;
    WorkflowFailureService.failResolvedInstance(timeoutFailReq);
  }

  // Transition the (not-yet-transitioned) parent instance for a timed-out step:
  // recoverable rollback-incomplete, terminal Failed, or start compensation.
  private static void applyTimedOutInstanceTransition(
    Workflow_Step_Execution__c step,
    String errorMsg,
    WorkflowTimeoutSweep.TimedOutStepContext ctx
  ) {
    Workflow_Instance__c parent = ctx.parents.get(step.Workflow_Instance__c);

    // Check if there are compensations to run
    Boolean hasCompensations = false;
    List<String> stack = new List<String>();
    if (String.isNotBlank(parent.Compensation_Stack__c)) {
      stack = (List<String>) JSON.deserialize(
        parent.Compensation_Stack__c,
        List<String>.class
      );
      hasCompensations = !stack.isEmpty();
    }

    Boolean isCompensationFailure = (parent.Status__c == 'Compensating' ||
    parent.Status__c == 'Cancelling' ||
    (String.isNotBlank(step.Step_Name__c) &&
    step.Step_Name__c.endsWith('_Compensate')));

    if (isCompensationFailure && hasCompensations) {
      // A compensation step timed out mid-rollback. The remaining stack is
      // intact, so park the saga in the recoverable "rollback incomplete"
      // state rather than abandoning the deeper compensations.
      Boolean wasCancelling = (parent.Status__c == 'Cancelling');
      parent.Status__c = 'CompensationFailed';
      parent.Failure_Category__c = WorkflowEngine.CAT_COMPENSATION_FAILED;
      parent.Error_Message__c = buildRollbackIncompleteMessage(
        wasCancelling,
        'Rollback incomplete at compensation step ' +
          step.Step_Name__c +
          ': ' +
          errorMsg
      );
      // Clear any stale sleep/retry deadline so a later resumed SUSPEND/approval
      // gate is not prematurely woken by the watchdog.
      parent.Sleep_Until__c = null;
      parent.Async_Job_Id__c = null;
      ctx.instancesToUpdate.put(parent.Id, parent);
    } else if (!hasCompensations) {
      parent.Status__c = 'Failed';
      parent.Failure_Category__c = WorkflowEngine.CAT_TIMEOUT;
      parent.Error_Message__c =
        'Failed at step ' +
        step.Step_Name__c +
        ': ' +
        errorMsg;
      ctx.instancesToUpdate.put(parent.Id, parent);
    } else {
      parent.Status__c = 'Compensating';
      parent.Error_Message__c =
        'Failed at step ' +
        step.Step_Name__c +
        ': ' +
        errorMsg;
      ctx.instancesToUpdate.put(parent.Id, parent);

      ctx.instancesNeedingCompensationInfo.add(parent.Id);
      if (!stack.isEmpty()) {
        ctx.activeStepNamesForComp.add(stack[stack.size() - 1]);
      }
    }
  }

  // Builds the Error_Message for a stalled ("rollback incomplete") saga,
  // preserving the cancel-driven phase marker when applicable. Private, pure
  // duplicate of the resident WorkflowEngine helper so this sweep does not
  // depend on a public boolean-parameter method.
  private static String buildRollbackIncompleteMessage(
    Boolean wasCancelling,
    String detail
  ) {
    return (wasCancelling ? 'Cancelled by user. ' : '') + detail;
  }
}
