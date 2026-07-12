/**
 * @description Optional contract a WorkflowStep implements to override the
 * engine's default per-step execution timeout with a step-specific budget.
 */
public interface ExecutionTimeoutConfigurable {
  /**
   * @description Returns the maximum wall-clock time the step is allowed to run
   * before the engine treats it as timed out.
   * @return The execution timeout, in seconds.
   */
  Integer getExecutionTimeoutSeconds();
}
