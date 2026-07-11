/**
 * @description A WorkflowStep that participates in saga compensation. When a
 * downstream step fails and the workflow unwinds, the engine invokes compensate
 * on each previously-completed compensatable step in reverse order to undo its
 * effects.
 */
public interface CompensatableStep extends WorkflowStep {
  /**
   * @description Reverses the effects this step applied during its forward run,
   * invoked by the engine while unwinding a failed saga.
   * @param ctx The durable per-step context for the compensation invocation.
   * @return The result of the compensation, signalling success or failure to the engine.
   */
  StepResult compensate(StepContext ctx);
}
