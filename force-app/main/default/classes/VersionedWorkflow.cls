public interface VersionedWorkflow extends WorkflowDefinition {
  Integer getLatestVersion();
  String getNextStep(
    String currentStepName,
    StepResult result,
    Integer version
  );
}
