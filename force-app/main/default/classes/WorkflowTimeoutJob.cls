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
            ORDER BY CreatedDate DESC
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

            List<Workflow_Instance__c> instances = [
                SELECT Id, Status__c, Error_Message__c 
                FROM Workflow_Instance__c 
                WHERE Id = :this.instanceId
                LIMIT 1
                FOR UPDATE
            ];
            if (!instances.isEmpty()) {
                Workflow_Instance__c instance = instances[0];
                instance.Status__c = 'Failed';
                instance.Error_Message__c = 'Step ' + this.stepName + ' timed out.';
                update instance;
            }
        }

        // Clean up this scheduled execution
        if (ctx != null) {
            System.abortJob(ctx.getTriggerId());
        }
    }
}
