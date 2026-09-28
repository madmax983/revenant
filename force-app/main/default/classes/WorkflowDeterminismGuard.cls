/**
 * @description Strict determinism mode (issue #102). When the mode is on, the
 * guard records each wait decision of a step. When the step runs again with
 * the same inputs, the guard compares the new decision with the record. A
 * different decision fails the instance with STEP_NON_DETERMINISM, before the
 * engine writes the decision. When the mode is off, the guard does no work.
 *
 * Inputs are what the engine gives the step: step input, previous output,
 * attempt, the timeout-resume flag, and the signals of the instance (status,
 * count and newest CreatedDate). Signals carry approvals and child outcomes.
 * Captures and step state are not inputs: once() values are stable by
 * contract, and the engine writes wait state from the recorded decision.
 */
public inherited sharing class WorkflowDeterminismGuard {
  /** @description Error message prefix of a divergence. */
  public static final String MESSAGE_PREFIX = 'Step non-determinism: ';
  /** @description Workflow_Log__c type of a divergence. */
  public static final String LOG_TYPE = 'StepNonDeterminism';

  /**
   * @description Digests the inputs of a step run. Call before execute(), so
   * a signal that arrives during the run counts as a new input.
   * @param context The hydrated step context.
   * @return The inputs digest, or null when strict mode is off.
   */
  public static String captureInputs(StepContext context) {
    if (WorkflowEngine.strictDeterminism != true || context == null) {
      return null;
    }
    List<String> parts = new List<String>{
      'input=' + context.inputJson,
      'previous=' + context.previousStepOutput,
      'attempt=' + context.attempt,
      'timeoutResume=' + context.retry().isTimeoutResume()
    };
    Id instanceId = context.workflowInstanceId;
    for (AggregateResult row : [
      SELECT Status__c sigStatus, COUNT(Id) total, MAX(CreatedDate) newest
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :instanceId
      WITH SYSTEM_MODE
      GROUP BY Status__c
      ORDER BY Status__c
    ]) {
      parts.add(
        'signals=' +
          row.get('sigStatus') +
          '|' +
          row.get('total') +
          '|' +
          row.get('newest')
      );
    }
    return WorkflowDecisionFingerprint.digest(String.join(parts, '\n'));
  }

  /**
   * @description Compares a step result with the recorded decision, and
   * records or clears the decision on the in-memory step row. The wait
   * handler saves the row, so a record costs no extra DML.
   * @param inputs The digest from captureInputs, or null.
   * @param ctx The run context with the step row and the thrown error.
   * @param stepInstance The step that ran.
   * @param result The step result.
   * @return The divergence message, or null.
   */
  public static String verify(
    String inputs,
    WorkflowStepRunner.RunStepContext ctx,
    WorkflowStep stepInstance,
    StepResult result
  ) {
    // A thrown error is not a decision. Auto-retry handles it.
    if (inputs == null || ctx?.stepExec == null || ctx.thrownError != null) {
      return null;
    }
    Workflow_Step_Execution__c stepExec = ctx.stepExec;
    String decision = WorkflowDecisionFingerprint.describe(
      result,
      stepInstance instanceof CompensatableStep
    );
    WorkflowDecisionFingerprint.Record rec = WorkflowDecisionFingerprint.parseRecord(
      stepExec.Decision_Record__c
    );
    if (rec != null && rec.inputs.equals(inputs)) {
      if (
        rec.decisionHash.equals(WorkflowDecisionFingerprint.digest(decision))
      ) {
        return null;
      }
      return MESSAGE_PREFIX +
        'step ' +
        stepExec.Step_Name__c +
        ' ran again with the same inputs and changed its decision. Recorded: ' +
        rec.decision +
        '. New: ' +
        decision.left(WorkflowDecisionFingerprint.MAX_SUMMARY_LENGTH) +
        '. Wrap values that change between runs in StepContext.captures().once().';
    }
    Boolean isWait =
      result != null &&
      WorkflowDecisionFingerprint.isWait(result.directive().action);
    stepExec.Decision_Record__c = isWait
      ? WorkflowDecisionFingerprint.toRecordJson(inputs, decision)
      : null;
    return null;
  }

  /**
   * @description Fails the instance when the outcome carries a divergence.
   * Runs after the outcome re-lock and before the dispatch, so the divergent
   * decision writes no new step row and no compensation push. The buffered
   * step events are not published. Claimed signals go back to Received.
   * @param outcome The step outcome.
   * @return True when the guard failed the instance.
   */
  public static Boolean failIfDivergent(
    WorkflowEngine.StepOutcomeContext outcome
  ) {
    if (outcome == null || String.isBlank(outcome.divergence)) {
      return false;
    }
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    WorkflowSignalConsume.rollbackClaimedSignals(outcome.context);
    stepExec.Status__c = 'Failed';
    stepExec.Error_Details__c = WorkflowFailureDetails.build(
      stepExec,
      outcome.divergence,
      null
    );
    WorkflowStepExecStore.saveStepExec(stepExec);
    // The log row keeps the category when error routing or compensation
    // handles the failure.
    WorkflowLog.error(LOG_TYPE, outcome.divergence, outcome.instance.Id);

    WorkflowEngine.FailInstanceRequest req = new WorkflowEngine.FailInstanceRequest();
    req.instanceId = outcome.instance.Id;
    req.stepName = stepExec.Step_Name__c;
    req.errorMessage = outcome.divergence;
    req.failureCategory = WorkflowEngine.CAT_STEP_NON_DETERMINISM;
    WorkflowEngine.failWorkflowInstance(req);
    return true;
  }
}
