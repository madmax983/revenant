/**
 * @description Business-hours-aware sleep duration calculator extracted from StepResult (issue: analyzer decomposition). Resolves a named BusinessHours calendar and converts an amount/unit pair into the clamped whole-second wait until the business-hours-adjusted wake time, delegating whole-business-day span math to BusinessHoursCalendar. Argument validation, unit conversion, the resolved-calendar cache, and the mockable clock live here so StepResult stays a thin directive factory. The public entry point computeSeconds is intentionally named differently from StepResult.sleep to avoid the PMD class-metric recursion inflation.
 */
public inherited sharing class BusinessSleepCalculator {
  /** @description Test hook overriding the current instant used by business-sleep math; null in production. */
  @TestVisible
  private static DateTime mockCurrentDateTime = null;

  /** @description Number of milliseconds in one second. */
  private static final Long MILLISECONDS_IN_SECOND = 1000L;
  /** @description Number of milliseconds in one minute. */
  private static final Long MILLISECONDS_IN_MINUTE = 60000L;
  /** @description Number of milliseconds in one hour. */
  private static final Long MILLISECONDS_IN_HOUR = 3600000L;

  /** @description Largest representable 32-bit Integer, used to clamp the returned seconds. */
  private static final Integer MAX_INTEGER = 2147483647;
  /** @description Largest representable 64-bit Long, used to cap overflowed millisecond intervals. */
  private static final Long MAX_LONG = 9223372036854775807L;

  // Lower-cased unit spellings that route a business sleep through the
  // BusinessHours calendar-day scan (all others are fixed-length multiples).
  /** @description Lower-cased unit spellings routed through the BusinessHours calendar-day scan. */
  private static final Set<String> BUSINESS_DAY_UNITS = new Set<String>{
    'days',
    'business days',
    'day',
    'business day'
  };

  /** @description Cache of resolved BusinessHours calendars keyed by lower-cased name. */
  private static final Map<String, BusinessHours> BUSINESS_HOURS_BY_NAME = new Map<String, BusinessHours>();

  /**
   * @description Validates the arguments, resolves the named calendar, and returns the clamped whole-second wait until the business-hours-adjusted wake time. Named distinctly from StepResult.sleep so the class-level complexity metric does not treat the delegation as recursion.
   * @param amount The non-negative quantity of the unit to sleep.
   * @param unit The unit of time (e.g. days, hours, minutes), optionally business-prefixed.
   * @param businessHoursName The name of the BusinessHours calendar to resolve against.
   * @return The clamped whole-second wait until the business-hours-adjusted wake time.
   */
  public static Integer computeSeconds(
    Integer amount,
    String unit,
    String businessHoursName
  ) {
    validateBusinessSleepArgs(amount, unit, businessHoursName);
    return businessSleepSeconds(amount, unit, businessHoursName);
  }

  private static DateTime getCurrentDateTime() {
    return mockCurrentDateTime != null ? mockCurrentDateTime : DateTime.now();
  }

  private static BusinessHours getBusinessHours(String name) {
    if (String.isBlank(name)) {
      return null;
    }
    String trimmedName = name.trim();
    String cacheKey = trimmedName.toLowerCase();
    if (BUSINESS_HOURS_BY_NAME.containsKey(cacheKey)) {
      return BUSINESS_HOURS_BY_NAME.get(cacheKey);
    }

    Boolean queryDefault = (cacheKey == 'default');
    List<BusinessHours> matchingBusinessHours;
    if (queryDefault) {
      matchingBusinessHours = [
        SELECT
          Id,
          Name,
          TimeZoneSidKey,
          IsActive,
          IsDefault,
          MondayStartTime,
          MondayEndTime,
          TuesdayStartTime,
          TuesdayEndTime,
          WednesdayStartTime,
          WednesdayEndTime,
          ThursdayStartTime,
          ThursdayEndTime,
          FridayStartTime,
          FridayEndTime,
          SaturdayStartTime,
          SaturdayEndTime,
          SundayStartTime,
          SundayEndTime
        FROM BusinessHours
        WHERE IsActive = TRUE AND IsDefault = TRUE
        WITH USER_MODE
        LIMIT 1
      ];
    } else {
      matchingBusinessHours = [
        SELECT
          Id,
          Name,
          TimeZoneSidKey,
          IsActive,
          IsDefault,
          MondayStartTime,
          MondayEndTime,
          TuesdayStartTime,
          TuesdayEndTime,
          WednesdayStartTime,
          WednesdayEndTime,
          ThursdayStartTime,
          ThursdayEndTime,
          FridayStartTime,
          FridayEndTime,
          SaturdayStartTime,
          SaturdayEndTime,
          SundayStartTime,
          SundayEndTime
        FROM BusinessHours
        WHERE IsActive = TRUE AND Name = :trimmedName
        WITH USER_MODE
        LIMIT 1
      ];
    }

    if (matchingBusinessHours.isEmpty()) {
      throw new IllegalArgumentException(
        'Unknown Business Hours name: ' + name
      );
    }

    BUSINESS_HOURS_BY_NAME.put(cacheKey, matchingBusinessHours[0]);
    if (matchingBusinessHours[0].Name != null) {
      BUSINESS_HOURS_BY_NAME.put(
        matchingBusinessHours[0].Name.toLowerCase(),
        matchingBusinessHours[0]
      );
    }
    return matchingBusinessHours[0];
  }

  private static void validateBusinessSleepArgs(
    Integer amount,
    String unit,
    String businessHoursName
  ) {
    if (amount == null || amount < 0) {
      throw new IllegalArgumentException(
        'StepResult.sleep: amount must be a non-negative integer'
      );
    }
    if (String.isBlank(unit)) {
      throw new IllegalArgumentException(
        'StepResult.sleep: unit must not be blank'
      );
    }
    if (String.isBlank(businessHoursName)) {
      throw new IllegalArgumentException(
        'StepResult.sleep: businessHoursName must not be blank'
      );
    }
  }

  /**
   * @description Resolves the named BusinessHours calendar, converts amount/unit to a millisecond interval, and returns the clamped whole-second wait until the business-hours-adjusted wake time.
   * @param amount The quantity of the unit to sleep.
   * @param unit The unit of time to convert.
   * @param businessHoursName The name of the BusinessHours calendar to resolve.
   * @return The clamped whole-second wait until the adjusted wake time.
   */
  private static Integer businessSleepSeconds(
    Integer amount,
    String unit,
    String businessHoursName
  ) {
    BusinessHours selectedBusinessHours = getBusinessHours(businessHoursName);
    DateTime now = getCurrentDateTime();

    String unitLower = unit.toLowerCase().trim();
    Long intervalMs = isBusinessDaysUnit(unitLower)
      ? BusinessHoursCalendar.getMillisecondsForDays(
          selectedBusinessHours,
          now,
          amount
        )
      : nonDayUnitMillis(unitLower, amount, unit);

    // Safety check against overflow in intervalMs
    if (intervalMs < 0) {
      intervalMs = MAX_LONG; // Cap at max value if it wrapped
    }

    DateTime wakeTime = BusinessHours.add(
      selectedBusinessHours.Id,
      now,
      intervalMs
    );
    return clampedSleepSeconds(now, wakeTime);
  }

  private static Boolean isBusinessDaysUnit(String unitLower) {
    return BUSINESS_DAY_UNITS.contains(unitLower);
  }

  /**
   * @description Converts a non-day unit (hours/minutes/seconds and their variants) to milliseconds, throwing for an unsupported unit.
   * @param unitLower The lower-cased, trimmed unit spelling to convert.
   * @param amount The quantity of the unit.
   * @param unit The original unit spelling, used in the error message.
   * @return The interval in milliseconds for the given amount and unit.
   */
  private static Long nonDayUnitMillis(
    String unitLower,
    Integer amount,
    String unit
  ) {
    Long intervalMs;
    switch on unitLower {
      when 'hours', 'business hours', 'hour', 'business hour' {
        intervalMs = (Long) amount * MILLISECONDS_IN_HOUR;
      }
      when 'minutes', 'business minutes', 'minute', 'business minute' {
        intervalMs = (Long) amount * MILLISECONDS_IN_MINUTE;
      }
      when 'seconds', 'business seconds', 'second', 'business second' {
        intervalMs = (Long) amount * MILLISECONDS_IN_SECOND;
      }
      when else {
        throw new IllegalArgumentException(
          'StepResult.sleep: unsupported unit: ' + unit
        );
      }
    }
    return intervalMs;
  }

  private static Integer clampedSleepSeconds(DateTime now, DateTime wakeTime) {
    Long diffMs = wakeTime.getTime() - now.getTime();
    if (diffMs < 0) {
      diffMs = 0L;
    }
    Long sleepSecondsLong = diffMs / 1000L;
    return sleepSecondsLong > MAX_INTEGER
      ? MAX_INTEGER
      : (Integer) sleepSecondsLong;
  }
}
