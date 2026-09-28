/**
 * @description Optional contract for auto-retry of thrown exceptions (issue
 * #101). A `WorkflowStep` or a `WorkflowDefinition` implements it to set a
 * default `RetryPolicy` for a catchable exception that `execute()` throws. The
 * engine then retries the step with backoff. The workflow fails only when all
 * attempts fail. A step policy has priority over a definition policy. A
 * returned `StepResult`, for example `fail()` or `retry()`, has priority over
 * this policy. The engine undoes the step DML before the retry. It does not
 * undo DML in a `CalloutStep`, so make that step safe to run again.
 */
global interface AutoRetryConfigurable {
  /**
   * @description Returns the default retry policy for thrown exceptions.
   * @return The policy, or null to fail fast on a thrown exception.
   */
  RetryPolicy getAutoRetryPolicy();
}
