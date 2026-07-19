/**
 * @description Verb-aware routing for the "Start Workflow" invocable
 * ({@link WorkflowStartInvocableAction}), extracted so the invocable stays a thin
 * request/result adapter while this class carries the get-or-start dedup routing.
 * Request translation and single-row suspect delegation live in
 * {@link WorkflowStartInvocableRequests}; result building in
 * {@link WorkflowStartInvocableResults}.
 *
 * "Start Workflow" is a GET-OR-START verb (it dedups on the correlation key), so
 * input-contract validation (INV-51) is applied only where a new instance would
 * actually be created:
 * - Contract-valid rows are batched through one {@link WorkflowEngine#startOrGet}
 *   bulk call FIRST (they never trip fresh-start validation).
 * - Contract-invalid rows are then delegated to the engine individually, so a row
 *   that resolves to an EXISTING instance — pre-existing OR one just created by a
 *   same-key valid sibling in this batch — is delivered (isValid=true; its unused
 *   fallback is never persisted), while a genuine new start is rejected with a
 *   branchable isValid=false (no Flow fault, no insert).
 * - Debounce rows arm a future sweep-time startOrGet and are not pre-validated.
 * Per-row results stay aligned to the original request order throughout.
 */
public inherited sharing class WorkflowStartInvocableRouter {
  /**
   * @description Routes each start request to a result, preserving input order.
   * @param requests the invocable start requests (assumed non-null/non-empty)
   * @return one result per request, index-aligned to the input
   */
  public static List<WorkflowStartInvocableAction.StartResult> route(
    List<WorkflowStartInvocableAction.StartRequest> requests
  ) {
    List<WorkflowStartInvocableAction.StartResult> results = new List<WorkflowStartInvocableAction.StartResult>();
    for (Integer i = 0; i < requests.size(); i++) {
      results.add(null);
    }

    List<WorkflowEngine.StartRequest> cleanEngineRequests = new List<WorkflowEngine.StartRequest>();
    List<Integer> cleanEngineIndices = new List<Integer>();
    List<WorkflowDebouncer.DebounceRequest> debounceRequests = new List<WorkflowDebouncer.DebounceRequest>();
    SuspectRows suspects = new SuspectRows();

    for (Integer i = 0; i < requests.size(); i++) {
      WorkflowStartInvocableAction.StartRequest req = requests[i];
      if (req == null) {
        results[i] = WorkflowStartInvocableResults.nullResult();
        continue;
      }
      if (req.debounceSeconds != null) {
        // Debounce wraps a dedup verb (sweep-time startOrGet): don't pre-validate.
        debounceRequests.add(
          WorkflowStartInvocableRequests.toDebounceRequest(req)
        );
        results[i] = WorkflowStartInvocableResults.debouncedResult();
        continue;
      }
      List<WorkflowInputFieldError> inputErrors = WorkflowInputValidator.collectErrors(
        WorkflowStartInvocableRequests.toValidationProbe(req)
      );
      if (inputErrors.isEmpty()) {
        cleanEngineRequests.add(
          WorkflowStartInvocableRequests.toEngineRequest(req)
        );
        cleanEngineIndices.add(i);
      } else {
        suspects.add(req, i, inputErrors);
      }
    }

    if (!debounceRequests.isEmpty()) {
      WorkflowDebouncer.startDebounced(debounceRequests);
    }

    // Create the valid rows' instances FIRST (one bulk call), so an invalid row
    // sharing a correlation key can dedup-resolve to the just-created sibling.
    applyCleanStartResults(cleanEngineRequests, cleanEngineIndices, results);

    // Then resolve the invalid-input rows individually against the now-existing
    // instances (intra-batch siblings included), preserving each row's index.
    resolveSuspectStarts(suspects, results);

    return results;
  }

  /**
   * @description Collector for the invalid-input rows deferred past the clean bulk
   * call: the invocable request, its original result index, and its pre-computed
   * contract violations, kept index-aligned.
   */
  private class SuspectRows {
    final List<WorkflowStartInvocableAction.StartRequest> requests = new List<WorkflowStartInvocableAction.StartRequest>();
    final List<Integer> indices = new List<Integer>();
    final List<List<WorkflowInputFieldError>> errors = new List<List<WorkflowInputFieldError>>();

    void add(
      WorkflowStartInvocableAction.StartRequest req,
      Integer index,
      List<WorkflowInputFieldError> rowErrors
    ) {
      this.requests.add(req);
      this.indices.add(index);
      this.errors.add(rowErrors);
    }
  }

  // Runs the batched get-or-start for the contract-valid rows in one bulk call and
  // maps each result back to its original index with isValid=true.
  private static void applyCleanStartResults(
    List<WorkflowEngine.StartRequest> cleanEngineRequests,
    List<Integer> cleanEngineIndices,
    List<WorkflowStartInvocableAction.StartResult> results
  ) {
    if (cleanEngineRequests.isEmpty()) {
      return;
    }
    List<WorkflowEngine.StartResult> engineResults = WorkflowEngine.startOrGet(
      cleanEngineRequests
    );
    for (Integer j = 0; j < engineResults.size(); j++) {
      results[
        cleanEngineIndices[j]
      ] = WorkflowStartInvocableResults.startedResult(engineResults[j]);
    }
  }

  // Resolves each collected invalid-input row individually (after the clean batch)
  // and writes the result back at the row's original index.
  private static void resolveSuspectStarts(
    SuspectRows suspects,
    List<WorkflowStartInvocableAction.StartResult> results
  ) {
    for (Integer s = 0; s < suspects.requests.size(); s++) {
      results[
        suspects.indices[s]
      ] = WorkflowStartInvocableRequests.resolveSuspectStart(
        suspects.requests[s],
        suspects.errors[s]
      );
    }
  }
}
