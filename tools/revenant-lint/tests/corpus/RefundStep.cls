// Anti-pattern: compensation stamps the time. A retry of the rollback changes it.
public class RefundStep implements CompensatableStep {
  private static final Datetime LOADED_AT = Datetime.now(); // expect: CLOCK_READ

  public StepResult execute(StepContext ctx) {
    return StepResult.complete(null, null);
  }

  public StepResult compensate(StepContext ctx) {
    Datetime refundedAt = System // expect: CLOCK_READ
      .now();
    return StepResult.complete(null, String.valueOf(refundedAt));
  }
}
