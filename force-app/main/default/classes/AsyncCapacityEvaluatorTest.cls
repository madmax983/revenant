/**
 * @description Tests for AsyncCapacityEvaluator (#129): threshold parse, percent,
 * classification at each boundary, worst status and chain risk. No SOQL, no DML.
 */
@IsTest
private class AsyncCapacityEvaluatorTest {
  private static AsyncCapacityEvaluator.Thresholds defaults() {
    return AsyncCapacityEvaluator.parseThresholds(null);
  }

  private static AsyncCapacityEvaluator.Reading reading(
    Integer dailyUsed,
    Integer dailyLimit,
    Integer holding
  ) {
    AsyncCapacityEvaluator.Reading r = new AsyncCapacityEvaluator.Reading();
    r.dailyUsed = dailyUsed;
    r.dailyLimit = dailyLimit;
    r.holding = holding;
    r.queued = 0;
    r.processing = 0;
    r.jobsKnown = holding != null;
    return r;
  }

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

  @IsTest
  static void blankConfigUsesDefaults() {
    for (String raw : new List<String>{ null, '', '   ' }) {
      AsyncCapacityEvaluator.Thresholds t = AsyncCapacityEvaluator.parseThresholds(
        raw
      );
      Assert.areEqual(
        AsyncCapacityEvaluator.DEFAULT_WARN_PERCENT,
        t.warn,
        'Default warn'
      );
      Assert.areEqual(
        AsyncCapacityEvaluator.DEFAULT_CRIT_PERCENT,
        t.crit,
        'Default crit'
      );
      Assert.areEqual(AsyncCapacityEvaluator.SOURCE_DEFAULT, t.source);
    }
  }

  @IsTest
  static void validConfigIsUsed() {
    AsyncCapacityEvaluator.Thresholds t = AsyncCapacityEvaluator.parseThresholds(
      ' 70.5 , 90 '
    );
    Assert.areEqual(Decimal.valueOf('70.5'), t.warn);
    Assert.areEqual(Decimal.valueOf('90'), t.crit);
    Assert.areEqual(AsyncCapacityEvaluator.SOURCE_CONFIG, t.source);

    t = AsyncCapacityEvaluator.parseThresholds('1,100');
    Assert.areEqual(Decimal.valueOf('1'), t.warn);
    Assert.areEqual(Decimal.valueOf('100'), t.crit);
    Assert.areEqual(AsyncCapacityEvaluator.SOURCE_CONFIG, t.source);
  }

  @IsTest
  static void invalidConfigFallsBackToDefaults() {
    List<String> bad = new List<String>{
      '95,80',
      '80,80',
      '0,50',
      '-1,50',
      '50,101',
      'abc',
      '80',
      '80,95,99',
      '80,',
      ',95'
    };
    for (String raw : bad) {
      AsyncCapacityEvaluator.Thresholds t = AsyncCapacityEvaluator.parseThresholds(
        raw
      );
      Assert.areEqual(AsyncCapacityEvaluator.DEFAULT_WARN_PERCENT, t.warn, raw);
      Assert.areEqual(AsyncCapacityEvaluator.DEFAULT_CRIT_PERCENT, t.crit, raw);
      Assert.areEqual(AsyncCapacityEvaluator.SOURCE_INVALID, t.source, raw);
    }
  }

  @IsTest
  static void percentRoundsHalfUpToTwoPlaces() {
    Assert.areEqual(33.33, AsyncCapacityEvaluator.percentOf(1, 3));
    Assert.areEqual(66.67, AsyncCapacityEvaluator.percentOf(2, 3));
    Assert.areEqual(0.00, AsyncCapacityEvaluator.percentOf(0, 250000));
    Assert.areEqual(120.00, AsyncCapacityEvaluator.percentOf(120, 100));
  }

  @IsTest
  static void percentIsNullWithoutUsableLimit() {
    Assert.isNull(AsyncCapacityEvaluator.percentOf(5, 0));
    Assert.isNull(AsyncCapacityEvaluator.percentOf(5, -1));
    Assert.isNull(AsyncCapacityEvaluator.percentOf(5, null));
    Assert.isNull(AsyncCapacityEvaluator.percentOf(null, 100));
  }

