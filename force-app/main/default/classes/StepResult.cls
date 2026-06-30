public inherited sharing class StepResult {
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

  public ActionType action { get; set; }
  public String nextStepName { get; set; }
  public String outputJson { get; set; }
  public String stepStateJson { get; set; }
  public Integer retryAfterSeconds { get; set; }
  public RetryPolicy retryPolicy { get; set; }
  public Integer sleepDurationSeconds { get; set; }
  public String childWorkflowName { get; set; }
  public String childCorrelationKey { get; set; }
  public String childInputJson { get; set; }
  public String approvalKey { get; set; }
  public String approvalRole { get; set; }
  public List<String> parallelStepNames { get; set; }
  public String parallelInputJson { get; set; }
  public String nextInputJson { get; set; }
  public String newCorrelationKey { get; set; }
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
  public Integer timeoutSeconds { get; set; }
  public String timeoutStep { get; set; }

  // Explicit terminal failure (issue #37). Populated by the fail() factories: a
  // deliberate, non-retryable business failure the author returns instead of
  // throwing. failureReason is the operator-readable message; failureDataJson is
  // optional structured data serialized for downstream compensation/alerting.
  public String failureReason { get; set; }
  public String failureDataJson { get; set; }

  public static StepResult complete(String nextStepName, Object output) {
    StepResult r = new StepResult();
    r.action = ActionType.COMPLETE;
    r.nextStepName = nextStepName;
    r.outputJson = (output != null) ? JSON.serialize(output) : null;
    return r;
  }

  /**
   * Completes the step and hands the engine one or more domain Platform Events
   * to publish effectively-once when this COMPLETE transition commits (issue
   * #64). Retries, yields, suspends, re-drives, and at-least-once resumes that
   * re-run execute() before that commit publish nothing; a step already durably
   * Completed never re-executes and so never re-emits.
   *
   * Authors choose their own __e type; the engine imposes no envelope. Delivery
   * to subscribers remains at-least-once — the guarantee is effectively-once
   * publication at the producer, so subscribers must stay idempotent.
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

  public static StepResult yield(String stepStateJson) {
    StepResult r = new StepResult();
    r.action = ActionType.YIELD;
    r.stepStateJson = stepStateJson;
    return r;
  }

  public static StepResult suspend() {
    StepResult r = new StepResult();
    r.action = ActionType.SUSPEND;
    return r;
  }

  public static StepResult suspend(String stepStateJson) {
    StepResult r = new StepResult();
    r.action = ActionType.SUSPEND;
    r.stepStateJson = stepStateJson;
    return r;
  }

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

  public static StepResult retry(Integer retryAfterSeconds) {
    StepResult r = new StepResult();
    r.action = ActionType.RETRY;
    r.retryAfterSeconds = retryAfterSeconds;
    r.retryPolicy = new RetryPolicy(retryAfterSeconds, (Double) 1.0, 5); // Backwards compatible fixed interval retry
    return r;
  }

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

  @TestVisible
  private static DateTime mockCurrentDateTime = null;

  private static final Long MILLISECONDS_IN_SECOND = 1000L;
  private static final Long MILLISECONDS_IN_MINUTE = 60000L;
  private static final Long MILLISECONDS_IN_HOUR = 3600000L;
  private static final Long MILLISECONDS_IN_DAY = 86400000L;

  private static final Integer MAX_INTEGER = 2147483647;
  private static final Long MAX_LONG = 9223372036854775807L;

  private static final Map<String, BusinessHours> businessHoursByName = new Map<String, BusinessHours>();
  private static final Map<Id, Long> msPerBusinessDayByBhId = new Map<Id, Long>();

  private static DateTime getCurrentDateTime() {
    return mockCurrentDateTime != null ? mockCurrentDateTime : DateTime.now();
  }

  private static BusinessHours getBusinessHours(String name) {
    if (String.isBlank(name)) {
      return null;
    }
    String trimmedName = name.trim();
    String cacheKey = trimmedName.toLowerCase();
    if (businessHoursByName.containsKey(cacheKey)) {
      return businessHoursByName.get(cacheKey);
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
        LIMIT 1
      ];
    }

    if (matchingBusinessHours.isEmpty()) {
      throw new IllegalArgumentException(
        'Unknown Business Hours name: ' + name
      );
    }

    businessHoursByName.put(cacheKey, matchingBusinessHours[0]);
    if (matchingBusinessHours[0].Name != null) {
      businessHoursByName.put(
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
    if (msPerBusinessDayByBhId.containsKey(selectedBusinessHours.Id)) {
      return msPerBusinessDayByBhId.get(selectedBusinessHours.Id);
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
    msPerBusinessDayByBhId.put(selectedBusinessHours.Id, result);
    return result;
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
    Long totalMs = 0;
    DateTime current = start;
    if (selectedBusinessHours.Id != null) {
      current = BusinessHours.isWithin(selectedBusinessHours.Id, start)
        ? start
        : BusinessHours.nextStartDate(selectedBusinessHours.Id, start);
    }
    Integer daysAdded = 0;

    for (Integer i = 0; i < 365 && daysAdded < days; i++) {
      Long workingMs = getWorkingMsForDay(selectedBusinessHours, current);
      if (workingMs > 0) {
        totalMs += workingMs;
        daysAdded++;
      }
      current = current.addDays(1);
    }

    if (daysAdded == 0) {
      return (Long) days * MILLISECONDS_IN_DAY;
    }
    if (daysAdded < days) {
      totalMs += (days - daysAdded) * (totalMs / daysAdded);
    }
    return totalMs;
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

  private static Long getWorkingMsForDay(
    BusinessHours selectedBusinessHours,
    DateTime dt
  ) {
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

  public static StepResult sleep(
    Integer amount,
    String unit,
    String businessHoursName
  ) {
    return sleep(amount, unit, businessHoursName, null);
  }

  public static StepResult sleep(
    Integer amount,
    String unit,
    String businessHoursName,
    String stepStateJson
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

    BusinessHours selectedBusinessHours = getBusinessHours(businessHoursName);

    DateTime now = getCurrentDateTime();
    Long intervalMs;
    String unitLower = unit.toLowerCase().trim();
    switch on unitLower {
      when 'days', 'business days', 'day', 'business day' {
        intervalMs = getMillisecondsForDays(selectedBusinessHours, now, amount);
      }
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

    // Safety checks against overflow in intervalMs
    if (intervalMs < 0) {
      intervalMs = MAX_LONG; // Cap at max value if it wrapped
    }

    DateTime wakeTime = BusinessHours.add(
      selectedBusinessHours.Id,
      now,
      intervalMs
    );

    Long diffMs = wakeTime.getTime() - now.getTime();
    if (diffMs < 0) {
      diffMs = 0L;
    }
    Long sleepSecondsLong = diffMs / 1000L;
    Integer sleepSeconds = sleepSecondsLong > MAX_INTEGER
      ? MAX_INTEGER
      : (Integer) sleepSecondsLong;

    StepResult result = new StepResult();
    result.action = ActionType.SLEEP;
    result.sleepDurationSeconds = sleepSeconds;
    result.stepStateJson = stepStateJson;
    return result;
  }

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

  public class ChildRequest {
    public String workflowName { get; set; }
    public String correlationKey { get; set; }
    public String inputJson { get; set; }

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

  public static StepResult waitForApproval(
    String key,
    String role,
    Integer timeoutSeconds,
    String timeoutStep
  ) {
    if (String.isBlank(key)) {
      throw new IllegalArgumentException(
        'StepResult.waitForApproval: key must not be blank'
      );
    }
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
    StepResult r = new StepResult();
    r.action = ActionType.WAIT_FOR_APPROVAL;
    r.approvalKey = key;
    r.approvalRole = role;
    r.timeoutSeconds = timeoutSeconds;
    r.timeoutStep = timeoutStep;
    return r;
  }

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

  public static StepResult continueAsNew(Object nextInput) {
    StepResult r = new StepResult();
    r.action = ActionType.CONTINUE_AS_NEW;
    r.nextInputJson = serializeInputIfNeeded(nextInput);
    r.newCorrelationKey = null;
    return r;
  }

  public static StepResult continueAsNew(Object nextInput, String customKey) {
    StepResult r = new StepResult();
    r.action = ActionType.CONTINUE_AS_NEW;
    r.nextInputJson = serializeInputIfNeeded(nextInput);
    r.newCorrelationKey = customKey;
    return r;
  }

  /**
   * Deliberately, terminally fails the step (issue #37). Returning this — rather
   * than throwing — records the author's operator-readable reason as the failure
   * (not an Apex stack trace) and stops the workflow in ZERO retry hops: the
   * engine routes straight through the existing failure/compensation path,
   * compensating (LIFO) when the instance has a Compensation_Stack__c or failing
   * outright when it does not. This is Revenant's non-retryable / permanent-
   * failure primitive: use it for business-rule violations the author knows will
   * never succeed (e.g. "order already refunded", "KYC rejected").
   */
  public static StepResult fail(String reason) {
    return fail(reason, null);
  }

  /**
   * Same as fail(reason) but also carries structured failureData, persisted with
   * the failing step for downstream inspection (compensation, alerting).
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
        } catch (Exception e) {
          // Fall through
        }
      }
      return JSON.serialize(strInput);
    }
    return JSON.serialize(input);
  }

  private static Boolean isJsonLike(String trimmed) {
    if (
      (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
      (trimmed.startsWith('[') && trimmed.endsWith(']')) ||
      (trimmed.startsWith('"') && trimmed.endsWith('"'))
    ) {
      return true;
    }
    if (trimmed == 'true' || trimmed == 'false' || trimmed == 'null') {
      return true;
    }
    // Match standard integer or float patterns in JSON
    if (Pattern.matches('^-?\\d+(\\.\\d+)?([eE][+-]?\\d+)?$', trimmed)) {
      return true;
    }
    return false;
  }
}
