/**
 * @description Value object describing a step's retry behavior: the first back-off interval,
 * the multiplier applied to each successive interval, and the maximum number of
 * attempts before the step is treated as failed.
 */
public inherited sharing class RetryPolicy {
  // True when the author gives no policy and the operator record decides.
  private Boolean configManaged = false;

  /** @description Seconds to wait before the first retry attempt. */
  public Integer initialIntervalSeconds { get; set; }
  /** @description Multiplier applied to the wait interval after each attempt. */
  public Double backoffCoefficient { get; set; }
  /** @description Maximum number of attempts before the step is considered failed. */
  public Integer maximumAttempts { get; set; }

  /**
   * @description Builds a retry policy with the engine defaults (5s initial interval,
   * 2.0 back-off coefficient, 5 maximum attempts).
   */
  public RetryPolicy() {
    this.initialIntervalSeconds = 5;
    this.backoffCoefficient = 2.0;
    this.maximumAttempts = 5;
  }

  /**
   * @description Builds a retry policy with explicit back-off settings.
   * @param initialIntervalSeconds Seconds to wait before the first retry attempt.
   * @param backoffCoefficient Multiplier applied to the wait interval after each attempt.
   * @param maximumAttempts Maximum number of attempts before the step is considered failed.
   */
  public RetryPolicy(
    Integer initialIntervalSeconds,
    Double backoffCoefficient,
    Integer maximumAttempts
  ) {
    this.initialIntervalSeconds = initialIntervalSeconds;
    this.backoffCoefficient = backoffCoefficient;
    this.maximumAttempts = maximumAttempts;
  }

  /**
   * @description Returns a policy that the operator controls (issue #103). The
   * engine uses the matching Workflow_Retry_Config__mdt record. With no
   * record, it uses the engine default (5 s, 2.0, 5 attempts). See
   * docs/retry-config.md.
   * @return A policy with the engine default values and no author values.
   */
  public static RetryPolicy fromConfig() {
    RetryPolicy policy = new RetryPolicy();
    policy.configManaged = true;
    return policy;
  }

  /**
   * @description Returns true for a policy from `fromConfig()`. The engine
   * then treats the step as a step with no author policy.
   * @return True when the operator record decides the policy.
   */
  public Boolean isFromConfig() {
    return configManaged == true;
  }
}
