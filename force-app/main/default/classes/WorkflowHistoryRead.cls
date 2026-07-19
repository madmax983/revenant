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
   * A terminal step has a settled `endedAt`/`durationMs`; any other status is
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
   * `entries` list is empty. Costs at most 2 SOQL queries and zero DML.
   * @param instanceId Id of the workflow instance to read
   * @return the instance's step history, or null when no such instance exists
   */
  public static WorkflowEngine.StepHistory getHistory(Id instanceId) {
    if (instanceId == null) {
      return null;
    }
    return getHistory(new List<Id>{ instanceId }).get(instanceId);
  }

  /**
   * @description Bulk variant — accepts a list of instance Ids and returns a map
   * from instance Id to its ordered step history. An Id with no matching instance
   * is absent from the map; a known instance with no logged steps is present with
   * an empty `entries` list (mirroring the single-Id null-vs-empty distinction).
   * Uses a bounded, constant number of SOQL queries regardless of list size (at
   * most 2) and zero DML.
   *
   * Per-instance rows are capped at {@link #MAX_HISTORY_ROWS}. To stay heap-bounded
   * the step scan is limited to `ids.size() * (MAX_HISTORY_ROWS + 1)` rows (clamped
   * to the SOQL row ceiling); in the pathological case where a single instance's
   * trail alone exhausts that budget, later instances in the same batch may
   * under-report — read such very long histories one Id at a time.
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

    // One query for the whole batch (constant SOQL), grouped per instance in
    // append order.
    Map<Id, List<Workflow_Step_Execution__c>> rowsByInstance = queryRowsByInstance(
      lookupIds
    );
    for (Id instId : rowsByInstance.keySet()) {
      out.put(
        instId,
        new WorkflowEngine.StepHistory(
          rowsByInstance.get(instId),
          MAX_HISTORY_ROWS
        )
      );
    }

    // A single existence query separates known-but-empty instances (present with
    // empty entries) from unknown Ids (absent from the map).
    Set<Id> withoutRows = new Set<Id>(lookupIds);
    withoutRows.removeAll(rowsByInstance.keySet());
    addKnownEmptyInstances(withoutRows, out);
    return out;
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
   * @description Adds a known instance that logged no step rows to the result as
   * an empty `StepHistory`, so callers can distinguish it from an unknown Id
   * (which stays absent from the map). Costs one SOQL query when there is at least
   * one such Id, zero otherwise.
   * @param candidateIds requested Ids that produced no step rows
   * @param out the result map to populate in place
   */
  private static void addKnownEmptyInstances(
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
          MAX_HISTORY_ROWS
        )
      );
    }
  }
}
