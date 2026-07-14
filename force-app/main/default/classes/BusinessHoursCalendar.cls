/**
 * @description Calendar-day math over a BusinessHours record, extracted from BusinessSleepCalculator (issue: analyzer decomposition) to keep each calculator class under the class-complexity thresholds. Computes working-millisecond spans for whole business days, resolving per-day working windows either through the platform BusinessHours methods (real records) or a day-of-week fallback (mock records with a null Id used in unit tests). Stateless apart from a per-BusinessHours working-day cache.
 */
public inherited sharing class BusinessHoursCalendar {
  /** @description Number of milliseconds in one second. */
  private static final Long MILLISECONDS_IN_SECOND = 1000L;
  /** @description Number of milliseconds in one minute. */
  private static final Long MILLISECONDS_IN_MINUTE = 60000L;
  /** @description Number of milliseconds in one hour. */
  private static final Long MILLISECONDS_IN_HOUR = 3600000L;
  /** @description Number of milliseconds in one day. */
  private static final Long MILLISECONDS_IN_DAY = 86400000L;

  /** @description Cache of average working milliseconds per business day keyed by BusinessHours Id. */
  private static final Map<Id, Long> MS_PER_BUSINESS_DAY_BY_BH_ID = new Map<Id, Long>();

  @TestVisible
  private static Long getMillisecondsInBusinessDay(
    BusinessHours selectedBusinessHours
  ) {
    if (MS_PER_BUSINESS_DAY_BY_BH_ID.containsKey(selectedBusinessHours.Id)) {
      return MS_PER_BUSINESS_DAY_BY_BH_ID.get(selectedBusinessHours.Id);
    }

    List<Time> starts = new List<Time>{
      selectedBusinessHours.SundayStartTime,
      selectedBusinessHours.MondayStartTime,
      selectedBusinessHours.TuesdayStartTime,
      selectedBusinessHours.WednesdayStartTime,
      selectedBusinessHours.ThursdayStartTime,
      selectedBusinessHours.FridayStartTime,
      selectedBusinessHours.SaturdayStartTime
    };
    List<Time> ends = new List<Time>{
      selectedBusinessHours.SundayEndTime,
      selectedBusinessHours.MondayEndTime,
      selectedBusinessHours.TuesdayEndTime,
      selectedBusinessHours.WednesdayEndTime,
      selectedBusinessHours.ThursdayEndTime,
      selectedBusinessHours.FridayEndTime,
      selectedBusinessHours.SaturdayEndTime
    };

    Long totalMs = 0;
    Integer activeDays = 0;
    for (Integer i = 0; i < 7; i++) {
      Time startTime = starts[i];
      Time endTime = ends[i];
      if (startTime != null && endTime != null) {
        activeDays++;
        if (startTime == endTime) {
          totalMs += MILLISECONDS_IN_DAY;
        } else {
          Long startMs = getMillisecondsSinceMidnight(startTime);
          Long endMs = getMillisecondsSinceMidnight(endTime);
          totalMs += (endMs - startMs);
        }
      }
    }
    Long result = MILLISECONDS_IN_DAY;
    if (activeDays > 0) {
      result = totalMs / activeDays;
    }
    MS_PER_BUSINESS_DAY_BY_BH_ID.put(selectedBusinessHours.Id, result);
    return result;
  }

  /**
   * @description The calendar's time zone key, defaulting to GMT when unset.
   * @param bh The BusinessHours calendar to read the time zone from.
   * @return The calendar's time zone key, or 'GMT' when blank.
   */
  private static String timeZoneKeyOf(BusinessHours bh) {
    return String.isNotBlank(bh.TimeZoneSidKey) ? bh.TimeZoneSidKey : 'GMT';
  }

  /**
   * @description The instant the calendar-day scan should begin: the given start when the calendar has no Id (mock) or start is already within business hours, otherwise the next business-hours start after it.
   * @param bh The BusinessHours calendar defining working windows.
   * @param start The candidate start instant for the scan.
   * @return The adjusted instant at which the calendar-day scan should begin.
   */
  private static DateTime businessScanStart(BusinessHours bh, DateTime start) {
    if (bh.Id == null) {
      return start;
    }
    return BusinessHours.isWithin(bh.Id, start)
      ? start
      : BusinessHours.nextStartDate(bh.Id, start);
  }

  /**
   * @description Sums the working milliseconds across the requested number of whole business days from the given start, scanning calendar days and skipping non-working ones. Falls back to a plain calendar-day span when no working day is found, and throws when the requested count cannot be reached inside the scan limit.
   * @param selectedBusinessHours The BusinessHours calendar defining working windows.
   * @param start The instant to begin the scan from.
   * @param days The number of whole business days to accumulate.
   * @return The total working milliseconds across the requested business days.
   */
  @TestVisible
  private static Long getMillisecondsForDays(
    BusinessHours selectedBusinessHours,
    DateTime start,
    Integer days
  ) {
    if (days == null || days <= 0) {
      return 0L;
    }
    String tz = timeZoneKeyOf(selectedBusinessHours);
    DateTime current = businessScanStart(selectedBusinessHours, start);
    Date currentDate = Date.valueOf(current.format('yyyy-MM-dd', tz));
    Long totalMs = 0;
    Integer daysAdded = 0;
    Integer maxDays = Math.min(3650, days * 7 + 366);

    for (Integer i = 0; i < maxDays && daysAdded < days; i++) {
      DateTime currentInstant = getLocalMidnight(currentDate, tz).addHours(12);
      Long workingMs = getWorkingMsForDay(
        selectedBusinessHours,
        currentInstant
      );
      if (workingMs > 0) {
        totalMs += workingMs;
        daysAdded++;
      }
      currentDate = currentDate.addDays(1);
    }

    if (daysAdded == 0) {
      return (Long) days * MILLISECONDS_IN_DAY;
    }
    if (daysAdded < days) {
      throw new IllegalArgumentException(
        'StepResult.sleep: requested business duration exceeds the maximum calendar scan limit (3650 days)'
      );
    }
    return totalMs;
  }

  @TestVisible
  private static DateTime getLocalMidnight(Date d, String tz) {
    DateTime gmtMidnight = DateTime.newInstanceGmt(
      d.year(),
      d.month(),
      d.day(),
      0,
      0,
      0
    );
    if (String.isBlank(tz)) {
      return gmtMidnight;
    }
    Timezone timezoneObj = Timezone.getTimeZone(tz);
    Integer offsetMs1 = timezoneObj.getOffset(gmtMidnight);
    DateTime candidate = gmtMidnight.addSeconds(-offsetMs1 / 1000);
    Integer offsetMs2 = timezoneObj.getOffset(candidate);
    if (offsetMs1 != offsetMs2) {
      candidate = gmtMidnight.addSeconds(-offsetMs2 / 1000);
    }
    return candidate;
  }

  private static Integer getDayOfWeek(DateTime dt, String tz) {
    String dateStr = dt.format('yyyy-MM-dd', tz);
    Date localDate = Date.valueOf(dateStr);
    Date refDate = Date.newInstance(1900, 1, 7); // A Sunday
    Integer daysBetween = refDate.daysBetween(localDate);
    Integer dayOfWeekNum = Math.mod(daysBetween, 7);
    if (dayOfWeekNum < 0) {
      dayOfWeekNum += 7;
    }
    return dayOfWeekNum; // 0 = Sunday, 1 = Monday, ..., 6 = Saturday
  }

  @TestVisible
  private static Long getWorkingMsForDay(
    BusinessHours selectedBusinessHours,
    DateTime dt
  ) {
    if (selectedBusinessHours.Id != null) {
      String tz = String.isNotBlank(selectedBusinessHours.TimeZoneSidKey)
        ? selectedBusinessHours.TimeZoneSidKey
        : 'GMT';
      Date localDate = Date.valueOf(dt.format('yyyy-MM-dd', tz));
      DateTime dayStart = getLocalMidnight(localDate, tz);
      DateTime dayEnd = getLocalMidnight(localDate.addDays(1), tz);
      return BusinessHours.diff(selectedBusinessHours.Id, dayStart, dayEnd);
    }

    // Fallback for mock BusinessHours with null ID in unit tests
    String tz = String.isNotBlank(selectedBusinessHours.TimeZoneSidKey)
      ? selectedBusinessHours.TimeZoneSidKey
      : 'GMT';
    Integer dayOfWeek = getDayOfWeek(dt, tz);
    Time startTime;
    Time endTime;
    switch on dayOfWeek {
      when 0 {
        startTime = selectedBusinessHours.SundayStartTime;
        endTime = selectedBusinessHours.SundayEndTime;
      }
      when 1 {
        startTime = selectedBusinessHours.MondayStartTime;
        endTime = selectedBusinessHours.MondayEndTime;
      }
      when 2 {
        startTime = selectedBusinessHours.TuesdayStartTime;
        endTime = selectedBusinessHours.TuesdayEndTime;
      }
      when 3 {
        startTime = selectedBusinessHours.WednesdayStartTime;
        endTime = selectedBusinessHours.WednesdayEndTime;
      }
      when 4 {
        startTime = selectedBusinessHours.ThursdayStartTime;
        endTime = selectedBusinessHours.ThursdayEndTime;
      }
      when 5 {
        startTime = selectedBusinessHours.FridayStartTime;
        endTime = selectedBusinessHours.FridayEndTime;
      }
      when 6 {
        startTime = selectedBusinessHours.SaturdayStartTime;
        endTime = selectedBusinessHours.SaturdayEndTime;
      }
    }
    if (startTime == null || endTime == null) {
      return 0L;
    }
    if (startTime == endTime) {
      return MILLISECONDS_IN_DAY;
    }
    return getMillisecondsSinceMidnight(endTime) -
      getMillisecondsSinceMidnight(startTime);
  }

  private static Long getMillisecondsSinceMidnight(Time t) {
    if (t == null) {
      return 0;
    }
    return t.hour() * MILLISECONDS_IN_HOUR +
      t.minute() * MILLISECONDS_IN_MINUTE +
      t.second() * MILLISECONDS_IN_SECOND +
      t.millisecond();
  }
}
