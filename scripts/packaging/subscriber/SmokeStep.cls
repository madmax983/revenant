/** One step. It completes at once. */
public class SmokeStep implements __NS__.WorkflowStep {
  public __NS__.StepResult execute(__NS__.StepContext ctx) {
    return __NS__.StepResult.complete(null, 'ok');
  }
}
