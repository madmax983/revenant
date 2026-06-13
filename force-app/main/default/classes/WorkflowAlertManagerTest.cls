@isTest
public class WorkflowAlertManagerTest {

    private static Workflow_Alert_Config__mdt createMockConfig(
        String devName, 
        String recipients, 
        Boolean enabled, 
        Integer consecutiveLimit, 
        Integer failLimit, 
        Integer windowMin, 
        Integer stallHours
    ) {
        Map<String, Object> fields = new Map<String, Object>{
            'DeveloperName' => devName,
            'Email_Recipients__c' => recipients,
            'Enable_Alerts__c' => enabled,
            'Consecutive_Failures_Limit__c' => consecutiveLimit,
            'Failure_Count_Limit__c' => failLimit,
            'Time_Window_Minutes__c' => windowMin,
            'Stall_Threshold_Hours__c' => stallHours
        };
        return (Workflow_Alert_Config__mdt)JSON.deserialize(
            JSON.serialize(fields), 
            Workflow_Alert_Config__mdt.class
        );
    }

    @isTest
    static void testSendAlertWithMockConfig() {
        // Mock Config
        WorkflowAlertManager.mockConfigs.put(
            'WorkflowEngineTest_HappyWorkflow', 
            createMockConfig('WorkflowEngineTest_HappyWorkflow', 'test@example.com', true, null, null, null, null)
        );
        WorkflowAlertManager.sentEmailsCount = 0;

        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Failed',
            Correlation_Key__c = 'TestKey1'
        );
        insert inst;

        // Query Name to avoid SObjectException
        inst = [SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c FROM Workflow_Instance__c WHERE Id = :inst.Id];

        Test.startTest();
        WorkflowAlertManager.sendAlert(inst, 'Some error');
        Test.stopTest();

