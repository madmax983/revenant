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
  /**
   * @description Returns the largest value in the cron-field set at or below the
   * given ceiling, used when walking backwards to the previous fire time.
   * @param vals The candidate values for a cron field (e.g. allowed minutes).
   * @param maxVal The inclusive upper bound to search at or below.
   * @return The greatest value <= maxVal, or -1 if the set has no such value.
   */
  public static Integer latestBelow(Set<Integer> vals, Integer maxVal) {
    Integer best = -1;
    for (Integer v : vals) {
      if (v <= maxVal && v > best) {
        best = v;
      }
    }
    return best;
  }

  /**
   * @description Returns the smallest value in the cron-field set at or above the
   * given floor, used when walking forwards to the next fire time.
   * @param vals The candidate values for a cron field (e.g. allowed minutes).
   * @param minVal The inclusive lower bound to search at or above.
   * @return The least value >= minVal, or -1 if the set has no such value.
   */
  public static Integer earliestAbove(Set<Integer> vals, Integer minVal) {
    Integer best = -1;
    for (Integer v : vals) {
      if (v >= minVal && (best == -1 || v < best)) {
        best = v;
      }
    }
    return best;
  }

  /**
   * @description Truncates a DateTime to the start of its current minute in UTC,
   * zeroing the seconds so cron comparisons align on minute boundaries.
   * @param dt The DateTime to truncate.
   * @return A UTC DateTime at the start of dt's minute.
   */
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

  /**
   * @description Returns midnight (00:00:00 UTC) of the calendar day containing
   * the given DateTime, used when the walk crosses to a new day.
   * @param dt The DateTime whose calendar day is taken.
   * @return A UTC DateTime at the start of dt's day.
   */
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

  /**
   * @description Returns the cron day-of-week (0=Sun ... 6=Sat) for the given
   * DateTime, converting from ISO-8601 (Mon=1 ... Sun=7) via Math.mod.
   * @param candidate The DateTime whose UTC day-of-week is computed.
   * @return The day-of-week in cron convention: 0=Sunday through 6=Saturday.
   */
  public static Integer dowOf(DateTime candidate) {
    return Math.mod(Integer.valueOf(candidate.formatGmt('u')), 7);
  }

  /**
   * @description Constructs the 1st of the given month at 00:00:00 UTC, the entry
   * point when the forward walk advances into a new month.
   * @param year The calendar year.
   * @param month The calendar month (1-12).
   * @return A UTC DateTime at midnight on the first day of that month.
   */
  public static DateTime firstOfMonth(Integer year, Integer month) {
    return DateTime.newInstanceGmt(year, month, 1, 0, 0, 0);
  }

  /**
   * @description Constructs the 1st of the month following the given year/month at
   * 00:00:00 UTC, rolling the year over when the month is December.
   * @param year The calendar year of the starting month.
   * @param month The calendar month (1-12) to advance past.
   * @return A UTC DateTime at midnight on the first day of the next month.
   */
  public static DateTime firstOfNextMonth(Integer year, Integer month) {
    Integer nextYear = (month == 12) ? year + 1 : year;
    Integer nextMonth = (month == 12) ? 1 : month + 1;
    return DateTime.newInstanceGmt(nextYear, nextMonth, 1, 0, 0, 0);
  }
}
