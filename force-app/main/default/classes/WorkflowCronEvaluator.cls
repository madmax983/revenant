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
 * Field parsing is delegated to CronFieldParser; nearest-value searches and UTC
 * calendar-boundary navigation are delegated to CronMath. The backward
 * ("previous") and forward ("next") searches share a single
 * direction-parameterised walk.
 */
public inherited sharing class WorkflowCronEvaluator {
  // Maximum days to look back/ahead before giving up (prevents governor timeout).
  private static final Integer MAX_LOOKBACK_DAYS = 1461; // ~4 years

  /**
   * @description Computes the most-recent fire instant at or before `now` for the given
   * cron expression.
   * @param cronExpr The 5-field cron expression to evaluate.
   * @param now The UTC reference instant to search backwards from.
   * @return The matching fire time, or null if the expression is invalid or no match falls within the lookback window.
   */
  public static DateTime previousFireTime(String cronExpr, DateTime now) {
    return fireTime(cronExpr, now, false);
  }

  /**
   * @description Computes the most-recent fire instant at or before `now`, interpreting the
   * cron in the given IANA time zone. A blank/null zone means UTC and takes the exact-GMT
   * path with zero behavioral change; a non-blank zone walks the calendar in the zone's
   * wall clock and resolves each matched local time to a UTC instant (DST gap/overlap
   * policy per CronMath.resolveLocalToUtc).
   * @param cronExpr The 5-field cron expression to evaluate.
   * @param now The UTC reference instant to search backwards from.
   * @param zoneId The IANA time-zone id the cron is interpreted in, or blank/null for UTC.
   * @return The matching fire time, or null if the expression is invalid or no match falls within the lookback window.
   */
  public static DateTime previousFireTime(
    String cronExpr,
    DateTime now,
    String zoneId
  ) {
    return WorkflowCronZones.previous(cronExpr, now, zoneId);
  }

  /**
   * @description Computes the next fire instant at or after `now`, useful for "next run"
   * previews in the UI.
   * @param cronExpr The 5-field cron expression to evaluate.
   * @param now The UTC reference instant to search forwards from.
   * @return The matching fire time, or null if the expression is invalid or no match falls within the lookahead window.
   */
  public static DateTime nextFireTime(String cronExpr, DateTime now) {
    return fireTime(cronExpr, now, true);
  }

  /**
   * @description Computes the next fire instant at or after `now`, interpreting the cron in
   * the given IANA time zone. A blank/null zone means UTC and takes the exact-GMT path with
   * zero behavioral change; a non-blank zone walks the calendar in the zone's wall clock and
   * resolves each matched local time to a UTC instant (DST gap/overlap policy per
   * CronMath.resolveLocalToUtc).
   * @param cronExpr The 5-field cron expression to evaluate.
   * @param now The UTC reference instant to search forwards from.
   * @param zoneId The IANA time-zone id the cron is interpreted in, or blank/null for UTC.
   * @return The matching fire time, or null if the expression is invalid or no match falls within the lookahead window.
   */
  public static DateTime nextFireTime(
    String cronExpr,
    DateTime now,
    String zoneId
  ) {
    return WorkflowCronZones.next(cronExpr, now, zoneId);
  }

  /**
   * @description Cheap validity check for editor input: true when the expression has
   * exactly 5 fields that all parse to a non-empty value set.
   * @param cronExpr The candidate cron expression to validate.
   * @return True if the expression parses to five valid fields, otherwise false.
   */
  public static Boolean isValidCron(String cronExpr) {
    return CronFieldParser.parse(cronExpr) != null;
  }

  /**
   * @description Whether a schedule time zone is usable (blank/null means UTC and is always
   * valid). Delegates to WorkflowCronZones, which owns the supported-zone allow-list.
   * @param zoneId The candidate IANA time-zone id, or blank/null for UTC.
   * @return True if the zone is blank (UTC) or a supported IANA id, otherwise false.
   */
  public static Boolean isValidZone(String zoneId) {
    return WorkflowCronZones.isZoneSupported(zoneId);
  }

  /**
   * @description The supported IANA time-zone ids offered by the editor's time-zone picker.
   * Delegates to WorkflowCronZones.
   * @return The sorted list of supported IANA time-zone ids.
   */
  public static List<String> supportedZones() {
    return WorkflowCronZones.listZones();
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

    DateTime candidate = CronMath.truncateToMinute(now);

    for (Integer d = 0; d <= MAX_LOOKBACK_DAYS; d++) {
      if (!f.months.contains(candidate.monthGmt())) {
        candidate = adjacentMonthStart(candidate, forward);
        continue;
      }

      if (!dayMatches(f, candidate.dayGmt(), CronMath.dowOf(candidate))) {
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
      ? CronMath.earliestAbove(f.hours, curHour)
      : CronMath.latestBelow(f.hours, curHour);
    if (matchHour == -1) {
      return null;
    }

    Integer startMinute = (matchHour == curHour)
      ? candidate.minuteGmt()
      : (forward ? 0 : 59);
    Integer matchMinute = forward
      ? CronMath.earliestAbove(f.minutes, startMinute)
      : CronMath.latestBelow(f.minutes, startMinute);

    DateTime dayStart = CronMath.midnight(candidate);
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
    Integer prevHour = CronMath.latestBelow(f.hours, matchHour - 1);
    if (prevHour == -1) {
      return null;
    }
    Integer prevMin = CronMath.latestBelow(f.minutes, 59);
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
    Integer nextHour = CronMath.earliestAbove(f.hours, matchHour + 1);
    if (nextHour == -1) {
      return null;
    }
    Integer firstMin = CronMath.earliestAbove(f.minutes, 0);
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
      ? CronMath.firstOfNextMonth(year, month)
      : CronMath.firstOfMonth(year, month).addSeconds(-60);
  }

  // Adjacent day boundary: end of the previous day (backwards, 23:59) or start
  // of the next day (forwards, 00:00).
  private static DateTime adjacentDayStart(
    DateTime candidate,
    Boolean forward
  ) {
    DateTime dayStart = CronMath.midnight(candidate);
    return forward ? dayStart.addDays(1) : dayStart.addSeconds(-60);
  }
}
