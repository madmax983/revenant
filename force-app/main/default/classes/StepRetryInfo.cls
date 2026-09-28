/**
 * @description Attempt/retry/error metadata for a single step execution, split
 * out of StepContext. Populated by the engine during context construction and
 * from the reserved capture keys (__maxAttempts / __failedStepName /
 * __errorMessage / __attemptCount) that StepCaptures round-trips. Reached by
 * step authors and the engine via StepContext.retry(). The step's 1-based
 * `attempt` and the `isFinalAttempt()` convenience remain directly on
 * StepContext, which reads maxAttempts from here.
 */
global inherited sharing class StepRetryInfo {
  /**
   * @description Keeps construction in the package namespace. Without an
   * explicit constructor, a global class gets a global default
   * constructor (issue #122).
   */
  public StepRetryInfo() {
    // No state to set.
  }

  /** The maximum number of attempts permitted for this step. */
  global Integer maxAttempts { get; private set; }
  /** The cumulative count of attempts carried across re-executions. */
  global Integer attemptCount { get; private set; }
  /** In a compensation/error context, the name of the step that failed. */
  global String failedStepName { get; private set; }
  /** In a compensation/error context, the failure's error message. */
  global String errorMessage { get; private set; }

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
  global Boolean isTimeoutResume() {
    return timeoutResume == true;
  }
}
