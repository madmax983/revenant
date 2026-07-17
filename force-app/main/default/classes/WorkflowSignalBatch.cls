/**
 * @description Bulk signal routing entry point and intake phase for the
 * durable-execution engine's exactly-once signal delivery. Orchestrates the six
 * ordered phases of `signal(List)`, preserving the original all-or-none and
 * in-batch cancel-before-sibling semantics: classify targets, FOR UPDATE-lock
 * and load the addressed instances, capture unmatched requests as Unrouted, run
 * the bulk keyed-cancel claim-before-apply pre-pass (`WorkflowSignalBatchCancel`),
 * partition the forward signals (`WorkflowSignalBatchPartition`), then insert the
 * rows and wake the fresh-signalled instances under one savepoint
 * (`WorkflowSignalBatchWake`). This class owns the intake (classify/load/resolve/
 * capture) and the shared `SignalInstanceMaps` cache. All DML/SOQL runs in system
 * mode.
 */
public inherited sharing class WorkflowSignalBatch {
  /** Partitions the batch's request key/id strings into instance ids and keys. */
  private class SignalTargets {
    Set<Id> ids = new Set<Id>();
    Set<String> keys = new Set<String>();
  }

  /**
   * @description The by-id (and 15-char) and by-normalized-key caches of the
   * FOR UPDATE-locked instances. Public (with public fields) so the extracted
   * keyed-cancel and partition phase classes can resolve and refresh instances
   * against one shared cache; carries no static members.
   */
  public class SignalInstanceMaps {
    public Map<String, Workflow_Instance__c> instById = new Map<String, Workflow_Instance__c>();
    public Map<String, Workflow_Instance__c> instByKey = new Map<String, Workflow_Instance__c>();
  }

  /**
   * @description Sends external signals to multiple workflow instances in bulk.
   * Orchestrates the six phases (in order, preserving the original all-or-none
   * and in-batch cancel-before-sibling semantics): classify targets, lock/load
   * instances, capture unmatched requests, run the keyed-cancel pre-pass,
   * partition the forward signals, insert the rows, then wake and enqueue.
   * @param requests the signal requests to deliver
   */
  public static void routeSignalBatch(
    List<WorkflowEngine.SignalRequest> requests
  ) {
    if (requests == null || requests.isEmpty()) {
      return;
    }
    SignalTargets targets = classifyRequestTargets(requests);
    SignalInstanceMaps maps = loadSignalableInstances(
      targets.ids,
      targets.keys
    );
    captureUnmatchedRequests(requests, maps);
    Set<Id> cancelledInstanceIds = WorkflowSignalBatchCancel.processKeyedCancels(
      requests,
      maps
    );
    WorkflowSignalBatchPartition.ForwardSignalPartition partition = WorkflowSignalBatchPartition.partitionForwardSignals(
      requests,
      maps,
      cancelledInstanceIds
    );
    System.Savepoint sp = WorkflowSignalBatchWake.insertSignalRows(partition);
    WorkflowSignalBatchWake.wakeAndEnqueueInstances(partition, sp);
  }

  /**
   * @description Partitions the batch's request identifiers into workflow-instance
   * ids (18/15-char key-prefixed) and correlation keys for the load query.
   * @param requests the signal requests to classify
   * @return the collected ids and keys
   */
  private static SignalTargets classifyRequestTargets(
    List<WorkflowEngine.SignalRequest> requests
  ) {
    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');
    SignalTargets targets = new SignalTargets();
    for (WorkflowEngine.SignalRequest req : requests) {
      if (req == null || String.isBlank(req.keyOrId)) {
        continue;
      }
      if (
        idPattern.matcher(req.keyOrId).matches() &&
        req.keyOrId.startsWith(wflowPrefix)
      ) {
        targets.ids.add((Id) req.keyOrId);
      } else {
        targets.keys.add(req.keyOrId);
      }
    }
    return targets;
  }

  /**
   * @description Loads and FOR UPDATE-locks every signalable instance addressed
   * by the batch and builds the by-id/by-key caches. Includes CompensationFailed
   * so a Cancel signal can reach a stalled rollback; the per-request guards
   * downstream still reject non-cancel signals to a stalled instance, preserving
   * active-only semantics for everything except cancellation.
   * @param ids the workflow-instance ids to lock
   * @param keys the correlation keys to lock
   * @return the by-id (and 15-char) and by-normalized-key instance caches
   */
  private static SignalInstanceMaps loadSignalableInstances(
    Set<Id> ids,
    Set<String> keys
  ) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Status__c,
        Correlation_Key__c,
        Current_Step__c,
        Compensation_Stack__c,
        Concurrency_Parked__c,
        Concurrency_Slot_Held__c,
        Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE
        (Id IN :ids
        OR Correlation_Key__c IN :keys)
        AND Status__c IN (
          'Pending',
          'Running',
          'Suspended',
          'Compensating',
          'Cancelling',
          'CompensationFailed',
          'Paused'
        )
      WITH SYSTEM_MODE
      FOR UPDATE
    ];

    SignalInstanceMaps maps = new SignalInstanceMaps();
    for (Workflow_Instance__c inst : instances) {
      maps.instById.put(inst.Id, inst);
      String idStr = String.valueOf(inst.Id);
      if (idStr.length() == 18) {
        maps.instById.put(idStr.substring(0, 15), inst);
      }
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        // Key by the normalized (lower-cased) correlation key: SOQL matched the
        // instance case-insensitively, so a request addressed as 'order-1' must
        // resolve the instance stored as 'Order-1' rather than miss the map and
        // be treated as unmatched (which would skip a keyed cancel entirely).
        maps.instByKey.put(
          WorkflowKeys.normalizeKey(inst.Correlation_Key__c),
          inst
        );
      }
    }
    return maps;
  }

  /**
   * @description Resolves the locked instance a request addresses, by id first
   * then by normalized correlation key. Public so the keyed-cancel and partition
   * phase classes resolve against the same shared cache.
   * @param req the request whose target to resolve
   * @param maps the by-id/by-key instance caches
   * @return the matched instance, or null when none was loaded/locked
   */
  public static Workflow_Instance__c resolveInstance(
    WorkflowEngine.SignalRequest req,
    SignalInstanceMaps maps
  ) {
    Workflow_Instance__c inst = maps.instById.get(req.keyOrId);
    if (inst == null) {
      inst = maps.instByKey.get(WorkflowKeys.normalizeKey(req.keyOrId));
    }
    return inst;
  }

  /**
   * @description Separates requests with no active match: non-cancel misses are
   * captured as Unrouted for replay; an unkeyed cancel miss throws (capturing a
   * cancel for an unknown future instance is unsafe); a keyed cancel miss is an
   * idempotent no-op. Throws before any keyed-cancel work, exactly as the
   * original loop.
   * @param requests the signal requests to screen
   * @param maps the by-id/by-key instance caches
   */
  private static void captureUnmatchedRequests(
    List<WorkflowEngine.SignalRequest> requests,
    SignalInstanceMaps maps
  ) {
    List<WorkflowEngine.SignalRequest> unmatchedToCapture = new List<WorkflowEngine.SignalRequest>();
    for (WorkflowEngine.SignalRequest req : requests) {
      if (req == null) {
        continue;
      }
      collectUnmatchedRequest(req, maps, unmatchedToCapture);
    }
    WorkflowUnroutedCapture.captureUnroutedSignals(unmatchedToCapture);
  }

  /**
   * @description Classifies a single request against the loaded instances and
   * either records it for Unrouted capture, no-ops it (keyed cancel miss), or
   * throws (unkeyed cancel miss). Guard-clause flattened; behavior matches the
   * original nested branches exactly.
   * @param req the request to classify
   * @param maps the by-id/by-key instance caches
   * @param unmatchedToCapture accumulator for non-cancel misses (mutated)
   */
  private static void collectUnmatchedRequest(
    WorkflowEngine.SignalRequest req,
    SignalInstanceMaps maps,
    List<WorkflowEngine.SignalRequest> unmatchedToCapture
  ) {
    Workflow_Instance__c inst = resolveInstance(req, maps);
    Boolean isCancel = WorkflowSignalHelpers.isCancelSignalName(req.signalName);
    Boolean unmatched =
      inst == null || (inst.Status__c == 'CompensationFailed' && !isCancel);
    if (!unmatched) {
      return;
    }
    if (!isCancel) {
      unmatchedToCapture.add(req);
      return;
    }
    if (String.isNotBlank(req.idempotencyKey)) {
      return; // keyed cancel, no active match: idempotent no-op
    }
    throw new WorkflowEngine.WorkflowException(
      'No active workflow found with key or ID: ' + req.keyOrId
    );
  }
}
