/**
 * @description Strict determinism mode (issue #102). When the mode is on, the
 * guard records each wait decision of a step. When the step runs again with
 * the same inputs, the guard compares the new decision with the record. A
 * different decision fails the instance with STEP_NON_DETERMINISM, before the
 * dispatch writes the decision. When the mode is off, the guard does no work.
 *
 * The inputs digest holds: the stored step input, previous output and step
 * state, the attempt, the timeout-resume flag, the live signals, and the
 * child status counts. The guard digests stored forms,
 * so no decoded payload goes into the digest. Captures are not inputs:
 * once() values are stable by contract.
 */
public inherited sharing class WorkflowDeterminismGuard {
  /** @description Error message prefix of a divergence. */
  public static final String MESSAGE_PREFIX = 'Step non-determinism: ';
  /** @description Workflow_Log__c type of a divergence. */
  public static final String LOG_TYPE = 'StepNonDeterminism';
  /**
   * @description Inputs value when the guard cannot read all inputs. The
   * guard then does not compare and keeps the record.
   */
  public static final String UNKNOWN_INPUTS = 'unknown';

  // Max live signals the guard reads. More rows give UNKNOWN_INPUTS, so a
  // large backlog cannot use up the query-row limit.
  @TestVisible
  private static Integer maxLiveSignals = 2000;
  // Max child instances the guard reads, for the same reason.
  @TestVisible
  private static Integer maxChildren = 2000;

  /**
   * @description Digests the inputs of a step run. Call before execute(), so
   * a signal that arrives during the run counts as a new input.
   * @param ctx The run context with the step row.
   * @param context The hydrated step context.
   * @param prevOutput The stored previous step output.
   * @return The inputs digest, UNKNOWN_INPUTS for live signals or children
   * over the cap, or null when strict mode is off.
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
    // Typed JSON values: a null value and the text "null" differ.
    List<Object> parts = new List<Object>{
      ctx.stepExec.Input__c,
      prevOutput,
      ctx.stepExec.Output__c,
      context.attempt,
      context.retry().isTimeoutResume()
    };
    // Live signals only: a step reads only these. Consumed history does
    // not count query rows.
    Integer rowCap = maxLiveSignals + 1;
    List<Workflow_Signal__c> live = [
      SELECT Id, Status__c
      FROM Workflow_Signal__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Status__c IN ('Received', 'Processing')
      WITH SYSTEM_MODE
      ORDER BY Id
      LIMIT :rowCap
    ];
    if (live.size() > maxLiveSignals) {
      return UNKNOWN_INPUTS;
    }
    // A parallel branch claims what it reads (Received to Processing). Count
    // the claims of this run as Received, so a re-check after the run sees
    // the same inputs.
    Set<Id> ownClaims = context.signals().getClaimedSignalIds();
    for (Workflow_Signal__c sig : live) {
      String status = ownClaims.contains(sig.Id) ? 'Received' : sig.Status__c;
      parts.add(sig.Id + '|' + status);
    }
    Integer childCap = maxChildren + 1;
    List<Workflow_Instance__c> children = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :instanceId
      WITH SYSTEM_MODE
      ORDER BY Status__c
      LIMIT :childCap
    ];
    if (children.size() > maxChildren) {
      return UNKNOWN_INPUTS;
    }
    for (Workflow_Instance__c child : children) {
      parts.add('child|' + child.Status__c);
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
    // Keep the record, so the next decision is still compared.
    if (isNotComparable(inputs, ctx, result)) {
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

  // Unknown inputs, a thrown error and a transient result give no compare.
  private static Boolean isNotComparable(
    String inputs,
    WorkflowStepRunner.RunStepContext ctx,
    StepResult result
  ) {
    return inputs == UNKNOWN_INPUTS ||
      ctx.thrownError != null ||
      isTransient(result);
  }

  // RETRY, SLEEP, YIELD and a batch wait (issue #138) ask the engine to run
  // the step again later. They are not routing decisions. The job status is
  // not a step input, so the guard does not compare a batch wait.
  private static Boolean isTransient(StepResult result) {
    StepResult.ActionType action = result?.directive().action;
    return action == StepResult.ActionType.RETRY ||
      action == StepResult.ActionType.SLEEP ||
      action == StepResult.ActionType.YIELD ||
      result?.directive().awaitedBatchJobId != null;
  }
}
