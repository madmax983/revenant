/**
 * @description Reads the engine-health snapshot (issue #127) with max three
 * bounded queries, for all fleet sizes:
 *
 * 1. Active counts: `COUNT(Id)` grouped by name and status.
 * 2. Terminal counts in the window (start, end]: same shape.
 * 3. Oldest active age: `ORDER BY CreatedDate ASC LIMIT k`. The first row of
 *    a name is its oldest row.
 *
 * `COUNT(field)` with `GROUP BY` uses one query row for each group. The age
 * scan uses max k rows. The collector keeps QUERY_RESERVE queries and
 * QUERY_ROW_RESERVE rows free, because a `LimitException` cannot be caught.
 * All queries run in system mode.
 */
public inherited sharing class WorkflowMetricsCollector {
  /** @description SOQL statements to keep free for the caller. */
  public static final Integer QUERY_RESERVE = 10;
  /** @description Query rows to keep free for the caller. */
  public static final Integer QUERY_ROW_RESERVE = 5000;
  private static final Integer QUERY_COUNT = 3;

  private static final Set<String> WINDOW_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled'
  };

  // Maximum groups read by each grouped query.
  @TestVisible
  private static Integer groupRowCap = 2000;
  // Maximum rows read by the age scan.
  @TestVisible
  private static Integer ageScanRowCap = 10000;
  @TestVisible
  private static Boolean forceQueryBudgetExhausted = false;

  /**
   * @description Result of collect().
   */
  public class Result {
    /** @description One row for each definition, sorted by name. */
    public List<WorkflowMetricsSnapshot.DefinitionMetrics> rows = new List<WorkflowMetricsSnapshot.DefinitionMetrics>();
    /** @description True when a cap dropped data. */
    public Boolean truncated = false;
    /** @description One note for each cap that dropped data. */
    public List<String> notes = new List<String>();
  }

  /**
   * @description Reads the snapshot. A definition is present when it has
   * an active instance or a counted terminal instance in the window.
   * @param windowStart Start of the window (not included).
   * @param snapshotAt End of the window (included) and the age reference.
   * @return The snapshot, or null when the query budget is too low.
   */
  public static Result collect(Datetime windowStart, Datetime snapshotAt) {
    Integer ageRows = ageScanBudget();
    if (ageRows == null) {
      return null;
    }
    Result result = new Result();
    Map<String, WorkflowMetricsSnapshot.DefinitionMetrics> byName = new Map<String, WorkflowMetricsSnapshot.DefinitionMetrics>();

    List<AggregateResult> active = queryActiveCounts();
    Integer activeTotal = 0;
    for (AggregateResult ar : capGroups(active, result, 'active')) {
      Integer n = (Integer) ar.get('n');
      activeTotal += n;
      addActive(row(byName, (String) ar.get('wf')), (String) ar.get('st'), n);
    }

    List<AggregateResult> terminal = queryWindowCounts(windowStart, snapshotAt);
    for (AggregateResult ar : capGroups(terminal, result, 'window')) {
      addWindow(
        row(byName, (String) ar.get('wf')),
        (String) ar.get('st'),
        (Integer) ar.get('n')
      );
    }

    if (activeTotal > 0) {
      Integer missing = applyOldestAges(
        byName,
        snapshotAt,
        Math.min(ageRows, activeTotal)
      );
      if (missing > 0) {
        result.truncated = true;
        result.notes.add(
          'The age scan hit the cap of ' +
            ageRows +
            ' rows. ' +
            missing +
            ' definitions have no age.'
        );
      }
    }

    List<String> names = new List<String>(byName.keySet());
    names.sort();
    for (String name : names) {
      result.rows.add(byName.get(name));
    }
    return result;
  }

  /**
   * @description Active counts grouped by name and status. Reads max
   * groupRowCap + 1 groups, so a caller can see that the cap is hit.
   * @return Rows with the aliases wf, st and n.
   */
  @TestVisible
  private static List<AggregateResult> queryActiveCounts() {
    Set<String> activeStatuses = WorkflowEngine.ACTIVE_STATUSES;
    Integer lim = groupRowCap + 1;
    return [
      SELECT Workflow_Name__c wf, Status__c st, COUNT(Id) n
      FROM Workflow_Instance__c
      WHERE Status__c IN :activeStatuses
      WITH SYSTEM_MODE
      GROUP BY Workflow_Name__c, Status__c
      ORDER BY Workflow_Name__c, Status__c
      LIMIT :lim
    ];
  }

  private static List<AggregateResult> queryWindowCounts(
    Datetime windowStart,
    Datetime snapshotAt
  ) {
    Integer lim = groupRowCap + 1;
    return [
      SELECT Workflow_Name__c wf, Status__c st, COUNT(Id) n
      FROM Workflow_Instance__c
      WHERE
        Status__c IN :WINDOW_STATUSES
        AND Terminal_At__c > :windowStart
        AND Terminal_At__c <= :snapshotAt
      WITH SYSTEM_MODE
      GROUP BY Workflow_Name__c, Status__c
      ORDER BY Workflow_Name__c, Status__c
      LIMIT :lim
    ];
  }

  // Reads the oldest rows first. The first row of a name gives its age. The
  // loop stops when each active name has an age. Returns the number of
  // active names with no age.
  private static Integer applyOldestAges(
    Map<String, WorkflowMetricsSnapshot.DefinitionMetrics> byName,
    Datetime snapshotAt,
    Integer scanRows
  ) {
    Set<String> activeStatuses = WorkflowEngine.ACTIVE_STATUSES;
    Integer remaining = countActiveNames(byName);
    for (List<Workflow_Instance__c> batch : [
      SELECT Workflow_Name__c, CreatedDate
      FROM Workflow_Instance__c
      WHERE Status__c IN :activeStatuses
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT :scanRows
    ]) {
      for (Workflow_Instance__c inst : batch) {
        WorkflowMetricsSnapshot.DefinitionMetrics m = byName.get(
          key(inst.Workflow_Name__c)
        );
        if (m != null && m.oldestActiveAgeSeconds == null) {
          m.oldestActiveAgeSeconds = Math.max(
            0L,
            (snapshotAt.getTime() - inst.CreatedDate.getTime()) / 1000
          );
          remaining--;
        }
      }
      if (remaining <= 0) {
        break;
      }
    }
    return remaining;
  }

  // Rows the age scan can read, or null when the budget cannot hold the
  // three queries and the reserve.
  private static Integer ageScanBudget() {
    if (forceQueryBudgetExhausted) {
      return null;
    }
    if (
      Limits.getQueries() + QUERY_COUNT + QUERY_RESERVE >
      Limits.getLimitQueries()
    ) {
      return null;
    }
    Integer freeRows =
      Limits.getLimitQueryRows() -
      Limits.getQueryRows() -
      QUERY_ROW_RESERVE -
      2 * (groupRowCap + 1);
    if (freeRows < 1) {
      return null;
    }
    return Math.min(ageScanRowCap, freeRows);
  }

  private static List<AggregateResult> capGroups(
    List<AggregateResult> groups,
    Result result,
    String label
  ) {
    if (groups.size() <= groupRowCap) {
      return groups;
    }
    result.truncated = true;
    result.notes.add(
      'The ' + label + ' query hit the cap of ' + groupRowCap + ' groups.'
    );
    List<AggregateResult> kept = new List<AggregateResult>();
    for (Integer i = 0; i < groupRowCap; i++) {
      kept.add(groups[i]);
    }
    return kept;
  }

  private static Integer countActiveNames(
    Map<String, WorkflowMetricsSnapshot.DefinitionMetrics> byName
  ) {
    Integer n = 0;
    for (WorkflowMetricsSnapshot.DefinitionMetrics m : byName.values()) {
      if (activeCount(m) > 0) {
        n++;
      }
    }
    return n;
  }

  private static Integer activeCount(
    WorkflowMetricsSnapshot.DefinitionMetrics m
  ) {
    return m.pending +
      m.running +
      m.suspended +
      m.paused +
      m.definitionChanged +
      m.cancelling +
      m.compensating +
      m.compensationFailed;
  }

  // A blank name is a valid group. The map key must not be null.
  private static String key(String workflowName) {
    return workflowName == null ? '' : workflowName;
  }

  private static WorkflowMetricsSnapshot.DefinitionMetrics row(
    Map<String, WorkflowMetricsSnapshot.DefinitionMetrics> byName,
    String workflowName
  ) {
    String k = key(workflowName);
    WorkflowMetricsSnapshot.DefinitionMetrics m = byName.get(k);
    if (m == null) {
      m = new WorkflowMetricsSnapshot.DefinitionMetrics(workflowName);
      byName.put(k, m);
    }
    return m;
  }

  private static void addActive(
    WorkflowMetricsSnapshot.DefinitionMetrics m,
    String status,
    Integer n
  ) {
    switch on status {
      when 'Pending' {
        m.pending += n;
      }
      when 'Running' {
        m.running += n;
      }
      when 'Suspended' {
        m.suspended += n;
      }
      when 'Paused' {
        m.paused += n;
      }
      when 'DefinitionChanged' {
        m.definitionChanged += n;
      }
      when 'Cancelling' {
        m.cancelling += n;
      }
      when 'Compensating' {
        m.compensating += n;
      }
      when 'CompensationFailed' {
        m.compensationFailed += n;
      }
    }
  }

  private static void addWindow(
    WorkflowMetricsSnapshot.DefinitionMetrics m,
    String status,
    Integer n
  ) {
    switch on status {
      when 'Completed' {
        m.completedInWindow += n;
      }
      when 'Failed' {
        m.failedInWindow += n;
      }
      when 'Compensated' {
        m.compensatedInWindow += n;
      }
      when 'Cancelled' {
        m.cancelledInWindow += n;
      }
    }
  }
}
