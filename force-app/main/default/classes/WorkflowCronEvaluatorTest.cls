@isTest
public class WorkflowCronEvaluatorTest {
  // Fixed reference point: 2026-06-17 14:37:00 UTC
  private static final DateTime REF = DateTime.newInstanceGmt(2026, 6, 17, 14, 37, 0);

  // ── Exact-minute anchor ──────────────────────────────────────────────────

  @isTest
  static void testHourly_onTheHour() {
    // "0 * * * *" fires at :00 of every hour. Previous fire from 14:37 = 14:00.
    DateTime result = WorkflowCronEvaluator.previousFireTime('0 * * * *', REF);
    System.assertEquals(
      DateTime.newInstanceGmt(2026, 6, 17, 14, 0, 0),
      result,
      'Hourly: previous fire should be 14:00'
    );
  }

  @isTest
  static void testHourly_exactlyOnFire() {
    // When now IS a fire minute, return it (previous fire ≤ now).
    DateTime onFire = DateTime.newInstanceGmt(2026, 6, 17, 14, 0, 0);
    DateTime result = WorkflowCronEvaluator.previousFireTime('0 * * * *', onFire);
    System.assertEquals(onFire, result, 'When now is exactly a fire instant, return it');
  }

  // ── Steps ─────────────────────────────────────────────────────────────────

  @isTest
  static void testEvery15Minutes() {
    // "*/15 * * * *" fires at :00, :15, :30, :45. Previous from 14:37 = 14:30.
    DateTime result = WorkflowCronEvaluator.previousFireTime('*/15 * * * *', REF);
    System.assertEquals(
      DateTime.newInstanceGmt(2026, 6, 17, 14, 30, 0),
      result,
      'Every-15: previous fire from :37 should be :30'
    );
  }

  @isTest
  static void testEvery15Minutes_onStep() {
    // Exactly at :45 → return :45.
    DateTime onStep = DateTime.newInstanceGmt(2026, 6, 17, 14, 45, 0);
    DateTime result = WorkflowCronEvaluator.previousFireTime('*/15 * * * *', onStep);
    System.assertEquals(onStep, result, 'On :45 step boundary should return :45');
  }

  // ── Daily ─────────────────────────────────────────────────────────────────

  @isTest
  static void testDaily_beforeFireTime() {
    // "0 2 * * *" fires at 02:00 daily. 14:37 → same-day 02:00.
    DateTime result = WorkflowCronEvaluator.previousFireTime('0 2 * * *', REF);
    System.assertEquals(
      DateTime.newInstanceGmt(2026, 6, 17, 2, 0, 0),
      result,
      'Daily 02:00: previous fire should be today at 02:00'
    );
  }

  @isTest
  static void testDaily_beforeMidnight() {
    // Now is 01:30 → today 02:00 hasn't fired yet → previous fire = yesterday 02:00.
    DateTime before = DateTime.newInstanceGmt(2026, 6, 17, 1, 30, 0);
    DateTime result = WorkflowCronEvaluator.previousFireTime('0 2 * * *', before);
    System.assertEquals(
      DateTime.newInstanceGmt(2026, 6, 16, 2, 0, 0),
      result,
      'Daily 02:00: when now is before todays fire, previous = yesterday'
    );
  }

  // ── Day-of-month ──────────────────────────────────────────────────────────

  @isTest
  static void testDayOfMonth_currentMonth() {
    // "0 0 15 * *" fires at midnight on the 15th. On Jun 17 → Jun 15.
    DateTime result = WorkflowCronEvaluator.previousFireTime('0 0 15 * *', REF);
    System.assertEquals(
      DateTime.newInstanceGmt(2026, 6, 15, 0, 0, 0),
      result,
      'Day-15: previous fire should be Jun 15'
    );
  }

  @isTest
  static void testDayOfMonth_previousMonth() {
    // Now is Jun 10 → haven't hit the 15th this month → May 15.
    DateTime before15 = DateTime.newInstanceGmt(2026, 6, 10, 12, 0, 0);
    DateTime result = WorkflowCronEvaluator.previousFireTime('0 0 15 * *', before15);
    System.assertEquals(
      DateTime.newInstanceGmt(2026, 5, 15, 0, 0, 0),
      result,
      'Day-15: before the 15th, previous should be prior month'
    );
  }

  // ── Day-of-week ───────────────────────────────────────────────────────────

  @isTest
  static void testDayOfWeek_monday() {
    // "0 9 * * 1" fires at 09:00 every Monday. Jun 17 is a Wednesday.
    // Previous Monday = Jun 15.
    DateTime result = WorkflowCronEvaluator.previousFireTime('0 9 * * 1', REF);
    System.assertEquals(
      DateTime.newInstanceGmt(2026, 6, 15, 9, 0, 0),
      result,
      'Monday 09:00: previous fire should be Jun 15'
    );
  }

  @isTest
  static void testDayOfWeek_wednesday_beforeFireHour() {
    // Now is Wednesday 08:00. The 09:00 fire today hasn't happened yet.
    // Previous fire = last Wednesday = Jun 10.
    DateTime before9 = DateTime.newInstanceGmt(2026, 6, 17, 8, 0, 0);
    DateTime result = WorkflowCronEvaluator.previousFireTime('0 9 * * 3', before9);
    System.assertEquals(
      DateTime.newInstanceGmt(2026, 6, 10, 9, 0, 0),
      result,
      'Wed 09:00: when now is 08:00 Wed, previous fire should be prior Wed'
    );
  }

