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

  /**
   * @description Resolves an intended local wall-clock time in the given IANA
   * time zone to the corresponding UTC instant, applying deterministic DST
   * gap/overlap policy so a calendar schedule fires exactly once per window.
   *
   * Salesforce exposes no direct zone-offset API, so the offset is derived by
   * formatting a candidate instant in the target zone and measuring the delta
   * between that zone-local rendering and the same instant's GMT rendering. The
   * requested local time is first treated as if it were GMT (the guess), the
   * zone offset at the guess is subtracted, and — because the offset can change
   * across a transition — the correction is re-evaluated at the corrected
   * instant. The corrected candidate is then round-tripped back to the zone's
   * wall clock and compared with the request:
   *
   *  - EXISTS ONCE (normal): the round-trip matches — return that instant.
   *  - FALL-BACK OVERLAP (local time occurs twice): both the pre- and
   *    post-transition offsets yield an instant that renders to the requested
   *    wall clock. The FIRST (earlier UTC, pre-transition) occurrence is chosen
   *    so a calendar day fires exactly once.
   *  - SPRING GAP (local time does not exist): neither offset renders to the
   *    requested wall clock. The gap-boundary instant — the transition instant,
   *    i.e. the first valid instant at or after the requested local time — is
   *    returned ONCE (never skipped, never duplicated).
   *
   * A blank/UTC zone is handled by the caller's exact-GMT path and never reaches
   * here, so this method leaves the pre-existing behavior byte-identical.
   * @param zoneId The IANA time-zone id (e.g. America/New_York).
   * @param year The intended local calendar year.
   * @param month The intended local calendar month (1-12).
   * @param day The intended local calendar day.
   * @param hour The intended local hour (0-23).
   * @param minute The intended local minute (0-59).
   * @return The UTC DateTime for the requested local wall clock under the policy above.
   */
  public static DateTime resolveLocalToUtc(
    String zoneId,
    Integer year,
    Integer month,
    Integer day,
    Integer hour,
    Integer minute
  ) {
    // Treat the requested local fields as if they were GMT: the resolved UTC
    // instant differs from this guess only by the zone offset.
    DateTime guess = DateTime.newInstanceGmt(year, month, day, hour, minute, 0);
    Integer offA = zoneOffsetMinutes(guess, zoneId);
    DateTime candA = guess.addMinutes(-offA);
    Integer offB = zoneOffsetMinutes(candA, zoneId);

    if (offA == offB) {
      // Offset is self-consistent. If it renders back to the request the time
      // exists; resolve any fall-back overlap to the earliest occurrence.
      if (rendersTo(candA, zoneId, year, month, day, hour, minute)) {
        return earliestOverlap(candA, zoneId, year, month, day, hour, minute);
      }
    }

    // Near a transition the two offsets disagree. Build the candidate for each
    // offset and classify by which (if any) renders to the requested wall clock.
    DateTime candB = guess.addMinutes(-offB);
    Boolean aValid = rendersTo(candA, zoneId, year, month, day, hour, minute);
    Boolean bValid = rendersTo(candB, zoneId, year, month, day, hour, minute);

    if (aValid && bValid) {
      // Overlap: both offsets are valid — pick the earliest (first) occurrence.
      return (candA <= candB) ? candA : candB;
    }
    if (aValid) {
      return candA;
    }
    if (bValid) {
      return candB;
    }

    // Spring gap: neither offset renders to the request. Return the transition
    // boundary — the first valid instant at or after the requested local time.
    DateTime lo = (candA <= candB) ? candA : candB;
    DateTime hi = (candA <= candB) ? candB : candA;
    return transitionBoundary(lo, hi, zoneId);
  }

  /**
   * @description Zone offset in minutes at the given instant: the signed delta
   * between the instant's wall clock in the target zone and its GMT wall clock
   * (e.g. -300 for US Eastern Standard Time). Derived by parsing the zone-local
   * rendering back as GMT, since Salesforce has no direct offset API.
   * @param instant The instant whose zone offset is measured.
   * @param zoneId The IANA time-zone id.
   * @return The offset in minutes (zone wall clock minus GMT wall clock).
   */
  private static Integer zoneOffsetMinutes(DateTime instant, String zoneId) {
    DateTime localAsGmt = DateTime.valueOfGmt(
      instant.format('yyyy-MM-dd HH:mm:ss', zoneId)
    );
    return (Integer) ((localAsGmt.getTime() - instant.getTime()) / 60000L);
  }

  /**
   * @description True when the candidate instant renders to exactly the requested
   * local wall clock in the target zone (minute granularity).
   * @param candidate The UTC instant to test.
   * @param zoneId The IANA time-zone id.
   * @param year The requested local year.
   * @param month The requested local month.
   * @param day The requested local day.
   * @param hour The requested local hour.
   * @param minute The requested local minute.
   * @return True if the candidate's zone wall clock equals the request.
   */
  private static Boolean rendersTo(
    DateTime candidate,
    String zoneId,
    Integer year,
    Integer month,
    Integer day,
    Integer hour,
    Integer minute
  ) {
    String want = DateTime.newInstanceGmt(year, month, day, hour, minute, 0)
      .formatGmt('yyyy-MM-dd HH:mm');
    return candidate.format('yyyy-MM-dd HH:mm', zoneId) == want;
  }

  /**
   * @description For a valid resolved instant, returns the earliest instant that
   * still renders to the requested local wall clock, so a fall-back overlap
   * (the same local time occurring twice, one DST hour apart) fires on its FIRST
   * occurrence. Assumes the standard one-hour DST shift used by the supported
   * zones; the shift is only applied when the earlier instant actually renders
   * to the request, so a non-overlapping time is returned unchanged.
   * @param candidate A UTC instant already known to render to the request.
   * @param zoneId The IANA time-zone id.
   * @param year The requested local year.
   * @param month The requested local month.
   * @param day The requested local day.
   * @param hour The requested local hour.
   * @param minute The requested local minute.
   * @return The earliest UTC instant rendering to the requested wall clock.
   */
  private static DateTime earliestOverlap(
    DateTime candidate,
    String zoneId,
    Integer year,
    Integer month,
    Integer day,
    Integer hour,
    Integer minute
  ) {
    DateTime earlier = candidate.addHours(-1);
    if (rendersTo(earlier, zoneId, year, month, day, hour, minute)) {
      return earlier;
    }
    return candidate;
  }

  /**
   * @description Binary-searches for the DST transition instant in (lo, hi]:
   * the first minute whose zone offset differs from the offset at lo. Used to
   * return the gap boundary when a requested local time does not exist.
   * @param lo An instant on the pre-transition side (offset == offset(lo)).
   * @param hi An instant on the post-transition side (offset != offset(lo)).
   * @param zoneId The IANA time-zone id.
   * @return The minute-aligned UTC instant at which the offset changes.
   */
  private static DateTime transitionBoundary(
    DateTime lo,
    DateTime hi,
    String zoneId
  ) {
    Integer loOff = zoneOffsetMinutes(lo, zoneId);
    DateTime low = lo;
    DateTime high = hi;
    while (high.getTime() - low.getTime() > 60000L) {
      Long midMs = low.getTime() + (high.getTime() - low.getTime()) / 2;
      DateTime mid = truncateToMinute(DateTime.newInstance(midMs));
      if (mid.getTime() <= low.getTime()) {
        mid = DateTime.newInstance(low.getTime() + 60000L);
      }
      if (zoneOffsetMinutes(mid, zoneId) == loOff) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return high;
  }
}
