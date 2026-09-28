/**
 * @description Tests for WorkflowAsyncCapacityService (#129): the envelope, the
 * governor cost, no writes, the job count read, and the hot-path isolation.
 */
@IsTest
private class WorkflowAsyncCapacityServiceTest {
  private static Map<String, Object> metricFor(
    Map<String, Object> result,
    String key
  ) {
    for (Object o : (List<Object>) result.get('metrics')) {
      Map<String, Object> m = (Map<String, Object>) o;
      if (key.equals(m.get('key'))) {
        return m;
      }
    }
    return null;
  }

  /**
   * @description Test Queueable. It only adds an AsyncApexJob row.
   */
  public class NoopJob implements Queueable {
    /**
     * @description Does nothing.
     * @param ctx The queueable context.
     */
    public void execute(QueueableContext ctx) {
      return;
    }
  }

  @IsTest
  static void envelopeHasAllKeys() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Map<String, Object> result = WorkflowAsyncCapacityService.asyncCapacity();
      for (
        String key : new List<String>{
          'asOfMs',
          'status',
          'chainAtRisk',
          'warnPercent',
          'critPercent',
          'thresholdSource',
          'metrics',
          'jobCounts'
        }
      ) {
        Assert.isTrue(result.containsKey(key), 'Missing key ' + key);
      }
      Assert.areEqual(2, ((List<Object>) result.get('metrics')).size());
    }
  }

  @IsTest
  static void dailyMetricMatchesOrgLimits() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Map<String, Object> result = WorkflowAsyncCapacityService.asyncCapacity();
      Map<String, Object> daily = metricFor(
        result,
        AsyncCapacityEvaluator.METRIC_DAILY_ASYNC
      );
      Map<String, System.OrgLimit> limitsMap = System.OrgLimits.getMap();
      if (limitsMap.containsKey('DailyAsyncApexExecutions')) {
        Integer expected = limitsMap.get('DailyAsyncApexExecutions').getLimit();
        if (limitsMap.containsKey('DailyAsyncApexElasticExecutions')) {
          Integer elastic = limitsMap.get('DailyAsyncApexElasticExecutions')
            .getLimit();
          expected = elastic > 0 ? elastic : expected;
        }
        Assert.areEqual(expected, daily.get('limit'));
        Assert.isNotNull(daily.get('used'));
      } else {
        Assert.areEqual(
          AsyncCapacityEvaluator.STATUS_UNKNOWN,
          daily.get('status')
        );
      }
    }
  }

  @IsTest
  static void readCostsAtMostOneSoqlAndNoDml() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      // Five queued Queueable jobs. Each one is one pending execution.
      System.enqueueJob(new NoopJob());
      System.enqueueJob(new NoopJob());
      System.enqueueJob(new NoopJob());
      System.enqueueJob(new NoopJob());
      System.enqueueJob(new NoopJob());
      Integer logsBefore = [SELECT COUNT() FROM Workflow_Log__c];
      Integer queriesBefore = Limits.getQueries();
      Integer rowsBefore = Limits.getQueryRows();
      Integer dmlBefore = Limits.getDmlStatements();

      Map<String, Object> result = WorkflowAsyncCapacityService.readCapacity();

      Integer queries = Limits.getQueries() - queriesBefore;
      Integer rows = Limits.getQueryRows() - rowsBefore;
      Integer dml = Limits.getDmlStatements() - dmlBefore;
      Integer logsAfter = [SELECT COUNT() FROM Workflow_Log__c];
      Test.stopTest();

      Map<String, Object> jobs = (Map<String, Object>) result.get('jobCounts');
      Assert.isTrue((Integer) jobs.get('total') >= 5, String.valueOf(jobs));
      Assert.isTrue(queries <= 1, 'The read must cost max 1 SOQL: ' + queries);
      Assert.isTrue(
        rows <= WorkflowAsyncCapacityService.JOB_SCAN_LIMIT + 1,
        'The read must cost max JOB_SCAN_LIMIT + 1 query rows: ' + rows
      );
      Assert.isTrue(
        (Integer) jobs.get('pendingExecutions') >= 5,
        'Each queued Queueable is one execution: ' + jobs
      );
      Assert.areEqual(0, dml, 'The read must not write');
      Assert.areEqual(
        logsBefore,
        logsAfter,
        'The read must not add audit rows'
      );
    }
  }

  @IsTest
  static void enqueuedJobShowsInCounts() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      System.enqueueJob(new NoopJob());
      Map<String, Object> result = WorkflowAsyncCapacityService.asyncCapacity();
      Test.stopTest();

      Map<String, Object> jobs = (Map<String, Object>) result.get('jobCounts');
      Integer total = (Integer) jobs.get('total');
      Assert.isTrue(total >= 1, 'The queued job must count: ' + jobs);
      Assert.areEqual(
        total,
        (Integer) jobs.get('holding') +
          (Integer) jobs.get('queued') +
          (Integer) jobs.get('processing')
      );
    }
  }

  @IsTest
  static void configThresholdsAreUsed() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowAsyncCapacityService.thresholdsOverride = '60,70';
      Map<String, Object> result = WorkflowAsyncCapacityService.asyncCapacity();
      Assert.areEqual(Decimal.valueOf('60'), result.get('warnPercent'));
      Assert.areEqual(Decimal.valueOf('70'), result.get('critPercent'));
      Assert.areEqual(
        AsyncCapacityEvaluator.SOURCE_CONFIG,
        result.get('thresholdSource')
      );
    }
  }

  @IsTest
  static void invalidConfigIsFlagged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowAsyncCapacityService.thresholdsOverride = '99,10';
      Map<String, Object> result = WorkflowAsyncCapacityService.asyncCapacity();
      Assert.areEqual(
        AsyncCapacityEvaluator.DEFAULT_WARN_PERCENT,
        result.get('warnPercent')
      );
      Assert.areEqual(
        AsyncCapacityEvaluator.DEFAULT_CRIT_PERCENT,
        result.get('critPercent')
      );
      Assert.areEqual(
        AsyncCapacityEvaluator.SOURCE_INVALID,
        result.get('thresholdSource')
      );
    }
  }

  @IsTest
  static void defaultRecordValueIsRead() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Revenant_Config__mdt config = Revenant_Config__mdt.getInstance('Default');
      AsyncCapacityEvaluator.Thresholds expected = AsyncCapacityEvaluator.parseThresholds(
        config == null ? null : config.Async_Capacity_Thresholds__c
      );
      Map<String, Object> result = WorkflowAsyncCapacityService.asyncCapacity();
      Assert.areEqual(expected.warn, result.get('warnPercent'));
      Assert.areEqual(expected.crit, result.get('critPercent'));
      Assert.areEqual(expected.source, result.get('thresholdSource'));
    }
  }

  @IsTest
  static void jobQueryErrorGivesUnknownBacklogMetric() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowAsyncCapacityService.failJobQuery = true;
      Map<String, Object> result = WorkflowAsyncCapacityService.asyncCapacity();
      Assert.areEqual(
        AsyncCapacityEvaluator.STATUS_UNKNOWN,
        metricFor(result, AsyncCapacityEvaluator.METRIC_BACKLOG).get('status')
      );
      Assert.isNotNull(
        metricFor(result, AsyncCapacityEvaluator.METRIC_DAILY_ASYNC),
        'The daily metric still shows'
      );
    }
  }

  @IsTest
  static void enqueuePathDoesNotCallTheRead() {
    // The orchestrator and each production class that calls System.enqueueJob.
    Set<String> hotPath = new Set<String>{
      'WorkflowOrchestrator',
      'WorkflowOrchestratorEnqueue',
      'WorkflowEngine',
      'WorkflowStepRunner',
      'WorkflowBranchResume',
      'WorkflowCancellation',
      'WorkflowCascadeCancel',
      'WorkflowCompensation',
      'WorkflowCompensationRunner',
      'WorkflowContinueAsNew',
      'WorkflowEventTriggerHandler',
      'WorkflowOperatorSkipAdvance',
      'WorkflowOperatorSkipParallelResume',
      'WorkflowPauseResumeDrainer',
      'WorkflowResumeEnqueue',
      'WorkflowResumeService',
      'WorkflowRetryJob',
      'WorkflowRetryService',
      'WorkflowRetrySleepScheduler',
      'WorkflowSleepJob',
      'WorkflowTimeoutReArm',
      'WorkflowTimeoutScheduler'
    };
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<ApexClass> classes = [
        SELECT Name, Body
        FROM ApexClass
        WHERE Name IN :hotPath
        LIMIT 100
      ];
      Assert.isTrue(classes.size() >= 2, 'Hot-path classes must exist');
      for (ApexClass c : classes) {
        Assert.isFalse(
          c.Body.contains('AsyncCapacity'),
          c.Name + ' must not call the capacity read'
        );
      }
    }
  }

  @IsTest
  static void executionsForEachJobType() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areEqual(
        1,
        WorkflowAsyncCapacityService.executionsFor('Queueable', 0, 0)
      );
      Assert.areEqual(
        1,
        WorkflowAsyncCapacityService.executionsFor('Future', null, null)
      );
      Assert.areEqual(
        0,
        WorkflowAsyncCapacityService.executionsFor('BatchApexWorker', 5, 1),
        'The parent batch row counts the chunks'
      );
      Assert.areEqual(
        4001,
        WorkflowAsyncCapacityService.executionsFor('BatchApex', 5000, 1000),
        'Chunks left plus finish'
      );
      Assert.areEqual(
        1,
        WorkflowAsyncCapacityService.executionsFor('BatchApex', 0, 0),
        'A batch that did not start counts at least 1'
      );
      Assert.areEqual(
        1,
        WorkflowAsyncCapacityService.executionsFor('BatchApex', 10, 12),
        'Never below 1'
      );
    }
  }
}
