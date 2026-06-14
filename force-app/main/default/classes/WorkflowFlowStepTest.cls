@isTest
public class WorkflowFlowStepTest {
  @isTest
  static void testWorkflowFlowStepNullInput() {
    WorkflowFlowStep step = new WorkflowFlowStep();
    StepContext ctx = new StepContext(
      null,
      'MyWorkflow',
      'MyStep',
      null,
      null,
      null,
      null
    );

    Test.startTest();
    Boolean caught = false;
    try {
      step.execute(ctx);
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = true;
      System.assert(ex.getMessage().contains('Input is null'), 'Exception message should contain "Input is null", but got: ' + ex.getMessage());
    }
    Test.stopTest();

    System.assert(caught, 'Expected WorkflowEngine.WorkflowException to be thrown');
  }

  @isTest
  static void testWorkflowFlowStepInvalidInputType() {
    WorkflowFlowStep step = new WorkflowFlowStep();
    StepContext ctx = new StepContext(
      null,
      'MyWorkflow',
      'MyStep',
      'Not a JSON Map',
      null,
      null,
      null
    );

    Test.startTest();
    Boolean caught = false;
    try {
      step.execute(ctx);
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = true;
      System.assert(ex.getMessage().contains('Input must be a valid JSON object'), 'Exception message should contain "Input must be a valid JSON object", but got: ' + ex.getMessage());
    }
    Test.stopTest();

    System.assert(caught, 'Expected WorkflowEngine.WorkflowException to be thrown');
  }

  @isTest
  static void testWorkflowFlowStepNullJsonInput() {
    WorkflowFlowStep step = new WorkflowFlowStep();
    StepContext ctx = new StepContext(
      null,
      'MyWorkflow',
      'MyStep',
      'null',
      null,
      null,
      null
    );

    Test.startTest();
    Boolean caught = false;
    try {
      step.execute(ctx);
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = true;
      System.assert(ex.getMessage().contains('Input must be a valid JSON object'), 'Exception message should contain "Input must be a valid JSON object", but got: ' + ex.getMessage());
    }
    Test.stopTest();

    System.assert(caught, 'Expected WorkflowEngine.WorkflowException to be thrown');
  }

  @isTest
  static void testWorkflowFlowStepMissingFlowName() {
    WorkflowFlowStep step = new WorkflowFlowStep();
    StepContext ctx = new StepContext(
      null,
      'MyWorkflow',
      'MyStep',
      '{"variables": {}}',
      null,
      null,
      null
    );

    Test.startTest();
    Boolean caught = false;
    try {
      step.execute(ctx);
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = true;
      System.assert(ex.getMessage().contains('flowName is required'), 'Exception message should indicate flowName is required, but got: ' + ex.getMessage());
    }
    Test.stopTest();

    System.assert(caught, 'Expected WorkflowEngine.WorkflowException to be thrown');
  }

  @isTest
  static void testWorkflowFlowStepInvalidFlowNameType() {
    WorkflowFlowStep step = new WorkflowFlowStep();
    
    // Test flowName as an integer
    StepContext ctxInt = new StepContext(
      null,
      'MyWorkflow',
      'MyStep',
      '{"flowName": 123, "variables": {}}',
      null,
      null,
      null
    );

    Test.startTest();
    Boolean caughtInt = false;
    try {
      step.execute(ctxInt);
    } catch (WorkflowEngine.WorkflowException ex) {
      caughtInt = true;
      System.assert(ex.getMessage().contains('flowName must be a String'), 'Exception message should indicate flowName must be a String, but got: ' + ex.getMessage());
    }

    // Test flowName as an array/list
    StepContext ctxArray = new StepContext(
      null,
      'MyWorkflow',
      'MyStep',
      '{"flowName": ["TestFlow"], "variables": {}}',
      null,
      null,
      null
    );

    Boolean caughtArray = false;
    try {
      step.execute(ctxArray);
    } catch (WorkflowEngine.WorkflowException ex) {
      caughtArray = true;
      System.assert(ex.getMessage().contains('flowName must be a String'), 'Exception message should indicate flowName must be a String, but got: ' + ex.getMessage());
    }
    Test.stopTest();

    System.assert(caughtInt, 'Expected WorkflowEngine.WorkflowException for integer flowName');
    System.assert(caughtArray, 'Expected WorkflowEngine.WorkflowException for array flowName');
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
    Boolean caught = false;
    try {
      step.execute(ctx);
    } catch (WorkflowEngine.WorkflowException ex) {
      caught = true;
      System.assert(ex.getMessage().contains('NonExistentFlowName_xyz'), 'Exception message should contain the flow name, but got: ' + ex.getMessage());
    }
    Test.stopTest();

    System.assert(caught, 'Expected WorkflowEngine.WorkflowException to be thrown');
  }

  @isTest
  static void testWorkflowFlowStepSuccess() {
    WorkflowFlowStep step = new WorkflowFlowStep();
    StepContext ctx = new StepContext(
      null,
      'MyWorkflow',
      'MyStep',
      '{"flowName": "Test_Autolaunched_Flow", "variables": {"inputVal": "HelloFlow"}}',
      null,
      null,
      null
    );

    Test.startTest();
    StepResult result = step.execute(ctx);
    Test.stopTest();

    System.assertEquals(StepResult.ActionType.COMPLETE, result.action, 'Action type should be COMPLETE');
    System.assertNotEquals(null, result.outputJson, 'Output JSON should not be null');
    Map<String, Object> outputMap = (Map<String, Object>) JSON.deserializeUntyped(result.outputJson);
    System.assertEquals('HelloFlow', outputMap.get('outputVal'), 'outputVal should be HelloFlow');
  }
}
