/**
 * @description Workflow definition that supports multiple concurrent versions, letting
 * in-flight instances keep running their original topology while new instances adopt the
 * latest revision.
 */
public interface VersionedWorkflow extends WorkflowDefinition {
  /**
   * @description Returns the highest version number defined for this workflow.
   * @return The latest version number available for new instances.
   */
  Integer getLatestVersion();
  /**
   * @description Determines the next step for a specific workflow version, allowing the
   * DAG topology to differ between versions.
   * @param currentStepName The name of the step that just completed.
   * @param result The result of the completed step.
   * @param version The workflow version whose topology should be evaluated.
   * @return The next step name, or null when the workflow is complete.
   */
  String getNextStep(
    String currentStepName,
    StepResult result,
    Integer version
  );
}
