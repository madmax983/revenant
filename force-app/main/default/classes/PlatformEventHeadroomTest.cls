/**
 * @description Tests for PlatformEventHeadroom (issue #120): state at each
 * threshold boundary, headroom values, missing keys and zero cost.
 */
@IsTest
private class PlatformEventHeadroomTest {
  private static final String PUBLISH = 'HourlyPublishedPlatformEvents';
  private static final String DELIVERY = 'DailyDeliveredPlatformEvents';

  private static PlatformEventHeadroom.Reading reading(
    String name,
    Integer value,
    Integer limitValue
  ) {
    return new PlatformEventHeadroom.Reading(name, value, limitValue);
  }

  private static Map<String, Object> evaluateDefaults(
    List<PlatformEventHeadroom.Reading> readings
  ) {
    return PlatformEventHeadroom.evaluate(
      readings,
      PlatformEventHeadroom.DEFAULT_WARNING_PERCENT,
      PlatformEventHeadroom.DEFAULT_CRITICAL_PERCENT
    );
  }

  private static List<Map<String, Object>> rows(Map<String, Object> result) {
    return (List<Map<String, Object>>) result.get('platformEventLimits');
  }

  // Decimal equality ignores scale, so 80 equals 80.0.
  private static void assertDecimal(Decimal expected, Object actual) {
    Assert.isTrue(
      actual instanceof Decimal && expected == (Decimal) actual,
      'Expected ' + expected + ' but was ' + actual
    );
  }

  private static String stateAt(Integer value, Integer limitValue) {
    return PlatformEventHeadroom.classify(value, limitValue, 80, 95);
  }

  @IsTest
  static void testDefaultThresholdsAre80And95() {
    assertDecimal(80, PlatformEventHeadroom.DEFAULT_WARNING_PERCENT);
    assertDecimal(95, PlatformEventHeadroom.DEFAULT_CRITICAL_PERCENT);
  }

  @IsTest
  static void testClassifyHealthyBelowWarning() {
    Assert.areEqual(PlatformEventHeadroom.STATE_HEALTHY, stateAt(0, 10000));
    Assert.areEqual(PlatformEventHeadroom.STATE_HEALTHY, stateAt(7999, 10000));
  }

  @IsTest
  static void testClassifyWarningAtAndAboveWarning() {
    Assert.areEqual(PlatformEventHeadroom.STATE_WARNING, stateAt(8000, 10000));
    Assert.areEqual(PlatformEventHeadroom.STATE_WARNING, stateAt(9499, 10000));
  }

  @IsTest
  static void testClassifyCriticalAtAndAboveCritical() {
    Assert.areEqual(PlatformEventHeadroom.STATE_CRITICAL, stateAt(9500, 10000));
    Assert.areEqual(
      PlatformEventHeadroom.STATE_CRITICAL,
      stateAt(10000, 10000)
    );
    Assert.areEqual(
      PlatformEventHeadroom.STATE_CRITICAL,
      stateAt(12000, 10000)
    );
  }

  @IsTest
  static void testClassifyUsesExactRatioNotRoundedPercent() {
    // 79.996 % rounds to 80 %, but it is below the threshold.
    Assert.areEqual(
      PlatformEventHeadroom.STATE_HEALTHY,
      stateAt(79996, 100000)
    );
    Assert.areEqual(
      PlatformEventHeadroom.STATE_WARNING,
      stateAt(80000, 100000)
    );
  }

  @IsTest
  static void testClassifyUnavailableWhenLimitNotPositive() {
    Assert.areEqual(PlatformEventHeadroom.STATE_UNAVAILABLE, stateAt(5, 0));
    Assert.areEqual(PlatformEventHeadroom.STATE_UNAVAILABLE, stateAt(5, -1));
    Assert.areEqual(
      PlatformEventHeadroom.STATE_UNAVAILABLE,
      PlatformEventHeadroom.classify(null, 100, 80, 95)
    );
  }

