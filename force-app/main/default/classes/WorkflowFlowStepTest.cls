@IsTest
public class WorkflowFlowStepTest {
  @IsTest
  static void testWorkflowFlowStepNullInput() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
        System.assert(
          ex.getMessage().contains('Input is null'),
          'Exception message should contain "Input is null", but got: ' +
          ex.getMessage()
        );
      }
      Test.stopTest();

      System.assert(
        caught,
        'Expected WorkflowEngine.WorkflowException to be thrown'
      );
    }
  }

  @IsTest
  static void testWorkflowFlowStepInvalidInputType() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
        System.assert(
          ex.getMessage().contains('Input must be a valid JSON object'),
          'Exception message should contain "Input must be a valid JSON object", but got: ' +
          ex.getMessage()
        );
      }
      Test.stopTest();

      System.assert(
        caught,
        'Expected WorkflowEngine.WorkflowException to be thrown'
      );
    }
  }

  @IsTest
  static void testWorkflowFlowStepNullJsonInput() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
        System.assert(
          ex.getMessage().contains('Input must be a valid JSON object'),
          'Exception message should contain "Input must be a valid JSON object", but got: ' +
          ex.getMessage()
        );
      }
      Test.stopTest();

      System.assert(
        caught,
        'Expected WorkflowEngine.WorkflowException to be thrown'
      );
    }
  }

  @IsTest
  static void testWorkflowFlowStepMissingFlowName() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
        System.assert(
          ex.getMessage().contains('flowName is required'),
          'Exception message should indicate flowName is required, but got: ' +
          ex.getMessage()
        );
      }
      Test.stopTest();

      System.assert(
        caught,
        'Expected WorkflowEngine.WorkflowException to be thrown'
      );
    }
  }

  @IsTest
  static void testWorkflowFlowStepInvalidFlowNameType() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
        System.assert(
          ex.getMessage().contains('flowName must be a String'),
          'Exception message should indicate flowName must be a String, but got: ' +
          ex.getMessage()
        );
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
        System.assert(
          ex.getMessage().contains('flowName must be a String'),
          'Exception message should indicate flowName must be a String, but got: ' +
          ex.getMessage()
        );
      }
      Test.stopTest();

      System.assert(
        caughtInt,
        'Expected WorkflowEngine.WorkflowException for integer flowName'
      );
      System.assert(
        caughtArray,
        'Expected WorkflowEngine.WorkflowException for array flowName'
      );
    }
  }

  @IsTest
  static void testWorkflowFlowStepNonExistentFlow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
        System.assert(
          ex.getMessage().contains('NonExistentFlowName_xyz'),
          'Exception message should contain the flow name, but got: ' +
          ex.getMessage()
        );
      }
      Test.stopTest();

      System.assert(
        caught,
        'Expected WorkflowEngine.WorkflowException to be thrown'
      );
    }
  }

  @IsTest
  static void testWorkflowFlowStepSuccess() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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

      System.assertEquals(
        StepResult.ActionType.COMPLETE,
        result.action,
        'Action type should be COMPLETE'
      );
      System.assertNotEquals(
        null,
        result.outputJson,
        'Output JSON should not be null'
      );
      Map<String, Object> outputMap = (Map<String, Object>) JSON.deserializeUntyped(
        result.outputJson
      );
      System.assertEquals(
        'HelloFlow',
        outputMap.get('outputVal'),
        'outputVal should be HelloFlow'
      );
    }
  }

  @IsTest
  static void testWorkflowFlowStepGuardedAgainstDoubleFire() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 1. Create a StepContext for first execution
      Id instanceId = '00D000000000001EAA';
      StepContext ctx1 = new StepContext(
        instanceId,
        'MyWorkflow',
        'MyStep',
        '{"flowName": "Test_Side_Effect_Flow", "variables": {"accountName": "TDD_Flow_Guard_Test"}}',
        null,
        null,
        null
      );

      // Verify initial count of Accounts with that name
      System.assertEquals(
        0,
        [SELECT COUNT() FROM Account WHERE Name = 'TDD_Flow_Guard_Test']
      );

      Test.startTest();
      // 2. First execution
      WorkflowFlowStep step = new WorkflowFlowStep();
      StepResult result1 = step.execute(ctx1);
      System.assertEquals(StepResult.ActionType.COMPLETE, result1.action);

      // Verify 1 Account was inserted
      System.assertEquals(
        1,
        [SELECT COUNT() FROM Account WHERE Name = 'TDD_Flow_Guard_Test']
      );

      // 3. Serialize captured values from first run
      String capturedJson = ctx1.getCapturedValuesJson();
      System.assertNotEquals(null, capturedJson);

      // 4. Create StepContext for second execution, seeded with the captured values from the first execution
      StepContext ctx2 = StepContext.withCapturedValues(
        instanceId,
        'MyWorkflow',
        'MyStep',
        '{"flowName": "Test_Side_Effect_Flow", "variables": {"accountName": "TDD_Flow_Guard_Test"}}',
        null,
        null,
        null,
        1,
        0,
        null,
        null,
        capturedJson
      );

      // 5. Second execution
      StepResult result2 = step.execute(ctx2);
      System.assertEquals(StepResult.ActionType.COMPLETE, result2.action);
      Test.stopTest();

      // Verify that NO second Account was inserted! Count remains 1.
      System.assertEquals(
        1,
        [SELECT COUNT() FROM Account WHERE Name = 'TDD_Flow_Guard_Test']
      );
    }
  }

  @IsTest
  static void testWorkflowFlowStepNullContext() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowFlowStep step = new WorkflowFlowStep();
      Test.startTest();
      Boolean caught = false;
      try {
        step.execute(null);
      } catch (WorkflowEngine.WorkflowException ex) {
        caught = true;
        Assert.isTrue(
          ex.getMessage().contains('Input is null'),
          'Exception message should contain Input is null'
        );
      }
      Test.stopTest();
      Assert.isTrue(caught, 'Expected WorkflowException for null context');
    }
  }

  @IsTest
  static void testWorkflowFlowStepInvalidVariablesType() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowFlowStep step = new WorkflowFlowStep();
      StepContext ctx = new StepContext(
        null,
        'MyWorkflow',
        'MyStep',
        '{"flowName": "Test_Autolaunched_Flow", "variables": "invalid_string_type"}',
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
        Assert.isTrue(
          ex.getMessage().contains('variables must be a JSON object'),
          'Expected variables validation error, got: ' + ex.getMessage()
        );
      }
      Test.stopTest();
      Assert.isTrue(
        caught,
        'Expected WorkflowException for invalid variables structure'
      );
    }
  }

  @IsTest
  static void testWorkflowFlowStepOmittedVariables() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowFlowStep step = new WorkflowFlowStep();
      StepContext ctx = new StepContext(
        null,
        'MyWorkflow',
        'MyStep',
        '{"flowName": "Test_Autolaunched_Flow"}',
        null,
        null,
        null
      );

      Test.startTest();
      StepResult result = step.execute(ctx);
      Test.stopTest();

      Assert.areEqual(StepResult.ActionType.COMPLETE, result.action);
    }
  }

  @IsTest
  static void testWorkflowFlowStepBypassesMetadataCheckOnReplay() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = '00D000000000001EAA';

      // Seed captured values with a cached output for a non-existent/deactivated flow.
      Map<String, Object> cachedOutputs = new Map<String, Object>{
        'outputVal' => 'CachedValue'
      };
      Map<String, Object> capturesMap = new Map<String, Object>{
        'flow_output_nonexistent_or_deactivated_flow' => cachedOutputs
      };
      String capturedJson = JSON.serialize(capturesMap);

      // Create a context for the re-execution with the non-existent flow name in the input JSON,
      // pre-seeded with the captured values.
      StepContext ctx = StepContext.withCapturedValues(
        instanceId,
        'MyWorkflow',
        'MyStep',
        '{"flowName": "NonExistent_Or_Deactivated_Flow"}',
        null,
        null,
        null,
        1,
        0,
        null,
        null,
        capturedJson
      );

      WorkflowFlowStep step = new WorkflowFlowStep();

      Test.startTest();
      // This should complete successfully by returning the cached output, bypassing the FlowDefinitionView SOQL check.
      StepResult result = step.execute(ctx);
      Test.stopTest();

      Assert.areEqual(StepResult.ActionType.COMPLETE, result.action);
      Assert.isNotNull(result.outputJson);
      Map<String, Object> outputMap = (Map<String, Object>) JSON.deserializeUntyped(
        result.outputJson
      );
      Assert.areEqual('CachedValue', outputMap.get('outputVal'));
    }
  }
}
