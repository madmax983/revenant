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

    Long dayMs = StepResult.getMillisecondsInBusinessDay(defaultBh);
    Long intervalMs = 2L * dayMs; // 2 business days
    DateTime expectedWake = BusinessHours.add(
      defaultBh.Id,
      startTime,
      intervalMs
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
      SELECT Id, Name
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

    // Sleep 2 business days under Standard Business Hours (8 hours/day).
    // Monday June 29, 2026 is a holiday, so it is skipped.
    // Friday 16:00 to Friday 17:00 (1 hour)
    // Monday June 29 (0 hours - Holiday)
    // Tuesday June 30 09:00 to 17:00 (8 hours)
    // Wednesday July 1 09:00 to 16:00 (7 hours)
    // Total calendar time: Friday 16:00 to Wednesday 16:00 = 120 hours = 432,000 seconds
    StepResult r = StepResult.sleep(2, 'Days', standardBh.Name);

    Assert.areEqual(
      StepResult.ActionType.SLEEP,
      r.action,
      'Action should be SLEEP'
    );
    Assert.areEqual(
      432000,
      r.sleepDurationSeconds,
      'Should have skipped holiday on Monday'
    );
  }

  @isTest
  static void testBusinessHoursDefaultExplicit() {
    // Start at Friday 16:00:00 (June 26, 2026)
    StepResult.mockCurrentDateTime = DateTime.newInstance(
      2026,
      6,
      26,
      16,
      0,
      0
    );

    // Default business hours has 24 hours daily.
    // 2 business days = 48 business hours.
    // Friday 16:00 + 48 hours = Sunday 16:00 = 172,800 seconds
    StepResult r = StepResult.sleep(2, 'Days', 'Default');

    Assert.areEqual(
      StepResult.ActionType.SLEEP,
      r.action,
      'Action should be SLEEP'
    );
    Assert.areEqual(
      172800,
      r.sleepDurationSeconds,
      'Default 24/7 business hours should be 48 hours in seconds'
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
}
