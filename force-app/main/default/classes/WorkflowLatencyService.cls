/**
 * @description Computes read-only latency analytics for a single workflow definition over a
 * selectable time window: end-to-end instance-duration percentiles (p50/p95/p99/max) from
 * Terminal_At__c − CreatedDate on terminal Workflow_Instance__c records, and a ranking of
 * steps by median wall-clock duration derived from consecutive append-only
 * Workflow_Step_Execution__c.CreatedDate deltas within each instance.
 *
 * Governor safety: the instance sample is bounded to the most-recent INSTANCE_SAMPLE_CAP
 * terminal instances in the window (a row-returning query with LIMIT — never a LIMIT on a
 * non-grouped aggregate), and the step-execution scan for those instances is bounded to
 * STEP_SCAN_CAP rows. When either bound is hit the result carries an isCapped flag so the UI
 * can show an explicit "sampled / window truncated" indicator rather than silently reporting
 * a truncated window. All percentile and median math is done in Apex (SOQL has no PERCENTILE
 * function). Strictly read-only: Terminal_At__c is read, never written; no DML, no events, no
 * jobs. All SOQL runs WITH SYSTEM_MODE.
 */
public inherited sharing class WorkflowLatencyService {
  // Selectable windows, mapped to a span in hours. Blank/unrecognized keys mean "all time"
  // (resolveWindowStart returns null → no Terminal_At__c lower bound, still LIMIT-bounded).
  private static final Map<String, Integer> LATENCY_WINDOW_HOURS = new Map<String, Integer>{
    '1h' => 1,
    '24h' => 24,
    '7d' => 168
  };

  // Most-recent terminal instances sampled per definition+window. The percentile set is
  // computed from these rows; if this many rows come back the window was truncated.
  private static final Integer INSTANCE_SAMPLE_CAP = 2000;

  // Upper bound on step-execution rows scanned for the sampled instances. Independent of the
  // instance cap because a definition may record many steps per instance.
  private static final Integer STEP_SCAN_CAP = 50000;

  // Test-only cap overrides so the truncation path can be exercised with bounded seeding
  // (a handful of records) instead of materializing the production caps. Null in production.
  @TestVisible
  private static Integer instanceSampleCapOverride = null;
  @TestVisible
  private static Integer stepScanCapOverride = null;

  // Effective instance-sample cap (test override when set, else the production constant).
  private static Integer instanceSampleCap() {
    return instanceSampleCapOverride != null
      ? instanceSampleCapOverride
      : INSTANCE_SAMPLE_CAP;
  }

  // Effective step-scan cap (test override when set, else the production constant).
  private static Integer stepScanCap() {
    return stepScanCapOverride != null ? stepScanCapOverride : STEP_SCAN_CAP;
  }

  /**
   * @description Returns end-to-end duration percentiles and a median-wall-clock step ranking
   * for one workflow definition over the given window. Percentiles are computed by the
   * nearest-rank method over the sorted list of terminal-instance durations
   * (Terminal_At__c − CreatedDate, in milliseconds); per-step wall-clock is the delta between
   * consecutive step-execution CreatedDate values within an instance, attributed to the
   * earlier step, and each step is ranked by its median across the sample (slowest first).
   * Wall-clock durations deliberately include durable waits (sleeps, retries, wait-for-signal).
   * @param workflowName The workflow definition name to analyze; blank returns an empty result.
   * @param windowKey One of '1h' | '24h' | '7d'; blank/unknown means all time.
   * @return A map with the window, cap metadata and isCapped flag, sampleSize, the p50/p95/p99/
   *         max duration milliseconds, and the per-step median ranking rows.
   */
  public static Map<String, Object> definitionLatency(
    String workflowName,
    String windowKey
  ) {
    WorkflowDashboardSupport.checkAuthorization();

    String resolvedWindow = String.isNotBlank(windowKey) ? windowKey : 'all';

    if (String.isBlank(workflowName)) {
      return emptyResult(resolvedWindow);
    }

    Datetime since = resolveWindowStart(windowKey);
    List<Workflow_Instance__c> instances = queryTerminalInstances(
      workflowName,
      since
    );

    Boolean instancesCapped = (instances.size() >= instanceSampleCap());

    // End-to-end durations (ms), ascending-sorted, for the sampled terminal instances.
    List<Long> durations = WorkflowLatencyStats.sortedDurations(instances);
    Set<Id> instanceIds = new Map<Id, Workflow_Instance__c>(instances).keySet();

    // Per-step median wall-clock ranking over the sampled instances' step executions.
    Boolean stepsCapped = false;
    List<Map<String, Object>> stepRows = new List<Map<String, Object>>();
    if (!instanceIds.isEmpty()) {
      List<Workflow_Step_Execution__c> stepExecs = queryStepExecutions(
        instanceIds
      );
      stepsCapped = (stepExecs.size() >= stepScanCap());
      stepRows = WorkflowLatencyStats.rankStepsByMedianWallClock(stepExecs);
    }

    return new Map<String, Object>{
      'workflowName' => workflowName,
      'windowKey' => resolvedWindow,
      'capLimit' => instanceSampleCap(),
      'isCapped' => (instancesCapped || stepsCapped),
      'sampleSize' => durations.size(),
      'p50Ms' => WorkflowLatencyStats.percentile(durations, 50),
      'p95Ms' => WorkflowLatencyStats.percentile(durations, 95),
      'p99Ms' => WorkflowLatencyStats.percentile(durations, 99),
      'maxMs' => WorkflowLatencyStats.maxDuration(durations),
      'steps' => stepRows
    };
  }

  // Empty/zeroed result shape used for a blank workflow name or no matching instances.
  private static Map<String, Object> emptyResult(String resolvedWindow) {
    return new Map<String, Object>{
      'workflowName' => '',
      'windowKey' => resolvedWindow,
      'capLimit' => INSTANCE_SAMPLE_CAP,
      'isCapped' => false,
      'sampleSize' => 0,
      'p50Ms' => null,
      'p95Ms' => null,
      'p99Ms' => null,
      'maxMs' => null,
      'steps' => new List<Map<String, Object>>()
    };
  }

  // Resolves the start of a recognized window (blank/unknown → null = "all time").
  private static Datetime resolveWindowStart(String windowKey) {
    if (
      String.isBlank(windowKey) || !LATENCY_WINDOW_HOURS.containsKey(windowKey)
    ) {
      return null;
    }
    return Datetime.now().addHours(-LATENCY_WINDOW_HOURS.get(windowKey));
  }

  // Most-recent terminal instances (non-null Terminal_At__c) for the definition, optionally
  // bounded to the window. Row-returning query, so the LIMIT is legal and enforces the cap.
  private static List<Workflow_Instance__c> queryTerminalInstances(
    String workflowName,
    Datetime since
  ) {
    Integer cap = instanceSampleCap();
    if (since != null) {
      return [
        SELECT Id, CreatedDate, Terminal_At__c
        FROM Workflow_Instance__c
        WHERE
          Workflow_Name__c = :workflowName
          AND Terminal_At__c != NULL
          AND Terminal_At__c >= :since
        WITH SYSTEM_MODE
        ORDER BY Terminal_At__c DESC
        LIMIT :cap
      ];
    }
    return [
      SELECT Id, CreatedDate, Terminal_At__c
      FROM Workflow_Instance__c
      WHERE Workflow_Name__c = :workflowName AND Terminal_At__c != NULL
      WITH SYSTEM_MODE
      ORDER BY Terminal_At__c DESC
      LIMIT :cap
    ];
  }

  // Ordered step-execution rows for the sampled instances. Row-returning query with a bounded
  // LIMIT; ordering by instance then CreatedDate lets consecutive deltas be computed in Apex.
  private static List<Workflow_Step_Execution__c> queryStepExecutions(
    Set<Id> instanceIds
  ) {
    Integer cap = stepScanCap();
    return [
      SELECT Workflow_Instance__c, Step_Name__c, CreatedDate
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :instanceIds
      WITH SYSTEM_MODE
      ORDER BY Workflow_Instance__c, CreatedDate ASC
      LIMIT :cap
    ];
  }
}
