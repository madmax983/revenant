/**
 * Reference example for issue #141: a branching workflow for the topology
 * graph. It has three decision points.
 *
 * Shape:
 *   ValidateOrderStep
 *     low risk  -> ReserveStockStep
 *     high risk -> ManualReviewStep (waits for approval)
 *                    approve -> ReserveStockStep
 *                    reject  -> CancelOrderStep -> end
 *   ReserveStockStep (rollback)
 *     in stock     -> ChargePaymentStep (rollback) -> ShipStep -> end
 *     out of stock -> BackorderStep -> end
 *
 * The routes depend on step output. The graph probe finds only the default
 * routes. The graph shows the other steps as "not reached" and tells the
 * operator that the routing is not fully known. The review router fails
 * closed: an unknown decision throws. The graph shows it as "routing not
 * known", not as an end.
 */
public inherited sharing class BranchingOrderWorkflowExample implements WorkflowDefinition {
  /** Approval key of the manual review. */
  public static final String REVIEW_KEY = 'OrderReview';
  /** The signal that gives the review decision. */
  public static final String REVIEW_SIGNAL = 'Approve:' + REVIEW_KEY;
  /** Orders at or above this amount need a manual review. */
  public static final Decimal REVIEW_THRESHOLD = 10000;

  private static final String PREFIX = 'BranchingOrderWorkflowExample.';
  private static final String VALIDATE = PREFIX + 'ValidateOrderStep';
  private static final String REVIEW = PREFIX + 'ManualReviewStep';
  private static final String RESERVE = PREFIX + 'ReserveStockStep';
  private static final String CHARGE = PREFIX + 'ChargePaymentStep';
  private static final String SHIP = PREFIX + 'ShipStep';
  private static final String BACKORDER = PREFIX + 'BackorderStep';
  private static final String CANCEL = PREFIX + 'CancelOrderStep';

  /**
   * @description Declares the steps.
   * @return The step names.
   */
  public List<String> getSteps() {
    return new List<String>{
      VALIDATE,
      REVIEW,
      RESERVE,
      CHARGE,
      SHIP,
      BACKORDER,
      CANCEL
    };
  }

  /**
   * @description Names the first step.
   * @return The ValidateOrderStep name.
   */
  public String getInitialStep() {
    return VALIDATE;
  }

  /**
   * @description Routes the steps. Three routes depend on the step output.
   * @param currentStepName The step that completed.
   * @param result The result of that step.
   * @return The next step, or null at the end.
   */
  public String getNextStep(String currentStepName, StepResult result) {
    Map<String, Object> out = outputOf(result);
    if (currentStepName == VALIDATE) {
      return out.get('needsReview') == true ? REVIEW : RESERVE;
    }
    if (currentStepName == REVIEW) {
      return routeReview(out.get('decision'));
    }
    if (currentStepName == RESERVE) {
      return out.get('inStock') == false ? BACKORDER : CHARGE;
    }
    if (currentStepName == CHARGE) {
      return SHIP;
    }
    return null;
  }

  // Fails closed: an unknown decision must not pick a route.
  private static String routeReview(Object decision) {
    if (decision == 'approve') {
      return RESERVE;
    }
    if (decision == 'reject') {
      return CANCEL;
    }
    throw new IllegalArgumentException(
      'Unknown review decision: ' + String.valueOf(decision)
    );
  }

  private static Map<String, Object> outputOf(StepResult result) {
    return parse(result == null ? null : result.directive().outputJson);
  }

  private static Map<String, Object> parse(String jsonText) {
    if (String.isBlank(jsonText)) {
      return new Map<String, Object>();
    }
    Object parsed = JSON.deserializeUntyped(jsonText);
    return parsed instanceof Map<String, Object>
      ? (Map<String, Object>) parsed
      : new Map<String, Object>();
  }

  private static Map<String, Object> input(StepContext ctx) {
    return parse(ctx.workflowInputJson);
  }

  // --- STEPS ---

  /** Decision 1: a large order needs a manual review. */
  public class ValidateOrderStep implements WorkflowStep {
    /**
     * @description Flags an order at or above the threshold for review.
     * @param ctx The step context.
     * @return A complete result with needsReview.
     */
    public StepResult execute(StepContext ctx) {
      Object amount = input(ctx).get('amount');
      Decimal value = amount == null
        ? 0
        : Decimal.valueOf(String.valueOf(amount));
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'needsReview' => value >= REVIEW_THRESHOLD }
      );
    }
  }

  /** Decision 2: an approver approves or rejects the order. */
  public class ManualReviewStep implements WorkflowStep {
    /**
     * @description Waits for the review signal, then gives the decision.
     * @param ctx The step context.
     * @return A wait result, or a complete result with the decision.
     */
    public StepResult execute(StepContext ctx) {
      StepContext.Signal signal = ctx.signals().getSignal(REVIEW_SIGNAL);
      if (!signal.isPresent()) {
        return StepResult.waitForApproval(REVIEW_KEY, null);
      }
      return StepResult.complete(null, parse(signal.payload));
    }
  }

  /** Decision 3: reserves stock. Rollback releases it. */
  public class ReserveStockStep implements CompensatableStep {
    /**
     * @description Reserves stock and tells if it is in stock.
     * @param ctx The step context.
     * @return A complete result with inStock.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'inStock' => input(ctx).get('inStock') != false
        }
      );
    }
    /**
     * @description Releases the stock.
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

  /** Charges the payment. Rollback refunds it. */
  public class ChargePaymentStep implements CompensatableStep {
    /**
     * @description Charges the payment.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'charged' => true }
      );
    }
    /**
     * @description Refunds the payment.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'refunded' => true }
      );
    }
  }

  /** Ships the order. The run ends. */
  public class ShipStep implements WorkflowStep {
    /**
     * @description Ships the order.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'shipped' => true }
      );
    }
  }

  /** Puts the order on backorder. The run ends. */
  public class BackorderStep implements WorkflowStep {
    /**
     * @description Records the backorder.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'backordered' => true }
      );
    }
  }

  /** Cancels a rejected order. The run ends. */
  public class CancelOrderStep implements WorkflowStep {
    /**
     * @description Records the cancel.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'cancelled' => true }
      );
    }
  }
}
