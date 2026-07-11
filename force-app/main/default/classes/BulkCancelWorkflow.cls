/**
 * BulkCancelWorkflow
 *
 * Operator-initiated bulk cancel of workflow instances.
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

  public List<String> getSteps() {
    return new List<String>{ 'BulkCancelWorkflow.BulkCancelStep' };
  }

  public String getInitialStep() {
    return 'BulkCancelWorkflow.BulkCancelStep';
  }

  public String getNextStep(String currentStepName, StepResult result) {
    return null; // single-step workflow
  }

  // ---- Eligible-selection helpers ----

  /**
   * Shared selection surface. The eligible-status set and the self-exclusion
   * name are this job's only variance from BulkRedriveWorkflow, so both are
   * injected into the one shared selector implementation.
   */
  private static BulkWorkflowSelector selector() {
    return new BulkWorkflowSelector(ELIGIBLE_STATUSES, CANCELER_WORKFLOW_NAME);
  }

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

  public inherited sharing class BulkCancelStep implements WorkflowStep {
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
     * Processes one chunk: locks the whole (<= chunkSize) chunk once up front
     * (one FOR UPDATE instead of one query per instance), then cancels each
     * still-eligible instance in its own savepoint, advancing the cursor and
     * tallies. Yields early (breaks) when the governor budget runs low.
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
     * One bulk FOR UPDATE read of the chunk, returning each instance's current
     * status keyed by Id. Locking the tiny chunk in a single query preserves the
     * pre-cancel status recheck while keeping SOQL out of the per-instance loop.
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
     * Cancels a single instance inside its own savepoint. A still-eligible
     * instance is cancelled; anything no longer eligible (or missing) is skipped;
     * any failure rolls back that instance's partial writes and is counted as an
     * error, leaving peers untouched.
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
        WorkflowEngine.cancel(instId, runCompensations);
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
