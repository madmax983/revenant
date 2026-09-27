/**
 * @description Optional contract for auto-retry of thrown errors (issue #101).
 * A `WorkflowStep` or a `WorkflowDefinition` implements it to set a default
 * `RetryPolicy` for a catchable exception that `execute()` throws. The engine
 * then retries the step with backoff. The workflow fails only when the policy
 * is exhausted. A step policy overrides a definition policy. A returned
 * `StepResult` (for example `fail()` or `retry()`) always overrides this policy.
 * A step that has a policy must be safe to run again: DML done before the throw
 * is kept.
 */
public interface AutoRetryConfigurable {
  /**
   * @description Returns the default retry policy for thrown errors.
   * @return The policy, or null to fail fast on a throw.
   */
  RetryPolicy getAutoRetryPolicy();
}
