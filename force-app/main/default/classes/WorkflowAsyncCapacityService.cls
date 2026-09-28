/**
 * @description Reads the data for the Async Apex Capacity panel in System Doctor (#129).
 * Cost: max 1 SOQL (one AsyncApexJob aggregate, max 3 query rows). OrgLimits and the
 * config read cost no SOQL. It writes no records. WorkflowOrchestrator does not call it.
 */
public inherited sharing class WorkflowAsyncCapacityService {
  // System.OrgLimits key of the rolling 24 hour async Apex execution count.
  private static final String DAILY_ASYNC_KEY = 'DailyAsyncApexExecutions';
  // System.OrgLimits key of the elastic daily limit. Present only in some orgs.
  private static final String DAILY_ELASTIC_KEY = 'DailyAsyncApexElasticExecutions';

  private static final String JOB_HOLDING = 'Holding';
  private static final String JOB_QUEUED = 'Queued';
  private static final String JOB_PROCESSING = 'Processing';
  private static final List<String> JOB_STATUSES = new List<String>{
    JOB_HOLDING,
    JOB_QUEUED,
    JOB_PROCESSING
  };

  private class CapacityReadException extends Exception {
  }

  // Test hook. When not null, it replaces the config text.
  @TestVisible
  private static String thresholdsOverride = null;

  // Test hook. When true, the AsyncApexJob read throws.
  @TestVisible
  private static Boolean failJobQuery = false;

  /**
   * @description Returns the async Apex capacity envelope. It checks the dashboard view
   * gate first.
   * @return A map with asOfMs, status, chainAtRisk, thresholds, metrics and jobCounts.
   */
  public static Map<String, Object> asyncCapacity() {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      return readCapacity();
    } catch (Exception ex) {
      throw WorkflowDashboardSupport.auraError(ex.getMessage());
    }
  }

  /**
   * @description Reads the org limit, the job counts and the thresholds. No gate.
   * @return The capacity envelope.
   */
  @TestVisible
  private static Map<String, Object> readCapacity() {
    AsyncCapacityEvaluator.Reading r = new AsyncCapacityEvaluator.Reading();
    readDailyLimit(r);
    readJobCounts(r);
    Map<String, Object> result = AsyncCapacityEvaluator.evaluate(
      r,
      AsyncCapacityEvaluator.parseThresholds(thresholdsText())
    );
    result.put('asOfMs', System.currentTimeMillis());
    return result;
  }

  // Leaves the daily values null when the org has no such limit.
  private static void readDailyLimit(AsyncCapacityEvaluator.Reading r) {
    Map<String, System.OrgLimit> limitsMap = System.OrgLimits.getMap();
    if (limitsMap.containsKey(DAILY_ASYNC_KEY)) {
      System.OrgLimit orgLimit = limitsMap.get(DAILY_ASYNC_KEY);
      r.dailyUsed = orgLimit.getValue();
      r.dailyLimit = orgLimit.getLimit();
    }
    if (limitsMap.containsKey(DAILY_ELASTIC_KEY)) {
      r.dailyElasticLimit = limitsMap.get(DAILY_ELASTIC_KEY).getLimit();
    }
  }

  // One aggregate query. The SOQL reference: COUNT(field) with GROUP BY costs one query
  // row per group (max 3). The test readCostsAtMostOneSoqlAndNoDml measures this.
  // Batch jobs in Preparing are not counted.
  // A failed read leaves jobsKnown false, so the flex metric shows Unknown.
  private static void readJobCounts(AsyncCapacityEvaluator.Reading r) {
    try {
      if (failJobQuery) {
        throw new CapacityReadException('Test: job query failed');
      }
      Map<String, Integer> byStatus = new Map<String, Integer>{
        JOB_HOLDING => 0,
        JOB_QUEUED => 0,
        JOB_PROCESSING => 0
      };
      for (AggregateResult ar : [
        SELECT Status, COUNT(Id) cnt
        FROM AsyncApexJob
        WHERE Status IN :JOB_STATUSES
        WITH SYSTEM_MODE
        GROUP BY Status
      ]) {
        byStatus.put((String) ar.get('Status'), (Integer) ar.get('cnt'));
      }
      r.holding = byStatus.get(JOB_HOLDING);
      r.queued = byStatus.get(JOB_QUEUED);
      r.processing = byStatus.get(JOB_PROCESSING);
      r.jobsKnown = true;
    } catch (Exception ex) {
      r.jobsKnown = false;
    }
  }

  // Custom metadata getInstance costs no SOQL.
  private static String thresholdsText() {
    if (thresholdsOverride != null) {
      return thresholdsOverride;
    }
    Revenant_Config__mdt config = Revenant_Config__mdt.getInstance('Default');
    return config == null ? null : config.Async_Capacity_Thresholds__c;
  }
}
