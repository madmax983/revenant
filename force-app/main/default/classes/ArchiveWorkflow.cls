/**
 * @description System workflow that archives terminal instances to the
 * configured {@link WorkflowArchiveSink}, then purges them. It selects
 * instances that were created more than `archiveAfterDays` days ago. Offline sweep in
 * bounded, resumable batches. See {@link WorkflowArchiveSweep}.
 *
 * Input (all optional):
 * - `archiveAfterDays`: minimum age in days (from `CreatedDate`). Default:
 *   `Revenant_Config__mdt.Archive_After_Days__c`, else 30.
 * - `batchSize`: instances in one batch. Default and maximum 20.
 *
 * When archival is off, the step completes at once and deletes nothing.
 */
public inherited sharing class ArchiveWorkflow implements WorkflowDefinition {
  private static final String STEP = 'ArchiveWorkflow.ArchiveOldInstancesStep';

  /**
   * @description Returns the step names.
   * @return the archive step
   */
  public List<String> getSteps() {
    return new List<String>{ STEP };
  }

  /**
   * @description Returns the first step.
   * @return the archive step
   */
  public String getInitialStep() {
    return STEP;
  }

  /**
   * @description Returns the next step.
   * @param currentStepName the step that completed
   * @param result the step result
   * @return null. This workflow has one step.
   */
  public String getNextStep(String currentStepName, StepResult result) {
    return null;
  }

  /**
   * @description Durable step state across batches. Also the output.
   */
  public class ArchiveState {
    /** @description Number of instances archived and purged. */
    public Integer archivedCount = 0;
    /** @description True when archival was off, so nothing ran. */
    public Boolean archivalDisabled = false;
    /**
     * @description Instances too large to archive, at most
     * {@link WorkflowArchiveSweep#MAX_SKIPPED_IDS}. They stay in primary
     * storage. See {@link WorkflowArchiveSweep}.
     */
    public List<Id> skippedInstanceIds = new List<Id>();
    /** @description Sweep cursor time. Null before the first move. */
    public Datetime cursorCreatedDate;
    /** @description Sweep cursor Id. */
    public Id cursorId;
  }

  /**
   * @description The archive step. It is a {@link CalloutStep}: the engine
   * does no DML before `execute`, so a sink can call out (for example to S3).
   */
  public inherited sharing class ArchiveOldInstancesStep implements WorkflowStep, CalloutStep {
    /**
     * @description Archives and purges one batch. Yields when more remain.
     * @param ctx the step context
     * @return a yield result when more remain, else a complete result
     */
    public StepResult execute(StepContext ctx) {
      ArchiveState state = String.isBlank(ctx.stepStateJson)
        ? new ArchiveState()
        : (ArchiveState) JSON.deserialize(
            ctx.stepStateJson,
            ArchiveState.class
          );
      if (!WorkflowArchive.isEnabled()) {
        state.archivalDisabled = true;
        return StepResult.complete(null, state);
      }
      WorkflowArchiveSweep.Params params = WorkflowArchiveSweep.parseParams(
        ctx.workflowInputJson,
        'archiveAfterDays',
        WorkflowArchive.archiveAfterDays(),
        WorkflowArchiveSweep.MAX_ARCHIVE_BATCH_SIZE
      );
      WorkflowArchiveSweep.resumeAt(
        params,
        state.cursorCreatedDate,
        state.cursorId
      );
      WorkflowArchiveSweep.BatchResult batch = WorkflowArchiveSweep.runBatch(
        params,
        WorkflowArchive.sink()
      );
      state.archivedCount += batch.purgedCount;
      if (batch.cursorId != null) {
        state.cursorCreatedDate = batch.cursorCreatedDate;
        state.cursorId = batch.cursorId;
      }
      WorkflowArchiveSweep.reportSkips(batch, state.skippedInstanceIds);
      if (batch.hasMore) {
        return StepResult.yield(JSON.serialize(state));
      }
      return StepResult.complete(null, state);
    }
  }
}
