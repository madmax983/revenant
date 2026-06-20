public inherited sharing class VerifyWorkflowHelper {
  public class TimeoutContinueWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'VerifyWorkflowHelper.TimeoutContinueStep' };
    }
    public String getInitialStep() {
      return 'VerifyWorkflowHelper.TimeoutContinueStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  public class TimeoutContinueStep implements WorkflowStep, TimeoutConfigurable {
    public Integer getTimeoutSeconds() {
      return 60;
    }
    public StepResult execute(StepContext ctx) {
      if (
        ctx.workflowInputJson != null &&
        ctx.workflowInputJson.contains('successor')
      ) {
        return StepResult.complete(null, 'SuccessorFinished');
      }
      return StepResult.continueAsNew(
        'successor',
        'SuccessorKey_' + System.currentTimeMillis()
      );
    }
  }
}
