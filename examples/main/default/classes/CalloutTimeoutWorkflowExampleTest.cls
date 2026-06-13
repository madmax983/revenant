@isTest
public class CalloutTimeoutWorkflowExampleTest {

    private class SingleRequestMock implements HttpCalloutMock {
        private Integer code;
        private String body;

        public SingleRequestMock(Integer code, String body) {
            this.code = code;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(this.code);
            res.setBody(this.body);
            return res;
        }
    }

    @isTest
    static void testCalloutSuccess() {
        // Enforce mock configs to prevent DB alerts dependency
        WorkflowAlertManager.mockConfigs.put(
            'CalloutTimeoutWorkflowExample_CalloutWorkflow', 
            (Workflow_Alert_Config__mdt)JSON.deserialize(
                '{"DeveloperName":"CalloutTimeoutWorkflowExample_CalloutWorkflow", "Email_Recipients__c":"test@example.com", "Enable_Alerts__c":true}', 
                Workflow_Alert_Config__mdt.class
            )
        );
        WorkflowAlertManager.sentEmailsCount = 0;

        // Set Http Callout Mock
        Test.setMock(HttpCalloutMock.class, new SingleRequestMock(200, '{"success": true}'));

        Test.startTest();
        // Pass a Map to prevent double serialization of input
        Id instanceId = WorkflowEngine.start(
            'CalloutTimeoutWorkflowExample.CalloutWorkflow', 
            'CalloutSuccessKey', 
            new Map<String, Object>{'endpoint' => 'https://httpbin.org/status/200'}
        );
        Test.stopTest(); // Executes the enqueued orchestrator queueable

        Workflow_Instance__c inst = [SELECT Status__c, Error_Message__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Completed', inst.Status__c, 'Should be Completed');
        System.assertEquals(0, WorkflowAlertManager.sentEmailsCount, 'No alert should be sent');
    }

    @isTest
    static void testCalloutFailureAndRetry() {
        WorkflowAlertManager.mockConfigs.put(
            'CalloutTimeoutWorkflowExample_CalloutWorkflow', 
            (Workflow_Alert_Config__mdt)JSON.deserialize(
                '{"DeveloperName":"CalloutTimeoutWorkflowExample_CalloutWorkflow", "Email_Recipients__c":"test@example.com", "Enable_Alerts__c":true}', 
                Workflow_Alert_Config__mdt.class
            )
        );
        WorkflowAlertManager.sentEmailsCount = 0;

        // Mock 500 error
        Test.setMock(HttpCalloutMock.class, new SingleRequestMock(500, 'Error'));

        Test.startTest();
        Id instanceId = WorkflowEngine.start('CalloutTimeoutWorkflowExample.CalloutWorkflow', 'CalloutRetryKey', null);
        Test.stopTest(); // Executes the enqueued orchestrator queueable

        List<Workflow_Step_Execution__c> stepExecs = [
            SELECT Status__c, Retry_Count__c 
            FROM Workflow_Step_Execution__c 
            WHERE Workflow_Instance__c = :instanceId
            AND Step_Name__c = 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep'
            ORDER BY CreatedDate DESC, Id DESC
        ];
        System.assert(!stepExecs.isEmpty());
        System.assertEquals('Retrying', stepExecs[0].Status__c, 'Step status should be Retrying');
        System.assertEquals(1, stepExecs[0].Retry_Count__c, 'Retry count should be 1');
    }

    @isTest
    static void testCalloutTimeoutWatchdog() {
        WorkflowAlertManager.mockConfigs.put(
            'CalloutTimeoutWorkflowExample_CalloutWorkflow', 
            (Workflow_Alert_Config__mdt)JSON.deserialize(
                '{"DeveloperName":"CalloutTimeoutWorkflowExample_CalloutWorkflow", "Email_Recipients__c":"test@example.com", "Enable_Alerts__c":true}', 
                Workflow_Alert_Config__mdt.class
            )
        );
        WorkflowAlertManager.sentEmailsCount = 0;

        // Start workflow instance and let the initial queueable run
        Id instanceId = WorkflowEngine.start('CalloutTimeoutWorkflowExample.CalloutWorkflow', 'CalloutTimeoutKey', null);
        
        Test.startTest();
        // Test.stopTest() executes the enqueued queueable to process the initial step run (which fails & schedules retry)
        Test.stopTest();

        Workflow_Instance__c inst = [
            SELECT Status__c, Current_Step__c 
            FROM Workflow_Instance__c 
            WHERE Id = :instanceId
        ];

        // Simulate step hanging in Running status
        inst.Status__c = 'Running';
        inst.Current_Step__c = 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep';
        update inst;

        List<Workflow_Step_Execution__c> stepExecs = [
            SELECT Id, Status__c FROM Workflow_Step_Execution__c 
            WHERE Workflow_Instance__c = :instanceId
            AND Step_Name__c = 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep'
            LIMIT 1
        ];
        System.assert(!stepExecs.isEmpty());
        Workflow_Step_Execution__c stepExec = stepExecs[0];
        stepExec.Status__c = 'Running';
        update stepExec;

        // Execute watchdog job
        WorkflowTimeoutJob job = new WorkflowTimeoutJob(instanceId, 'CalloutTimeoutWorkflowExample.MakeHttpCalloutStep');
        job.execute(null);

        // Verify status transitioned to Failed and email alert sent
        Workflow_Instance__c updatedInst = [SELECT Status__c, Error_Message__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Failed', updatedInst.Status__c, 'Instance should fail due to timeout');
        System.assert(updatedInst.Error_Message__c.contains('timed out'), 'Error message should contain timeout details');
        System.assertEquals(1, WorkflowAlertManager.sentEmailsCount, 'Email alert should be dispatched on watchdog timeout');
    }
}
