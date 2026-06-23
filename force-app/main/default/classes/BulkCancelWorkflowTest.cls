@isTest
public class BulkCancelWorkflowTest {
  // ==========================================
  // Helpers
  // ==========================================

  private static Workflow_Instance__c makeInstance(
    String name,
    String status,
    String workflowName,
    String compStack
  ) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = workflowName,
      Status__c = status,
      Correlation_Key__c = name,
      Input__c = '"InputData"',
      Compensation_Stack__c = compStack
    );
    insert inst;
    return inst;
  }

  private static StepContext ctxFor(String inputJson, String stateJson) {
    return new StepContext(
      null,
      'BulkCancelWorkflow',
      'BulkCancelWorkflow.BulkCancelStep',
      null,
      null,
      stateJson,
      inputJson
    );
  }

  // ==========================================
  // Tests
  // ==========================================

  @isTest
  static void testCountEligibleFiltersAndExcludesSelfAndCompensating() {
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
      makeInstance('Inst_' + st, st, 'WorkflowEngineTest.HappyWorkflow', null);
    }

    // Seed BulkCancelWorkflow self instance (must be excluded)
    makeInstance('SelfInstance', 'Running', 'BulkCancelWorkflow', null);

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

  @isTest
  static void testCancelsEligibleInstances() {
    WorkflowEngine.disableQueueableInTest = true;
    makeInstance(
      'ActivePending',
      'Pending',
      'WorkflowEngineTest.HappyWorkflow',
      null
    );
    makeInstance(
      'ActiveRunning',
      'Running',
      'WorkflowEngineTest.HappyWorkflow',
      null
    );
    makeInstance(
      'ActiveSuspended',
      'Suspended',
      'WorkflowEngineTest.HappyWorkflow',
      null
    );

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

  @isTest
  static void testYieldsAndResumesInChunks() {
    WorkflowEngine.disableQueueableInTest = true;
    Integer original = BulkCancelWorkflow.CHUNK_SIZE;
    BulkCancelWorkflow.CHUNK_SIZE = 2;
    try {
      for (Integer i = 0; i < 5; i++) {
        makeInstance(
          'Chunk_' + i,
          'Running',
          'WorkflowEngineTest.HappyWorkflow',
          null
        );
      }
      String filter = JSON.serialize(
        new Map<String, Object>{
          'workflowName' => '',
          'status' => '',
          'searchTerm' => '',
          'runCompensations' => false
        }
      );

      Test.startTest();
      BulkCancelWorkflow.BulkCancelStep step = new BulkCancelWorkflow.BulkCancelStep();
      StepResult r1 = step.execute(ctxFor(filter, null));
      System.assertEquals(
        StepResult.ActionType.YIELD,
        r1.action,
        'A selection larger than one chunk must yield to a fresh transaction'
      );
      StepResult r2 = step.execute(ctxFor(filter, r1.stepStateJson));
      System.assertEquals(StepResult.ActionType.YIELD, r2.action);
      StepResult r3 = step.execute(ctxFor(filter, r2.stepStateJson));
      Test.stopTest();

      System.assertEquals(
        StepResult.ActionType.COMPLETE,
        r3.action,
        'Final chunk completes the cancel'
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
      BulkCancelWorkflow.CHUNK_SIZE = original;
    }
  }

  @isTest
  static void testOneFailureDoesNotAbortRest() {
    WorkflowEngine.disableQueueableInTest = true;
    makeInstance('GoodA', 'Running', 'WorkflowEngineTest.HappyWorkflow', null);
    makeInstance('GoodB', 'Running', 'WorkflowEngineTest.HappyWorkflow', null);

    // Poison instance: Status__c = 'CompensationFailed' and malformed json compensation stack
    // so WorkflowEngine.cancel throws a JSON deserialization exception.
    makeInstance(
      'Poison',
      'CompensationFailed',
      'WorkflowEngineTest.HappyWorkflow',
      '{ this is not valid json'
    );

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

  @isTest
  static void testZeroEligibleCompletesCleanly() {
    WorkflowEngine.disableQueueableInTest = true;
    makeInstance(
      'NothingToDo',
      'Completed',
      'WorkflowEngineTest.HappyWorkflow',
      null
    );

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

  @isTest
  static void testEndToEndViaEngine() {
    WorkflowEngine.disableQueueableInTest = true;
    makeInstance('E2E_A', 'Running', 'WorkflowEngineTest.HappyWorkflow', null);
    makeInstance('E2E_B', 'Running', 'WorkflowEngineTest.HappyWorkflow', null);

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

  @isTest
  static void testControllerMethods() {
    WorkflowEngine.disableQueueableInTest = true;
    makeInstance('CtrlA', 'Running', 'WorkflowEngineTest.HappyWorkflow', null);

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
      '',
      false
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
