/**
 * BulkRedriveWorkflow
 *
 * Operator-initiated bulk re-drive of failed workflow instances. When a shared
 * downstream dependency recovers (an endpoint comes back, a throttle clears, a
 * credential is rotated), an operator can re-drive every instance matching their
 * current dashboard filter in a single bounded action instead of clicking
 * "Retry" once per instance.
 *
 * Design (issue #1):
 *  - This re-driver runs AS a Revenant workflow instance (dogfooding the
 *    CursorFanout / yield story), so it inherits resumability, the append-only
 *    audit trail, and dashboard visibility for free.
 *  - The single step pages over the eligible selection in safe-sized chunks,
 *    yielding to a fresh transaction (`StepResult.yield`) whenever it approaches
 *    a governor limit, so an arbitrarily large selection never throws.
 *  - Each eligible instance is recovered through the EXISTING
 *    WorkflowEngine.retryWorkflow(Id) primitive — no new state-transition path.
 *    Idempotency leans on that primitive's FOR UPDATE active-state guard: an
 *    instance that is no longer Failed is skipped, never double-chained.
 *  - Eligibility is restricted to the operator-recoverable terminal set
 *    ({Failed}); Completed / Cancelled / Running / Suspended / Pending /
 *    Compensating / Cancelling / Compensated are excluded. Compensated is listed
 *    in the spec as recoverable "where applicable", but retryWorkflow only
 *    accepts Failed, so re-driving it would require a new state path — out of
 *    scope for this slice.
 *  - The confirmed count is a pre-flight approximation, not a hard contract.
 *    Instances that fail between confirmation and the final chunk may be swept
 *    in; this is acceptable (they are Failed and match the operator's filter),
 *    and the idempotency guard prevents double-drives. A LastModifiedDate bound
 *    was considered but rejected: it would silently DROP confirmed rows whenever
 *    an automation or operator edits a field on a still-Failed instance mid-sweep,
 *    which is a worse failure mode than re-driving a few extra instances.
 *  - OUROBOROS GUARD: the selection hard-excludes the re-driver's own
 *    Workflow_Name__c, so a future "re-drive all Failed" sweep can never
 *    re-drive a previously-failed re-drive instance and build a self-replaying
 *    loop with governor limits as the only brake.
 *
 * The eligible-selection SOQL is shared with BulkCancelWorkflow through
 * BulkWorkflowSelector; only the recoverable-status set and the self-exclusion
 * name differ between the two jobs.
 */
