/**
 * @description Opt-in interface a WorkflowStep implements to override the engine's
 * default per-step execution timeout, bounding how long the step may run before the
 * watchdog treats it as timed out and routes it to failure or error handling.
 */
public interface TimeoutConfigurable {
  /**
   * @description Returns the maximum number of seconds this step is allowed to run
   * before the engine considers it timed out.
   * @return The step's timeout budget in seconds.
   */
  Integer getTimeoutSeconds();
}
