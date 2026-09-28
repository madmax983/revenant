/**
 * @description Strict determinism mode (issue #102). When the mode is on, the
 * guard records each wait decision of a step. When the step runs again with
 * the same inputs, the guard compares the new decision with the record. A
 * different decision fails the instance with STEP_NON_DETERMINISM, before the
 * dispatch writes the decision. When the mode is off, the guard does no work.
 *
 * The inputs digest holds: the stored step input, previous output and step
 * state, the attempt, the timeout-resume flag, the live signal counts, the
 * newest signal, and the child status counts. The guard digests stored forms,
 * so no decoded payload goes into the digest. Captures are not inputs:
 * once() values are stable by contract.
 */
public inherited sharing class WorkflowDeterminismGuard {
  /** @description Error message prefix of a divergence. */
  public static final String MESSAGE_PREFIX = 'Step non-determinism: ';
  /** @description Workflow_Log__c type of a divergence. */
  public static final String LOG_TYPE = 'StepNonDeterminism';

  /**
   * @description Digests the inputs of a step run. Call before execute(), so
   * a signal that arrives during the run counts as a new input.
   * @param ctx The run context with the step row.
   * @param context The hydrated step context.
   * @param prevOutput The stored previous step output.
   * @return The inputs digest, or null when strict mode is off.
   */
  public static String captureInputs(
    WorkflowStepRunner.RunStepContext ctx,
    StepContext context,
    String prevOutput
  ) {
    if (
      WorkflowEngine.strictDeterminism != true ||
      ctx?.stepExec == null ||
      context == null
    ) {
      return null;
    }
    Id instanceId = ctx.instanceId;
    List<String> parts = new List<String>{
      'input=' + ctx.stepExec.Input__c,
      'previous=' + prevOutput,
      'state=' + ctx.stepExec.Output__c,
      'attempt=' + context.attempt,
      'timeoutResume=' + context.retry().isTimeoutResume()
    };
    // Live signals only: consumed history does not count query rows.
    for (AggregateResult row : [
      SELECT Status__c sigStatus, COUNT(Id) total
      FROM Workflow_Signal__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Status__c IN ('Received', 'Processing')
      WITH SYSTEM_MODE
      GROUP BY Status__c
      ORDER BY Status__c
    ]) {
      parts.add('live=' + row.get('sigStatus') + '|' + row.get('total'));
    }
    for (Workflow_Signal__c newest : [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :instanceId
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ]) {
      parts.add('newest=' + newest.Id);
    }
    for (AggregateResult row : [
      SELECT Status__c childStatus, COUNT(Id) total
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :instanceId
      WITH SYSTEM_MODE
      GROUP BY Status__c
      ORDER BY Status__c
    ]) {
      parts.add('child=' + row.get('childStatus') + '|' + row.get('total'));
    }
    // JSON keeps each part apart: no part can look like two parts.
    return WorkflowDecisionFingerprint.digest(JSON.serialize(parts));
  }

  /**
   * @description Compares a step result with the recorded decision, and
   * records or clears the decision on the in-memory step row. The outcome
   * handler saves the row, so this costs no extra DML.
   * @param inputs The digest from captureInputs, or null.
   * @param ctx The run context with the step, the step row and the thrown
   * error.
   * @param result The step result.
   * @return The divergence message, or null.
   */
  public static String verify(
    String inputs,
    WorkflowStepRunner.RunStepContext ctx,
    StepResult result
  ) {
    if (ctx?.stepExec == null) {
      return null;
    }
    Workflow_Step_Execution__c stepExec = ctx.stepExec;
    if (inputs == null) {
      // Mode off: remove an old record, so it cannot come back later.
      stepExec.Decision_Record__c = null;
      return null;
    }
    // A thrown error and a transient result are not decisions. Keep the
    // record, so the next decision is still compared.
    if (ctx.thrownError != null || isTransient(result)) {
      return null;
    }
    String decision = WorkflowDecisionFingerprint.describe(
      result,
      ctx.stepInstance instanceof CompensatableStep
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
        'the step changed its decision on equal inputs.' +
        '\nRecorded: ' +
        rec.decision +
        '\nNew: ' +
        decision.left(WorkflowDecisionFingerprint.MAX_SUMMARY_LENGTH) +
        '\nWrap values that change between runs in StepContext.captures().once().';
    }
    stepExec.Decision_Record__c = WorkflowDecisionFingerprint.isWait(
        result?.directive().action
      )
      ? WorkflowDecisionFingerprint.toRecordJson(inputs, decision)
      : null;
    return null;
  }

  /**
   * @description Fails the instance when the outcome carries a divergence.
   * Runs after the outcome re-lock and before the dispatch, so the engine
   * writes no new step row and no compensation push. The guard does not
   * publish the buffered step events. Claimed signals go back to Received.
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

  /**
   * @description Removes the recorded decisions of the open rows of the
   * current steps. Call when an operator accepts new decisions, for example on
   * a definition-change release.
   * @param instanceId The instance.
   * @param currentStep The current step, or a comma-separated list of steps.
   */
  public static void clearRecords(Id instanceId, String currentStep) {
    if (String.isBlank(currentStep)) {
      return;
    }
    List<String> steps = new List<String>();
    for (String step : currentStep.split(',')) {
      steps.add(step.trim());
    }
    List<Workflow_Step_Execution__c> rows = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c IN :steps
        AND Status__c IN ('Pending', 'Running')
      WITH SYSTEM_MODE
    ];
    for (Workflow_Step_Execution__c row : rows) {
      row.Decision_Record__c = null;
    }
    if (!rows.isEmpty()) {
      Database.update(rows, true, AccessLevel.SYSTEM_MODE);
    }
  }

  // RETRY, SLEEP and YIELD ask the engine to run the step again later. They
  // are not routing decisions.
  private static Boolean isTransient(StepResult result) {
    StepResult.ActionType action = result?.directive().action;
    return action == StepResult.ActionType.RETRY ||
      action == StepResult.ActionType.SLEEP ||
      action == StepResult.ActionType.YIELD;
  }
}
