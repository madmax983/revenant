@IsTest
public class WorkflowEngineCore1Test {
  @IsTest
  static void testHappyPath() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'HappyKey',
        'StartVal'
      );
      Test.stopTest(); // Runs HappyStep1 synchronously

      // Manually execute second step HappyStep2 synchronously
      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Instance__c inst = [
        SELECT Status__c, Output__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', inst.Status__c);
      System.assertEquals('"Output1_Output2"', inst.Output__c);
      System.assertEquals(null, inst.Current_Step__c);

      List<Workflow_Step_Execution__c> steps = [
        SELECT Step_Name__c, Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId
        ORDER BY CreatedDate ASC
      ];
      System.assertEquals(2, steps.size());
      System.assertEquals(
        'WorkflowEngineTest.HappyStep1',
        steps[0].Step_Name__c
      );
      System.assertEquals('Completed', steps[0].Status__c);
      System.assertEquals(
        'WorkflowEngineTest.HappyStep2',
        steps[1].Step_Name__c
      );
      System.assertEquals('Completed', steps[1].Status__c);
    }
  }

  @IsTest
  static void testYieldingPath() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.YieldingWorkflow',
        'YieldKey',
        null
      );
      Test.stopTest(); // Runs initial step execution (which yields first time)

      Workflow_Instance__c inst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Running', inst.Status__c);

      List<Workflow_Step_Execution__c> steps = [
        SELECT Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId
      ];
      System.assertEquals(1, steps.size());
      System.assertEquals('Running', steps[0].Status__c);
      System.assert(steps[0].Output__c.contains('"processed":1'));

      // Manually run orchestrator for second yield (processed = 2)
      new WorkflowOrchestrator(instanceId).execute(null);
      steps = [
        SELECT Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId
      ];
      System.assert(steps[0].Output__c.contains('"processed":2'));

      // Manually run orchestrator for third yield (processed = 3)
      new WorkflowOrchestrator(instanceId).execute(null);
      steps = [
        SELECT Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId
      ];
      System.assert(steps[0].Output__c.contains('"processed":3'));

      // Manually run orchestrator for final complete
      new WorkflowOrchestrator(instanceId).execute(null);

      inst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', inst.Status__c);
      System.assertEquals('"Done_3"', inst.Output__c);
    }
  }

  @IsTest
  static void testSuspensionAndResume() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.SuspendingWorkflow',
        'SuspendKey',
        null
      );
      Test.stopTest(); // Enqueues and executes SuspendingStep which suspends

      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Suspended', inst.Status__c);
      System.assertEquals(
        'WorkflowEngineTest.SuspendingStep',
        inst.Current_Step__c
      );

      // Resume using Platform Event
      Workflow_Event__e event = new Workflow_Event__e(
        Workflow_Instance_Id__c = 'SuspendKey',
        Event_Type__c = 'RESUME',
        Payload__c = 'EventData'
      );

      EventBus.publish(event);
      Test.getEventBus().deliver(); // Trigger executes resume() synchronously

      // Manually run orchestrator to execute the next step (resumed SuspendingStep)
      new WorkflowOrchestrator(instanceId).execute(null);

      // Manually run orchestrator again to execute the subsequent AfterSuspendStep
      new WorkflowOrchestrator(instanceId).execute(null);

      inst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', inst.Status__c);
      System.assertEquals('"Resumed_EventData"', inst.Output__c);
    }
  }

  @IsTest
  static void testSignals() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Start a workflow that blocks on a signal
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.SignaledWorkflow',
        'SignalKey',
        null
      );
      Test.stopTest(); // Runs SignaledStep which suspends waiting for 'PaymentReceived'

      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Suspended', inst.Status__c);
      System.assertEquals(
        'WorkflowEngineMocksATest.SignaledStep',
        inst.Current_Step__c
      );

      // Send a signal via Platform Event using Event_Type__c = 'SIGNAL:PaymentReceived'
      Workflow_Event__e event = new Workflow_Event__e(
        Workflow_Instance_Id__c = 'SignalKey',
        Event_Type__c = 'SIGNAL:PaymentReceived',
        Payload__c = '{"amount": 150}'
      );

      EventBus.publish(event);
      Test.getEventBus().deliver(); // Trigger runs, inserts Workflow_Signal__c, sets workflow to Running

      // Verify the signal was recorded
      Workflow_Signal__c sig = [
        SELECT Signal_Name__c, Payload__c, Status__c
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :instanceId
        LIMIT 1
      ];
      System.assertEquals('PaymentReceived', sig.Signal_Name__c);
      System.assertEquals('{"amount": 150}', sig.Payload__c);
      System.assertEquals('Received', sig.Status__c);

      // Manually execute the orchestrator to run the step again with the signal now populated
      new WorkflowOrchestrator(instanceId).execute(null);

      // Verify that the step completed and consumed the signal
      inst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', inst.Status__c);
      System.assertEquals('"Paid_{\\"amount\\": 150}"', inst.Output__c);

      sig = [SELECT Status__c FROM Workflow_Signal__c WHERE Id = :sig.Id];
      System.assertEquals('Consumed', sig.Status__c);
    }
  }

  @IsTest
  static void testCustomRetryPolicy() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.CustomRetryWorkflow',
        'RetryKey',
        null
      );
      Test.stopTest(); // Runs CustomRetryStep once synchronously, which fails and triggers first retry (attempts=1, delay=2s)

      Workflow_Step_Execution__c step = [
        SELECT Status__c, Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId
        LIMIT 1
      ];
      System.assertEquals('Retrying', step.Status__c);
      System.assertEquals(1, step.Retry_Count__c);

      // Run second attempt manually
      WorkflowEngine.runStep(instanceId); // CustomRetryStep runs, returns retry, triggers second retry (attempts=2, delay=6s)

      step = [
        SELECT Status__c, Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId
        LIMIT 1
      ];
      System.assertEquals('Retrying', step.Status__c);
      System.assertEquals(2, step.Retry_Count__c);

      // Run third attempt manually (should exceed maximum attempts of 3)
      WorkflowEngine.runStep(instanceId); // CustomRetryStep runs, returns retry, attempts=3 >= maximumAttempts(3) -> transitions to Failed

      step = [
        SELECT Status__c, Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId
        LIMIT 1
      ];
      System.assertEquals('Failed', step.Status__c);
      System.assertEquals(3, step.Retry_Count__c);

      Workflow_Instance__c inst = [
        SELECT Status__c, Error_Message__c, Failure_Category__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Failed', inst.Status__c);
      System.assert(inst.Error_Message__c.contains('Max retries exceeded'));
      System.assertEquals('RETRIES_EXHAUSTED', inst.Failure_Category__c);
    }
  }

  @IsTest
  static void testCrashAndFinalizer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.CrashingWorkflow',
        'CrashKey',
        null
      );

      Workflow_Instance__c inst = [
        SELECT Id, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      inst.Current_Step__c = 'WorkflowEngineMocksATest.CrashingStep';
      update inst;

      Boolean threw = false;
      Test.startTest();
      try {
        WorkflowEngine.runStep(instanceId);
      } catch (Exception ex) {
        threw = true;
        // Simulate Transaction Finalizer rescue operation
        WorkflowEngine.handleCrash(instanceId, ex);
      }
      Test.stopTest();

      System.assert(threw, 'Should have thrown exception');

      inst = [
        SELECT Status__c, Error_Message__c, Failure_Category__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Failed', inst.Status__c);
      System.assert(inst.Error_Message__c.contains('Simulated Crash'));
      System.assertEquals('STEP_EXCEPTION', inst.Failure_Category__c);

      Workflow_Step_Execution__c step = [
        SELECT Status__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId
        LIMIT 1
      ];
      System.assertEquals('Failed', step.Status__c);
      System.assert(step.Error_Details__c.contains('Simulated Crash'));
    }
  }

  @IsTest
  static void testSleepingWorkflow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.SleepingWorkflow',
        'SleepKey',
        null
      );
      Test.stopTest(); // Runs SleepingStep once synchronously, which requests sleep

      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Suspended', inst.Status__c);
      System.assertEquals(
        'WorkflowEngineMocksBTest.SleepingStep',
        inst.Current_Step__c
      );

      Workflow_Step_Execution__c step = [
        SELECT Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId
        LIMIT 1
      ];
      System.assertEquals('Pending', step.Status__c);
      System.assertEquals('resumed_state', step.Output__c);

      // Manually call runStep to simulate the timer firing and enqueuing execution
      WorkflowEngine.runStep(instanceId); // SleepingStep runs again, sees stepStateJson != null, completes.

      // Manually execute second step (AfterSleepStep) synchronously
      new WorkflowOrchestrator(instanceId).execute(null);

      inst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', inst.Status__c);
      System.assertEquals('"Done_resumed_state"', inst.Output__c);
    }
  }

  @IsTest
  static void testParentChildWorkflow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id parentId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.ParentWorkflow',
        'ParentKey',
        null
      );
      Test.stopTest(); // Executes ParentStep once, starts child, and suspends parent

      Workflow_Instance__c parentInst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :parentId
      ];
      System.assertEquals('Suspended', parentInst.Status__c);

      Workflow_Step_Execution__c parentStep = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :parentId
          AND Step_Name__c = 'WorkflowEngineMocksBTest.ParentStep'
        LIMIT 1
      ];
      System.assertNotEquals(null, parentStep.Output__c);
      Map<String, Object> childInfo = (Map<String, Object>) JSON.deserializeUntyped(
        parentStep.Output__c
      );
      System.assertEquals(
        'WorkflowEngineMocksATest.ChildWorkflow',
        childInfo.get('childWorkflowName')
      );
      System.assertEquals('SubKey', childInfo.get('childCorrelationKey'));

      Workflow_Instance__c childInst = [
        SELECT
          Id,
          Status__c,
          Parent_Instance__c,
          Correlation_Key__c,
          Causation_Id__c
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :parentId
        LIMIT 1
      ];
      System.assertEquals('SubKey', childInst.Correlation_Key__c);
      System.assertEquals('Pending', childInst.Status__c);
      System.assertEquals(
        parentId,
        childInst.Causation_Id__c,
        'Child must have parent Id as Causation_Id__c'
      );

      WorkflowEngine.WorkflowStatus status = WorkflowStatusRead.getStatus(
        childInst.Id
      );
      System.assertEquals(
        parentId,
        status.causationId,
        'WorkflowStatus must return parent Id as causationId'
      );

      // Execute child workflow synchronously
      new WorkflowOrchestrator(childInst.Id).execute(null); // ChildStep completes, triggers child completion event

      // Deliver Platform Event (ChildCompleted) to parent
      Test.getEventBus().deliver(); // Parent becomes Running, enqueues orchestrator

      // Manually run orchestrator for parent to consume child output signal and complete
      new WorkflowOrchestrator(parentId).execute(null);

      parentInst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :parentId
      ];
      System.assertEquals('Completed', parentInst.Status__c);
      System.assertEquals(
        '"ParentResult_ChildInput_ChildDone"',
        parentInst.Output__c
      );
    }
  }

  @IsTest
  static void testRetryWorkflow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Start the workflow that will fail
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.FailingWorkflow',
        'FailingKey',
        null
      );

      // Execute failing step manually. It will request a retry and hit maxAttempts = 1, resulting in Failure.
      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Instance__c inst = [
        SELECT Status__c, Error_Message__c, Current_Step__c, Failure_Category__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Failed', inst.Status__c, 'Should be failed');
      System.assertNotEquals(null, inst.Error_Message__c);
      System.assertEquals('RETRIES_EXHAUSTED', inst.Failure_Category__c);

      Workflow_Step_Execution__c stepExec = [
        SELECT Status__c, Retry_Count__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = :inst.Current_Step__c
        LIMIT 1
      ];
      System.assertEquals('Failed', stepExec.Status__c);

      // Now, trigger the retry! Change mock state to succeed
      WorkflowEngineMocksATest.shouldSucceedOnFailingStep = true;

      Test.startTest();
      WorkflowEngine.retryWorkflow(instanceId);
      // This will run the Orchestrator synchronously in Test context
      Test.stopTest();

      Workflow_Instance__c retriedInst = [
        SELECT Status__c, Error_Message__c, Failure_Category__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Completed',
        retriedInst.Status__c,
        'Should complete successfully now'
      );
      System.assertEquals(null, retriedInst.Error_Message__c);
      System.assertEquals(null, retriedInst.Failure_Category__c);
    }
  }

  @IsTest
  static void testWorkflowTimeout() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Start a workflow instance
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.TimeoutWorkflow',
        'TimeoutKey',
        null
      );

      // Assert a step execution record is created when started
      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      // In the test context, because it ran manually, it completed successfully (since execute is synchronous).
      // Let's now simulate a timeout by changing status back to Running and manually executing the timeout job!
      inst.Status__c = 'Running';
      inst.Current_Step__c = 'WorkflowEngineTest.TimeoutStep';
      update inst;

      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Id, Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineTest.TimeoutStep'
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

      // Check if both records are marked Failed
      Workflow_Instance__c timedOutInst = [
        SELECT Status__c, Error_Message__c, Failure_Category__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Failed', timedOutInst.Status__c);
      System.assertEquals(
        'Failed at step WorkflowEngineTest.TimeoutStep: Step execution timed out.',
        timedOutInst.Error_Message__c
      );
      System.assertEquals('TIMEOUT', timedOutInst.Failure_Category__c);

      Workflow_Step_Execution__c timedOutStep = [
        SELECT Status__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExec.Id
      ];
      System.assertEquals('Failed', timedOutStep.Status__c);
      System.assertEquals(
        'Step execution timed out.',
        timedOutStep.Error_Details__c
      );
    }
  }

  @IsTest
  static void testWorkflowApproval() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.ApprovalWorkflow',
        'ApprovalKey',
        null
      );

      // Execute initial step. It will return waitForApproval and suspend.
      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Suspended', inst.Status__c);
      System.assertEquals(
        'WorkflowEngineMocksATest.ApprovalStep',
        inst.Current_Step__c
      );

      Workflow_Step_Execution__c stepExec = [
        SELECT Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineMocksATest.ApprovalStep'
        LIMIT 1
      ];
      System.assertEquals('Pending', stepExec.Status__c);
      System.assert(stepExec.Output__c.contains('"waitingForApproval":true'));
      System.assert(
        stepExec.Output__c.contains('"approvalKey":"ExpenseApproval"')
      );
      System.assert(stepExec.Output__c.contains('"approvalRole":"Manager"'));

      // Signal the approval
      Test.startTest();
      WorkflowEngine.signal(
        'ApprovalKey',
        'Approve:ExpenseApproval',
        '{"approved":true,"comments":"Approved","approver":"test@example.com"}'
      );
      Test.stopTest();

      // Platform Event delivery wakes up the parent orchestrator synchronously in test
      Test.getEventBus().deliver();

      // Run orchestrator to consume signal and complete step
      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Instance__c completedInst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', completedInst.Status__c);
      System.assertEquals('"Approved"', completedInst.Output__c);
    }
  }

  @IsTest
  static void testParallelExecution() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.ParallelWorkflow',
        'ParallelKey',
        null
      );

      // Run initial SplitStep
      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Running', inst.Status__c);
      System.assertEquals(
        'WorkflowEngineMocksATest.ParallelStep1,WorkflowEngineMocksATest.ParallelStep2',
        inst.Current_Step__c
      );

      // Run ParallelStep1 manually
      new WorkflowOrchestrator(
          instanceId,
          'WorkflowEngineMocksATest.ParallelStep1'
        )
        .execute(null);

      // Verify workflow is still running and waiting for ParallelStep2
      inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Running', inst.Status__c);

      // Run ParallelStep2 manually
      new WorkflowOrchestrator(
          instanceId,
          'WorkflowEngineMocksATest.ParallelStep2'
        )
        .execute(null);

      // Run JoinStep manually
      new WorkflowOrchestrator(instanceId).execute(null);

      // Verify JoinStep has executed and completed the workflow
      inst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', inst.Status__c);
      System.assertEquals(
        '"BranchInput_P1Done+BranchInput_P2Done"',
        inst.Output__c
      );
    }
  }

  @IsTest
  static void testStepContextShouldYield() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = new StepContext.Builder()
        .workflowName('TestWorkflow')
        .stepName('TestStep')
        .build();
      // Under normal test conditions, limit usage is low, so shouldYield should return false
      System.assertEquals(false, ctx.shouldYield());
    }
  }

  @IsTest
  static void testTriggerQueueableThrottling() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Create 55 distinct workflow instances
      List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 55; i++) {
        instances.add(
          new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Running',
            Current_Step__c = 'WorkflowEngineTest.HappyStep1'
          )
        );
      }
      insert instances;

      List<Workflow_Event__e> events = new List<Workflow_Event__e>();
      for (Integer i = 0; i < 55; i++) {
        events.add(
          new Workflow_Event__e(
            Workflow_Instance_Id__c = instances[i].Id,
            Event_Type__c = 'RUN_STEP',
            Payload__c = 'WorkflowEngineTest.HappyStep1'
          )
        );
      }

      Test.startTest();
      List<Database.SaveResult> srs = EventBus.publish(events);
      for (Database.SaveResult sr : srs) {
        System.assert(sr.isSuccess());
      }
      Test.stopTest();
    }
  }

  @IsTest
  static void testCorrelationKeyValidation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String longKey = 'A'.repeat(201);
      try {
        WorkflowEngine.start('WorkflowEngineTest.HappyWorkflow', longKey, null);
        System.assert(
          false,
          'Should have thrown exception for long correlation key'
        );
      } catch (WorkflowEngine.WorkflowException ex) {
        System.assert(
          ex.getMessage()
            .contains('Correlation key length cannot exceed 200 characters')
        );
      }

      try {
        WorkflowEngine.start('WorkflowEngineTest.HappyWorkflow', null, null);
        System.assert(
          false,
          'Should have thrown exception for null correlation key'
        );
      } catch (WorkflowEngine.WorkflowException ex) {
        System.assert(ex.getMessage().contains('Correlation key is required'));
      }

      try {
        WorkflowEngine.start('WorkflowEngineTest.HappyWorkflow', '', null);
        System.assert(
          false,
          'Should have thrown exception for empty correlation key'
        );
      } catch (WorkflowEngine.WorkflowException ex) {
        System.assert(ex.getMessage().contains('Correlation key is required'));
      }
    }
  }

  @IsTest
  static void testLargePayloadFileOffloading() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String largeInput = 'A'.repeat(110000);

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.LargePayloadWorkflow',
        'LargePayloadKey',
        largeInput
      );
      Test.stopTest(); // Executes first step LargePayloadStep

      // Query the instance in database
      Workflow_Instance__c inst = [
        SELECT Input__c, Output__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', inst.Status__c);

      // Assert that the input is stored as attachment marker
      System.assert(
        inst.Input__c.startsWith('{"$attachmentId":'),
        'Input__c should be stored as attachment marker but got: ' +
        inst.Input__c
      );
      System.assert(
        inst.Output__c.startsWith('{"$attachmentId":'),
        'Output__c should be stored as attachment marker but got: ' +
        inst.Output__c
      );

      // Assert ContentVersion records exist
      List<ContentDocumentLink> links = [
        SELECT ContentDocumentId
        FROM ContentDocumentLink
        WHERE LinkedEntityId = :instanceId
      ];
      System.assertEquals(
        3,
        links.size(),
        'Should have created 3 file links (one for Input, one for Step Output, and one for Final Output)'
      );

      // Fetch details via dashboard controller and verify transparent resolution
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        instanceId
      );
      Workflow_Instance__c detailedInst = (Workflow_Instance__c) details.get(
        'instance'
      );
      System.assertEquals(
        50015,
        detailedInst.Input__c.length(),
        'Input should resolve to truncated length due to dashboard cap'
      );
      System.assert(
        detailedInst.Input__c.endsWith('... (truncated)'),
        'Input should be truncated'
      );
      System.assertEquals(
        50015,
        detailedInst.Output__c.length(),
        'Output should resolve to truncated length due to dashboard cap'
      );
      System.assert(
        detailedInst.Output__c.endsWith('... (truncated)'),
        'Output should be truncated'
      );

      // Run Cleanup/Purge step on this instance
      CleanupWorkflow.PurgeOldInstancesStep purgeStep = new CleanupWorkflow.PurgeOldInstancesStep();

      StepContext purgeCtx = new StepContext.Builder()
        .workflowName('CleanupWorkflow')
        .stepName('CleanupWorkflow.PurgeOldInstancesStep')
        .workflowInputJson('{"retentionDays":0,"batchSize":100}')
        .workflowVersion(1)
        .build();

      // Execute purge
      StepResult purgeResult = purgeStep.execute(purgeCtx);
      System.assertEquals(
        StepResult.ActionType.COMPLETE,
        purgeResult.directive().action
      );

      // Verify ContentDocument links and files are deleted
      List<ContentDocumentLink> remainingLinks = [
        SELECT ContentDocumentId
        FROM ContentDocumentLink
        WHERE LinkedEntityId = :instanceId
      ];
      System.assertEquals(
        0,
        remainingLinks.size(),
        'All links should be deleted'
      );

      List<Workflow_Instance__c> remainingInstances = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        0,
        remainingInstances.size(),
        'Workflow instance should be deleted'
      );
    }
  }

  @IsTest
  static void testContinueAsNew() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.DaemonWorkflow',
        'DaemonKey',
        0
      );
      new WorkflowOrchestrator(instanceId).execute(null); // Runs the first execution run (counter 0 -> continueAsNew 1)

      // Manual triggers for execution runs 2 and 3

      // Query Run 1
      Workflow_Instance__c run1 = [
        SELECT Status__c, Correlation_Key__c, Input__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('ContinuedAsNew', run1.Status__c);
      System.assertEquals('DaemonKey', run1.Correlation_Key__c);

      // Find and run Run 2
      Workflow_Instance__c run2 = [
        SELECT
          Id,
          Status__c,
          Correlation_Key__c,
          Input__c,
          Previous_Instance__c,
          Previous_Run_At__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :run1.Id
      ];
      System.assertEquals('Pending', run2.Status__c);
      System.assertEquals('DaemonKey_run2', run2.Correlation_Key__c);
      System.assertEquals('1', run2.Input__c);
      System.assertNotEquals(
        null,
        run2.Previous_Run_At__c,
        'Successor instance must carry the predecessor run timestamp'
      );

      // Execute Run 2 (counter 1 -> continueAsNew 2)
      new WorkflowOrchestrator(run2.Id).execute(null);

      run2 = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :run2.Id];
      System.assertEquals('ContinuedAsNew', run2.Status__c);

      // Find and run Run 3
      Workflow_Instance__c run3 = [
        SELECT Id, Status__c, Correlation_Key__c, Input__c, Previous_Instance__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :run2.Id
      ];
      System.assertEquals('Pending', run3.Status__c);
      System.assertEquals('DaemonKey_run3', run3.Correlation_Key__c);
      System.assertEquals('2', run3.Input__c);

      // Execute Run 3 (counter 2 -> complete 3)
      new WorkflowOrchestrator(run3.Id).execute(null);

      run3 = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :run3.Id
      ];
      System.assertEquals('Completed', run3.Status__c);
      System.assertEquals('3', run3.Output__c);
    }
  }
}
