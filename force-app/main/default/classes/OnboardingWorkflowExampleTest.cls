@isTest
public class OnboardingWorkflowExampleTest {

    @isTest
    static void testCustomerOnboardingWorkflow() {
        // Define onboarding input
        Map<String, Object> inputMap = new Map<String, Object>{
            'amount' => 15000.0,
            'customerName' => 'Acme Corp',
            'email' => 'admin@acme.com'
        };

        Test.startTest();
        // 1. Start the workflow definition
        Id instanceId = WorkflowEngine.start('OnboardingWorkflowExample', 'Onboarding_Key_123', inputMap);
        Test.stopTest(); // Executes VerifyOrderStep synchronously

        Workflow_Instance__c inst = [
            SELECT Status__c, Current_Step__c 
            FROM Workflow_Instance__c 
            WHERE Id = :instanceId
        ];
        System.assertEquals('Running', inst.Status__c);
        System.assertEquals('OnboardingWorkflowExample.SplitOnboardingStep', inst.Current_Step__c);

        // 2. Execute SplitOnboardingStep to spawn parallel branches
        new WorkflowOrchestrator(instanceId).execute(null);

        inst = [SELECT Status__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Running', inst.Status__c);
        System.assertEquals('OnboardingWorkflowExample.ProvisionSandboxStep,OnboardingWorkflowExample.CreateBillingAccountStep', inst.Current_Step__c);

        // 3. Run parallel ProvisionSandboxStep manually
        new WorkflowOrchestrator(instanceId, 'OnboardingWorkflowExample.ProvisionSandboxStep').execute(null);

        // 4. Run parallel CreateBillingAccountStep manually
        new WorkflowOrchestrator(instanceId, 'OnboardingWorkflowExample.CreateBillingAccountStep').execute(null);

        // 5. Run JoinOnboardingStep manually (since both parallel branches are done)
        new WorkflowOrchestrator(instanceId).execute(null);

        inst = [SELECT Status__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Running', inst.Status__c);
        System.assertEquals('OnboardingWorkflowExample.VIPApprovalStep', inst.Current_Step__c);

        // 6. Run VIPApprovalStep manually. Since amount >= 10000, it should suspend.
        new WorkflowOrchestrator(instanceId).execute(null);

        inst = [SELECT Status__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Suspended', inst.Status__c);
        System.assertEquals('OnboardingWorkflowExample.VIPApprovalStep', inst.Current_Step__c);

        // 7. Submit Executive Approval
        WorkflowEngine.signal('Onboarding_Key_123', 'Approve:VIPOrderApproval', '{"approved":true,"comments":"Approved VIP Customer"}');
        Test.getEventBus().deliver();

        // 8. Execute VIPApprovalStep again to consume approval and transition to welcome launcher
        new WorkflowOrchestrator(instanceId).execute(null);

        inst = [SELECT Status__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Running', inst.Status__c);
        System.assertEquals('OnboardingWorkflowExample.WelcomeWorkflowLauncherStep', inst.Current_Step__c);

        // 9. Execute WelcomeWorkflowLauncherStep manually. It will launch the child WelcomeEmailWorkflow.
        new WorkflowOrchestrator(instanceId).execute(null);

        inst = [SELECT Status__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Suspended', inst.Status__c);

        // Verify child instance was created
        Workflow_Instance__c childInst = [
            SELECT Id, Status__c, Current_Step__c, Parent_Instance__c 
            FROM Workflow_Instance__c 
            WHERE Parent_Instance__c = :instanceId 
            LIMIT 1
        ];
        System.assertEquals('Pending', childInst.Status__c);

        // 10. Execute child workflow's DelayEmailStep (which will suspend for sleep)
        new WorkflowOrchestrator(childInst.Id).execute(null);

        childInst = [SELECT Status__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :childInst.Id];
        System.assertEquals('Suspended', childInst.Status__c);
        System.assertEquals('OnboardingWorkflowExample.DelayEmailStep', childInst.Current_Step__c);

        // Simulating the Schedulable Sleep Resumer Job firing
        childInst.Status__c = 'Running';
        childInst.Current_Step__c = 'OnboardingWorkflowExample.SendEmailStep';
        update childInst;

        // 11. Execute SendEmailStep manually (which completes the child workflow and notifies the parent)
        new WorkflowOrchestrator(childInst.Id).execute(null);

        // Deliver child completion platform event to parent
        Test.getEventBus().deliver();

        // Verify parent is Running again
        inst = [SELECT Status__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Running', inst.Status__c);

        // 12. Run WelcomeWorkflowLauncherStep again to consume child completion signal and transition to final step
        new WorkflowOrchestrator(instanceId).execute(null);

        inst = [SELECT Status__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Running', inst.Status__c);
        System.assertEquals('OnboardingWorkflowExample.CompleteOnboardingStep', inst.Current_Step__c);

        // 13. Run CompleteOnboardingStep to finish the workflow
        new WorkflowOrchestrator(instanceId).execute(null);

        inst = [SELECT Status__c, Output__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Completed', inst.Status__c);
        System.assert(inst.Output__c.contains('"status":"Completed"'));
    }
}
