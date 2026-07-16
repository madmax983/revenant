/**
 * @description Bulk keyed-cancel pre-pass for the durable-execution engine's
 * `signal(List)` path (INV-F effectively-once cancellation). Claims the keyed
 * cancels in bulk under one savepoint (one marker insert with allOrNone=false
 * guards the whole sub-batch, rather than ~2 DML statements per row which would
 * abort large batches against the 150-statement limit), cancels only the
 * freshly-claimed (won-the-race) instances in claim order, then refreshes their
 * cached statuses. A concurrent-duplicate claim loses the unique-constraint race
 * and is skipped; a genuine (non-duplicate) claim error or a failed cancel rolls
 * the whole sub-batch's claims back and rethrows so the keys can be retried. The
 * claim→apply sequence is kept intra-class so the effectively-once guarantee is
 * never split across a class boundary. All DML/SOQL runs in system mode.
 */
public inherited sharing class WorkflowSignalBatchCancel {
  /** Parallel lists describing the keyed-cancel claims to insert then act on. */
  private class KeyedCancelClaimBatch {
    List<Workflow_Signal__c> claims = new List<Workflow_Signal__c>();
    List<Id> instIds = new List<Id>();
    List<Boolean> runComp = new List<Boolean>();

    Boolean isEmpty() {
      return claims.isEmpty();
    }
  }

  /**
   * @description Keyed-cancel pre-pass: claims the keyed cancels in bulk, cancels
   * the freshly-claimed instances, then refreshes their cached statuses. A failed
   * cancel rolls the batch's claims back so the keys retry.
   * @param requests the signal requests to scan for keyed cancels
   * @param maps the by-id/by-key instance caches (statuses refreshed in place)
   * @return the ids driven to a terminal (non-wakeable) state by this pre-pass
   */
  public static Set<Id> processKeyedCancels(
    List<WorkflowEngine.SignalRequest> requests,
    WorkflowSignalBatch.SignalInstanceMaps maps
  ) {
    Set<Id> cancelledInstanceIds = new Set<Id>();
    KeyedCancelClaimBatch batch = collectCancelClaims(requests, maps);
    if (batch.isEmpty()) {
      return cancelledInstanceIds;
    }
    Savepoint cancelSp = Database.setSavepoint();
    Database.SaveResult[] claimResults = Database.insert(
      batch.claims,
      false,
      AccessLevel.SYSTEM_MODE
    );
    List<Integer> freshClaims = collectFreshClaimIndices(
      claimResults,
      cancelSp
    );
    Set<Id> attemptedCancelIds = runKeyedCancels(batch, freshClaims, cancelSp);
    refreshAfterKeyedCancels(attemptedCancelIds, maps, cancelledInstanceIds);
    return cancelledInstanceIds;
  }

  /**
   * @description Builds the keyed-cancel claim rows from the batch. In-batch
   * duplicates collapse via a seen-key set; cross-transaction duplicates lose the
   * unique-constraint race later and are skipped.
   * @param requests the signal requests to scan
   * @param maps the by-id/by-key instance caches
   * @return the parallel claim/instance/run-compensations lists to act on
   */
  private static KeyedCancelClaimBatch collectCancelClaims(
    List<WorkflowEngine.SignalRequest> requests,
    WorkflowSignalBatch.SignalInstanceMaps maps
  ) {
    KeyedCancelClaimBatch batch = new KeyedCancelClaimBatch();
    Set<String> seenCancelKeys = new Set<String>();
    for (WorkflowEngine.SignalRequest req : requests) {
      if (req == null) {
        continue;
      }
      if (
        String.isBlank(req.idempotencyKey) ||
        !WorkflowSignalHelpers.isCancelSignalName(req.signalName)
      ) {
        continue;
      }
      Workflow_Instance__c inst = WorkflowSignalBatch.resolveInstance(
        req,
        maps
      );
      if (inst == null) {
        continue; // unmatched keyed cancel already no-op'd above
      }
      String claimKey = WorkflowSignalDedup.deriveSignalDedupKey(
        inst.Id,
        req.idempotencyKey
      );
      if (seenCancelKeys.contains(claimKey)) {
        continue; // in-batch duplicate keyed cancel
      }
      seenCancelKeys.add(claimKey);
      batch.claims.add(
        new Workflow_Signal__c(
          Workflow_Instance__c = inst.Id,
          Signal_Name__c = req.signalName,
          Status__c = 'Consumed',
          Signal_Key__c = claimKey
        )
      );
      batch.instIds.add(inst.Id);
      batch.runComp.add(
        WorkflowSignalHelpers.parseRunCompensations(req.payload)
      );
    }
    return batch;
  }

  /**
   * @description Collects the indices of the freshly-claimed (won-the-race)
   * cancel rows. Concurrent-duplicate losers are skipped; on any genuine
   * (non-duplicate) insert error the batch is rolled back and a WorkflowException
   * is thrown.
   * @param claimResults the save results of the bulk claim insert
   * @param cancelSp the savepoint to roll back on a genuine failure
   * @return the indices (into the KeyedCancelClaimBatch) of the fresh claims
   */
  private static List<Integer> collectFreshClaimIndices(
    Database.SaveResult[] claimResults,
    Savepoint cancelSp
  ) {
    List<Integer> freshClaims = new List<Integer>();
    String claimError = null;
    for (Integer i = 0; i < claimResults.size(); i++) {
      Database.SaveResult sr = claimResults[i];
      if (sr.isSuccess()) {
        freshClaims.add(i);
        continue;
      }
      if (WorkflowStartService.isDuplicateSaveError(sr)) {
        continue;
      }
      if (claimError == null) {
        claimError = sr.getErrors()[0].getMessage();
      }
    }
    if (claimError != null) {
      Database.rollback(cancelSp);
      throw new WorkflowEngine.WorkflowException(
        'Failed to claim cancel: ' + claimError
      );
    }
    return freshClaims;
  }

  /**
   * @description Cancels each freshly-claimed instance in claim order. On any
   * failure the whole sub-batch's claims are rolled back and the error rethrown
   * so the keys can be retried.
   * @param batch the claim batch supplying instance ids and run-compensation flags
   * @param freshClaims the indices of the claims that won the race
   * @param cancelSp the savepoint to roll back on failure
   * @return the ids of the instances a cancel was attempted on
   */
  private static Set<Id> runKeyedCancels(
    KeyedCancelClaimBatch batch,
    List<Integer> freshClaims,
    Savepoint cancelSp
  ) {
    Set<Id> attemptedCancelIds = new Set<Id>();
    try {
      for (Integer i : freshClaims) {
        cancelInstance(batch.instIds[i], batch.runComp[i]);
        attemptedCancelIds.add(batch.instIds[i]);
      }
    } catch (Exception e) {
      Database.rollback(cancelSp);
      throw e;
    }
    return attemptedCancelIds;
  }

  /**
   * @description Refreshes the post-cancel statuses of the keyed-cancel sub-batch
   * in one query. A no-compensation cancel is terminal (Cancelled) and its
   * sibling signals must be skipped; a compensating cancel leaves the instance
   * Cancelling (still signalable), so the cached SObject is refreshed so the
   * forward loop wakes it rather than resurrecting it.
   * @param attemptedCancelIds the ids a cancel was attempted on
   * @param maps the by-id/by-key instance caches (statuses refreshed in place)
   * @param cancelledInstanceIds accumulates ids driven terminal (mutated)
   */
  private static void refreshAfterKeyedCancels(
    Set<Id> attemptedCancelIds,
    WorkflowSignalBatch.SignalInstanceMaps maps,
    Set<Id> cancelledInstanceIds
  ) {
    if (attemptedCancelIds.isEmpty()) {
      return;
    }
    for (Workflow_Instance__c refreshed : [
      SELECT Id, Status__c
      FROM Workflow_Instance__c
      WHERE Id IN :attemptedCancelIds
      WITH SYSTEM_MODE
    ]) {
      WorkflowSignalHelpers.refreshCachedStatus(maps.instById, refreshed);
      if (!WorkflowSignalHelpers.isWakeableStatus(refreshed.Status__c)) {
        cancelledInstanceIds.add(refreshed.Id);
      }
    }
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
