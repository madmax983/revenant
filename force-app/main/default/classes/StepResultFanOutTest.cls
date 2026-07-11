@IsTest
public class StepResultFanOutTest {
  // ==========================================
  // MOCK WORKFLOWS & STEPS
  // ==========================================

  public class SimpleChildWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'StepResultFanOutTest.ChildStep' };
    }
    public String getInitialStep() {
      return 'StepResultFanOutTest.ChildStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  public class ChildStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.workflowInputJson
      );
      Integer val = ((Decimal) input.get('val')).intValue();
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'result' => val * 10 }
      );
    }
  }

  public class ParentWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'StepResultFanOutTest.ParentStep' };
    }
    public String getInitialStep() {
      return 'StepResultFanOutTest.ParentStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  public class ParentStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String key1 = 'Child1_' + ctx.workflowInstanceId;
      String key2 = 'Child2_' + ctx.workflowInstanceId;

      StepContext.ChildOutcome outcome1 = ctx.getChildOutcome(key1);
      StepContext.ChildOutcome outcome2 = ctx.getChildOutcome(key2);

      if (outcome1.isPresent() && outcome2.isPresent()) {
        Map<String, Object> res1 = (Map<String, Object>) JSON.deserializeUntyped(
          WorkflowEngine.resolvePayload(outcome1.output)
        );
        Map<String, Object> res2 = (Map<String, Object>) JSON.deserializeUntyped(
          WorkflowEngine.resolvePayload(outcome2.output)
        );
        Integer val1 = ((Decimal) res1.get('result')).intValue();
        Integer val2 = ((Decimal) res2.get('result')).intValue();
        return StepResult.complete(
          null,
          new Map<String, Object>{ 'sum' => val1 + val2 }
        );
      }

      List<StepResult.ChildRequest> reqs = new List<StepResult.ChildRequest>{
        new StepResult.ChildRequest(
          'StepResultFanOutTest.SimpleChildWorkflow',
          key1,
          new Map<String, Object>{ 'val' => 3 }
        ),
        new StepResult.ChildRequest(
          'StepResultFanOutTest.SimpleChildWorkflow',
          key2,
          new Map<String, Object>{ 'val' => 5 }
        )
      };
      return StepResult.startChildren(reqs);
    }
  }

  public class SuspendingChildWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'StepResultFanOutTest.SuspendingChildStep' };
    }
    public String getInitialStep() {
      return 'StepResultFanOutTest.SuspendingChildStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  public class SuspendingChildStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.suspend();
    }
  }

  public class ParallelGatingWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepResultFanOutTest.ParallelSplitStep',
        'StepResultFanOutTest.FanOutStep',
        'StepResultFanOutTest.SignalStep',
        'StepResultFanOutTest.ParallelJoinStep'
      };
    }
    public String getInitialStep() {
      return 'StepResultFanOutTest.ParallelSplitStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'StepResultFanOutTest.ParallelSplitStep') {
        return 'StepResultFanOutTest.ParallelJoinStep';
      }
      return null;
    }
  }

  public class ParallelSplitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'StepResultFanOutTest.FanOutStep',
          'StepResultFanOutTest.SignalStep'
        }
      );
    }
  }

  public class FanOutStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String key1 = 'ChildKey1_' + ctx.workflowInstanceId;
      StepContext.ChildOutcome outcome1 = ctx.getChildOutcome(key1);
      if (outcome1.isPresent()) {
        return StepResult.complete(null, null);
      }
      List<StepResult.ChildRequest> reqs = new List<StepResult.ChildRequest>{
        new StepResult.ChildRequest(
          'StepResultFanOutTest.SuspendingChildWorkflow',
          key1,
          new Map<String, Object>{ 'val' => 10 }
        )
      };
      return StepResult.startChildren(reqs);
    }
  }

  public class SignalStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (ctx.getSignal('MyExternalSignal').isPresent()) {
        return StepResult.complete(null, 'SignalReceived');
      }
      return StepResult.suspend();
    }
  }

  public class ParallelJoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  // ==========================================
  // UNIT TESTS
  // ==========================================

  @IsTest
  static void testStartChildrenFactory() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<StepResult.ChildRequest> requests = new List<StepResult.ChildRequest>{
        new StepResult.ChildRequest(
          'WorkflowA',
          'KeyA',
          new Map<String, Object>{ 'val' => 1 }
        ),
        new StepResult.ChildRequest(
          'WorkflowB',
          'KeyB',
          new Map<String, Object>{ 'val' => 2 }
        )
      };

      StepResult result = StepResult.startChildren(requests);

      System.assertEquals(StepResult.ActionType.START_CHILDREN, result.action);
      System.assertEquals(2, result.childRequests.size());
      System.assertEquals('WorkflowA', result.childRequests[0].workflowName);
      System.assertEquals('KeyA', result.childRequests[0].correlationKey);
      System.assert(result.childRequests[0].inputJson.contains('"val"'));
    }
  }

  @IsTest
  static void testGetChildOutcomes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);

      List<StepContext.Signal> signals = new List<StepContext.Signal>{
        new StepContext.Signal(
          null,
          'ChildCompleted:KeyA',
          '{"result":"successA"}'
        ),
        new StepContext.Signal(
          null,
          'ChildFailed:KeyB',
          '{"status":"Failed","errorMessage":"errorB","output":null}'
        )
      };

      StepContext ctx = new StepContext.Builder()
        .instanceId(dummyInstanceId)
        .workflowName('TestWorkflow')
        .stepName('TestStep')
        .inputJson('{}')
        .previousStepOutput('{}')
        .stepStateJson('{}')
        .workflowInputJson('{}')
        .workflowVersion(1)
        .pendingSignals(signals)
        .build();

      List<StepContext.ChildOutcome> outcomes = ctx.getChildOutcomes(
        new List<String>{ 'KeyA', 'KeyB', 'KeyC' }
      );

      System.assertEquals(3, outcomes.size());

      // KeyA should be completed/success
      System.assertEquals(true, outcomes[0].isPresent());
      System.assertEquals(true, outcomes[0].isSuccess());
      System.assertEquals('Completed', outcomes[0].status);
      System.assertEquals('{"result":"successA"}', outcomes[0].output);

      // KeyB should be failed
      System.assertEquals(true, outcomes[1].isPresent());
      System.assertEquals(false, outcomes[1].isSuccess());
      System.assertEquals('Failed', outcomes[1].status);
      System.assertEquals('errorB', outcomes[1].errorMessage);

      // KeyC should not be present
      System.assertEquals(false, outcomes[2].isPresent());
    }
  }

  @IsTest
  static void testParallelChildFanOutAndJoin() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id parentId = WorkflowEngine.start(
        'StepResultFanOutTest.ParentWorkflow',
        'ParentKey_' + Crypto.getRandomInteger(),
        null
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(parentId);
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      System.assertEquals('Completed', result.status);

      Workflow_Instance__c parentInst = [
        SELECT Output__c
        FROM Workflow_Instance__c
        WHERE Id = :parentId
      ];
      Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(
        WorkflowEngine.resolvePayload(parentInst.Output__c)
      );
      System.assertEquals(80, ((Decimal) output.get('sum')).intValue());
    }
  }

  @IsTest
  static void testStepResultValidation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 1. startChildren validation
      try {
        StepResult.startChildren(null);
        System.assert(false, 'Should have failed on null list');
      } catch (IllegalArgumentException e) {
        System.assert(e.getMessage().contains('StepResult.startChildren'));
      }

      try {
        StepResult.startChildren(new List<StepResult.ChildRequest>());
        System.assert(false, 'Should have failed on empty list');
      } catch (IllegalArgumentException e) {
        System.assert(e.getMessage().contains('StepResult.startChildren'));
      }

      // 2. split validation
      try {
        StepResult.split(null);
        System.assert(false, 'Should have failed on null list');
      } catch (IllegalArgumentException e) {
        System.assert(e.getMessage().contains('StepResult.split'));
      }

      try {
        StepResult.split(new List<String>());
        System.assert(false, 'Should have failed on empty list');
      } catch (IllegalArgumentException e) {
        System.assert(e.getMessage().contains('StepResult.split'));
      }
    }
  }

  @IsTest
  static void testSafeDoubleSerialization() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String inputJson = '{"val":123}';
      StepResult res = StepResult.startChild('WorkflowA', 'KeyA', inputJson);
      System.assertEquals(
        '{"val":123}',
        res.childInputJson,
        'Should not double-serialize pre-serialized JSON string'
      );

      StepResult res2 = StepResult.startChild(
        'WorkflowA',
        'KeyA',
        'Plain string'
      );
      System.assertEquals(
        '"Plain string"',
        res2.childInputJson,
        'Should serialize plain string'
      );
    }
  }

  @IsTest
  static void testInvalidWorkflowTypeVerification() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      try {
        WorkflowEngine.start(
          'InvalidWorkflowClassNameNonExistent',
          'Key_' + Crypto.getRandomInteger(),
          null
        );
        System.assert(
          false,
          'Should have thrown exception on invalid workflow class name'
        );
      } catch (Exception e) {
        System.assert(e.getMessage().contains('workflow definition'));
      }
      Test.stopTest();
    }
  }

  @IsTest
  static void testCaseInsensitiveChildKeyMatching() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id parentId = WorkflowEngine.start(
        'StepResultFanOutTest.ParentWorkflow',
        'ParentKey_' + Crypto.getRandomInteger(),
        null
      );

      // We manually insert an active sibling child instance with mixed case.
      Workflow_Instance__c child = new Workflow_Instance__c();
      child.Workflow_Name__c = 'StepResultFanOutTest.SimpleChildWorkflow';
      child.Status__c = 'Pending';
      child.Correlation_Key__c = 'child1_' + parentId; // lowercase child1
      child.Parent_Instance__c = parentId;
      child.Current_Step__c = 'StepResultFanOutTest.ChildStep';
      insert as system child;

      // Call WorkflowEngine.startChildWorkflow with the matching correlation key in mixed case (e.g. 'Child1_')
      // Under our case-insensitive check, this call should resolve to a no-op (idempotent re-suspend)
      // rather than throwing a duplicate key exception or trying to insert a new row.
      try {
        WorkflowEngine.startChildWorkflow(
          parentId,
          'StepResultFanOutTest.SimpleChildWorkflow',
          'Child1_' + parentId,
          '{}'
        );
        System.assert(
          true,
          'Should have resolved idempotently without throwing a duplicate exception'
        );
      } catch (Exception ex) {
        System.assert(
          false,
          'Should not have thrown exception: ' + ex.getMessage()
        );
      }
      Test.stopTest();
    }
  }

  @IsTest
  static void testParallelChildFanOutWithConcurrencyGate() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Mock the child workflow to have a ConcurrencyGate configured with ceiling = 1
      ConcurrencyGate.mockConfigs.put(
        'StepResultFanOutTest.SimpleChildWorkflow',
        new Concurrency_Config__mdt(
          Label = 'StepResultFanOutTest.SimpleChildWorkflow',
          DeveloperName = 'SimpleChildWorkflow',
          Max_Concurrent_Instances__c = 1
        )
      );

      Test.startTest();
      Id parentId = WorkflowEngine.start(
        'StepResultFanOutTest.ParentWorkflow',
        'ParentKey_' + Crypto.getRandomInteger(),
        null
      );

      // Drive parent to start children. Under the hood, this will spawn Child1 and Child2.
      // Both will be marked concurrency parked, but must still be advanceable and complete.
      WorkflowTestHarness harness = new WorkflowTestHarness(parentId);
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      // Verify parent completes successfully
      System.assertEquals(
        'Completed',
        result.status,
        'Parent workflow should complete'
      );

      // Verify child instances exist and completed
      List<Workflow_Instance__c> children = [
        SELECT Id, Status__c, Concurrency_Parked__c, Concurrency_Slot_Held__c
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :parentId
      ];
      System.assertEquals(
        2,
        children.size(),
        'Should have started 2 child instances'
      );
      for (Workflow_Instance__c child : children) {
        System.assertEquals(
          'Completed',
          child.Status__c,
          'Child should have completed'
        );
      }
    }
  }

  @IsTest
  static void testParallelBranchSignalNotGatedByChildFanOut() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id parentId = WorkflowEngine.start(
        'StepResultFanOutTest.ParallelGatingWorkflow',
        'ParentKey_' + Crypto.getRandomInteger(),
        null
      );

      // Split step runs and both branches are executed, suspending parent.
      WorkflowTestHarness harness = new WorkflowTestHarness(parentId);
      WorkflowTestHarness.Result r1 = harness.drive();

      System.assertEquals('Suspended', r1.status);

      // Let's verify that the child workflow is active/pending.
      List<Workflow_Instance__c> children = [
        SELECT Id, Status__c
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :parentId
      ];
      System.assertEquals(1, children.size());
      System.assertEquals('Suspended', children[0].Status__c);

      // Now, send the external signal "MyExternalSignal" to the parent workflow.
      // Because it is an unrelated signal, it must NOT be gated by the child-readiness barrier.
      // It should wake the parent to 'Running'.
      WorkflowEngine.signal(parentId, 'MyExternalSignal', 'SomePayload');

      // Reload the parent.
      Workflow_Instance__c parentReloaded = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :parentId
      ];
      System.assertEquals(
        'Running',
        parentReloaded.Status__c,
        'Parent must be woken to Running by the sibling signal'
      );

      Test.stopTest();
    }
  }
}
