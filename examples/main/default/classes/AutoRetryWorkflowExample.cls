/**
 * @description Reference example for auto-retry of thrown exceptions (issue
 * #101). An order saga reserves stock, charges a card and sends a receipt.
 *
 * OrderSaga implements AutoRetryConfigurable. When a step throws (for example a
 * 503 from the payment gateway), the engine retries the step with backoff. A
 * short outage does not roll back the saga. ChargePaymentStep has no try/catch.
 * When all 4 charge attempts fail, the saga rolls back (LIFO). The idempotency
 * key stops a second charge when the gateway charged but the response was lost.
 *
 * SendReceiptStep returns a null policy. A receipt email is not idempotent, so
 * a thrown exception there fails fast.
 *
 * In production, the charge is an HTTP callout. Then ChargePaymentStep must
 * implement CalloutStep. The engine sets a savepoint before execute(), and a
 * savepoint blocks a callout.
 */
public inherited sharing class AutoRetryWorkflowExample {
  private static final String RESERVE = 'AutoRetryWorkflowExample.ReserveInventoryStep';
  private static final String CHARGE = 'AutoRetryWorkflowExample.ChargePaymentStep';
  private static final String RECEIPT = 'AutoRetryWorkflowExample.SendReceiptStep';

  /**
   * @description Order saga: reserve, charge, receipt. It sets the default
   * retry policy for thrown exceptions.
   */
  public class OrderSaga implements WorkflowDefinition, AutoRetryConfigurable {
    /**
     * @description Returns the saga steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ RESERVE, CHARGE, RECEIPT };
    }

    /**
     * @description Returns the first step.
     * @return The reserve step name.
     */
    public String getInitialStep() {
      return RESERVE;
    }

    /**
     * @description Returns the step after the current step.
     * @param currentStepName The step that completed.
     * @param result The result of that step.
     * @return The next step name, or null at the end.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == RESERVE) {
        return CHARGE;
      }
      if (currentStepName == CHARGE) {
        return RECEIPT;
      }
      return null;
    }

    /**
     * @description Returns the default policy for thrown exceptions: 4
     * attempts, with 30 s, 60 s and 120 s between them.
     * @return The policy.
     */
    public RetryPolicy getAutoRetryPolicy() {
      return new RetryPolicy(30, (Double) 2.0, 4);
    }
  }

  /** @description Reserves stock. Compensation releases it. */
  public class ReserveInventoryStep implements CompensatableStep {
    /**
     * @description Reserves stock for the order.
     * @param ctx The step context.
     * @return A complete result with the reservation id.
     */
    public StepResult execute(StepContext ctx) {
      String orderId = (String) readInput(ctx).get('orderId');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'reservationId' => 'RES-' + orderId }
      );
    }

    /**
     * @description Releases the reservation.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'released' => true }
      );
    }
  }

  /**
   * @description Charges the card. It has no try/catch: the definition policy
   * retries a gateway error. The idempotency key stops a double charge.
   */
  public class ChargePaymentStep implements CompensatableStep {
    /**
     * @description Charges the card. A gateway error throws.
     * @param ctx The step context.
     * @return A complete result with the charge id.
     */
    public StepResult execute(StepContext ctx) {
      Integer amountCents = toCents(readInput(ctx).get('amountCents'));
      String chargeId = MockFlakyOrderServices.charge(
        ctx.idempotencyKey,
        amountCents
      );
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'chargeId' => chargeId }
      );
    }

    /**
     * @description Refunds the charge from the step output.
     * @param ctx The step context. stepStateJson holds the step output.
     * @return A complete result.
     */
    public StepResult compensate(StepContext ctx) {
      Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.stepStateJson
      );
      MockFlakyOrderServices.refund((String) output.get('chargeId'));
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'refunded' => true }
      );
    }
  }

  /**
   * @description Sends the receipt. It opts out of auto-retry, because a
   * second email is a duplicate.
   */
  public class SendReceiptStep implements WorkflowStep, AutoRetryConfigurable {
    /**
     * @description Sends the receipt email.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      MockFlakyOrderServices.sendReceipt(
        (String) readInput(ctx).get('orderId')
      );
      return StepResult.complete(null, 'sent');
    }

    /**
     * @description Returns null: a thrown exception fails fast.
     * @return Null.
     */
    public RetryPolicy getAutoRetryPolicy() {
      return null;
    }
  }

  // Returns the amount in cents. A Flow or a numeric field can give a Decimal
  // such as 4200.00, so do not use Integer.valueOf on the text.
  private static Integer toCents(Object amount) {
    return Decimal.valueOf(String.valueOf(amount)).intValue();
  }

  // Reads the workflow input map.
  private static Map<String, Object> readInput(StepContext ctx) {
    return (Map<String, Object>) JSON.deserializeUntyped(ctx.workflowInputJson);
  }
}
