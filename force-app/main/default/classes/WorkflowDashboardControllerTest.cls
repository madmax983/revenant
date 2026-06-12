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
