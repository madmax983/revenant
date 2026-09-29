/**
 * @description Reads the data for the Async Apex Capacity panel in System Doctor (#129).
 * Cost: max 1 SOQL (one AsyncApexJob read, max JOB_SCAN_LIMIT + 1 query rows). OrgLimits
 * and the config read cost no SOQL. It writes no records. WorkflowOrchestrator does not
 * call it.
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

  // Max job rows that the read counts. One more row tells that the read stopped.
  @TestVisible
  private static final Integer JOB_SCAN_LIMIT = 2000;

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
   * @description Gives the overall status for the global admission brake
   * (issue #136). No gate. Cost: max 1 SOQL. The brake calls it only for a new
   * start that it governs, never for an in-flight instance.
   * @return HEALTHY, DEGRADED, CRITICAL or UNKNOWN, or null when the read fails.
   */
  public static String currentStatus() {
    try {
      return (String) readCapacity().get('status');
    } catch (Exception ex) {
      return null;
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

  // One row query, max JOB_SCAN_LIMIT + 1 rows. A grouped SUM() costs one query row
  // for each job with no cap, so the read counts the rows itself. ORDER BY JobType puts
  // BatchApex rows (the rows with many chunks) first when the read stops at the cap.
  // Batch jobs in Preparing are not counted.
  // A failed read leaves jobsKnown false, so the pending executions metric shows Unknown.
  private static void readJobCounts(AsyncCapacityEvaluator.Reading r) {
    try {
      if (failJobQuery) {
        throw new CapacityReadException('Test: job query failed');
      }
      Integer rowLimit = JOB_SCAN_LIMIT + 1;
      List<AsyncApexJob> jobs = [
        SELECT Status, JobType, TotalJobItems, JobItemsProcessed
        FROM AsyncApexJob
        WHERE Status IN :JOB_STATUSES
        WITH SYSTEM_MODE
        ORDER BY JobType ASC
        LIMIT :rowLimit
      ];
      Map<String, Integer> byStatus = new Map<String, Integer>{
        JOB_HOLDING => 0,
        JOB_QUEUED => 0,
        JOB_PROCESSING => 0
      };
      Integer executions = 0;
      Integer unsized = 0;
      Integer counted = Math.min(jobs.size(), JOB_SCAN_LIMIT);
      for (Integer i = 0; i < counted; i++) {
        AsyncApexJob job = jobs[i];
        byStatus.put(job.Status, byStatus.get(job.Status) + 1);
        executions += executionsFor(
          job.JobType,
          job.TotalJobItems,
          job.JobItemsProcessed
        );
        if (isUnsizedBatch(job.JobType, job.TotalJobItems)) {
          unsized++;
        }
      }
      r.holding = byStatus.get(JOB_HOLDING);
      r.queued = byStatus.get(JOB_QUEUED);
      r.processing = byStatus.get(JOB_PROCESSING);
      r.pendingExecutions = executions;
      r.jobsCapped = jobs.size() > JOB_SCAN_LIMIT;
      r.unsizedBatches = unsized;
      r.jobsKnown = true;
    } catch (Exception ex) {
      r.jobsKnown = false;
    }
  }

  /**
   * @description Executions that one pending job still needs. A batch job needs one
   * for each chunk left plus one for finish (min. 1). A batch worker row needs 0: its
   * parent batch row counts the chunk. Other jobs need 1.
   * @param jobType The AsyncApexJob.JobType value.
   * @param totalItems The AsyncApexJob.TotalJobItems value.
   * @param processedItems The AsyncApexJob.JobItemsProcessed value.
   * @return The executions the job still needs.
   */
  @TestVisible
  private static Integer executionsFor(
    String jobType,
    Integer totalItems,
    Integer processedItems
  ) {
    if (jobType == 'BatchApexWorker') {
      return 0;
    }
    if (jobType == 'BatchApex') {
      Integer total = totalItems == null ? 0 : totalItems;
      Integer done = processedItems == null ? 0 : processedItems;
      return Math.max(total - done, 0) + 1;
    }
    return 1;
  }

  // A batch job whose start method did not run has TotalJobItems 0 or null. Its chunk
  // count is not known, so its executions are a lower bound.
  private static Boolean isUnsizedBatch(String jobType, Integer totalItems) {
    return jobType == 'BatchApex' && (totalItems == null || totalItems == 0);
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
