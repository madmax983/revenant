/**
 * @description Bulk resolution of the "Signal or Start" invocable's invalid-input
 * rows, extracted from {@link WorkflowSignalOrStartInvocableAction} so each class
 * stays within the repo's per-class complexity budget. Resolves ALL deferred
 * invalid-input rows with ONE bulk key lookup plus at most ONE bulk signal
 * delivery — no per-row scalar engine calls, so the suspect path is
 * governor-bounded (no per-row savepoint exhaustion) regardless of count.
 */
public inherited sharing class WorkflowSignalOrStartSuspects {
  /**
   * @description Collector for the invalid-input rows deferred past the clean bulk
   * call: the invocable request, its original result index, and its pre-computed
   * contract violations, kept index-aligned.
   */
  public class SuspectRows {
    public final List<WorkflowSignalOrStartInvocableAction.SignalOrStartRequest> requests = new List<WorkflowSignalOrStartInvocableAction.SignalOrStartRequest>();
    public final List<Integer> indices = new List<Integer>();
    public final List<List<WorkflowInputFieldError>> errors = new List<List<WorkflowInputFieldError>>();

    /**
     * @description Adds one deferred invalid-input row.
     * @param req the invocable signal-or-start request
     * @param index its original index in the results list
     * @param rowErrors its pre-computed contract violations
     */
    public void add(
      WorkflowSignalOrStartInvocableAction.SignalOrStartRequest req,
      Integer index,
      List<WorkflowInputFieldError> rowErrors
    ) {
      this.requests.add(req);
      this.indices.add(index);
      this.errors.add(rowErrors);
    }
  }

  /**
   * @description Resolves all collected invalid-input rows: a row whose correlation
   * key resolves (via ONE bulk lookup that sees the clean batch's just-inserted
   * rows) to an existing instance delivers its signal there (via ONE bulk
   * signalOrStart — all dedup hits, so no new starts and no validation); a row
   * whose key has no instance is a genuine new start with invalid input, rejected
   * in memory with no engine call.
   * @param suspects the collected invalid-input rows
   * @param results the result list to populate in place
   */
  public static void resolve(
    SuspectRows suspects,
    List<WorkflowSignalOrStartInvocableAction.SignalOrStartResult> results
  ) {
    if (suspects.requests.isEmpty()) {
      return;
    }
    Map<String, Workflow_Instance__c> existingByKey = lookupExisting(
      suspects.requests
    );

    List<WorkflowEngine.SignalOrStartRequest> deliverReqs = new List<WorkflowEngine.SignalOrStartRequest>();
    List<Integer> deliverIndices = new List<Integer>();
    for (Integer s = 0; s < suspects.requests.size(); s++) {
      if (isDedupHit(suspects.requests[s], existingByKey)) {
        deliverReqs.add(toDeliveryRequest(suspects.requests[s]));
        deliverIndices.add(suspects.indices[s]);
      } else {
        // Genuine new start with invalid input — rejected in memory, no engine call.
        results[
          suspects.indices[s]
        ] = WorkflowSignalOrStartResults.invalidResult(
          WorkflowInputValidator.describeErrors(suspects.errors[s])
        );
      }
    }

    deliverSignals(deliverReqs, deliverIndices, results);
  }

  // True when the row's correlation key resolves to an existing instance
  // (pre-existing or an intra-batch just-inserted sibling).
  private static Boolean isDedupHit(
    WorkflowSignalOrStartInvocableAction.SignalOrStartRequest req,
    Map<String, Workflow_Instance__c> existingByKey
  ) {
    return String.isNotBlank(req.correlationKey) &&
      existingByKey.containsKey(WorkflowKeys.normalizeKey(req.correlationKey));
  }

  // ONE bulk key lookup via the engine's shared dedup resolver (WITH SYSTEM_MODE).
  private static Map<String, Workflow_Instance__c> lookupExisting(
    List<WorkflowSignalOrStartInvocableAction.SignalOrStartRequest> requests
  ) {
    Set<String> keys = new Set<String>();
    for (
      WorkflowSignalOrStartInvocableAction.SignalOrStartRequest req : requests
    ) {
      if (String.isNotBlank(req.correlationKey)) {
        keys.add(req.correlationKey);
      }
    }
    return keys.isEmpty()
      ? new Map<String, Workflow_Instance__c>()
      : WorkflowStartDedup.findExistingByKey(keys);
  }

  // Delivers all dedup-hit signals in ONE bulk signalOrStart (no new starts, no
  // validation, one savepoint), mapping each result back to its originating row.
  private static void deliverSignals(
    List<WorkflowEngine.SignalOrStartRequest> deliverReqs,
    List<Integer> deliverIndices,
    List<WorkflowSignalOrStartInvocableAction.SignalOrStartResult> results
  ) {
    if (deliverReqs.isEmpty()) {
      return;
    }
    List<WorkflowEngine.StartResult> deliverResults = WorkflowEngine.signalOrStart(
      deliverReqs
    );
    for (Integer d = 0; d < deliverResults.size(); d++) {
      results[deliverIndices[d]] = WorkflowSignalOrStartResults.deliveredResult(
        deliverResults[d]
      );
    }
  }

  // Builds a signal-delivery request for a dedup-hit suspect: it carries the RAW
  // input JSON without parsing (the fallback input is never persisted on a dedup
  // hit, so a malformed payload cannot fault here) plus the signal to land on the
  // existing instance.
  private static WorkflowEngine.SignalOrStartRequest toDeliveryRequest(
    WorkflowSignalOrStartInvocableAction.SignalOrStartRequest req
  ) {
    WorkflowEngine.StartRequest startReq = new WorkflowEngine.StartRequest(
      req.workflowName,
      req.correlationKey,
      null
    );
    startReq.inputJson = req.inputJson;
    startReq.causationId = req.causationId;
    return new WorkflowEngine.SignalOrStartRequest(
        startReq,
        req.signalName,
        req.payloadJson
      )
      .withIdempotencyKey(req.idempotencyKey);
  }
}
