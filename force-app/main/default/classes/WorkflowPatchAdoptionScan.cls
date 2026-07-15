/**
 * @description Per-chunk step-execution scan phase for {@link WorkflowPatchAdoption}.
 * Given the active instance population, this class walks it in 1,000-instance
 * chunks, resolves each chunk's captured-values payloads (rehydrating offloaded
 * payloads through {@link WorkflowPayloadOffload}) and records which workflows
 * observed the patch key and which instances recorded an explicit `false`
 * decision. Split out from `WorkflowPatchAdoption` so each cohesive phase stays
 * within its own complexity budget. All SOQL executes in system mode.
 */
public inherited sharing class WorkflowPatchAdoptionScan {
  /**
   * @description Scans the active instances in 1,000-instance chunks, marking on
   * the supplied accumulator which workflows recorded the patch key and which
   * instances recorded an explicit `false`.
   * @param instances the active instance population
   * @param scan the mutable accumulator collecting scan results
   */
  public static void scanInstancesForExplicitFalse(
    List<Workflow_Instance__c> instances,
    WorkflowPatchAdoption.AdoptionScan scan
  ) {
    Integer instanceBatchSize = 1000;
    for (Integer i = 0; i < instances.size(); i += instanceBatchSize) {
      List<Workflow_Instance__c> batchInstances = sliceInstances(
        instances,
        i,
        instanceBatchSize
      );

      List<Workflow_Step_Execution__c> execs = queryStepExecutionsForBatch(
        batchInstances
      );

      List<String> resolvedCaptures = resolveCapturesInBatches(execs);
      applyExecCaptures(execs, resolvedCaptures, scan);
    }
  }

  /**
   * @description Fetches the step-execution rows for one 1,000-instance chunk of
   * the adoption scan in {@link scanInstancesForExplicitFalse}.
   * <p><b>Intentional per-iteration SOQL.</b> This runs one SOQL query per
   * 1,000-instance chunk. The chunking <i>is itself the governor-safety
   * strategy</i>: capping each query at 1,000 parent instances keeps the
   * number of {@code Workflow_Step_Execution__c} rows returned per query well
   * under the 50k SOQL-row limit on large data volumes. De-chunking into a
   * single query would <b>increase</b> governor risk (the opposite of the
   * rule's intent), so the fixed <b>1,000-instance chunk size</b> must be
   * preserved exactly. The query count is bounded by
   * ceil(instances.size() / 1000).
   * @param batchInstances one chunk of at most 1,000 instances whose step
   *        executions to fetch
   * @return the step-execution rows for the given chunk
   */
  private static List<Workflow_Step_Execution__c> queryStepExecutionsForBatch(
    List<Workflow_Instance__c> batchInstances
  ) {
    return [
      SELECT
        Workflow_Instance__c,
        Captured_Values__c,
        Workflow_Instance__r.Workflow_Name__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :batchInstances
      WITH SYSTEM_MODE
    ];
  }

  /**
   * @description Returns a sublist of at most {@code batchSize} instances
   * beginning at {@code start}, without mutating the source list.
   * @param instances the full instance population
   * @param start the start index of the chunk
   * @param batchSize the maximum chunk size
   * @return the chunk of instances
   */
  private static List<Workflow_Instance__c> sliceInstances(
    List<Workflow_Instance__c> instances,
    Integer start,
    Integer batchSize
  ) {
    List<Workflow_Instance__c> batch = new List<Workflow_Instance__c>();
    for (
      Integer j = start; j < start + batchSize && j < instances.size(); j++
    ) {
      batch.add(instances[j]);
    }
    return batch;
  }

  /**
   * @description Resolves the captured-values payloads for a chunk of step
   * executions in sub-batches of 40 to stay under the synchronous Apex heap cap
   * (6 MB), rehydrating any offloaded payloads through {@link WorkflowPayloadOffload}.
   * @param execs the step executions whose captured values to resolve
   * @return the resolved captured-values JSON strings, index-aligned with execs
   */
  private static List<String> resolveCapturesInBatches(
    List<Workflow_Step_Execution__c> execs
  ) {
    Integer offloadBatchSize = 40;
    List<String> resolvedCaptures = new List<String>();
    for (Integer k = 0; k < execs.size(); k += offloadBatchSize) {
      List<String> batchRaw = new List<String>();
      for (Integer m = k; m < k + offloadBatchSize && m < execs.size(); m++) {
        batchRaw.add(execs[m].Captured_Values__c);
      }
      resolvedCaptures.addAll(WorkflowPayloadOffload.resolvePayloads(batchRaw));
    }
    return resolvedCaptures;
  }

  /**
   * @description Applies each resolved captured-values payload to the scan
   * accumulator, index-aligned with the step executions.
   * @param execs the step executions being scanned
   * @param resolvedCaptures the resolved captured-values JSON, aligned with execs
   * @param scan the mutable accumulator collecting scan results
   */
  private static void applyExecCaptures(
    List<Workflow_Step_Execution__c> execs,
    List<String> resolvedCaptures,
    WorkflowPatchAdoption.AdoptionScan scan
  ) {
    for (Integer k = 0; k < execs.size(); k++) {
      applyExecCapture(execs[k], resolvedCaptures[k], scan);
    }
  }

  /**
   * @description Applies one resolved captured-values payload to the scan: records
   * the workflow name when the patch key is present and flags the instance when
   * the recorded decision is explicitly `false`. Malformed JSON is ignored.
   * @param exec the step execution being scanned
   * @param capturesJson the resolved captured-values JSON for this execution
   * @param scan the mutable accumulator collecting scan results
   */
  private static void applyExecCapture(
    Workflow_Step_Execution__c exec,
    String capturesJson,
    WorkflowPatchAdoption.AdoptionScan scan
  ) {
    if (String.isBlank(capturesJson)) {
      return;
    }
    if (!capturesJson.contains(scan.key)) {
      return;
    }
    try {
      Map<String, Object> captures = (Map<String, Object>) JSON.deserializeUntyped(
        capturesJson
      );
      if (captures.containsKey(scan.key)) {
        scan.targetWorkflows.add(exec.Workflow_Instance__r.Workflow_Name__c);
        if (captures.get(scan.key) == false) {
          scan.instancesWithExplicitFalse.add(exec.Workflow_Instance__c);
        }
      }
    } catch (Exception ignored) {
      // Ignore malformed JSON
    }
  }
}
