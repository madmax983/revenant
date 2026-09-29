public class QueryStep implements WorkflowStep {
  public StepResult execute(StepContext ctx) {
    return StepResult.complete(null, [SELECT Id FROM Account LIMIT 1]);
  }
}
