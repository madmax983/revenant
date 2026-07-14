/**
 * @description Operator-initiated, resumable bulk cancel of workflow instances:
 * a single-step workflow that selects eligible instances in chunks and cancels
 * each in its own savepoint, tallying cancelled/skipped/errored outcomes.
 */
public inherited sharing class BulkCancelWorkflow implements WorkflowDefinition {
  public static final String CANCELER_WORKFLOW_NAME = 'BulkCancelWorkflow';

  private static final Set<String> ELIGIBLE_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended',
    'Paused',
    'CompensationFailed'
  };

  @TestVisible
  // Capped at 4 because of Salesforce Apex's hard limit of 5 savepoints per transaction, leaving 1 slot for safety/triggers.
  public static Integer defaultChunkSize = 4;

  private enum CancelOutcome {
    CANCELLED,
    SKIPPED,
    ERRORED
  }

  // ---- WorkflowDefinition ----

  /**
   * @description Declares the single step class that performs the bulk cancel.
   * @return The one-element list naming the BulkCancelStep step.
   */
  public List<String> getSteps() {
    return new List<String>{ 'BulkCancelWorkflow.BulkCancelStep' };
  }

  /**
   * @description Returns the entry step, which is the sole bulk-cancel step.
   * @return The name of the initial step.
   */
  public String getInitialStep() {
    return 'BulkCancelWorkflow.BulkCancelStep';
  }

  /**
   * @description Terminates the workflow after its single step, since there is
   * no successor to route to.
   * @param currentStepName The name of the step that just completed.
   * @param result The result of the completed step.
   * @return Always null, marking the single-step workflow complete.
   */
  public String getNextStep(String currentStepName, StepResult result) {
    return null; // single-step workflow
  }

  // ---- Eligible-selection helpers ----

  /**
   * @description Builds the shared selection surface. The eligible-status set and
   * the self-exclusion name are this job's only variance from BulkRedriveWorkflow,
   * so both are injected into the one shared selector implementation.
   * @return A selector scoped to this job's eligible statuses and self-exclusion.
   */
  private static BulkWorkflowSelector selector() {
    return new BulkWorkflowSelector(ELIGIBLE_STATUSES, CANCELER_WORKFLOW_NAME);
  }

  /**
   * @description Counts how many instances match the given filters and are
   * eligible for cancellation, used to preview the scope of a bulk cancel.
   * @param workflowName The workflow name to filter by, or null for all.
   * @param status The instance status to filter by, or null for all eligible.
   * @param searchTerm A free-text term matched against instance search fields.
   * @return The number of eligible matching instances.
   */
  public static Integer countEligible(
    String workflowName,
    String status,
    String searchTerm
  ) {
    return selector()
      .count(
        new BulkWorkflowSelector.Criteria(workflowName, status, searchTerm)
      );
  }

  // ---- The cancel step ----

  /**
   * Mutable per-execution progress: the resumable cursor plus the running
   * cancelled / skipped / errored tallies and how many rows this pass handled.
   */
  private class Progress {
    Id afterId;
    Integer cancelled = 0;
    Integer skipped = 0;
    Integer errored = 0;
    Integer processed = 0;
  }

  /**
   * @description The resumable step that cancels one chunk of eligible instances
   * per execution, persisting its cursor and tallies to durable state and
   * yielding until every matching instance has been processed.
   */
  public inherited sharing class BulkCancelStep implements WorkflowStep {
    /**
     * @description Fetches and processes the next chunk of eligible instances,
     * writing the advanced cursor and running tallies back to durable state and
     * yielding while more rows remain, otherwise completing with a summary.
     * @param ctx The durable step context carrying state and governor budget.
     * @return A yield result while work remains, or a complete result with the summary.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> state = BulkWorkflowStepState.hydrate(
        ctx,
        new List<String>{
          'workflowName',
          'status',
          'searchTerm',
          'runCompensations'
        }
      );
      String workflowName = (String) state.get('workflowName');
      String status = (String) state.get('status');
      String searchTerm = (String) state.get('searchTerm');
      Integer chunkSize = defaultChunkSize;

      List<Id> chunk = selector()
        .fetchChunk(
          new BulkWorkflowSelector.Criteria(workflowName, status, searchTerm),
          BulkWorkflowStepState.cursorFrom(state),
          chunkSize
        );

      Progress p = processChunk(ctx, chunk, state);

      // The filter keys (workflowName/status/runCompensations/...) are already
      // carried in `state` by BulkWorkflowStepState.hydrate and never mutated, so
      // only the cursor and tallies need to be written back before serializing.
      state.put('lastId', p.afterId == null ? null : String.valueOf(p.afterId));
      state.put('cancelled', p.cancelled);
      state.put('skipped', p.skipped);
      state.put('errored', p.errored);

      Boolean moreRemain =
        (p.processed < chunk.size()) || (chunk.size() == chunkSize);
      if (moreRemain) {
        return StepResult.yield(JSON.serialize(state));
      }

      return StepResult.complete(
        null,
        buildSummary(p.cancelled, p.skipped, p.errored)
      );
    }

    /**
     * @description Processes one chunk: locks the whole (&lt;= chunkSize) chunk once
     * up front (one FOR UPDATE instead of one query per instance), then cancels each
     * still-eligible instance in its own savepoint, advancing the cursor and
     * tallies. Yields early (breaks) when the governor budget runs low.
     * @param ctx The durable step context used to check the yield budget.
     * @param chunk The instance Ids selected for this pass.
     * @param state The hydrated durable state carrying prior cursor and tallies.
     * @return The updated progress with advanced cursor and running tallies.
     */
    private Progress processChunk(
      StepContext ctx,
      List<Id> chunk,
      Map<String, Object> state
    ) {
      Boolean runCompensations = state.get('runCompensations') == true;
      Map<Id, String> statusById = lockStatuses(chunk);

      Progress p = new Progress();
      p.afterId = BulkWorkflowStepState.cursorFrom(state);
      p.cancelled = BulkWorkflowStepState.intOf(state.get('cancelled'));
      p.skipped = BulkWorkflowStepState.intOf(state.get('skipped'));
      p.errored = BulkWorkflowStepState.intOf(state.get('errored'));

      for (Id instId : chunk) {
        if (ctx.shouldYield()) {
          break;
        }
        // Each cancel keeps its own savepoint (see cancelOne), so one poison
        // instance rolls back only itself — never the peers already cancelled.
        switch on cancelOne(instId, statusById.get(instId), runCompensations) {
          when CANCELLED {
            p.cancelled++;
          }
          when SKIPPED {
            p.skipped++;
          }
          when else {
            p.errored++;
          }
        }
        p.afterId = instId;
        p.processed++;

        if (ctx.shouldYield()) {
          break;
        }
      }
      return p;
    }

    /**
     * @description One bulk FOR UPDATE read of the chunk, returning each instance's
     * current status keyed by Id. Locking the tiny chunk in a single query preserves
     * the pre-cancel status recheck while keeping SOQL out of the per-instance loop.
     * @param ids The instance Ids in the chunk to lock and read.
     * @return A map of instance Id to its current status.
     */
    private Map<Id, String> lockStatuses(List<Id> ids) {
      Map<Id, String> statusById = new Map<Id, String>();
      if (ids.isEmpty()) {
        return statusById;
      }
      for (Workflow_Instance__c inst : [
        SELECT Id, Status__c
        FROM Workflow_Instance__c
        WHERE Id IN :ids
        WITH SYSTEM_MODE
        FOR UPDATE
      ]) {
        statusById.put(inst.Id, inst.Status__c);
      }
      return statusById;
    }

    /**
     * @description Cancels a single instance inside its own savepoint. A still-eligible
     * instance is cancelled; anything no longer eligible (or missing) is skipped;
     * any failure rolls back that instance's partial writes and is counted as an
     * error, leaving peers untouched.
     * @param instId The Id of the instance to cancel.
     * @param currentStatus The instance's status read under lock, for the eligibility recheck.
     * @param runCompensations Whether to run saga compensations as part of the cancel.
     * @return The outcome: CANCELLED, SKIPPED, or ERRORED.
     */
    private CancelOutcome cancelOne(
      Id instId,
      String currentStatus,
      Boolean runCompensations
    ) {
      if (currentStatus == null || !ELIGIBLE_STATUSES.contains(currentStatus)) {
        return CancelOutcome.SKIPPED;
      }
      Savepoint sp = Database.setSavepoint();
      try {
        if (runCompensations) {
          WorkflowEngine.cancelWithCompensations(instId);
        } else {
          WorkflowEngine.cancel(instId);
        }
        return CancelOutcome.CANCELLED;
      } catch (Exception ex) {
        Database.rollback(sp);
        return CancelOutcome.ERRORED;
      }
    }

    private Map<String, Object> buildSummary(
      Integer cancelled,
      Integer skipped,
      Integer errored
    ) {
      return new Map<String, Object>{
        'cancelled' => cancelled,
        'skipped' => skipped,
        'errored' => errored,
        'totalProcessed' => cancelled +
        skipped +
        errored
      };
    }
  }
}
