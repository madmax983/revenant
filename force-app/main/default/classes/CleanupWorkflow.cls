public with sharing class CleanupWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
        return 'CleanupWorkflow.PurgeOldInstancesStep';
    }
    
    public String getNextStep(String currentStepName, StepResult result) {
        return null; // Single step workflow
    }

    public class PurgeState {
        public Integer deletedCount;
    }

    public class PurgeOldInstancesStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            // Parse input parameters
            Integer retentionDays = 30;
            Integer batchSize = 200;
            if (String.isNotBlank(ctx.workflowInputJson)) {
                try {
                    Map<String, Object> input = (Map<String, Object>)JSON.deserializeUntyped(ctx.workflowInputJson);
                    if (input.containsKey('retentionDays')) {
                        retentionDays = Integer.valueOf(input.get('retentionDays'));
                    }
                    if (input.containsKey('batchSize')) {
                        batchSize = Integer.valueOf(input.get('batchSize'));
                    }
                } catch (Exception ex) {
                    // fallback to defaults
                }
            }

            DateTime threshold = DateTime.now().addDays(-retentionDays);
            
            // Query old terminal instances
            List<Workflow_Instance__c> oldInstances = [
                SELECT Id FROM Workflow_Instance__c
                WHERE Status__c IN ('Completed', 'Failed', 'Compensated', 'Cancelled')
                AND CreatedDate < :threshold
                LIMIT :batchSize
            ];

            PurgeState state = new PurgeState();
            if (String.isNotBlank(ctx.stepStateJson)) {
                state = (PurgeState)JSON.deserialize(ctx.stepStateJson, PurgeState.class);
            } else {
                state.deletedCount = 0;
            }

            if (oldInstances.isEmpty()) {
                return StepResult.complete(null, state);
            }

            // Perform delete (Master-Detail cascade deletes all steps and signals automatically)
            delete oldInstances;
            state.deletedCount += oldInstances.size();

            // Yield to process next batch with fresh limits
            return StepResult.yield(JSON.serialize(state));
        }
    }
}
