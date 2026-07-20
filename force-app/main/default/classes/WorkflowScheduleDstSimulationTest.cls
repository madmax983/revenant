/**
 * Year-long DST simulation for the zone-aware cron evaluator. Iterates a daily
 * "0 2 * * *" schedule across a full calendar year — including one spring-forward
 * and one fall-back transition — asserting no missed and no duplicate fire, that
 * each resolved instant lands on the intended local wall clock (with the single
 * documented spring-gap exception), and that a blank-zone run stays byte-identical
 * to the pre-existing exact-GMT path.
 *
 * Each scenario is its own test method so it gets a fresh governor allowance for
 * the 365-iteration walk.
 */
@IsTest
public class WorkflowScheduleDstSimulationTest {
  private static final String NIGHTLY = '0 2 * * *';
  private static final String NY = 'America/New_York';
  // Tokyo observes no DST, so every day's 02:00 exists exactly once.
  private static final String TOKYO = 'Asia/Tokyo';
  private static final Integer DAYS = 365; // 2026 is not a leap year.

  // Walks DAYS consecutive daily fires forward from `start`, interpreting the
  // cron in the given zone. Each step advances one minute past the prior fire so
  // the inclusive nextFireTime returns the following window.
  private static List<DateTime> walkYear(
    String cron,
    DateTime start,
    String zoneId
  ) {
    List<DateTime> fires = new List<DateTime>();
    DateTime cursor = start;
    for (Integer i = 0; i < DAYS; i++) {
      DateTime fire = WorkflowCronEvaluator.nextFireTime(cron, cursor, zoneId);
      System.assertNotEquals(
        null,
        fire,
        'Every day within the year must yield a fire'
      );
      fires.add(fire);
      cursor = fire.addMinutes(1);
    }
    return fires;
  }

  // Asserts the fires are strictly increasing (no duplicate, no regression) and
  // all distinct.
  private static void assertStrictlyIncreasing(List<DateTime> fires) {
    Set<DateTime> seen = new Set<DateTime>();
    for (Integer i = 0; i < fires.size(); i++) {
      System.assertEquals(
        false,
        seen.contains(fires[i]),
        'No fire instant may repeat: ' + fires[i]
      );
      seen.add(fires[i]);
      if (i > 0) {
        System.assert(
          fires[i] > fires[i - 1],
          'Fires must be strictly increasing: ' +
            fires[i - 1] +
            ' then ' +
            fires[i]
        );
      }
    }
    System.assertEquals(DAYS, seen.size(), 'Exactly one fire per day');
  }

  @IsTest
  static void testNewYorkYearNoMissNoDuplicate() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Start just before 2026-01-01 so the first fire is Jan 1 02:00 local.
      DateTime start = DateTime.newInstanceGmt(2026, 1, 1, 0, 0, 0);

      Test.startTest();
      List<DateTime> fires = walkYear(NIGHTLY, start, NY);
      Test.stopTest();

      assertStrictlyIncreasing(fires);

      // Every fire lands at 02:00 New York wall clock EXCEPT the spring-forward
      // day (2026-03-08), where 02:00 does not exist and the schedule fires once
      // at the gap boundary 03:00. Fall-back (2026-11-01) still lands at 02:00.
      Integer at0200 = 0;
      Integer at0300 = 0;
      for (DateTime fire : fires) {
        String hhmm = fire.format('HH:mm', NY);
        if (hhmm == '02:00') {
          at0200++;
        } else if (hhmm == '03:00') {
          at0300++;
        } else {
          System.assert(
            false,
            'Unexpected local wall clock ' +
              hhmm +
              ' for ' +
              fire.format('yyyy-MM-dd HH:mm', NY)
          );
        }
      }
      System.assertEquals(
        DAYS - 1,
        at0200,
        '364 days should land exactly at 02:00 New York'
      );
      System.assertEquals(
        1,
        at0300,
        'The single spring-gap day should land at the 03:00 boundary'
      );
    }
  }

  @IsTest
  static void testNonDstZoneTokyoAllLandAtLocalTwo() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      DateTime start = DateTime.newInstanceGmt(2026, 1, 1, 0, 0, 0);

      Test.startTest();
      List<DateTime> fires = walkYear(NIGHTLY, start, TOKYO);
      Test.stopTest();

      assertStrictlyIncreasing(fires);
      for (DateTime fire : fires) {
        System.assertEquals(
          '02:00',
          fire.format('HH:mm', TOKYO),
          'A non-DST zone lands at 02:00 local every day: ' +
          fire.format('yyyy-MM-dd HH:mm', TOKYO)
        );
      }
    }
  }

  @IsTest
  static void testBlankZoneMatchesGoldenUtcBaseline() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      DateTime start = DateTime.newInstanceGmt(2026, 1, 1, 0, 0, 0);

      Test.startTest();
      // Golden baseline: the pre-existing no-arg (exact-GMT) walk.
      List<DateTime> baseline = new List<DateTime>();
      DateTime cursor = start;
      for (Integer i = 0; i < DAYS; i++) {
        DateTime fire = WorkflowCronEvaluator.nextFireTime(NIGHTLY, cursor);
        baseline.add(fire);
        cursor = fire.addMinutes(1);
      }
      // Blank-zone and null-zone walks must reproduce it byte-for-byte.
      List<DateTime> blankZone = walkYear(NIGHTLY, start, '');
      List<DateTime> nullZone = walkYear(NIGHTLY, start, null);
      Test.stopTest();

      System.assertEquals(DAYS, baseline.size(), 'Baseline covers the year');
      for (Integer i = 0; i < DAYS; i++) {
        System.assertEquals(
          baseline[i],
          blankZone[i],
          'Blank-zone fire must equal the UTC baseline at day ' + i
        );
        System.assertEquals(
          baseline[i],
          nullZone[i],
          'Null-zone fire must equal the UTC baseline at day ' + i
        );
        // The baseline is pure UTC: every fire is exactly 02:00Z.
        System.assertEquals(
          '02:00',
          baseline[i].formatGmt('HH:mm'),
          'UTC baseline fires at 02:00Z every day'
        );
      }
    }
  }
}
