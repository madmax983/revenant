/**
 * @description Immutable description of a step failure, passed to error-routing
 * workflows so they can decide how to compensate or reroute after a step exhausts
 * its retries.
 */
public inherited sharing class StepError {
  /**
   * @description The name of the step that failed.
   */
  public String failedStepName { get; private set; }
  /**
   * @description The error message captured from the failing step.
   */
  public String errorMessage { get; private set; }
  /**
   * @description The number of attempts made before the step was considered failed.
   */
  public Integer attemptCount { get; private set; }

  /**
   * @description Constructs a StepError capturing the failed step, its message, and
   * the attempt count at the point of failure.
   * @param failedStepName The name of the step that failed.
   * @param errorMessage The error message captured from the failing step.
   * @param attemptCount The number of attempts made before failure.
   */
  public StepError(
    String failedStepName,
    String errorMessage,
    Integer attemptCount
  ) {
    this.failedStepName = failedStepName;
    this.errorMessage = errorMessage;
    this.attemptCount = attemptCount;
  }
}
