public class DeadlineWorkflowExample implements WorkflowDefinition, ExecutionTimeoutConfigurable {
  public List<String> getSteps() {
    return new List<String>{'DeadlineWorkflowExample.AwaitingSignalStep'};
  }

  public String getInitialStep() {
    return 'DeadlineWorkflowExample.AwaitingSignalStep';
  }

  public String getNextStep(String currentStepName, StepResult stepResult) {
    return null;
  }

  public Integer getExecutionTimeoutSeconds() {
    return 10; // 10 second timeout for quick testing
  }

  public class AwaitingSignalStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Suspend waiting for a signal that will never arrive
      return StepResult.suspend('NeverArrivingSignal');
    }
  }
}
