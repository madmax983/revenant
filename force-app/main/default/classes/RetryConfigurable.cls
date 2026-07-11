/**
 * @description Implemented by a WorkflowStep that supplies its own RetryPolicy,
 * letting the engine override the default backoff/attempt limits when the step
 * returns a retry result.
 */
public interface RetryConfigurable {
  /**
   * @description Returns the RetryPolicy governing this step's retry attempts,
   * including maximum attempts, initial interval, and backoff coefficient.
   * @return The RetryPolicy the engine applies to this step's retries.
   */
  RetryPolicy getRetryPolicy();
}
