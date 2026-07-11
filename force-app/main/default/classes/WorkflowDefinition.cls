/**
 * @description Contract a workflow author implements to declare a DAG of steps:
 * its full step inventory, entry point, and the transition function the engine
 * consults to route from one completed step to the next.
 */
public interface WorkflowDefinition {
  /**
   * @description Declares the complete set of step class names involved in this workflow.
   * Each entry is a fully-qualified Apex class name that must resolve via
   * Type.forName to a class implementing WorkflowStep (or CompensatableStep).
   * This is the authoritative step inventory WorkflowValidator checks the DAG
   * against, so a step reachable through getNextStep must also appear here.
   * @return The list of fully-qualified step class names in this workflow.
   */
  List<String> getSteps();
  /**
   * @description Returns the step the engine executes first when an instance of
   * this workflow starts.
   * @return The name of the initial step.
   */
  String getInitialStep();
  /**
   * @description Determines the next step after the current step completes,
   * driving the workflow's DAG traversal.
   * @param currentStepName The name of the step that just completed.
   * @param stepResult The result produced by the completed step.
   * @return The next step name, or null when the workflow is complete.
   */
  String getNextStep(String currentStepName, StepResult stepResult);
}
