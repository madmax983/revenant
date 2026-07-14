/**
 * @description Parses resolved prior-execution rows into the patch/completion
 * caches, split out of StepCaptures / StepExecutionIndex. Pure functions that
 * derive the completed-visit markers and prior __patch: decisions from a batch of
 * Workflow_Step_Execution__c rows and their resolved captured-values payloads,
 * returned as a ParseResult the index merges into its caches.
 */
public inherited sharing class StepExecutionParse {
  /**
   * @description Derived prior-execution index: completed-visit markers and prior
   * __patch: decisions parsed from a batch of executions.
   */
  public class ParseResult {
    /** Per-visit completion markers ("<step>:<visit>") from prior executions. */
    public Set<String> completedSteps = new Set<String>();
    /** Prior __patch: decisions recorded by earlier steps in this instance. */
    public Map<String, Boolean> patchDecisions = new Map<String, Boolean>();
  }

  /**
   * @description Resolves offloaded captured-values payloads in small batches to
   * stay under Apex Heap Limits (synchronous cap is 6 MB).
   * @param executions The step executions whose Captured_Values__c to resolve.
   * @return The resolved captured-values payloads, aligned to executions.
   */
  public static List<String> resolveCapturePayloads(
    List<Workflow_Step_Execution__c> executions
  ) {
    List<String> rawCaptures = new List<String>();
    for (Workflow_Step_Execution__c exec : executions) {
      rawCaptures.add(exec.Captured_Values__c);
    }
    Integer batchSize = 40;
    List<String> resolvedCaptures = new List<String>();
    for (Integer i = 0; i < rawCaptures.size(); i += batchSize) {
      List<String> batchRaw = new List<String>();
      for (Integer j = i; j < i + batchSize && j < rawCaptures.size(); j++) {
        batchRaw.add(rawCaptures[j]);
      }
      resolvedCaptures.addAll(WorkflowPayloadOffload.resolvePayloads(batchRaw));
    }
    return resolvedCaptures;
  }

  /**
   * @description Derives the completed-visit markers and prior __patch: decisions
   * from the resolved captures.
   * @param executions The step executions in sorted order.
   * @param resolvedCaptures The resolved captured-values payloads, aligned to
   * executions.
   * @return The parsed completion markers and patch decisions.
   */
  public static ParseResult parse(
    List<Workflow_Step_Execution__c> executions,
    List<String> resolvedCaptures
  ) {
    ParseResult result = new ParseResult();
    Map<String, Integer> completedCounts = new Map<String, Integer>();
    for (Integer i = 0; i < executions.size(); i++) {
      recordCompletedVisit(
        executions[i],
        completedCounts,
        result.completedSteps
      );
      mergePatchDecisions(resolvedCaptures[i], result.patchDecisions);
    }
    return result;
  }

  /**
   * @description Records a per-visit completion marker for a completed/skipped
   * execution, tracking the running visit count per step name.
   * @param exec The execution row to record.
   * @param completedCounts The running per-step completed-visit counts.
   * @param completedSteps The per-visit completion marker set to populate.
   */
  private static void recordCompletedVisit(
    Workflow_Step_Execution__c exec,
    Map<String, Integer> completedCounts,
    Set<String> completedSteps
  ) {
    if (exec.Status__c != 'Completed' && exec.Status__c != 'OperatorSkipped') {
      return;
    }
    Integer visit = completedCounts.containsKey(exec.Step_Name__c)
      ? completedCounts.get(exec.Step_Name__c)
      : 0;
    completedSteps.add(exec.Step_Name__c + ':' + visit);
    completedCounts.put(exec.Step_Name__c, visit + 1);
  }

  /**
   * @description Merges any recorded __patch: decisions from a resolved captures
   * payload into the patch-decisions map, ignoring malformed JSON.
   * @param capturesJson The resolved captured-values JSON for one execution.
   * @param patchDecisions The prior __patch: decision map to populate.
   */
  private static void mergePatchDecisions(
    String capturesJson,
    Map<String, Boolean> patchDecisions
  ) {
    if (String.isBlank(capturesJson) || !capturesJson.contains('__patch:')) {
      return;
    }
    try {
      Map<String, Object> captures = (Map<String, Object>) JSON.deserializeUntyped(
        capturesJson
      );
      for (String k : captures.keySet()) {
        if (k.startsWith('__patch:')) {
          patchDecisions.put(k.substring(8), (Boolean) captures.get(k));
        }
      }
    } catch (Exception ignored) {
      // Ignore malformed JSON
    }
  }
}
