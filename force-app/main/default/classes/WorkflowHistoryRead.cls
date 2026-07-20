/**
 * @description Read API for a workflow instance's ordered step-execution timeline.
 * Returns the append-order history of `Workflow_Step_Execution__c` rows for an
 * instance (single or bulk) projected into the resident public DTOs
 * `WorkflowEngine.StepHistoryEntry` and `WorkflowEngine.StepHistory`. This is the
 * timeline complement to {@link WorkflowStatusRead} (which returns the terminal
 * outcome): callers get every step that ran, in order, with attempt counts,
 * timing, and a forward-vs-compensation flag, without coupling to the internal
 * `Workflow_Step_Execution__c` field API names. It is the supported read
 * contract — mirroring how `WorkflowStatusRead.getStatus` (not the facade) is the
 * supported outcome contract; the forever-public DTOs remain on `WorkflowEngine`.
 *
 * Strictly read-only: a small constant number of SOQL queries and zero DML. The
 * read never mutates the append-only step-execution trail. The timeline is
 * payload-free / heap-safe: it never loads the potentially large
 * `Error_Details__c`, `Input__c`, or `Output__c` long-text fields. Callers derive
 * error/retry facts from the lightweight fields (`status`, `attempt`) and fetch
 * the full per-step error text for one row via {@link #getStepError}; terminal
 * output comes from {@link WorkflowStatusRead}.
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
   * @description Maximum number of distinct instance Ids the bulk `getHistory`
   * accepts in one call. The bulk read resolves per-instance totals with a grouped
   * aggregate `COUNT()` that returns one `AggregateResult` per step-bearing
   * instance, and Apex aggregate SOQL cannot `queryMore()` past 2,000 rows — a
   * larger batch would throw `Aggregate query does not support queryMore()`. This
   * cap (which also matches the standard Batch Apex `execute()` scope of 2,000)
   * turns that into a clear, up-front input-contract error. Callers with more Ids
   * must split them into batches of this size or fewer. Public so callers can size
   * their own chunking against the documented boundary.
   */
  public static final Integer MAX_INSTANCES_PER_CALL = 2000;

  /**
   * @description Row-budget headroom the bulk scan leaves unused, so a very large
   * batch degrades to graceful truncation rather than consuming the entire
   * per-transaction SOQL row governor (leaving room for any queries the caller
   * runs after `getHistory` returns). Kept small relative to the 50,000-row
   * ceiling.
   */
  private static final Integer SCAN_ROW_SAFETY_MARGIN = 1000;

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
   * `entries` list is empty. Read-only and heap-safe (never loads long-text).
   * Costs at most 2 SOQL queries and zero DML — and exactly ONE query in the
   * common case (rows present and within the row cap): the real total is resolved
   * lazily with a `COUNT()` only when the history is truncated, and instance
   * existence is probed only when no rows are returned. A single instance can never
   * be scan-starved (its scan budget covers its own cap), so this path cannot
   * produce a false-empty history.
   * @param instanceId Id of the workflow instance to read
   * @return the instance's step history, or null when no such instance exists
   */
  public static WorkflowEngine.StepHistory getHistory(Id instanceId) {
    if (instanceId == null) {
      return null;
    }
    // A single instance's scan is tiny (at most the cap plus one), so it needs no
    // budget arithmetic: cap + 1 lets the truncated case be detected cheaply.
    List<Workflow_Step_Execution__c> rows = queryRowsByInstance(
        new Set<Id>{ instanceId },
        MAX_HISTORY_ROWS + 1
      )
      .get(instanceId);

    if (rows == null || rows.isEmpty()) {
      // No rows: distinguish a known step-less instance (empty history) from an
      // unknown Id (null) with a single existence probe.
      return instanceExists(instanceId)
        ? new WorkflowEngine.StepHistory(
            new List<Workflow_Step_Execution__c>(),
            0
          )
        : null;
    }

    // Rows present. Only when the scan hit the cap do we need the real total; an
    // untruncated read stays at the single scan query.
    Integer totalCount = rows.size() > MAX_HISTORY_ROWS
      ? countSteps(instanceId)
      : rows.size();
    return new WorkflowEngine.StepHistory(rows, totalCount);
  }

  /**
   * @description Bulk variant — accepts a list of instance Ids and returns a map
   * from instance Id to its ordered step history. An Id with no matching instance
   * is absent from the map; a known instance with no logged steps is present with
   * an empty `entries` list (mirroring the single-Id null-vs-empty distinction).
   * Uses a bounded, constant number of SOQL queries (≤ 3) and zero DML for valid
   * input.
   *
   * Input contract: at most {@link #MAX_INSTANCES_PER_CALL} distinct instance Ids
   * per call — more throws a `WorkflowEngine.WorkflowException` (the grouped
   * aggregate `COUNT()` cannot page beyond 2,000 rows). For valid input the read
   * never throws a governor or aggregate-`queryMore()` error: the queries are
   * ordered small-first so the large row scan runs LAST, sized from the REMAINING
   * row budget, so it can never overrun `System.LimitException: Too many query
   * rows` — it degrades gracefully to truncation instead. The small grouped
   * `COUNT()` (≤ one aggregate row per instance) and the existence probe run first;
   * the scan then takes whatever budget is left (nothing queries after it).
   *
   * Correctness invariant: a step-bearing instance is NEVER reported as empty. The
   * authoritative `COUNT()` supplies every requested instance's real `totalCount`,
   * so an instance whose rows the scan could not fully retrieve (starved by a
   * larger sibling or by the remaining row budget) still comes back with
   * `isTruncated = true` and its true `totalCount` — never a false-empty history.
   * To get the full `entries` of such a very large history, re-read it singly.
   * Heap-safe: no long-text field is loaded.
   * @param instanceIds instance Ids to read
   * @return map of instance Id to step history (absent key per unmatched Id)
   * @throws WorkflowEngine.WorkflowException when more than
   * {@link #MAX_INSTANCES_PER_CALL} distinct instance Ids are supplied
   */
  public static Map<Id, WorkflowEngine.StepHistory> getHistory(
    List<Id> instanceIds
  ) {
    Map<Id, WorkflowEngine.StepHistory> out = new Map<Id, WorkflowEngine.StepHistory>();
    Set<Id> lookupIds = toLookupIds(instanceIds);
    if (lookupIds.isEmpty()) {
      return out;
    }

    // Input-contract guard — runs BEFORE any query so the grouped aggregate below
    // never hits its 2,000-row queryMore ceiling.
    if (lookupIds.size() > MAX_INSTANCES_PER_CALL) {
      throw new WorkflowEngine.WorkflowException(
        'getHistory supports at most ' +
          MAX_INSTANCES_PER_CALL +
          ' instances per call (Salesforce aggregate SOQL cannot page beyond ' +
          MAX_INSTANCES_PER_CALL +
          ' rows); received ' +
          lookupIds.size() +
          '. Split the Ids into batches of ' +
          MAX_INSTANCES_PER_CALL +
          ' or fewer.'
      );
    }

    // Query 1 (small): the authoritative real step total per instance. Instances
    // absent from the result have zero steps.
    Map<Id, Integer> realTotals = realStepTotals(lookupIds);

    // Query 2 (small, only when there are step-less Ids): an existence probe
    // separates a known step-less instance (present, empty entries) from an
    // unknown Id (absent). Resolved from the COUNT results, so it runs before the
    // big scan.
    Set<Id> steplessIds = new Set<Id>(lookupIds);
    steplessIds.removeAll(realTotals.keySet());
    addExistingSteplessInstances(steplessIds, out);

    // Query 3 (large, LAST): the row scan. Its LIMIT is the ideal number of rows
    // (each instance capped at MAX_HISTORY_ROWS) clamped to the row budget still
    // available after the small queries above — so it can never overrun the row
    // governor. Because it runs last, nothing queries after it.
    Integer desired = 0;
    for (Id instId : realTotals.keySet()) {
      desired += Math.min(realTotals.get(instId), MAX_HISTORY_ROWS);
    }
    Integer scanLimit = resolveScanLimit(
      desired,
      Limits.getLimitQueryRows() - Limits.getQueryRows()
    );
    Map<Id, List<Workflow_Step_Execution__c>> rowsByInstance = scanLimit > 0
      ? queryRowsByInstance(lookupIds, scanLimit)
      : new Map<Id, List<Workflow_Step_Execution__c>>();

    // Build a history for every step-bearing instance. totalCount is authoritative
    // (from the COUNT); the DTO derives isTruncated from totalCount vs the retained
    // entries, so a scan-starved instance is flagged truncated, never false-empty.
    for (Id instId : realTotals.keySet()) {
      List<Workflow_Step_Execution__c> rows = rowsByInstance.containsKey(instId)
        ? rowsByInstance.get(instId)
        : new List<Workflow_Step_Execution__c>();
      out.put(
        instId,
        new WorkflowEngine.StepHistory(rows, realTotals.get(instId))
      );
    }
    return out;
  }

  /**
   * @description Pure helper that sizes the bulk row scan so it can never overrun
   * the SOQL row governor: the scan runs last, so it may consume all remaining row
   * budget less a small safety margin, but no more than the ideal (desired) row
   * count. Returns 0 when there is no budget or nothing to fetch, in which case the
   * caller skips the scan entirely and every instance still gets its authoritative
   * `totalCount` from the COUNT.
   * @param desired the ideal scan row count (sum of per-instance capped totals)
   * @param remainingRowBudget query rows still available this transaction
   * ({@link System.Limits#getLimitQueryRows} minus
   * {@link System.Limits#getQueryRows})
   * @return the scan LIMIT to use, never negative and never above the budget
   */
  @TestVisible
  private static Integer resolveScanLimit(
    Integer desired,
    Integer remainingRowBudget
  ) {
    return Math.max(
      0,
      Math.min(desired, remainingRowBudget - SCAN_ROW_SAFETY_MARGIN)
    );
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
   * single query (bounded by the caller-supplied `scanLimit`) and buckets them per
   * instance in append order. Ordering by instance then append time makes each
   * instance's rows contiguous so a per-instance cap can be applied downstream.
   * @param lookupIds the instances to read
   * @param scanLimit the SOQL LIMIT for the scan (already sized to the row budget)
   * @return map of instance Id to its append-ordered step-execution rows
   */
  private static Map<Id, List<Workflow_Step_Execution__c>> queryRowsByInstance(
    Set<Id> lookupIds,
    Integer scanLimit
  ) {
    Map<Id, List<Workflow_Step_Execution__c>> rowsByInstance = new Map<Id, List<Workflow_Step_Execution__c>>();
    // Deliberately excludes the long-text fields (Error_Details__c / Input__c /
    // Output__c) so the timeline stays heap-bounded; per-step error text is fetched
    // one row at a time via getStepError.
    for (Workflow_Step_Execution__c row : [
      SELECT
        Id,
        Workflow_Instance__c,
        Step_Name__c,
        Status__c,
        Retry_Count__c,
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

  /**
   * @description Returns the full `Error_Details__c` text for a single step
   * execution, or null when the Id is unknown or the row has no error recorded.
   * This is the authoritative per-step "was error text recorded, and what is it"
   * read: the timeline is payload-free, so callers fetch a stack trace here when a
   * step is in a failure `status` (or a retried row, `attempt` &gt; 0, that may
   * carry error detail from an earlier attempt). It loads the long-text for exactly
   * ONE row, so it stays heap-bounded by construction. Costs 1 SOQL query and zero
   * DML.
   * @param executionId Id of the step-execution row
   * ({@link WorkflowEngine.StepHistoryEntry#executionId})
   * @return the recorded error detail, or null when unknown or error-free
   */
  public static String getStepError(Id executionId) {
    if (executionId == null) {
      return null;
    }
    List<Workflow_Step_Execution__c> rows = [
      SELECT Id, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :executionId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return rows.isEmpty() ? null : rows[0].Error_Details__c;
  }
}
