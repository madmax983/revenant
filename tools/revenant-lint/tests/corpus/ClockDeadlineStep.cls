// Anti-pattern: a deadline from the clock. A replay after a wait gets a new deadline.
public with sharing class ClockDeadlineStep implements WorkflowStep {
  public StepResult execute(StepContext ctx) {
    Datetime deadline = Datetime.now().addHours(4); // expect: CLOCK_READ
    Date runDate = System.today(); // expect: CLOCK_READ
    Date bizDate = Date.today(); // expect: CLOCK_READ
    Long started = System.currentTimeMillis(); // expect: CLOCK_READ
    if (System.now() > deadline) { // expect: CLOCK_READ
      return StepResult.complete(null, null);
    }
    return StepResult.suspend();
  }
}
