// Anti-pattern in a subclass of a base step.
public class ShipStep extends AuditedBaseStep {
  public StepResult execute(StepContext ctx) {
    return StepResult.complete(null, UserInfo.getName()); // expect: USER_CONTEXT
  }
  public StepResult compensate(StepContext ctx) {
    return StepResult.complete(null, null);
  }
}
