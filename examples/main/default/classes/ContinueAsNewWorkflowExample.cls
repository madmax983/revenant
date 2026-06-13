public inherited sharing class ContinueAsNewWorkflowExample {
    
    public class PollerWorkflow implements WorkflowDefinition {
        public List<String> getSteps() {
            return new List<String>{
                'ContinueAsNewWorkflowExample.PollStep'
            };
        }

        public String getInitialStep() {
            return 'ContinueAsNewWorkflowExample.PollStep';
        }

        public String getNextStep(String currentStepName, StepResult result) {
            return null; // Single step execution
        }
    }

    public class PollStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            Integer runsCompleted = 0;
            if (String.isNotBlank(ctx.workflowInputJson)) {
                try {
                    runsCompleted = Integer.valueOf(ctx.workflowInputJson);
                } catch (Exception e) {
                    // fallback to 0
                }
            }
            
            if (runsCompleted < 3) {
                // Continue-As-New with incremented counter
                return StepResult.continueAsNew(runsCompleted + 1);
            }
            
            return StepResult.complete(null, 'Successfully completed poller after ' + runsCompleted + ' runs.');
        }
    }
}
