@IsTest
public class WorkflowEngineErrorRoutingTest {
  @IsTest
  static void testStepBreadcrumbsPersisted() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.BreadcrumbWorkflow',
        'BreadcrumbKey',
        null
      );
      Test.stopTest(); // runs BreadcrumbStep synchronously

      List<Workflow_Log__c> logs = [
        SELECT
          Log_Type__c,
          Level__c,
          Message__c,
          Correlation_Key__c,
          Workflow_Instance__c,
          Workflow_Name__c
        FROM Workflow_Log__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Log_Type__c = :StepContext.LOG_TYPE_BREADCRUMB
        ORDER BY Fire_Time__c ASC, Id ASC
      ];

      Workflow_Step_Execution__c stepExec = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineMocksBTest.BreadcrumbStep'
        LIMIT 1
      ];

      System.assertEquals(2, logs.size(), 'Should have saved 2 breadcrumbs');

      System.assertEquals(StepContext.LOG_TYPE_BREADCRUMB, logs[0].Log_Type__c);
      System.assertEquals('INFO', logs[0].Level__c);
      System.assert(
        logs[0].Message__c.contains('Step 1 execution started'),
        'Message mismatch: ' + logs[0].Message__c
      );
      System.assert(
        logs[0].Message__c.contains('"status":"init"'),
        'Message mismatch: ' + logs[0].Message__c
      );
      System.assertEquals(stepExec.Id, logs[0].Correlation_Key__c);

      System.assertEquals(StepContext.LOG_TYPE_BREADCRUMB, logs[1].Log_Type__c);
      System.assertEquals('WARN', logs[1].Level__c);
      System.assertEquals('Step 1 warning encountered', logs[1].Message__c);
      System.assertEquals(stepExec.Id, logs[1].Correlation_Key__c);
    }
  }

  @IsTest
  static void testStepBreadcrumbsRollbackOnFailure() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.RollbackWorkflow',
        'RollbackKey',
        null
      );

      Savepoint sp = Database.setSavepoint();
      try {
        new WorkflowOrchestrator(instanceId).execute(null);
        System.assert(false, 'Should have thrown an exception');
      } catch (Exception ex) {
        Database.rollback(sp);
        System.assert(
          ex.getMessage().contains('Simulated Failure') ||
          ex.getMessage().contains('terminated, cancelled'),
          'Exception mismatch: ' + ex.getMessage()
        );
      }

      List<Workflow_Log__c> logs = [
        SELECT Log_Type__c, Level__c, Message__c
        FROM Workflow_Log__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Log_Type__c = :StepContext.LOG_TYPE_BREADCRUMB
      ];
      System.assertEquals(
        0,
        logs.size(),
        'Should not have saved any breadcrumbs because of rollback'
      );
    }
  }

  @IsTest
  static void testStepBreadcrumbsEffectivelyOnceOnRetry() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksBTest.retryBreadcrumbAttempt = 1;

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.RetryBreadcrumbWorkflow',
        'RetryBreadcrumbKey',
        null
      );
      Test.stopTest(); // Runs Attempt 1, returns retry (Retry_Count__c = 1)

      // Attempt 2
      WorkflowEngine.runStep(instanceId); // Runs Attempt 2, returns retry (Retry_Count__c = 2)

      // Attempt 3
      WorkflowEngine.runStep(instanceId); // Runs Attempt 3, completes successfully!

      List<Workflow_Log__c> logs = [
        SELECT Log_Type__c, Level__c, Message__c, Correlation_Key__c
        FROM Workflow_Log__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Log_Type__c = :StepContext.LOG_TYPE_BREADCRUMB
        ORDER BY CreatedDate ASC, Id ASC
      ];

      System.assertEquals(
        3,
        logs.size(),
        'Should have saved exactly 3 breadcrumbs'
      );
      System.assertEquals('Attempt 1', logs[0].Message__c);
      System.assertEquals('Attempt 2', logs[1].Message__c);
      System.assertEquals('Attempt 3', logs[2].Message__c);
    }
  }

  @IsTest
  static void testErrorRoutingOnCrash() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksBTest.routedStepsRun.clear();
      WorkflowEngineMocksBTest.routedStepContextData.clear();
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.ErrorRoutedWorkflow',
        'CrashKey',
        null
      );

      try {
        WorkflowEngine.runStep(
          instanceId,
          'WorkflowEngineMocksBTest.CrashStep'
        );
      } catch (Exception ex) {
        WorkflowEngine.handleCrash(
          instanceId,
          'WorkflowEngineMocksBTest.CrashStep',
          ex
        );
      }

      Workflow_Instance__c inst = [
        SELECT Current_Step__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'WorkflowEngineMocksATest.NormalHandlerStep',
        inst.Current_Step__c
      );
      System.assertEquals('Running', inst.Status__c);

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksATest.NormalHandlerStep'
      );

      System.assertEquals(1, WorkflowEngineMocksBTest.routedStepsRun.size());
      System.assertEquals(
        'NormalHandlerStep',
        WorkflowEngineMocksBTest.routedStepsRun[0]
      );
      System.assertEquals(
        'WorkflowEngineMocksBTest.CrashStep',
        WorkflowEngineMocksBTest.routedStepContextData.get('failedStepName')
      );
      System.assert(
        String.valueOf(
            WorkflowEngineMocksBTest.routedStepContextData.get('errorMessage')
          )
          .contains('Crash in execution')
      );
      System.assertEquals(
        1,
        WorkflowEngineMocksBTest.routedStepContextData.get('attemptCount')
      );
    }
  }

  @IsTest
  static void testErrorRoutingOnRetryExhaustion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksBTest.routedStepsRun.clear();
      WorkflowEngineMocksBTest.routedStepContextData.clear();
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.ErrorRoutedWorkflow',
        'RetryExhaustKey',
        null
      );

      Workflow_Instance__c inst = [
        SELECT Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      inst.Current_Step__c = 'WorkflowEngineMocksBTest.RetryThenFailStep';
      update inst;

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksBTest.RetryThenFailStep'
      );

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksBTest.RetryThenFailStep'
      );

      inst = [
        SELECT Current_Step__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'WorkflowEngineMocksATest.NormalHandlerStep',
        inst.Current_Step__c
      );
      System.assertEquals('Running', inst.Status__c);

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksATest.NormalHandlerStep'
      );

      System.assertEquals(1, WorkflowEngineMocksBTest.routedStepsRun.size());
      System.assertEquals(
        'NormalHandlerStep',
        WorkflowEngineMocksBTest.routedStepsRun[0]
      );
      System.assertEquals(
        'WorkflowEngineMocksBTest.RetryThenFailStep',
        WorkflowEngineMocksBTest.routedStepContextData.get('failedStepName')
      );
      System.assert(
        String.valueOf(
            WorkflowEngineMocksBTest.routedStepContextData.get('errorMessage')
          )
          .contains('Failed after retry')
      );
      System.assertEquals(
        2,
        WorkflowEngineMocksBTest.routedStepContextData.get('attemptCount')
      );
    }
  }

  @IsTest
  static void testErrorRoutingOnExplicitFail() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksBTest.routedStepsRun.clear();
      WorkflowEngineMocksBTest.routedStepContextData.clear();
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.ErrorRoutedWorkflow',
        'ExplicitFailKey',
        null
      );

      Workflow_Instance__c inst = [
        SELECT Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      inst.Current_Step__c = 'WorkflowEngineMocksBTest.ExplicitFailStep';
      update inst;

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksBTest.ExplicitFailStep'
      );

      inst = [
        SELECT Current_Step__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'WorkflowEngineMocksATest.NormalHandlerStep',
        inst.Current_Step__c
      );
      System.assertEquals('Running', inst.Status__c);

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksATest.NormalHandlerStep'
      );

      System.assertEquals(1, WorkflowEngineMocksBTest.routedStepsRun.size());
      System.assertEquals(
        'NormalHandlerStep',
        WorkflowEngineMocksBTest.routedStepsRun[0]
      );
      System.assertEquals(
        'WorkflowEngineMocksBTest.ExplicitFailStep',
        WorkflowEngineMocksBTest.routedStepContextData.get('failedStepName')
      );
      System.assert(
        String.valueOf(
            WorkflowEngineMocksBTest.routedStepContextData.get('errorMessage')
          )
          .contains('Explicit business failure')
      );
      System.assertEquals(
        1,
        WorkflowEngineMocksBTest.routedStepContextData.get('attemptCount')
      );
    }
  }

  @IsTest
  static void testHandlerItselfFailsFallsBack() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksBTest.routedStepsRun.clear();
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.FailingHandlerWorkflow',
        'HandlerFailKey',
        null
      );

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksBTest.ExplicitFailStep'
      );

      Workflow_Instance__c inst = [
        SELECT Current_Step__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'WorkflowEngineMocksBTest.FailingHandlerStep',
        inst.Current_Step__c
      );
      System.assertEquals('Running', inst.Status__c);

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksBTest.FailingHandlerStep'
      );

      inst = [
        SELECT Current_Step__c, Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Failed', inst.Status__c);
      System.assert(inst.Error_Message__c.contains('Handler itself failed'));
    }
  }

  @IsTest
  static void testCompensationStackPreservedAcrossErrorRouting() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksBTest.routedStepsRun.clear();
      WorkflowEngineMocksBTest.compensationsRun.clear();
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.CompensatableErrorRoutedWorkflow',
        'CompStackKey',
        null
      );

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksBTest.CompensatableForwardStep1'
      );

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksBTest.ExplicitFailStep'
      );

      Workflow_Instance__c inst = [
        SELECT Current_Step__c, Status__c, Compensation_Stack__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'WorkflowEngineMocksATest.NormalHandlerStep',
        inst.Current_Step__c
      );
      System.assertEquals('Running', inst.Status__c);

      List<String> stack = (List<String>) JSON.deserialize(
        inst.Compensation_Stack__c,
        List<String>.class
      );
      System.assertEquals(1, stack.size());
      System.assertEquals(
        'WorkflowEngineMocksBTest.CompensatableForwardStep1',
        stack[0]
      );

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksATest.NormalHandlerStep'
      );

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksATest.CompensatableForwardStep2'
      );

      inst = [
        SELECT Current_Step__c, Status__c, Compensation_Stack__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      stack = (List<String>) JSON.deserialize(
        inst.Compensation_Stack__c,
        List<String>.class
      );
      System.assertEquals(2, stack.size());
      System.assertEquals(
        'WorkflowEngineMocksBTest.CompensatableForwardStep1',
        stack[0]
      );
      System.assertEquals(
        'WorkflowEngineMocksATest.CompensatableForwardStep2',
        stack[1]
      );

      WorkflowEngine.failWorkflowInstance(
        instanceId,
        'FinalFailureStep',
        'Final terminal failure triggering rollback'
      );

      inst = [
        SELECT Current_Step__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Compensating', inst.Status__c);

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksATest.CompensatableForwardStep2_Compensate'
      );

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksBTest.CompensatableForwardStep1_Compensate'
      );

      inst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Compensated', inst.Status__c);
      System.assertEquals(2, WorkflowEngineMocksBTest.compensationsRun.size());
      System.assertEquals(
        'CompensatableForwardStep2_Compensate',
        WorkflowEngineMocksBTest.compensationsRun[0]
      );
      System.assertEquals(
        'CompensatableForwardStep1_Compensate',
        WorkflowEngineMocksBTest.compensationsRun[1]
      );
    }
  }

  @IsTest
  static void testParallelErrorRoutingSiblingCancellation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksBTest.routedStepsRun.clear();
      WorkflowEngineMocksBTest.compensationsRun.clear();
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.ParallelErrorRoutedWorkflow',
        'ParallelKey',
        null
      );

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksATest.ParallelSpawnStep'
      );

      Workflow_Instance__c inst = [
        SELECT Current_Step__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assert(
        inst.Current_Step__c.contains(
          'WorkflowEngineMocksBTest.ExplicitFailStep'
        )
      );
      System.assert(
        inst.Current_Step__c.contains('WorkflowEngineMocksATest.SiblingStep')
      );

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksBTest.ExplicitFailStep'
      );

      Workflow_Step_Execution__c siblingExec = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineMocksATest.SiblingStep'
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      System.assertEquals('Cancelled', siblingExec.Status__c);

      inst = [
        SELECT Current_Step__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'WorkflowEngineMocksATest.NormalHandlerStep',
        inst.Current_Step__c
      );
      System.assertEquals('Running', inst.Status__c);

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksATest.SiblingStep'
      );

      inst = [
        SELECT Current_Step__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'WorkflowEngineMocksATest.NormalHandlerStep',
        inst.Current_Step__c
      );
    }
  }

  @IsTest
  static void testStaleCompletionSignalRollback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksBTest.routedStepsRun.clear();
      WorkflowEngineMocksBTest.compensationsRun.clear();
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.StaleSignalRollbackWorkflow',
        'ParallelKey',
        null
      );

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksBTest.StaleSpawnStep'
      );

      // Insert a signal that the stale sibling step will claim
      Workflow_Signal__c sig = new Workflow_Signal__c(
        Workflow_Instance__c = instanceId,
        Signal_Name__c = 'TestSignal',
        Correlation_Key__c = 'ParallelKey',
        Status__c = 'Received'
      );
      insert as system sig;

      // Run the StaleSignalSiblingStep. During its execute(), it claims the signal
      // and then updates the instance's Current_Step__c to NormalHandlerStep,
      // causing handleStepResult to treat it as a stale completion.
      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksBTest.StaleSignalSiblingStep'
      );

      // Verify that the signal's status is rolled back to Received
      sig = [
        SELECT Status__c
        FROM Workflow_Signal__c
        WHERE Id = :sig.Id
        WITH SYSTEM_MODE
      ];
      System.assertEquals('Received', sig.Status__c);
    }
  }

  @IsTest
  static void testRetryExhaustedAttemptCount() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksBTest.routedStepsRun.clear();
      WorkflowEngineMocksBTest.routedStepContextData.clear();
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.RetryExhaustedErrorRoutedWorkflow',
        'RetryExhaustedKey',
        null
      );

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksBTest.RetryExhaustedFailureStep'
      );

      Workflow_Instance__c inst = [
        SELECT Current_Step__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'WorkflowEngineMocksATest.NormalHandlerStep',
        inst.Current_Step__c
      );
      System.assertEquals('Running', inst.Status__c);

      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksATest.NormalHandlerStep'
      );

      System.assertEquals(1, WorkflowEngineMocksBTest.routedStepsRun.size());
      System.assertEquals(
        'NormalHandlerStep',
        WorkflowEngineMocksBTest.routedStepsRun[0]
      );
      System.assertEquals(
        'WorkflowEngineMocksBTest.RetryExhaustedFailureStep',
        (String) WorkflowEngineMocksBTest.routedStepContextData.get(
          'failedStepName'
        )
      );
      System.assertEquals(
        1,
        (Integer) WorkflowEngineMocksBTest.routedStepContextData.get(
          'attemptCount'
        )
      );
    }
  }

  @IsTest
  static void testWatchdogTimeoutErrorRouting() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksBTest.routedStepsRun.clear();
      WorkflowEngineMocksBTest.routedStepContextData.clear();
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.TimeoutErrorRoutedWorkflow',
        'TimeoutRoutedKey',
        null
      );

      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      // Simulate running state
      inst.Status__c = 'Running';
      inst.Current_Step__c = 'WorkflowEngineMocksATest.TimeoutFailureStep';
      update inst;

      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Id, Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineMocksATest.TimeoutFailureStep'
        LIMIT 1
      ];
      System.assert(!stepExecs.isEmpty());
      Workflow_Step_Execution__c stepExec = stepExecs[0];
      stepExec.Status__c = 'Running';
      stepExec.Timeout_At__c = DateTime.now().addSeconds(-10);
      update as system stepExec;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      inst = [
        SELECT Current_Step__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'WorkflowEngineMocksATest.NormalHandlerStep',
        inst.Current_Step__c
      );
      System.assertEquals('Running', inst.Status__c);
    }
  }

  @IsTest
  static void testErrorRoutingWorkflowInStartValidation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.PureRoutingWorkflow',
        'PureRoutingKey',
        null
      );
      System.assertNotEquals(null, instanceId);
    }
  }

  @IsTest
  static void testPreserveErrorMetadataAcrossHandlerCheckpoint() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksBTest.routedStepsRun.clear();
      WorkflowEngineMocksBTest.routedStepContextData.clear();
      WorkflowEngineMocksBTest.yieldingHandlerFirstRunDone = false;
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.YieldingHandlerWorkflow',
        'YieldingKey',
        null
      );

      // Fail the step and route to YieldingHandlerStep
      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksBTest.RetryExhaustedFailureStep'
      );

      // Run the YieldingHandlerStep (first execution -> returns Sleep, writes capture)
      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksATest.YieldingHandlerStep'
      );

      Workflow_Instance__c inst = [
        SELECT Current_Step__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'WorkflowEngineMocksATest.YieldingHandlerStep',
        inst.Current_Step__c
      );
      System.assertEquals('Suspended', inst.Status__c);

      // Re-run the YieldingHandlerStep (second execution -> completes, reads capture)
      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksATest.YieldingHandlerStep'
      );

      System.assertEquals(1, WorkflowEngineMocksBTest.routedStepsRun.size());
      System.assertEquals(
        'YieldingHandlerStep',
        WorkflowEngineMocksBTest.routedStepsRun[0]
      );
      System.assertEquals(
        'WorkflowEngineMocksBTest.RetryExhaustedFailureStep',
        (String) WorkflowEngineMocksBTest.routedStepContextData.get(
          'failedStepName'
        )
      );
      System.assertEquals(
        1,
        (Integer) WorkflowEngineMocksBTest.routedStepContextData.get(
          'attemptCount'
        )
      );
    }
  }

  @IsTest
  static void testLoadErrorMetadataForRetryableHandler() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngineMocksBTest.routedStepsRun.clear();
      WorkflowEngineMocksBTest.routedStepContextData.clear();
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.RetryableHandlerWorkflow',
        'RetryableHandlerKey',
        null
      );

      // Fail the step and route to RetryableHandlerStep
      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksBTest.RetryExhaustedFailureStep'
      );

      Workflow_Instance__c inst = [
        SELECT Current_Step__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'WorkflowEngineMocksBTest.RetryableHandlerStep',
        inst.Current_Step__c
      );
      System.assertEquals('Running', inst.Status__c);

      // Run the RetryableHandlerStep
      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksBTest.RetryableHandlerStep'
      );

      System.assertEquals(1, WorkflowEngineMocksBTest.routedStepsRun.size());
      System.assertEquals(
        'RetryableHandlerStep',
        WorkflowEngineMocksBTest.routedStepsRun[0]
      );
      System.assertEquals(
        'WorkflowEngineMocksBTest.RetryExhaustedFailureStep',
        (String) WorkflowEngineMocksBTest.routedStepContextData.get(
          'failedStepName'
        )
      );
      System.assertEquals(
        1,
        (Integer) WorkflowEngineMocksBTest.routedStepContextData.get(
          'attemptCount'
        )
      );
    }
  }

  @IsTest
  static void testGetPatchAdoptionCount() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 1. Create a non-terminal instance (Running)
      Workflow_Instance__c inst1 = new Workflow_Instance__c(
        Workflow_Name__c = 'TestWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'AdoptKey1'
      );
      insert inst1;

      // 2. Create another non-terminal instance (Suspended)
      Workflow_Instance__c inst2 = new Workflow_Instance__c(
        Workflow_Name__c = 'TestWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'AdoptKey2'
      );
      insert inst2;

      // 3. Create a terminal instance (Completed)
      Workflow_Instance__c inst3 = new Workflow_Instance__c(
        Workflow_Name__c = 'TestWorkflow',
        Status__c = 'Completed',
        Correlation_Key__c = 'AdoptKey3'
      );
      insert inst3;

      // 4. Create step executions with patch decisions
      // inst1: recorded __patch:change-1 = false
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst1.Id,
        Step_Name__c = 'StepB',
        Status__c = 'Completed',
        Captured_Values__c = '{"__patch:change-1":false}'
      );

      // inst2: recorded __patch:change-1 = true
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst2.Id,
        Step_Name__c = 'StepB',
        Status__c = 'Completed',
        Captured_Values__c = '{"__patch:change-1":true}'
      );

      // inst3: recorded __patch:change-1 = false (but it's Completed, a terminal status)
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst3.Id,
        Step_Name__c = 'StepB',
        Status__c = 'Completed',
        Captured_Values__c = '{"__patch:change-1":false}'
      );

      // Query adoption: only inst1 is non-terminal AND has __patch:change-1 = false.
      // So the count should be exactly 1.
      Integer count = WorkflowPatchAdoption.getPatchAdoptionCount('change-1');
      System.assertEquals(1, count, 'Adoption count should be 1');
    }
  }

  @IsTest
  static void testGetPatchAdoptionCountOffloaded() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 1. Create a non-terminal instance
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'TestWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'AdoptKeyOffloaded'
      );
      insert inst;

      // 2. Save patch decision to ContentVersion (offloaded payload)
      String capturesJson = '{"__patch:change-offload":false}';
      String marker = WorkflowPayloadOffload.savePayloadIfNeeded(
        inst.Id,
        capturesJson,
        'CapturedValues'
      );

      // 3. Create a step execution with the offloaded marker
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'StepB',
        Status__c = 'Completed',
        Captured_Values__c = marker
      );

      // 4. Query adoption: it should resolve the offloaded payload and count it as 1!
      Integer count = WorkflowPatchAdoption.getPatchAdoptionCount(
        'change-offload'
      );
      System.assertEquals(
        1,
        count,
        'Adoption count should find offloaded legacy instance'
      );
    }
  }

  @IsTest
  static void testGetPatchAdoptionCountThrowsExceptionWhenCapped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPatchAdoption.adoptionQueryLimit = 1;
      try {
        Workflow_Instance__c inst1 = new Workflow_Instance__c(
          Workflow_Name__c = 'TestWorkflow',
          Status__c = 'Running',
          Correlation_Key__c = 'CappedKey1'
        );
        Workflow_Instance__c inst2 = new Workflow_Instance__c(
          Workflow_Name__c = 'TestWorkflow',
          Status__c = 'Running',
          Correlation_Key__c = 'CappedKey2'
        );
        insert new List<Workflow_Instance__c>{ inst1, inst2 };

        insert new List<Workflow_Step_Execution__c>{
          new Workflow_Step_Execution__c(
            Workflow_Instance__c = inst1.Id,
            Step_Name__c = 'StepB',
            Status__c = 'Completed',
            Captured_Values__c = '{"__patch:change-capped":false}'
          ),
          new Workflow_Step_Execution__c(
            Workflow_Instance__c = inst2.Id,
            Step_Name__c = 'StepB',
            Status__c = 'Completed',
            Captured_Values__c = '{"__patch:change-capped":false}'
          )
        };

        try {
          WorkflowPatchAdoption.getPatchAdoptionCount('change-capped');
          System.assert(false, 'Should throw exception when query is capped');
        } catch (WorkflowEngine.WorkflowException e) {
          System.assert(
            e.getMessage().contains('Active instances exceed query limit')
          );
        }
      } finally {
        WorkflowPatchAdoption.adoptionQueryLimit = 45000;
      }
    }
  }

  @IsTest
  static void testGetPatchAdoptionCountExactKeyMatching() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      DateTime introducedAt = DateTime.newInstance(2026, 1, 2);

      try {
        // Insert a real parent instance to satisfy database reference checks
        Workflow_Instance__c realInst = new Workflow_Instance__c(
          Workflow_Name__c = 'TestWorkflowExact',
          Status__c = 'Running',
          Correlation_Key__c = 'ExactKey1'
        );
        insert realInst;

        // Create a mock active instance created on Day 1 (before introducedAt) using the real ID
        String instanceJson =
          '{"attributes":{"type":"Workflow_Instance__c"},"Id":"' +
          realInst.Id +
          '","Workflow_Name__c":"TestWorkflowExact","Status__c":"Running","CreatedDate":"2026-01-01T00:00:00.000Z"}';
        Workflow_Instance__c mockInst = (Workflow_Instance__c) JSON.deserialize(
          instanceJson,
          Workflow_Instance__c.class
        );
        WorkflowPatchAdoption.mockInstancesForAdoption = new List<Workflow_Instance__c>{
          mockInst
        };

        // Create a step execution with a similar patch name (e.g. 'foo-v2' containing 'foo')
        insert new Workflow_Step_Execution__c(
          Workflow_Instance__c = mockInst.Id,
          Step_Name__c = 'StepB',
          Status__c = 'Completed',
          Captured_Values__c = '{"__patch:foo-v2":false}'
        );

        // Query adoption count for 'foo' (which this workflow has NOT used exactly!)
        // Since it only has 'foo-v2', 'foo' adoption count should be 0, not 1!
        Integer count = WorkflowPatchAdoption.getPatchAdoptionCount(
          'foo',
          introducedAt
        );
        System.assertEquals(
          0,
          count,
          'Should not count mockInst as legacy for foo since it only used foo-v2'
        );

        // If we query for 'foo-v2', it should count it as 1!
        Integer countV2 = WorkflowPatchAdoption.getPatchAdoptionCount(
          'foo-v2',
          introducedAt
        );
        System.assertEquals(
          1,
          countV2,
          'Should count mockInst as legacy for foo-v2 since it matches exactly'
        );
      } finally {
        WorkflowPatchAdoption.mockInstancesForAdoption = null;
      }
    }
  }
}
