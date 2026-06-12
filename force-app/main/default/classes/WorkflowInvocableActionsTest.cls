@isTest
public class WorkflowInvocableActionsTest {

    @isTest
    static void testStartWorkflowInvocable() {
        WorkflowStartInvocableAction.StartRequest req = new WorkflowStartInvocableAction.StartRequest();
        req.workflowName = 'WorkflowEngineTest.HappyWorkflow';
        req.correlationKey = 'InvocableKey';
        req.inputJson = '"InvocableInput"';
        
        Test.startTest();
        List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
            new List<WorkflowStartInvocableAction.StartRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        Id instanceId = results[0].workflowInstanceId;
        System.assertNotEquals(null, instanceId);

        Workflow_Instance__c inst = [
            SELECT Workflow_Name__c, Status__c, Correlation_Key__c, Input__c 
            FROM Workflow_Instance__c 
            WHERE Id = :instanceId
        ];
        System.assertEquals('WorkflowEngineTest.HappyWorkflow', inst.Workflow_Name__c);
        System.assertEquals('InvocableKey', inst.Correlation_Key__c);
        System.assertEquals('"InvocableInput"', inst.Input__c);
    }

    @isTest
    static void testSignalWorkflowInvocable() {
        // Create active instance
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Suspended',
            Correlation_Key__c = 'InvocableSignalKey',
            Input__c = '"InputData"'
        );
        insert inst;

        WorkflowSignalInvocableAction.SignalRequest req = new WorkflowSignalInvocableAction.SignalRequest();
        req.targetKey = 'InvocableSignalKey';
        req.signalName = 'Approve:InvocableApproval';
        req.payloadJson = '{"approved":true}';

        Test.startTest();
        WorkflowSignalInvocableAction.signalWorkflow(
            new List<WorkflowSignalInvocableAction.SignalRequest>{ req }
        );
        Test.stopTest();

        // Deliver Platform Event
        Test.getEventBus().deliver();

        List<Workflow_Signal__c> signals = [
            SELECT Signal_Name__c, Payload__c 
            FROM Workflow_Signal__c 
            WHERE Workflow_Instance__c = :inst.Id
        ];
        System.assertEquals(1, signals.size());
        System.assertEquals('Approve:InvocableApproval', signals[0].Signal_Name__c);
    }
}
