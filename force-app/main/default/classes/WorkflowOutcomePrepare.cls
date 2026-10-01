/**
 * @description Prepares a freshly re-locked workflow instance for the outcome
 * dispatch. Guards against a stale completion: it rolls back the claimed
 * signals and cancels a still-running execution. Ends a step that stopped for
 * a cancel (issue #143). Persists reported progress and capture-once values,
 * restores a blanked current step, and asserts the instance is runnable before
 * the outcome handler acts. Extracted from `WorkflowEngine`;
 * {@link WorkflowOutcomePrepare#prepareStepOutcome} is invoked by the outcome
 * seam after the FOR UPDATE re-lock. All SOQL and DML run in system mode.
 */
public inherited sharing class WorkflowOutcomePrepare {
  /**
   * @description Prepares the freshly re-locked instance for the outcome
   * dispatch: returns false when the completion is stale (already handled),
   * otherwise persists progress, restores a blanked current step, asserts the
   * instance is runnable, resets the transient-retry counter, records whether the
   * step is a parallel branch, and persists new captures.
   * @param outcome the step outcome bundle carrying instance, step exec and context
   * @param freshInstance the FOR UPDATE re-locked instance record
   * @return false when this is a stale completion to ignore, true otherwise
   */
  public static Boolean prepareStepOutcome(
    WorkflowEngine.StepOutcomeContext outcome,
    Workflow_Instance__c freshInstance
  ) {
    if (isStaleCompletion(outcome, freshInstance)) {
      return false;
    }
    // Issue #143: a step that saw a cancel and returned ends cleanly here.
    if (WorkflowCooperativeCancel.stopIfCancelled(outcome, freshInstance)) {
      return false;
    }
    applyProgressUpdate(outcome, freshInstance);
    restoreBlankCurrentStep(outcome, freshInstance);
    assertInstanceRunnable(freshInstance);
    outcome.instance = freshInstance;
    // Issue #138: a batch wait sets the job Id. Each other step outcome
    // clears it, so the watchdog does not wake a later wait for an old job.
    freshInstance.Awaited_Batch_Job_Id__c = outcome.result
      ?.directive()
      .awaitedBatchJobId;
    resetTransientRetryCounter(outcome.stepExec);
    outcome.isParallel =
      String.isNotBlank(freshInstance.Current_Step__c) &&
      freshInstance.Current_Step__c.contains(',');
    persistNewCaptures(outcome);
    return true;
  }

  // Verify the completing step is still active in the current step list. If not,
  // roll back its claimed signals, cancel a still-Running exec, and report stale.
  private static Boolean isStaleCompletion(
    WorkflowEngine.StepOutcomeContext outcome,
    Workflow_Instance__c freshInstance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    Boolean stepIsActive = false;
    if (String.isNotBlank(freshInstance.Current_Step__c) && stepExec != null) {
      for (String activeStep : freshInstance.Current_Step__c.split(',')) {
        if (activeStep.trim() == stepExec.Step_Name__c) {
          stepIsActive = true;
          break;
        }
      }
    }
    if (stepIsActive) {
      return false;
    }
    WorkflowSignalConsume.rollbackClaimedSignals(outcome.context);
    if (
      stepExec != null &&
      stepExec.Id != null &&
      stepExec.Status__c == 'Running'
    ) {
      stepExec.Status__c = 'Cancelled';
      Database.update(stepExec, true, AccessLevel.SYSTEM_MODE);
    }
    return true;
  }

  // Persist reported progress onto the fresh instance before dispatch.
  private static void applyProgressUpdate(
    WorkflowEngine.StepOutcomeContext outcome,
    Workflow_Instance__c freshInstance
  ) {
    StepContext context = outcome.context;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    if (context != null && context.progress().isProgressReported()) {
      String progJson = context.progress().getProgressJson();
      freshInstance.Progress__c = WorkflowPayloadOffload.savePayloadIfNeeded(
        freshInstance.Id,
        WorkflowPayloadCodecs.encode(
          progJson,
          CodecContext.PayloadKind.STEP_STATE
        ),
        'Progress_' +
        (stepExec != null && String.isNotBlank(stepExec.Step_Name__c)
          ? stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
          : 'Default')
      );
    }
  }

  // Restore a blanked current step from the pre-drive instance snapshot.
  private static void restoreBlankCurrentStep(
    WorkflowEngine.StepOutcomeContext outcome,
    Workflow_Instance__c freshInstance
  ) {
    Workflow_Instance__c instance = outcome.instance;
    if (
      String.isBlank(freshInstance.Current_Step__c) &&
      String.isNotBlank(instance.Current_Step__c)
    ) {
      freshInstance.Current_Step__c = instance.Current_Step__c;
    }
  }

  // Guard against a terminal/compensating instance and flip Pending/Suspended to
  // Running so the outcome dispatch always sees a runnable instance.
  private static void assertInstanceRunnable(
    Workflow_Instance__c freshInstance
  ) {
    if (isTerminalOrTransitioningStatus(freshInstance.Status__c)) {
      throw new WorkflowEngine.WorkflowException(
        'Workflow execution was terminated, cancelled, is compensating, or was continued as new.'
      );
    }
    if (
      freshInstance.Status__c == 'Pending' ||
      freshInstance.Status__c == 'Suspended'
    ) {
      freshInstance.Status__c = 'Running';
    }
  }

  /**
   * @description True when a status is terminal, compensating, cancelling, or
   * continued-as-new. The seam does not run a step result for such a status.
   * @param status the instance status to test
   * @return true when the instance is not runnable
   */
  public static Boolean isTerminalOrTransitioningStatus(String status) {
    return status == 'Failed' ||
      status == 'Compensating' ||
      status == 'Compensated' ||
      status == 'CompensationFailed' ||
      status == 'Cancelled' ||
      status == 'Cancelling' ||
      status == 'ContinuedAsNew';
  }

  /**
   * @description True when a status is a park: `DefinitionChanged`, `Held` or
   * `Paused`. An outcome that finishes after the park must not change it.
   * Only release or resume moves a parked instance.
   * @param status the instance status to test
   * @return true when the instance is parked
   */
  public static Boolean isParkedStatus(String status) {
    return status == WorkflowDefinitionChangeGate.STATUS ||
      status == WorkflowInstanceHoldGate.STATUS ||
      status == 'Paused';
  }

  // Reaching handleStepResult means the instance lock cleared, so reset the
  // consecutive transient-retry counter on the step.
  private static void resetTransientRetryCounter(
    Workflow_Step_Execution__c stepExec
  ) {
    if (
      stepExec != null &&
      stepExec.Id != null &&
      stepExec.Transient_Retry_Count__c != null &&
      stepExec.Transient_Retry_Count__c > 0
    ) {
      // Targeted single-field update so this early reset never persists any other
      // in-memory staging the outcome branches below have yet to commit.
      Database.update(
        new Workflow_Step_Execution__c(
          Id = stepExec.Id,
          Transient_Retry_Count__c = 0
        ),
        true,
        AccessLevel.SYSTEM_MODE
      );
      stepExec.Transient_Retry_Count__c = 0;
    }
  }

  // Persist capture-once values produced during this execution (once, before the
  // action dispatch, so every outcome durably records new captures).
  private static void persistNewCaptures(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    StepContext context = outcome.context;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    Workflow_Instance__c instance = outcome.instance;
    if (context.captures().hasNewCaptures()) {
      String capturedJson = context.captures().getCapturedValuesJson();
      stepExec.Captured_Values__c = WorkflowPayloadOffload.savePayloadIfNeeded(
        instance.Id,
        WorkflowPayloadCodecs.encode(
          capturedJson,
          CodecContext.PayloadKind.STEP_STATE
        ),
        'Captures_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
    }
  }
}
