/**
 * @description System workflow definition that purges old, terminal workflow
 * instances and their engine-owned ContentDocuments in bounded, resumable batches.
 * With archival on, it archives each batch first (see {@link WorkflowArchiveSweep}).
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
    /**
     * @description With archival on: instances too large to archive, at most
     * 2000. They stay in primary storage. Null when none were skipped.
     */
    public List<Id> skippedInstanceIds;
    /** @description With archival on: sweep cursor time. Null before the first move. */
    public Datetime cursorCreatedDate;
    /** @description With archival on: sweep cursor Id. */
    public Id cursorId;
  }

  // inherited sharing: the step runs in the engine's (caller's) context. Every SOQL
  // uses WITH SYSTEM_MODE and every DML uses `as system`, so record access is already
  // elevated deliberately where the purge needs it; the explicit keyword just satisfies
  // the sharing-declaration requirement without widening or narrowing that behavior.
  /**
   * @description The single durable step that selects terminal instances past their
   * retention window, deletes their engine-owned unshared documents, removes the
   * instances and their signals, and yields to continue when more remain. When
   * archival is on (`Revenant_Config__mdt.Archive_Enabled__c`), it archives each
   * chunk to the configured {@link WorkflowArchiveSink} before it deletes it.
   *
   * It is a {@link CalloutStep}, so the engine does no DML before `execute`.
   * `Database.insertImmediate` and a callout sink need that. The step has no
   * timeout and no auto-retry policy, so the marker changes nothing else.
   */
  public inherited sharing class PurgeOldInstancesStep implements WorkflowStep, CalloutStep {
    /**
     * @description Executes one bounded purge batch, deleting qualified documents and
     * instances and yielding if further candidates remain.
     * @param ctx The durable step context supplying workflow input and step state.
     * @return A yield result if more candidates remain, otherwise a complete result.
     */
    public StepResult execute(StepContext ctx) {
      WorkflowArchiveSweep.Params params = WorkflowArchiveSweep.parseParams(
        ctx.workflowInputJson,
        'retentionDays',
        30,
        200
      );
      PurgeState state = loadState(ctx.stepStateJson);
      // Archive before purge when archival is on. A config read failure throws,
      // so the step never purges history that archival should keep.
      WorkflowArchiveSink sink = WorkflowArchive.isEnabled()
        ? WorkflowArchive.sink()
        : null;
      WorkflowArchiveSweep.resumeAt(
        params,
        state.cursorCreatedDate,
        state.cursorId
      );
      WorkflowArchiveSweep.BatchResult batch = WorkflowArchiveSweep.runBatch(
        params,
        sink
      );
      state.deletedCount += batch.purgedCount;
      if (batch.cursorId != null) {
        state.cursorCreatedDate = batch.cursorCreatedDate;
        state.cursorId = batch.cursorId;
      }
      if (!batch.skippedInstanceIds.isEmpty()) {
        if (state.skippedInstanceIds == null) {
          state.skippedInstanceIds = new List<Id>();
        }
        WorkflowArchiveSweep.reportSkips(batch, state.skippedInstanceIds);
      }
      if (batch.hasMore) {
        return StepResult.yield(JSON.serialize(state));
      }
      return StepResult.complete(null, state);
    }

    private PurgeState loadState(String stepStateJson) {
      PurgeState state = new PurgeState();
      state.deletedCount = 0;
      if (String.isNotBlank(stepStateJson)) {
        state = (PurgeState) JSON.deserialize(stepStateJson, PurgeState.class);
      }
      return state;
    }
  }
}
