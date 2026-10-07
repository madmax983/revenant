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
      Assert.isNotNull(jobs.get('preparing'), 'Preparing must have a count');
      Assert.areEqual(
        0,
        jobs.get('preparing'),
        'A test cannot force Preparing'
      );
      Integer total = (Integer) jobs.get('total');
      Assert.isTrue(total >= 1, 'The queued job must count: ' + jobs);
      Assert.areEqual(
        total,
        (Integer) jobs.get('holding') +
          (Integer) jobs.get('queued') +
          (Integer) jobs.get('processing') +
          (Integer) jobs.get('preparing')
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

  // Asserts executionsFor for one job type, status and batch progress.
  private static void assertExecutions(
    Integer expected,
    String jobType,
    String status,
    Integer totalItems,
    Integer processedItems
  ) {
    Assert.areEqual(
      expected,
      WorkflowAsyncCapacityService.executionsFor(
        jobType,
        status,
        totalItems,
        processedItems
      ),
      jobType + ' in ' + status
    );
  }

  // Makes an in-memory AsyncApexJob. Its fields are read-only, so use JSON.
  private static AsyncApexJob job(
    String status,
    String jobType,
    Integer totalItems,
    Integer processedItems
  ) {
    return (AsyncApexJob) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'Status' => status,
          'JobType' => jobType,
          'TotalJobItems' => totalItems,
          'JobItemsProcessed' => processedItems
        }
      ),
      AsyncApexJob.class
    );
  }

  @IsTest
  static void chargedJobTypesMatchTheDailyLimit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Salesforce: the daily limit counts batch, future, Queueable and
      // scheduled Apex executions.
      Assert.areEqual(
        new Set<String>{ 'BatchApex', 'Future', 'Queueable', 'ScheduledApex' },
        new Set<String>(WorkflowAsyncCapacityService.CHARGED_JOB_TYPES)
      );
    }
  }

  @IsTest
  static void nonBatchJobNeedsOneUntilItStarts() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      for (String jobType : new List<String>{ 'Queueable', 'Future' }) {
        assertExecutions(1, jobType, 'Queued', 0, 0);
        assertExecutions(1, jobType, 'Holding', null, null);
        // A started job is already in dailyUsed.
        assertExecutions(0, jobType, 'Processing', 0, 0);
      }
      assertExecutions(1, 'ScheduledApex', 'Queued', null, null);
      assertExecutions(0, 'ScheduledApex', 'Processing', null, null);
    }
  }

  @IsTest
  static void batchNeedsChunksLeftPlusFinish() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      assertExecutions(4001, 'BatchApex', 'Queued', 5000, 1000);
      assertExecutions(4001, 'BatchApex', 'Holding', 5000, 1000);
      assertExecutions(1, 'BatchApex', 'Holding', 0, 0);
      assertExecutions(1, 'BatchApex', 'Queued', null, null);
      // Preparing: start runs and TotalJobItems is 0. Finish is left.
      assertExecutions(1, 'BatchApex', 'Preparing', 0, 0);
      // Never below 1.
      assertExecutions(1, 'BatchApex', 'Queued', 10, 12);
    }
  }

  @IsTest
  static void processingBatchDoesNotCountItsCurrentChunk() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      assertExecutions(4000, 'BatchApex', 'Processing', 5000, 1000);
      assertExecutions(1, 'BatchApex', 'Processing', 10, 9);
      // Last chunk done or no chunks: finish is left.
      assertExecutions(1, 'BatchApex', 'Processing', 10, 10);
      assertExecutions(1, 'BatchApex', 'Processing', 0, 0);
      assertExecutions(1, 'BatchApex', 'Processing', 10, 12);
    }
  }

  @IsTest
  static void uncountedJobTypesNeedNoExecution() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      for (
        String jobType : new List<String>{
          'BatchApexWorker',
          'TestRequest',
          'TestWorker',
          'SharingRecalculation',
          'ApexToken',
          null
        }
      ) {
        for (
          String status : new List<String>{
            'Holding',
            'Queued',
            'Processing',
            'Preparing'
          }
        ) {
          assertExecutions(0, jobType, status, 5, 1);
        }
      }
    }
  }

  @IsTest
  static void tallyDoesNotCountStartedExecutions() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      AsyncCapacityEvaluator.Reading r = new AsyncCapacityEvaluator.Reading();
      WorkflowAsyncCapacityService.tallyJobs(
        new List<AsyncApexJob>{
          job('Processing', 'BatchApex', 10, 4),
          job('Processing', 'BatchApex', 0, 0),
          job('Processing', 'Queueable', null, null),
          job('Processing', 'Future', null, null),
          job('Queued', 'Queueable', null, null)
        },
        r
      );
      Assert.isTrue(r.jobsKnown);
      Assert.areEqual(4, r.processing);
      Assert.areEqual(1, r.queued);
      Assert.areEqual(0, r.holding);
      Assert.areEqual(0, r.preparing);
      // 6 (5 chunks + finish) + 1 (finish) + 0 + 0 + 1.
      Assert.areEqual(8, r.pendingExecutions);
      Assert.areEqual(0, r.unsizedBatches, 'Start is done in Processing');
      Assert.isFalse(r.jobsCapped);
    }
  }

  @IsTest
  static void tallyFlagsBatchesWithNoSize() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      AsyncCapacityEvaluator.Reading r = new AsyncCapacityEvaluator.Reading();
      WorkflowAsyncCapacityService.tallyJobs(
        new List<AsyncApexJob>{
          job('Holding', 'BatchApex', 0, 0),
          job('Queued', 'BatchApex', null, null),
          job('Preparing', 'BatchApex', 0, 0),
          job('Queued', 'BatchApex', 3, 0)
        },
        r
      );
      Assert.areEqual(1, r.holding);
      Assert.areEqual(2, r.queued);
      Assert.areEqual(1, r.preparing);
      Assert.areEqual(3, r.unsizedBatches);
      Assert.areEqual(1 + 1 + 1 + 4, r.pendingExecutions);
    }
  }

  @IsTest
  static void tallyStopsAtTheScanLimit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<AsyncApexJob> jobs = new List<AsyncApexJob>();
      AsyncApexJob queued = job('Queued', 'Queueable', null, null);
      for (
        Integer i = 0; i <= WorkflowAsyncCapacityService.JOB_SCAN_LIMIT; i++
      ) {
        jobs.add(queued);
      }
      AsyncCapacityEvaluator.Reading r = new AsyncCapacityEvaluator.Reading();
      WorkflowAsyncCapacityService.tallyJobs(jobs, r);
      Assert.isTrue(r.jobsCapped);
      Assert.areEqual(WorkflowAsyncCapacityService.JOB_SCAN_LIMIT, r.queued);
      Assert.areEqual(
        WorkflowAsyncCapacityService.JOB_SCAN_LIMIT,
        r.pendingExecutions
      );
    }
  }

  @IsTest
  static void processingJobsDoNotMakeAFalseCritical() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 95 executions left. 100 Queueables in Processing are already in
      // dailyUsed. The old count gave 100 / 95 (Critical).
      List<AsyncApexJob> jobs = new List<AsyncApexJob>();
      for (Integer i = 0; i < 100; i++) {
        jobs.add(job('Processing', 'Queueable', null, null));
      }
      jobs.add(job('Queued', 'Queueable', null, null));
      AsyncCapacityEvaluator.Reading r = new AsyncCapacityEvaluator.Reading();
      r.dailyUsed = 905;
      r.dailyLimit = 1000;
      WorkflowAsyncCapacityService.tallyJobs(jobs, r);
      Map<String, Object> result = AsyncCapacityEvaluator.evaluate(
        r,
        AsyncCapacityEvaluator.parseThresholds(null)
      );
      Map<String, Object> backlog = metricFor(
        result,
        AsyncCapacityEvaluator.METRIC_BACKLOG
      );
      Assert.areEqual(1, backlog.get('used'));
      Assert.areEqual(
        AsyncCapacityEvaluator.STATUS_HEALTHY,
        backlog.get('status')
      );
      Assert.isFalse((Boolean) result.get('chainAtRisk'));
    }
  }

  @IsTest
  static void batchThatDidNotStartIsCountedAsUnsized() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Database.executeBatch(new WorkflowAsyncCapacityNoopBatch());
      Map<String, Object> result = WorkflowAsyncCapacityService.readCapacity();
      Test.stopTest();
      Map<String, Object> jobs = (Map<String, Object>) result.get('jobCounts');
      Assert.isTrue(
        (Integer) jobs.get('unsizedBatches') >= 1,
        'A batch that did not start has no size: ' + jobs
      );
    }
  }
}