  @IsTest
  static void classifyAtEachBoundary() {
    AsyncCapacityEvaluator.Thresholds t = defaults();
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_HEALTHY,
      AsyncCapacityEvaluator.classify(0, t)
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_HEALTHY,
      AsyncCapacityEvaluator.classify(79.99, t)
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_DEGRADED,
      AsyncCapacityEvaluator.classify(80, t)
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_DEGRADED,
      AsyncCapacityEvaluator.classify(94.99, t)
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_CRITICAL,
      AsyncCapacityEvaluator.classify(95, t)
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_CRITICAL,
      AsyncCapacityEvaluator.classify(140, t)
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_UNKNOWN,
      AsyncCapacityEvaluator.classify(null, t)
    );
  }

  @IsTest
  static void displayedPercentDecidesStatus() {
    // 79,996 / 100,000 = 79.996%, shown as 80.00%. The status must match the shown value.
    Map<String, Object> result = AsyncCapacityEvaluator.evaluate(
      reading(79996, 100000, 0),
      defaults()
    );
    Map<String, Object> daily = metricFor(
      result,
      AsyncCapacityEvaluator.METRIC_DAILY_ASYNC
    );
    Assert.areEqual(80.00, daily.get('percent'));
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_DEGRADED,
      daily.get('status')
    );
  }

  @IsTest
  static void worstStatusRank() {
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_HEALTHY,
      AsyncCapacityEvaluator.worst(
        new List<String>{ AsyncCapacityEvaluator.STATUS_HEALTHY }
      )
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_UNKNOWN,
      AsyncCapacityEvaluator.worst(
        new List<String>{
          AsyncCapacityEvaluator.STATUS_HEALTHY,
          AsyncCapacityEvaluator.STATUS_UNKNOWN
        }
      )
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_DEGRADED,
      AsyncCapacityEvaluator.worst(
        new List<String>{
          AsyncCapacityEvaluator.STATUS_UNKNOWN,
          AsyncCapacityEvaluator.STATUS_DEGRADED
        }
      )
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_CRITICAL,
      AsyncCapacityEvaluator.worst(
        new List<String>{
          AsyncCapacityEvaluator.STATUS_DEGRADED,
          AsyncCapacityEvaluator.STATUS_CRITICAL,
          AsyncCapacityEvaluator.STATUS_HEALTHY
        }
      )
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_UNKNOWN,
      AsyncCapacityEvaluator.worst(new List<String>())
    );
  }

  @IsTest
  static void healthyReadingHasNoChainRisk() {
    Map<String, Object> result = AsyncCapacityEvaluator.evaluate(
      reading(1000, 250000, 3),
      defaults()
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_HEALTHY,
      result.get('status')
    );
    Assert.areEqual(false, result.get('chainAtRisk'));
    Assert.areEqual(
      AsyncCapacityEvaluator.DEFAULT_WARN_PERCENT,
      result.get('warnPercent')
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.DEFAULT_CRIT_PERCENT,
      result.get('critPercent')
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.SOURCE_DEFAULT,
      result.get('thresholdSource')
    );

    Map<String, Object> daily = metricFor(
      result,
      AsyncCapacityEvaluator.METRIC_DAILY_ASYNC
    );
    Assert.areEqual(1000, daily.get('used'));
    Assert.areEqual(250000, daily.get('limit'));
    Assert.areEqual(0.40, daily.get('percent'));

    Assert.areEqual(false, daily.get('elastic'));

    Map<String, Object> jobs = (Map<String, Object>) result.get('jobCounts');
    Assert.areEqual(3, jobs.get('holding'));
    Assert.areEqual(
      AsyncCapacityEvaluator.FLEX_QUEUE_LIMIT,
      jobs.get('flexQueueLimit')
    );
  }

  @IsTest
  static void degradedReadingHasNoChainRisk() {
    Map<String, Object> result = AsyncCapacityEvaluator.evaluate(
      reading(210000, 250000, 0),
      defaults()
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_DEGRADED,
      result.get('status')
    );
    Assert.areEqual(false, result.get('chainAtRisk'));
  }

  @IsTest
  static void anyCriticalMetricFlagsChainRisk() {
    Map<String, Object> dailyCritical = AsyncCapacityEvaluator.evaluate(
      reading(240000, 250000, 0),
      defaults()
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_CRITICAL,
      dailyCritical.get('status')
    );
    Assert.areEqual(true, dailyCritical.get('chainAtRisk'));
  }

  @IsTest
  static void fullFlexQueueDoesNotFlagChainRisk() {
    // Queueables do not enter the flex queue. A full flex queue cannot block the handoff.
    Map<String, Object> result = AsyncCapacityEvaluator.evaluate(
      reading(10, 250000, 100),
      defaults()
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_HEALTHY,
      result.get('status')
    );
    Assert.areEqual(false, result.get('chainAtRisk'));
    Map<String, Object> jobs = (Map<String, Object>) result.get('jobCounts');
    Assert.areEqual(100, jobs.get('holding'));
  }

  @IsTest
  static void elasticLimitIsTheDailyLimit() {
    // Base limit 250,000 is spent. The elastic limit 500,000 gives more capacity.
    AsyncCapacityEvaluator.Reading r = reading(250000, 250000, 0);
    r.dailyElasticLimit = 500000;
    r.queued = 10;
    Map<String, Object> result = AsyncCapacityEvaluator.evaluate(r, defaults());
    Map<String, Object> daily = metricFor(
      result,
      AsyncCapacityEvaluator.METRIC_DAILY_ASYNC
    );
    Assert.areEqual(500000, daily.get('limit'));
    Assert.areEqual(50.00, daily.get('percent'));
    Assert.areEqual(true, daily.get('elastic'));
    Assert.areEqual(AsyncCapacityEvaluator.STATUS_HEALTHY, daily.get('status'));
    Map<String, Object> backlog = metricFor(
      result,
      AsyncCapacityEvaluator.METRIC_BACKLOG
    );
    Assert.areEqual(250000, backlog.get('limit'), 'Elastic limit minus used');
    Assert.areEqual(false, result.get('chainAtRisk'));
  }

  @IsTest
  static void zeroElasticLimitIsIgnored() {
    AsyncCapacityEvaluator.Reading r = reading(1000, 250000, 0);
    r.dailyElasticLimit = 0;
    Map<String, Object> daily = metricFor(
      AsyncCapacityEvaluator.evaluate(r, defaults()),
      AsyncCapacityEvaluator.METRIC_DAILY_ASYNC
    );
    Assert.areEqual(250000, daily.get('limit'));
    Assert.areEqual(false, daily.get('elastic'));
  }

  @IsTest
  static void missingDataIsUnknownNotHealthy() {
    Map<String, Object> result = AsyncCapacityEvaluator.evaluate(
      reading(null, null, null),
      defaults()
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_UNKNOWN,
      result.get('status')
    );
    Assert.areEqual(false, result.get('chainAtRisk'));
    Map<String, Object> jobs = (Map<String, Object>) result.get('jobCounts');
    Assert.isNull(jobs.get('total'), 'Unknown job counts stay null');
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_UNKNOWN,
      metricFor(result, AsyncCapacityEvaluator.METRIC_BACKLOG).get('status')
    );
    Assert.areEqual(2, ((List<Object>) result.get('metrics')).size());
  }

  @IsTest
  static void jobCountsAddUp() {
    AsyncCapacityEvaluator.Reading r = reading(0, 250000, 2);
    r.queued = 5;
    r.processing = 1;
    Map<String, Object> jobs = (Map<String, Object>) AsyncCapacityEvaluator.evaluate(
        r,
        defaults()
      )
      .get('jobCounts');
    Assert.areEqual(2, jobs.get('holding'));
    Assert.areEqual(5, jobs.get('queued'));
    Assert.areEqual(1, jobs.get('processing'));
    Assert.areEqual(8, jobs.get('total'));
  }

  @IsTest
  static void configThresholdsChangeStatus() {
    Map<String, Object> result = AsyncCapacityEvaluator.evaluate(
      reading(50, 100, 0),
      AsyncCapacityEvaluator.parseThresholds('40,50')
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_CRITICAL,
      result.get('status')
    );
    Assert.areEqual(true, result.get('chainAtRisk'));
    Assert.areEqual(
      AsyncCapacityEvaluator.SOURCE_CONFIG,
      result.get('thresholdSource')
    );
  }

  @IsTest
  static void backlogMetricUsesExecutionsLeft() {
    AsyncCapacityEvaluator.Reading r = reading(200000, 250000, 10);
    r.queued = 30;
    r.processing = 5;
    Map<String, Object> result = AsyncCapacityEvaluator.evaluate(r, defaults());
    Map<String, Object> backlog = metricFor(
      result,
      AsyncCapacityEvaluator.METRIC_BACKLOG
    );
    Assert.areEqual(45, backlog.get('used'), 'Holding + Queued + Processing');
    Assert.areEqual(50000, backlog.get('limit'), 'Limit minus used');
    Assert.areEqual(0.09, backlog.get('percent'));
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_HEALTHY,
      backlog.get('status')
    );
    Assert.areEqual(2, ((List<Object>) result.get('metrics')).size());
  }

  @IsTest
  static void backlogLargerThanExecutionsLeftIsCritical() {
    AsyncCapacityEvaluator.Reading r = reading(249900, 250000, 0);
    r.queued = 100;
    Map<String, Object> result = AsyncCapacityEvaluator.evaluate(r, defaults());
    Map<String, Object> backlog = metricFor(
      result,
      AsyncCapacityEvaluator.METRIC_BACKLOG
    );
    Assert.areEqual(100.00, backlog.get('percent'));
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_CRITICAL,
      backlog.get('status')
    );
    Assert.areEqual(true, result.get('chainAtRisk'));
  }

  @IsTest
  static void backlogIsUnknownWithoutDailyOrJobData() {
    Map<String, Object> noDaily = AsyncCapacityEvaluator.evaluate(
      reading(null, null, 4),
      defaults()
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_UNKNOWN,
      metricFor(noDaily, AsyncCapacityEvaluator.METRIC_BACKLOG).get('status')
    );
    Map<String, Object> noJobs = AsyncCapacityEvaluator.evaluate(
      reading(10, 250000, null),
      defaults()
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_UNKNOWN,
      metricFor(noJobs, AsyncCapacityEvaluator.METRIC_BACKLOG).get('status')
    );
  }

  @IsTest
  static void noExecutionsLeftGivesUnknownBacklogAndCriticalDaily() {
    Map<String, Object> result = AsyncCapacityEvaluator.evaluate(
      reading(250000, 250000, 1),
      defaults()
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_UNKNOWN,
      metricFor(result, AsyncCapacityEvaluator.METRIC_BACKLOG).get('status')
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_CRITICAL,
      result.get('status')
    );
    Assert.areEqual(true, result.get('chainAtRisk'));
  }

  @IsTest
  static void worstIgnoresUnrankedStatus() {
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_DEGRADED,
      AsyncCapacityEvaluator.worst(
        new List<String>{
          'BOGUS',
          AsyncCapacityEvaluator.STATUS_DEGRADED,
          null
        }
      )
    );
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_UNKNOWN,
      AsyncCapacityEvaluator.worst(new List<String>{ 'BOGUS' })
    );
  }

  @IsTest
  static void batchChunksCanMakeBacklogCritical() {
    // One processing batch with 47,999 chunks left and 50,000 executions left.
    AsyncCapacityEvaluator.Reading r = reading(200000, 250000, 0);
    r.processing = 1;
    r.pendingExecutions = 48000;
    Map<String, Object> result = AsyncCapacityEvaluator.evaluate(r, defaults());
    Map<String, Object> backlog = metricFor(
      result,
      AsyncCapacityEvaluator.METRIC_BACKLOG
    );
    Assert.areEqual(48000, backlog.get('used'));
    Assert.areEqual(96.00, backlog.get('percent'));
    Assert.areEqual(
      AsyncCapacityEvaluator.STATUS_CRITICAL,
      backlog.get('status')
    );
    Assert.areEqual(true, result.get('chainAtRisk'));
    Map<String, Object> jobs = (Map<String, Object>) result.get('jobCounts');
    Assert.areEqual(1, jobs.get('total'), 'The job count stays one row');
    Assert.areEqual(48000, jobs.get('pendingExecutions'));
  }

  @IsTest
  static void cappedScanIsFlagged() {
    AsyncCapacityEvaluator.Reading r = reading(1000, 250000, 0);
    r.queued = 2000;
    r.pendingExecutions = 2000;
    r.jobsCapped = true;
    Map<String, Object> result = AsyncCapacityEvaluator.evaluate(r, defaults());
    Assert.areEqual(
      true,
      metricFor(result, AsyncCapacityEvaluator.METRIC_BACKLOG).get('capped')
    );
    Assert.areEqual(
      true,
      ((Map<String, Object>) result.get('jobCounts')).get('capped')
    );
  }
}
