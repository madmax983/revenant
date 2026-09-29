// A base class. It is a step through CompensatableStep.
public abstract class AuditedBaseStep implements rvn.CompensatableStep {
  protected String stamp() {
    return String.valueOf(Datetime.now()); // expect: CLOCK_READ
  }
}
