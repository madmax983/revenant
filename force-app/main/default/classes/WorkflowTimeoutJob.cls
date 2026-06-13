public class WorkflowTimeoutJob implements Schedulable {
    private Id instanceId;
    private String stepName;

    public WorkflowTimeoutJob(Id instanceId, String stepName) {
        this.instanceId = instanceId;
        this.stepName = stepName;
    }

    public void execute(SchedulableContext ctx) {
        // Query the step execution record and instance
        List<Workflow_Step_Execution__c> stepExecs = [
            SELECT Id 
            FROM Workflow_Step_Execution__c 
            WHERE Workflow_Instance__c = :this.instanceId 
            AND Step_Name__c = :this.stepName 
            AND Status__c = 'Running'
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];

        if (!stepExecs.isEmpty()) {
            Workflow_Step_Execution__c stepExec = [
                SELECT Status__c, Error_Details__c 
                FROM Workflow_Step_Execution__c 
                WHERE Id = :stepExecs[0].Id 
                FOR UPDATE
            ];
            stepExec.Status__c = 'Failed';
            stepExec.Error_Details__c = 'Step execution timed out.';
            update stepExec;

            WorkflowEngine.failWorkflowInstance(this.instanceId, this.stepName, 'Step execution timed out.');
        }

        // Clean up this scheduled execution
        if (ctx != null) {
            System.abortJob(ctx.getTriggerId());
        }
    }
}
