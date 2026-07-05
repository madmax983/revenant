public inherited sharing class StepError {
  public String failedStepName { get; private set; }
  public String errorMessage { get; private set; }
  public Integer attemptCount { get; private set; }

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
