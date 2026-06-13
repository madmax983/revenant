@isTest
public class SagaWorkflowExampleTest {

    @isTest
    static void testSagaWorkflowCompensationsSuccess() {
        WorkflowEngine.disableQueueableInTest = true;

        Test.startTest();
        // 1. Start workflow - runs initial step (ChargeCreditCardStep)
        Id instanceId = WorkflowEngine.start('SagaWorkflowExample.SagaWorkflow', 'SagaKey_1', '{"email":"test@example.com"}');
        
        // Run first step manually since queueable is disabled
        WorkflowEngine.runStep(instanceId, null);
        
        // Verify forward steps run and append to compensation stack
        // ChargeCreditCardStep completed, next step is ProvisionServiceStep
        Workflow_Instance__c inst = [SELECT Status__c, Current_Step__c, Compensation_Stack__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Running', inst.Status__c);
        System.assertEquals('SagaWorkflowExample.ProvisionServiceStep', inst.Current_Step__c);
        System.assert(inst.Compensation_Stack__c.contains('SagaWorkflowExample.ChargeCreditCardStep'));

        // Run ProvisionServiceStep forward
        WorkflowEngine.runStep(instanceId, null);
        
        inst = [SELECT Status__c, Current_Step__c, Compensation_Stack__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('SagaWorkflowExample.SendWelcomeEmailStep', inst.Current_Step__c);
        System.assert(inst.Compensation_Stack__c.contains('SagaWorkflowExample.ProvisionServiceStep'));

        // Run SendWelcomeEmailStep (SMTP Server Down -> Crashes -> Triggers compensation)
        try {
            WorkflowEngine.runStep(instanceId, null);
            System.assert(false, 'Should have thrown exception');
        } catch (Exception ex) {
            WorkflowEngine.handleCrash(instanceId, ex);
        }
        
        inst = [SELECT Status__c, Current_Step__c, Compensation_Stack__c, Error_Message__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Compensating', inst.Status__c);
        System.assert(inst.Error_Message__c.contains('SMTP Server Down'));
        
        // Run compensation loop (pop ProvisionServiceStep)
        WorkflowEngine.runStep(instanceId, null);
        
        // Run compensation loop (pop ChargeCreditCardStep)
        WorkflowEngine.runStep(instanceId, null);
        
        // Final loop run: stack empty -> status transitions to Compensated
        WorkflowEngine.runStep(instanceId, null);
        Test.stopTest();

        inst = [SELECT Status__c, Compensation_Stack__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Compensated', inst.Status__c);
        
        // Verify compensation execution logs exist
        List<Workflow_Step_Execution__c> compLogs = [
            SELECT Step_Name__c, Status__c, Output__c 
            FROM Workflow_Step_Execution__c 
            WHERE Workflow_Instance__c = :instanceId
            AND Step_Name__c LIKE '%_Compensate'
            ORDER BY CreatedDate ASC
        ];
        System.assertEquals(2, compLogs.size());
        System.assertEquals('SagaWorkflowExample.ProvisionServiceStep_Compensate', compLogs[0].Step_Name__c);
        System.assertEquals('Compensated', compLogs[0].Status__c);
        
        System.assertEquals('SagaWorkflowExample.ChargeCreditCardStep_Compensate', compLogs[1].Step_Name__c);
        System.assertEquals('Compensated', compLogs[1].Status__c);
        System.assert(compLogs[1].Output__c.contains('refundId'));
        System.assert(compLogs[1].Output__c.contains('ch_12345'));
    }
}
