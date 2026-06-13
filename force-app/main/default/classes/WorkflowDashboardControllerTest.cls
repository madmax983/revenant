@isTest
public class WorkflowDashboardControllerTest {

    @isTest
    static void testGetInstancesAndDetails() {
        // Create mock parent workflow instance
        Workflow_Instance__c parentInst = new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Completed',
            Correlation_Key__c = 'TestParentKey',
            Input__c = '"ParentInput"'
        );
        insert parentInst;

        // Create mock child workflow instance
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Pending',
            Correlation_Key__c = 'TestDashboardKey',
            Input__c = '"InputData"',
            Parent_Instance__c = parentInst.Id
        );
        insert inst;

        // Create mock step execution
        Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
            Workflow_Instance__c = inst.Id,
            Step_Name__c = 'WorkflowEngineTest.HappyStep1',
            Status__c = 'Completed',
            Input__c = '"InputData"',
            Output__c = '"Output1"',
            Retry_Count__c = 0
        );
        insert step;

        Test.startTest();
        List<Workflow_Instance__c> instances = WorkflowDashboardController.getInstances();
        Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(inst.Id);
        Map<String, Object> parentDetails = WorkflowDashboardController.getInstanceDetails(parentInst.Id);
        Test.stopTest();

        // Re-query parentInst to get the auto-number Name field
        parentInst = [SELECT Name FROM Workflow_Instance__c WHERE Id = :parentInst.Id];

        // Should find two instances now
        System.assertEquals(2, instances.size(), 'Should find two instances');

        Workflow_Instance__c returnedInst = (Workflow_Instance__c)details.get('instance');
        List<Workflow_Step_Execution__c> returnedSteps = (List<Workflow_Step_Execution__c>)details.get('steps');
        List<Workflow_Instance__c> returnedChildren = (List<Workflow_Instance__c>)details.get('children');

        System.assertEquals(inst.Id, returnedInst.Id);
        System.assertEquals(parentInst.Id, returnedInst.Parent_Instance__c);
        System.assertEquals(parentInst.Name, returnedInst.Parent_Instance__r.Name);
        System.assertEquals(1, returnedSteps.size(), 'Should find one step execution');
        System.assertEquals(step.Id, returnedSteps[0].Id);
        System.assertEquals(0, returnedChildren.size(), 'Child has no children');

        // Check parent's details for children
        List<Workflow_Instance__c> parentChildren = (List<Workflow_Instance__c>)parentDetails.get('children');
        System.assertEquals(1, parentChildren.size(), 'Parent should have one child');
        System.assertEquals(inst.Id, parentChildren[0].Id);
    }

    @isTest
    static void testGetDefinitions() {
        Test.startTest();
        List<String> definitions = WorkflowDashboardController.getDefinitions();
        Test.stopTest();
 
        // Should return a list of classes containing "implements WorkflowDefinition" or "implements VersionedWorkflow"
        System.assert(definitions != null, 'Definitions list should not be null');
        System.assert(definitions.contains('CleanupWorkflow'), 'Should find CleanupWorkflow');
        System.assert(definitions.contains('BatchFanoutWorkflowExample.BatchFanoutWorkflow'), 'Should find BatchFanoutWorkflowExample.BatchFanoutWorkflow inner class');
        System.assert(definitions.contains('SagaWorkflowExample.SagaWorkflow'), 'Should find SagaWorkflowExample.SagaWorkflow inner class');
    }

    @isTest
    static void testStartWorkflow() {
        Test.startTest();
        Id instanceId = WorkflowDashboardController.startWorkflow(
            'WorkflowEngineTest.HappyWorkflow',
            'StartDashboardKey',
            '"InputPayload"'
        );
        Test.stopTest();

        System.assertNotEquals(null, instanceId, 'Should start workflow and return ID');

        Workflow_Instance__c inst = [
            SELECT Workflow_Name__c, Status__c, Correlation_Key__c, Input__c 
            FROM Workflow_Instance__c 
            WHERE Id = :instanceId
        ];
        System.assertEquals('WorkflowEngineTest.HappyWorkflow', inst.Workflow_Name__c);
        System.assertEquals('StartDashboardKey', inst.Correlation_Key__c);
        System.assertEquals('"InputPayload"', inst.Input__c);
    }

    @isTest
    static void testRetryWorkflowInstance() {
        // Create a failed instance
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Failed',
            Correlation_Key__c = 'FailedKey',
            Input__c = '"InputData"',
            Current_Step__c = 'WorkflowEngineTest.HappyStep1'
        );
        insert inst;

        Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
            Workflow_Instance__c = inst.Id,
            Step_Name__c = 'WorkflowEngineTest.HappyStep1',
            Status__c = 'Failed',
            Retry_Count__c = 1,
            Error_Details__c = 'Some error'
        );
        insert step;

        Test.startTest();
        WorkflowDashboardController.retryWorkflowInstance(inst.Id);
        Test.stopTest();

        Workflow_Instance__c updatedInst = [
            SELECT Status__c, Error_Message__c 
            FROM Workflow_Instance__c 
            WHERE Id = :inst.Id
        ];
        System.assertEquals('Running', updatedInst.Status__c);
        System.assertEquals(null, updatedInst.Error_Message__c);

        Workflow_Step_Execution__c updatedStep = [
            SELECT Status__c, Retry_Count__c, Error_Details__c 
            FROM Workflow_Step_Execution__c 
            WHERE Id = :step.Id
        ];
        System.assertEquals('Completed', updatedStep.Status__c);
        System.assertEquals(0, updatedStep.Retry_Count__c);
        System.assertEquals(null, updatedStep.Error_Details__c);
    }

    @isTest
    static void testSubmitApproval() {
        // Create active instance
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Suspended',
            Correlation_Key__c = 'ApprovalKey',
            Input__c = '"InputData"'
        );
        insert inst;

        Test.startTest();
        WorkflowDashboardController.submitApproval(inst.Id, 'ExpenseApproval', true, 'Looks good');
        Test.stopTest();

        // Deliver Platform Event
        Test.getEventBus().deliver();

        // Verify a signal is received in database
        List<Workflow_Signal__c> signals = [
            SELECT Id, Signal_Name__c, Payload__c, Status__c 
            FROM Workflow_Signal__c 
            WHERE Workflow_Instance__c = :inst.Id
        ];
        System.assertEquals(1, signals.size());
        System.assertEquals('Approve:ExpenseApproval', signals[0].Signal_Name__c);
        System.assert(signals[0].Payload__c.contains('"approved":true'));
        System.assert(signals[0].Payload__c.contains('"comments":"Looks good"'));
    }

    @isTest
    static void testCancelWorkflowInstance() {
        // Create running instance
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Running',
            Correlation_Key__c = 'CancelDashKey',
            Input__c = '"InputData"'
        );
        insert inst;

        Test.startTest();
        WorkflowDashboardController.cancelWorkflow(inst.Id, false);
        Test.stopTest();

        Workflow_Instance__c updatedInst = [
            SELECT Status__c, Error_Message__c 
            FROM Workflow_Instance__c 
            WHERE Id = :inst.Id
        ];
        System.assertEquals('Cancelled', updatedInst.Status__c);
        System.assertEquals('Cancelled by user.', updatedInst.Error_Message__c);
    }

    @isTest
    static void testGetFilteredInstances() {
        // Create 3 instances with distinct details
        List<Workflow_Instance__c> testInstances = new List<Workflow_Instance__c>{
            new Workflow_Instance__c(
                Workflow_Name__c = 'TestDefA',
                Status__c = 'Completed',
                Correlation_Key__c = 'AppleKey',
                Input__c = '"TestInput"'
            ),
            new Workflow_Instance__c(
                Workflow_Name__c = 'TestDefA',
                Status__c = 'Failed',
                Correlation_Key__c = 'BananaKey',
                Input__c = '"TestInput"',
                Error_Message__c = 'Slipped on banana'
            ),
            new Workflow_Instance__c(
                Workflow_Name__c = 'TestDefB',
                Status__c = 'Running',
                Correlation_Key__c = 'OrangeKey',
                Input__c = '"TestInput"'
            )
        };
        insert testInstances;

        Test.startTest();
        // 1. Test filtering by Workflow Name
        List<Workflow_Instance__c> resWorkflow = WorkflowDashboardController.getFilteredInstances('TestDefA', '', '', 10, 0);
        System.assertEquals(2, resWorkflow.size(), 'Should find 2 instances with definition TestDefA');

        // 2. Test filtering by Status
        List<Workflow_Instance__c> resStatus = WorkflowDashboardController.getFilteredInstances('', 'Running', '', 10, 0);
        System.assertEquals(1, resStatus.size(), 'Should find 1 instance with Status Running');
        System.assertEquals('OrangeKey', resStatus[0].Correlation_Key__c);

        // 3. Test filtering by Search Term on Correlation Key
        List<Workflow_Instance__c> resSearchKey = WorkflowDashboardController.getFilteredInstances('', '', 'Banana', 10, 0);
        System.assertEquals(1, resSearchKey.size(), 'Should find 1 instance matching search Banana');
        System.assertEquals('BananaKey', resSearchKey[0].Correlation_Key__c);

        // 4. Test filtering by Search Term case-insensitivity on Correlation Key
        List<Workflow_Instance__c> resSearchError = WorkflowDashboardController.getFilteredInstances('', '', 'banana', 10, 0);
        System.assertEquals(1, resSearchError.size(), 'Search term search should be case-insensitive');

        // 5. Test pagination: limit and offset
        List<Workflow_Instance__c> page1 = WorkflowDashboardController.getFilteredInstances('', '', '', 2, 0);
        System.assertEquals(2, page1.size(), 'Page 1 limit 2 should return 2 records');

        List<Workflow_Instance__c> page2 = WorkflowDashboardController.getFilteredInstances('', '', '', 2, 2);
        System.assertEquals(1, page2.size(), 'Page 2 offset 2 limit 2 should return the remaining 1 record');
        
        Test.stopTest();
    }

    @isTest
    static void testGetWorkflowStats() {
        // Create 3 instances with distinct details
        List<Workflow_Instance__c> testInstances = new List<Workflow_Instance__c>{
            new Workflow_Instance__c(
                Workflow_Name__c = 'TestDefA',
                Status__c = 'Completed',
                Correlation_Key__c = 'AppleKey',
                Input__c = '"TestInput"'
            ),
            new Workflow_Instance__c(
                Workflow_Name__c = 'TestDefA',
                Status__c = 'Failed',
                Correlation_Key__c = 'BananaKey',
                Input__c = '"TestInput"',
                Error_Message__c = 'Slipped on banana'
            ),
            new Workflow_Instance__c(
                Workflow_Name__c = 'TestDefB',
                Status__c = 'Running',
                Correlation_Key__c = 'OrangeKey',
                Input__c = '"TestInput"'
            )
        };
        insert testInstances;

        Test.startTest();
        // 1. Get stats overall (no filters)
        Map<String, Integer> statsAll = WorkflowDashboardController.getWorkflowStats('', '', '');
        System.assertEquals(3, statsAll.get('total'), 'Should count 3 total runs');
        System.assertEquals(1, statsAll.get('active'), 'Should count 1 active run');
        System.assertEquals(1, statsAll.get('completed'), 'Should count 1 completed run');
        System.assertEquals(1, statsAll.get('failed'), 'Should count 1 failed run');

        // 2. Get stats filtered by definition A
        Map<String, Integer> statsDefA = WorkflowDashboardController.getWorkflowStats('TestDefA', '', '');
        System.assertEquals(2, statsDefA.get('total'));
        System.assertEquals(0, statsDefA.get('active'));
        System.assertEquals(1, statsDefA.get('completed'));
        System.assertEquals(1, statsDefA.get('failed'));

        // 3. Get stats filtered by search term
        Map<String, Integer> statsSearch = WorkflowDashboardController.getWorkflowStats('', '', 'Banana');
        System.assertEquals(1, statsSearch.get('total'));
        System.assertEquals(1, statsSearch.get('failed'));
        Test.stopTest();
    }
}
