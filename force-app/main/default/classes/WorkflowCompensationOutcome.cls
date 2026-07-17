/**
 * @description Dispatches the `StepResult` of a compensation drive: on COMPLETE it
 * pops the top of the LIFO stack (so a compensated step never re-runs) and, when
 * the stack drains, transitions the saga to Compensated/Cancelled; a YIELD/SUSPEND/
 * SLEEP/WAIT_FOR_APPROVAL suspends without popping so the step re-drives; a RETRY
 * reschedules or, once exhausted, parks the saga recoverable; an explicit FAIL or
 * unsupported action parks it recoverable ("rollback incomplete"), preserving the
 * remaining stack for operator resume. All DML and SOQL run in system mode.
 */
public inherited sharing class WorkflowCompensationOutcome {
  /**
   * Builds the Error_Message for a stalled ("rollback incomplete") saga, preserving
   * the cancel-driven phase marker when applicable. The resume paths (resumeCompensation,
   * the watchdog sleep-resume, and runStep) infer whether to resume as 'Cancelling'
   * vs 'Compensating' from the presence of 'Cancelled' in this text, so a cancel-driven
   * rollback must retain that marker across the stall — otherwise a cancelled saga would
   * resume as a plain compensation and wrongly terminate as 'Compensated' instead of
   * 'Cancelled'.
   * @param wasCancelling true when the stalled rollback was cancel-driven
   * @param detail the base stall detail message
   * @return the error message with the cancel-phase marker prepended when applicable
   */
  private static String buildRollbackIncompleteMessage(
    Boolean wasCancelling,
    String detail
  ) {
    return (wasCancelling ? 'Cancelled by user. ' : '') + detail;
  }

  /**
   * @description Dispatches the compensation step's `StepResult` to the matching
   * action handler after persisting breadcrumbs, re-locking the instance, and
   * saving reported progress and captures. Public so the runner's drive can hand
   * off the compensate() outcome for its LIFO pop-on-success and terminal
   * transitions.
   * @param outcome the step-outcome context bundling the instance, step-exec,
   * result, stack, and step context
   */
  public static void handleCompensationStepResult(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    WorkflowBreadcrumbs.persistStepBreadcrumbs(outcome);
    Workflow_Instance__c instance = loadFreshCompensationInstance(
      outcome.instance
    );
    persistCompensationProgressAndCaptures(outcome, instance);

    StepResult.ActionType action = outcome.result.directive().action;
    if (action == StepResult.ActionType.COMPLETE) {
      handleCompensationComplete(outcome, instance);
    } else if (action == StepResult.ActionType.YIELD) {
      handleCompensationYield(outcome, instance);
    } else if (action == StepResult.ActionType.SUSPEND) {
      handleCompensationSuspend(outcome, instance);
    } else if (action == StepResult.ActionType.SLEEP) {
      handleCompensationSleep(outcome, instance);
    } else if (action == StepResult.ActionType.WAIT_FOR_APPROVAL) {
      handleCompensationWaitForApproval(outcome, instance);
    } else if (action == StepResult.ActionType.RETRY) {
      handleCompensationRetry(outcome, instance);
    } else if (action == StepResult.ActionType.FAIL) {
      handleCompensationFail(outcome, instance);
    } else {
      handleCompensationUnsupported(outcome, instance);
    }
  }

  // Re-load the instance under FOR UPDATE and reject if a concurrent path
  // already terminated or cancelled it.
  private static Workflow_Instance__c loadFreshCompensationInstance(
    Workflow_Instance__c instance
  ) {
    Workflow_Instance__c freshInstance = [
      SELECT
        Id,
        Status__c,
        Progress__c,
        Current_Step__c,
        Compensation_Stack__c,
        Sleep_Until__c,
        Async_Job_Id__c,
        Failure_Category__c,
        Error_Message__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Input__c,
        Definition_Version__c,
        Previous_Run_At__c,
        CreatedDate
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (
      freshInstance.Status__c == 'Failed' ||
      freshInstance.Status__c == 'CompensationFailed' ||
      freshInstance.Status__c == 'Cancelled'
    ) {
      throw new WorkflowEngine.WorkflowException(
        'Workflow execution was terminated or cancelled.'
      );
    }
    return freshInstance;
  }

  private static void persistCompensationProgressAndCaptures(
    WorkflowEngine.StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepContext context = outcome.context;
    if (context != null && context.progress().isProgressReported()) {
      String progJson = context.progress().getProgressJson();
      instance.Progress__c = WorkflowPayloadOffload.savePayloadIfNeeded(
        instance.Id,
        progJson,
        'Progress_' +
        (stepExec != null && String.isNotBlank(stepExec.Step_Name__c)
          ? stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
          : 'Default')
      );
    }

    // Persist capture-once values produced during this compensation execution.
    if (context.captures().hasNewCaptures()) {
      String capturedJson = context.captures().getCapturedValuesJson();
      stepExec.Captured_Values__c = WorkflowPayloadOffload.savePayloadIfNeeded(
        instance.Id,
        capturedJson,
        'Captures_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
    }
  }

  // Shared recoverable rollback-failure transition used by the RETRY-exhausted,
  // explicit-FAIL, and unsupported-action branches. Captures wasCancelling from
  // the pre-mutation status, then parks the saga in CompensationFailed.
  private static void failCompensationRecoverable(
    Workflow_Instance__c instance,
    String detail
  ) {
    Boolean wasCancelling = (instance.Status__c == 'Cancelling');
    instance.Status__c = 'CompensationFailed';
    instance.Failure_Category__c = WorkflowEngine.CAT_COMPENSATION_FAILED;
    instance.Error_Message__c = buildRollbackIncompleteMessage(
        wasCancelling,
        detail
      )
      .left(255);
    // Clear any stale sleep/retry deadline so a resumed gate is not immediately
    // re-woken by the watchdog (Sleep_Until__c <= now).
    instance.Sleep_Until__c = null;
    instance.Async_Job_Id__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    WorkflowParentNotifier.notifyParentCompletion(instance);
    WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
    WorkflowLifecyclePublisher.publish(instance);
  }

  private static void handleCompensationComplete(
    WorkflowEngine.StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    List<String> stack = outcome.stack;
    StepContext context = outcome.context;
    stepExec.Status__c = 'Compensated';
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      result.directive().outputJson,
      'Output_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    WorkflowStepExecStore.saveStepExec(stepExec);

    // A compensating step that read signals durably completed; consume them on
    // the same contract as a forward step so a later compensation attempt or
    // step does not re-observe them. Compensation runs serially (LIFO) and
    // does not claim, so it consumes still-Received rows plus same-name cleanup.
    WorkflowSignalConsume.markSignalsConsumedSerial(instance.Id, context);

    // Effectively-once outbound emit from compensation (issue #64): a
    // CompensatableStep.compensate() that calls ctx.events().emit() or the
    // complete(..., events) overload publishes here, coupled to the durable
    // Compensated transition — the same commit-coupling as the forward path,
    // so the public emit API does not silently drop events in rollback flows.
    WorkflowStepOutcome.publishOutboundEvents(result, context);

    stack.remove(stack.size() - 1);
    instance.Compensation_Stack__c = JSON.serialize(stack);

    if (stack.isEmpty()) {
      instance.Status__c = (instance.Status__c == 'Cancelling')
        ? 'Cancelled'
        : 'Compensated';
      instance.Current_Step__c = null;
    }
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    if (stack.isEmpty()) {
      WorkflowParentNotifier.notifyParentCompletion(instance);
    } else {
      WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
    }

    WorkflowOrchestratorEnqueue.enqueueOrchestratorForInstance(instance.Id);

    // Fire-and-forget outbound lifecycle event; only fires once the stack is
    // drained and the instance has reached Compensated/Cancelled. Runs LAST so
    // the load-bearing orchestrator enqueue above keeps first claim on DML budget.
    WorkflowLifecyclePublisher.publish(instance);
  }

  private static void handleCompensationYield(
    WorkflowEngine.StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    stepExec.Status__c = 'Running';
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      result.directive().stepStateJson,
      'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    WorkflowStepExecStore.saveStepExec(stepExec);

    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
    WorkflowOrchestratorEnqueue.enqueueOrchestrator(instance.Id, null);
  }

  private static void handleCompensationSuspend(
    WorkflowEngine.StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    // Note: timed-wait timeout is not supported in compensation steps and is not armed here.
    stepExec.Status__c = 'Pending';
    stepExec.Output__c = String.isNotBlank(result.directive().stepStateJson)
      ? WorkflowPayloadOffload.savePayloadIfNeeded(
          instance.Id,
          result.directive().stepStateJson,
          'State_Suspend_' +
          stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
        )
      : null;
    WorkflowStepExecStore.saveStepExec(stepExec);
    instance.Status__c = 'Suspended';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
  }

  private static void handleCompensationSleep(
    WorkflowEngine.StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    stepExec.Status__c = 'Pending';
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      result.directive().stepStateJson,
      'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    WorkflowStepExecStore.saveStepExec(stepExec);
    instance.Status__c = 'Suspended';
    if (result.directive().sleepDurationSeconds != null) {
      instance.Sleep_Until__c = DateTime.now()
        .addSeconds(result.directive().sleepDurationSeconds);
      instance.Async_Job_Id__c = WorkflowRetrySleepScheduler.scheduleSleepResume(
        instance.Id,
        stepExec.Step_Name__c,
        result.directive().sleepDurationSeconds
      );
    }
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
  }

  private static void handleCompensationWaitForApproval(
    WorkflowEngine.StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    // Note: timed-wait timeout is not supported in compensation steps and is not armed here.
    stepExec.Status__c = 'Pending';
    Map<String, Object> state = new Map<String, Object>{
      'waitingForApproval' => true,
      'approvalKey' => result.directive().approvalKey,
      'approvalRole' => result.directive().approvalRole
    };
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      JSON.serialize(state),
      'State_Approval_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    WorkflowStepExecStore.saveStepExec(stepExec);
    instance.Status__c = 'Suspended';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
  }

  private static void handleCompensationRetry(
    WorkflowEngine.StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    stepExec.Retry_Count__c += 1;
    // Get and sanitize retry policy
    RetryPolicy policy = WorkflowRetryScheduling.sanitizePolicy(
      result.directive().retry.policy
    );

    WorkflowRetryScheduling.persistRetryMaxAttempts(instance, stepExec, policy);

    if (stepExec.Retry_Count__c >= policy.maximumAttempts) {
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c =
        'Compensation max retries (' +
        policy.maximumAttempts +
        ') exceeded.';
      WorkflowStepExecStore.saveStepExec(stepExec);

      // The author's RetryPolicy budget for the automatic phase is exhausted, but
      // the remaining stack is intact. Surface a recoverable "rollback incomplete"
      // state (resumable by an operator) instead of abandoning the deeper steps.
      failCompensationRecoverable(
        instance,
        'Rollback incomplete: compensation step ' +
          stepExec.Step_Name__c +
          ' failed after max retries.'
      );
    } else {
      WorkflowRetryScheduling.scheduleExponentialRetry(
        instance,
        stepExec,
        policy
      );
    }
  }

  private static void handleCompensationFail(
    WorkflowEngine.StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    // A compensation step returned an explicit fail() — treat it as a deliberate
    // compensation crash: park the saga in the recoverable CompensationFailed state
    // with the author's reason, preserving the remaining LIFO stack for operator
    // resume. Same format as the RETRY-exhausted and thrown-exception paths.
    stepExec.Status__c = 'Failed';
    stepExec.Error_Details__c = (result.directive().failureDataJson != null)
      ? result.directive().failureReason +
        '\nfailureData: ' +
        result.directive().failureDataJson
      : result.directive().failureReason;
    WorkflowStepExecStore.saveStepExec(stepExec);

    failCompensationRecoverable(
      instance,
      'Rollback incomplete: compensation step ' +
        stepExec.Step_Name__c +
        ' failed: ' +
        result.directive().failureReason
    );
  }

  private static void handleCompensationUnsupported(
    WorkflowEngine.StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    stepExec.Status__c = 'Failed';
    stepExec.Error_Details__c =
      'Unsupported compensation action: ' +
      (result != null ? result.directive().action : null);
    WorkflowStepExecStore.saveStepExec(stepExec);

    // Remaining stack is intact; leave the saga recoverable rather than abandoning it.
    failCompensationRecoverable(
      instance,
      'Rollback incomplete: compensation step ' +
        stepExec.Step_Name__c +
        ' failed: Unsupported action.'
    );
  }
}
