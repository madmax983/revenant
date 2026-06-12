@isTest
public class WorkflowDashboardControllerTest {

    @isTest
    static void testGetInstancesAndDetails() {
        // Create mock workflow instance
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Pending',
            Correlation_Key__c = 'TestDashboardKey',
            Input__c = '"InputData"'
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
        Test.stopTest();

        System.assertEquals(1, instances.size(), 'Should find one instance');
        System.assertEquals(inst.Id, instances[0].Id);

        Workflow_Instance__c returnedInst = (Workflow_Instance__c)details.get('instance');
        List<Workflow_Step_Execution__c> returnedSteps = (List<Workflow_Step_Execution__c>)details.get('steps');

        System.assertEquals(inst.Id, returnedInst.Id);
        System.assertEquals(1, returnedSteps.size(), 'Should find one step execution');
        System.assertEquals(step.Id, returnedSteps[0].Id);
    }

    @isTest
    static void testGetDefinitions() {
        Test.startTest();
        List<String> definitions = WorkflowDashboardController.getDefinitions();
        Test.stopTest();

        // Should return a list of classes containing "implements WorkflowDefinition"
        // In the local workspace scratch org, HappyWorkflow and other definitions will be found.
        System.assert(definitions != null, 'Definitions list should not be null');
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
}
