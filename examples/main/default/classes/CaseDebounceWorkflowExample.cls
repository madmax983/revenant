/**
 * @description Reference workflow demonstrating debounced Case-update handling: a
 * single-step definition whose instances collapse a burst of rapid Case changes
 * into one downstream processing run.
 */
public class CaseDebounceWorkflowExample implements WorkflowDefinition {
  /**
   * @description Declares the ordered step names comprising this workflow.
   * @return The single-element list containing the ProcessCaseUpdate step.
   */
  public List<String> getSteps() {
    return new List<String>{ 'CaseDebounceWorkflowExample.ProcessCaseUpdate' };
  }

  /**
   * @description Names the step the engine runs first for a new instance.
   * @return The ProcessCaseUpdate step name.
   */
  public String getInitialStep() {
    return 'CaseDebounceWorkflowExample.ProcessCaseUpdate';
  }

  /**
   * @description Resolves the step to run after the current one completes.
   * @param currentStepName The name of the step that just completed.
   * @param stepResult The result of the completed step.
   * @return Null, since the single processing step terminates the workflow.
   */
  public String getNextStep(String currentStepName, StepResult stepResult) {
    return null;
  }

  /**
   * @description The lone step that processes the debounced Case update.
   */
  public class ProcessCaseUpdate implements WorkflowStep {
    /**
     * @description Processes the coalesced Case update carried in the step input
     * and completes the workflow.
     * @param ctx The durable step context supplying the Case update input.
     * @return A completed StepResult ending the workflow.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }
}
