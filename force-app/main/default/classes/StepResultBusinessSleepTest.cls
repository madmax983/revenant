@isTest
private class StepResultBusinessSleepTest {
  @isTest
  static void testDefaultBusinessHoursSleepInSeconds() {
    // Omitting business hours name preserves existing wall-clock sleep
    StepResult r1 = StepResult.sleep(10);
    Assert.areEqual(
      StepResult.ActionType.SLEEP,
      r1.action,
      'Action should be SLEEP'
    );
    Assert.areEqual(
      10,
      r1.sleepDurationSeconds,
      'Duration should be 10 seconds'
    );
    Assert.isNull(r1.stepStateJson, 'State JSON should be null');

    StepResult r2 = StepResult.sleep(20, 'my_state');
    Assert.areEqual(
      StepResult.ActionType.SLEEP,
      r2.action,
      'Action should be SLEEP'
    );
    Assert.areEqual(
      20,
      r2.sleepDurationSeconds,
      'Duration should be 20 seconds'
    );
    Assert.areEqual('my_state', r2.stepStateJson, 'State JSON should match');
  }

  @isTest
  static void testBusinessHoursHoursSleep() {
    // Start at Friday 16:00:00 (July 3, 2026) - No holidays in this window
    DateTime startTime = DateTime.newInstance(2026, 7, 3, 16, 0, 0);
    StepResult.mockCurrentDateTime = startTime;

    // Use default active business hours dynamically with all fields queried
    BusinessHours defaultBh = [
      SELECT
        Id,
        Name,
        IsActive,
        IsDefault,
        MondayStartTime,
        MondayEndTime,
        TuesdayStartTime,
        TuesdayEndTime,
        WednesdayStartTime,
        WednesdayEndTime,
        ThursdayStartTime,
        ThursdayEndTime,
        FridayStartTime,
        FridayEndTime,
        SaturdayStartTime,
        SaturdayEndTime,
        SundayStartTime,
        SundayEndTime
      FROM BusinessHours
      WHERE IsActive = TRUE AND IsDefault = TRUE
      LIMIT 1
    ];

    Long intervalMs = 2L * 3600000L; // 2 business hours
    DateTime expectedWake = BusinessHours.add(
      defaultBh.Id,
      startTime,
      intervalMs
    );
    Long expectedSeconds =
      (expectedWake.getTime() - startTime.getTime()) / 1000L;

    StepResult r = StepResult.sleep(2, 'Hours', defaultBh.Name, 'state_abc');

    Assert.areEqual(
      StepResult.ActionType.SLEEP,
      r.action,
      'Action should be SLEEP'
    );
    Assert.areEqual('state_abc', r.stepStateJson, 'State should match');
    Assert.areEqual(
      (Integer) expectedSeconds,
      r.sleepDurationSeconds,
      'Duration should match computed business hours difference'
    );
  }

  @isTest
  static void testBusinessHoursDaysSleep() {
    // Start at Friday 16:00:00 (July 3, 2026) - No holidays in this window
    DateTime startTime = DateTime.newInstance(2026, 7, 3, 16, 0, 0);
    StepResult.mockCurrentDateTime = startTime;

    // Use default active business hours dynamically with all fields queried
    BusinessHours defaultBh = [
      SELECT
        Id,
        Name,
        TimeZoneSidKey,
        IsActive,
        IsDefault,
        MondayStartTime,
        MondayEndTime,
        TuesdayStartTime,
        TuesdayEndTime,
        WednesdayStartTime,
        WednesdayEndTime,
        ThursdayStartTime,
        ThursdayEndTime,
        FridayStartTime,
        FridayEndTime,
        SaturdayStartTime,
        SaturdayEndTime,
        SundayStartTime,
        SundayEndTime
      FROM BusinessHours
      WHERE IsActive = TRUE AND IsDefault = TRUE
      LIMIT 1
    ];

    DateTime alignedStart = BusinessHours.isWithin(defaultBh.Id, startTime)
      ? startTime
      : BusinessHours.nextStartDate(defaultBh.Id, startTime);
    Long expectedMs = StepResult.getMillisecondsForDays(
      defaultBh,
      alignedStart,
      2
    );
    DateTime expectedWake = BusinessHours.add(
      defaultBh.Id,
      startTime,
      expectedMs
    );
    Long expectedSeconds =
      (expectedWake.getTime() - startTime.getTime()) / 1000L;

    StepResult r = StepResult.sleep(2, 'Days', defaultBh.Name);

    Assert.areEqual(
      StepResult.ActionType.SLEEP,
      r.action,
      'Action should be SLEEP'
    );
    Assert.areEqual(
      (Integer) expectedSeconds,
      r.sleepDurationSeconds,
      'Duration should match computed business days difference'
    );
  }

