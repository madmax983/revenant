/**
 * @description Governor-limit yielding logic, split out of StepContext. Reports
 * whether the current transaction is approaching a monitored governor limit so a
 * step can yield before hitting a hard limit. StepContext.shouldYield() delegates
 * here (to the differently named isNearingLimit()) so the author-facing method
 * keeps its name while the branch-heavy logic lives off StepContext.
 */
public inherited sharing class StepGovernor {
  private static Double cachedAsyncFraction = null;

  @TestVisible
  private static Double mockQueryRowsFraction = null;
  @TestVisible
  private static Double mockAsyncExecutionsFraction = null;

  /**
   * @description True if any monitored limit (CPU, SOQL, DML statements, DML
   * rows, Heap size, or Daily Async Apex Executions) is more than 80% consumed,
   * so the step should yield.
   * @return True if the transaction is nearing a governor limit.
   */
  public static Boolean isNearingLimit() {
    if (exceedsThreshold(Limits.getCpuTime(), Limits.getLimitCpuTime())) {
      return true;
    }
    if (exceedsThreshold(Limits.getQueries(), Limits.getLimitQueries())) {
      return true;
    }
    Double queryRowsFraction = mockQueryRowsFraction != null
      ? mockQueryRowsFraction
      : fractionOf(Limits.getQueryRows(), Limits.getLimitQueryRows());
    if (queryRowsFraction > 0.80) {
      return true;
    }
    if (
      exceedsThreshold(
        Limits.getDmlStatements(),
        Limits.getLimitDmlStatements()
      )
    ) {
      return true;
    }
    if (exceedsThreshold(Limits.getDmlRows(), Limits.getLimitDmlRows())) {
      return true;
    }
    if (exceedsThreshold(Limits.getHeapSize(), Limits.getLimitHeapSize())) {
      return true;
    }
    Double asyncFraction = asyncExecutionsFraction();
    return asyncFraction != null && asyncFraction > 0.80;
  }

  // 0.0 when the limit is non-positive, else current/limit as a fraction.
  private static Double fractionOf(Integer current, Integer max) {
    return max > 0 ? ((Double) current / max) : 0.0;
  }

  // True when current consumes more than 80% of a positive limit.
  private static Boolean exceedsThreshold(Integer current, Integer max) {
    return max > 0 && ((Double) current / max) > 0.80;
  }

  // Daily Async Apex Executions fraction (accounts for Beta Elastic Limits if
  // enabled). Uses the test mock when set, else the cached org-limit reading.
  private static Double asyncExecutionsFraction() {
    if (mockAsyncExecutionsFraction != null) {
      return mockAsyncExecutionsFraction;
    }
    if (cachedAsyncFraction != null) {
      return cachedAsyncFraction;
    }
    Map<String, System.OrgLimit> limitsMap = System.OrgLimits.getMap();
    if (!limitsMap.containsKey('DailyAsyncApexExecutions')) {
      return null;
    }
    System.OrgLimit dailyLimitObj = limitsMap.get('DailyAsyncApexExecutions');
    Integer limitValue = dailyLimitObj.getValue();
    Integer maxLimit = dailyLimitObj.getLimit();
    if (limitsMap.containsKey('DailyAsyncApexElasticExecutions')) {
      maxLimit = limitsMap.get('DailyAsyncApexElasticExecutions').getLimit();
    }
    if (maxLimit > 0) {
      cachedAsyncFraction = (Double) limitValue / maxLimit;
    }
    return cachedAsyncFraction;
  }
}
