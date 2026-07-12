/**
 * @description Example poller workflow that re-arms itself with continue-as-new to run a
 * bounded number of times, demonstrating how to loop without unbounded history growth.
 */
public inherited sharing class ContinueAsNewWorkflowExample {
  /**
   * @description Single-step workflow that repeatedly continues as a fresh instance until a
   * run limit is reached.
   */
  public class PollerWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered step names of the poller workflow.
     * @return A single-element list naming the poll step.
     */
    public List<String> getSteps() {
      return new List<String>{ 'ContinueAsNewWorkflowExample.PollStep' };
    }

    /**
     * @description Returns the name of the first step to execute.
     * @return The name of the poll step.
     */
    public String getInitialStep() {
      return 'ContinueAsNewWorkflowExample.PollStep';
    }

    /**
     * @description Computes the next step after the given step completes.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, since this is a single-step workflow.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null; // Single step execution
    }
  }

  /**
   * @description Poll step that continues as new with an incremented counter until three
   * runs have completed, then completes.
   */
  public class PollStep implements WorkflowStep {
    /**
     * @description Reads the run counter from input and either continues as new with an
     * incremented counter or completes once three runs are done.
     * @param ctx The durable step context supplying the workflow input.
     * @return A continue-as-new result while below the limit, otherwise a complete result.
     */
    public StepResult execute(StepContext ctx) {
      Integer runsCompleted = 0;
      if (String.isNotBlank(ctx.workflowInputJson)) {
        try {
          runsCompleted = Integer.valueOf(ctx.workflowInputJson);
        } catch (Exception e) {
          System.debug(
            LoggingLevel.WARN,
            'Failed to parse runsCompleted from workflowInputJson: ' +
            e.getMessage()
          );
        }
      }

      if (runsCompleted < 3) {
        // Continue-As-New with incremented counter
        return StepResult.continueAsNew(runsCompleted + 1);
      }

      return StepResult.complete(
        null,
        'Successfully completed poller after ' + runsCompleted + ' runs.'
      );
    }
  }
}
