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
        System.OrgLimit orgLimit = limitsMap.get('DailyAsyncApexExecutions');
        Assert.areEqual(orgLimit.getLimit(), daily.get('limit'));
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
      Integer logsBefore = [SELECT COUNT() FROM Workflow_Log__c];
      Integer queriesBefore = Limits.getQueries();
      Integer rowsBefore = Limits.getQueryRows();
      Integer dmlBefore = Limits.getDmlStatements();

      WorkflowAsyncCapacityService.readCapacity();

      Assert.isTrue(
        Limits.getQueries() - queriesBefore <= 1,
        'The read must cost max 1 SOQL'
      );
      Assert.isTrue(
        Limits.getQueryRows() - rowsBefore <= 3,
        'The read must cost max 3 query rows (one per status group)'
      );
      Assert.areEqual(
        dmlBefore,
        Limits.getDmlStatements(),
        'The read must not write'
      );
      Assert.areEqual(
        logsBefore,
        [SELECT COUNT() FROM Workflow_Log__c],
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
  static void jobQueryErrorGivesUnknownFlexMetric() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowAsyncCapacityService.failJobQuery = true;
      Map<String, Object> result = WorkflowAsyncCapacityService.asyncCapacity();
      Assert.areEqual(
        AsyncCapacityEvaluator.STATUS_UNKNOWN,
        metricFor(result, AsyncCapacityEvaluator.METRIC_FLEX_QUEUE)
          .get('status')
      );
      Assert.isNotNull(
        metricFor(result, AsyncCapacityEvaluator.METRIC_DAILY_ASYNC),
        'The daily metric still shows'
      );
    }
  }

  @IsTest
  static void orchestratorDoesNotCallTheRead() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      ApexClass orchestrator = [
        SELECT Body
        FROM ApexClass
        WHERE Name = 'WorkflowOrchestrator'
        LIMIT 1
      ];
      Assert.isFalse(
        orchestrator.Body.contains('AsyncCapacity'),
        'The capacity read must stay off the enqueue hot path'
      );
    }
  }
}
