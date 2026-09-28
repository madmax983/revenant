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
    Assert.isTrue(
      PlatformEventHeadroom.DEFAULT_WARNING_PERCENT == 80,
      'Default Warning threshold'
    );
    Assert.isTrue(
      PlatformEventHeadroom.DEFAULT_CRITICAL_PERCENT == 95,
      'Default Critical threshold'
    );
  }

  @IsTest
  static void testEachKeyHasLabelAndImpact() {
    Map<String, String> expectedImpact = new Map<String, String>{
      'HourlyPublishedPlatformEvents' => PlatformEventHeadroom.IMPACT_PUBLISH,
      'DailyDeliveredPlatformEvents' => PlatformEventHeadroom.IMPACT_DELIVERY,
      'MonthlyPlatformEventsUsageEntitlement' => PlatformEventHeadroom.IMPACT_DELIVERY,
      'HourlyPublishedStandardVolumePlatformEvents' => PlatformEventHeadroom.IMPACT_STANDARD_VOLUME,
      'DailyStandardVolumePlatformEvents' => PlatformEventHeadroom.IMPACT_STANDARD_VOLUME
    };
    List<PlatformEventHeadroom.Reading> readings = new List<PlatformEventHeadroom.Reading>();
    for (String key : PlatformEventHeadroom.limitKeys()) {
      readings.add(reading(key, 1, 100));
    }

    List<Map<String, Object>> result = rows(evaluateDefaults(readings));

    Assert.areEqual(
      new List<String>{
        'HourlyPublishedPlatformEvents',
        'DailyDeliveredPlatformEvents',
        'MonthlyPlatformEventsUsageEntitlement',
        'HourlyPublishedStandardVolumePlatformEvents',
        'DailyStandardVolumePlatformEvents'
      },
      PlatformEventHeadroom.limitKeys(),
      'Key order'
    );
    Assert.areEqual(5, result.size(), 'One row for each key');
    for (Map<String, Object> row : result) {
      String name = (String) row.get('name');
      Assert.areEqual(expectedImpact.get(name), row.get('impact'), name);
      Assert.areNotEqual(name, row.get('label'), 'Readable label: ' + name);
    }
  }

  @IsTest
  static void testLimitKeysReturnsACopy() {
    PlatformEventHeadroom.limitKeys().clear();

    Assert.areEqual(5, PlatformEventHeadroom.limitKeys().size());
  }

  @IsTest
  static void testUnknownKeyUsesNameAsLabelAndPublishImpact() {
    Map<String, Object> row = rows(
      evaluateDefaults(
        new List<PlatformEventHeadroom.Reading>{
          reading('SomeNewPlatformEventLimit', 1, 100)
        }
      )
    )[0];

    Assert.areEqual('SomeNewPlatformEventLimit', row.get('label'));
    Assert.areEqual(PlatformEventHeadroom.IMPACT_PUBLISH, row.get('impact'));
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
    // 33.3332% used and 66.6668% remaining: both round down.
    assertDecimal(33.3, row.get('percentUsed'));
    assertDecimal(66.6, row.get('percentRemaining'));
    Assert.areEqual(PlatformEventHeadroom.IMPACT_PUBLISH, row.get('impact'));
    Assert.areEqual(PlatformEventHeadroom.STATE_HEALTHY, row.get('state'));
  }

  @IsTest
  static void testEvaluatePercentRoundsDownSoLabelMatchesState() {
    Map<String, Object> result = evaluateDefaults(
      new List<PlatformEventHeadroom.Reading>{ reading(PUBLISH, 79999, 100000) }
    );

    Map<String, Object> row = rows(result)[0];
    assertDecimal(79.9, row.get('percentUsed'));
    assertDecimal(20.0, row.get('percentRemaining'));
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
    for (String key : PlatformEventHeadroom.limitKeys()) {
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
