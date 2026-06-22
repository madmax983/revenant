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
    FAIL
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
    StepResult r = new StepResult();
    r.action = ActionType.SLEEP;
    r.sleepDurationSeconds = seconds;
    return r;
  }

  public static StepResult sleep(Integer seconds, String stepStateJson) {
    StepResult r = new StepResult();
    r.action = ActionType.SLEEP;
    r.sleepDurationSeconds = seconds;
    r.stepStateJson = stepStateJson;
    return r;
  }

  public static StepResult startChild(
    String childWorkflowName,
    String correlationKey,
    Object input
  ) {
    StepResult r = new StepResult();
    r.action = ActionType.START_CHILD;
    r.childWorkflowName = childWorkflowName;
    r.childCorrelationKey = correlationKey;
    r.childInputJson = (input != null) ? JSON.serialize(input) : null;
    return r;
  }

  public static StepResult waitForApproval(String key, String role) {
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
    StepResult r = new StepResult();
    r.action = ActionType.SPLIT;
    r.parallelStepNames = stepNames;
    return r;
  }

  public static StepResult split(List<String> stepNames, Object input) {
    StepResult r = new StepResult();
    r.action = ActionType.SPLIT;
    r.parallelStepNames = stepNames;
    if (input == null) {
      r.parallelInputJson = null;
      return r;
    }
    if (input instanceof String) {
      String strInput = (String) input;
      try {
        JSON.deserializeUntyped(strInput);
        r.parallelInputJson = strInput;
      } catch (Exception e) {
        System.debug(
          LoggingLevel.FINE,
          'Parallel input is not a JSON string, serializing: ' + e.getMessage()
        );
        r.parallelInputJson = JSON.serialize(strInput);
      }
      return r;
    }
    r.parallelInputJson = JSON.serialize(input);
    return r;
  }

  public static StepResult continueAsNew(Object nextInput) {
    StepResult r = new StepResult();
    r.action = ActionType.CONTINUE_AS_NEW;
    r.nextInputJson = (nextInput != null) ? JSON.serialize(nextInput) : null;
    r.newCorrelationKey = null;
    return r;
  }

  public static StepResult continueAsNew(Object nextInput, String customKey) {
    StepResult r = new StepResult();
    r.action = ActionType.CONTINUE_AS_NEW;
    r.nextInputJson = (nextInput != null) ? JSON.serialize(nextInput) : null;
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
}
