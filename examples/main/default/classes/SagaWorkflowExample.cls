public inherited sharing class SagaWorkflowExample {
  public class SagaWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'SagaWorkflowExample.ChargeCreditCardStep',
        'SagaWorkflowExample.ProvisionServiceStep',
        'SagaWorkflowExample.SendWelcomeEmailStep'
      };
    }

    public String getInitialStep() {
      return 'SagaWorkflowExample.ChargeCreditCardStep';
    }

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

  public class ChargeCreditCardStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'chargeId' => 'ch_12345', 'amount' => 150 }
      );
    }

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
        } catch (Exception e) {
          // Fallback to mock chargeId
        }
      }

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

  public class ProvisionServiceStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'serviceId' => 'srv_98765' }
      );
    }

    public StepResult compensate(StepContext ctx) {
      // Mock deprovision logic
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'status' => 'Deprovisioned' }
      );
    }
  }

  public class SendWelcomeEmailStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Intentionally fail to trigger Saga compensations
      throw new WorkflowEngine.WorkflowException('SMTP Server Down');
    }
  }
}
