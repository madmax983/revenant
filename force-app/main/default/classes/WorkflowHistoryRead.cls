/**
 * @description Read API for a workflow instance's ordered step-execution timeline.
 * Returns the append-order history of `Workflow_Step_Execution__c` rows for an
 * instance (single or bulk) projected into the resident public DTOs
 * `WorkflowEngine.StepHistoryEntry` and `WorkflowEngine.StepHistory`. This is the
 * timeline complement to {@link WorkflowStatusRead} (which returns the terminal
 * outcome): callers get every step that ran, in order, with attempt counts,
 * timing, error text, and a forward-vs-compensation flag, without coupling to the
 * internal `Workflow_Step_Execution__c` field API names. It is the supported read
 * contract — mirroring how `WorkflowStatusRead.getStatus` (not the facade) is the
 * supported outcome contract; the forever-public DTOs remain on `WorkflowEngine`.
 *
 * Strictly read-only: a small constant number of SOQL queries and zero DML. The
 * read never mutates the append-only step-execution trail. v1 is metadata-only —
 * per-step input/output payload bodies are deliberately excluded to stay
 * heap-bounded; terminal output still comes from {@link WorkflowStatusRead}.
 */
public inherited sharing class WorkflowHistoryRead {
  /**
   * @description Maximum number of step-execution rows returned per instance. A
   * history longer than this cap is truncated to the earliest `MAX_HISTORY_ROWS`
   * entries and the corresponding `WorkflowEngine.StepHistory.isTruncated` flag is
   * set to true so results are never silently cut. Public so callers can size
   * their own paging/UX against the documented boundary.
   */
  public static final Integer MAX_HISTORY_ROWS = 500;

  /**
   * @description Step statuses treated as terminal for a single step execution.
   * A terminal step has a settled `endedAt`/`totalDurationMs`; any other status is
   * considered in flight and reports null timing. Public so the resident
   * `WorkflowEngine.StepHistoryEntry` constructor shares one source of truth.
   */
  public static final Set<String> TERMINAL_STEP_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled',
    'OperatorSkipped',
    'ContinuedAsNew'
  };

  /**
   * @description Returns the ordered step-execution timeline for a workflow
   * instance by Id, or null when no instance with that Id exists. A known
   * instance that has not yet logged a step returns a `StepHistory` whose
   * `entries` list is empty. Costs at most 2 SOQL queries and zero DML — and
   * exactly ONE query in the common case (rows present and within the row cap):
   * the real total is resolved lazily with a `COUNT()` only when the history is
   * truncated, and instance existence is probed only when no rows are returned.
   * A single instance can never be scan-starved (its scan budget covers its own
   * cap), so this lazy path cannot produce a false-empty history.
   * @param instanceId Id of the workflow instance to read
   * @return the instance's step history, or null when no such instance exists
   */
  public static WorkflowEngine.StepHistory getHistory(Id instanceId) {
    if (instanceId == null) {
      return null;
    }
    List<Workflow_Step_Execution__c> rows = queryRowsByInstance(
        new Set<Id>{ instanceId }
      )
      .get(instanceId);

    if (rows == null || rows.isEmpty()) {
      // No rows: distinguish a known step-less instance (empty history) from an
      // unknown Id (null) with a single existence probe.
      return instanceExists(instanceId)
        ? new WorkflowEngine.StepHistory(
            new List<Workflow_Step_Execution__c>(),
            MAX_HISTORY_ROWS,
            0
          )
        : null;
    }

    // Rows present. Only when the scan hit the cap do we need the real total; an
    // untruncated read stays at the single scan query.
    Integer totalCount = rows.size() > MAX_HISTORY_ROWS
      ? countSteps(instanceId)
      : rows.size();
    return new WorkflowEngine.StepHistory(rows, MAX_HISTORY_ROWS, totalCount);
  }

  /**
   * @description Bulk variant — accepts a list of instance Ids and returns a map
   * from instance Id to its ordered step history. An Id with no matching instance
   * is absent from the map; a known instance with no logged steps is present with
   * an empty `entries` list (mirroring the single-Id null-vs-empty distinction).
   * Uses a bounded, constant number of SOQL queries regardless of list size and
   * zero DML.
   *
   * Correctness invariant: a step-bearing instance is NEVER reported as empty.
   * The per-instance row scan is capped at `ids.size() * (MAX_HISTORY_ROWS + 1)`
   * rows (clamped to the SOQL row ceiling) to stay heap-bounded, so a large
   * sibling can starve another instance of scan budget — but an authoritative
   * `COUNT()` grouped by instance (one query over the whole batch) supplies every
   * requested instance's real `totalCount`. A starved instance therefore comes
   * back with `isTruncated = true` and its true `totalCount` (with whatever rows
   * the scan retrieved, possibly none), never as a false-empty history. To get the
   * full `entries` of such a very large history, re-read that instance singly.
   * @param instanceIds instance Ids to read
   * @return map of instance Id to step history (absent key per unmatched Id)
   */
  public static Map<Id, WorkflowEngine.StepHistory> getHistory(
    List<Id> instanceIds
  ) {
    Map<Id, WorkflowEngine.StepHistory> out = new Map<Id, WorkflowEngine.StepHistory>();
    Set<Id> lookupIds = toLookupIds(instanceIds);
    if (lookupIds.isEmpty()) {
      return out;
    }

    // Query 1: the (budget-capped) rows per instance in append order.
    Map<Id, List<Workflow_Step_Execution__c>> rowsByInstance = queryRowsByInstance(
      lookupIds
    );
    // Query 2: the authoritative real step total for every requested instance in
    // one grouped COUNT — this is what makes a scan-starved instance impossible to
    // mistake for an empty one.
    Map<Id, Integer> realTotals = realStepTotals(lookupIds);

    for (Id instId : lookupIds) {
      Integer totalCount = realTotals.containsKey(instId)
        ? realTotals.get(instId)
        : 0;
      if (totalCount == 0) {
        // No steps: existence is resolved below (known-empty vs unknown Id).
        continue;
      }
      List<Workflow_Step_Execution__c> rows = rowsByInstance.containsKey(instId)
        ? rowsByInstance.get(instId)
        : new List<Workflow_Step_Execution__c>();
      out.put(
        instId,
        new WorkflowEngine.StepHistory(rows, MAX_HISTORY_ROWS, totalCount)
      );
    }

    // Query 3 (only when there are step-less requested Ids): an existence probe
    // separates a known step-less instance (present, empty entries) from an
    // unknown Id (absent from the map).
    Set<Id> steplessIds = new Set<Id>(lookupIds);
    steplessIds.removeAll(out.keySet());
    addExistingSteplessInstances(steplessIds, out);
    return out;
  }

  /**
   * @description Resolves the real step-execution total for every requested
   * instance in a single aggregate `COUNT()` query. Instances with no step rows
   * are simply absent from the result (treated as a total of 0 by the caller).
   * Returns an empty map (and runs no query) for an empty input set.
   * @param instanceIds the instances to total
   * @return map of instance Id to its real step-execution count
   */
  private static Map<Id, Integer> realStepTotals(Set<Id> instanceIds) {
    Map<Id, Integer> totals = new Map<Id, Integer>();
    if (instanceIds.isEmpty()) {
      return totals;
    }
    for (AggregateResult ar : [
      SELECT Workflow_Instance__c instId, COUNT(Id) total
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :instanceIds
      WITH SYSTEM_MODE
      GROUP BY Workflow_Instance__c
    ]) {
      totals.put((Id) ar.get('instId'), (Integer) ar.get('total'));
    }
    return totals;
  }

  /**
   * @description Normalizes the requested Ids into a de-duplicated, non-null set
   * for the SOQL bind.
   * @param instanceIds the raw requested Ids
   * @return the set of non-null requested Ids
   */
  private static Set<Id> toLookupIds(List<Id> instanceIds) {
    Set<Id> lookupIds = new Set<Id>();
    if (instanceIds == null) {
      return lookupIds;
    }
    for (Id instanceId : instanceIds) {
      if (instanceId != null) {
        lookupIds.add(instanceId);
      }
    }
    return lookupIds;
  }

  /**
   * @description Queries the step-execution rows for the requested instances in a
   * single bounded query and buckets them per instance in append order. The scan
   * is capped at `lookupIds.size() * (MAX_HISTORY_ROWS + 1)` rows (clamped to the
   * SOQL row ceiling) so no single instance can exhaust the heap.
   * @param lookupIds the instances to read
   * @return map of instance Id to its append-ordered step-execution rows
   */
  private static Map<Id, List<Workflow_Step_Execution__c>> queryRowsByInstance(
    Set<Id> lookupIds
  ) {
    Integer scanLimit = Math.min(
      50000,
      lookupIds.size() * (MAX_HISTORY_ROWS + 1)
    );
    Map<Id, List<Workflow_Step_Execution__c>> rowsByInstance = new Map<Id, List<Workflow_Step_Execution__c>>();
    for (Workflow_Step_Execution__c row : [
      SELECT
        Id,
        Workflow_Instance__c,
        Step_Name__c,
        Status__c,
        Retry_Count__c,
        Error_Details__c,
        CreatedDate,
        LastModifiedDate
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :lookupIds
      WITH SYSTEM_MODE
      ORDER BY Workflow_Instance__c ASC, CreatedDate ASC, Id ASC
      LIMIT :scanLimit
    ]) {
      List<Workflow_Step_Execution__c> bucket = rowsByInstance.get(
        row.Workflow_Instance__c
      );
      if (bucket == null) {
        bucket = new List<Workflow_Step_Execution__c>();
        rowsByInstance.put(row.Workflow_Instance__c, bucket);
      }
      bucket.add(row);
    }
    return rowsByInstance;
  }

  /**
   * @description Adds each genuinely step-less but existing instance to the result
   * as an empty (`totalCount = 0`, `isTruncated = false`) `StepHistory`, so callers
   * can distinguish it from an unknown Id (which stays absent from the map). By
   * construction these Ids have a real step total of 0, so this can never mask a
   * scan-starved step-bearing instance. Costs one SOQL query when there is at
   * least one such Id, zero otherwise.
   * @param candidateIds requested Ids with no step executions
   * @param out the result map to populate in place
   */
  private static void addExistingSteplessInstances(
    Set<Id> candidateIds,
    Map<Id, WorkflowEngine.StepHistory> out
  ) {
    if (candidateIds.isEmpty()) {
      return;
    }
    for (Workflow_Instance__c inst : [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Id IN :candidateIds
      WITH SYSTEM_MODE
    ]) {
      out.put(
        inst.Id,
        new WorkflowEngine.StepHistory(
          new List<Workflow_Step_Execution__c>(),
          MAX_HISTORY_ROWS,
          0
        )
      );
    }
  }

  /**
   * @description Whether a workflow instance with the given Id exists. Used by the
   * single-Id read to distinguish a known step-less instance from an unknown Id.
   * @param instanceId the instance Id to probe
   * @return true when an instance with that Id exists
   */
  private static Boolean instanceExists(Id instanceId) {
    return [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
        WITH SYSTEM_MODE
        LIMIT 1
      ] > 0;
  }

  /**
   * @description Real step-execution count for a single instance, used lazily by
   * the single-Id read only when its history is truncated at the row cap.
   * @param instanceId the instance whose steps to count
   * @return the instance's real step-execution count
   */
  private static Integer countSteps(Id instanceId) {
    return [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      WITH SYSTEM_MODE
    ];
  }
}
