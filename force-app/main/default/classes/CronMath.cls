/**
 * Stateless numeric and calendar primitives used by the cron fire-time walk:
 * nearest-value searches over a cron field's value set, and UTC calendar-boundary
 * navigation (minute truncation, midnight, month-start construction, day-of-week
 * conversion). Extracted from WorkflowCronEvaluator so the evaluator can focus on
 * the direction-parameterised walk while each class stays under the aggregate
 * complexity threshold.
 *
 * All DateTime math is in UTC (Salesforce DateTime is always UTC internally).
 */
public inherited sharing class CronMath {
  // Returns the largest value in the set that is <= maxVal, or -1 if none.
  public static Integer latestBelow(Set<Integer> vals, Integer maxVal) {
    Integer best = -1;
    for (Integer v : vals) {
      if (v <= maxVal && v > best) {
        best = v;
      }
    }
    return best;
  }

  // Returns the smallest value in the set that is >= minVal, or -1 if none.
  public static Integer earliestAbove(Set<Integer> vals, Integer minVal) {
    Integer best = -1;
    for (Integer v : vals) {
      if (v >= minVal && (best == -1 || v < best)) {
        best = v;
      }
    }
    return best;
  }

  // Truncates a DateTime to the start of its current minute (UTC).
  public static DateTime truncateToMinute(DateTime dt) {
    return DateTime.newInstanceGmt(
      dt.yearGmt(),
      dt.monthGmt(),
      dt.dayGmt(),
      dt.hourGmt(),
      dt.minuteGmt(),
      0
    );
  }

  // Midnight (00:00:00 UTC) of the given DateTime's calendar day.
  public static DateTime midnight(DateTime dt) {
    return DateTime.newInstanceGmt(
      dt.yearGmt(),
      dt.monthGmt(),
      dt.dayGmt(),
      0,
      0,
      0
    );
  }

  // formatGmt('u') is ISO-8601 day-of-week: Mon=1 ... Sun=7. Math.mod(u, 7)
  // maps that to cron convention 0=Sun ... 6=Sat (Sun: 7->0, Mon..Sat: 1..6).
  public static Integer dowOf(DateTime candidate) {
    return Math.mod(Integer.valueOf(candidate.formatGmt('u')), 7);
  }

  // Returns the DateTime for the 1st of the given month at 00:00:00 UTC.
  public static DateTime firstOfMonth(Integer year, Integer month) {
    return DateTime.newInstanceGmt(year, month, 1, 0, 0, 0);
  }

  // Returns the 1st of the month after the given year/month at 00:00:00 UTC.
  public static DateTime firstOfNextMonth(Integer year, Integer month) {
    Integer nextYear = (month == 12) ? year + 1 : year;
    Integer nextMonth = (month == 12) ? 1 : month + 1;
    return DateTime.newInstanceGmt(nextYear, nextMonth, 1, 0, 0, 0);
  }
}
