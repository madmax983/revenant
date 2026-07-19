@IsTest
public class WorkflowCronEvaluatorTest {
  // Fixed reference point: 2026-06-17 14:37:00 UTC
  private static final DateTime REF = DateTime.newInstanceGmt(
    2026,
    6,
    17,
    14,
    37,
    0
  );
  private static final String NY = 'America/New_York';

  // ── Exact-minute anchor ──────────────────────────────────────────────────

  @IsTest
  static void testHourlyOnTheHour() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "0 * * * *" fires at :00 of every hour. Previous fire from 14:37 = 14:00.
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0 * * * *',
        REF
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 17, 14, 0, 0),
        result,
        'Hourly: previous fire should be 14:00'
      );
    }
  }

  @IsTest
  static void testHourlyExactlyOnFire() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // When now IS a fire minute, return it (previous fire ≤ now).
      DateTime onFire = DateTime.newInstanceGmt(2026, 6, 17, 14, 0, 0);
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0 * * * *',
        onFire
      );
      System.assertEquals(
        onFire,
        result,
        'When now is exactly a fire instant, return it'
      );
    }
  }

  // ── Steps ─────────────────────────────────────────────────────────────────

  @IsTest
  static void testEvery15Minutes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "*/15 * * * *" fires at :00, :15, :30, :45. Previous from 14:37 = 14:30.
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '*/15 * * * *',
        REF
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 17, 14, 30, 0),
        result,
        'Every-15: previous fire from :37 should be :30'
      );
    }
  }

  @IsTest
  static void testEvery15MinutesOnStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Exactly at :45 → return :45.
      DateTime onStep = DateTime.newInstanceGmt(2026, 6, 17, 14, 45, 0);
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '*/15 * * * *',
        onStep
      );
      System.assertEquals(
        onStep,
        result,
        'On :45 step boundary should return :45'
      );
    }
  }

  // ── Daily ─────────────────────────────────────────────────────────────────

  @IsTest
  static void testDailyBeforeFireTime() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "0 2 * * *" fires at 02:00 daily. 14:37 → same-day 02:00.
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0 2 * * *',
        REF
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 17, 2, 0, 0),
        result,
        'Daily 02:00: previous fire should be today at 02:00'
      );
    }
  }

  @IsTest
  static void testDailyBeforeMidnight() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Now is 01:30 → today 02:00 hasn't fired yet → previous fire = yesterday 02:00.
      DateTime before = DateTime.newInstanceGmt(2026, 6, 17, 1, 30, 0);
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0 2 * * *',
        before
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 16, 2, 0, 0),
        result,
        'Daily 02:00: when now is before todays fire, previous = yesterday'
      );
    }
  }

  // ── Day-of-month ──────────────────────────────────────────────────────────

  @IsTest
  static void testDayOfMonthCurrentMonth() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "0 0 15 * *" fires at midnight on the 15th. On Jun 17 → Jun 15.
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0 0 15 * *',
        REF
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 15, 0, 0, 0),
        result,
        'Day-15: previous fire should be Jun 15'
      );
    }
  }

  @IsTest
  static void testDayOfMonthPreviousMonth() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Now is Jun 10 → haven't hit the 15th this month → May 15.
      DateTime before15 = DateTime.newInstanceGmt(2026, 6, 10, 12, 0, 0);
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0 0 15 * *',
        before15
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 5, 15, 0, 0, 0),
        result,
        'Day-15: before the 15th, previous should be prior month'
      );
    }
  }

  // ── Day-of-week ───────────────────────────────────────────────────────────

  @IsTest
  static void testDayOfWeekMonday() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "0 9 * * 1" fires at 09:00 every Monday. Jun 17 is a Wednesday.
      // Previous Monday = Jun 15.
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0 9 * * 1',
        REF
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 15, 9, 0, 0),
        result,
        'Monday 09:00: previous fire should be Jun 15'
      );
    }
  }

  @IsTest
  static void testDayOfWeekWednesdayBeforeFireHour() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Now is Wednesday 08:00. The 09:00 fire today hasn't happened yet.
      // Previous fire = last Wednesday = Jun 10.
      DateTime before9 = DateTime.newInstanceGmt(2026, 6, 17, 8, 0, 0);
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0 9 * * 3',
        before9
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 10, 9, 0, 0),
        result,
        'Wed 09:00: when now is 08:00 Wed, previous fire should be prior Wed'
      );
    }
  }

  // ── Lists ─────────────────────────────────────────────────────────────────

  @IsTest
  static void testMinuteList() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "0,30 * * * *" fires at :00 and :30. At 14:37 → 14:30.
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0,30 * * * *',
        REF
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 17, 14, 30, 0),
        result,
        'Minute list 0,30: previous from :37 should be :30'
      );
    }
  }

  @IsTest
  static void testHourList() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "0 8,14,20 * * *" fires at 08:00, 14:00, 20:00. At 14:37 → 14:00.
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0 8,14,20 * * *',
        REF
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 17, 14, 0, 0),
        result,
        'Hour list 8,14,20: previous from 14:37 should be 14:00'
      );
    }
  }

  // ── Ranges ────────────────────────────────────────────────────────────────

  @IsTest
  static void testMinuteRange() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "0-5 * * * *" fires at :00,:01,:02,:03,:04,:05. At 14:37 → 14:05 from previous hour? No — 14:05.
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0-5 * * * *',
        REF
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 17, 14, 5, 0),
        result,
        'Minute range 0-5: previous from :37 should be :05 same hour'
      );
    }
  }

  // ── Steps on range ────────────────────────────────────────────────────────

  @IsTest
  static void testStepOnRange() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "0-30/10 * * * *" fires at :00,:10,:20,:30. At 14:37 → 14:30.
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0-30/10 * * * *',
        REF
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 17, 14, 30, 0),
        result,
        'Range+step 0-30/10: previous from :37 should be :30'
      );
    }
  }

  // ── Month filter ──────────────────────────────────────────────────────────

  @IsTest
  static void testMonthFilterCurrentMonth() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "0 12 1 6 *" fires at noon on June 1. Jun 17 → Jun 1 12:00.
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0 12 1 6 *',
        REF
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 1, 12, 0, 0),
        result,
        'June 1 noon: previous from Jun 17 should be Jun 1'
      );
    }
  }

  @IsTest
  static void testMonthFilterPreviousYear() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "0 12 1 3 *" fires at noon on March 1. On Jun 17 → this year's Mar 1.
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0 12 1 3 *',
        REF
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 3, 1, 12, 0, 0),
        result,
        'March 1 noon: previous from Jun 17 should be Mar 1 same year'
      );
    }
  }

  // ── Invalid / never-match ─────────────────────────────────────────────────

  @IsTest
  static void testInvalidCronNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        null,
        WorkflowCronEvaluator.previousFireTime(null, REF),
        'Null cron → null'
      );
    }
  }

  @IsTest
  static void testInvalidCronEmpty() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        null,
        WorkflowCronEvaluator.previousFireTime('', REF),
        'Empty cron → null'
      );
    }
  }

  @IsTest
  static void testInvalidCronWrongFieldCount() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        null,
        WorkflowCronEvaluator.previousFireTime('* * * *', REF),
        'Wrong field count → null'
      );
    }
  }

  @IsTest
  static void testInvalidCronOutOfRange() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Minute 99 is invalid; should return null.
      System.assertEquals(
        null,
        WorkflowCronEvaluator.previousFireTime('99 * * * *', REF),
        'Out-of-range minute → null'
      );
    }
  }

  @IsTest
  static void testNeverMatchCronFeb31() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Feb 31 never exists: should return null.
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0 0 31 2 *',
        REF
      );
      System.assertEquals(null, result, 'Feb 31 never fires → null');
    }
  }

  @IsTest
  static void testNullNow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        null,
        WorkflowCronEvaluator.previousFireTime('* * * * *', null),
        'Null now → null'
      );
    }
  }

  // ── Wildcard all ──────────────────────────────────────────────────────────

  @IsTest
  static void testWildcardAllReturnsNow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "* * * * *" fires every minute; previous fire = now truncated to the minute.
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '* * * * *',
        REF
      );
      DateTime expected = DateTime.newInstanceGmt(2026, 6, 17, 14, 37, 0);
      System.assertEquals(
        expected,
        result,
        'Wildcard-all: previous fire = current minute'
      );
    }
  }

  // ── isValidCron ─────────────────────────────────────────────────────────────

  @IsTest
  static void testIsValidCron() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        true,
        WorkflowCronEvaluator.isValidCron('0 2 * * *'),
        'Daily valid'
      );
      System.assertEquals(
        true,
        WorkflowCronEvaluator.isValidCron('*/15 9-17 * * 1-5'),
        'Complex valid'
      );
      System.assertEquals(
        false,
        WorkflowCronEvaluator.isValidCron(null),
        'Null invalid'
      );
      System.assertEquals(
        false,
        WorkflowCronEvaluator.isValidCron(''),
        'Empty invalid'
      );
      System.assertEquals(
        false,
        WorkflowCronEvaluator.isValidCron('* * * *'),
        'Wrong field count invalid'
      );
      System.assertEquals(
        false,
        WorkflowCronEvaluator.isValidCron('99 * * * *'),
        'Out-of-range invalid'
      );
      System.assertEquals(
        false,
        WorkflowCronEvaluator.isValidCron('a b c d e'),
        'Non-numeric invalid'
      );
    }
  }

  // ── nextFireTime ────────────────────────────────────────────────────────────

  @IsTest
  static void testNextFireHourly() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "0 * * * *" → next fire from 14:37 = 15:00.
      DateTime result = WorkflowCronEvaluator.nextFireTime('0 * * * *', REF);
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 17, 15, 0, 0),
        result,
        'Hourly: next fire from :37 should be next hour :00'
      );
    }
  }

  @IsTest
  static void testNextFireExactlyOnFire() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // When now IS a fire minute, return it (next fire ≥ now).
      DateTime onFire = DateTime.newInstanceGmt(2026, 6, 17, 15, 0, 0);
      DateTime result = WorkflowCronEvaluator.nextFireTime('0 * * * *', onFire);
      System.assertEquals(onFire, result, 'On a fire instant, next fire = now');
    }
  }

  @IsTest
  static void testNextFireEvery15() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "*/15 * * * *" → next fire from 14:37 = 14:45.
      DateTime result = WorkflowCronEvaluator.nextFireTime('*/15 * * * *', REF);
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 17, 14, 45, 0),
        result,
        'Every-15: next fire from :37 should be :45'
      );
    }
  }

  @IsTest
  static void testNextFireDailyRollToTomorrow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "0 2 * * *" at 14:37 → today's 02:00 already passed → tomorrow 02:00.
      DateTime result = WorkflowCronEvaluator.nextFireTime('0 2 * * *', REF);
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 18, 2, 0, 0),
        result,
        'Daily 02:00: next fire from 14:37 should be tomorrow 02:00'
      );
    }
  }

  @IsTest
  static void testNextFireDayOfWeek() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "0 9 * * 1" (Mondays 09:00). Jun 17 is Wed → next Monday Jun 22.
      DateTime result = WorkflowCronEvaluator.nextFireTime('0 9 * * 1', REF);
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 22, 9, 0, 0),
        result,
        'Monday 09:00: next from Wed Jun 17 should be Mon Jun 22'
      );
    }
  }

  @IsTest
  static void testNextFireInvalidNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        null,
        WorkflowCronEvaluator.nextFireTime('99 * * * *', REF),
        'Invalid → null'
      );
      System.assertEquals(
        null,
        WorkflowCronEvaluator.nextFireTime('* * * * *', null),
        'Null now → null'
      );
      System.assertEquals(
        null,
        WorkflowCronEvaluator.nextFireTime('0 0 31 2 *', REF),
        'Feb 31 never → null'
      );
    }
  }

  @IsTest
  static void testNextFireMonthRollover() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // "0 0 1 * *" first of month midnight. From Jun 17 → Jul 1 00:00.
      DateTime result = WorkflowCronEvaluator.nextFireTime('0 0 1 * *', REF);
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 7, 1, 0, 0, 0),
        result,
        'First-of-month: next from Jun 17 should be Jul 1'
      );
    }
  }

  // ── Zone-aware evaluation (America/New_York) ──────────────────────────────

  @IsTest
  static void testZoneNightlyEst() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Winter: 02:00 US/Eastern (EST, UTC-5) resolves to 07:00Z. Reference is
      // 2026-01-15 12:00Z (07:00 EST), so the previous 02:00 window is same day.
      DateTime ref = DateTime.newInstanceGmt(2026, 1, 15, 12, 0, 0);
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0 2 * * *',
        ref,
        NY
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 1, 15, 7, 0, 0),
        result,
        'EST nightly 02:00 should resolve to 07:00Z'
      );
    }
  }

  @IsTest
  static void testZoneNightlyEdt() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Summer: 02:00 US/Eastern (EDT, UTC-4) resolves to 06:00Z. Reference is
      // 2026-06-17 12:00Z (08:00 EDT).
      DateTime ref = DateTime.newInstanceGmt(2026, 6, 17, 12, 0, 0);
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0 2 * * *',
        ref,
        NY
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 17, 6, 0, 0),
        result,
        'EDT nightly 02:00 should resolve to 06:00Z'
      );
    }
  }

  @IsTest
  static void testZoneSpringGapFiresOnceAtBoundary() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Spring-forward day 2026-03-08: local clocks jump 02:00 → 03:00, so the
      // 02:00 wall clock never occurs. Policy returns the gap boundary ONCE: the
      // transition instant 07:00Z, which renders as 03:00 EDT. Reference is
      // 2026-03-08 12:00Z (08:00 EDT).
      DateTime ref = DateTime.newInstanceGmt(2026, 3, 8, 12, 0, 0);
      DateTime result = WorkflowCronEvaluator.previousFireTime(
        '0 2 * * *',
        ref,
        NY
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 3, 8, 7, 0, 0),
        result,
        'Spring gap 02:00 should resolve once to the boundary 07:00Z'
      );
      System.assertEquals(
        '2026-03-08 03:00',
        result.format('yyyy-MM-dd HH:mm', NY),
        'Boundary instant renders as 03:00 New York wall clock'
      );

      // A time strictly inside the gap (02:30) also collapses to the boundary.
      DateTime midGap = WorkflowCronEvaluator.previousFireTime(
        '30 2 * * *',
        ref,
        NY
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 3, 8, 7, 0, 0),
        midGap,
        'A local time inside the gap resolves to the same boundary instant'
      );
    }
  }

  @IsTest
  static void testZoneFallBackFiresOnce() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Fall-back day 2026-11-01: local 01:00–01:59 occurs twice. 02:00 occurs
      // once (EST) → 07:00Z. Reference is 2026-11-01 12:00Z (07:00 EST).
      DateTime ref = DateTime.newInstanceGmt(2026, 11, 1, 12, 0, 0);
      DateTime nightly = WorkflowCronEvaluator.previousFireTime(
        '0 2 * * *',
        ref,
        NY
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 11, 1, 7, 0, 0),
        nightly,
        'Fall-back 02:00 EST should resolve to 07:00Z'
      );

      // 01:30 exists twice; policy picks the FIRST (pre-transition, EDT) at
      // 05:30Z so the calendar day fires exactly once.
      DateTime overlap = WorkflowCronEvaluator.previousFireTime(
        '30 1 * * *',
        ref,
        NY
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 11, 1, 5, 30, 0),
        overlap,
        'Overlapping 01:30 should resolve to the earliest (EDT) occurrence 05:30Z'
      );
    }
  }

  @IsTest
  static void testZoneFallBackForwardReturnsFutureInstant() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Fall-back day 2026-11-01: local 01:30 occurs twice — 05:30Z (EDT,
      // pre-transition) and 06:30Z (EST, post-transition). With now at 06:00Z
      // (between the two occurrences) the earliest occurrence 05:30Z is already
      // in the past, so a forward search must NOT return it; it must skip to the
      // next day's 01:30 fire, which under EST resolves to 2026-11-02 06:30Z.
      DateTime nowBetween = DateTime.newInstanceGmt(2026, 11, 1, 6, 0, 0);
      DateTime forward = WorkflowCronEvaluator.nextFireTime(
        '30 1 * * *',
        nowBetween,
        NY
      );
      System.assert(
        forward >= nowBetween,
        'Forward search across a fall-back overlap must return a strictly-future instant, not the past 05:30Z occurrence (got ' +
          forward +
          ')'
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 11, 2, 6, 30, 0),
        forward,
        'Forward search should skip to the next day 01:30 EST fire at 06:30Z'
      );

      // The backward/due-detection path is unchanged: previous still resolves the
      // overlap to the earliest (EDT) occurrence 05:30Z at or before now.
      DateTime backward = WorkflowCronEvaluator.previousFireTime(
        '30 1 * * *',
        nowBetween,
        NY
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 11, 1, 5, 30, 0),
        backward,
        'Previous must still resolve the overlap to the earliest (EDT) 05:30Z occurrence'
      );

      // No regression on a normal (non-transition) summer day: no overlap, so the
      // forward search accepts the first matched local wall clock. 2026-06-17
      // 01:30 EDT (offset -4) resolves to 05:30Z and is returned unchanged.
      DateTime normalRef = DateTime.newInstanceGmt(2026, 6, 17, 0, 0, 0);
      DateTime normalForward = WorkflowCronEvaluator.nextFireTime(
        '30 1 * * *',
        normalRef,
        NY
      );
      System.assert(
        normalForward >= normalRef,
        'Normal-day forward search must return an instant at or after now'
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 6, 17, 5, 30, 0),
        normalForward,
        'Normal-day 01:30 EDT should resolve to 05:30Z with no overlap skipping'
      );

      // Current-minute window must be KEPT when now carries seconds. Summer EDT
      // (UTC-4): 09:00:30 local is 13:00:30Z. A "0 9 * * *" forward search must
      // return TODAY's 09:00 fire (13:00:00Z), not push to tomorrow — the guard
      // floors now to the minute so the minute-aligned candidate is accepted,
      // matching the blank/UTC path which truncates now before matching.
      DateTime nowWithSeconds = DateTime.newInstanceGmt(2026, 7, 19, 13, 0, 30);
      DateTime currentMinute = WorkflowCronEvaluator.nextFireTime(
        '0 9 * * *',
        nowWithSeconds,
        NY
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 7, 19, 13, 0, 0),
        currentMinute,
        'Zoned forward search at 09:00:30 must keep the current 09:00 minute (13:00Z), not skip to tomorrow'
      );

      // Blank/UTC path is unchanged: it already truncates now to the minute, so
      // 09:00:30Z on "0 9 * * *" keeps the current 09:00Z window (the behavior
      // the zoned path above is being made consistent with).
      DateTime blankNowWithSeconds = DateTime.newInstanceGmt(
        2026,
        7,
        19,
        9,
        0,
        30
      );
      DateTime blankCurrentMinute = WorkflowCronEvaluator.nextFireTime(
        '0 9 * * *',
        blankNowWithSeconds,
        ''
      );
      System.assertEquals(
        DateTime.newInstanceGmt(2026, 7, 19, 9, 0, 0),
        blankCurrentMinute,
        'Blank-zone forward search keeps the current 09:00Z minute at 09:00:30Z'
      );
    }
  }

  // ── Backward compatibility: blank/null zone == the no-arg exact-GMT path ────

  @IsTest
  static void testBlankZoneMatchesNoArgExactly() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<String> crons = new List<String>{
        '0 * * * *',
        '*/15 * * * *',
        '0 2 * * *',
        '0 9 * * 1',
        '0 0 1 * *',
        '0-30/10 * * * *'
      };
      for (String cron : crons) {
        DateTime baselinePrev = WorkflowCronEvaluator.previousFireTime(
          cron,
          REF
        );
        System.assertEquals(
          baselinePrev,
          WorkflowCronEvaluator.previousFireTime(cron, REF, null),
          'Null zone previous must equal the no-arg result for ' + cron
        );
        System.assertEquals(
          baselinePrev,
          WorkflowCronEvaluator.previousFireTime(cron, REF, ''),
          'Blank zone previous must equal the no-arg result for ' + cron
        );

        DateTime baselineNext = WorkflowCronEvaluator.nextFireTime(cron, REF);
        System.assertEquals(
          baselineNext,
          WorkflowCronEvaluator.nextFireTime(cron, REF, null),
          'Null zone next must equal the no-arg result for ' + cron
        );
        System.assertEquals(
          baselineNext,
          WorkflowCronEvaluator.nextFireTime(cron, REF, ''),
          'Blank zone next must equal the no-arg result for ' + cron
        );
      }
    }
  }

  // ── isValidZone ─────────────────────────────────────────────────────────────

  @IsTest
  static void testIsValidZone() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        true,
        WorkflowCronEvaluator.isValidZone(null),
        'Null zone (UTC) is valid'
      );
      System.assertEquals(
        true,
        WorkflowCronEvaluator.isValidZone(''),
        'Blank zone (UTC) is valid'
      );
      System.assertEquals(
        true,
        WorkflowCronEvaluator.isValidZone('America/New_York'),
        'Supported IANA id is valid'
      );
      System.assertEquals(
        true,
        WorkflowCronEvaluator.isValidZone('UTC'),
        'Explicit UTC is valid'
      );
      System.assertEquals(
        false,
        WorkflowCronEvaluator.isValidZone('Not/AZone'),
        'Unsupported id is invalid'
      );
      System.assertEquals(
        false,
        WorkflowCronEvaluator.isValidZone('america/new_york'),
        'Case-mismatched id is invalid'
      );
    }
  }
}
