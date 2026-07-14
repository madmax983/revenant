/**
 * @description Attempt/retry/error metadata for a single step execution, split
 * out of StepContext. Populated by the engine during context construction and
 * from the reserved capture keys (__maxAttempts / __failedStepName /
 * __errorMessage / __attemptCount) that StepCaptures round-trips. Reached by
 * step authors and the engine via StepContext.retry(). The step's 1-based
 * `attempt` and the `isFinalAttempt()` convenience remain directly on
 * StepContext, which reads maxAttempts from here.
 */
public inherited sharing class StepRetryInfo {
  /** The maximum number of attempts permitted for this step. */
  public Integer maxAttempts { get; private set; }
  /** The cumulative count of attempts carried across re-executions. */
  public Integer attemptCount { get; private set; }
  /** In a compensation/error context, the name of the step that failed. */
  public String failedStepName { get; private set; }
  /** In a compensation/error context, the failure's error message. */
  public String errorMessage { get; private set; }

  /** True when this execution is the engine-routed timeout fallback. */
  private Boolean timeoutResume = false;

  /**
   * @description Sets the maximum attempts permitted for this step.
   * @param val The maximum attempts.
   */
  public void setMaxAttempts(Integer val) {
    this.maxAttempts = val;
  }

  /**
   * @description Sets the cumulative attempt count carried across re-executions.
   * @param val The attempt count.
   */
  public void setAttemptCount(Integer val) {
    this.attemptCount = val;
  }

  /**
   * @description Sets the name of the step that failed, for compensation/error
   * contexts.
   * @param val The failed step name.
   */
  public void setFailedStepName(String val) {
    this.failedStepName = val;
  }

  /**
   * @description Sets the failure error message, for compensation/error contexts.
   * @param val The error message.
   */
  public void setErrorMessage(String val) {
    this.errorMessage = val;
  }

  /**
   * @description Marks this execution as the engine-routed timeout fallback
   * (issue #35).
   */
  public void markTimeoutResume() {
    this.timeoutResume = true;
  }

  /**
   * @description True when this execution is the engine-routed timeout fallback
   * rather than a normal run, so a step can take its timeout-handling branch.
   * @return True if the context was built as a timeout resume.
   */
  public Boolean isTimeoutResume() {
    return timeoutResume == true;
  }
}
