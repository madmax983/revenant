@isTest
public class WorkflowFlowStepTest {

    @isTest
    static void testWorkflowFlowStepNullInput() {
        WorkflowFlowStep step = new WorkflowFlowStep();
        StepContext ctx = new StepContext(null, 'MyWorkflow', 'MyStep', null, null, null, null);

        Test.startTest();
        StepResult result = step.execute(ctx);
        Test.stopTest();

        System.assertEquals(StepResult.ActionType.COMPLETE, result.action);
        System.assertNotEquals(null, result.outputJson);
        Map<String, Object> outputMap = (Map<String, Object>)JSON.deserializeUntyped(result.outputJson);
        System.assertEquals('Input is null', outputMap.get('error'));
    }

    @isTest
    static void testWorkflowFlowStepInvalidInputType() {
        WorkflowFlowStep step = new WorkflowFlowStep();
        StepContext ctx = new StepContext(null, 'MyWorkflow', 'MyStep', 'Not a JSON Map', null, null, null);

        Test.startTest();
        StepResult result = step.execute(ctx);
        Test.stopTest();

        System.assertEquals(StepResult.ActionType.COMPLETE, result.action);
        System.assertNotEquals(null, result.outputJson);
        Map<String, Object> outputMap = (Map<String, Object>)JSON.deserializeUntyped(result.outputJson);
        System.assertEquals('Input must be a valid JSON object', outputMap.get('error'));
    }

    @isTest
    static void testWorkflowFlowStepMissingFlowName() {
        WorkflowFlowStep step = new WorkflowFlowStep();
        StepContext ctx = new StepContext(null, 'MyWorkflow', 'MyStep', '{"variables": {}}', null, null, null);

        Test.startTest();
        StepResult result = step.execute(ctx);
        Test.stopTest();

        System.assertEquals(StepResult.ActionType.COMPLETE, result.action);
        System.assertNotEquals(null, result.outputJson);
        Map<String, Object> outputMap = (Map<String, Object>)JSON.deserializeUntyped(result.outputJson);
        System.assertEquals('flowName is required in input', outputMap.get('error'));
    }

    @isTest
    static void testWorkflowFlowStepNonExistentFlow() {
        WorkflowFlowStep step = new WorkflowFlowStep();
        StepContext ctx = new StepContext(
            null, 
            'MyWorkflow', 
            'MyStep', 
            '{"flowName": "NonExistentFlowName_xyz", "variables": {"myVar": "test"}, "outputs": ["outVar"]}', 
            null, 
            null, 
            null
        );

        Test.startTest();
        StepResult result = step.execute(ctx);
        Test.stopTest();

        System.assertEquals(StepResult.ActionType.COMPLETE, result.action);
        System.assertNotEquals(null, result.outputJson);
        Map<String, Object> outputMap = (Map<String, Object>)JSON.deserializeUntyped(result.outputJson);
        System.assert(outputMap.containsKey('error'), 'Should contain an error key');
        System.assert(((String)outputMap.get('error')).contains('NonExistentFlowName_xyz'), 'Error should mention flow name');
    }
}
