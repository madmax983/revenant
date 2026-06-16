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

  public class StalledSagaWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'SagaStalledRollbackExample.ChargeCardStep',
        'SagaStalledRollbackExample.ReserveInventoryStep',
        'SagaStalledRollbackExample.ShipOrderStep',
        'SagaStalledRollbackExample.BookCourierStep',
        'SagaStalledRollbackExample.ConfirmDeliveryStep'
      };
    }

    public String getInitialStep() {
      return 'SagaStalledRollbackExample.ChargeCardStep';
    }

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

  public class ChargeCardStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'chargeId' => 'ch_1001' }
      );
    }

    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'refundId' => 'rf_1001' }
      );
    }
  }

  public class ReserveInventoryStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'reservationId' => 'res_2002' }
      );
    }

    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'released' => 'res_2002' }
      );
    }
  }

  public class ShipOrderStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'shipmentId' => 'shp_3003' }
      );
    }

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

  public class BookCourierStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'courierId' => 'crr_4004' }
      );
    }

    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'cancelledCourier' => 'crr_4004' }
      );
    }
  }

  public class ConfirmDeliveryStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Forward failure that triggers the saga rollback.
      throw new WorkflowEngine.WorkflowException(
        'Delivery confirmation failed; rolling back order.'
      );
    }
  }
}
