@IsTest
public class BulkCancelWorkflowTest {
  // ==========================================
  // Helpers
  // ==========================================

  // Fluent builder for the Workflow_Instance__c fixtures these tests insert,
  // replacing a 4-parameter makeInstance() that tripped ExcessiveParameterList.
  // Produces byte-identical records: key -> Correlation_Key__c, a fixed Input__c
  // payload, and an optional compensation stack (null when never set).
  private class InstanceBuilder {
    private String correlationKey;
    private String status;
    private String workflowName;
    private String compStack;

    private InstanceBuilder key(String value) {
      this.correlationKey = value;
      return this;
    }
    private InstanceBuilder status(String value) {
      this.status = value;
      return this;
    }
    private InstanceBuilder workflow(String value) {
      this.workflowName = value;
      return this;
    }
    private InstanceBuilder compStack(String value) {
      this.compStack = value;
      return this;
    }

    private Workflow_Instance__c create() {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = this.workflowName,
        Status__c = this.status,
        Correlation_Key__c = this.correlationKey,
        Input__c = '"InputData"',
        Compensation_Stack__c = this.compStack
      );
      insert inst;
      return inst;
    }
  }

  private static StepContext ctxFor(String inputJson, String stateJson) {
    return new StepContext.Builder()
      .workflowName('BulkCancelWorkflow')
      .stepName('BulkCancelWorkflow.BulkCancelStep')
      .stepStateJson(stateJson)
      .workflowInputJson(inputJson)
      .build();
  }

  // Threads the operator filter into the chunk driver so each yielded
  // transaction rebuilds its StepContext from the persisted step state.
  private class ChunkCtxFactory implements BulkWorkflowTestHelpers.ChunkContextFactory {
    private final String filter;

    private ChunkCtxFactory(String filter) {
      this.filter = filter;
    }

    /**
     * @description Rebuilds a StepContext for the next chunk transaction from the
     * persisted step state, re-threading the captured operator filter.
     * @param stepStateJson The serialized step state persisted across the yield.
     * @return A StepContext seeded with the filter and restored step state.
     */
    public StepContext build(String stepStateJson) {
      return ctxFor(filter, stepStateJson);
    }
  }

  // ==========================================
  // Tests
  // ==========================================

  @IsTest
  static void testCountEligibleFiltersAndExcludesSelfAndCompensating() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<String> statuses = new List<String>{
        'Pending',
        'Running',
        'Suspended',
        'Paused',
        'CompensationFailed',
        'Compensating',
        'Cancelling',
        'Completed',
        'Failed',
        'Compensated',
        'Cancelled',
        'ContinuedAsNew'
      };
      for (String st : statuses) {
        new InstanceBuilder()
          .key('Inst_' + st)
          .status(st)
          .workflow('WorkflowEngineTest.HappyWorkflow')
          .create();
      }

      // Seed BulkCancelWorkflow self instance (must be excluded)
      new InstanceBuilder()
        .key('SelfInstance')
        .status('Running')
        .workflow('BulkCancelWorkflow')
        .create();

      Test.startTest();
      Integer eligibleCount = BulkCancelWorkflow.countEligible('', '', '');
      Integer runningCount = BulkCancelWorkflow.countEligible(
        'WorkflowEngineTest.HappyWorkflow',
        'Running',
        ''
      );
      Integer completedCount = BulkCancelWorkflow.countEligible(
        'WorkflowEngineTest.HappyWorkflow',
        'Completed',
        ''
      );
      Test.stopTest();

      System.assertEquals(
        5,
        eligibleCount,
        'Should return exactly 5 eligible instances'
      );
      System.assertEquals(1, runningCount, 'Should find 1 running instance');
      System.assertEquals(
        0,
        completedCount,
        'Completed instances are not eligible'
      );
    }
  }

  @IsTest
  static void testCancelsEligibleInstances() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      new InstanceBuilder()
        .key('ActivePending')
        .status('Pending')
        .workflow('WorkflowEngineTest.HappyWorkflow')
        .create();
      new InstanceBuilder()
        .key('ActiveRunning')
        .status('Running')
        .workflow('WorkflowEngineTest.HappyWorkflow')
        .create();
      new InstanceBuilder()
        .key('ActiveSuspended')
        .status('Suspended')
        .workflow('WorkflowEngineTest.HappyWorkflow')
        .create();

      String filter = JSON.serialize(
        new Map<String, Object>{
          'workflowName' => '',
          'status' => '',
          'searchTerm' => '',
          'runCompensations' => false
        }
      );

      Test.startTest();
      StepResult result = new BulkCancelWorkflow.BulkCancelStep()
        .execute(ctxFor(filter, null));
      Test.stopTest();

      System.assertEquals(
        StepResult.ActionType.COMPLETE,
        result.action,
        'Small selection should finish in a single transaction'
      );

      Map<String, Object> summary = (Map<String, Object>) JSON.deserializeUntyped(
        result.outputJson
      );
      System.assertEquals(
        3,
        (Integer) summary.get('cancelled'),
        'All 3 cancelled'
      );
      System.assertEquals(0, (Integer) summary.get('skipped'));
      System.assertEquals(0, (Integer) summary.get('errored'));

      Integer cancelledCount = [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE
          Status__c = 'Cancelled'
          AND Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow'
      ];
      System.assertEquals(
        3,
        cancelledCount,
        'All 3 instances should be in Cancelled status'
      );
    }
  }

  @IsTest
  static void testYieldsAndResumesInChunks() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Integer original = BulkCancelWorkflow.defaultChunkSize;
      BulkCancelWorkflow.defaultChunkSize = 2;
      try {
        for (Integer i = 0; i < 5; i++) {
          new InstanceBuilder()
            .key('Chunk_' + i)
            .status('Running')
            .workflow('WorkflowEngineTest.HappyWorkflow')
            .create();
        }
        String filter = JSON.serialize(
          new Map<String, Object>{
            'workflowName' => '',
            'status' => '',
            'searchTerm' => '',
            'runCompensations' => false
          }
        );

        StepResult r3 = BulkWorkflowTestHelpers.driveTwoYieldsThenComplete(
          new BulkCancelWorkflow.BulkCancelStep(),
          new ChunkCtxFactory(filter)
        );

        Map<String, Object> summary = (Map<String, Object>) JSON.deserializeUntyped(
          r3.outputJson
        );
        System.assertEquals(
          5,
          (Integer) summary.get('cancelled'),
          'All 5 cancelled across chunks'
        );

        Integer cancelledCount = [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE
            Status__c = 'Cancelled'
            AND Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow'
        ];
        System.assertEquals(5, cancelledCount);
      } finally {
        BulkCancelWorkflow.defaultChunkSize = original;
      }
    }
  }

  @IsTest
  static void testOneFailureDoesNotAbortRest() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      new InstanceBuilder()
        .key('GoodA')
        .status('Running')
        .workflow('WorkflowEngineTest.HappyWorkflow')
        .create();
      new InstanceBuilder()
        .key('GoodB')
        .status('Running')
        .workflow('WorkflowEngineTest.HappyWorkflow')
        .create();

      // Poison instance: Status__c = 'CompensationFailed' and malformed json compensation stack
      // so WorkflowEngine.cancel throws a JSON deserialization exception.
      new InstanceBuilder()
        .key('Poison')
        .status('CompensationFailed')
        .workflow('WorkflowEngineTest.HappyWorkflow')
        .compStack('{ this is not valid json')
        .create();

      String filter = JSON.serialize(
        new Map<String, Object>{
          'workflowName' => '',
          'status' => '',
          'searchTerm' => '',
          'runCompensations' => true
        }
      );

      Test.startTest();
      StepResult result = new BulkCancelWorkflow.BulkCancelStep()
        .execute(ctxFor(filter, null));
      Test.stopTest();

      Map<String, Object> summary = (Map<String, Object>) JSON.deserializeUntyped(
        result.outputJson
      );
      System.assertEquals(
        2,
        (Integer) summary.get('cancelled'),
        'The 2 healthy instances cancel'
      );
      System.assertEquals(
        1,
        (Integer) summary.get('errored'),
        'The poison instance is counted as errored'
      );

      Workflow_Instance__c reloaded = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c = 'Poison'
      ];
      System.assertEquals(
        'CompensationFailed',
        reloaded.Status__c,
        'Errored instance is left unchanged'
      );
    }
  }

  @IsTest
  static void testZeroEligibleCompletesCleanly() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      new InstanceBuilder()
        .key('NothingToDo')
        .status('Completed')
        .workflow('WorkflowEngineTest.HappyWorkflow')
        .create();

      String filter = JSON.serialize(
        new Map<String, Object>{
          'workflowName' => '',
          'status' => '',
          'searchTerm' => '',
          'runCompensations' => false
        }
      );

      Test.startTest();
      StepResult result = new BulkCancelWorkflow.BulkCancelStep()
        .execute(ctxFor(filter, null));
      Test.stopTest();

      System.assertEquals(StepResult.ActionType.COMPLETE, result.action);
      Map<String, Object> summary = (Map<String, Object>) JSON.deserializeUntyped(
        result.outputJson
      );
      System.assertEquals(0, (Integer) summary.get('cancelled'));
    }
  }

  @IsTest
  static void testEndToEndViaEngine() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      new InstanceBuilder()
        .key('E2E_A')
        .status('Running')
        .workflow('WorkflowEngineTest.HappyWorkflow')
        .create();
      new InstanceBuilder()
        .key('E2E_B')
        .status('Running')
        .workflow('WorkflowEngineTest.HappyWorkflow')
        .create();

      WorkflowEngine.disableQueueableInTest = false;
      Test.startTest();
      Id cancelId = WorkflowEngine.start(
        'BulkCancelWorkflow',
        'E2E_Cancel',
        new Map<String, Object>{
          'workflowName' => 'WorkflowEngineTest.HappyWorkflow',
          'status' => 'Running',
          'searchTerm' => '',
          'runCompensations' => false
        }
      );
      WorkflowEngine.disableQueueableInTest = true;
      Test.stopTest();

      Workflow_Instance__c runner = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :cancelId
      ];
      System.assertEquals(
        'Completed',
        runner.Status__c,
        'Cancel workflow completes'
      );
      System.assert(
        runner.Output__c != null && runner.Output__c.contains('cancelled'),
        'Output carries outcomes: ' + runner.Output__c
      );

      Integer cancelledCount = [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE
          Status__c = 'Cancelled'
          AND Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow'
      ];
      System.assertEquals(2, cancelledCount, 'Both targets cancelled');
    }
  }

  @IsTest
  static void testControllerMethods() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      new InstanceBuilder()
        .key('CtrlA')
        .status('Running')
        .workflow('WorkflowEngineTest.HappyWorkflow')
        .create();

      Test.startTest();
      Integer count = WorkflowDashboardController.getCancelEligibleCount(
        'WorkflowEngineTest.HappyWorkflow',
        'Running',
        ''
      );
      System.assertEquals(1, count, 'Should find 1 eligible');

      Map<String, Object> result = WorkflowDashboardController.cancelMatchingInstances(
        'WorkflowEngineTest.HappyWorkflow',
        'Running',
        ''
      );
      Test.stopTest();

      System.assertEquals(
        true,
        (Boolean) result.get('started'),
        'Workflow should start'
      );
      System.assertEquals(
        1,
        (Integer) result.get('eligibleCount'),
        'Should have 1 eligible'
      );
      System.assertNotEquals(
        null,
        result.get('cancelInstanceId'),
        'Should return the bulk cancel instance ID'
      );
    }
  }
}
