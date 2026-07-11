@IsTest
public class WorkflowEngineRetryTelemetryTest {
  private static Map<String, Object> loadProgressForStatus(
    Id instanceId,
    String expectedStatus
  ) {
    Workflow_Instance__c inst = [
      SELECT Status__c, Progress__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(expectedStatus, inst.Status__c);
    return (Map<String, Object>) JSON.deserializeUntyped(inst.Progress__c);
  }

  @IsTest
  static void testProgressReportingEndToEnd() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.ProgressWorkflow',
        'ProgressKey',
        'InitialInput'
      );

      // 1. Run first step execution -> Should Yield and save progress (20%, Step 1: Yielding first)
      new WorkflowOrchestrator(instanceId).execute(null);
      Workflow_Instance__c inst1 = [
        SELECT Status__c, Progress__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Running', inst1.Status__c);
      System.assertNotEquals(null, inst1.Progress__c);
      Map<String, Object> progress1 = (Map<String, Object>) JSON.deserializeUntyped(
        inst1.Progress__c
      );
      System.assertEquals(20.0, (Decimal) progress1.get('percentComplete'));
      System.assertEquals(
        'Step 1: Yielding first',
        (String) progress1.get('message')
      );

      // 2. Run next step execution -> Should Complete Step 1 and update progress (50%, Step 1: Done)
      new WorkflowOrchestrator(instanceId).execute(null);
      Map<String, Object> progress2 = loadProgressForStatus(
        instanceId,
        'Running'
      );
      System.assertEquals(50.0, (Decimal) progress2.get('percentComplete'));
      System.assertEquals('Step 1: Done', (String) progress2.get('message'));

      // 3. Run Step 2 execution -> Should ContinueAsNew and set progress (stage: Step 2 final, percent: 90%)
      new WorkflowOrchestrator(instanceId).execute(null);
      Map<String, Object> progress3 = loadProgressForStatus(
        instanceId,
        'ContinuedAsNew'
      );
      System.assertEquals(90.0, (Decimal) progress3.get('percent'));
      System.assertEquals('Step 2 final', (String) progress3.get('stage'));

      // Find successor run and verify progress carried forward
      Workflow_Instance__c successor = [
        SELECT Id, Status__c, Progress__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :instanceId
      ];
      System.assertEquals('Pending', successor.Status__c);
      System.assertNotEquals(null, successor.Progress__c);
      Map<String, Object> progressSucc = (Map<String, Object>) JSON.deserializeUntyped(
        successor.Progress__c
      );
      System.assertEquals(90.0, (Decimal) progressSucc.get('percent'));

      // 4. Run successor (first run) -> runs ProgressStep1 (first yield)
      new WorkflowOrchestrator(successor.Id).execute(null);
      Map<String, Object> progressFinal1 = loadProgressForStatus(
        successor.Id,
        'Running'
      );
      System.assertEquals(
        20.0,
        (Decimal) progressFinal1.get('percentComplete')
      );

      // 5. Run successor (second run) -> completes ProgressStep1
      new WorkflowOrchestrator(successor.Id).execute(null);
      Map<String, Object> progressFinal2 = loadProgressForStatus(
        successor.Id,
        'Running'
      );
      System.assertEquals(
        50.0,
        (Decimal) progressFinal2.get('percentComplete')
      );

      // 6. Run successor (third run) -> runs ProgressStep2 and completes
      new WorkflowOrchestrator(successor.Id).execute(null);
      Workflow_Instance__c finalInst = [
        SELECT Status__c, Progress__c
        FROM Workflow_Instance__c
        WHERE Id = :successor.Id
      ];
      System.assertEquals('Completed', finalInst.Status__c);
      Map<String, Object> progressFinal = (Map<String, Object>) JSON.deserializeUntyped(
        finalInst.Progress__c
      );
      System.assertEquals(
        100.0,
        (Decimal) progressFinal.get('percentComplete')
      );
      System.assertEquals(
        'Workflow Complete',
        (String) progressFinal.get('message')
      );
    }
  }

  @IsTest
  static void testRetryAttemptProgressionAndFallback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksATest.observedAttemptStates.clear();
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.RetryExposeWorkflow',
        'ExposeKey',
        null
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      System.assertEquals('Completed', result.status);
      System.assertEquals(
        3,
        WorkflowEngineMocksATest.observedAttemptStates.size()
      );

      // Attempt 1
      System.assertEquals(
        1,
        WorkflowEngineMocksATest.observedAttemptStates[0].get('attempt')
      );
      System.assertEquals(
        3,
        WorkflowEngineMocksATest.observedAttemptStates[0].get('maxAttempts')
      );
      System.assertEquals(
        false,
        WorkflowEngineMocksATest.observedAttemptStates[0].get('isFinalAttempt')
      );

      // Attempt 2
      System.assertEquals(
        2,
        WorkflowEngineMocksATest.observedAttemptStates[1].get('attempt')
      );
      System.assertEquals(
        3,
        WorkflowEngineMocksATest.observedAttemptStates[1].get('maxAttempts')
      );
      System.assertEquals(
        false,
        WorkflowEngineMocksATest.observedAttemptStates[1].get('isFinalAttempt')
      );

      // Attempt 3 (Final attempt)
      System.assertEquals(
        3,
        WorkflowEngineMocksATest.observedAttemptStates[2].get('attempt')
      );
      System.assertEquals(
        3,
        WorkflowEngineMocksATest.observedAttemptStates[2].get('maxAttempts')
      );
      System.assertEquals(
        true,
        WorkflowEngineMocksATest.observedAttemptStates[2].get('isFinalAttempt')
      );

      // Verify persisted Retry Count agrees (2 retries performed before completing)
      Workflow_Step_Execution__c step = [
        SELECT Retry_Count__c, Status__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId
        LIMIT 1
      ];
      System.assertEquals('Completed', step.Status__c);
      System.assertEquals(
        2,
        step.Retry_Count__c,
        'Persisted Retry Count must be 2 (0-based retry count)'
      );
    }
  }

  @IsTest
  static void testDynamicRetryAttemptProgression() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksATest.dynamicObservedStates.clear();
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.DynamicRetryWorkflow',
        'DynamicKey',
        null
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      System.assertEquals('Completed', result.status);
      System.assertEquals(
        3,
        WorkflowEngineMocksATest.dynamicObservedStates.size()
      );

      // Attempt 1 (No policy resolved yet -> defaults to 1)
      System.assertEquals(
        1,
        WorkflowEngineMocksATest.dynamicObservedStates[0].get('attempt')
      );
      System.assertEquals(
        1,
        WorkflowEngineMocksATest.dynamicObservedStates[0].get('maxAttempts')
      );

      // Attempt 2 (Policy was resolved on attempt 1 -> loaded from Captured_Values__c)
      System.assertEquals(
        2,
        WorkflowEngineMocksATest.dynamicObservedStates[1].get('attempt')
      );
      System.assertEquals(
        3,
        WorkflowEngineMocksATest.dynamicObservedStates[1].get('maxAttempts')
      );

      // Attempt 3 (Policy was resolved on attempt 2 -> loaded from Captured_Values__c)
      System.assertEquals(
        3,
        WorkflowEngineMocksATest.dynamicObservedStates[2].get('attempt')
      );
      System.assertEquals(
        3,
        WorkflowEngineMocksATest.dynamicObservedStates[2].get('maxAttempts')
      );
    }
  }

  @IsTest
  static void testCompensationRetryAttemptProgression() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksBTest.compensationObservedStates.clear();
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.CompensatableRetryWorkflow',
        'CompensateRetryKey',
        null
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      System.assertEquals('Compensated', result.status);
      System.assertEquals(
        2,
        WorkflowEngineMocksBTest.compensationObservedStates.size()
      );

      // Compensation Attempt 1
      System.assertEquals(
        1,
        WorkflowEngineMocksBTest.compensationObservedStates[0].get('attempt')
      );
      System.assertEquals(
        2,
        WorkflowEngineMocksBTest.compensationObservedStates[0]
          .get('maxAttempts')
      );
      System.assertEquals(
        false,
        WorkflowEngineMocksBTest.compensationObservedStates[0]
          .get('isFinalAttempt')
      );

      // Compensation Attempt 2 (Final attempt)
      System.assertEquals(
        2,
        WorkflowEngineMocksBTest.compensationObservedStates[1].get('attempt')
      );
      System.assertEquals(
        2,
        WorkflowEngineMocksBTest.compensationObservedStates[1]
          .get('maxAttempts')
      );
      System.assertEquals(
        true,
        WorkflowEngineMocksBTest.compensationObservedStates[1]
          .get('isFinalAttempt')
      );
    }
  }

  @IsTest
  static void testRetryAttemptResetOnFreshVisit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksBTest.loopObservedStates.clear();
      WorkflowEngineMocksBTest.loopCounter = 0;
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.LoopExposeWorkflow',
        'LoopKey',
        null
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      System.assertEquals('Completed', result.status);
      System.assertEquals(
        3,
        WorkflowEngineMocksBTest.loopObservedStates.size()
      );

      // First visit: attempt 1
      System.assertEquals(
        1,
        WorkflowEngineMocksBTest.loopObservedStates[0].get('attempt')
      );

      // First visit: attempt 2 (retry)
      System.assertEquals(
        2,
        WorkflowEngineMocksBTest.loopObservedStates[1].get('attempt')
      );

      // Second visit: resets to attempt 1
      System.assertEquals(
        1,
        WorkflowEngineMocksBTest.loopObservedStates[2].get('attempt')
      );
    }
  }

  @IsTest
  static void testTelemetryCapturedOnTransitions() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'TelemetryKey',
        'InitialInput'
      );

      new WorkflowOrchestrator(instanceId).execute(null);

      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT
          Status__c,
          CPU_Time_Ms__c,
          SOQL_Query_Count__c,
          Heap_Size_Bytes__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId
        ORDER BY CreatedDate ASC
      ];

      System.assert(
        !stepExecs.isEmpty(),
        'Should have recorded step executions'
      );
      for (Workflow_Step_Execution__c step : stepExecs) {
        if (step.Status__c == 'Completed') {
          System.assertNotEquals(
            null,
            step.CPU_Time_Ms__c,
            'CPU time telemetry should be captured'
          );
          System.assertNotEquals(
            null,
            step.SOQL_Query_Count__c,
            'SOQL queries telemetry should be captured'
          );
          System.assertNotEquals(
            null,
            step.Heap_Size_Bytes__c,
            'Heap size telemetry should be captured'
          );
          System.assert(
            step.CPU_Time_Ms__c >= 0,
            'CPU time should be non-negative'
          );
          System.assert(
            step.SOQL_Query_Count__c >= 0,
            'SOQL query count should be non-negative'
          );
          System.assert(
            step.Heap_Size_Bytes__c >= 0,
            'Heap size should be non-negative'
          );
        }
      }
    }
  }

  @IsTest
  static void testTelemetryOnPendingAndCrash() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Start a sleeping workflow to verify telemetry is populated on Pending status (sleep/suspension)
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.SleepingWorkflow',
        'TelemetrySleepKey',
        'InitialInput'
      );
      new WorkflowOrchestrator(instanceId).execute(null);

      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT
          Status__c,
          CPU_Time_Ms__c,
          SOQL_Query_Count__c,
          Heap_Size_Bytes__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId
        ORDER BY CreatedDate ASC
      ];
      System.assert(
        !stepExecs.isEmpty(),
        'Should have recorded step executions'
      );
      Boolean foundPending = false;
      for (Workflow_Step_Execution__c step : stepExecs) {
        if (step.Status__c == 'Pending') {
          foundPending = true;
          System.assertNotEquals(
            null,
            step.CPU_Time_Ms__c,
            'CPU time telemetry should be captured on Pending/sleep status'
          );
          System.assertNotEquals(
            null,
            step.SOQL_Query_Count__c,
            'SOQL queries telemetry should be captured on Pending/sleep status'
          );
          System.assertNotEquals(
            null,
            step.Heap_Size_Bytes__c,
            'Heap size telemetry should be captured on Pending/sleep status'
          );
        }
      }
      System.assert(
        foundPending,
        'Should have found a Pending step execution for sleep'
      );

      // Trigger handleCrash to verify telemetry is cleared/skipped during crashes
      WorkflowEngine.handleCrash(
        instanceId,
        'WorkflowEngineMocksBTest.SleepingStep',
        new WorkflowEngine.WorkflowException('Test Exception')
      );
      List<Workflow_Step_Execution__c> crashedExecs = [
        SELECT
          Status__c,
          CPU_Time_Ms__c,
          SOQL_Query_Count__c,
          Heap_Size_Bytes__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Failed'
        ORDER BY CreatedDate DESC
        LIMIT 1
      ];
      System.assert(
        !crashedExecs.isEmpty(),
        'Should have recorded failed step execution from handleCrash'
      );
      Workflow_Step_Execution__c failedStep = crashedExecs[0];
      System.assertEquals(
        null,
        failedStep.CPU_Time_Ms__c,
        'CPU time telemetry should be null on crash'
      );
      System.assertEquals(
        null,
        failedStep.SOQL_Query_Count__c,
        'SOQL queries telemetry should be null on crash'
      );
      System.assertEquals(
        null,
        failedStep.Heap_Size_Bytes__c,
        'Heap size telemetry should be null on crash'
      );
    }
  }

  @IsTest
  static void testParentChildWorkflowReentrancy() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id parentId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.ParentWorkflow',
        'ParentKey_Reentry',
        null
      );
      // Runs ParentStep once: returns startChild which sets status to Suspended and calls startChildWorkflow
      new WorkflowOrchestrator(parentId).execute(null);

      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Parent_Instance__c = :parentId
        ],
        'Exactly one child must exist after the first launcher run'
      );

      // Now, run the parent step again (re-entrant hop)
      // ParentStep will run execute() again. Since no ChildCompleted:SubKey signal exists,
      // it will call StepResult.startChild() again with correlationKey = 'SubKey'.
      // The engine must handle this idempotently (return early from startChildWorkflow, no exception, no duplicate child).
      try {
        new WorkflowOrchestrator(parentId).execute(null);
      } catch (Exception ex) {
        System.assert(
          false,
          'Should not throw an exception on re-entrant startChild: ' +
          ex.getMessage()
        );
      }

      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Parent_Instance__c = :parentId
        ],
        'Re-entry must NOT start a duplicate child'
      );

      Workflow_Instance__c parentInst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :parentId
      ];
      System.assertEquals(
        'Suspended',
        parentInst.Status__c,
        'Parent must remain Suspended'
      );

      // Set parent instance status to Failed so its automatically-triggered post-test queueable runs as a no-op
      update as system new Workflow_Instance__c(
        Id = parentId,
        Status__c = 'Failed'
      );
    }
  }

  @IsTest
  static void testParentChildWorkflowForeignCollision() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id parentIdA = WorkflowEngine.start(
        'WorkflowEngineMocksATest.ParentWorkflow',
        'ParentKey_A',
        null
      );
      new WorkflowOrchestrator(parentIdA).execute(null);

      Id parentIdB = WorkflowEngine.start(
        'WorkflowEngineMocksATest.ParentWorkflow',
        'ParentKey_B',
        null
      );

      // Executing ParentStep for parentIdB will return StepResult.startChild with key 'SubKey'.
      // Since 'SubKey' is already active and belongs to parentIdA, this must throw a WorkflowException.
      try {
        new WorkflowOrchestrator(parentIdB).execute(null);
        System.assert(
          false,
          'Should have thrown WorkflowException on foreign correlation key collision'
        );
      } catch (WorkflowEngine.WorkflowException ex) {
        System.assert(
          ex.getMessage()
            .contains(
              'An active workflow already exists with correlation key: SubKey'
            ),
          'Expected duplicate correlation key message, got: ' + ex.getMessage()
        );
      } catch (Exception ex) {
        System.assert(
          false,
          'Expected WorkflowException, got: ' +
            ex.getTypeName() +
            ': ' +
            ex.getMessage()
        );
      }

      // Set parent instances status to Failed so their automatically-triggered post-test queueables run as no-ops
      update as system new List<Workflow_Instance__c>{
        new Workflow_Instance__c(Id = parentIdA, Status__c = 'Failed'),
        new Workflow_Instance__c(Id = parentIdB, Status__c = 'Failed')
      };
    }
  }

  @IsTest
  static void testParentChildWorkflowReentrancyWithPausedChild() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id parentId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.ParentWorkflow',
        'ParentKey_Reentry_Paused',
        null
      );
      new WorkflowOrchestrator(parentId).execute(null);

      // Locate child and pause it manually
      Workflow_Instance__c child = [
        SELECT Id, Status__c
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :parentId
        LIMIT 1
      ];
      child.Status__c = 'Paused';
      update as system child;

      // Execute parent re-entrant hop
      try {
        new WorkflowOrchestrator(parentId).execute(null);
      } catch (Exception ex) {
        System.assert(
          false,
          'Should not throw on re-entrant startChild with paused child: ' +
          ex.getMessage()
        );
      }

      // Verify parent remains Suspended
      Workflow_Instance__c parentInst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :parentId
      ];
      System.assertEquals('Suspended', parentInst.Status__c);

      // Set parent instance status to Failed so its automatically-triggered post-test queueable runs as a no-op
      update as system new Workflow_Instance__c(
        Id = parentId,
        Status__c = 'Failed'
      );
    }
  }
}
