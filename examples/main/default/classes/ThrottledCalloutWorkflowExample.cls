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