  @isTest
  static void testBusinessHoursHolidaySpanning() {
    // Check if Standard Business Hours exists (deployed in examples/scratch org)
    List<BusinessHours> standardBhs = [
      SELECT Id, Name, TimeZoneSidKey
      FROM BusinessHours
      WHERE IsActive = TRUE AND Name = 'Standard Business Hours'
      LIMIT 1
    ];
    if (standardBhs.isEmpty()) {
      return; // Skip holiday test if examples metadata is not present in target org
    }

    BusinessHours standardBh = standardBhs[0];

    // Start at Friday 16:00:00 (June 26, 2026)
    StepResult.mockCurrentDateTime = DateTime.newInstance(
      2026,
      6,
      26,
      16,
      0,
      0
    );

    DateTime testStart = StepResult.mockCurrentDateTime;
    DateTime alignedStart = BusinessHours.isWithin(standardBh.Id, testStart)
      ? testStart
      : BusinessHours.nextStartDate(standardBh.Id, testStart);
    Long expectedMs = StepResult.getMillisecondsForDays(
      standardBh,
      alignedStart,
      2
    );
    DateTime expectedWake = BusinessHours.add(
      standardBh.Id,
      testStart,
      expectedMs
    );
    Long expectedSeconds =
      (expectedWake.getTime() - testStart.getTime()) / 1000L;

    StepResult r = StepResult.sleep(2, 'Days', standardBh.Name);

    Assert.areEqual(
      StepResult.ActionType.SLEEP,
      r.action,
      'Action should be SLEEP'
    );
    Assert.areEqual(
      (Integer) expectedSeconds,
      r.sleepDurationSeconds,
      'Sleep duration seconds should match the dynamic standard BusinessHours calculation'
    );
  }

  @isTest
  static void testBusinessHoursDefaultExplicit() {
    // Start at Friday 16:00:00 (June 26, 2026)
    DateTime testStart = DateTime.newInstance(2026, 6, 26, 16, 0, 0);
    StepResult.mockCurrentDateTime = testStart;

    List<BusinessHours> defaultBhs = [
      SELECT Id, TimeZoneSidKey
      FROM BusinessHours
      WHERE IsActive = TRUE AND IsDefault = TRUE
      LIMIT 1
    ];
    if (defaultBhs.isEmpty()) {
      return;
    }
    BusinessHours defaultBh = defaultBhs[0];

    // Compute expected dynamically based on the org's actual default BusinessHours configuration.
    // Align start to the next open period:
    DateTime alignedStart = BusinessHours.isWithin(defaultBh.Id, testStart)
      ? testStart
      : BusinessHours.nextStartDate(defaultBh.Id, testStart);
    // Get expected business milliseconds:
    Long expectedMs = StepResult.getMillisecondsForDays(
      defaultBh,
      alignedStart,
      2
    );
    // Call BusinessHours.add to see what the final wake time will be:
    DateTime expectedWake = BusinessHours.add(
      defaultBh.Id,
      testStart,
      expectedMs
    );
    Long expectedDiffMs = expectedWake.getTime() - testStart.getTime();
    if (expectedDiffMs < 0) {
      expectedDiffMs = 0L;
    }
    Integer expectedSeconds = (Integer) (expectedDiffMs / 1000L);

    StepResult r = StepResult.sleep(2, 'Days', 'Default');

    Assert.areEqual(
      StepResult.ActionType.SLEEP,
      r.action,
      'Action should be SLEEP'
    );
    Assert.areEqual(
      expectedSeconds,
      r.sleepDurationSeconds,
      'Sleep duration seconds should match the dynamic default BusinessHours calculation'
    );
  }

  @isTest
  static void testBusinessHoursInvalidNameThrows() {
    try {
      StepResult.sleep(2, 'Days', 'NonExistentBusinessHours');
      Assert.fail('Should have thrown IllegalArgumentException');
    } catch (IllegalArgumentException ex) {
      Assert.isTrue(
        ex.getMessage().contains('Unknown Business Hours name'),
        'Unexpected error message: ' + ex.getMessage()
      );
    }
  }

