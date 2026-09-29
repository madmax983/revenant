public class RandomStep implements WorkflowStep {
  public StepResult execute(StepContext ctx) {
    return StepResult.complete(null, Math.random());
  }
}
