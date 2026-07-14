@IsTest
public class WorkflowFlowStepTest {
  @IsTest
  static void testWorkflowFlowStepNullInput() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowFlowStep step = new WorkflowFlowStep();
      StepContext ctx = new StepContext.Builder()
        .instanceId(null)
        .workflowName('MyWorkflow')
        .stepName('MyStep')
        .inputJson(null)
        .previousStepOutput(null)
        .stepStateJson(null)
        .workflowInputJson(null)
        .build();

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

  // Shared driver: executes WorkflowFlowStep with the given input JSON and returns
  // the thrown WorkflowException message (or null if none was thrown). Consolidates
  // the StepContext construction and execute/try-catch block previously duplicated
  // across the invalid-input-type and null-json-input tests. Assertions stay in the
  // callers so each test documents its own expectations.
  private static String captureInvalidInputMessage(String inputJson) {
    WorkflowFlowStep step = new WorkflowFlowStep();
    StepContext ctx = new StepContext.Builder()
      .instanceId(null)
      .workflowName('MyWorkflow')
      .stepName('MyStep')
      .inputJson(inputJson)
      .previousStepOutput(null)
      .stepStateJson(null)
      .workflowInputJson(null)
      .build();

    Test.startTest();
    String message = null;
    try {
      step.execute(ctx);
    } catch (WorkflowEngine.WorkflowException ex) {
      message = ex.getMessage();
    }
    Test.stopTest();
    return message;
  }

