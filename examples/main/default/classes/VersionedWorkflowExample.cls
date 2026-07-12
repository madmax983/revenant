/**
 * @description Reference example demonstrating versioned routing, where the successor step varies by workflow version.
 */
public inherited sharing class VersionedWorkflowExample {
  /**
   * @description VersionedWorkflow definition whose routing diverges between version 1 (legacy) and version 2.
   */
  public class VersionedWorkflowImpl implements VersionedWorkflow {
    /**
     * @description Declares the fully-qualified step names that make up this workflow.
     * @return The list of fully-qualified step names in this definition.
     */
    public List<String> getSteps() {
      return new List<String>{
        'VersionedWorkflowExample.StepAStep',
        'VersionedWorkflowExample.StepBStep',
        'VersionedWorkflowExample.NewStepBStep'
      };
    }

    /**
     * @description Names the entry-point step the engine runs first.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'VersionedWorkflowExample.StepAStep';
    }

    /**
     * @description Reports the newest defined version of this workflow.
     * @return The latest workflow version.
     */
    public Integer getLatestVersion() {
      return 2;
    }

    /**
     * @description Default routing entry point; defers to the version-aware overload using version 1.
     * @param currentStepName The step that just completed.
     * @param result The result of the completed step.
     * @return The next step name, or null at the end of the workflow.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      // Fallback / default routing (Version 1 behavior)
      return getNextStep(currentStepName, result, 1);
    }

    /**
     * @description Version-aware routing: after StepA, routes to the new step on version 2+ and the legacy step otherwise.
     * @param currentStepName The step that just completed.
     * @param result The result of the completed step.
     * @param version The workflow version driving the routing choice.
     * @return The next step name, or null at the end of the workflow.
     */
    public String getNextStep(
      String currentStepName,
      StepResult result,
      Integer version
    ) {
      if (currentStepName == 'VersionedWorkflowExample.StepAStep') {
        return (version >= 2)
          ? 'VersionedWorkflowExample.NewStepBStep'
          : 'VersionedWorkflowExample.StepBStep';
      }
      return null; // End of workflow
    }
  }

  /**
   * @description First step; selects its output message based on the running workflow version.
   */
  public class StepAStep implements WorkflowStep {
    /**
     * @description Completes with a version-specific message.
     * @param ctx The durable per-step execution context.
     * @return The step's outcome result.
     */
    public StepResult execute(StepContext ctx) {
      String msg = (ctx.workflowVersion >= 2) ? 'New logic' : 'Legacy logic';
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'message' => msg }
      );
    }
  }

  /**
   * @description Legacy (version 1) second step.
   */
  public class StepBStep implements WorkflowStep {
    /**
     * @description Completes with the legacy marker payload.
     * @param ctx The durable per-step execution context.
     * @return The step's outcome result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'legacy' => true }
      );
    }
  }

  /**
   * @description New (version 2) second step.
   */
  public class NewStepBStep implements WorkflowStep {
    /**
     * @description Completes with the non-legacy marker payload.
     * @param ctx The durable per-step execution context.
     * @return The step's outcome result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'legacy' => false }
      );
    }
  }
}
