// A test class. Excluded by name.
@IsTest
private class OrderStepsTest {
  private class FakeStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, Datetime.now());
    }
  }
}
