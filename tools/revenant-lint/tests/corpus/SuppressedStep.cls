// The author reviewed these calls and suppressed them.
public class SuppressedStep implements WorkflowStep {
  public StepResult execute(StepContext ctx) {
    System.debug(Datetime.now()); // revenant-lint-disable-line: debug output only
    // revenant-lint-disable-next-line: the id is only in a log
    String trace = String.valueOf(Crypto.getRandomInteger());
    return StepResult.complete(null, null);
  }
}