public inherited sharing class BulkRedriveWorkflow implements WorkflowDefinition {
  /**
   * The re-driver's own Workflow_Name__c. Must be excluded from every eligible
   * selection (the ouroboros guard).
   */
  public static final String REDRIVER_WORKFLOW_NAME = 'BulkRedriveWorkflow';

  /**
   * Operator-recoverable terminal statuses. Only these are ever re-enqueued.
   */
  private static final Set<String> RECOVERABLE_STATUSES = new Set<String>{
    'Failed'
  };

  /**
   * Max instances re-driven per transaction before yielding. Each retryWorkflow
   * call costs a few DML statements plus an orchestrator enqueue, so this is kept
   * comfortably under the synchronous DML-statement budget; shouldYield() trims
   * it further under real load. Overridable in tests.
   */
  @TestVisible
  // Capped at 4 because of Salesforce Apex's hard limit of 5 savepoints per transaction, leaving 1 slot for safety/triggers.
  public static Integer defaultChunkSize = 4;

  private enum RedriveOutcome {
    REDRIVEN,
    SKIPPED,
    ERRORED
  }

  // ---- WorkflowDefinition ----

  public List<String> getSteps() {
    return new List<String>{ 'BulkRedriveWorkflow.BulkRedriveStep' };
  }

  public String getInitialStep() {
    return 'BulkRedriveWorkflow.BulkRedriveStep';
  }

  public String getNextStep(String currentStepName, StepResult result) {
    return null; // single-step workflow
  }

  // ---- Eligible-selection helpers (single source of truth) ----

  /**
   * Shared selection surface. Injects this job's recoverable-status set and its
   * self-exclusion name into the one shared selector implementation.
   */
  private static BulkWorkflowSelector selector() {
    return new BulkWorkflowSelector(
      RECOVERABLE_STATUSES,
      REDRIVER_WORKFLOW_NAME
    );
  }

  /**
   * Exact count of instances that WILL be re-driven for the given filter — the
   * number shown to the operator for confirmation. Uses the same selection
   * surface (workflowName / status / searchTerm) as getFilteredInstances and
   * excludes the re-driver itself.
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

  // ---- The re-drive step ----

  public inherited sharing class BulkRedriveStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Map<String, Object> state = hydrateState(ctx);

      String workflowName = (String) state.get('workflowName');
      String status = (String) state.get('status');
      String searchTerm = (String) state.get('searchTerm');
      Id afterId = state.get('lastId') != null
        ? (Id) (String) state.get('lastId')
        : null;
      Integer redriven = intOf(state.get('redriven'));
      Integer skipped = intOf(state.get('skipped'));
      Integer errored = intOf(state.get('errored'));

      Integer chunkSize = defaultChunkSize;
      List<Id> chunk = selector()
        .fetchChunk(
          new BulkWorkflowSelector.Criteria(workflowName, status, searchTerm),
          afterId,
          chunkSize
        );

      Integer processed = 0;
      for (Id instId : chunk) {
        // Pre-flight yield check: a previous high-fan-out parallel retry may have
        // consumed significant DML/event budget. Yield now rather than enter the
        // next retryWorkflow call when already near the governor ceiling.
        if (ctx.shouldYield()) {
          break;
        }
        switch on redriveOne(instId) {
          when REDRIVEN {
            redriven++;
          }
          when SKIPPED {
            skipped++;
          }
          when else {
            errored++;
          }
        }
        afterId = instId;
        processed++;

        // Post-retry yield check: stop early if we are approaching a governor
        // limit; progress is checkpointed below and resumed in a fresh transaction.
        if (ctx.shouldYield()) {
          break;
        }
      }

      state.put('workflowName', workflowName);
      state.put('status', status);
      state.put('searchTerm', searchTerm);
      state.put('lastId', afterId == null ? null : String.valueOf(afterId));
      state.put('redriven', redriven);
      state.put('skipped', skipped);
      state.put('errored', errored);

      // More work remains if we either stopped early mid-chunk (processed fewer
      // than we fetched) or fetched a full chunk (so another page likely exists).
      // Only a fully-drained short chunk means the selection is exhausted.
      Boolean moreRemain =
        (processed < chunk.size()) || (chunk.size() == chunkSize);
      if (moreRemain) {
        return StepResult.yield(JSON.serialize(state));
      }

      return StepResult.complete(
        null,
        buildSummary(redriven, skipped, errored)
      );
    }

    /**
     * Hydrates step state: on the first run the persisted state is empty, so
     * seed it from the operator's filter (the workflow input); on resume, the
     * yield state carries the cursor and running tallies forward.
     */
    private Map<String, Object> hydrateState(StepContext ctx) {
      if (String.isNotBlank(ctx.stepStateJson)) {
        return (Map<String, Object>) JSON.deserializeUntyped(ctx.stepStateJson);
      }
      Map<String, Object> state = new Map<String, Object>();
      if (String.isBlank(ctx.workflowInputJson)) {
        return state;
      }
      Map<String, Object> filter = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.workflowInputJson
      );
      state.put('workflowName', filter.get('workflowName'));
      state.put('status', filter.get('status'));
      state.put('searchTerm', filter.get('searchTerm'));
      return state;
    }

    /**
     * Re-drives a single instance inside its own savepoint. A retryWorkflow
     * failure rolls back that instance's partial writes; a "Failed status" guard
     * rejection is a benign skip, anything else is counted as an error — leaving
     * the peers already re-driven in this chunk untouched.
     */
    private RedriveOutcome redriveOne(Id instId) {
      Savepoint sp = Database.setSavepoint();
      try {
        WorkflowEngine.retryWorkflow(instId);
        return RedriveOutcome.REDRIVEN;
      } catch (WorkflowEngine.WorkflowException wex) {
        Database.rollback(sp);
        Boolean noLongerFailed =
          wex.getMessage() != null &&
          wex.getMessage().contains('Failed status');
        return noLongerFailed ? RedriveOutcome.SKIPPED : RedriveOutcome.ERRORED;
      } catch (Exception ex) {
        Database.rollback(sp);
        return RedriveOutcome.ERRORED;
      }
    }

    private Map<String, Object> buildSummary(
      Integer redriven,
      Integer skipped,
      Integer errored
    ) {
      return new Map<String, Object>{
        'redriven' => redriven,
        'skipped' => skipped,
        'errored' => errored,
        'totalProcessed' => redriven +
        skipped +
        errored
      };
    }

    private Integer intOf(Object o) {
      return o == null ? 0 : Integer.valueOf(String.valueOf(o));
    }
  }
}
