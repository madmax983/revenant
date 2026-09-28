/**
 * @description Calculates the org Platform Event allocation use for System
 * Doctor (issue #120). Reads only the `System.OrgLimits` map. Does no SOQL,
 * no DML, no async enqueue and no event publish.
 *
 * State for each limit key (thresholds in percent, `warn < crit`): if
 * `value × 100 ≥ crit × limit`, the state is CRITICAL. If
 * `value × 100 ≥ warn × limit`, the state is WARNING. If not, the state is
 * HEALTHY. If a key has no positive limit, the class adds no row. If there
 * are no rows, the state is UNAVAILABLE.
 */
public inherited sharing class PlatformEventHeadroom {
  public static final String STATE_HEALTHY = 'HEALTHY';
  public static final String STATE_WARNING = 'WARNING';
  public static final String STATE_CRITICAL = 'CRITICAL';
  public static final String STATE_UNAVAILABLE = 'UNAVAILABLE';

  /** @description Revenant events use this allocation (all are high-volume). */
  public static final String IMPACT_PUBLISH = 'PUBLISH';
  /** @description Delivery to CometD, Pub/Sub API and empApi clients. */
  public static final String IMPACT_DELIVERY = 'DELIVERY';
  /** @description Standard-volume events. Revenant does not use them. */
  public static final String IMPACT_STANDARD_VOLUME = 'STANDARD_VOLUME';

  public static final Decimal DEFAULT_WARNING_PERCENT = 80;
  public static final Decimal DEFAULT_CRITICAL_PERCENT = 95;

  // Limit keys in display order. The high-volume publish key is first:
  // each engine wake-up uses it.
  private static final List<String> LIMIT_KEYS = new List<String>{
    'HourlyPublishedPlatformEvents',
    'DailyDeliveredPlatformEvents',
    'MonthlyPlatformEventsUsageEntitlement',
    'HourlyPublishedStandardVolumePlatformEvents',
    'DailyStandardVolumePlatformEvents'
  };

  private static final Map<String, String> LABELS = new Map<String, String>{
    'HourlyPublishedPlatformEvents' => 'Hourly Published Platform Events',
    'DailyDeliveredPlatformEvents' => 'Daily Delivered Platform Events',
    'MonthlyPlatformEventsUsageEntitlement' => 'Monthly Platform Event Delivery Entitlement',
    'HourlyPublishedStandardVolumePlatformEvents' => 'Hourly Published Standard-Volume Platform Events',
    'DailyStandardVolumePlatformEvents' => 'Daily Delivered Standard-Volume Platform Events'
  };

  private static final Map<String, String> IMPACTS = new Map<String, String>{
    'HourlyPublishedPlatformEvents' => IMPACT_PUBLISH,
    'DailyDeliveredPlatformEvents' => IMPACT_DELIVERY,
    'MonthlyPlatformEventsUsageEntitlement' => IMPACT_DELIVERY,
    'HourlyPublishedStandardVolumePlatformEvents' => IMPACT_STANDARD_VOLUME,
    'DailyStandardVolumePlatformEvents' => IMPACT_STANDARD_VOLUME
  };

  private static final Map<String, Integer> SEVERITY = new Map<String, Integer>{
    STATE_UNAVAILABLE => 0,
    STATE_HEALTHY => 1,
    STATE_WARNING => 2,
    STATE_CRITICAL => 3
  };

  /**
   * @description Tests use this seam. If it is not null, `fromOrgLimits` uses
   * these readings. Apex tests cannot make a `System.OrgLimit`.
   */
  @TestVisible
  private static List<Reading> readingsOverride;

  /**
   * @description One limit key with its used value and its limit.
   */
  public class Reading {
    public String name;
    public Integer value;
    public Integer limitValue;

    /**
     * @description Makes a reading.
     * @param name The `OrgLimits` key.
     * @param value The used amount.
     * @param limitValue The allocation.
     */
    public Reading(String name, Integer value, Integer limitValue) {
      this.name = name;
      this.value = value;
      this.limitValue = limitValue;
    }
  }

  /**
   * @description The limit keys that the class reads, in display order.
   * @return A copy of the key list.
   */
  public static List<String> limitKeys() {
    return LIMIT_KEYS.clone();
  }

  /**
   * @description Returns the state for one limit. Uses the exact ratio, not a
   * rounded percent.
   * @param value The used amount.
   * @param limitValue The allocation.
   * @param warningPercent The Warning threshold in percent.
   * @param criticalPercent The Critical threshold in percent.
   * @return CRITICAL, WARNING, HEALTHY, or UNAVAILABLE when a value is null
   * or the limit is not positive.
   */
  public static String classify(
    Integer value,
    Integer limitValue,
    Decimal warningPercent,
    Decimal criticalPercent
  ) {
    if (value == null || limitValue == null || limitValue <= 0) {
      return STATE_UNAVAILABLE;
    }
    Decimal scaledUsed = Decimal.valueOf(value) * 100;
    if (scaledUsed >= criticalPercent * limitValue) {
      return STATE_CRITICAL;
    }
    if (scaledUsed >= warningPercent * limitValue) {
      return STATE_WARNING;
    }
    return STATE_HEALTHY;
  }

  /**
   * @description Reads the Platform Event keys from an `OrgLimits` map and
   * evaluates them at the default thresholds.
   * @param limitsMap The result of `System.OrgLimits.getMap()`. Can be null.
   * @return The headroom payload. See `evaluate`.
   */
  public static Map<String, Object> fromOrgLimits(
    Map<String, System.OrgLimit> limitsMap
  ) {
    List<Reading> readings = readingsOverride;
    if (readings == null) {
      readings = new List<Reading>();
      for (String key : LIMIT_KEYS) {
        if (limitsMap != null && limitsMap.containsKey(key)) {
          System.OrgLimit orgLimit = limitsMap.get(key);
          readings.add(
            new Reading(key, orgLimit.getValue(), orgLimit.getLimit())
          );
        }
      }
    }
    return evaluate(
      readings,
      DEFAULT_WARNING_PERCENT,
      DEFAULT_CRITICAL_PERCENT
    );
  }

  /**
   * @description Evaluates readings against the thresholds. Skips a reading
   * with no positive limit.
   * @param readings The limit readings, in display order.
   * @param warningPercent The Warning threshold in percent.
   * @param criticalPercent The Critical threshold in percent.
   * @return A map with `hasPlatformEventLimits`, `platformEventState` (worst
   * row state), `platformEventLimits` (rows), `platformEventWarningPercent`
   * and `platformEventCriticalPercent`.
   */
  public static Map<String, Object> evaluate(
    List<Reading> readings,
    Decimal warningPercent,
    Decimal criticalPercent
  ) {
    List<Map<String, Object>> rows = new List<Map<String, Object>>();
    String worst = STATE_UNAVAILABLE;
    for (Reading r : readings == null ? new List<Reading>() : readings) {
      String state = classify(
        r.value,
        r.limitValue,
        warningPercent,
        criticalPercent
      );
      if (state == STATE_UNAVAILABLE) {
        continue;
      }
      rows.add(toRow(r, state));
      if (SEVERITY.get(state) > SEVERITY.get(worst)) {
        worst = state;
      }
    }
    return payload(rows, worst, warningPercent, criticalPercent);
  }

  /**
   * @description The payload for an org with no Platform Event limit, or
   * for a failed read.
   * @return The headroom payload with no rows and the UNAVAILABLE state.
   */
  public static Map<String, Object> unavailable() {
    return payload(
      new List<Map<String, Object>>(),
      STATE_UNAVAILABLE,
      DEFAULT_WARNING_PERCENT,
      DEFAULT_CRITICAL_PERCENT
    );
  }

  private static Map<String, Object> payload(
    List<Map<String, Object>> rows,
    String state,
    Decimal warningPercent,
    Decimal criticalPercent
  ) {
    return new Map<String, Object>{
      'hasPlatformEventLimits' => !rows.isEmpty(),
      'platformEventState' => state,
      'platformEventLimits' => rows,
      'platformEventWarningPercent' => warningPercent,
      'platformEventCriticalPercent' => criticalPercent
    };
  }

  // Rounds both percents down. The used label does not show a threshold
  // before the state changes. The remaining label does not show more
  // headroom than the org has.
  private static Map<String, Object> toRow(Reading r, String state) {
    Integer remaining = Math.max(0, r.limitValue - r.value);
    Decimal percentUsed = (Decimal.valueOf(r.value) * 100)
      .divide(r.limitValue, 1, System.RoundingMode.DOWN);
    Decimal percentRemaining = (Decimal.valueOf(remaining) * 100)
      .divide(r.limitValue, 1, System.RoundingMode.DOWN);
    return new Map<String, Object>{
      'name' => r.name,
      'label' => LABELS.containsKey(r.name) ? LABELS.get(r.name) : r.name,
      'value' => r.value,
      'limit' => r.limitValue,
      'impact' => IMPACTS.containsKey(r.name)
        ? IMPACTS.get(r.name)
        : IMPACT_PUBLISH,
      'remaining' => remaining,
      'percentUsed' => percentUsed,
      'percentRemaining' => percentRemaining,
      'state' => state
    };
  }
}
