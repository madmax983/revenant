public class ThrottledCalloutWorkflowExample implements WorkflowDefinition {
    public List<String> getSteps() {
        return new List<String>{ 'ThrottledCalloutWorkflowExample.PlaceholderStep' };
    }

    public String getInitialStep() {
        return 'ThrottledCalloutWorkflowExample.PlaceholderStep';
    }

    public String getNextStep(String currentStepName, StepResult stepResult) {
        return null;
    }

    public class PlaceholderStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            return StepResult.complete(null, null);
        }
    }
}
