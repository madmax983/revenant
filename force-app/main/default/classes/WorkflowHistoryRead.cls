/**
 * @description Read API for a workflow instance's ordered step-execution timeline.
 * Returns the append-order history of `Workflow_Step_Execution__c` rows for an
 * instance (single or bulk) projected into the resident public DTOs
 * `WorkflowEngine.StepHistoryEntry` and `WorkflowEngine.StepHistory`. This is the
 * timeline complement to {@link WorkflowStatusRead} (which returns the terminal
 * outcome): callers get every step that ran, in order, with attempt counts,
 * timing, error text, and a forward-vs-compensation flag, without coupling to the
 * internal `Workflow_Step_Execution__c` field API names.
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
    Map<Id, WorkflowEngine.StepHistory> byId = getHistory(
      new List<Id>{ instanceId }
    );
    return byId.get(instanceId);
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
    if (instanceIds == null || instanceIds.isEmpty()) {
      return out;
    }

    Set<Id> lookupIds = new Set<Id>(instanceIds);
    lookupIds.remove(null);
    if (lookupIds.isEmpty()) {
      return out;
    }

    // Bound the scan so no single instance can exhaust the heap. The clamp keeps
    // the LIMIT within the SOQL row ceiling for large batches.
    Integer scanLimit = Math.min(
      50000,
      lookupIds.size() * (MAX_HISTORY_ROWS + 1)
    );

    // One query for the whole batch (constant SOQL). Ordered by instance so each
    // instance's rows are contiguous, then by append order within the instance.
    List<Workflow_Step_Execution__c> rows = [
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
    ];

    // Bucket rows per instance, capping each at MAX_HISTORY_ROWS and flagging when
    // an instance had more rows than the cap.
    Map<Id, List<WorkflowEngine.StepHistoryEntry>> entriesByInstance = new Map<Id, List<WorkflowEngine.StepHistoryEntry>>();
    Map<Id, Boolean> truncatedByInstance = new Map<Id, Boolean>();
    for (Workflow_Step_Execution__c row : rows) {
      Id instId = row.Workflow_Instance__c;
      List<WorkflowEngine.StepHistoryEntry> entries = entriesByInstance.get(
        instId
      );
      if (entries == null) {
        entries = new List<WorkflowEngine.StepHistoryEntry>();
        entriesByInstance.put(instId, entries);
        truncatedByInstance.put(instId, false);
      }
      if (entries.size() >= MAX_HISTORY_ROWS) {
        truncatedByInstance.put(instId, true);
        continue;
      }
      entries.add(new WorkflowEngine.StepHistoryEntry(row));
    }

    // Instances that produced at least one step row are known to exist.
    for (Id instId : entriesByInstance.keySet()) {
      out.put(
        instId,
        new WorkflowEngine.StepHistory(
          entriesByInstance.get(instId),
          truncatedByInstance.get(instId)
        )
      );
    }

    // For the remaining requested Ids (no step rows), a single existence query
    // separates known-but-empty (present with empty entries) from unknown (absent).
    Set<Id> withoutRows = new Set<Id>(lookupIds);
    withoutRows.removeAll(entriesByInstance.keySet());
    if (!withoutRows.isEmpty()) {
      for (Workflow_Instance__c inst : [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Id IN :withoutRows
        WITH SYSTEM_MODE
      ]) {
        out.put(
          inst.Id,
          new WorkflowEngine.StepHistory(
            new List<WorkflowEngine.StepHistoryEntry>(),
            false
          )
        );
      }
    }

    return out;
  }
}
