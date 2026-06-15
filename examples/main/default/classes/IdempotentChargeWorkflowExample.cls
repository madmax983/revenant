/**
 * Reference example for issue #2: forwarding the engine-supplied, per-step
 * stable `StepContext.idempotencyKey` to an external system to obtain
 * effective-once side effects on top of the engine's at-least-once execution
 * contract.
 *
 * The non-idempotent side effect here is "charge a credit card". The step
 * forwards `ctx.idempotencyKey` to a mock gateway exactly as an author would
 * forward it as a Stripe `Idempotency-Key` header. Because the key is identical
 * across every re-execution of the same logical (instance, step) -- transient
 * RetryPolicy/WorkflowRetryJob retries, operator re-drive (#1), and at-least-once
 * Workflow_Event__e resumes -- the gateway dedupes repeat calls and only one
 * effective charge is ever made.
 */
public inherited sharing class IdempotentChargeWorkflowExample {
  public class ChargeWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'IdempotentChargeWorkflowExample.ChargePaymentStep'
      };
    }

    public String getInitialStep() {
      return 'IdempotentChargeWorkflowExample.ChargePaymentStep';
    }

    public String getNextStep(String currentStepName, StepResult result) {
      return null; // Terminal single-step workflow
    }
  }

  /**
   * Charges a card via the mock gateway, forwarding the stable idempotency key
   * so that re-execution of this same logical step never double-charges.
   */
  public class ChargePaymentStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Integer amountCents = 1500;
      if (String.isNotBlank(ctx.workflowInputJson)) {
        try {
          Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
            ctx.workflowInputJson
          );
          if (input.containsKey('amountCents')) {
            amountCents = (Integer) input.get('amountCents');
          }
        } catch (Exception ex) {
          // Fall back to the default amount.
        }
      }

      // The whole point of issue #2: read one field and forward it. No
      // hand-rolled token off Datetime.now(), a random UUID, or the per-attempt
      // step-execution record Id (all of which change between attempts).
      MockIdempotentPaymentGateway.ChargeResult res = MockIdempotentPaymentGateway.charge(
        ctx.idempotencyKey,
        amountCents
      );

      return StepResult.complete(
        null,
        new Map<String, Object>{
          'chargeId' => res.chargeId,
          'amountCents' => amountCents,
          'deduplicated' => res.deduplicated
        }
      );
    }
  }
}
