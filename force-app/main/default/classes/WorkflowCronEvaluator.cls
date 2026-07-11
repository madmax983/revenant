/**
 * Evaluates a 5-field cron expression (minute hour dom month dow) to find the
 * most-recent fire instant at or before a given DateTime.
 *
 * Supported syntax per field:
 *   *          — every value
 *   a          — exact value
 *   a,b,c      — list
 *   a-b        — range (inclusive)
 *   *\/n         — step across full range
 *   a-b/n      — step across range
 *
 * Day-of-week: 0 = Sunday … 6 = Saturday.
 * Month: 1–12.
 * All evaluation is in UTC (Salesforce DateTime is always UTC internally).
 *
 * When both dom and dow are restricted (not *) they are OR-ed, matching
 * standard cron semantics.
 *
 * Returns null if the expression is invalid, the reference DateTime is null,
 * or no matching instant can be found within a ~4-year window.
 *
 * Field parsing is delegated to CronFieldParser. The backward ("previous") and
 * forward ("next") searches share a single direction-parameterised walk.
 */
public inherited sharing class WorkflowCronEvaluator {
  // Maximum days to look back/ahead before giving up (prevents governor timeout).
  private static final Integer MAX_LOOKBACK_DAYS = 1461; // ~4 years

  /**
   * Most-recent fire instant at or before `now`, or null if invalid / no match
   * within the lookback window.
   */
  public static DateTime previousFireTime(String cronExpr, DateTime now) {
    return fireTime(cronExpr, now, false);
  }

  /**
   * Next fire instant at or after `now`, or null if invalid / no match within
   * the lookahead window. Useful for "next run" previews in the UI.
   */
  public static DateTime nextFireTime(String cronExpr, DateTime now) {
    return fireTime(cronExpr, now, true);
  }

  /**
   * Returns true when the expression has exactly 5 fields that all parse to a
   * non-empty value set. Cheap validity check for editor input.
   */
  public static Boolean isValidCron(String cronExpr) {
    return CronFieldParser.parse(cronExpr) != null;
  }

  // Walks day by day (backwards when forward=false, forwards when forward=true)
  // from `now` looking for the first matching minute.
  private static DateTime fireTime(
    String cronExpr,
    DateTime now,
    Boolean forward
  ) {
    if (now == null) {
      return null;
    }
    CronFieldParser.Fields f = CronFieldParser.parse(cronExpr);
    if (f == null) {
      return null;
    }

    DateTime candidate = truncateToMinute(now);

    for (Integer d = 0; d <= MAX_LOOKBACK_DAYS; d++) {
      if (!f.months.contains(candidate.monthGmt())) {
        candidate = adjacentMonthStart(candidate, forward);
        continue;
      }

      if (!dayMatches(f, candidate.dayGmt(), dowOf(candidate))) {
        candidate = adjacentDayStart(candidate, forward);
        continue;
      }

      DateTime hit = matchInDay(f, candidate, forward);
      if (hit != null) {
        return hit;
      }
      candidate = adjacentDayStart(candidate, forward);
    }

    return null; // No match within the window.
  }

  // Finds the matching instant on candidate's own day, or null when the day has
  // no match and the walk must move to the adjacent day. Because non-today
  // candidates are pre-positioned at the day boundary (23:59 backwards, 00:00
  // forwards), candidate's own hour/minute double as the per-day search start.
  private static DateTime matchInDay(
    CronFieldParser.Fields f,
    DateTime candidate,
    Boolean forward
  ) {
    Integer curHour = candidate.hourGmt();
    Integer matchHour = forward
      ? earliestAbove(f.hours, curHour)
      : latestBelow(f.hours, curHour);
    if (matchHour == -1) {
      return null;
    }

    Integer startMinute = (matchHour == curHour)
      ? candidate.minuteGmt()
      : (forward ? 0 : 59);
    Integer matchMinute = forward
      ? earliestAbove(f.minutes, startMinute)
      : latestBelow(f.minutes, startMinute);

    DateTime dayStart = midnight(candidate);
    if (matchMinute != -1) {
      return dayStart.addHours(matchHour).addMinutes(matchMinute);
    }

    // No minute left in matchHour; fall back to an adjacent allowed hour today.
    return forward
      ? resolveLaterSameDay(f, dayStart, matchHour)
      : resolveEarlierSameDay(f, dayStart, matchHour);
  }

  // Latest fire instant in an earlier hour of the same day, or null if none.
  private static DateTime resolveEarlierSameDay(
    CronFieldParser.Fields f,
    DateTime dayStart,
    Integer matchHour
  ) {
    if (matchHour == 0) {
      return null;
    }
    Integer prevHour = latestBelow(f.hours, matchHour - 1);
    if (prevHour == -1) {
      return null;
    }
    Integer prevMin = latestBelow(f.minutes, 59);
    if (prevMin == -1) {
      return null;
    }
    return dayStart.addHours(prevHour).addMinutes(prevMin);
  }

  // Earliest fire instant in a later hour of the same day, or null if none.
  private static DateTime resolveLaterSameDay(
    CronFieldParser.Fields f,
    DateTime dayStart,
    Integer matchHour
  ) {
    Integer nextHour = earliestAbove(f.hours, matchHour + 1);
    if (nextHour == -1) {
      return null;
    }
    Integer firstMin = earliestAbove(f.minutes, 0);
    if (firstMin == -1) {
      return null;
    }
    return dayStart.addHours(nextHour).addMinutes(firstMin);
  }

  // Applies cron dom/dow matching semantics for a single calendar day.
  private static Boolean dayMatches(
    CronFieldParser.Fields f,
    Integer cDay,
    Integer cDow
  ) {
    Boolean domMatch = f.doms.contains(cDay);
    Boolean dowMatch = f.dows.contains(cDow);
    if (f.domRestricted && f.dowRestricted) {
      return domMatch || dowMatch;
    }
    if (f.domRestricted) {
      return domMatch;
    }
    if (f.dowRestricted) {
      return dowMatch;
    }
    return true;
  }

  // Day boundary the walk jumps to when the current month is not allowed.
  private static DateTime adjacentMonthStart(
    DateTime candidate,
    Boolean forward
  ) {
    Integer year = candidate.yearGmt();
    Integer month = candidate.monthGmt();
    return forward
      ? firstOfNextMonth(year, month)
      : firstOfMonth(year, month).addSeconds(-60);
  }

  // Adjacent day boundary: end of the previous day (backwards, 23:59) or start
  // of the next day (forwards, 00:00).
  private static DateTime adjacentDayStart(
    DateTime candidate,
    Boolean forward
  ) {
    DateTime dayStart = midnight(candidate);
    return forward ? dayStart.addDays(1) : dayStart.addSeconds(-60);
  }

  // Truncates a DateTime to the start of its current minute (UTC).
  private static DateTime truncateToMinute(DateTime dt) {
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
  private static DateTime midnight(DateTime dt) {
    return DateTime.newInstanceGmt(
      dt.yearGmt(),
      dt.monthGmt(),
      dt.dayGmt(),
      0,
      0,
      0
    );
  }

  // formatGmt('u') is ISO-8601 day-of-week: Mon=1 … Sun=7. Math.mod(u, 7)
  // maps that to cron convention 0=Sun … 6=Sat (Sun: 7→0, Mon..Sat: 1..6).
  private static Integer dowOf(DateTime candidate) {
    return Math.mod(Integer.valueOf(candidate.formatGmt('u')), 7);
  }

  // Returns the largest value in the set that is ≤ maxVal, or -1 if none.
  private static Integer latestBelow(Set<Integer> vals, Integer maxVal) {
    Integer best = -1;
    for (Integer v : vals) {
      if (v <= maxVal && v > best) {
        best = v;
      }
    }
    return best;
  }

  // Returns the smallest value in the set that is ≥ minVal, or -1 if none.
  private static Integer earliestAbove(Set<Integer> vals, Integer minVal) {
    Integer best = -1;
    for (Integer v : vals) {
      if (v >= minVal && (best == -1 || v < best)) {
        best = v;
      }
    }
    return best;
  }

  // Returns the DateTime for the 1st of the given month at 00:00:00 UTC.
  private static DateTime firstOfMonth(Integer year, Integer month) {
    return DateTime.newInstanceGmt(year, month, 1, 0, 0, 0);
  }

  // Returns the 1st of the month after the given year/month at 00:00:00 UTC.
  private static DateTime firstOfNextMonth(Integer year, Integer month) {
    Integer nextYear = (month == 12) ? year + 1 : year;
    Integer nextMonth = (month == 12) ? 1 : month + 1;
    return DateTime.newInstanceGmt(nextYear, nextMonth, 1, 0, 0, 0);
  }
}
