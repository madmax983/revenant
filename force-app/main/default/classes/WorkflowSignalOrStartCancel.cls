/**
 * @description Cancel pre-pass for the durable-execution engine's bulk
 * signal-or-start (INV-F effectively-once cancellation). Builds keyed cancel
 * claims (deduped in-batch) and runs unkeyed cancels immediately; inserts the
 * keyed claims with allOrNone=false so a winner cancels its instance, a
 * concurrent duplicate is a no-op, and a genuine (non-duplicate) claim failure
 * rolls the batch's savepoint back and rethrows; then refreshes post-cancel
 * statuses so cancelled instances are excluded from the forward signal pass. The
 * claim→apply sequence is kept intra-class so the effectively-once guarantee is
 * never split across a class boundary. All DML/SOQL runs in system mode.
 */
public inherited sharing class WorkflowSignalOrStartCancel {
  // Keyed cancel claims and the instances whose cancellation was attempted.
  private class CancelClaimBatch {
    List<Workflow_Signal__c> claims = new List<Workflow_Signal__c>();
    List<Id> instIds = new List<Id>();
    List<Boolean> runComp = new List<Boolean>();
    Set<Id> attemptedIds = new Set<Id>();
  }

  /**
   * @description Builds keyed cancel claims, runs cancellations, and refreshes
   * post-cancel statuses so cancelled instances are excluded from the forward
   * signal pass.
   * @param run the signal-or-start accumulator (cancelled ids populated)
   */
  public static void processSignalOrStartCancels(
    WorkflowSignalOrStartService.SignalOrStartRun run
  ) {
    CancelClaimBatch batch = buildSignalOrStartCancelClaims(run);
    insertSignalOrStartCancelClaims(run, batch);
    refreshCancelledInstances(run, batch);
  }

  // Build keyed cancel claims (deduped in-batch) and immediately run unkeyed
  // cancels; skips non-cancel and already-terminal targets.
  private static CancelClaimBatch buildSignalOrStartCancelClaims(
    WorkflowSignalOrStartService.SignalOrStartRun run
  ) {
    CancelClaimBatch batch = new CancelClaimBatch();
    Set<String> seenCancelKeys = new Set<String>();
    List<WorkflowEngine.SignalOrStartRequest> requests = run.requests;
    List<WorkflowEngine.StartResult> startResults = run.startResults;

    for (Integer i = 0; i < requests.size(); i++) {
      WorkflowEngine.SignalOrStartRequest req = requests[i];
      WorkflowEngine.StartResult res = startResults[i];
      if (res == null) {
        continue;
      }

      Id instanceId = res.instanceId;
      Boolean isNew = res.isNew;

      if (!WorkflowSignalHelpers.isCancelSignalName(req.signalName)) {
        continue;
      }
      if (
        isSignalTargetTerminal(run.existingInstances.get(instanceId), isNew)
      ) {
        continue; // Terminal or continued-as-new instance: cancel is an idempotent no-op
      }

      Boolean runCompensations = WorkflowSignalHelpers.parseRunCompensations(
        req.payload
      );

      if (String.isNotBlank(req.idempotencyKey)) {
        String claimKey = WorkflowSignalDedup.deriveSignalDedupKey(
          instanceId,
          req.idempotencyKey
        );
        if (seenCancelKeys.contains(claimKey)) {
          continue; // in-batch duplicate keyed cancel
        }
        seenCancelKeys.add(claimKey);
        batch.claims.add(
          new Workflow_Signal__c(
            Workflow_Instance__c = instanceId,
            Signal_Name__c = req.signalName,
            Status__c = 'Consumed',
            Signal_Key__c = claimKey
          )
        );
        batch.instIds.add(instanceId);
        batch.runComp.add(runCompensations);
      } else {
        // Unkeyed cancel: execute immediately
        cancelInstance(instanceId, runCompensations);
        batch.attemptedIds.add(instanceId);
      }
    }
    return batch;
  }

  // Insert the keyed cancel claims (allOrNone=false); each winner runs its
  // cancel, a genuine (non-duplicate) claim failure rolls back and throws.
  private static void insertSignalOrStartCancelClaims(
    WorkflowSignalOrStartService.SignalOrStartRun run,
    CancelClaimBatch batch
  ) {
    if (batch.claims.isEmpty()) {
      return;
    }
    Database.SaveResult[] claimResults = Database.insert(
      batch.claims,
      false,
      AccessLevel.SYSTEM_MODE
    );
    String claimError = null;
    for (Integer i = 0; i < claimResults.size(); i++) {
      Database.SaveResult sr = claimResults[i];
      if (sr.isSuccess()) {
        cancelInstance(batch.instIds[i], batch.runComp[i]);
        batch.attemptedIds.add(batch.instIds[i]);
      } else if (
        !WorkflowStartService.isDuplicateSaveError(sr) && claimError == null
      ) {
        claimError = sr.getErrors()[0].getMessage();
      }
    }
    if (claimError != null) {
      Database.rollback(run.sp);
      throw new WorkflowEngine.WorkflowException(
        'Failed to claim cancel: ' + claimError
      );
    }
  }

  // Refresh post-cancel statuses in one query; non-wakeable results are recorded
  // so the forward signal pass skips them.
  private static void refreshCancelledInstances(
    WorkflowSignalOrStartService.SignalOrStartRun run,
    CancelClaimBatch batch
  ) {
    if (batch.attemptedIds.isEmpty()) {
      return;
    }
    Set<Id> attemptedCancelIds = batch.attemptedIds;
    for (Workflow_Instance__c refreshed : [
      SELECT Id, Status__c
      FROM Workflow_Instance__c
      WHERE Id IN :attemptedCancelIds
      WITH SYSTEM_MODE
    ]) {
      Workflow_Instance__c cached = run.existingInstances.get(refreshed.Id);
      if (cached != null) {
        cached.Status__c = refreshed.Status__c;
      }
      if (!WorkflowSignalHelpers.isWakeableStatus(refreshed.Status__c)) {
        run.cancelledInstanceIds.add(refreshed.Id);
      }
    }
  }

  // True when an existing (non-new) instance is terminal or continued-as-new, so
  // a cancel is an idempotent no-op.
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

  // Cancels a workflow instance, optionally running saga compensations across the
  // instance and its active descendant tree. Thin dispatcher mirroring the
  // engine's internal cancel call sites; the cancellation logic lives on
  // WorkflowCancellation.
  private static void cancelInstance(Id instanceId, Boolean runCompensations) {
    if (runCompensations) {
      WorkflowCancellation.cancelWithCompensationsInstance(instanceId);
    } else {
      WorkflowCancellation.cancelInstance(instanceId);
    }
  }
}
