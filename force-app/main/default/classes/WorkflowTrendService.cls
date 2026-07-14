/**
 * @description Computes the per-definition success-rate and throughput trend over a
 * selectable recent window for the dashboard. Extracted from WorkflowDashboardController;
 * uses a single GROUP BY aggregate (no per-instance rows materialized) and runs WITH
 * SYSTEM_MODE.
 */
public inherited sharing class WorkflowTrendService {
  // Selectable trend windows, mapped to a span in hours. Blank/unrecognized keys fall
  // back to TREND_DEFAULT_WINDOW.
  private static final Map<String, Integer> TREND_WINDOW_HOURS = new Map<String, Integer>{
    '1h' => 1,
    '24h' => 24,
    '7d' => 168
  };
  private static final String TREND_DEFAULT_WINDOW = '24h';

  // Terminal statuses classified as a successful outcome. CompensationFailed is
  // intentionally absent from FAILURE_STATUSES: it is a non-terminal status
  // (WorkflowInstanceTrigger never stamps Terminal_At__c for it), so the windowed query
  // can never surface such instances.
  private static final Set<String> SUCCESS_STATUSES = new Set<String>{
    'Completed',
    'ContinuedAsNew'
  };
  private static final Set<String> FAILURE_STATUSES = new Set<String>{
    'Failed',
    'Compensated',
    'Cancelled'
  };

  /**
   * @description Per-definition success-rate and throughput over a selectable recent
   * window. The window is computed against Terminal_At__c (not CreatedDate) so a
   * long-running instance that *finished* inside the window is counted in that window.
   * Uses a single GROUP BY aggregate — no per-instance rows are materialized into heap.
   *
   * Governor note: Salesforce counts the underlying rows scanned by an aggregate query
   * toward the 50,000 synchronous query-row limit. On orgs with >50k terminal instances
   * in the selected window the query will throw LimitException.
   *
   * @param windowKey one of '1h' | '24h' | '7d' (blank/unknown → 24h)
   * @return Map with 'windowKey', 'windowHours', and 'rows' — a List<Map<String,Object>>
   *         (one row per Workflow_Name__c with terminal activity in the window), sorted
   *         worst-first (highest failure count). Empty 'rows' when nothing terminated in
   *         the window.
   */
  public static Map<String, Object> computeTrends(String windowKey) {
    WorkflowDashboardSupport.checkAuthorization();

    String resolvedKey = TREND_WINDOW_HOURS.containsKey(windowKey)
      ? windowKey
      : TREND_DEFAULT_WINDOW;
    Integer windowHours = TREND_WINDOW_HOURS.get(resolvedKey);
    Datetime since = Datetime.now().addHours(-windowHours);

    // Aggregate by definition + status. The Terminal_At__c predicate restricts to
    // terminal instances (active instances have a null Terminal_At__c), so every returned
    // row is already a terminal outcome to be bucketed.
    Map<String, WorkflowTrendAggregate> byDefinition = new Map<String, WorkflowTrendAggregate>();
    for (AggregateResult ar : [
      SELECT Workflow_Name__c, Status__c, COUNT(Id) cnt
      FROM Workflow_Instance__c
      WHERE Terminal_At__c >= :since
      WITH SYSTEM_MODE
      GROUP BY Workflow_Name__c, Status__c
    ]) {
      String name = (String) ar.get('Workflow_Name__c');
      String stat = (String) ar.get('Status__c');
      Integer count = (Integer) ar.get('cnt');

      WorkflowTrendAggregate agg = byDefinition.get(name);
      if (agg == null) {
        agg = new WorkflowTrendAggregate(name);
        byDefinition.put(name, agg);
      }
      if (SUCCESS_STATUSES.contains(stat)) {
        agg.successCount += count;
      } else if (FAILURE_STATUSES.contains(stat)) {
        agg.failureCount += count;
      }
    }

    List<WorkflowTrendAggregate> aggregates = byDefinition.values();
    aggregates.sort(); // worst-first (highest failure count, then name)

    List<Map<String, Object>> rows = new List<Map<String, Object>>();
    for (WorkflowTrendAggregate agg : aggregates) {
      rows.add(agg.toRow(windowHours));
    }

    return new Map<String, Object>{
      'windowKey' => resolvedKey,
      'windowHours' => windowHours,
      'rows' => rows
    };
  }

  /**
   * Accumulates per-definition success/failure terminal counts and renders the display
   * row. Comparable so the panel surfaces the sickest definition first (highest failure
   * count, ties broken by name).
   */
  private class WorkflowTrendAggregate implements Comparable {
    String workflowName;
    Integer successCount = 0;
    Integer failureCount = 0;

    WorkflowTrendAggregate(String workflowName) {
      this.workflowName = workflowName;
    }

    Integer terminalCount() {
      return successCount + failureCount;
    }

    Map<String, Object> toRow(Integer windowHours) {
      Integer terminal = terminalCount();
      // terminal is always >= 1 for a row that exists, but guard anyway so the
      // contract is divide-by-zero-safe for any caller.
      Decimal successRate = terminal == 0
        ? null
        : (Decimal.valueOf(successCount) * 100)
            .divide(terminal, 1, System.RoundingMode.HALF_UP);
      Decimal throughputPerHour = windowHours == 0
        ? null
        : Decimal.valueOf(terminal)
            .divide(windowHours, 2, System.RoundingMode.HALF_UP);
      return new Map<String, Object>{
        'workflowName' => workflowName,
        'terminalCount' => terminal,
        'successCount' => successCount,
        'failureCount' => failureCount,
        'successRate' => successRate,
        'throughputPerHour' => throughputPerHour
      };
    }

    /**
     * @description Orders aggregates worst-first: higher failure count first, ties broken
     * by workflow name.
     * @param other The other WorkflowTrendAggregate to compare against.
     * @return A negative, zero, or positive value per the Comparable contract.
     */
    public Integer compareTo(Object other) {
      WorkflowTrendAggregate that = (WorkflowTrendAggregate) other;
      if (this.failureCount != that.failureCount) {
        return that.failureCount - this.failureCount; // higher failures first
      }
      return this.workflowName.compareTo(that.workflowName);
    }
  }
}
