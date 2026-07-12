/**
 * @description Core execution unit of a workflow DAG. Each step implements this
 * interface to perform its work and return a StepResult describing the outcome
 * (complete, retry, sleep, yield, split, etc.) that drives the engine's durable
 * state transitions.
 */
public interface WorkflowStep {
  /**
   * @description Executes the step's business logic using its durable per-step
   * context and returns the outcome that determines the workflow's next transition.
   * @param context The durable StepContext carrying input, state, and engine services for this step.
   * @return The StepResult describing how the engine should advance the workflow.
   */
  StepResult execute(StepContext context);
}
