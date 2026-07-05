public class CaseDebounceWorkflowExample implements WorkflowDefinition {
  public List<String> getSteps() {
    return new List<String>{ 'CaseDebounceWorkflowExample.ProcessCaseUpdate' };
  }

  public String getInitialStep() {
    return 'CaseDebounceWorkflowExample.ProcessCaseUpdate';
  }

  public String getNextStep(String currentStepName, StepResult stepResult) {
    return null;
  }

  public class ProcessCaseUpdate implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      System.debug(
        'CaseDebounceWorkflowExample processing case update input: ' +
        ctx.inputJson
      );
      return StepResult.complete(null, null);
    }
  }
}
