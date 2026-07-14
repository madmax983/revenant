/**
 * @description Immutable directive a WorkflowStep returns to tell the engine what to do next — complete, yield, suspend, retry, sleep, split, start children, wait for approval, continue-as-new, or fail — built through the static factory methods on this class. The engine reads the resulting transition data through the grouped value object returned by directive(); step authors keep constructing results through the ergonomic factories and fluent chaining and never touch directive() (it is read-only).
 */
public inherited sharing class StepResult {
  /** @description The grouped, engine-facing transition data this result carries. */
  private StepDirective directiveData = new StepDirective();

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

  /**
   * @description Grouped, engine-facing read model of a step transition. Every datum the engine inspects to enact a StepResult lives here — scalars directly, and the retry/timeout/continue-as-new fields behind small grouped sub-objects so this type stays within the public-member limit. The enclosing StepResult exposes exactly one accessor, directive(), so this whole surface stays off StepResult's own public member count. Populated only by StepResult's own factory and fluent methods — authors never construct or mutate it directly.
   */
  public class StepDirective {
    /** @description Retry backoff/attempt data, for RETRY. Never null. */
    public RetryDirective retry = new RetryDirective();
    /** @description Durable-wait timeout data (issue #35). Never null. */
    public TimeoutDirective timeout = new TimeoutDirective();
    /** @description Continue-as-new seeding data, for CONTINUE_AS_NEW. Never null. */
    public ContinueDirective continuation = new ContinueDirective();

    /** @description The kind of transition this result requests. */
    public ActionType action { get; set; }
    /** @description The name of the next step to run, when applicable. */
    public String nextStepName { get; set; }
    /** @description The step's serialized output payload, or null. */
    public String outputJson { get; set; }
    /** @description Opaque durable step state persisted across a yield/suspend/sleep. */
    public String stepStateJson { get; set; }
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
    /** @description Child workflows to start together, for START_CHILDREN. */
    public List<ChildRequest> childRequests { get; set; }

    /**
     * @description Author-owned Platform Event records the engine publishes
     * effectively-once, coupled to this step's COMPLETE (or SPLIT) transition
     * commit (issue #64). Merged by the engine with anything the step buffered
     * via StepContext.emit(). Null when the step buffers its events through
     * StepContext.emit() instead. The emitted __e should use
     * publishBehavior=PublishAfterCommit so a rolled-back/retried/yielded
     * transition publishes nothing.
     */
    public List<SObject> outboundEvents { get; set; }

    // Explicit terminal failure (issue #37). Populated by the fail() factories: a
    // deliberate, non-retryable business failure the author returns instead of
    // throwing. failureReason is the operator-readable message; failureDataJson is
    // optional structured data serialized for downstream compensation/alerting.
    /** @description Operator-readable reason for a deliberate terminal failure. */
    public String failureReason { get; set; }
    /** @description Optional serialized structured data accompanying the failure. */
    public String failureDataJson { get; set; }
  }

  /**
   * @description Grouped retry data on a StepDirective. policy governs backoff and attempt limits; afterSeconds carries a legacy fixed-interval delay (retained for the engine read contract).
   */
  public class RetryDirective {
    /** @description The retry policy governing backoff and attempt limits. */
    public RetryPolicy policy { get; set; }
    /** @description Fixed delay in seconds for a legacy fixed-interval retry. */
    public Integer afterSeconds { get; set; }
  }

  /**
   * @description Grouped durable-wait timeout data on a StepDirective. When seconds is set, the engine arms Sleep_Until__c and routes to step if the deadline elapses before a signal/approval.
   */
  public class TimeoutDirective {
    /** @description Deadline in seconds for a durable wait before routing to step. */
    public Integer seconds { get; set; }
    /** @description Step to route to when the durable wait deadline elapses. */
    public String step { get; set; }
  }

  /**
   * @description Grouped continue-as-new data on a StepDirective. nextInputJson seeds the continued instance; newCorrelationKey optionally assigns it a custom correlation key.
   */
  public class ContinueDirective {
    /** @description Serialized input seeding the continued-as-new instance. */
    public String nextInputJson { get; set; }
    /** @description Custom correlation key for the continued-as-new instance. */
    public String newCorrelationKey { get; set; }
  }

  /**
   * @description Returns the grouped, read-only transition data the engine inspects to enact this result (e.g. result.directive().action, result.directive().outputJson, result.directive().retry.policy, result.directive().timeout.step). Step authors do not call this — they build results through the static factories and fluent methods.
   * @return The StepDirective carrying this result's transition data.
   */
  public StepDirective directive() {
    return this.directiveData;
  }

  /**
   * @description Completes the step, optionally routing to a named next step and carrying a serialized output payload.
   * @param nextStepName The name of the next step to run, or null to let the definition decide.
   * @param output The step output to serialize, or null for no output.
   * @return A COMPLETE result carrying the next step and serialized output.
   */
  public static StepResult complete(String nextStepName, Object output) {
    StepResult r = new StepResult();
    r.directiveData.action = ActionType.COMPLETE;
    r.directiveData.nextStepName = nextStepName;
    r.directiveData.outputJson = (output != null)
      ? JSON.serialize(output)
      : null;
    return r;
  }

  /**
   * @description Yields control back to the engine to re-drive the same step in a fresh transaction, persisting the given durable state so long-running work stays within limits.
   * @param stepStateJson Opaque durable state carried into the next re-drive.
   * @return A YIELD result carrying the persisted step state.
   */
  public static StepResult yield(String stepStateJson) {
    StepResult r = new StepResult();
    r.directiveData.action = ActionType.YIELD;
    r.directiveData.stepStateJson = stepStateJson;
    return r;
  }

  /**
   * @description Suspends the step indefinitely to await an external signal or approval. To persist durable state while suspended, chain withStepState(json).
   * @return A SUSPEND result with no persisted state or timeout.
   */
  public static StepResult suspend() {
    StepResult r = new StepResult();
    r.directiveData.action = ActionType.SUSPEND;
    return r;
  }

  /**
   * @description Suspends the step with a durable timeout, routing to timeoutStep if the deadline elapses before a signal or approval arrives.
   * @param timeoutSeconds Positive number of seconds before the wait times out.
   * @param timeoutStep The non-blank step to route to on timeout.
   * @return A SUSPEND result armed with the timeout and timeout step.
   */
  public static StepResult suspend(Integer timeoutSeconds, String timeoutStep) {
    StepResultValidator.requirePositiveTimeout(
      timeoutSeconds,
      timeoutStep,
      'StepResult.suspend'
    );
    StepResult r = new StepResult();
    r.directiveData.action = ActionType.SUSPEND;
    r.directiveData.timeout.seconds = timeoutSeconds;
    r.directiveData.timeout.step = timeoutStep;
    return r;
  }

  /**
   * @description Requests a retry of the step governed by the given retry policy's backoff and attempt limits. For a legacy fixed delay, pass new RetryPolicy(seconds, 1.0, 5).
   * @param policy The non-null retry policy controlling delay and max attempts.
   * @return A RETRY result carrying the retry policy.
   */
  public static StepResult retry(RetryPolicy policy) {
    StepResultValidator.requireNonNull(
      policy,
      'StepResult.retry: policy must not be null'
    );
    StepResult r = new StepResult();
    r.directiveData.action = ActionType.RETRY;
    r.directiveData.retry.policy = policy;
    return r;
  }

  /**
   * @description Sleeps durably for the given number of seconds before the engine resumes the step. To persist durable state across the wait, chain withStepState(json).
   * @param seconds The non-negative number of seconds to sleep.
   * @return A SLEEP result carrying the sleep duration.
   */
  public static StepResult sleep(Integer seconds) {
    StepResultValidator.requireNonNegativeSeconds(
      seconds,
      'StepResult.sleep: seconds must be a non-negative integer'
    );
    StepResult r = new StepResult();
    r.directiveData.action = ActionType.SLEEP;
    r.directiveData.sleepDurationSeconds = seconds;
    return r;
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
    StepResult result = new StepResult();
    result.directiveData.action = ActionType.SLEEP;
    result.directiveData.sleepDurationSeconds = BusinessSleepCalculator.computeSeconds(
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
    this.directiveData.stepStateJson = stepStateJson;
    return this;
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
    StepResultValidator.requireNonBlank(
      childWorkflowName,
      'StepResult.startChild: childWorkflowName must not be blank'
    );
    StepResult r = new StepResult();
    r.directiveData.action = ActionType.START_CHILD;
    r.directiveData.childWorkflowName = childWorkflowName;
    r.directiveData.childCorrelationKey = childCorrelationKey;
    r.directiveData.childInputJson = StepResultJson.serialize(input);
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
      StepResultValidator.requireNonBlank(
        workflowName,
        'ChildRequest: workflowName must not be blank'
      );
      this.workflowName = workflowName;
      this.correlationKey = correlationKey;
      this.inputJson = StepResultJson.serialize(input);
    }
  }

  /**
   * @description Starts multiple child workflows together as a fan-out, validating that the list is non-empty and contains no null entries.
   * @param children The non-empty list of child requests to start.
   * @return A START_CHILDREN result carrying the child requests.
   */
  public static StepResult startChildren(List<ChildRequest> children) {
    StepResultValidator.requireValidChildren(children);
    StepResult r = new StepResult();
    r.directiveData.action = ActionType.START_CHILDREN;
    r.directiveData.childRequests = children;
    return r;
  }

  /**
   * @description Suspends the step to wait for a human approval signal matching the given key, optionally restricted to a role.
   * @param key The non-blank approval signal key to wait on.
   * @param role The role authorized to approve, or null for any.
   * @return A WAIT_FOR_APPROVAL result carrying the approval key and role.
   */
  public static StepResult waitForApproval(String key, String role) {
    StepResultValidator.requireNonBlank(
      key,
      'StepResult.waitForApproval: key must not be blank'
    );
    StepResult r = new StepResult();
    r.directiveData.action = ActionType.WAIT_FOR_APPROVAL;
    r.directiveData.approvalKey = key;
    r.directiveData.approvalRole = role;
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
    StepResultValidator.requirePositiveTimeout(
      timeoutSeconds,
      timeoutStep,
      'StepResult.waitForApproval'
    );
    this.directiveData.timeout.seconds = timeoutSeconds;
    this.directiveData.timeout.step = timeoutStep;
    return this;
  }

  /**
   * @description Splits execution into parallel branches, one per named step, all running concurrently before the workflow joins.
   * @param stepNames The non-empty list of step names to run in parallel.
   * @return A SPLIT result carrying the parallel step names.
   */
  public static StepResult split(List<String> stepNames) {
    StepResultValidator.requireValidStepNames(stepNames);
    StepResult r = new StepResult();
    r.directiveData.action = ActionType.SPLIT;
    r.directiveData.parallelStepNames = stepNames;
    return r;
  }

  /**
   * @description Splits execution into parallel branches, one per named step, sharing the given serialized input across all branches.
   * @param stepNames The non-empty list of step names to run in parallel.
   * @param input The shared branch input, serialized if needed.
   * @return A SPLIT result carrying the parallel step names and shared input.
   */
  public static StepResult split(List<String> stepNames, Object input) {
    StepResultValidator.requireValidStepNames(stepNames);
    StepResult r = new StepResult();
    r.directiveData.action = ActionType.SPLIT;
    r.directiveData.parallelStepNames = stepNames;
    r.directiveData.parallelInputJson = StepResultJson.serialize(input);
    return r;
  }

  /**
   * @description Continues the workflow as a fresh instance seeded with the given input, carrying over the current correlation key, to bound history growth on long-running loops.
   * @param nextInput The input seeding the continued instance, serialized if needed.
   * @return A CONTINUE_AS_NEW result carrying the next input.
   */
  public static StepResult continueAsNew(Object nextInput) {
    StepResult r = new StepResult();
    r.directiveData.action = ActionType.CONTINUE_AS_NEW;
    r.directiveData.continuation.nextInputJson = StepResultJson.serialize(
      nextInput
    );
    r.directiveData.continuation.newCorrelationKey = null;
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
    r.directiveData.action = ActionType.CONTINUE_AS_NEW;
    r.directiveData.continuation.nextInputJson = StepResultJson.serialize(
      nextInput
    );
    r.directiveData.continuation.newCorrelationKey = customKey;
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
    StepResultValidator.requireNonBlank(
      reason,
      'StepResult.fail: reason must not be blank'
    );
    StepResult r = new StepResult();
    r.directiveData.action = ActionType.FAIL;
    r.directiveData.failureReason = reason;
    r.directiveData.failureDataJson = (failureData != null)
      ? JSON.serialize(failureData)
      : null;
    return r;
  }
}
