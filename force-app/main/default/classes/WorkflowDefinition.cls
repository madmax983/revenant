public interface WorkflowDefinition {
    String getInitialStep();
    String getNextStep(String currentStepName, StepResult stepResult);
}
