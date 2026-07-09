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

  public static void performCallout(String idempotencyKey) {
    calloutAttempts++;
    if (processedKeys.contains(idempotencyKey)) {
      return;
    }
    processedKeys.add(idempotencyKey);
    successfulCallouts++;
  }

  public static void reset() {
    calloutAttempts = 0;
    successfulCallouts = 0;
    processedKeys.clear();
  }

  public class ThrottledCalloutWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'ThrottledCalloutWorkflowExample.AcquireTokenStep',
        'ThrottledCalloutWorkflowExample.ThrottledCalloutStep'
      };
    }
    public String getInitialStep() {
      return 'ThrottledCalloutWorkflowExample.AcquireTokenStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      if (
        currentStepName == 'ThrottledCalloutWorkflowExample.AcquireTokenStep'
      ) {
        return 'ThrottledCalloutWorkflowExample.ThrottledCalloutStep';
      }
      return null;
    }
  }

  public class AcquireTokenStep implements WorkflowStep {
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

  public class ThrottledCalloutStep implements WorkflowStep, CalloutStep {
    public StepResult execute(StepContext ctx) {
      ThrottledCalloutWorkflowExample.performCallout(ctx.idempotencyKey);
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'status' => 'Success' }
      );
    }
  }
}
