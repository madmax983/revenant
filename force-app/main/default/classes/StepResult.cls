/**
 * @description Immutable directive a WorkflowStep returns to tell the engine what to do next — complete, yield, suspend, retry, sleep, split, start children, wait for approval, continue-as-new, or fail — built through the static factory methods on this class.
 */
public inherited sharing class StepResult {
  /**
   * @description Enumerates the kinds of transitions a step can request from the engine.
   */
  public enum ActionType {
    COMPLETE,
    SUSPEND,
    YIELD,
    RETRY,
    SLEEP,
    START_CHILD,
    WAIT_FOR_APPROVAL,
    SPLIT,
    CONTINUE_AS_NEW,
    FAIL,
    START_CHILDREN
  }

  /** @description The kind of transition this result requests. */
  public ActionType action { get; set; }
  /** @description The name of the next step to run, when applicable. */
  public String nextStepName { get; set; }
  /** @description The step's serialized output payload, or null. */
  public String outputJson { get; set; }
  /** @description Opaque durable step state persisted across a yield/suspend/sleep. */
  public String stepStateJson { get; set; }
  /** @description Fixed delay in seconds before a legacy fixed-interval retry. */
  public Integer retryAfterSeconds { get; set; }
  /** @description The retry policy governing backoff and attempt limits. */
  public RetryPolicy retryPolicy { get; set; }
  /** @description Duration in seconds the engine should sleep before resuming. */
  public Integer sleepDurationSeconds { get; set; }
  /** @description Name of the child workflow to start, for START_CHILD. */
  public String childWorkflowName { get; set; }
  /** @description Correlation key for the child workflow to start. */
  public String childCorrelationKey { get; set; }
  /** @description Serialized input passed to the child workflow. */
  public String childInputJson { get; set; }
  /** @description Approval signal key the step waits on, for WAIT_FOR_APPROVAL. */
  public String approvalKey { get; set; }
  /** @description Role authorized to satisfy the pending approval. */
  public String approvalRole { get; set; }
  /** @description Step names to run in parallel, for SPLIT. */
  public List<String> parallelStepNames { get; set; }
  /** @description Serialized input shared by the parallel branches. */
  public String parallelInputJson { get; set; }
  /** @description Serialized input seeding the continued-as-new instance. */
  public String nextInputJson { get; set; }
  /** @description Custom correlation key for the continued-as-new instance. */
  public String newCorrelationKey { get; set; }
  /** @description Child workflows to start together, for START_CHILDREN. */
  public List<ChildRequest> childRequests { get; set; }

  /**
   * Author-owned Platform Event records the engine publishes effectively-once,
   * coupled to this step's COMPLETE (or SPLIT) transition commit (issue #64).
   * Populated by the complete(next, output, events) overload, or merged with
   * anything the step buffered via StepContext.emit(). Null when the step emits
   * no events. The emitted __e should use publishBehavior=PublishAfterCommit so
   * a rolled-back/retried/yielded transition publishes nothing.
   */
  public List<SObject> outboundEvents { get; set; }

  // Durable wait timeout (issue #35). When set, the engine arms Sleep_Until__c
  // and routes to timeoutStep if the deadline elapses before a signal/approval.
  /** @description Deadline in seconds for a durable wait before routing to timeoutStep. */
  public Integer timeoutSeconds { get; set; }
  /** @description Step to route to when the durable wait deadline elapses. */
  public String timeoutStep { get; set; }

  // Explicit terminal failure (issue #37). Populated by the fail() factories: a
  // deliberate, non-retryable business failure the author returns instead of
  // throwing. failureReason is the operator-readable message; failureDataJson is
  // optional structured data serialized for downstream compensation/alerting.
  /** @description Operator-readable reason for a deliberate terminal failure. */
  public String failureReason { get; set; }
  /** @description Optional serialized structured data accompanying the failure. */
  public String failureDataJson { get; set; }

  @TestVisible
  private static DateTime mockCurrentDateTime = null;

  private static final Long MILLISECONDS_IN_SECOND = 1000L;
  private static final Long MILLISECONDS_IN_MINUTE = 60000L;
  private static final Long MILLISECONDS_IN_HOUR = 3600000L;
  private static final Long MILLISECONDS_IN_DAY = 86400000L;

  private static final Integer MAX_INTEGER = 2147483647;
  private static final Long MAX_LONG = 9223372036854775807L;

  // Lower-cased unit spellings that route a business sleep through the
  // BusinessHours calendar-day scan (all others are fixed-length multiples).
  private static final Set<String> BUSINESS_DAY_UNITS = new Set<String>{
    'days',
    'business days',
    'day',
    'business day'
  };

  private static final Map<String, BusinessHours> BUSINESS_HOURS_BY_NAME = new Map<String, BusinessHours>();
  private static final Map<Id, Long> MS_PER_BUSINESS_DAY_BY_BH_ID = new Map<Id, Long>();

  /**
   * @description Completes the step, optionally routing to a named next step and carrying a serialized output payload.
   * @param nextStepName The name of the next step to run, or null to let the definition decide.
   * @param output The step output to serialize, or null for no output.
   * @return A COMPLETE result carrying the next step and serialized output.
   */
  public static StepResult complete(String nextStepName, Object output) {
    StepResult r = new StepResult();
    r.action = ActionType.COMPLETE;
    r.nextStepName = nextStepName;
    r.outputJson = (output != null) ? JSON.serialize(output) : null;
    return r;
  }

  /**
   * @description Completes the step and hands the engine one or more domain Platform Events to publish effectively-once when this COMPLETE transition commits (issue #64). Retries, yields, suspends, re-drives, and at-least-once resumes that re-run execute() before that commit publish nothing; a step already durably Completed never re-emits. Authors choose their own __e type; delivery to subscribers stays at-least-once, so subscribers must remain idempotent.
   * @param nextStepName The name of the next step to run, or null.
   * @param output The step output to serialize, or null for no output.
   * @param events The outbound Platform Events to publish on commit.
   * @return A COMPLETE result carrying the output and buffered outbound events.
   */
  public static StepResult complete(
    String nextStepName,
    Object output,
    List<SObject> events
  ) {
    StepResult r = complete(nextStepName, output);
    r.outboundEvents = events;
    return r;
  }

  /**
   * @description Yields control back to the engine to re-drive the same step in a fresh transaction, persisting the given durable state so long-running work stays within limits.
   * @param stepStateJson Opaque durable state carried into the next re-drive.
   * @return A YIELD result carrying the persisted step state.
   */
  public static StepResult yield(String stepStateJson) {
    StepResult r = new StepResult();
    r.action = ActionType.YIELD;
    r.stepStateJson = stepStateJson;
    return r;
  }

  /**
   * @description Suspends the step indefinitely to await an external signal or approval.
   * @return A SUSPEND result with no persisted state or timeout.
   */
  public static StepResult suspend() {
    StepResult r = new StepResult();
    r.action = ActionType.SUSPEND;
    return r;
  }

  /**
   * @description Suspends the step to await an external signal, persisting durable state.
   * @param stepStateJson Opaque durable state to persist while suspended.
   * @return A SUSPEND result carrying the persisted step state.
   */
  public static StepResult suspend(String stepStateJson) {
    StepResult r = new StepResult();
    r.action = ActionType.SUSPEND;
    r.stepStateJson = stepStateJson;
    return r;
  }

  /**
   * @description Suspends the step with a durable timeout, routing to timeoutStep if the deadline elapses before a signal or approval arrives.
   * @param timeoutSeconds Positive number of seconds before the wait times out.
   * @param timeoutStep The non-blank step to route to on timeout.
   * @return A SUSPEND result armed with the timeout and timeout step.
   */
  public static StepResult suspend(Integer timeoutSeconds, String timeoutStep) {
    if (String.isBlank(timeoutStep)) {
      throw new IllegalArgumentException(
        'StepResult.suspend: timeoutStep must not be blank'
      );
    }
    if (timeoutSeconds == null || timeoutSeconds <= 0) {
      throw new IllegalArgumentException(
        'StepResult.suspend: timeoutSeconds must be a positive integer'
      );
    }
    StepResult r = new StepResult();
    r.action = ActionType.SUSPEND;
    r.timeoutSeconds = timeoutSeconds;
    r.timeoutStep = timeoutStep;
    return r;
  }

  /**
   * @description Requests a retry of the step governed by the given retry policy's backoff and attempt limits.
   * @param policy The non-null retry policy controlling delay and max attempts.
   * @return A RETRY result carrying the retry policy.
   */
  public static StepResult retry(RetryPolicy policy) {
    if (policy == null) {
      throw new IllegalArgumentException(
        'StepResult.retry: policy must not be null'
      );
    }
    StepResult r = new StepResult();
    r.action = ActionType.RETRY;
    r.retryPolicy = policy;
    return r;
  }

  /**
   * @description Requests a retry after a fixed delay, wrapping it in a backwards-compatible fixed-interval retry policy.
   * @param retryAfterSeconds The fixed delay in seconds before the retry.
   * @return A RETRY result carrying a fixed-interval retry policy.
   */
  public static StepResult retry(Integer retryAfterSeconds) {
    StepResult r = new StepResult();
    r.action = ActionType.RETRY;
    r.retryAfterSeconds = retryAfterSeconds;
    r.retryPolicy = new RetryPolicy(retryAfterSeconds, (Double) 1.0, 5); // Backwards compatible fixed interval retry
    return r;
  }

  /**
   * @description Sleeps durably for the given number of seconds before the engine resumes the step.
   * @param seconds The non-negative number of seconds to sleep.
   * @return A SLEEP result carrying the sleep duration.
   */
  public static StepResult sleep(Integer seconds) {
    if (seconds == null || seconds < 0) {
      throw new IllegalArgumentException(
        'StepResult.sleep: seconds must be a non-negative integer'
      );
    }
    StepResult r = new StepResult();
    r.action = ActionType.SLEEP;
    r.sleepDurationSeconds = seconds;
    return r;
  }

  /**
   * @description Sleeps durably for the given number of seconds while persisting durable step state across the wait.
   * @param seconds The non-negative number of seconds to sleep.
   * @param stepStateJson Opaque durable state to persist while sleeping.
   * @return A SLEEP result carrying the sleep duration and persisted state.
   */
  public static StepResult sleep(Integer seconds, String stepStateJson) {
    if (seconds == null || seconds < 0) {
      throw new IllegalArgumentException(
        'StepResult.sleep: seconds must be a non-negative integer'
      );
    }
    StepResult r = new StepResult();
    r.action = ActionType.SLEEP;
    r.sleepDurationSeconds = seconds;
    r.stepStateJson = stepStateJson;
    return r;
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

  /**
   * @description Sleeps durably for a business-hours-aware duration, converting the given amount and unit against the named BusinessHours calendar to a wake time.
   * @param amount The non-negative quantity of the unit to sleep.
   * @param unit The unit of time (e.g. days, hours, minutes), optionally business-prefixed.
   * @param businessHoursName The name of the BusinessHours calendar to resolve against.
   * @return A SLEEP result whose duration reflects the business-hours-adjusted wake time.
   */
  public static StepResult sleep(
    Integer amount,
    String unit,
    String businessHoursName
  ) {
    validateBusinessSleepArgs(amount, unit, businessHoursName);

    StepResult result = new StepResult();
    result.action = ActionType.SLEEP;
    result.sleepDurationSeconds = businessSleepSeconds(
      amount,
      unit,
      businessHoursName
    );
    return result;
  }

  /**
   * @description Attaches durable step state (opaque JSON, persisted across the wait) to this result, returning it for fluent chaining — e.g. StepResult.sleep(2, 'Hours', 'Default').withStepState(json).
   * @param stepStateJson The opaque durable state to persist across the wait.
   * @return This StepResult, for fluent chaining.
   */
  public StepResult withStepState(String stepStateJson) {
    this.stepStateJson = stepStateJson;
    return this;
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
      ? getMillisecondsForDays(selectedBusinessHours, now, amount)
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

  /**
   * @description Starts a single child workflow as part of a saga, correlating it by key and passing the given input.
   * @param childWorkflowName The non-blank name of the child workflow to start.
   * @param childCorrelationKey The correlation key identifying the child instance.
   * @param input The child input, serialized if needed.
   * @return A START_CHILD result describing the child to start.
   */
  public static StepResult startChild(
    String childWorkflowName,
    String childCorrelationKey,
    Object input
  ) {
    if (String.isBlank(childWorkflowName)) {
      throw new IllegalArgumentException(
        'StepResult.startChild: childWorkflowName must not be blank'
      );
    }
    StepResult r = new StepResult();
    r.action = ActionType.START_CHILD;
    r.childWorkflowName = childWorkflowName;
    r.childCorrelationKey = childCorrelationKey;
    r.childInputJson = serializeInputIfNeeded(input);
    return r;
  }

  /**
   * @description One child workflow to start when a step fans out to multiple children via startChildren.
   */
  public class ChildRequest {
    /** @description Name of the child workflow to start. */
    public String workflowName { get; set; }
    /** @description Correlation key identifying the child instance. */
    public String correlationKey { get; set; }
    /** @description Serialized input passed to the child workflow. */
    public String inputJson { get; set; }

    /**
     * @description Constructs a child request, validating the workflow name and serializing the input as needed.
     * @param workflowName The non-blank name of the child workflow to start.
     * @param correlationKey The correlation key identifying the child instance.
     * @param input The child input, serialized if needed.
     */
    public ChildRequest(
      String workflowName,
      String correlationKey,
      Object input
    ) {
      if (String.isBlank(workflowName)) {
        throw new IllegalArgumentException(
          'ChildRequest: workflowName must not be blank'
        );
      }
      this.workflowName = workflowName;
      this.correlationKey = correlationKey;
      this.inputJson = serializeInputIfNeeded(input);
    }
  }

  /**
   * @description Starts multiple child workflows together as a fan-out, validating that the list is non-empty and contains no null entries.
   * @param children The non-empty list of child requests to start.
   * @return A START_CHILDREN result carrying the child requests.
   */
  public static StepResult startChildren(List<ChildRequest> children) {
    if (children == null || children.isEmpty()) {
      throw new IllegalArgumentException(
        'StepResult.startChildren: children list must not be null or empty'
      );
    }
    for (ChildRequest child : children) {
      if (child == null) {
        throw new IllegalArgumentException(
          'StepResult.startChildren: children list must not contain null values'
        );
      }
    }
    StepResult r = new StepResult();
    r.action = ActionType.START_CHILDREN;
    r.childRequests = children;
    return r;
  }

  /**
   * @description Suspends the step to wait for a human approval signal matching the given key, optionally restricted to a role.
   * @param key The non-blank approval signal key to wait on.
   * @param role The role authorized to approve, or null for any.
   * @return A WAIT_FOR_APPROVAL result carrying the approval key and role.
   */
  public static StepResult waitForApproval(String key, String role) {
    if (String.isBlank(key)) {
      throw new IllegalArgumentException(
        'StepResult.waitForApproval: key must not be blank'
      );
    }
    StepResult r = new StepResult();
    r.action = ActionType.WAIT_FOR_APPROVAL;
    r.approvalKey = key;
    r.approvalRole = role;
    return r;
  }

  /**
   * @description Arms a durable timeout on this WAIT_FOR_APPROVAL result, returning it for fluent chaining — e.g. StepResult.waitForApproval(key, role).withApprovalTimeout(60, 'TimeoutStep'). If the deadline elapses before the approval, the engine routes to timeoutStep.
   * @param timeoutSeconds Positive number of seconds before the approval times out.
   * @param timeoutStep The non-blank step to route to on timeout.
   * @return This StepResult, for fluent chaining.
   */
  public StepResult withApprovalTimeout(
    Integer timeoutSeconds,
    String timeoutStep
  ) {
    if (String.isBlank(timeoutStep)) {
      throw new IllegalArgumentException(
        'StepResult.waitForApproval: timeoutStep must not be blank'
      );
    }
    if (timeoutSeconds == null || timeoutSeconds <= 0) {
      throw new IllegalArgumentException(
        'StepResult.waitForApproval: timeoutSeconds must be a positive integer'
      );
    }
    this.timeoutSeconds = timeoutSeconds;
    this.timeoutStep = timeoutStep;
    return this;
  }

  /**
   * @description Splits execution into parallel branches, one per named step, all running concurrently before the workflow joins.
   * @param stepNames The non-empty list of step names to run in parallel.
   * @return A SPLIT result carrying the parallel step names.
   */
  public static StepResult split(List<String> stepNames) {
    if (stepNames == null || stepNames.isEmpty()) {
      throw new IllegalArgumentException(
        'StepResult.split: stepNames list must not be null or empty'
      );
    }
    for (String stepName : stepNames) {
      if (String.isBlank(stepName)) {
        throw new IllegalArgumentException(
          'StepResult.split: stepNames list must not contain null or blank values'
        );
      }
    }
    StepResult r = new StepResult();
    r.action = ActionType.SPLIT;
    r.parallelStepNames = stepNames;
    return r;
  }

  /**
   * @description Splits execution into parallel branches, one per named step, sharing the given serialized input across all branches.
   * @param stepNames The non-empty list of step names to run in parallel.
   * @param input The shared branch input, serialized if needed.
   * @return A SPLIT result carrying the parallel step names and shared input.
   */
  public static StepResult split(List<String> stepNames, Object input) {
    if (stepNames == null || stepNames.isEmpty()) {
      throw new IllegalArgumentException(
        'StepResult.split: stepNames list must not be null or empty'
      );
    }
    for (String stepName : stepNames) {
      if (String.isBlank(stepName)) {
        throw new IllegalArgumentException(
          'StepResult.split: stepNames list must not contain null or blank values'
        );
      }
    }
    StepResult r = new StepResult();
    r.action = ActionType.SPLIT;
    r.parallelStepNames = stepNames;
    r.parallelInputJson = serializeInputIfNeeded(input);
    return r;
  }

  /**
   * @description Continues the workflow as a fresh instance seeded with the given input, carrying over the current correlation key, to bound history growth on long-running loops.
   * @param nextInput The input seeding the continued instance, serialized if needed.
   * @return A CONTINUE_AS_NEW result carrying the next input.
   */
  public static StepResult continueAsNew(Object nextInput) {
    StepResult r = new StepResult();
    r.action = ActionType.CONTINUE_AS_NEW;
    r.nextInputJson = serializeInputIfNeeded(nextInput);
    r.newCorrelationKey = null;
    return r;
  }

  /**
   * @description Continues the workflow as a fresh instance seeded with the given input and a custom correlation key.
   * @param nextInput The input seeding the continued instance, serialized if needed.
   * @param customKey The correlation key to assign to the continued instance.
   * @return A CONTINUE_AS_NEW result carrying the next input and correlation key.
   */
  public static StepResult continueAsNew(Object nextInput, String customKey) {
    StepResult r = new StepResult();
    r.action = ActionType.CONTINUE_AS_NEW;
    r.nextInputJson = serializeInputIfNeeded(nextInput);
    r.newCorrelationKey = customKey;
    return r;
  }

  /**
   * @description Deliberately, terminally fails the step (issue #37). Returning this — rather than throwing — records the author's operator-readable reason as the failure (not an Apex stack trace) and stops the workflow in ZERO retry hops: the engine routes straight through the failure/compensation path, compensating (LIFO) when the instance has a Compensation_Stack__c or failing outright when it does not. Use it for business-rule violations the author knows will never succeed (e.g. "order already refunded").
   * @param reason The non-blank operator-readable failure reason.
   * @return A FAIL result carrying the failure reason.
   */
  public static StepResult fail(String reason) {
    return fail(reason, null);
  }

  /**
   * @description Same as fail(reason) but also carries structured failureData, persisted with the failing step for downstream inspection (compensation, alerting).
   * @param reason The non-blank operator-readable failure reason.
   * @param failureData Structured failure data to serialize, or null.
   * @return A FAIL result carrying the reason and serialized failure data.
   */
  public static StepResult fail(String reason, Object failureData) {
    if (String.isBlank(reason)) {
      throw new IllegalArgumentException(
        'StepResult.fail: reason must not be blank'
      );
    }
    StepResult r = new StepResult();
    r.action = ActionType.FAIL;
    r.failureReason = reason;
    r.failureDataJson = (failureData != null)
      ? JSON.serialize(failureData)
      : null;
    return r;
  }

  private static String serializeInputIfNeeded(Object input) {
    if (input == null) {
      return null;
    }
    if (input instanceof String) {
      String strInput = (String) input;
      String trimmed = strInput.trim();
      if (isJsonLike(trimmed)) {
        try {
          JSON.deserializeUntyped(trimmed);
          return strInput;
        } catch (Exception ignored) {
        }
      }
      return JSON.serialize(strInput);
    }
    return JSON.serialize(input);
  }

  private static Boolean isJsonLike(String trimmed) {
    return hasJsonDelimiters(trimmed) ||
      trimmed == 'true' ||
      trimmed == 'false' ||
      trimmed == 'null' ||
      // Match standard integer or float patterns in JSON
      Pattern.matches('^-?\\d+(\\.\\d+)?([eE][+-]?\\d+)?$', trimmed);
  }

  /**
   * @description True when the trimmed value is wrapped in matching JSON object, array, or string delimiters.
   * @param trimmed The trimmed candidate string to inspect.
   * @return True if the value has matching JSON delimiters, otherwise false.
   */
  private static Boolean hasJsonDelimiters(String trimmed) {
    return (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
      (trimmed.startsWith('[') && trimmed.endsWith(']')) ||
      (trimmed.startsWith('"') && trimmed.endsWith('"'));
  }
}
