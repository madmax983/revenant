// Anti-pattern: publish an event in a step. Each replay publishes it again.
public class EventPublishStep implements WorkflowStep {
  public StepResult execute(StepContext ctx) {
    EventBus.publish(new Order_Shipped__e()); // expect: EVENT_PUBLISH
    ctx.events().emit(new Order_Shipped__e());
    return StepResult.complete(null, null);
  }
}
