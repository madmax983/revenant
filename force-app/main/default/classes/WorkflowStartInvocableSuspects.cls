/**
 * @description Bulk resolution of the "Start Workflow" invocable's invalid-input
 * rows, extracted from {@link WorkflowStartInvocableRouter} so each class stays
 * within the repo's per-class complexity budget. Resolves ALL deferred
 * invalid-input rows with ONE bulk key lookup (no per-row engine call), so the
 * suspect path is governor-bounded regardless of count.
 */
public inherited sharing class WorkflowStartInvocableSuspects {
  /**
   * @description Collector for the invalid-input rows deferred past the clean bulk
   * call: the invocable request, its original result index, and its pre-computed
   * contract violations, kept index-aligned.
   */
  public class SuspectRows {
    public final List<WorkflowStartInvocableAction.StartRequest> requests = new List<WorkflowStartInvocableAction.StartRequest>();
    public final List<Integer> indices = new List<Integer>();
    public final List<List<WorkflowInputFieldError>> errors = new List<List<WorkflowInputFieldError>>();

    /**
     * @description Adds one deferred invalid-input row.
     * @param req the invocable start request
     * @param index its original index in the results list
     * @param rowErrors its pre-computed contract violations
     */
    public void add(
      WorkflowStartInvocableAction.StartRequest req,
      Integer index,
      List<WorkflowInputFieldError> rowErrors
    ) {
      this.requests.add(req);
      this.indices.add(index);
      this.errors.add(rowErrors);
    }
  }

  /**
   * @description Resolves all collected invalid-input rows and writes each result
   * back at its original index. A same-transaction SOQL sees the clean batch's
   * just-inserted rows, so a row whose correlation key matches a pre-existing OR an
   * intra-batch valid sibling is delivered to that instance (isValid=true); a row
   * whose key has no instance is a genuine new start with invalid input
   * (isValid=false — no engine call, since starting it would only create a failing
   * instance).
   * @param suspects the collected invalid-input rows
   * @param results the result list to populate in place
   */
  public static void resolve(
    SuspectRows suspects,
    List<WorkflowStartInvocableAction.StartResult> results
  ) {
    if (suspects.requests.isEmpty()) {
      return;
    }
    Map<String, Workflow_Instance__c> existingByKey = lookupExisting(
      suspects.requests
    );
    for (Integer s = 0; s < suspects.requests.size(); s++) {
      results[suspects.indices[s]] = classify(
        suspects.requests[s],
        existingByKey,
        suspects.errors[s]
      );
    }
  }

  // ONE bulk key lookup via the engine's shared dedup resolver (WITH SYSTEM_MODE),
  // bounded regardless of how many suspect rows there are.
  private static Map<String, Workflow_Instance__c> lookupExisting(
    List<WorkflowStartInvocableAction.StartRequest> requests
  ) {
    Set<String> keys = new Set<String>();
    for (WorkflowStartInvocableAction.StartRequest req : requests) {
      if (String.isNotBlank(req.correlationKey)) {
        keys.add(req.correlationKey);
      }
    }
    return keys.isEmpty()
      ? new Map<String, Workflow_Instance__c>()
      : WorkflowStartDedup.findExistingByKey(keys);
  }

  // A dedup hit (existing instance) is delivered; otherwise the row is a genuine
  // new start with invalid input and is rejected in memory.
  private static WorkflowStartInvocableAction.StartResult classify(
    WorkflowStartInvocableAction.StartRequest req,
    Map<String, Workflow_Instance__c> existingByKey,
    List<WorkflowInputFieldError> rowErrors
  ) {
    if (String.isNotBlank(req.correlationKey)) {
      Workflow_Instance__c hit = existingByKey.get(
        WorkflowKeys.normalizeKey(req.correlationKey)
      );
      if (hit != null) {
        return WorkflowStartInvocableResults.dedupHitResult(hit.Id);
      }
    }
    return WorkflowStartInvocableResults.invalidResult(
      WorkflowInputValidator.describeErrors(rowErrors)
    );
  }
}
