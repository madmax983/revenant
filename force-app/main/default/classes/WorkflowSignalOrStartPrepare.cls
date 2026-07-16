/**
 * @description Signal-record prepare and insert phase for the durable-execution
 * engine's bulk signal-or-start. Builds the ordinary (non-cancel) Received signal
 * rows -- skipping cancels, instances cancelled earlier in this batch, and
 * terminal/stalled/continued-as-new targets, and deduping keyed signals in-batch
 * on the per-instance composite key -- while collecting the active existing
 * instances that may need waking. Then inserts the rows with allOrNone=false so a
 * concurrent duplicate is swallowed as a no-op while a genuine (non-duplicate)
 * failure rolls the batch savepoint back and rethrows, recording the instances
 * whose insert landed a fresh signal. All DML/SOQL runs in system mode.
 */
public inherited sharing class WorkflowSignalOrStartPrepare {
  /**
   * @description Builds the ordinary signal records to insert (in-batch keyed
   * dedup) and collects the active existing instances that may need waking.
   * @param run the signal-or-start accumulator (signal rows/wake set populated)
   */
  public static void prepareSignalOrStartRecords(
    WorkflowSignalOrStartService.SignalOrStartRun run
  ) {
    Set<String> seenCompositeKeys = new Set<String>();
    for (Integer i = 0; i < run.requests.size(); i++) {
      prepareSignalOrStartRecord(run, i, seenCompositeKeys);
    }
  }

  // Build/track the signal record for one request, skipping cancels, already
  // cancelled/terminal/stalled targets, and in-batch keyed duplicates.
  private static void prepareSignalOrStartRecord(
    WorkflowSignalOrStartService.SignalOrStartRun run,
    Integer i,
    Set<String> seenCompositeKeys
  ) {
    WorkflowEngine.StartResult res = run.startResults[i];
    if (res == null) {
      return;
    }
    WorkflowEngine.SignalOrStartRequest req = run.requests[i];
    Id instanceId = res.instanceId;
    Boolean isNew = res.isNew;

    // Skip cancellation signals (already handled above) or instances that were cancelled in this batch
    if (
      WorkflowSignalHelpers.isCancelSignalName(req.signalName) ||
      run.cancelledInstanceIds.contains(instanceId)
    ) {
      return;
    }

    Workflow_Instance__c existingInst = isNew
      ? null
      : run.existingInstances.get(instanceId);
    if (isSignalTargetTerminalOrStalled(existingInst, isNew)) {
      // Discard/swallow signal for terminal, stalled rollback, or continued-as-new instances (idempotent no-op)
      return;
    }

    Workflow_Signal__c sig = buildSignalOrStartSignalRecord(
      req,
      instanceId,
      seenCompositeKeys
    );
    if (sig == null) {
      // In-batch duplicate: skip insertion of this signal
      return;
    }

    run.signalsToInsert.add(sig);
    run.signalsInstIds.add(instanceId);

    // If it's an existing active instance, we may need to wake it. Brand-new
    // instances are already enqueued to run by startOrGet, so we don't wake them.
    if (shouldTrackSignalWake(existingInst, isNew)) {
      run.activeInstIdsToWake.add(instanceId);
    }
  }

  // True when a signal to an existing instance must be swallowed: the instance is
  // terminal/continued-as-new or in a stalled CompensationFailed rollback.
  private static Boolean isSignalTargetTerminalOrStalled(
    Workflow_Instance__c existingInst,
    Boolean isNew
  ) {
    if (isNew || existingInst == null) {
      return false;
    }
    return isSignalTargetTerminal(existingInst, isNew) ||
      existingInst.Status__c == 'CompensationFailed';
  }

  // True when an existing (non-new) instance is terminal or continued-as-new.
  private static Boolean isSignalTargetTerminal(
    Workflow_Instance__c existingInst,
    Boolean isNew
  ) {
    if (isNew || existingInst == null) {
      return false;
    }
    return WorkflowStatusRead.TERMINAL_GETSTATUS_STATUSES.contains(
        existingInst.Status__c
      ) || existingInst.Status__c == 'ContinuedAsNew';
  }

  // True when an existing, non-new instance is signal-wakeable and so should be
  // tracked for a possible wake after its fresh signal lands.
  private static Boolean shouldTrackSignalWake(
    Workflow_Instance__c existingInst,
    Boolean isNew
  ) {
    return !isNew &&
      existingInst != null &&
      isWakeableSignalStatus(existingInst.Status__c);
  }

  // True when an instance's status is signal-wakeable.
  private static Boolean isWakeableSignalStatus(String status) {
    return status == 'Suspended' ||
      status == 'Running' ||
      status == 'Compensating' ||
      status == 'Cancelling';
  }

  // Build a Received signal record; keyed signals dedup in-batch (null return
  // means an in-batch duplicate that must be skipped).
  private static Workflow_Signal__c buildSignalOrStartSignalRecord(
    WorkflowEngine.SignalOrStartRequest req,
    Id instanceId,
    Set<String> seenCompositeKeys
  ) {
    Workflow_Signal__c sig = new Workflow_Signal__c(
      Workflow_Instance__c = instanceId,
      Signal_Name__c = req.signalName,
      Payload__c = req.payload,
      Status__c = 'Received'
    );

    if (String.isNotBlank(req.idempotencyKey)) {
      String compositeKey = WorkflowSignalDedup.deriveSignalDedupKey(
        instanceId,
        req.idempotencyKey
      );
      if (seenCompositeKeys.contains(compositeKey)) {
        return null;
      }
      seenCompositeKeys.add(compositeKey);
      sig.Signal_Key__c = compositeKey;
    }
    return sig;
  }

  /**
   * @description Inserts the signal records (allOrNone=false); a genuine
   * (non-duplicate) failure rolls back the batch savepoint and throws, otherwise
   * fresh-signal instances are tracked for the wake phase.
   * @param run the signal-or-start accumulator (fresh-signal set populated)
   */
  public static void insertSignalOrStartSignals(
    WorkflowSignalOrStartService.SignalOrStartRun run
  ) {
    if (run.signalsToInsert.isEmpty()) {
      return;
    }
    // Insert signals using allOrNone=false so concurrent duplicates are swallowed as no-ops,
    // but genuine errors are rolled back and thrown.
    Database.SaveResult[] srs = Database.insert(
      run.signalsToInsert,
      false,
      AccessLevel.SYSTEM_MODE
    );

    String genuineError = null;
    for (Integer i = 0; i < srs.size(); i++) {
      Database.SaveResult sr = srs[i];
      if (sr.isSuccess()) {
        run.instancesWithFreshSignal.add(run.signalsInstIds[i]);
      } else if (
        !WorkflowStartService.isDuplicateSaveError(sr) && genuineError == null
      ) {
        genuineError = sr.getErrors()[0].getMessage();
      }
    }

    if (genuineError != null) {
      Database.rollback(run.sp);
      throw new WorkflowEngine.WorkflowException(
        'Failed to insert signal: ' + genuineError
      );
    }
  }
}
