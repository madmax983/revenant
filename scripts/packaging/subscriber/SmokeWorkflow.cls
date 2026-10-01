/** One-step workflow. Subscriber code, not part of the package. */
public class SmokeWorkflow implements __NS__.WorkflowDefinition {
  public List<String> getSteps() {
    return new List<String>{ 'SmokeStep' };
  }
  public String getInitialStep() {
    return 'SmokeStep';
  }
  public String getNextStep(String currentStep, __NS__.StepResult result) {
    return null;
  }
}