  @IsTest
  static void testClassifyWithCustomThresholds() {
    Assert.areEqual(
      PlatformEventHeadroom.STATE_HEALTHY,
      PlatformEventHeadroom.classify(49, 100, 50, 70)
    );
    Assert.areEqual(
      PlatformEventHeadroom.STATE_WARNING,
      PlatformEventHeadroom.classify(50, 100, 50, 70)
    );
    Assert.areEqual(
      PlatformEventHeadroom.STATE_CRITICAL,
      PlatformEventHeadroom.classify(70, 100, 50, 70)
    );
  }

  @IsTest
  static void testEvaluateRowCarriesUsedAndRemainingValues() {
    Map<String, Object> result = evaluateDefaults(
      new List<PlatformEventHeadroom.Reading>{ reading(PUBLISH, 83333, 250000) }
    );

    Map<String, Object> row = rows(result)[0];
    Assert.areEqual(PUBLISH, row.get('name'));
    Assert.areEqual('Hourly Published Platform Events', row.get('label'));
    Assert.areEqual(83333, row.get('value'));
    Assert.areEqual(250000, row.get('limit'));
    Assert.areEqual(166667, row.get('remaining'));
    // 33.3332 % used: round down to 33.3. Remaining is 100 - 33.3.
    assertDecimal(33.3, row.get('percentUsed'));
    assertDecimal(66.7, row.get('percentRemaining'));
    Assert.areEqual(PlatformEventHeadroom.STATE_HEALTHY, row.get('state'));
  }

  @IsTest
  static void testEvaluatePercentRoundsDownSoLabelMatchesState() {
    Map<String, Object> result = evaluateDefaults(
      new List<PlatformEventHeadroom.Reading>{ reading(PUBLISH, 79999, 100000) }
    );

    Map<String, Object> row = rows(result)[0];
    assertDecimal(79.9, row.get('percentUsed'));
    Assert.areEqual(PlatformEventHeadroom.STATE_HEALTHY, row.get('state'));
  }

  @IsTest
  static void testEvaluateOverLimitClampsRemainingToZero() {
    Map<String, Object> result = evaluateDefaults(
      new List<PlatformEventHeadroom.Reading>{ reading(DELIVERY, 110, 100) }
    );

    Map<String, Object> row = rows(result)[0];
    Assert.areEqual(0, row.get('remaining'));
    assertDecimal(110.0, row.get('percentUsed'));
    assertDecimal(0, row.get('percentRemaining'));
    Assert.areEqual(PlatformEventHeadroom.STATE_CRITICAL, row.get('state'));
  }

  @IsTest
  static void testEvaluateSkipsReadingsWithNoPositiveLimit() {
    Map<String, Object> result = evaluateDefaults(
      new List<PlatformEventHeadroom.Reading>{
        reading(PUBLISH, 0, 0),
        reading(DELIVERY, 10, 100)
      }
    );

    Assert.areEqual(1, rows(result).size());
    Assert.areEqual(DELIVERY, rows(result)[0].get('name'));
  }

  @IsTest
  static void testEvaluatePanelStateIsWorstRowState() {
    Map<String, Object> result = evaluateDefaults(
      new List<PlatformEventHeadroom.Reading>{
        reading(PUBLISH, 10, 100),
        reading(DELIVERY, 96, 100)
      }
    );

    Assert.areEqual(true, result.get('hasPlatformEventLimits'));
    Assert.areEqual(
      PlatformEventHeadroom.STATE_CRITICAL,
      result.get('platformEventState')
    );
    Assert.areEqual(PUBLISH, rows(result)[0].get('name'));
    Assert.areEqual(DELIVERY, rows(result)[1].get('name'));
  }

  @IsTest
  static void testEvaluateWarningWhenWorstRowIsWarning() {
    Map<String, Object> result = evaluateDefaults(
      new List<PlatformEventHeadroom.Reading>{
        reading(PUBLISH, 85, 100),
        reading(DELIVERY, 10, 100)
      }
    );

    Assert.areEqual(
      PlatformEventHeadroom.STATE_WARNING,
      result.get('platformEventState')
    );
  }

  @IsTest
  static void testEvaluateReturnsThresholdsUsed() {
    Map<String, Object> result = PlatformEventHeadroom.evaluate(
      new List<PlatformEventHeadroom.Reading>{ reading(PUBLISH, 60, 100) },
      50,
      70
    );

    assertDecimal(50, result.get('platformEventWarningPercent'));
    assertDecimal(70, result.get('platformEventCriticalPercent'));
    Assert.areEqual(
      PlatformEventHeadroom.STATE_WARNING,
      result.get('platformEventState')
    );
  }

