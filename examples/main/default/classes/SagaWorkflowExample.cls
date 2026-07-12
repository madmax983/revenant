/**
 * @description Reference saga example: a charge then provision then welcome-email
 * sequence in which each compensatable step defines the rollback that undoes it if a
 * later step fails, demonstrating the engine's compensation stack.
 */
public inherited sharing class SagaWorkflowExample {
  /**
   * @description Workflow definition sequencing the three saga steps.
   */
  public class SagaWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered step names composing the saga.
     * @return The charge, provision, and welcome-email step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'SagaWorkflowExample.ChargeCreditCardStep',
        'SagaWorkflowExample.ProvisionServiceStep',
        'SagaWorkflowExample.SendWelcomeEmailStep'
      };
    }

    /**
     * @description Returns the step the saga begins with.
     * @return The charge-credit-card step name.
     */
    public String getInitialStep() {
      return 'SagaWorkflowExample.ChargeCreditCardStep';
    }

    /**
     * @description Advances the linear charge then provision then email sequence.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return The next step name, or null once the welcome email completes.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'SagaWorkflowExample.ChargeCreditCardStep') {
        return 'SagaWorkflowExample.ProvisionServiceStep';
      }
      if (currentStepName == 'SagaWorkflowExample.ProvisionServiceStep') {
        return 'SagaWorkflowExample.SendWelcomeEmailStep';
      }
      return null;
    }
  }

  /**
   * @description Saga step that charges the credit card, compensated by a refund.
   */
  public class ChargeCreditCardStep implements CompensatableStep {
    /**
     * @description Charges the credit card and records the charge id for later refund.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result carrying the charge id and amount.
     */
    public StepResult execute(StepContext ctx) {
      ctx.log(
        StepContext.Level.INFO,
        'Charging credit card',
        new Map<String, Object>{ 'amount' => 150 }
      );
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'chargeId' => 'ch_12345', 'amount' => 150 }
      );
    }

    /**
     * @description Rolls back the charge by refunding it, recovering the original
     * charge id from the recorded step state.
     * @param ctx The durable step context exposing the original charge output.
     * @return A COMPLETE result carrying the refund id and refunded charge id.
     */
    public StepResult compensate(StepContext ctx) {
      // Retrieve chargeId from original output in ctx
      String chargeId = 'ch_mock';
      if (String.isNotBlank(ctx.stepStateJson)) {
        try {
          Map<String, Object> origOutput = (Map<String, Object>) JSON.deserializeUntyped(
            ctx.stepStateJson
          );
          if (origOutput != null && origOutput.containsKey('chargeId')) {
            chargeId = (String) origOutput.get('chargeId');
          }
        } catch (Exception ignored) {
        }
      }

      ctx.log(
        StepContext.Level.WARN,
        'Refunding credit card charge',
        new Map<String, Object>{ 'chargeId' => chargeId }
      );
      // Mock refund logic
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'refundId' => 'rf_12345',
          'refundedChargeId' => chargeId
        }
      );
    }
  }

  /**
   * @description Saga step that provisions the service, compensated by deprovisioning.
   */
  public class ProvisionServiceStep implements CompensatableStep {
    /**
     * @description Provisions the service for the customer.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result carrying the provisioned service id.
     */
    public StepResult execute(StepContext ctx) {
      ctx.log(StepContext.Level.INFO, 'Provisioning service...');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'serviceId' => 'srv_98765' }
      );
    }

    /**
     * @description Rolls back provisioning by deprovisioning the service.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result confirming the service was deprovisioned.
     */
    public StepResult compensate(StepContext ctx) {
      ctx.log(StepContext.Level.INFO, 'Deprovisioning service...');
      // Mock deprovision logic
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'status' => 'Deprovisioned' }
      );
    }
  }

  /**
   * @description Terminal saga step that sends the welcome email; being a plain
   * WorkflowStep it has no compensation.
   */
  public class SendWelcomeEmailStep implements WorkflowStep {
    /**
     * @description Sends the welcome email, completing the saga.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result confirming the email was sent.
     */
    public StepResult execute(StepContext ctx) {
      ctx.log(StepContext.Level.INFO, 'Sending welcome email...');
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'status' => 'Sent' }
      );
    }
  }
}