  // ── Lists ─────────────────────────────────────────────────────────────────

  @isTest
  static void testMinuteList() {
    // "0,30 * * * *" fires at :00 and :30. At 14:37 → 14:30.
    DateTime result = WorkflowCronEvaluator.previousFireTime('0,30 * * * *', REF);
    System.assertEquals(
      DateTime.newInstanceGmt(2026, 6, 17, 14, 30, 0),
      result,
      'Minute list 0,30: previous from :37 should be :30'
    );
  }

  @isTest
  static void testHourList() {
    // "0 8,14,20 * * *" fires at 08:00, 14:00, 20:00. At 14:37 → 14:00.
    DateTime result = WorkflowCronEvaluator.previousFireTime('0 8,14,20 * * *', REF);
    System.assertEquals(
      DateTime.newInstanceGmt(2026, 6, 17, 14, 0, 0),
      result,
      'Hour list 8,14,20: previous from 14:37 should be 14:00'
    );
  }

  // ── Ranges ────────────────────────────────────────────────────────────────

  @isTest
  static void testMinuteRange() {
    // "0-5 * * * *" fires at :00,:01,:02,:03,:04,:05. At 14:37 → 14:05 from previous hour? No — 14:05.
    DateTime result = WorkflowCronEvaluator.previousFireTime('0-5 * * * *', REF);
    System.assertEquals(
      DateTime.newInstanceGmt(2026, 6, 17, 14, 5, 0),
      result,
      'Minute range 0-5: previous from :37 should be :05 same hour'
    );
  }

  // ── Steps on range ────────────────────────────────────────────────────────

  @isTest
  static void testStepOnRange() {
    // "0-30/10 * * * *" fires at :00,:10,:20,:30. At 14:37 → 14:30.
    DateTime result = WorkflowCronEvaluator.previousFireTime('0-30/10 * * * *', REF);
    System.assertEquals(
      DateTime.newInstanceGmt(2026, 6, 17, 14, 30, 0),
      result,
      'Range+step 0-30/10: previous from :37 should be :30'
    );
  }

  // ── Month filter ──────────────────────────────────────────────────────────

  @isTest
  static void testMonthFilter_currentMonth() {
    // "0 12 1 6 *" fires at noon on June 1. Jun 17 → Jun 1 12:00.
    DateTime result = WorkflowCronEvaluator.previousFireTime('0 12 1 6 *', REF);
    System.assertEquals(
      DateTime.newInstanceGmt(2026, 6, 1, 12, 0, 0),
      result,
      'June 1 noon: previous from Jun 17 should be Jun 1'
    );
  }

  @isTest
  static void testMonthFilter_previousYear() {
    // "0 12 1 3 *" fires at noon on March 1. On Jun 17 → this year's Mar 1.
    DateTime result = WorkflowCronEvaluator.previousFireTime('0 12 1 3 *', REF);
    System.assertEquals(
      DateTime.newInstanceGmt(2026, 3, 1, 12, 0, 0),
      result,
      'March 1 noon: previous from Jun 17 should be Mar 1 same year'
    );
  }

  // ── Invalid / never-match ─────────────────────────────────────────────────

  @isTest
  static void testInvalidCron_null() {
    System.assertEquals(null, WorkflowCronEvaluator.previousFireTime(null, REF), 'Null cron → null');
  }

  @isTest
  static void testInvalidCron_empty() {
    System.assertEquals(null, WorkflowCronEvaluator.previousFireTime('', REF), 'Empty cron → null');
  }

  @isTest
  static void testInvalidCron_wrongFieldCount() {
    System.assertEquals(null, WorkflowCronEvaluator.previousFireTime('* * * *', REF), 'Wrong field count → null');
  }

  @isTest
  static void testInvalidCron_outOfRange() {
    // Minute 99 is invalid; should return null.
    System.assertEquals(null, WorkflowCronEvaluator.previousFireTime('99 * * * *', REF), 'Out-of-range minute → null');
  }

  @isTest
  static void testNeverMatchCron_feb31() {
    // Feb 31 never exists: should return null.
    DateTime result = WorkflowCronEvaluator.previousFireTime('0 0 31 2 *', REF);
    System.assertEquals(null, result, 'Feb 31 never fires → null');
  }

  @isTest
  static void testNullNow() {
    System.assertEquals(null, WorkflowCronEvaluator.previousFireTime('* * * * *', null), 'Null now → null');
  }

  // ── Wildcard all ──────────────────────────────────────────────────────────

  @isTest
  static void testWildcardAll_returnsNow() {
    // "* * * * *" fires every minute; previous fire = now truncated to the minute.
    DateTime result = WorkflowCronEvaluator.previousFireTime('* * * * *', REF);
    DateTime expected = DateTime.newInstanceGmt(2026, 6, 17, 14, 37, 0);
    System.assertEquals(expected, result, 'Wildcard-all: previous fire = current minute');
  }
}
