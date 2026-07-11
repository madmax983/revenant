@IsTest
public class BulkRedriveWorkflowTest {
  // ==========================================
  // Helpers
  // ==========================================

  /**
   * Creates a re-drivable Failed instance of WorkflowEngineTest.HappyWorkflow,
   * complete with a Failed step execution that retryWorkflow() can reset.
   */
  private static Workflow_Instance__c makeFailedInstance(String key) {
    return makeFailedInstance(key, 'WorkflowEngineTest.HappyWorkflow');
  }

  private static Workflow_Instance__c makeFailedInstance(
    String key,
    String workflowName
  ) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = workflowName,
      Status__c = 'Failed',
      Correlation_Key__c = key,
      Input__c = '"InputData"',
      Current_Step__c = 'WorkflowEngineTest.HappyStep1',
      Error_Message__c = 'Downstream endpoint down'
    );
    insert inst;
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Failed',
      Retry_Count__c = 1,
      Error_Details__c = 'boom'
    );
    return inst;
  }

  /**
   * Builds a StepContext that drives BulkRedriveStep directly. `stateJson` is the
   * persisted yield state (null on first run); `inputJson` is the operator filter.
   */
  private static StepContext ctxFor(String inputJson, String stateJson) {
    return new StepContext.Builder()
      .instanceId(null)
      .workflowName('BulkRedriveWorkflow')
      .stepName('BulkRedriveWorkflow.BulkRedriveStep')
      .inputJson(null)
      .previousStepOutput(null)
      .stepStateJson(stateJson)
      .workflowInputJson(inputJson)
      .build();
  }

  private static Integer countByStatus(String status) {
    return [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE
        Status__c = :status
        AND Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow'
    ];
  }

  // ==========================================
  // Tests
  // ==========================================

  @IsTest
  static void testRedrivesEligibleFailedInstances() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      makeFailedInstance('RedriveA');
      makeFailedInstance('RedriveB');
      makeFailedInstance('RedriveC');

      String filter = JSON.serialize(
        new Map<String, Object>{
          'workflowName' => '',
          'status' => '',
          'searchTerm' => ''
        }
      );

      Test.startTest();
      StepResult result = new BulkRedriveWorkflow.BulkRedriveStep()
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
        (Integer) summary.get('redriven'),
        'All 3 re-driven'
      );
      System.assertEquals(0, (Integer) summary.get('skipped'));
      System.assertEquals(0, (Integer) summary.get('errored'));
      System.assertEquals(
        3,
        countByStatus('Running'),
        'All 3 Failed instances transitioned to Running'
      );
      System.assertEquals(0, countByStatus('Failed'), 'No Failed left behind');
    }
  }

  @IsTest
  static void testExcludesNonRecoverableStatuses() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // Only Failed is operator-recoverable. Everything else must be untouched.
      for (
        String st : new List<String>{
          'Completed',
          'Cancelled',
          'Running',
          'Suspended',
          'Pending',
          'Compensating',
          'Cancelling',
          'Compensated'
        }
      ) {
        insert new Workflow_Instance__c(
          Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
          Status__c = st,
          Correlation_Key__c = 'Excl_' + st,
          Current_Step__c = 'WorkflowEngineTest.HappyStep1'
        );
      }

      String filter = JSON.serialize(
        new Map<String, Object>{
          'workflowName' => '',
          'status' => '',
          'searchTerm' => ''
        }
      );

      Test.startTest();
      StepResult result = new BulkRedriveWorkflow.BulkRedriveStep()
        .execute(ctxFor(filter, null));
      Test.stopTest();

      Map<String, Object> summary = (Map<String, Object>) JSON.deserializeUntyped(
        result.outputJson
      );
      System.assertEquals(
        0,
        (Integer) summary.get('redriven'),
        'No non-Failed instance may be re-driven'
      );
      // None of the seeded statuses should have flipped to Running.
      System.assertEquals(
        1,
        countByStatus('Running'),
        'The pre-existing Running instance is unchanged and nothing new became Running'
      );
    }
  }

  @IsTest
  static void testOuroborosSelfExclusion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // A previously-failed re-driver instance must NEVER be selected for re-drive,
      // otherwise "re-drive all Failed" becomes a self-replaying loop.
      Workflow_Instance__c selfRedriver = new Workflow_Instance__c(
        Workflow_Name__c = 'BulkRedriveWorkflow',
        Status__c = 'Failed',
        Correlation_Key__c = 'SelfRedriver',
        Current_Step__c = 'BulkRedriveWorkflow.BulkRedriveStep'
      );
      insert selfRedriver;
      makeFailedInstance('NormalFailure');

      String filter = JSON.serialize(
        new Map<String, Object>{
          'workflowName' => '',
          'status' => '',
          'searchTerm' => ''
        }
      );

      Test.startTest();
      StepResult result = new BulkRedriveWorkflow.BulkRedriveStep()
        .execute(ctxFor(filter, null));
      Test.stopTest();

      Map<String, Object> summary = (Map<String, Object>) JSON.deserializeUntyped(
        result.outputJson
      );
      System.assertEquals(
        1,
        (Integer) summary.get('redriven'),
        'Only the non-re-driver Failed instance is eligible'
      );
      Workflow_Instance__c reloaded = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :selfRedriver.Id
      ];
      System.assertEquals(
        'Failed',
        reloaded.Status__c,
        'The re-driver workflow must not re-drive itself'
      );
    }
  }

  @IsTest
  static void testIdempotentNoDoubleRedrive() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      makeFailedInstance('IdemA');
      makeFailedInstance('IdemB');

      String filter = JSON.serialize(
        new Map<String, Object>{
          'workflowName' => '',
          'status' => '',
          'searchTerm' => ''
        }
      );

      Test.startTest();
      // First sweep re-drives both (Failed -> Running).
      StepResult first = new BulkRedriveWorkflow.BulkRedriveStep()
        .execute(ctxFor(filter, null));
      // Second sweep (double-click / overlapping operator) finds nothing eligible.
      StepResult second = new BulkRedriveWorkflow.BulkRedriveStep()
        .execute(ctxFor(filter, null));
      Test.stopTest();

      Map<String, Object> s1 = (Map<String, Object>) JSON.deserializeUntyped(
        first.outputJson
      );
      Map<String, Object> s2 = (Map<String, Object>) JSON.deserializeUntyped(
        second.outputJson
      );
      System.assertEquals(
        2,
        (Integer) s1.get('redriven'),
        'First sweep re-drives both'
      );
      System.assertEquals(
        0,
        (Integer) s2.get('redriven'),
        'Second sweep re-drives nothing — no double-enqueue'
      );
      System.assertEquals(2, countByStatus('Running'));
    }
  }

  @IsTest
  static void testYieldsAndResumesInChunks() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Integer original = BulkRedriveWorkflow.defaultChunkSize;
      BulkRedriveWorkflow.defaultChunkSize = 2;
      try {
        for (Integer i = 0; i < 5; i++) {
          makeFailedInstance('Chunk_' + i);
        }
        String filter = JSON.serialize(
          new Map<String, Object>{
            'workflowName' => '',
            'status' => '',
            'searchTerm' => ''
          }
        );

        Test.startTest();
        BulkRedriveWorkflow.BulkRedriveStep step = new BulkRedriveWorkflow.BulkRedriveStep();
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
          'Final chunk completes the re-drive'
        );
        Map<String, Object> summary = (Map<String, Object>) JSON.deserializeUntyped(
          r3.outputJson
        );
        System.assertEquals(
          5,
          (Integer) summary.get('redriven'),
          'All 5 re-driven across chunks'
        );
        System.assertEquals(5, countByStatus('Running'));
      } finally {
        BulkRedriveWorkflow.defaultChunkSize = original;
      }
    }
  }

  @IsTest
  static void testOneFailureDoesNotAbortRest() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Integer original = BulkRedriveWorkflow.defaultChunkSize;
      BulkRedriveWorkflow.defaultChunkSize = 10;
      try {
        makeFailedInstance('GoodA');
        makeFailedInstance('GoodB');
        makeFailedInstance('GoodC');
        // Malformed compensation stack makes retryWorkflow throw a JSON exception for
        // this one instance — it must be counted as errored without aborting the rest.
        Workflow_Instance__c poison = new Workflow_Instance__c(
          Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
          Status__c = 'Failed',
          Correlation_Key__c = 'Poison',
          Current_Step__c = 'WorkflowEngineTest.HappyStep1',
          Compensation_Stack__c = '{ this is not valid json'
        );
        insert poison;

        String filter = JSON.serialize(
          new Map<String, Object>{
            'workflowName' => '',
            'status' => '',
            'searchTerm' => ''
          }
        );

        Test.startTest();
        StepResult result = new BulkRedriveWorkflow.BulkRedriveStep()
          .execute(ctxFor(filter, null));
        Test.stopTest();

        Map<String, Object> summary = (Map<String, Object>) JSON.deserializeUntyped(
          result.outputJson
        );
        System.assertEquals(
          3,
          (Integer) summary.get('redriven'),
          'The 3 healthy instances re-drive'
        );
        System.assertEquals(
          1,
          (Integer) summary.get('errored'),
          'The poison instance is counted as errored'
        );
        Workflow_Instance__c reloaded = [
          SELECT Status__c
          FROM Workflow_Instance__c
          WHERE Id = :poison.Id
        ];
        System.assertEquals(
          'Failed',
          reloaded.Status__c,
          'Errored instance is left Failed for re-inspection'
        );
      } finally {
        BulkRedriveWorkflow.defaultChunkSize = original;
      }
    }
  }

  @IsTest
  static void testZeroEligibleCompletesCleanly() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      insert new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Completed',
        Correlation_Key__c = 'NothingToDo'
      );

      String filter = JSON.serialize(
        new Map<String, Object>{
          'workflowName' => '',
          'status' => '',
          'searchTerm' => ''
        }
      );

      Test.startTest();
      StepResult result = new BulkRedriveWorkflow.BulkRedriveStep()
        .execute(ctxFor(filter, null));
      Test.stopTest();

      System.assertEquals(StepResult.ActionType.COMPLETE, result.action);
      Map<String, Object> summary = (Map<String, Object>) JSON.deserializeUntyped(
        result.outputJson
      );
      System.assertEquals(0, (Integer) summary.get('redriven'));
    }
  }

  @IsTest
  static void testCountEligibleHonorsFilterAndExcludesSelf() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      makeFailedInstance('CntA');
      makeFailedInstance('CntB');
      insert new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Completed',
        Correlation_Key__c = 'CntDone'
      );
      // A failed re-driver must not be counted.
      insert new Workflow_Instance__c(
        Workflow_Name__c = 'BulkRedriveWorkflow',
        Status__c = 'Failed',
        Correlation_Key__c = 'CntSelf'
      );

      Test.startTest();
      Integer allFailed = BulkRedriveWorkflow.countEligible('', '', '');
      Integer scoped = BulkRedriveWorkflow.countEligible(
        'WorkflowEngineTest.HappyWorkflow',
        'Failed',
        ''
      );
      Integer nonRecoverable = BulkRedriveWorkflow.countEligible(
        '',
        'Completed',
        ''
      );
      Test.stopTest();

      System.assertEquals(
        2,
        allFailed,
        'Only the 2 non-self Failed instances are eligible'
      );
      System.assertEquals(2, scoped, 'Scoped filter matches');
      System.assertEquals(
        0,
        nonRecoverable,
        'A non-recoverable status filter yields zero eligible'
      );
    }
  }

  @IsTest
  static void testEndToEndViaEngine() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Dogfood: the re-driver runs AS a Revenant workflow instance.
      WorkflowEngine.disableQueueableInTest = true;
      makeFailedInstance('E2E_A');
      makeFailedInstance('E2E_B');

      WorkflowEngine.disableQueueableInTest = false;
      Test.startTest();
      Id redriverId = WorkflowEngine.start(
        'BulkRedriveWorkflow',
        'E2E_Redrive',
        new Map<String, Object>{
          'workflowName' => 'WorkflowEngineTest.HappyWorkflow',
          'status' => 'Failed',
          'searchTerm' => ''
        }
      );
      WorkflowEngine.disableQueueableInTest = true;
      Test.stopTest();

      // The orchestrator runs BulkRedriveStep at stopTest.
      Workflow_Instance__c redriver = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :redriverId
      ];
      System.assertEquals(
        'Completed',
        redriver.Status__c,
        'Re-driver workflow completes'
      );
      System.assert(
        redriver.Output__c != null && redriver.Output__c.contains('redriven'),
        'Re-driver output carries the outcome summary: ' + redriver.Output__c
      );
      System.assertEquals(
        2,
        countByStatus('Running'),
        'Both targets re-driven'
      );
    }
  }
}
