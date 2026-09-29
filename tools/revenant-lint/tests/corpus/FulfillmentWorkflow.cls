// A definition. getSteps() names a packaged step and a step that is not in the source.
public class FulfillmentWorkflow implements WorkflowDefinition {
  public List<String> getSteps() {
    return new List<String>{
      'FulfillmentWorkflow.Pick',
      'acme.ShipStep',
      'vendor.LabelStep' // expect: STEP_SOURCE_NOT_FOUND
    };
  }
  public String getInitialStep() {
    return 'FulfillmentWorkflow.Pick';
  }
  public String getNextStep(String current, StepResult result) {
    return null;
  }

  // A step through getSteps() only: its base class is in a package.
  public class Pick extends vendor.PackagedStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, Math.random()); // expect: RANDOM_VALUE
    }
  }
}
