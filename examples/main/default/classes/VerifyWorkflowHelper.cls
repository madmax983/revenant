/**
 * @description Verification helper defining a minimal workflow whose single step both
 * declares a timeout and continues-as-new, exercising the timeout and ContinuedAsNew paths
 * end to end.
 */
public inherited sharing class VerifyWorkflowHelper {
  /**
   * @description Single-step workflow definition used to verify timeout-plus-continue behavior.
   */
  public class TimeoutContinueWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the steps that make up this workflow.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{ 'VerifyWorkflowHelper.TimeoutContinueStep' };
    }
    /**
     * @description Names the first step executed when an instance starts.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'VerifyWorkflowHelper.TimeoutContinueStep';
    }
    /**
     * @description Routes to the next step; this workflow completes after its only step.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, signalling the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  /**
   * @description The single step of the verification workflow: it declares a 60-second
   * timeout and continues-as-new to a successor generation, then completes on that successor.
   */
  public class TimeoutContinueStep implements WorkflowStep, TimeoutConfigurable {
    /**
     * @description Declares the step's timeout deadline.
     * @return The timeout in seconds before the step is considered timed out.
     */
    public Integer getTimeoutSeconds() {
      return 60;
    }
    /**
     * @description Continues-as-new to a successor on the first generation and completes once
     * the successor input is observed.
     * @param ctx The durable step context carrying workflow input.
     * @return A continue-as-new StepResult on the first run, or a completed result on the successor.
     */
    public StepResult execute(StepContext ctx) {
      if (
        ctx.workflowInputJson != null &&
        ctx.workflowInputJson.contains('successor')
      ) {
        return StepResult.complete(null, 'SuccessorFinished');
      }
      return StepResult.continueAsNew(
        'successor',
        'SuccessorKey_' + System.currentTimeMillis()
      );
    }
  }
}
