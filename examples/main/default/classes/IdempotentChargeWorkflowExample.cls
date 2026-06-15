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

  /**
   * Stands in for a Stripe-style idempotent endpoint: it records exactly one
   * effective side effect per distinct Idempotency-Key. A repeat call carrying a
   * key it has already seen returns the prior charge WITHOUT charging again.
   */
  public class MockIdempotentPaymentGateway {
    // Counts only true (effective) side effects -- i.e. first-seen keys.
    public static Integer effectiveSideEffectCount = 0;
    private static Map<String, String> chargeIdByKey = new Map<String, String>();
    private static Integer sequence = 0;

    public class ChargeResult {
      public String chargeId;
      public Boolean deduplicated;

      public ChargeResult(String chargeId, Boolean deduplicated) {
        this.chargeId = chargeId;
        this.deduplicated = deduplicated;
      }
    }

    public static ChargeResult charge(String idempotencyKey, Integer amountCents) {
      if (
        String.isNotBlank(idempotencyKey) &&
        chargeIdByKey.containsKey(idempotencyKey)
      ) {
        // Server-side dedup on the caller-supplied key: no new side effect.
        return new ChargeResult(chargeIdByKey.get(idempotencyKey), true);
      }
      // First time we have seen this key: the one real, effective charge.
      effectiveSideEffectCount++;
      sequence++;
      String chargeId = 'ch_' + sequence;
      if (String.isNotBlank(idempotencyKey)) {
        chargeIdByKey.put(idempotencyKey, chargeId);
      }
      return new ChargeResult(chargeId, false);
    }

    @TestVisible
    private static void reset() {
      effectiveSideEffectCount = 0;
      chargeIdByKey = new Map<String, String>();
      sequence = 0;
    }
  }
}