        System.assertEquals(1, WorkflowAlertManager.sentEmailsCount, 'Alert should be sent');
    }

    @isTest
    static void testSendAlertWithDefaultConfigFallback() {
        // Setup only Default config in mock
        WorkflowAlertManager.mockConfigs.clear();
        WorkflowAlertManager.mockConfigs.put(
            'Default', 
            createMockConfig('Default', 'default@example.com', true, null, null, null, null)
        );
        WorkflowAlertManager.sentEmailsCount = 0;

        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Name__c = 'SomeRandomWorkflow',
            Status__c = 'Failed'
        );
        insert inst;
        inst = [SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c FROM Workflow_Instance__c WHERE Id = :inst.Id];

        Test.startTest();
        WorkflowAlertManager.sendAlert(inst, 'Some fallback error');
        Test.stopTest();

        System.assertEquals(1, WorkflowAlertManager.sentEmailsCount, 'Should fallback to Default and send alert');
    }

    @isTest
    static void testSendAlertWithTruncatedDevNameConfig() {
        String longWorkflowName = 'WorkflowEngineTest.HappyWorkflowWithVeryLongName';
        String expectedTruncatedDevName = longWorkflowName.replaceAll('[^a-zA-Z0-9_]', '_').substring(0, 40);
        
        WorkflowAlertManager.mockConfigs.clear();
        WorkflowAlertManager.mockConfigs.put(
            expectedTruncatedDevName, 
            createMockConfig(expectedTruncatedDevName, 'longname@example.com', true, null, null, null, null)
        );
        WorkflowAlertManager.sentEmailsCount = 0;

        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Name__c = longWorkflowName,
            Status__c = 'Failed'
        );
        insert inst;
        inst = [SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c FROM Workflow_Instance__c WHERE Id = :inst.Id];

        Test.startTest();
        WorkflowAlertManager.sendAlert(inst, 'Long workflow name error');
        Test.stopTest();

        System.assertEquals(1, WorkflowAlertManager.sentEmailsCount, 'Should resolve via truncated DeveloperName and send alert');
    }

    @isTest
    static void testSendAlertDisabled() {
        WorkflowAlertManager.mockConfigs.clear();
        WorkflowAlertManager.mockConfigs.put(
            'WorkflowEngineTest_HappyWorkflow', 
            createMockConfig('WorkflowEngineTest_HappyWorkflow', 'test@example.com', false, null, null, null, null)
        );
        WorkflowAlertManager.sentEmailsCount = 0;

        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Failed'
        );
        insert inst;
        inst = [SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c FROM Workflow_Instance__c WHERE Id = :inst.Id];

        Test.startTest();
        WorkflowAlertManager.sendAlert(inst, 'Some error');
        Test.stopTest();

        System.assertEquals(0, WorkflowAlertManager.sentEmailsCount, 'No alert should be sent because config is disabled');
    }

    @isTest
    static void testSendAlertNoRecipients() {
        WorkflowAlertManager.mockConfigs.clear();
        WorkflowAlertManager.mockConfigs.put(
            'WorkflowEngineTest_HappyWorkflow', 
            createMockConfig('WorkflowEngineTest_HappyWorkflow', '', true, null, null, null, null)
        );
        WorkflowAlertManager.sentEmailsCount = 0;

        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Failed'
        );
        insert inst;
        inst = [SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c FROM Workflow_Instance__c WHERE Id = :inst.Id];

        Test.startTest();
        WorkflowAlertManager.sendAlert(inst, 'Some error');
        Test.stopTest();

        System.assertEquals(0, WorkflowAlertManager.sentEmailsCount, 'No alert should be sent when email recipients is blank');
    }

    @isTest
    static void testConsecutiveFailuresThreshold() {
        WorkflowAlertManager.mockConfigs.clear();
        WorkflowAlertManager.mockConfigs.put(
            'WorkflowEngineTest_HappyWorkflow', 
            createMockConfig('WorkflowEngineTest_HappyWorkflow', 'test@example.com', true, 3, null, null, null)
        );
        WorkflowAlertManager.sentEmailsCount = 0;

        String wfName = 'WorkflowEngineTest.HappyWorkflow';

        // Insert first failure
        Workflow_Instance__c inst1 = new Workflow_Instance__c(Workflow_Name__c = wfName, Status__c = 'Failed');
        insert inst1;
        inst1 = [SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c FROM Workflow_Instance__c WHERE Id = :inst1.Id];
        
        WorkflowAlertManager.sendAlert(inst1, 'Err 1');
        System.assertEquals(0, WorkflowAlertManager.sentEmailsCount, 'Not sent yet (consecutive count = 1, limit = 3)');

        // Insert second failure
        Workflow_Instance__c inst2 = new Workflow_Instance__c(Workflow_Name__c = wfName, Status__c = 'Compensated');
        insert inst2;
        inst2 = [SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c FROM Workflow_Instance__c WHERE Id = :inst2.Id];
        
        WorkflowAlertManager.sendAlert(inst2, 'Err 2');
        System.assertEquals(0, WorkflowAlertManager.sentEmailsCount, 'Not sent yet (consecutive count = 2, limit = 3)');

        // Insert third failure
        Workflow_Instance__c inst3 = new Workflow_Instance__c(Workflow_Name__c = wfName, Status__c = 'Failed');
        insert inst3;
        inst3 = [SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c FROM Workflow_Instance__c WHERE Id = :inst3.Id];
        
        WorkflowAlertManager.sendAlert(inst3, 'Err 3');
        System.assertEquals(1, WorkflowAlertManager.sentEmailsCount, 'Sent alert (consecutive count = 3, limit = 3)');

        // Insert a completed one in between
        Workflow_Instance__c instComp = new Workflow_Instance__c(Workflow_Name__c = wfName, Status__c = 'Completed');
        insert instComp;

        Workflow_Instance__c inst4 = new Workflow_Instance__c(Workflow_Name__c = wfName, Status__c = 'Failed');
        insert inst4;
        inst4 = [SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c FROM Workflow_Instance__c WHERE Id = :inst4.Id];
        
        WorkflowAlertManager.sentEmailsCount = 0;
        WorkflowAlertManager.sendAlert(inst4, 'Err 4');
        System.assertEquals(0, WorkflowAlertManager.sentEmailsCount, 'Not sent because consecutive was broken by Completed');
    }

    @isTest
    static void testSlidingWindowCountThreshold() {
        WorkflowAlertManager.mockConfigs.clear();
        WorkflowAlertManager.mockConfigs.put(
            'WorkflowEngineTest_HappyWorkflow', 
            createMockConfig('WorkflowEngineTest_HappyWorkflow', 'test@example.com', true, null, 2, 10, null)
        );
        WorkflowAlertManager.sentEmailsCount = 0;

        String wfName = 'WorkflowEngineTest.HappyWorkflow';

        // Failure 1
        Workflow_Instance__c inst1 = new Workflow_Instance__c(Workflow_Name__c = wfName, Status__c = 'Failed');
        insert inst1;
        inst1 = [SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c FROM Workflow_Instance__c WHERE Id = :inst1.Id];

        WorkflowAlertManager.sendAlert(inst1, 'Err 1');
        System.assertEquals(0, WorkflowAlertManager.sentEmailsCount, 'Only 1 failure in window, need 2');

        // Failure 2
        Workflow_Instance__c inst2 = new Workflow_Instance__c(Workflow_Name__c = wfName, Status__c = 'Cancelled');
        insert inst2;
        inst2 = [SELECT Id, Name, Workflow_Name__c, Status__c, Correlation_Key__c FROM Workflow_Instance__c WHERE Id = :inst2.Id];

        WorkflowAlertManager.sendAlert(inst2, 'Err 2');
        System.assertEquals(1, WorkflowAlertManager.sentEmailsCount, '2 failures in window met, alert sent');
    }

    @isTest
    static void testWorkflowEngineAlertIntegration() {
        // Enforce mock configs
        WorkflowAlertManager.mockConfigs.clear();
        WorkflowAlertManager.mockConfigs.put(
            'WorkflowEngineTest_HappyWorkflow', 
            createMockConfig('WorkflowEngineTest_HappyWorkflow', 'test@example.com', true, null, null, null, null)
        );
        WorkflowAlertManager.sentEmailsCount = 0;

        // Create a workflow instance that starts directly
        WorkflowEngine.disableQueueableInTest = true;
        
        // Let's create an instance, set current step to something that will fail immediately
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Running',
            Current_Step__c = 'WorkflowEngineTest.FailureStep'
        );
        insert inst;

        Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
            Workflow_Instance__c = inst.Id,
            Step_Name__c = 'WorkflowEngineTest.FailureStep',
            Status__c = 'Running',
            Retry_Count__c = 0
        );
        insert stepExec;

        Test.startTest();
        // Running step which fails will run, exceed retry limits,
        // we call WorkflowEngine.failWorkflowInstance directly to test the engine's failure path
        WorkflowEngine.failWorkflowInstance(inst.Id, 'WorkflowEngineTest.FailureStep', 'Crashed and burned');
        Test.stopTest();

        // The failWorkflowInstance should transition the instance status to Failed and send an alert
        Workflow_Instance__c updatedInst = [SELECT Status__c, Error_Message__c FROM Workflow_Instance__c WHERE Id = :inst.Id];
        System.assertEquals('Failed', updatedInst.Status__c);
        System.assertEquals(1, WorkflowAlertManager.sentEmailsCount, 'Alert should be triggered by WorkflowEngine failure');
    }

    @isTest
    static void testWorkflowTimeoutJobAlert() {
        WorkflowAlertManager.mockConfigs.clear();
        WorkflowAlertManager.mockConfigs.put(
            'WorkflowEngineTest_HappyWorkflow', 
            createMockConfig('WorkflowEngineTest_HappyWorkflow', 'timeout@example.com', true, null, null, null, null)
        );
        WorkflowAlertManager.sentEmailsCount = 0;

        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Running',
            Current_Step__c = 'SomeStep'
        );
        insert inst;

        Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
            Workflow_Instance__c = inst.Id,
            Step_Name__c = 'SomeStep',
            Status__c = 'Running'
        );
        insert stepExec;

        Test.startTest();
        WorkflowTimeoutJob job = new WorkflowTimeoutJob(inst.Id, 'SomeStep');
        job.execute(null);
        Test.stopTest();

        Workflow_Instance__c updatedInst = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id];
        System.assertEquals('Failed', updatedInst.Status__c);
        System.assertEquals(1, WorkflowAlertManager.sentEmailsCount, 'Alert should be sent on timeout');
    }
}
