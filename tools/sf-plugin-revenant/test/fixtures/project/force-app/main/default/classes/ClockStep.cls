public class ClockStep implements WorkflowStep {
  public StepResult execute(StepContext ctx) {
    return StepResult.complete(null, Datetime.now());
  }
}