  @isTest
  static void testBusinessHoursInvalidUnitThrows() {
    try {
      StepResult.sleep(2, 'Fortnights', 'Default');
      Assert.fail('Should have thrown IllegalArgumentException');
    } catch (IllegalArgumentException ex) {
      Assert.isTrue(
        ex.getMessage().contains('unsupported unit'),
        'Unexpected error message: ' + ex.getMessage()
      );
    }
  }

  @isTest
  static void testBusinessHoursInvalidAmountThrows() {
    try {
      StepResult.sleep(-1, 'Days', 'Default');
      Assert.fail('Should have thrown IllegalArgumentException');
    } catch (IllegalArgumentException ex) {
      Assert.isTrue(
        ex.getMessage().contains('amount must be a non-negative integer'),
        'Unexpected error message: ' + ex.getMessage()
      );
    }
  }

  @isTest
  static void testBusinessHoursCachingEffectiveness() {
    BusinessHours defaultBh = [
      SELECT Name
      FROM BusinessHours
      WHERE IsActive = TRUE AND IsDefault = TRUE
      LIMIT 1
    ];

    Integer startingQueries = Limits.getQueries();

    // 1. Initial default query
    StepResult r1 = StepResult.sleep(1, 'Days', 'Default');
    Integer afterFirstQuery = Limits.getQueries();
    Assert.isTrue(
      afterFirstQuery > startingQueries,
      'First lookup must query database'
    );

    // 2. Secondary default query (hits cache)
    StepResult r2 = StepResult.sleep(1, 'Days', 'Default');
    Assert.areEqual(
      afterFirstQuery,
      Limits.getQueries(),
      'Second lookup must hit the cache'
    );

    // 3. Named query matching default's actual name (hits cache)
    StepResult r3 = StepResult.sleep(1, 'Days', defaultBh.Name);
    Assert.areEqual(
      afterFirstQuery,
      Limits.getQueries(),
      'Named lookup for the default record must hit the cache'
    );
  }

  @isTest
  static void testUnequalBusinessDayLengthsDoNotAverage() {
    BusinessHours mockBh = new BusinessHours(
      MondayStartTime = Time.newInstance(9, 0, 0, 0),
      MondayEndTime = Time.newInstance(17, 0, 0, 0), // 8 hours
      TuesdayStartTime = Time.newInstance(9, 0, 0, 0),
      TuesdayEndTime = Time.newInstance(17, 0, 0, 0), // 8 hours
      WednesdayStartTime = Time.newInstance(9, 0, 0, 0),
      WednesdayEndTime = Time.newInstance(17, 0, 0, 0), // 8 hours
      ThursdayStartTime = Time.newInstance(9, 0, 0, 0),
      ThursdayEndTime = Time.newInstance(17, 0, 0, 0), // 8 hours
      FridayStartTime = Time.newInstance(9, 0, 0, 0),
      FridayEndTime = Time.newInstance(13, 0, 0, 0), // 4 hours
      TimeZoneSidKey = 'GMT'
    );

    // 1. Sleep 1 business day starting on Monday morning (July 6, 2026) -> should equal 8 working hours
    DateTime mondayStart = DateTime.newInstance(2026, 7, 6, 9, 0, 0);
    Long mondayMs = StepResult.getMillisecondsForDays(mockBh, mondayStart, 1);
    Assert.areEqual(
      8L * 3600000L,
      mondayMs,
      'Monday business day should be 8 working hours'
    );

    // 2. Sleep 1 business day starting on Friday morning (July 3, 2026) -> should equal 4 working hours
    DateTime fridayStart = DateTime.newInstance(2026, 7, 3, 9, 0, 0);
    Long fridayMs = StepResult.getMillisecondsForDays(mockBh, fridayStart, 1);
    Assert.areEqual(
      4L * 3600000L,
      fridayMs,
      'Friday business day should be 4 working hours'
    );
  }

