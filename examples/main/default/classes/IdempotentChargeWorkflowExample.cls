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
  /**
   * @description Single-step workflow definition whose only step charges the card
   * using the engine's stable idempotency key.
   */
  public class ChargeWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the sole step composing this workflow.
     * @return A one-element list naming the charge-payment step.
     */
    public List<String> getSteps() {
      return new List<String>{
        'IdempotentChargeWorkflowExample.ChargePaymentStep'
      };
    }

    /**
     * @description Returns the step the workflow begins with.
     * @return The charge-payment step name.
     */
    public String getInitialStep() {
      return 'IdempotentChargeWorkflowExample.ChargePaymentStep';
    }

    /**
     * @description Terminal single-step workflow: there is no successor step.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, ending the workflow after the charge step.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null; // Terminal single-step workflow
    }
  }

  /**
   * Charges a card via the mock gateway, forwarding the stable idempotency key
   * so that re-execution of this same logical step never double-charges.
   */
  public class ChargePaymentStep implements WorkflowStep {
    /**
     * @description Charges the card via the mock gateway, forwarding
     * ctx.idempotencyKey so retries, re-drives, and at-least-once resumes of this
     * same logical step never double-charge.
     * @param ctx The durable step context supplying the stable idempotency key and input.
     * @return A COMPLETE result carrying the charge id, amount, and deduplication flag.
     */
    public StepResult execute(StepContext ctx) {
      Integer amountCents = 1500;
      if (String.isNotBlank(ctx.workflowInputJson)) {
        try {
          Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
            ctx.workflowInputJson
          );
          if (input.get('amountCents') != null) {
            amountCents = toIntAmount(input.get('amountCents'), amountCents);
          }
        } catch (Exception ignored) {
          // Malformed workflowInputJson: keep the default charge amount.
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

    /**
     * @description Coerces a JSON-deserialized numeric value to an Integer.
     * JSON.deserializeUntyped boxes numbers as Integer/Long/Decimal/Double depending on the
     * value, so a direct (Integer) cast can throw; each numeric type is handled so the
     * requested amount is preserved.
     * @param amountObj The boxed numeric value from JSON deserialization.
     * @param defaultAmount The fallback returned when amountObj is not a recognized numeric type.
     * @return The coerced Integer amount, or defaultAmount when the value is not numeric.
     */
    private Integer toIntAmount(Object amountObj, Integer defaultAmount) {
      if (amountObj instanceof Integer) {
        return (Integer) amountObj;
      }
      if (amountObj instanceof Long) {
        return ((Long) amountObj).intValue();
      }
      if (amountObj instanceof Decimal) {
        return ((Decimal) amountObj).intValue();
      }
      if (amountObj instanceof Double) {
        return ((Double) amountObj).intValue();
      }
      return defaultAmount;
    }
  }
}
