/**
 * @description Pure rules of the Async Apex Capacity panel (#129). It parses the
 * thresholds, calculates percentages and gives each metric a status. Metrics: daily
 * executions (used / limit) and pending executions (of the Holding, Queued,
 * Processing and Preparing jobs) / daily executions left. Both gate the Queueable chain. The flex
 * queue (Holding / 100) is a count only: Queueables do not enter it. It does no SOQL,
 * no DML and reads no clock.
 */
public inherited sharing class AsyncCapacityEvaluator {
  /** @description Percent is below the warn threshold. */
  public static final String STATUS_HEALTHY = 'HEALTHY';
  /** @description Percent is at or above the warn threshold. */
  public static final String STATUS_DEGRADED = 'DEGRADED';
  /** @description Percent is at or above the critical threshold. */
  public static final String STATUS_CRITICAL = 'CRITICAL';
  /** @description No usable data or limit. */
  public static final String STATUS_UNKNOWN = 'UNKNOWN';

  /** @description Thresholds are the defaults because the field is blank. */
  public static final String SOURCE_DEFAULT = 'DEFAULT';
  /** @description Thresholds come from the config field. */
  public static final String SOURCE_CONFIG = 'CONFIG';
  /** @description The config field is not valid. Thresholds are the defaults. */
  public static final String SOURCE_INVALID = 'INVALID';

  /** @description Key of the daily async Apex executions metric. */
  public static final String METRIC_DAILY_ASYNC = 'DAILY_ASYNC';
  /** @description Key of the pending executions vs daily executions left metric. */
  public static final String METRIC_BACKLOG = 'BACKLOG';

  /** @description Platform maximum of batch jobs in the flex queue (Holding). */
  public static final Integer FLEX_QUEUE_LIMIT = 100;

  /** @description Default warn threshold in percent. */
  public static final Decimal DEFAULT_WARN_PERCENT = 80;
  /** @description Default critical threshold in percent. */
  public static final Decimal DEFAULT_CRIT_PERCENT = 95;

  // Display label of each metric.
  private static final Map<String, String> LABELS = new Map<String, String>{
    METRIC_DAILY_ASYNC => 'Daily async Apex executions',
    METRIC_BACKLOG => 'Pending executions vs executions left'
  };

  // Rank for the overall status. Higher is worse. Unknown is worse than Healthy.
  // worst() ignores a status that is not in this map.
  private static final Map<String, Integer> RANK = new Map<String, Integer>{
    STATUS_HEALTHY => 0,
    STATUS_UNKNOWN => 1,
    STATUS_DEGRADED => 2,
    STATUS_CRITICAL => 3
  };

  /**
   * @description Warn and critical thresholds in percent, and their source.
   */
  public class Thresholds {
    /** @description Warn threshold in percent. */
    public Decimal warn;
    /** @description Critical threshold in percent. */
    public Decimal crit;
    /** @description SOURCE_DEFAULT, SOURCE_CONFIG or SOURCE_INVALID. */
    public String source;
  }

  /**
   * @description Raw values of one capacity read. A null value means "not known".
   */
  public class Reading {
    /** @description Daily async Apex executions used in the last 24 hours. */
    public Integer dailyUsed;
    /** @description Daily async Apex executions limit. */
    public Integer dailyLimit;
    /** @description Elastic daily limit, or null when the org has none. */
    public Integer dailyElasticLimit;
    /** @description AsyncApexJob rows in Holding (the flex queue). */
    public Integer holding;
    /** @description AsyncApexJob rows in Queued. */
    public Integer queued;
    /** @description AsyncApexJob rows in Processing. */
    public Integer processing;
    /** @description AsyncApexJob rows in Preparing (batch start method runs). */
    public Integer preparing = 0;
    /** @description False when the AsyncApexJob read failed. */
    public Boolean jobsKnown = false;
    /**
     * @description Executions the pending jobs still need. Null uses the job count.
     */
    public Integer pendingExecutions;
    /** @description True when the job read stopped at its row cap. */
    public Boolean jobsCapped = false;
    /** @description Batch jobs that did not start, so their chunk count is not known. */
    public Integer unsizedBatches = 0;
  }

  /**
   * @description Parses the text "warn,crit". Blank gives the defaults. Text that is
   * not two numbers with 0 < warn < crit <= 100 gives the defaults and SOURCE_INVALID.
   * @param raw The config text, for example "80,95".
   * @return The thresholds to use.
   */
  public static Thresholds parseThresholds(String raw) {
    Thresholds t = new Thresholds();
    t.warn = DEFAULT_WARN_PERCENT;
    t.crit = DEFAULT_CRIT_PERCENT;
    t.source = SOURCE_DEFAULT;
    if (String.isBlank(raw)) {
      return t;
    }
    t.source = SOURCE_INVALID;
    List<String> parts = raw.split(',', -1);
    if (parts.size() != 2) {
      return t;
    }
    Decimal warn;
    Decimal crit;
    try {
      warn = Decimal.valueOf(parts[0].trim());
      crit = Decimal.valueOf(parts[1].trim());
    } catch (System.TypeException ex) {
      return t;
    }
    if (warn <= 0 || warn >= crit || crit > 100) {
      return t;
    }
    t.warn = warn;
    t.crit = crit;
    t.source = SOURCE_CONFIG;
    return t;
  }

  /**
   * @description Calculates used / limit in percent, rounded HALF_UP to 2 places.
   * @param used The used amount.
   * @param limitValue The limit.
   * @return The percent, or null when a value is missing or the limit is not above 0.
   */
  public static Decimal percentOf(Integer used, Integer limitValue) {
    if (used == null || limitValue == null || limitValue <= 0) {
      return null;
    }
    Decimal usedValue = used;
    return (usedValue *
      100 /
      limitValue)
      .setScale(2, System.RoundingMode.HALF_UP);
  }

  /**
   * @description Gives the status of one percent.
   * @param percent The percent, or null.
   * @param t The thresholds.
   * @return STATUS_UNKNOWN, STATUS_HEALTHY, STATUS_DEGRADED or STATUS_CRITICAL.
   */
  public static String classify(Decimal percent, Thresholds t) {
    if (percent == null) {
      return STATUS_UNKNOWN;
    }
    if (percent >= t.crit) {
      return STATUS_CRITICAL;
    }
    if (percent >= t.warn) {
      return STATUS_DEGRADED;
    }
    return STATUS_HEALTHY;
  }

  /**
   * @description Gives the worst status. Rank: Critical, Degraded, Unknown, Healthy.
   * @param statuses The statuses. Values that are not ranked are ignored.
   * @return The worst status, or STATUS_UNKNOWN when no status is ranked.
   */
  public static String worst(List<String> statuses) {
    String result = null;
    Integer highest = -1;
    for (String s : statuses) {
      Integer rank = RANK.get(s);
      if (rank != null && rank > highest) {
        highest = rank;
        result = s;
      }
    }
    return result == null ? STATUS_UNKNOWN : result;
  }

  /**
   * @description Builds the panel envelope (without asOfMs) from one reading.
   * @param r The reading.
   * @param t The thresholds.
   * @return A map with status, chainAtRisk, thresholds, metrics and jobCounts.
   */
  public static Map<String, Object> evaluate(Reading r, Thresholds t) {
    Map<String, Object> daily = metric(
      METRIC_DAILY_ASYNC,
      r.dailyUsed,
      dailyLimit(r)
    );
    daily.put('elastic', usesElastic(r));
    Map<String, Object> backlog = metric(
      METRIC_BACKLOG,
      pendingExecutions(r),
      executionsLeft(r)
    );
    backlog.put('capped', r.jobsCapped);
    backlog.put('lowerBound', isLowerBound(r));
    List<Map<String, Object>> metrics = new List<Map<String, Object>>{
      daily,
      backlog
    };
    List<String> statuses = new List<String>();
    for (Map<String, Object> m : metrics) {
      String status = classify((Decimal) m.get('percent'), t);
      // A lower bound can prove Critical only.
      if (m.get('lowerBound') == true && status != STATUS_CRITICAL) {
        status = STATUS_UNKNOWN;
      }
      m.put('status', status);
      statuses.add(status);
    }
    return new Map<String, Object>{
      'status' => worst(statuses),
      'chainAtRisk' => statuses.contains(STATUS_CRITICAL),
      'warnPercent' => t.warn,
      'critPercent' => t.crit,
      'thresholdSource' => t.source,
      'metrics' => metrics,
      'jobCounts' => jobCounts(r)
    };
  }

  private static Map<String, Object> metric(
    String key,
    Integer used,
    Integer limitValue
  ) {
    return new Map<String, Object>{
      'key' => key,
      'label' => LABELS.get(key),
      'used' => used,
      'limit' => limitValue,
      'percent' => percentOf(used, limitValue)
    };
  }

  // Holding + Queued + Processing + Preparing. Null when the job read failed.
  private static Integer pendingJobs(Reading r) {
    return r.jobsKnown
      ? r.holding + r.queued + r.processing + r.preparing
      : null;
  }

  // True when pending executions is a lower bound: the read hit its cap, or a batch
  // job did not start and its chunk count is not known.
  private static Boolean isLowerBound(Reading r) {
    return r.jobsCapped || r.unsizedBatches > 0;
  }

  // Executions the pending jobs need. Falls back to the job count.
  private static Integer pendingExecutions(Reading r) {
    if (!r.jobsKnown) {
      return null;
    }
    return r.pendingExecutions != null ? r.pendingExecutions : pendingJobs(r);
  }

  // True when the org has an elastic limit above 0. StepGovernor uses the same rule.
  private static Boolean usesElastic(Reading r) {
    return r.dailyElasticLimit != null && r.dailyElasticLimit > 0;
  }

  // The elastic limit when the org has one, else the base daily limit.
  private static Integer dailyLimit(Reading r) {
    return usesElastic(r) ? r.dailyElasticLimit : r.dailyLimit;
  }

  // Daily limit minus daily used. Null when the daily values are not known.
  // A value of 0 or less gives no percent (Unknown). The daily metric is then Critical.
  private static Integer executionsLeft(Reading r) {
    Integer limitValue = dailyLimit(r);
    if (r.dailyUsed == null || limitValue == null) {
      return null;
    }
    return limitValue - r.dailyUsed;
  }

  private static Map<String, Object> jobCounts(Reading r) {
    if (!r.jobsKnown) {
      return new Map<String, Object>{
        'holding' => null,
        'queued' => null,
        'processing' => null,
        'preparing' => null,
        'total' => null,
        'pendingExecutions' => null,
        'capped' => false,
        'unsizedBatches' => null,
        'flexQueueLimit' => FLEX_QUEUE_LIMIT
      };
    }
    Integer total = pendingJobs(r);
    return new Map<String, Object>{
      'holding' => r.holding,
      'queued' => r.queued,
      'processing' => r.processing,
      'preparing' => r.preparing,
      'total' => total,
      'pendingExecutions' => pendingExecutions(r),
      'capped' => r.jobsCapped,
      'unsizedBatches' => r.unsizedBatches,
      'flexQueueLimit' => FLEX_QUEUE_LIMIT
    };
  }
}
