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
 * or no matching instant can be found within a ~4-year lookback window.
 */
public inherited sharing class WorkflowCronEvaluator {
  // Maximum days to look back before giving up (prevents governor timeout).
  private static final Integer MAX_LOOKBACK_DAYS = 1461; // ~4 years

  public static DateTime previousFireTime(String cronExpr, DateTime now) {
    if (now == null || String.isBlank(cronExpr)) {
      return null;
    }

    List<String> fields = cronExpr.trim().split('\\s+');
    if (fields.size() != 5) {
      return null;
    }

    Set<Integer> minutes = parseField(fields[0], 0, 59);
    Set<Integer> hours = parseField(fields[1], 0, 23);
    Set<Integer> doms = parseField(fields[2], 1, 31);
    Set<Integer> months = parseField(fields[3], 1, 12);
    Set<Integer> dows = parseField(fields[4], 0, 6);

    if (
      minutes == null ||
      hours == null ||
      doms == null ||
      months == null ||
      dows == null
    ) {
      return null;
    }

    Boolean domRestricted = !fields[2].equals('*');
    Boolean dowRestricted = !fields[4].equals('*');

    // Walk backwards day by day from now.
    // Truncate now to the current minute (seconds are irrelevant).
    Integer nowMinute = now.minuteGmt();
    Integer nowHour = now.hourGmt();
    Integer nowDay = now.dayGmt();
    Integer nowMonth = now.monthGmt();
    Integer nowYear = now.yearGmt();

    // Start candidate = now truncated to minute.
    DateTime candidate = DateTime.newInstanceGmt(nowYear, nowMonth, nowDay, nowHour, nowMinute, 0);

    for (Integer d = 0; d <= MAX_LOOKBACK_DAYS; d++) {
      Integer cDay = candidate.dayGmt();
      Integer cMonth = candidate.monthGmt();
      Integer cYear = candidate.yearGmt();
      // Apex dayOfWeekGmt(): Sun=1 … Sat=7. Subtract 1 to get 0=Sun … 6=Sat (cron convention).
      Integer cDow = candidate.dayOfWeekGmt() - 1;

      // Check month.
      if (!months.contains(cMonth)) {
        // Skip to last day of previous month.
        candidate = firstOfMonth(cYear, cMonth).addSeconds(-60);
        continue;
      }

      // Check day (dom OR dow when both restricted, dom-only when dom restricted,
      // dow-only when dow restricted, either when neither restricted).
      Boolean domMatch = doms.contains(cDay);
      Boolean dowMatch = dows.contains(cDow);
      Boolean dayMatch;
      if (domRestricted && dowRestricted) {
        dayMatch = domMatch || dowMatch;
      } else if (domRestricted) {
        dayMatch = domMatch;
      } else if (dowRestricted) {
        dayMatch = dowMatch;
      } else {
        dayMatch = true;
      }

      if (!dayMatch) {
        // Move to end of previous day.
        candidate = DateTime.newInstanceGmt(cYear, cMonth, cDay, 0, 0, 0).addSeconds(-60);
        continue;
      }

      // Day matches. Find the latest matching hour ≤ candidate's current hour.
      Integer startHour = (d == 0) ? candidate.hourGmt() : 23;
      Integer matchHour = latestBelow(hours, startHour);
      if (matchHour == -1) {
        // No valid hour today; go to previous day.
        candidate = DateTime.newInstanceGmt(cYear, cMonth, cDay, 0, 0, 0).addSeconds(-60);
        continue;
      }

      // Find the latest matching minute ≤ candidate's current minute (if same
      // hour as now) or ≤ 59 (for earlier hours).
      Integer startMinute = (d == 0 && matchHour == candidate.hourGmt())
        ? candidate.minuteGmt()
        : 59;
      Integer matchMinute = latestBelow(minutes, startMinute);
      if (matchMinute == -1) {
        // No valid minute in this hour; try the hour before.
        if (matchHour == 0) {
          candidate = DateTime.newInstanceGmt(cYear, cMonth, cDay, 0, 0, 0).addSeconds(-60);
        } else {
          // We need to look at hours before matchHour on the same day.
          // Re-derive from the next-lower allowed hour.
          Integer prevHour = latestBelow(hours, matchHour - 1);
          if (prevHour == -1) {
            candidate = DateTime.newInstanceGmt(cYear, cMonth, cDay, 0, 0, 0).addSeconds(-60);
          } else {
            Integer prevMin = latestBelow(minutes, 59);
            if (prevMin == -1) {
              candidate = DateTime.newInstanceGmt(cYear, cMonth, cDay, 0, 0, 0).addSeconds(-60);
            } else {
              return DateTime.newInstanceGmt(cYear, cMonth, cDay, prevHour, prevMin, 0);
            }
          }
        }
        continue;
      }

      return DateTime.newInstanceGmt(cYear, cMonth, cDay, matchHour, matchMinute, 0);
    }

    return null; // No match within lookback window.
  }

  /**
   * Returns the next fire instant at or after `now`, or null if invalid / no
   * match within the lookahead window. Mirror of previousFireTime, walking
   * forward. Useful for "next run" previews in the UI.
   */
  public static DateTime nextFireTime(String cronExpr, DateTime now) {
    if (now == null || String.isBlank(cronExpr)) {
      return null;
    }

    List<String> fields = cronExpr.trim().split('\\s+');
    if (fields.size() != 5) {
      return null;
    }

    Set<Integer> minutes = parseField(fields[0], 0, 59);
    Set<Integer> hours = parseField(fields[1], 0, 23);
    Set<Integer> doms = parseField(fields[2], 1, 31);
    Set<Integer> months = parseField(fields[3], 1, 12);
    Set<Integer> dows = parseField(fields[4], 0, 6);

    if (
      minutes == null ||
      hours == null ||
      doms == null ||
      months == null ||
      dows == null
    ) {
      return null;
    }

    Boolean domRestricted = !fields[2].equals('*');
    Boolean dowRestricted = !fields[4].equals('*');

    DateTime candidate = DateTime.newInstanceGmt(
      now.yearGmt(),
      now.monthGmt(),
      now.dayGmt(),
      now.hourGmt(),
      now.minuteGmt(),
      0
    );

    for (Integer d = 0; d <= MAX_LOOKBACK_DAYS; d++) {
      Integer cDay = candidate.dayGmt();
      Integer cMonth = candidate.monthGmt();
      Integer cYear = candidate.yearGmt();
      Integer cDow = candidate.dayOfWeekGmt() - 1; // 0=Sun … 6=Sat

      if (!months.contains(cMonth)) {
        candidate = firstOfNextMonth(cYear, cMonth);
        continue;
      }

      Boolean domMatch = doms.contains(cDay);
      Boolean dowMatch = dows.contains(cDow);
      Boolean dayMatch;
      if (domRestricted && dowRestricted) {
        dayMatch = domMatch || dowMatch;
      } else if (domRestricted) {
        dayMatch = domMatch;
      } else if (dowRestricted) {
        dayMatch = dowMatch;
      } else {
        dayMatch = true;
      }

      if (!dayMatch) {
        candidate = DateTime.newInstanceGmt(cYear, cMonth, cDay, 0, 0, 0).addDays(1);
        continue;
      }

      Integer startHour = (d == 0) ? candidate.hourGmt() : 0;
      Integer matchHour = earliestAbove(hours, startHour);
      if (matchHour == -1) {
        candidate = DateTime.newInstanceGmt(cYear, cMonth, cDay, 0, 0, 0).addDays(1);
        continue;
      }

      Integer startMinute = (d == 0 && matchHour == candidate.hourGmt())
        ? candidate.minuteGmt()
        : 0;
      Integer matchMinute = earliestAbove(minutes, startMinute);
      if (matchMinute == -1) {
        // No minute left in this hour; advance to the next allowed hour today.
        Integer nextHour = earliestAbove(hours, matchHour + 1);
        if (nextHour == -1) {
          candidate = DateTime.newInstanceGmt(cYear, cMonth, cDay, 0, 0, 0).addDays(1);
        } else {
          Integer firstMin = earliestAbove(minutes, 0);
          if (firstMin == -1) {
            candidate = DateTime.newInstanceGmt(cYear, cMonth, cDay, 0, 0, 0).addDays(1);
          } else {
            return DateTime.newInstanceGmt(cYear, cMonth, cDay, nextHour, firstMin, 0);
          }
        }
        continue;
      }

      return DateTime.newInstanceGmt(cYear, cMonth, cDay, matchHour, matchMinute, 0);
    }

    return null; // No match within lookahead window.
  }

  /**
   * Returns true when the expression has exactly 5 fields that all parse to a
   * non-empty value set. Cheap validity check for editor input.
   */
  public static Boolean isValidCron(String cronExpr) {
    if (String.isBlank(cronExpr)) {
      return false;
    }
    List<String> fields = cronExpr.trim().split('\\s+');
    if (fields.size() != 5) {
      return false;
    }
    return parseField(fields[0], 0, 59) != null &&
      parseField(fields[1], 0, 23) != null &&
      parseField(fields[2], 1, 31) != null &&
      parseField(fields[3], 1, 12) != null &&
      parseField(fields[4], 0, 6) != null;
  }

  // Returns the largest value in the set that is ≤ max, or -1 if none.
  private static Integer latestBelow(Set<Integer> vals, Integer maxVal) {
    Integer best = -1;
    for (Integer v : vals) {
      if (v <= maxVal && v > best) {
        best = v;
      }
    }
    return best;
  }

  // Returns the smallest value in the set that is ≥ min, or -1 if none.
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

  /**
   * Parses a single cron field into an expanded Set<Integer>.
   * Returns null if the field is invalid or any value is out of [minVal, maxVal].
   */
  @TestVisible
  static Set<Integer> parseField(String field, Integer minVal, Integer maxVal) {
    Set<Integer> result = new Set<Integer>();

    for (String part : field.split(',')) {
      part = part.trim();
      if (String.isBlank(part)) {
        return null;
      }

      // Step: a-b/n or */n
      if (part.contains('/')) {
        List<String> stepParts = part.split('/');
        if (stepParts.size() != 2) {
          return null;
        }
        Integer step = tryParseInt(stepParts[1]);
        if (step == null || step < 1) {
          return null;
        }
        Integer rangeStart;
        Integer rangeEnd;
        if (stepParts[0].equals('*')) {
          rangeStart = minVal;
          rangeEnd = maxVal;
        } else if (stepParts[0].contains('-')) {
          List<String> bounds = stepParts[0].split('-');
          if (bounds.size() != 2) {
            return null;
          }
          rangeStart = tryParseInt(bounds[0]);
          rangeEnd = tryParseInt(bounds[1]);
          if (rangeStart == null || rangeEnd == null) {
            return null;
          }
        } else {
          rangeStart = tryParseInt(stepParts[0]);
          if (rangeStart == null) {
            return null;
          }
          rangeEnd = maxVal;
        }
        if (
          rangeStart < minVal ||
          rangeEnd > maxVal ||
          rangeStart > rangeEnd
        ) {
          return null;
        }
        for (Integer v = rangeStart; v <= rangeEnd; v += step) {
          result.add(v);
        }
      } else if (part.equals('*')) {
        for (Integer v = minVal; v <= maxVal; v++) {
          result.add(v);
        }
      } else if (part.contains('-')) {
        List<String> bounds = part.split('-');
        if (bounds.size() != 2) {
          return null;
        }
        Integer lo = tryParseInt(bounds[0]);
        Integer hi = tryParseInt(bounds[1]);
        if (lo == null || hi == null || lo < minVal || hi > maxVal || lo > hi) {
          return null;
        }
        for (Integer v = lo; v <= hi; v++) {
          result.add(v);
        }
      } else {
        Integer val = tryParseInt(part);
        if (val == null || val < minVal || val > maxVal) {
          return null;
        }
        result.add(val);
      }
    }

    return result.isEmpty() ? null : result;
  }

  private static Integer tryParseInt(String s) {
    try {
      return Integer.valueOf(s.trim());
    } catch (Exception e) {
      return null;
    }
  }
}