  @isTest
  static void testWalkAfterHoursWithStandardBusinessHours() {
    List<BusinessHours> standardBhs = [
      SELECT
        Id,
        Name,
        TimeZoneSidKey,
        IsActive,
        IsDefault,
        MondayStartTime,
        MondayEndTime,
        TuesdayStartTime,
        TuesdayEndTime,
        WednesdayStartTime,
        WednesdayEndTime,
        ThursdayStartTime,
        ThursdayEndTime,
        FridayStartTime,
        FridayEndTime,
        SaturdayStartTime,
        SaturdayEndTime,
        SundayStartTime,
        SundayEndTime
      FROM BusinessHours
      WHERE IsActive = TRUE AND IsDefault = TRUE
      LIMIT 1
    ];
    if (standardBhs.isEmpty()) {
      return;
    }
    BusinessHours standardBh = standardBhs[0];

    // Starting on Saturday (closed day) should align start to Monday morning
    DateTime saturdayDate = DateTime.newInstance(2026, 7, 4, 12, 0, 0); // Saturday
    Long dayMs = StepResult.getMillisecondsForDays(standardBh, saturdayDate, 1);

    // Get expected Monday day length directly by starting on Monday morning
    DateTime mondayDate = DateTime.newInstance(2026, 7, 6, 9, 0, 0);
    Long mondayLength = StepResult.getMillisecondsForDays(
      standardBh,
      mondayDate,
      1
    );

    Assert.areEqual(
      mondayLength,
      dayMs,
      'Sleeping on Saturday should walk starting from the aligned Monday start and return Monday day length'
    );
  }

  @isTest
  static void testBusinessHoursHolidaySpanningWithVariableLengthDays() {
    List<BusinessHours> standardBhs = [
      SELECT
        Id,
        Name,
        TimeZoneSidKey,
        MondayStartTime,
        MondayEndTime,
        TuesdayStartTime,
        TuesdayEndTime,
        WednesdayStartTime,
        WednesdayEndTime,
        ThursdayStartTime,
        ThursdayEndTime,
        FridayStartTime,
        FridayEndTime,
        SaturdayStartTime,
        SaturdayEndTime,
        SundayStartTime,
        SundayEndTime
      FROM BusinessHours
      WHERE IsActive = TRUE AND IsDefault = TRUE
      LIMIT 1
    ];
    if (standardBhs.isEmpty()) {
      return;
    }
    BusinessHours standardBh = standardBhs[0];

    // Friday June 26, 2026. Monday June 29, 2026 is a holiday (configured in examples settings metadata).
    DateTime startFriday = DateTime.newInstance(2026, 6, 26, 9, 0, 0);

    // Dynamically check if Monday June 29, 2026 is treated as a holiday (closed) on this calendar.
    DateTime monday = DateTime.newInstance(2026, 6, 29, 12, 0, 0);
    Boolean isMondayOpen = BusinessHours.isWithin(standardBh.Id, monday);

    DateTime secondDay = isMondayOpen
      ? DateTime.newInstance(2026, 6, 29, 9, 0, 0) // Monday
      : DateTime.newInstance(2026, 6, 30, 9, 0, 0); // Tuesday

    // Sum of Friday's working ms + second day's working ms
    Long expectedMs =
      StepResult.getWorkingMsForDay(standardBh, startFriday) +
      StepResult.getWorkingMsForDay(standardBh, secondDay);

    Long actualMs = StepResult.getMillisecondsForDays(
      standardBh,
      startFriday,
      2
    );

    Assert.areEqual(
      expectedMs,
      actualMs,
      'Calculated day walking milliseconds must match dynamic configuration'
    );
  }

  @isTest
  static void testPositiveOffsetDstMidnightRefinement() {
    // Australia/Sydney DST start: Sunday, October 4, 2026
    Date targetDate = Date.newInstance(2026, 10, 4);
    String tz = 'Australia/Sydney';

    // Call getLocalMidnight
    DateTime midnight = StepResult.getLocalMidnight(targetDate, tz);

    // In Australia/Sydney, the offset at 00:00:00 Sunday Oct 4, 2026 is UTC+10.
    // So the GMT time of local midnight should be exactly Saturday Oct 3, 14:00:00 GMT.
    DateTime expectedGmtMidnight = DateTime.newInstanceGmt(
      2026,
      10,
      3,
      14,
      0,
      0
    );

    Assert.areEqual(
      expectedGmtMidnight.getTime(),
      midnight.getTime(),
      'Local midnight for Sydney on transition day must use pre-transition offset (UTC+10) and equal 14:00:00 GMT'
    );
  }

