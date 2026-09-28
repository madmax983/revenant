/**
 * @description Reference example for the operator retry policy (issue #103).
 * A workflow sends an order to a partner API. When the API returns 503 or
 * 429, the step returns StepResult.retry(RetryPolicy.fromConfig()). This
 * means no author policy. The operator owns the
 * pacing in the Workflow_Retry_Config__mdt record "PartnerSync".
 *
 * During an incident, the operator sets Maximum_Attempts__c to a lower value
 * in Setup. The next retry outcome uses the new value. No deploy is
 * necessary. See docs/retry-config.md.
 *
 * In production, the push is an HTTP callout, so PushOrderStep implements
 * CalloutStep.
 */
public inherited sharing class RetryConfigWorkflowExample {
  private static final String PUSH = 'RetryConfigWorkflowExample.PushOrderStep';
  private static final String CONFIRM = 'RetryConfigWorkflowExample.ConfirmSyncStep';

  /** @description Partner sync: push the order, then confirm. */
  public class PartnerSyncWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ PUSH, CONFIRM };
    }

    /**
     * @description Returns the first step.
     * @return The push step name.
     */
    public String getInitialStep() {
      return PUSH;
    }

    /**
     * @description Returns the step after the current step.
     * @param currentStepName The step that completed.
     * @param result The result of that step.
     * @return The next step name, or null at the end.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return currentStepName == PUSH ? CONFIRM : null;
    }
  }

  /**
   * @description Sends the order. A 503 requests a retry with no author
   * policy, so the operator record sets the pacing and the attempt cap.
   */
  public class PushOrderStep implements WorkflowStep, CalloutStep {
    /**
     * @description Sends the order to the partner API.
     * @param ctx The step context.
     * @return A complete result, a retry result on 503, or a fail result.
     */
    public StepResult execute(StepContext ctx) {
      Integer status = MockPartnerApi.pushOrder(ctx.idempotencyKey);
      if (status == 200) {
        return StepResult.complete(
          null,
          new Map<String, Object>{ 'status' => status }
        );
      }
      if (status == 503 || status == 429) {
        return StepResult.retry(RetryPolicy.fromConfig());
      }
      return StepResult.fail('Partner API rejected the order: HTTP ' + status);
    }
  }

  /** @description Records that the sync is complete. */
  public class ConfirmSyncStep implements WorkflowStep {
    /**
     * @description Completes the workflow.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'synced');
    }
  }
}
