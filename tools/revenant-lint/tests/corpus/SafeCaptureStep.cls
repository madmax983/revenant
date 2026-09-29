// Safe: each hazard is in a CaptureProducer, a comment, or a string.
public class SafeCaptureStep implements WorkflowStep {
  // Do not call Datetime.now() here. Use once().
  public StepResult execute(StepContext ctx) {
    /* Math.random(); UserInfo.getUserId(); System.enqueueJob(q); */
    String note = 'Datetime.now() and Crypto.getRandomInteger() are unsafe';
    String quoted = 'it\'s Math.random()';
    Object at = ctx.captures().once('at', new NowProducer());
    Object id = ctx.captures().once('id', new IdProducer());
    Type t = Datetime.class;
    return StepResult.complete(null, note + quoted + at + id + t);
  }

  private class NowProducer implements CaptureProducer {
    public Object produce() {
      return String.valueOf(Datetime.now().getTime());
    }
  }

  private class IdProducer extends BaseIdProducer {
    public Object produce() {
      return String.valueOf(Crypto.getRandomLong()) + UserInfo.getUserId();
    }
  }
}
