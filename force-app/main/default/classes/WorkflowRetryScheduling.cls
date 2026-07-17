/**
 * @description Retry persistence and exponential-backoff scheduling surface for
 * the Revenant engine. Sanitizes an author-supplied `RetryPolicy` to the engine's
 * safe floor, merges the sanitized maximum-attempts into a step's captured values,
 * and reschedules a not-yet-exhausted attempt by marking the step Retrying,
 * suspending the instance for the capped backoff delay and arming the retry job.
 * Extracted from `WorkflowEngine`; step-execution flushes are delegated to
 * {@link WorkflowStepExecStore}. All DML executes in system mode.
 */
public inherited sharing class WorkflowRetryScheduling {
  /**
   * @description Shared retry persistence: merges the sanitized policy's
   * maximumAttempts into the step's captured values and re-offloads them.
   * Extracted from the forward and compensation retry paths, which persisted
   * identical captures state before diverging on the retries-exhausted branch.
   * Behavior is byte-identical to the inlined blocks. Public so the extracted
   * outcome retry handler can invoke it, called qualified.
   * @param instance the workflow instance owning the step
   * @param stepExec the step execution whose captured values are updated
   * @param policy the sanitized retry policy whose maximumAttempts is persisted
   */
  public static void persistRetryMaxAttempts(
    Workflow_Instance__c instance,
    Workflow_Step_Execution__c stepExec,
    RetryPolicy policy
  ) {
    Map<String, Object> captures = new Map<String, Object>();
    if (String.isNotBlank(stepExec.Captured_Values__c)) {
      String resolvedCaptures = WorkflowPayloadOffload.resolvePayload(
        stepExec.Captured_Values__c
      );
      if (String.isNotBlank(resolvedCaptures)) {
        try {
          captures = (Map<String, Object>) JSON.deserializeUntyped(
            resolvedCaptures
          );
        } catch (Exception ignored) {
          // Malformed captures; proceed with an empty captures map.
        }
      }
    }
    captures.put('__maxAttempts', policy.maximumAttempts);
    stepExec.Captured_Values__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      JSON.serialize(captures),
      'Captures_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
  }

  /**
   * @description Shared exponential-backoff reschedule: marks the step Retrying,
   * computes the capped backoff delay, suspends the instance and arms the retry
   * job. Extracted from the not-yet-exhausted branch of the forward and
   * compensation retry paths, which scheduled the next attempt identically.
   * Behavior is byte-identical to the inlined else-branches. Public so the
   * extracted outcome retry handler can invoke it, called qualified.
   * @param instance the workflow instance to suspend until the next attempt
   * @param stepExec the step execution being rescheduled
   * @param policy the sanitized retry policy driving the backoff computation
   */
  public static void scheduleExponentialRetry(
    Workflow_Instance__c instance,
    Workflow_Step_Execution__c stepExec,
    RetryPolicy policy
  ) {
    stepExec.Status__c = 'Retrying';
    stepExec.Output__c = null;
    WorkflowStepExecStore.saveStepExec(stepExec);

    // Calculate exponential backoff
    Double backoff = Math.pow(
      (Double) policy.backoffCoefficient,
      (Double) (stepExec.Retry_Count__c - 1)
    );
    Integer delay = (Integer) (policy.initialIntervalSeconds * backoff);
    delay = Math.min(delay, 86400);

    instance.Status__c = 'Suspended';
    instance.Sleep_Until__c = DateTime.now().addSeconds(delay);
    instance.Async_Job_Id__c = WorkflowRetrySleepScheduler.scheduleRetry(
      instance.Id,
      stepExec.Step_Name__c,
      delay
    );
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
  }

  /**
   * @description Returns a retry policy with only the valid, positive fields of
   * the supplied policy applied over the defaults, so an author-supplied policy
   * can never weaken the engine below its safe retry floor. Public so the
   * extracted outcome retry handler can invoke it, called qualified.
   * @param policy the author-supplied retry policy to sanitize (may be null)
   * @return a sanitized retry policy safe for backoff scheduling
   */
  public static RetryPolicy sanitizePolicy(RetryPolicy policy) {
    RetryPolicy clean = new RetryPolicy();
    if (policy != null) {
      if (policy.maximumAttempts != null && policy.maximumAttempts > 0) {
        clean.maximumAttempts = policy.maximumAttempts;
      }
      if (
        policy.initialIntervalSeconds != null &&
        policy.initialIntervalSeconds > 0
      ) {
        clean.initialIntervalSeconds = policy.initialIntervalSeconds;
      }
      if (
        policy.backoffCoefficient != null &&
        policy.backoffCoefficient >= 1.0
      ) {
        clean.backoffCoefficient = policy.backoffCoefficient;
      }
    }
    return clean;
  }
}