  @IsTest
  static void testEvaluateUnavailableWhenNoReadings() {
    Map<String, Object> result = evaluateDefaults(
      new List<PlatformEventHeadroom.Reading>()
    );

    Assert.areEqual(false, result.get('hasPlatformEventLimits'));
    Assert.areEqual(
      PlatformEventHeadroom.STATE_UNAVAILABLE,
      result.get('platformEventState')
    );
    Assert.isTrue(rows(result).isEmpty());
    assertDecimal(80, result.get('platformEventWarningPercent'));
    assertDecimal(95, result.get('platformEventCriticalPercent'));
  }

  @IsTest
  static void testUnavailablePayloadHasAllKeys() {
    Map<String, Object> result = PlatformEventHeadroom.unavailable();

    Assert.areEqual(false, result.get('hasPlatformEventLimits'));
    Assert.areEqual(
      PlatformEventHeadroom.STATE_UNAVAILABLE,
      result.get('platformEventState')
    );
    Assert.isTrue(rows(result).isEmpty());
    assertDecimal(80, result.get('platformEventWarningPercent'));
    assertDecimal(95, result.get('platformEventCriticalPercent'));
  }

  @IsTest
  static void testFromOrgLimitsEmptyMapIsUnavailable() {
    Map<String, Object> result = PlatformEventHeadroom.fromOrgLimits(
      new Map<String, System.OrgLimit>()
    );

    Assert.areEqual(false, result.get('hasPlatformEventLimits'));
    Assert.areEqual(
      PlatformEventHeadroom.STATE_UNAVAILABLE,
      result.get('platformEventState')
    );
  }

  @IsTest
  static void testFromOrgLimitsNullMapIsUnavailable() {
    Map<String, Object> result = PlatformEventHeadroom.fromOrgLimits(null);

    Assert.areEqual(
      PlatformEventHeadroom.STATE_UNAVAILABLE,
      result.get('platformEventState')
    );
  }

  @IsTest
  static void testFromOrgLimitsReadsOnlyKnownKeysInOrder() {
    Map<String, System.OrgLimit> live = System.OrgLimits.getMap();

    Map<String, Object> result = PlatformEventHeadroom.fromOrgLimits(live);

    List<String> expected = new List<String>();
    for (String key : PlatformEventHeadroom.LIMIT_KEYS) {
      if (live.containsKey(key) && live.get(key).getLimit() > 0) {
        expected.add(key);
      }
    }
    List<String> actual = new List<String>();
    for (Map<String, Object> row : rows(result)) {
      actual.add((String) row.get('name'));
      System.OrgLimit source = live.get((String) row.get('name'));
      Assert.areEqual(source.getValue(), row.get('value'));
      Assert.areEqual(source.getLimit(), row.get('limit'));
    }
    Assert.areEqual(expected, actual);
    Assert.areEqual(!expected.isEmpty(), result.get('hasPlatformEventLimits'));
  }

  @IsTest
  static void testFromOrgLimitsHasNoDmlQueryAsyncOrPublishCost() {
    Map<String, System.OrgLimit> live = System.OrgLimits.getMap();
    Integer dml = Limits.getDmlStatements();
    Integer dmlRows = Limits.getDmlRows();
    Integer queries = Limits.getQueries();
    Integer queueables = Limits.getQueueableJobs();
    Integer futures = Limits.getFutureCalls();
    Integer immediatePublishes = Limits.getPublishImmediateDML();

    PlatformEventHeadroom.fromOrgLimits(live);

    Assert.areEqual(dml, Limits.getDmlStatements());
    Assert.areEqual(dmlRows, Limits.getDmlRows());
    Assert.areEqual(queries, Limits.getQueries());
    Assert.areEqual(queueables, Limits.getQueueableJobs());
    Assert.areEqual(futures, Limits.getFutureCalls());
    Assert.areEqual(immediatePublishes, Limits.getPublishImmediateDML());
  }
}
