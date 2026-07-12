/**
 * Reference saga that demonstrates a RECOVERABLE compensation failure.
 *
 * The forward flow charges a card, reserves inventory, ships an order, and books
 * a courier (four compensatable steps). A final non-compensatable step then fails,
 * triggering a LIFO rollback. The third forward step's compensation (the
 * second-from-top entry on the rollback stack) fails transiently on its first
 * attempt, stranding the saga in the "rollback incomplete" (CompensationFailed)
 * condition with the deeper stack entries still un-reversed.
 *
 * After an operator resumes the rollback, the transient failure clears and every
 * remaining compensation runs in strict LIFO order, leaving the saga fully
 * Compensated. See SagaStalledRollbackExampleTest for the end-to-end walkthrough.
 */
public inherited sharing class SagaStalledRollbackExample {
  /**
   * Test/operator switch. While true, ShipOrderStep.compensate() throws to simulate
   * a transient downstream outage (e.g. the carrier API being unreachable). Flip to
   * false to represent the outage clearing before the operator resumes the rollback.
   */
  public static Boolean failShipmentCompensation = false;

  /**
   * @description Saga definition: four compensatable steps followed by a terminal step that fails, triggering a LIFO rollback.
   */
  public class StalledSagaWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the fully-qualified step names that make up this saga.
     * @return The list of fully-qualified step names in this definition.
     */
    public List<String> getSteps() {
      return new List<String>{
        'SagaStalledRollbackExample.ChargeCardStep',
        'SagaStalledRollbackExample.ReserveInventoryStep',
        'SagaStalledRollbackExample.ShipOrderStep',
        'SagaStalledRollbackExample.BookCourierStep',
        'SagaStalledRollbackExample.ConfirmDeliveryStep'
      };
    }

    /**
     * @description Names the entry-point step the engine runs first.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'SagaStalledRollbackExample.ChargeCardStep';
    }

    /**
     * @description Routes to the successor step after the current step completes.
     * @param currentStepName The step that just completed.
     * @param result The result of the completed step.
     * @return The next step name, or null when the saga has no further forward step.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'SagaStalledRollbackExample.ChargeCardStep') {
        return 'SagaStalledRollbackExample.ReserveInventoryStep';
      }
      if (
        currentStepName == 'SagaStalledRollbackExample.ReserveInventoryStep'
      ) {
        return 'SagaStalledRollbackExample.ShipOrderStep';
      }
      if (currentStepName == 'SagaStalledRollbackExample.ShipOrderStep') {
        return 'SagaStalledRollbackExample.BookCourierStep';
      }
      if (currentStepName == 'SagaStalledRollbackExample.BookCourierStep') {
        return 'SagaStalledRollbackExample.ConfirmDeliveryStep';
      }
      return null;
    }
  }

  /**
   * @description Compensatable step that charges the card; its compensation issues a refund.
   */
  public class ChargeCardStep implements CompensatableStep {
    /**
     * @description Charges the card and records the resulting charge id.
     * @param ctx The durable per-step execution context.
     * @return The step's outcome result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'chargeId' => 'ch_1001' }
      );
    }

    /**
     * @description Refunds the charge during rollback.
     * @param ctx The durable per-step execution context.
     * @return The step's outcome result.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'refundId' => 'rf_1001' }
      );
    }
  }

  /**
   * @description Compensatable step that reserves inventory; its compensation releases the reservation.
   */
  public class ReserveInventoryStep implements CompensatableStep {
    /**
     * @description Reserves inventory and records the reservation id.
     * @param ctx The durable per-step execution context.
     * @return The step's outcome result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'reservationId' => 'res_2002' }
      );
    }

    /**
     * @description Releases the inventory reservation during rollback.
     * @param ctx The durable per-step execution context.
     * @return The step's outcome result.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'released' => 'res_2002' }
      );
    }
  }

  /**
   * @description Compensatable step that ships the order; its compensation recalls the shipment and fails transiently while failShipmentCompensation is set.
   */
  public class ShipOrderStep implements CompensatableStep {
    /**
     * @description Ships the order and records the shipment id.
     * @param ctx The durable per-step execution context.
     * @return The step's outcome result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'shipmentId' => 'shp_3003' }
      );
    }

    /**
     * @description Recalls the shipment during rollback, throwing a transient failure while failShipmentCompensation is set.
     * @param ctx The durable per-step execution context.
     * @return The step's outcome result.
     */
    public StepResult compensate(StepContext ctx) {
      // Transient failure: the recall request to the carrier is temporarily
      // unavailable. The engine must NOT abandon the deeper stack entries.
      if (failShipmentCompensation) {
        throw new WorkflowEngine.WorkflowException(
          'Carrier recall API temporarily unavailable'
        );
      }
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'recalled' => 'shp_3003' }
      );
    }
  }

  /**
   * @description Compensatable step that books a courier; its compensation cancels the booking.
   */
  public class BookCourierStep implements CompensatableStep {
    /**
     * @description Books a courier and records the courier id.
     * @param ctx The durable per-step execution context.
     * @return The step's outcome result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'courierId' => 'crr_4004' }
      );
    }

    /**
     * @description Cancels the courier booking during rollback.
     * @param ctx The durable per-step execution context.
     * @return The step's outcome result.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'cancelledCourier' => 'crr_4004' }
      );
    }
  }

  /**
   * @description Non-compensatable terminal step that always fails, triggering the saga rollback.
   */
  public class ConfirmDeliveryStep implements WorkflowStep {
    /**
     * @description Throws to fail the forward flow and start the LIFO rollback.
     * @param ctx The durable per-step execution context.
     * @return The step's outcome result.
     */
    public StepResult execute(StepContext ctx) {
      // Forward failure that triggers the saga rollback.
      throw new WorkflowEngine.WorkflowException(
        'Delivery confirmation failed; rolling back order.'
      );
    }
  }
}
