/**
 * @description Forward-signal partition phase for the durable-execution engine's
 * `signal(List)` path. Partitions the forward (non-keyed-cancel) signals into the
 * unkeyed and keyed rows to insert, records which instances are wakeable and
 * which signal names each received (for the join-readiness gate), and runs any
 * in-batch unkeyed cancels in request order so their result is visible to later
 * siblings in the same batch. Unkeyed signals keep at-least-once behavior; keyed
 * signals dedup in-batch on the per-instance composite key (the unique constraint
 * handles concurrent transactions). The accumulated `ForwardSignalPartition` is
 * handed to `WorkflowSignalBatchWake` for the insert-and-wake phase. All DML/SOQL
 * runs in system mode.
 */
public inherited sharing class WorkflowSignalBatchPartition {
  /**
   * @description Accumulated state of the forward-signal partition pass. Public
   * (with public fields) so the extracted insert-and-wake phase class can read
   * the staged rows, wakeable instances and fresh-signal sets; carries no static
   * members.
   */
  public class ForwardSignalPartition {
    public List<Workflow_Signal__c> unkeyedSignals = new List<Workflow_Signal__c>();
    public Set<String> seenCompositeKeys = new Set<String>();
    public List<Workflow_Signal__c> keyedSignals = new List<Workflow_Signal__c>();
    public List<Id> keyedSignalInstIds = new List<Id>();
    public Map<Id, Workflow_Instance__c> activeInstById = new Map<Id, Workflow_Instance__c>();
    public Set<Id> instancesWithUnkeyedSignal = new Set<Id>();
    public Map<Id, Set<String>> signalsByInstanceId = new Map<Id, Set<String>>();
    public Set<Id> instancesWithFreshKeyedSignal = new Set<Id>();
    // Instances driven terminal by an in-batch cancel; siblings are skipped.
    public Set<Id> cancelledInstanceIds = new Set<Id>();
  }

  /**
   * @description Partitions the forward (non-keyed-cancel) signals into the
   * unkeyed and keyed rows to insert, records which instances are wakeable, and
   * runs any in-batch unkeyed cancels in request order so their result is visible
   * to later siblings in the same batch.
   * @param requests the signal requests to partition
   * @param maps the by-id/by-key instance caches
   * @param cancelledInstanceIds ids already driven terminal by the keyed pre-pass
   * @return the accumulated forward-signal partition
   */
  public static ForwardSignalPartition partitionForwardSignals(
    List<WorkflowEngine.SignalRequest> requests,
    WorkflowSignalBatch.SignalInstanceMaps maps,
    Set<Id> cancelledInstanceIds
  ) {
    ForwardSignalPartition part = new ForwardSignalPartition();
    part.cancelledInstanceIds = cancelledInstanceIds;
    for (WorkflowEngine.SignalRequest req : requests) {
      if (req == null) {
        continue;
      }
      partitionOneForwardSignal(req, maps, part);
    }
    return part;
  }

  /**
   * @description Handles one forward request: records the signal name for
   * join-readiness, skips siblings of an instance a prior in-batch cancel drove
   * terminal, runs an in-batch unkeyed cancel (refreshing status for later
   * siblings), or stages the signal row. Guard-clause flattened; matches the
   * original nesting exactly.
   * @param req the request to handle
   * @param maps the by-id/by-key instance caches
   * @param part the partition accumulator (mutated)
   */
  private static void partitionOneForwardSignal(
    WorkflowEngine.SignalRequest req,
    WorkflowSignalBatch.SignalInstanceMaps maps,
    ForwardSignalPartition part
  ) {
    Workflow_Instance__c inst = WorkflowSignalBatch.resolveInstance(req, maps);
    if (inst != null) {
      if (!part.signalsByInstanceId.containsKey(inst.Id)) {
        part.signalsByInstanceId.put(inst.Id, new Set<String>());
      }
      part.signalsByInstanceId.get(inst.Id).add(req.signalName);
    }
    if (inst == null) {
      return;
    }
    // A cancel earlier in this batch already drove this instance terminal; the
    // cached SObject is stale, so skip every sibling signal for it rather than
    // acting on the pre-cancel status and resurrecting a Cancelled workflow.
    if (part.cancelledInstanceIds.contains(inst.Id)) {
      return;
    }
    Boolean isCancel =
      req.signalName.equalsIgnoreCase('Cancel') ||
      req.signalName.equalsIgnoreCase('CancelWorkflow');
    if (inst.Status__c == 'CompensationFailed' && !isCancel) {
      return;
    }
    if (isCancel) {
      if (String.isNotBlank(req.idempotencyKey)) {
        return; // keyed cancel handled in the bulk-claim pre-pass above
      }
      cancelInstance(
        inst.Id,
        WorkflowSignalHelpers.parseRunCompensations(req.payload)
      );
      refreshAfterUnkeyedCancel(inst, maps.instById, part.cancelledInstanceIds);
      return;
    }
    addForwardSignalRow(req, inst, part);
  }

  /**
   * @description Stages a forward signal row (Received). Unkeyed signals keep
   * at-least-once behavior; keyed signals dedup in-batch on the per-instance
   * composite key (the unique constraint handles concurrent transactions).
   * Wakeable instances are recorded for the wake phase.
   * @param req the request supplying the signal name/payload/idempotency key
   * @param inst the resolved target instance
   * @param part the partition accumulator (mutated)
   */
  private static void addForwardSignalRow(
    WorkflowEngine.SignalRequest req,
    Workflow_Instance__c inst,
    ForwardSignalPartition part
  ) {
    Workflow_Signal__c sig = new Workflow_Signal__c(
      Workflow_Instance__c = inst.Id,
      Signal_Name__c = req.signalName,
      Payload__c = req.payload,
      Status__c = 'Received'
    );

    Boolean isWakeable =
      inst.Status__c == 'Suspended' ||
      inst.Status__c == 'Running' ||
      inst.Status__c == 'Compensating' ||
      inst.Status__c == 'Cancelling';

    if (String.isBlank(req.idempotencyKey)) {
      // Unkeyed signal: at-least-once behavior unchanged.
      part.unkeyedSignals.add(sig);
      if (isWakeable) {
        part.activeInstById.put(inst.Id, inst);
        part.instancesWithUnkeyedSignal.add(inst.Id);
      }
      return;
    }

    // Keyed signal: compute per-instance hash for unique-constraint dedup.
    // In-batch dedup skips later duplicates with the same composite key.
    String compositeKey = WorkflowSignalDedup.deriveSignalDedupKey(
      inst.Id,
      req.idempotencyKey
    );
    if (part.seenCompositeKeys.contains(compositeKey)) {
      return; // in-batch duplicate — skip entirely (no row, no wake-up)
    }
    part.seenCompositeKeys.add(compositeKey);
    sig.Signal_Key__c = compositeKey;
    part.keyedSignals.add(sig);
    part.keyedSignalInstIds.add(inst.Id);
    if (isWakeable) {
      part.activeInstById.put(inst.Id, inst);
    }
  }

  /**
   * @description Refreshes the cached status of an instance immediately after an
   * in-batch unkeyed cancel in the forward loop, and records it in
   * cancelledInstanceIds when the cancel drove it to a terminal (non-wakeable)
   * state so later sibling signals in the same batch skip it.
   * <p><b>Intentional per-iteration SOQL — order-dependent, MUST stay in the
   * loop.</b> This runs one targeted SOQL query per unkeyed cancel because its
   * result is read by <i>later iterations of the same request loop</i> (via
   * cancelledInstanceIds and the refreshed cache): hoisting it out of the loop
   * would break the in-batch cancel&rarr;sibling ordering and could resurrect a
   * Cancelled workflow (waking a stale Suspended SObject back to Running). It
   * therefore cannot be bulkified without changing behavior. Its query count
   * grows linearly (O(n)) with the number of unkeyed cancels, staying in the same
   * cost class as the per-instance cancel path it pairs with.
   * @param inst the just-cancelled instance whose cached status to refresh
   * @param instById the by-id/by-15-char instance cache to update in place
   * @param cancelledInstanceIds accumulates ids driven terminal by this batch
   */
  private static void refreshAfterUnkeyedCancel(
    Workflow_Instance__c inst,
    Map<String, Workflow_Instance__c> instById,
    Set<Id> cancelledInstanceIds
  ) {
    for (Workflow_Instance__c refreshed : [
      SELECT Id, Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
      WITH SYSTEM_MODE
    ]) {
      WorkflowSignalHelpers.refreshCachedStatus(instById, refreshed);
      if (!WorkflowSignalHelpers.isWakeableStatus(refreshed.Status__c)) {
        cancelledInstanceIds.add(inst.Id);
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