  @isTest
  static void testDstFallbackDayWalkingRegression() {
    // Mock a BusinessHours record with America/Chicago timezone.
    // Sunday: 8 hours (28,800,000 ms)
    // Monday: 10 hours (36,000,000 ms)
    // All other days closed.
    BusinessHours mockBh = new BusinessHours(
      TimeZoneSidKey = 'America/Chicago',
      SundayStartTime = Time.newInstance(9, 0, 0, 0),
      SundayEndTime = Time.newInstance(17, 0, 0, 0),
      MondayStartTime = Time.newInstance(8, 0, 0, 0),
      MondayEndTime = Time.newInstance(18, 0, 0, 0)
    );

    // America/Chicago DST Fall-back: Sunday, November 4, 2018.
    // Start at 00:30:00 local time on Sunday (before the DST transition).
    // The offset before DST end is UTC-5, so local 00:30:00 Sunday is 05:30:00 Sunday GMT.
    DateTime startDateTime = DateTime.newInstanceGmt(2018, 11, 4, 5, 30, 0);

    // Walk 2 business days. If the bug is present, Sunday will be processed twice, returning 16 hours.
    // If correct, it walks Sunday (8h) + Monday (10h), returning 18 hours (64,800,000 ms).
    Long actualMs = StepResult.getMillisecondsForDays(mockBh, startDateTime, 2);

    Long expectedMs = 64800000L; // 8 hours + 10 hours

    Assert.areEqual(
      expectedMs,
      actualMs,
      'Should walk from Sunday (8h) to Monday (10h) instead of repeating Sunday due to DST fall-back'
    );
  }

  @isTest
  static void testUnequalDayWalkLargeDurationRegression() {
    // Mock a BusinessHours record. Monday = 8h, Tuesday = 10h, all others closed.
    BusinessHours mockBh = new BusinessHours(
      TimeZoneSidKey = 'America/Chicago',
      MondayStartTime = Time.newInstance(9, 0, 0, 0),
      MondayEndTime = Time.newInstance(17, 0, 0, 0),
      TuesdayStartTime = Time.newInstance(8, 0, 0, 0),
      TuesdayEndTime = Time.newInstance(18, 0, 0, 0)
    );

    // Monday November 5, 2018 (start of walk)
    DateTime startDateTime = DateTime.newInstanceGmt(2018, 11, 5, 12, 0, 0);

    // 106 business days = 53 Mondays (53 * 8h) and 53 Tuesdays (53 * 10h)
    // 53 * 8 = 424h. 53 * 10 = 530h. Total = 954h = 3,434,400,000 ms.
    // If the 365 cap was active, it would stop at 105 days and estimate day 106 as 8.99h instead of 10h.
    Long actualMs = StepResult.getMillisecondsForDays(
      mockBh,
      startDateTime,
      106
    );

    Long expectedMs = 3434400000L;

    Assert.areEqual(
      expectedMs,
      actualMs,
      'Should walk all 106 business days exactly without falling back to averaged day lengths'
    );
  }

  @isTest
  static void testLargeDurationExceedingScanLimitThrows() {
    // Mock a BusinessHours record. Monday = 8h, all others closed.
    BusinessHours mockBh = new BusinessHours(
      TimeZoneSidKey = 'America/Chicago',
      MondayStartTime = Time.newInstance(9, 0, 0, 0),
      MondayEndTime = Time.newInstance(17, 0, 0, 0)
    );

    // Monday November 5, 2018 (start of walk)
    DateTime startDateTime = DateTime.newInstanceGmt(2018, 11, 5, 12, 0, 0);

    // Requesting 600 business days on a Monday-only calendar requires 600 * 7 = 4200 calendar days.
    // Since 4200 exceeds the 3650 calendar days limit, it should throw an IllegalArgumentException.
    Boolean threwException = false;
    try {
      StepResult.getMillisecondsForDays(mockBh, startDateTime, 600);
    } catch (IllegalArgumentException e) {
      Assert.isTrue(
        e.getMessage()
          .contains(
            'requested business duration exceeds the maximum calendar scan limit'
          ),
        'Exception message should specify the calendar scan limit exceedance'
      );
      threwException = true;
    }

    Assert.isTrue(
      threwException,
      'Should have thrown IllegalArgumentException for duration exceeding maximum scan limit'
    );
  }
}
