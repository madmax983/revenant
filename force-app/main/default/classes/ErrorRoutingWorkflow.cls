public interface ErrorRoutingWorkflow extends WorkflowDefinition {
  String getErrorStep(String failedStepName, StepError error);
}
