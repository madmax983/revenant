/**
 * @description System workflow definition that purges old, terminal workflow
 * instances and their engine-owned ContentDocuments in bounded, resumable batches.
 */
public inherited sharing class CleanupWorkflow implements WorkflowDefinition {
  /**
   * @description Returns the ordered list of step names that make up this workflow.
   * @return A single-element list naming the purge step.
   */
  public List<String> getSteps() {
    return new List<String>{ 'CleanupWorkflow.PurgeOldInstancesStep' };
  }

  /**
   * @description Returns the name of the step the engine executes first.
   * @return The name of the purge step.
   */
  public String getInitialStep() {
    return 'CleanupWorkflow.PurgeOldInstancesStep';
  }

  /**
   * @description Computes the next step to run after the given step completes.
   * @param currentStepName The name of the step that just completed.
   * @param result The result of the completed step.
   * @return Always null, since this is a single-step workflow.
   */
  public String getNextStep(String currentStepName, StepResult result) {
    return null; // Single step workflow
  }

  /**
   * @description Durable step state tracking how many instances have been purged
   * across resumed batches of the purge run.
   */
  public class PurgeState {
    public Integer deletedCount;
  }

  // Parsed, validated input parameters for a purge run.
  private class PurgeParams {
    public Integer retentionDays = 30;
    public Integer batchSize = 200;
  }

  // inherited sharing: the step runs in the engine's (caller's) context. Every SOQL
  // uses WITH SYSTEM_MODE and every DML uses `as system`, so record access is already
  // elevated deliberately where the purge needs it; the explicit keyword just satisfies
  // the sharing-declaration requirement without widening or narrowing that behavior.
  /**
   * @description The single durable step that selects terminal instances past their
   * retention window, deletes their engine-owned unshared documents, removes the
   * instances and their signals, and yields to continue when more remain.
   */
  public inherited sharing class PurgeOldInstancesStep implements WorkflowStep {
    /**
     * @description Executes one bounded purge batch, deleting qualified documents and
     * instances and yielding if further candidates remain.
     * @param ctx The durable step context supplying workflow input and step state.
     * @return A yield result if more candidates remain, otherwise a complete result.
     */
    public StepResult execute(StepContext ctx) {
      PurgeParams params = parseParams(ctx.workflowInputJson);

      // Clamp batchSize to a maximum of 50
      Integer clampedBatchSize = Math.min(params.batchSize, 50);
      DateTime threshold = DateTime.now().addDays(-params.retentionDays);

      List<Workflow_Instance__c> candidateInstances = queryCandidates(
        threshold,
        clampedBatchSize
      );

      PurgeState state = loadState(ctx.stepStateJson);

      if (candidateInstances.isEmpty()) {
        return StepResult.complete(null, state);
      }

      // 1-5. Index the candidate instances' documents, select the bounded chunk of
      //    instances to purge, and delete their engine-owned unshared documents. The
      //    returned chunk carries the instances (and ids) still to be deleted.
      CleanupDocumentPurger.PurgeChunk chunk = CleanupDocumentPurger.purgeInstanceDocuments(
        candidateInstances
      );

      // 6. Delete associated signal records before deleting instances.
      applyInstanceDeletion(chunk, state);

      // Check if we still have remaining candidate instances that weren't processed in
      // this batch due to the limit, or if we fetched a full batch which implies there
      // could be more in the database.
      Boolean hasMore =
        (candidateInstances.size() > chunk.instancesToPurge.size()) ||
        (candidateInstances.size() == clampedBatchSize);
      if (hasMore) {
        return StepResult.yield(JSON.serialize(state));
      }

      return StepResult.complete(null, state);
    }

    // ── Input parsing ──────────────────────────────────────────────────────────
    private PurgeParams parseParams(String inputJson) {
      PurgeParams params = new PurgeParams();
      if (String.isBlank(inputJson)) {
        return params;
      }
      Map<String, Object> input = deserializeInput(inputJson);
      if (input.containsKey('retentionDays')) {
        params.retentionDays = parseRetentionDays(input.get('retentionDays'));
      }
      if (input.containsKey('batchSize')) {
        params.batchSize = parseBatchSize(input.get('batchSize'));
      }
      return params;
    }

    private Map<String, Object> deserializeInput(String inputJson) {
      try {
        return (Map<String, Object>) JSON.deserializeUntyped(inputJson);
      } catch (Exception ex) {
        throw new WorkflowEngine.WorkflowException(
          'Malformed JSON in workflow input: ' + ex.getMessage()
        );
      }
    }

    private Integer parseRetentionDays(Object raw) {
      Integer value = toInt(raw, 'retentionDays');
      if (value < 0) {
        throw new WorkflowEngine.WorkflowException(
          'retentionDays parameter cannot be negative'
        );
      }
      return value;
    }

    private Integer parseBatchSize(Object raw) {
      Integer value = toInt(raw, 'batchSize');
      if (value <= 0) {
        throw new WorkflowEngine.WorkflowException(
          'batchSize parameter must be greater than zero'
        );
      }
      return value;
    }

    private Integer toInt(Object raw, String label) {
      try {
        return Integer.valueOf(raw);
      } catch (Exception ex) {
        throw new WorkflowEngine.WorkflowException(
          'Invalid ' + label + ' parameter type: ' + ex.getMessage()
        );
      }
    }

    // ── State + candidate selection ──────────────────────────────────────────────
    private PurgeState loadState(String stepStateJson) {
      PurgeState state = new PurgeState();
      state.deletedCount = 0;
      if (String.isNotBlank(stepStateJson)) {
        state = (PurgeState) JSON.deserialize(stepStateJson, PurgeState.class);
      }
      return state;
    }

    private List<Workflow_Instance__c> queryCandidates(
      DateTime threshold,
      Integer clampedBatchSize
    ) {
      return [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE
          Status__c IN (
            'Completed',
            'Failed',
            'Compensated',
            'Cancelled',
            'ContinuedAsNew'
          )
          AND CreatedDate < :threshold
        WITH SYSTEM_MODE
        LIMIT :clampedBatchSize
      ];
    }

    // ── Deletion ─────────────────────────────────────────────────────────────────
    private void applyInstanceDeletion(
      CleanupDocumentPurger.PurgeChunk chunk,
      PurgeState state
    ) {
      if (chunk.instancesToPurge.isEmpty()) {
        return;
      }
      // Workflow_Signal__c.Workflow_Instance__c is a Lookup with SetNull (not a
      // cascade-delete MasterDetail), so signals must be deleted explicitly first.
      List<Workflow_Signal__c> signalsToDelete = [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c IN :chunk.instanceIdsToPurge
        WITH SYSTEM_MODE
      ];
      if (!signalsToDelete.isEmpty()) {
        delete as system signalsToDelete;
      }
      delete as system chunk.instancesToPurge;
      state.deletedCount += chunk.instancesToPurge.size();
    }
  }
}
