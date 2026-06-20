public interface WorkflowDefinition {
  /**
   * Declares the complete set of step class names involved in this workflow.
   * Each entry is a fully-qualified Apex class name that must resolve via
   * Type.forName to a class implementing WorkflowStep (or CompensatableStep).
   * This is the authoritative step inventory WorkflowValidator checks the DAG
   * against, so a step reachable through getNextStep must also appear here.
   */
  List<String> getSteps();
  String getInitialStep();
  String getNextStep(String currentStepName, StepResult stepResult);
}
