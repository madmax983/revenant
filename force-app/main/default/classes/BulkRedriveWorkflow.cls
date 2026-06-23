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
  public static Integer CHUNK_SIZE = 30;

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
   * Resolves the effective status set for the selection. Honors the operator's
   * status filter but intersects it with the recoverable set, so filtering to a
   * non-recoverable status (e.g. Completed) yields nothing.
   */
  private static List<String> effectiveStatuses(String status) {
    List<String> result = new List<String>();
    if (String.isNotBlank(status)) {
      if (RECOVERABLE_STATUSES.contains(status)) {
        result.add(status);
      }
    } else {
      result.addAll(RECOVERABLE_STATUSES);
    }
    return result;
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
    List<String> effStatuses = effectiveStatuses(status);
    if (effStatuses.isEmpty()) {
      return 0;
    }
    String excludeName = REDRIVER_WORKFLOW_NAME;
    String likeTerm = String.isNotBlank(searchTerm)
      ? '%' + String.escapeSingleQuotes(searchTerm) + '%'
      : null;

    if (String.isBlank(workflowName)) {
      if (likeTerm == null) {
        return [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Status__c IN :effStatuses AND Workflow_Name__c != :excludeName
          WITH SYSTEM_MODE
        ];
      } else {
        return [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE
            Status__c IN :effStatuses
            AND Workflow_Name__c != :excludeName
            AND (Name LIKE :likeTerm
            OR Correlation_Key__c LIKE :likeTerm
            OR Workflow_Name__c LIKE :likeTerm
            OR Error_Message__c LIKE :likeTerm)
          WITH SYSTEM_MODE
        ];
      }
    } else {
      if (likeTerm == null) {
        return [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE
            Status__c IN :effStatuses
            AND Workflow_Name__c != :excludeName
            AND Workflow_Name__c = :workflowName
          WITH SYSTEM_MODE
        ];
      } else {
        return [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE
            Status__c IN :effStatuses
            AND Workflow_Name__c != :excludeName
            AND Workflow_Name__c = :workflowName
            AND (Name LIKE :likeTerm
            OR Correlation_Key__c LIKE :likeTerm
            OR Workflow_Name__c LIKE :likeTerm
            OR Error_Message__c LIKE :likeTerm)
          WITH SYSTEM_MODE
        ];
      }
    }
  }

  /**
   * Returns up to `chunkSize` eligible instance Ids ordered by Id, starting
   * strictly after `afterId` (the cursor). Ordering by Id gives a stable,
   * resumable cursor across yield boundaries.
   */
  public static List<Id> fetchEligibleChunk(
    String workflowName,
    String status,
    String searchTerm,
    Id afterId,
    Integer chunkSize
  ) {
    List<String> effStatuses = effectiveStatuses(status);
    if (effStatuses.isEmpty()) {
      return new List<Id>();
    }
    String excludeName = REDRIVER_WORKFLOW_NAME;
    String likeTerm = String.isNotBlank(searchTerm)
      ? '%' + String.escapeSingleQuotes(searchTerm) + '%'
      : null;
    Integer lim = chunkSize;

    List<Workflow_Instance__c> rows;
    if (afterId == null) {
      if (String.isBlank(workflowName)) {
        if (likeTerm == null) {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE Status__c IN :effStatuses AND Workflow_Name__c != :excludeName
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        } else {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE
              Status__c IN :effStatuses
              AND Workflow_Name__c != :excludeName
              AND (Name LIKE :likeTerm
              OR Correlation_Key__c LIKE :likeTerm
              OR Workflow_Name__c LIKE :likeTerm
              OR Error_Message__c LIKE :likeTerm)
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        }
      } else {
        if (likeTerm == null) {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE
              Status__c IN :effStatuses
              AND Workflow_Name__c != :excludeName
              AND Workflow_Name__c = :workflowName
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        } else {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE
              Status__c IN :effStatuses
              AND Workflow_Name__c != :excludeName
              AND Workflow_Name__c = :workflowName
              AND (Name LIKE :likeTerm
              OR Correlation_Key__c LIKE :likeTerm
              OR Workflow_Name__c LIKE :likeTerm
              OR Error_Message__c LIKE :likeTerm)
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        }
      }
    } else {
      if (String.isBlank(workflowName)) {
        if (likeTerm == null) {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE
              Status__c IN :effStatuses
              AND Workflow_Name__c != :excludeName
              AND Id > :afterId
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        } else {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE
              Status__c IN :effStatuses
              AND Workflow_Name__c != :excludeName
              AND Id > :afterId
              AND (Name LIKE :likeTerm
              OR Correlation_Key__c LIKE :likeTerm
              OR Workflow_Name__c LIKE :likeTerm
              OR Error_Message__c LIKE :likeTerm)
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        }
      } else {
        if (likeTerm == null) {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE
              Status__c IN :effStatuses
              AND Workflow_Name__c != :excludeName
              AND Id > :afterId
              AND Workflow_Name__c = :workflowName
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        } else {
          rows = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE
              Status__c IN :effStatuses
              AND Workflow_Name__c != :excludeName
              AND Id > :afterId
              AND Workflow_Name__c = :workflowName
              AND (Name LIKE :likeTerm
              OR Correlation_Key__c LIKE :likeTerm
              OR Workflow_Name__c LIKE :likeTerm
              OR Error_Message__c LIKE :likeTerm)
            WITH SYSTEM_MODE
            ORDER BY Id ASC
            LIMIT :lim
          ];
        }
      }
    }

    List<Id> ids = new List<Id>();
    for (Workflow_Instance__c inst : rows) {
      ids.add(inst.Id);
    }
    return ids;
  }

  // ---- The re-drive step ----

  public class BulkRedriveStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Hydrate state: on the first run the persisted state is empty, so seed it
      // from the operator's filter (the workflow input). On resume, the yield
      // state carries the cursor and running tallies forward.
      Map<String, Object> state;
      if (String.isNotBlank(ctx.stepStateJson)) {
        state = (Map<String, Object>) JSON.deserializeUntyped(
          ctx.stepStateJson
        );
      } else {
        state = new Map<String, Object>();
        if (String.isNotBlank(ctx.workflowInputJson)) {
          Map<String, Object> filter = (Map<String, Object>) JSON.deserializeUntyped(
            ctx.workflowInputJson
          );
          state.put('workflowName', filter.get('workflowName'));
          state.put('status', filter.get('status'));
          state.put('searchTerm', filter.get('searchTerm'));
        }
      }

      String workflowName = (String) state.get('workflowName');
      String status = (String) state.get('status');
      String searchTerm = (String) state.get('searchTerm');
      Id afterId = state.get('lastId') != null
        ? (Id) (String) state.get('lastId')
        : null;
      Integer redriven = intOf(state.get('redriven'));
      Integer skipped = intOf(state.get('skipped'));
      Integer errored = intOf(state.get('errored'));

      Integer chunkSize = CHUNK_SIZE;
      List<Id> chunk = fetchEligibleChunk(
        workflowName,
        status,
        searchTerm,
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
        try {
          // Reuse the proven single-instance primitive: it acquires a FOR UPDATE
          // lock and refuses any instance that is no longer Failed, so concurrent
          // / double-click re-drives can never produce two orchestrator chains.
          // Revenant's orchestration uses Platform Events, which are committed
          // atomically with the enclosing transaction, so a partial-write scenario
          // (status updated, enqueue not committed) cannot arise; no savepoint is
          // needed, and using one per iteration would hit Apex's 5-savepoint limit.
          WorkflowEngine.retryWorkflow(instId);
          redriven++;
        } catch (WorkflowEngine.WorkflowException wex) {
          // The active-state guard fired: the instance is no longer Failed
          // (already re-driven by an overlapping sweep). Idempotent skip.
          if (
            wex.getMessage() != null &&
            wex.getMessage().contains('Failed status')
          ) {
            skipped++;
          } else {
            errored++;
          }
        } catch (Exception ex) {
          // A failure on one instance must not abort the rest of the selection.
          errored++;
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

      Map<String, Object> summary = new Map<String, Object>{
        'redriven' => redriven,
        'skipped' => skipped,
        'errored' => errored,
        'totalProcessed' => redriven +
        skipped +
        errored
      };
      return StepResult.complete(null, summary);
    }

    private Integer intOf(Object o) {
      return o == null ? 0 : Integer.valueOf(String.valueOf(o));
    }
  }
}
