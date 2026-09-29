public class SafeStep implements WorkflowStep {
  // Datetime.now() is safe in a comment.
  public StepResult execute(StepContext ctx) {
    return StepResult.complete(null, ctx.captures().once('t', new Now()));
  }
  class Now implements CaptureProducer {
    public Object produce() { return String.valueOf(Datetime.now()); }
  }
}
