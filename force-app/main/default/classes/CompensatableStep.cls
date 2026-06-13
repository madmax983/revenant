public interface CompensatableStep extends WorkflowStep {
  StepResult compensate(StepContext ctx);
}
