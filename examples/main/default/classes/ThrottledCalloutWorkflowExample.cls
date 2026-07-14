/**
 * Reference example for durable rate limiting.
 *
 * Demonstrates a safe two-step pattern to throttle outbound callouts:
 *   1. AcquireTokenStep: Calls RateLimiter.acquire(). If allowed, transitions to the callout step.
 *      If blocked, yields a durable sleep. This commits the DML in a separate transaction.
 *   2. ThrottledCalloutStep: Executes the callout using ctx.idempotencyKey.
 *      Runs in a fresh transaction, avoiding System.CalloutException (uncommitted work pending).
 *
 * Note on Retries & Re-drives:
 * ----------------------------
 * When a callout fails (e.g. transient network error) and is retried via a RetryPolicy,
 * or when an operator manually re-drives the ThrottledCalloutStep from the dashboard,
 * the engine re-executes ThrottledCalloutStep directly, bypassing AcquireTokenStep.
 *
 * This is the intended behavior:
 *   - Transaction Safety: AcquireTokenStep performs DML (RateLimiter.acquire), while
 *     ThrottledCalloutStep performs the HTTP Callout. Apex prohibits HTTP Callouts after
 *     DML in the same transaction, so they must be separated.
 *   - Built-in Back-off: Callout retries are already throttled by the step's own
 *     RetryPolicy back-off delay (which sleeps durably between attempts).
 *
 * If you must enforce rate-limiting on every single callout retry, you can handle
 * callout exceptions in ThrottledCalloutStep and return a transition back to
 * AcquireTokenStep instead of using the engine's built-in RetryPolicy.
 */
public inherited sharing class ThrottledCalloutWorkflowExample {
  public static Integer calloutAttempts = 0;
  public static Integer successfulCallouts = 0;
  private static Set<String> processedKeys = new Set<String>();

  /**
   * @description Simulates the throttled outbound callout, counting every attempt
   * and recording a successful call only once per idempotency key.
   * @param idempotencyKey The key that makes the callout effectively-once.
   */
  public static void performCallout(String idempotencyKey) {
    calloutAttempts++;
    if (processedKeys.contains(idempotencyKey)) {
      return;
    }
    processedKeys.add(idempotencyKey);
    successfulCallouts++;
  }

  /**
   * @description Resets the callout counters and processed-key set so tests start
   * from a clean state.
   */
  public static void reset() {
    calloutAttempts = 0;
    successfulCallouts = 0;
    processedKeys.clear();
  }

  /**
   * @description Two-step workflow DAG: acquire a rate-limiter token, then perform
   * the callout in a separate transaction.
   */
  public class ThrottledCalloutWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the ordered step names in this workflow.
     * @return The step names in execution order.
     */
    public List<String> getSteps() {
      return new List<String>{
        'ThrottledCalloutWorkflowExample.AcquireTokenStep',
        'ThrottledCalloutWorkflowExample.ThrottledCalloutStep'
      };
    }
    /**
     * @description Names the first step to run when an instance starts.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return 'ThrottledCalloutWorkflowExample.AcquireTokenStep';
    }
    /**
     * @description Determines the step to run after the current one completes.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return The callout step after acquiring a token, or null when complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (
        currentStepName == 'ThrottledCalloutWorkflowExample.AcquireTokenStep'
      ) {
        return 'ThrottledCalloutWorkflowExample.ThrottledCalloutStep';
      }
      return null;
    }
  }

  /**
   * @description Acquires a rate-limiter token; on success advances to the callout
   * step, otherwise yields a durable sleep so the DML commits in its own transaction.
   */
  public class AcquireTokenStep implements WorkflowStep {
    /**
     * @description Calls the rate limiter and either sleeps until a token frees up or
     * transitions to the throttled callout step.
     * @param ctx The durable step context for this execution.
     * @return A sleep result when throttled, or completion routing to the callout.
     */
    public StepResult execute(StepContext ctx) {
      RateLimiter.AcquireResult result = RateLimiter.acquire(
        'ThrottledService'
      );
      if (!result.isAllowed) {
        return StepResult.sleep(result.sleepDurationSeconds);
      }
      return StepResult.complete(
        'ThrottledCalloutWorkflowExample.ThrottledCalloutStep',
        null
      );
    }
  }

  /**
   * @description Performs the outbound callout in a fresh transaction, keyed by the
   * step's idempotency key so retries and re-drives stay effectively-once.
   */
  public class ThrottledCalloutStep implements WorkflowStep, CalloutStep {
    /**
     * @description Executes the idempotent callout and completes the workflow.
     * @param ctx The durable step context for this execution.
     * @return A completion result reporting success.
     */
    public StepResult execute(StepContext ctx) {
      ThrottledCalloutWorkflowExample.performCallout(ctx.idempotencyKey);
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'status' => 'Success' }
      );
    }
  }
}
