/**
 * @description Reference workflow demonstrating execution-timeout deadlines: it
 * suspends awaiting a signal that never arrives so the configured timeout fires
 * and the instance is failed by the deadline sweeper.
 */
public class DeadlineWorkflowExample implements WorkflowDefinition, ExecutionTimeoutConfigurable {
  /**
   * @description Declares the ordered step names comprising this workflow.
   * @return The single-element list containing the AwaitingSignalStep step.
   */
  public List<String> getSteps() {
    return new List<String>{ 'DeadlineWorkflowExample.AwaitingSignalStep' };
  }

  /**
   * @description Names the step the engine runs first for a new instance.
   * @return The AwaitingSignalStep step name.
   */
  public String getInitialStep() {
    return 'DeadlineWorkflowExample.AwaitingSignalStep';
  }

  /**
   * @description Resolves the step to run after the current one completes.
   * @param currentStepName The name of the step that just completed.
   * @param stepResult The result of the completed step.
   * @return Null; the instance is expected to end via timeout, not step succession.
   */
  public String getNextStep(String currentStepName, StepResult stepResult) {
    return null;
  }

  /**
   * @description The execution-timeout budget the engine enforces on this workflow.
   * @return The timeout in seconds (10) after which the deadline sweeper fails the instance.
   */
  public Integer getExecutionTimeoutSeconds() {
    return 10; // 10 second timeout for quick testing
  }

  /**
   * @description The step that suspends indefinitely to exercise the deadline path.
   */
  public class AwaitingSignalStep implements WorkflowStep {
    /**
     * @description Suspends the instance waiting on a signal that never arrives so
     * the execution timeout can elapse.
     * @param ctx The durable step context for this execution.
     * @return A suspend StepResult awaiting the NeverArrivingSignal.
     */
    public StepResult execute(StepContext ctx) {
      // Suspend waiting for a signal that will never arrive
      return StepResult.suspend('NeverArrivingSignal');
    }
  }
}
