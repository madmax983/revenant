/**
 * @description Outcome-seam rule for cooperative cancellation (issue #143). It
 * acts only when the step saw `ctx.isCancellationRequested() == true`:
 *
 * 1. Instance `Cancelled` or `Cancelling`: drop the step result. Roll back
 *    claimed signals. Set the step row to `Cancelled`. `cancel()` already
 *    started the rollback when it was asked for.
 * 2. Instance runnable, an ancestor cancelled: do rule 1, then cancel the
 *    instance. A `Cancelling` ancestor gives a cancel with compensations.
 *
 * The seam then skips the dispatch: no `Completed` row, no forward hop, no
 * throw. A step that did not see a cancel keeps the old seam path. Runs in
 * system mode.
 */
public inherited sharing class WorkflowCooperativeCancel {
  /**
   * @description Ends a step that stopped for a cancel.
   * @param outcome The step outcome. Its context tells if the step saw a cancel.
   * @param freshInstance The instance, locked FOR UPDATE by the seam.
   * @return True when this call handled the outcome. The seam must then skip
   * the dispatch.
   */
  public static Boolean stopIfCancelled(
    WorkflowEngine.StepOutcomeContext outcome,
    Workflow_Instance__c freshInstance
  ) {
    if (outcome.context == null || !outcome.context.wasCancellationObserved()) {
      return false;
    }
    if (WorkflowCancelProbe.isCancelStatus(freshInstance.Status__c)) {
      abandonStep(outcome);
      return true;
    }
    if (
      WorkflowOutcomePrepare.isTerminalOrTransitioningStatus(
        freshInstance.Status__c
      )
    ) {
      return false;
    }
    String ancestorStatus = WorkflowCancelProbe.ancestorCancelStatus(
      freshInstance.Id
    );
    if (ancestorStatus == null) {
      return false;
    }
    abandonStep(outcome);
    WorkflowEngine.cancel(freshInstance.Id, ancestorStatus == 'Cancelling');
    return true;
  }

  // Drops the step result: releases claimed signals and marks the step row
  // Cancelled. Writes only the status, so no other staged field is saved.
  private static void abandonStep(WorkflowEngine.StepOutcomeContext outcome) {
    WorkflowSignalConsume.rollbackClaimedSignals(outcome.context);
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    if (stepExec == null) {
      return;
    }
    stepExec.Status__c = 'Cancelled';
    if (stepExec.Id == null) {
      // A CalloutStep saves its row after execute(). Keep an audit row.
      WorkflowStepExecStore.saveStepExec(stepExec);
      return;
    }
    Database.update(
      new Workflow_Step_Execution__c(Id = stepExec.Id, Status__c = 'Cancelled'),
      true,
      AccessLevel.SYSTEM_MODE
    );
  }
}