  @IsTest
  static void testWorkflowFlowStepInvalidInputType() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String message = captureInvalidInputMessage('Not a JSON Map');
      System.assert(
        message != null,
        'Expected WorkflowEngine.WorkflowException to be thrown'
      );
      System.assert(
        message.contains('Input must be a valid JSON object'),
        'Exception message should contain "Input must be a valid JSON object", but got: ' +
        message
      );
    }
  }

  @IsTest
  static void testWorkflowFlowStepNullJsonInput() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String message = captureInvalidInputMessage('null');
      System.assert(
        message != null,
        'Expected WorkflowEngine.WorkflowException to be thrown'
      );
      System.assert(
        message.contains('Input must be a valid JSON object'),
        'Exception message should contain "Input must be a valid JSON object", but got: ' +
        message
      );
    }
  }

  @IsTest
  static void testWorkflowFlowStepMissingFlowName() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowFlowStep step = new WorkflowFlowStep();
      StepContext ctx = new StepContext.Builder()
        .instanceId(null)
        .workflowName('MyWorkflow')
        .stepName('MyStep')
        .inputJson('{"variables": {}}')
        .previousStepOutput(null)
        .stepStateJson(null)
        .workflowInputJson(null)
        .build();

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
      StepContext ctxInt = new StepContext.Builder()
        .instanceId(null)
        .workflowName('MyWorkflow')
        .stepName('MyStep')
        .inputJson('{"flowName": 123, "variables": {}}')
        .previousStepOutput(null)
        .stepStateJson(null)
        .workflowInputJson(null)
        .build();

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
      StepContext ctxArray = new StepContext.Builder()
        .instanceId(null)
        .workflowName('MyWorkflow')
        .stepName('MyStep')
        .inputJson('{"flowName": ["TestFlow"], "variables": {}}')
        .previousStepOutput(null)
        .stepStateJson(null)
        .workflowInputJson(null)
        .build();

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
      StepContext ctx = new StepContext.Builder()
        .instanceId(null)
        .workflowName('MyWorkflow')
        .stepName('MyStep')
        .inputJson(
          '{"flowName": "NonExistentFlowName_xyz", "variables": {"myVar": "test"}, "outputs": ["outVar"]}'
        )
        .previousStepOutput(null)
        .stepStateJson(null)
        .workflowInputJson(null)
        .build();

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
      StepContext ctx = new StepContext.Builder()
        .instanceId(null)
        .workflowName('MyWorkflow')
        .stepName('MyStep')
        .inputJson(
          '{"flowName": "Test_Autolaunched_Flow", "variables": {"inputVal": "HelloFlow"}}'
        )
        .previousStepOutput(null)
        .stepStateJson(null)
        .workflowInputJson(null)
        .build();

      Test.startTest();
      StepResult result = step.execute(ctx);
      Test.stopTest();

      System.assertEquals(
        StepResult.ActionType.COMPLETE,
        result.directive().action,
        'Action type should be COMPLETE'
      );
      System.assertNotEquals(
        null,
        result.directive().outputJson,
        'Output JSON should not be null'
      );
      Map<String, Object> outputMap = (Map<String, Object>) JSON.deserializeUntyped(
        result.directive().outputJson
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
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx1 = new StepContext.Builder()
        .instanceId(instanceId)
        .workflowName('MyWorkflow')
        .stepName('MyStep')
        .inputJson(
          '{"flowName": "Test_Side_Effect_Flow", "variables": {"accountName": "TDD_Flow_Guard_Test"}}'
        )
        .previousStepOutput(null)
        .stepStateJson(null)
        .workflowInputJson(null)
        .build();

      // Verify initial count of Accounts with that name
      System.assertEquals(
        0,
        [SELECT COUNT() FROM Account WHERE Name = 'TDD_Flow_Guard_Test']
      );

      Test.startTest();
      // 2. First execution
      WorkflowFlowStep step = new WorkflowFlowStep();
      StepResult result1 = step.execute(ctx1);
      System.assertEquals(
        StepResult.ActionType.COMPLETE,
        result1.directive().action
      );

      // Verify 1 Account was inserted
      System.assertEquals(
        1,
        [SELECT COUNT() FROM Account WHERE Name = 'TDD_Flow_Guard_Test']
      );

      // 3. Serialize captured values from first run
      String capturedJson = ctx1.captures().getCapturedValuesJson();
      System.assertNotEquals(null, capturedJson);

      // 4. Create StepContext for second execution, seeded with the captured values from the first execution
      StepContext ctx2 = new StepContext.Builder()
        .instanceId(instanceId)
        .workflowName('MyWorkflow')
        .stepName('MyStep')
        .inputJson(
          '{"flowName": "Test_Side_Effect_Flow", "variables": {"accountName": "TDD_Flow_Guard_Test"}}'
        )
        .previousStepOutput(null)
        .stepStateJson(null)
        .workflowInputJson(null)
        .workflowVersion(1)
        .stepVisit(0)
        .signalSource(null)
        .previousRunAt(null)
        .capturedValuesJson(capturedJson)
        .build();

      // 5. Second execution
      StepResult result2 = step.execute(ctx2);
      System.assertEquals(
        StepResult.ActionType.COMPLETE,
        result2.directive().action
      );
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
      StepContext ctx = new StepContext.Builder()
        .instanceId(null)
        .workflowName('MyWorkflow')
        .stepName('MyStep')
        .inputJson(
          '{"flowName": "Test_Autolaunched_Flow", "variables": "invalid_string_type"}'
        )
        .previousStepOutput(null)
        .stepStateJson(null)
        .workflowInputJson(null)
        .build();

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
      StepContext ctx = new StepContext.Builder()
        .instanceId(null)
        .workflowName('MyWorkflow')
        .stepName('MyStep')
        .inputJson('{"flowName": "Test_Autolaunched_Flow"}')
        .previousStepOutput(null)
        .stepStateJson(null)
        .workflowInputJson(null)
        .build();

      Test.startTest();
      StepResult result = step.execute(ctx);
      Test.stopTest();

      Assert.areEqual(
        StepResult.ActionType.COMPLETE,
        result.directive().action
      );
    }
  }

  @IsTest
  static void testWorkflowFlowStepBypassesMetadataCheckOnReplay() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);

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
      StepContext ctx = new StepContext.Builder()
        .instanceId(instanceId)
        .workflowName('MyWorkflow')
        .stepName('MyStep')
        .inputJson('{"flowName": "NonExistent_Or_Deactivated_Flow"}')
        .previousStepOutput(null)
        .stepStateJson(null)
        .workflowInputJson(null)
        .workflowVersion(1)
        .stepVisit(0)
        .signalSource(null)
        .previousRunAt(null)
        .capturedValuesJson(capturedJson)
        .build();

      WorkflowFlowStep step = new WorkflowFlowStep();

      Test.startTest();
      // This should complete successfully by returning the cached output, bypassing the FlowDefinitionView SOQL check.
      StepResult result = step.execute(ctx);
      Test.stopTest();

      Assert.areEqual(
        StepResult.ActionType.COMPLETE,
        result.directive().action
      );
      Assert.isNotNull(result.directive().outputJson);
      Map<String, Object> outputMap = (Map<String, Object>) JSON.deserializeUntyped(
        result.directive().outputJson
      );
      Assert.areEqual('CachedValue', outputMap.get('outputVal'));
    }
  }
}
