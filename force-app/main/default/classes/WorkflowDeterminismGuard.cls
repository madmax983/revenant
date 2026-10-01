/**
 * @description Strict determinism mode (issue #102). When the mode is on, the
 * guard records each wait decision of a step. When the step runs again with
 * the same inputs, the guard compares the new decision with the record. A
 * different decision fails the instance with STEP_NON_DETERMINISM, before the
 * dispatch writes the decision. When the mode is off, the guard does no work.
 *
 * The inputs digest holds: the stored step input, previous output and step
 * state, the attempt, the timeout-resume flag, the live signals (Id, status,
 * name and payload), and the child status counts. The guard digests stored
 * forms, so no decoded payload goes into the digest. An offloaded value is
 * digested as the checksum of its file. Captures are not inputs: once()
 * values are stable by contract.
 */
public inherited sharing class WorkflowDeterminismGuard {
  /** @description Error message prefix of a divergence. */
  public static final String MESSAGE_PREFIX = 'Step non-determinism: ';
  /** @description Workflow_Log__c type of a divergence. */
  public static final String LOG_TYPE = 'StepNonDeterminism';
  /**
   * @description Inputs value that makes the guard skip the compare and keep
   * the record. captureInputs no longer returns it; verify still accepts it.
   */
  public static final String UNKNOWN_INPUTS = 'unknown';

  // Prefix of a file checksum in the digest. It sets the text apart from a
  // stored value.
  private static final String CHECKSUM_PREFIX = '$checksum|';

  // Max live signals the guard reads. Each payload can hold 131,072
  // characters, so the cap bounds the heap (about 2.6 million characters).
  // Over it, the guard digests the first rows and the total count.
  @TestVisible
  private static Integer maxLiveSignals = 20;
  /**
   * @description The inputs of a step run. The digest covers all inputs. The
   * other parts let the re-check find which live signal changed.
   */
  public class InputSnapshot {
    /** @description Digest of all inputs. */
    public String digest;
    // Digest of the inputs that are not live signals. It includes the
    // children and the signal count.
    private String rest;
    // The text of each live signal in the digest, by signal Id.
    private Map<Id, String> signalParts = new Map<Id, String>();
    // The lower-case name of each live signal, by signal Id.
    private Map<Id, String> signalNames = new Map<Id, String>();
  }

  /**
   * @description Digests the inputs of a step run. Call before execute(), so
   * a signal that arrives during the run counts as a new input.
   * @param ctx The run context with the step row.
   * @param context The hydrated step context.
   * @param prevOutput The stored previous step output.
   * @return The inputs digest, or null when strict mode is off or an argument
   * is missing.
   */
  public static String captureInputs(
    WorkflowStepRunner.RunStepContext ctx,
    StepContext context,
    String prevOutput
  ) {
    return capture(ctx, context, prevOutput)?.digest;
  }

  /**
   * @description Reads the inputs of a step run. Call before execute().
   * @param ctx The run context with the step row.
   * @param context The hydrated step context.
   * @param prevOutput The stored previous step output.
   * @return The snapshot, or null when strict mode is off or an argument is
   * missing.
   */
  public static InputSnapshot capture(
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
    InputSnapshot snap = new InputSnapshot();
    // The large stored values go through one digest. Typed JSON values: a null
    // value and the text "null" differ.
    String base = WorkflowDecisionFingerprint.digest(
      JSON.serialize(baseParts(ctx, context, prevOutput))
    );
    List<Object> parts = new List<Object>{ base };
    List<Object> rest = new List<Object>{ base };
    addSignalParts(snap, parts, rest, instanceId, context);
    addChildParts(parts, rest, instanceId);
    // JSON keeps each part apart: no part can look like two parts.
    snap.digest = WorkflowDecisionFingerprint.digest(JSON.serialize(parts));
    snap.rest = WorkflowDecisionFingerprint.digest(JSON.serialize(rest));
    return snap;
  }

  /**
   * @description Tells if an input that the step read changed during the run.
   * It reads the inputs again. A live signal counts only when the step matched
   * it, looked up its name, or read the full list. A change to the step state,
   * the children or the signal count over the cap always counts. A change to
   * another live signal does not count, because the step cannot see it.
   * @param before The snapshot from before the run, or null.
   * @param ctx The run context with the step row.
   * @param context The step context after the run.
   * @param prevOutput The stored previous step output.
   * @return True when a read input changed. False when the snapshot is null or
   * the inputs are equal.
   */
  public static Boolean inputsChangedDuringRun(
    InputSnapshot before,
    WorkflowStepRunner.RunStepContext ctx,
    StepContext context,
    String prevOutput
  ) {
    InputSnapshot after = before == null
      ? null
      : capture(ctx, context, prevOutput);
    if (after == null || before.digest.equals(after.digest)) {
      return false;
    }
    return !before.rest.equals(after.rest) ||
      context.signals().hasReadAllSignals() ||
      readSignalChanged(before, after, context.signals());
  }

  // True when a changed live signal is one that the step matched, or one with
  // a name that the step looked up.
  private static Boolean readSignalChanged(
    InputSnapshot before,
    InputSnapshot after,
    StepSignals signals
  ) {
    Set<Id> matched = signals.getConsumedSignalIds();
    Set<String> probed = signals.getProbedSignalNames();
    Set<Id> ids = new Set<Id>(before.signalParts.keySet());
    ids.addAll(after.signalParts.keySet());
    for (Id sigId : ids) {
      String was = before.signalParts.get(sigId);
      if (was != null && was.equals(after.signalParts.get(sigId))) {
        continue;
      }
      if (
        matched.contains(sigId) ||
        probed.contains(before.signalNames.get(sigId)) ||
        probed.contains(after.signalNames.get(sigId))
      ) {
        return true;
      }
    }
    return false;
  }

  // The inputs that are not signals or children. The engine replaces an
  // offload marker with the checksum of its file. A new marker with equal
  // content is then an equal input.
  private static List<Object> baseParts(
    WorkflowStepRunner.RunStepContext ctx,
    StepContext context,
    String prevOutput
  ) {
    List<String> stored = new List<String>{
      ctx.stepExec.Input__c,
      prevOutput,
      ctx.stepExec.Output__c
    };
    Map<Id, String> checksums = WorkflowPayloadOffload.ownedChecksums(
      stored,
      ctx.instanceId
    );
    List<Object> parts = new List<Object>();
    for (String text : stored) {
      Id docId = WorkflowPayloadOffload.markerDocId(text);
      parts.add(
        docId != null && checksums.containsKey(docId)
          ? CHECKSUM_PREFIX + checksums.get(docId)
          : text
      );
    }
    parts.add(context.attempt);
    parts.add(context.retry().isTimeoutResume());
    return parts;
  }

  // The engine reads live signals only, because a step reads only these.
  // Consumed signals add no query rows.
  private static void addSignalParts(
    InputSnapshot snap,
    List<Object> parts,
    List<Object> rest,
    Id instanceId,
    StepContext context
  ) {
    Integer rowCap = maxLiveSignals + 1;
    List<Workflow_Signal__c> live = [
      SELECT Id, Status__c, Signal_Name__c, Payload__c
      FROM Workflow_Signal__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Status__c IN ('Received', 'Processing')
      WITH SYSTEM_MODE
      ORDER BY Id
      LIMIT :rowCap
    ];
    // A parallel branch claims what it reads (Received to Processing). Count
    // the claims of this run as Received, so a re-check after the run sees
    // the same inputs.
    Set<Id> ownClaims = context.signals().getClaimedSignalIds();
    for (Integer i = 0; i < live.size() && i < maxLiveSignals; i++) {
      Workflow_Signal__c sig = live[i];
      String status = ownClaims.contains(sig.Id) ? 'Received' : sig.Status__c;
      // A name or payload edit changes the digest: a legal route change.
      String part =
        sig.Id +
        '|' +
        status +
        '|' +
        WorkflowDecisionFingerprint.digest(
          JSON.serialize(new List<Object>{ sig.Signal_Name__c, sig.Payload__c })
        );
      parts.add(part);
      snap.signalParts.put(sig.Id, part);
      snap.signalNames.put(sig.Id, sig.Signal_Name__c?.toLowerCase());
    }
    if (live.size() > maxLiveSignals) {
      // The oldest rows are digested. The total count shows an arrival.
      String count =
        'liveCount|' +
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE
            Workflow_Instance__c = :instanceId
            AND Status__c IN ('Received', 'Processing')
          WITH SYSTEM_MODE
        ];
      parts.add(count);
      rest.add(count);
    }
  }

  // One aggregate row for each status: no row cap, no heap cost.
  private static void addChildParts(
    List<Object> parts,
    List<Object> rest,
    Id instanceId
  ) {
    for (AggregateResult agg : [
      SELECT Status__c status, COUNT(Id) total
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :instanceId
      WITH SYSTEM_MODE
      GROUP BY Status__c
      ORDER BY Status__c
    ]) {
      String part = 'child|' + agg.get('status') + '|' + agg.get('total');
      parts.add(part);
      rest.add(part);
    }
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
