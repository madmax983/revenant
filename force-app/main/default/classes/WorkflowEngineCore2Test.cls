@IsTest
public class WorkflowEngineCore2Test {
  @IsTest
  static void testStepNameValidation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'ValidationKey',
        null
      );

      // Let's run a step but supply an invalid step name
      try {
        WorkflowEngine.runStep(instanceId, 'InvalidStepName');
        System.assert(false, 'Should have failed step validation');
      } catch (WorkflowEngine.WorkflowException ex) {
        System.assert(
          ex.getMessage().contains('is not the active/expected step'),
          'Error should be about invalid step: ' + ex.getMessage()
        );
      }
    }
  }

  @IsTest
  static void testParallelRecovery() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.ParallelWorkflow',
        'ParallelRecoveryKey',
        null
      );

      // Execute initial split step to spawn parallel branches
      WorkflowEngine.runStep(instanceId, null);

      Workflow_Instance__c inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'WorkflowEngineMocksATest.ParallelStep1,WorkflowEngineMocksATest.ParallelStep2',
        inst.Current_Step__c
      );

      // Make ParallelStep2 succeed
      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksATest.ParallelStep2'
      );

      // Verify ParallelStep2 is Completed
      Workflow_Step_Execution__c step2Exec = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineMocksATest.ParallelStep2'
        LIMIT 1
      ];
      System.assertEquals('Completed', step2Exec.Status__c);

      // Now simulate a crash on ParallelStep1
      WorkflowEngine.handleCrash(
        instanceId,
        'WorkflowEngineMocksATest.ParallelStep1',
        new WorkflowEngine.WorkflowException('Parallel step 1 crashed')
      );

      // Verify instance and ParallelStep1 are Failed
      inst = [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Failed', inst.Status__c);
      System.assert(inst.Error_Message__c.contains('ParallelStep1'));

      Workflow_Step_Execution__c step1Exec = [
        SELECT Status__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineMocksATest.ParallelStep1'
        LIMIT 1
      ];
      System.assertEquals('Failed', step1Exec.Status__c);
      System.assert(
        step1Exec.Error_Details__c.contains('Parallel step 1 crashed')
      );

      // Retry the workflow - should only reset ParallelStep1 and spawn orchestrator for it
      WorkflowEngine.retryWorkflow(instanceId);

      step1Exec = [
        SELECT Status__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineMocksATest.ParallelStep1'
        LIMIT 1
      ];
      System.assertEquals('Pending', step1Exec.Status__c);
      System.assertEquals(null, step1Exec.Error_Details__c);

      // ParallelStep2 should remain Completed
      step2Exec = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineMocksATest.ParallelStep2'
        LIMIT 1
      ];
      System.assertEquals('Completed', step2Exec.Status__c);
    }
  }

  @IsTest
  static void testCorrelationKeyReuse() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // Disable the dedup window so a completed key may be reused (legacy reuse)
      WorkflowEngine.dedupWindowMinutes = 0;

      // Run first instance to completion
      Id instanceId1 = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'SharedKey',
        null
      );
      WorkflowEngine.runStep(instanceId1, null);
      WorkflowEngine.runStep(instanceId1, null);

      Workflow_Instance__c inst1 = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId1
      ];
      System.assertEquals('Completed', inst1.Status__c);

      // Start a second instance with the same correlation key - should create a
      // new instance because the first one is terminal and the window is disabled.
      Test.startTest();
      Id instanceId2 = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'SharedKey',
        null
      );
      Test.stopTest();

      System.assertNotEquals(
        instanceId1,
        instanceId2,
        'With the dedup window disabled, a terminal key starts a new instance'
      );
      Workflow_Instance__c inst2 = [
        SELECT Status__c, Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId2
      ];
      System.assertEquals('SharedKey', inst2.Correlation_Key__c);
    }
  }

  @IsTest
  static void testDirectCalloutStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.setMock(
        HttpCalloutMock.class,
        new WorkflowEngineMocksATest.MockCalloutResponse()
      );

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.CalloutWorkflow',
        'CalloutKey',
        null
      );
      Test.stopTest();

      Workflow_Instance__c inst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', inst.Status__c);
      System.assertEquals(
        '{"status":"success"}',
        (String) JSON.deserialize(
          WorkflowPayloadOffload.resolvePayload(inst.Output__c),
          String.class
        )
      );
    }
  }

  @IsTest
  static void testWatchdogLifecycle() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // TimeoutStep has timeout of 30 seconds
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.TimeoutWorkflow',
        'TimeoutWatchdogKey',
        null
      );

      // Verify watchdog was scheduled in DB
      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Timeout_At__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineTest.TimeoutStep'
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      System.assertEquals(1, stepExecs.size());
      System.assertNotEquals(
        null,
        stepExecs[0].Timeout_At__c,
        'Watchdog timeout should be set on step execution'
      );

      // Verify watchdog was scheduled in CronTriggers
      String cleanStepName = 'WorkflowEngineTest_TimeoutStep';
      String jobName = 'Timeout_' + instanceId + '_' + cleanStepName;
      List<CronTrigger> triggers = [
        SELECT Id, State
        FROM CronTrigger
        WHERE CronJobDetail.Name = :jobName
      ];
      System.assertEquals(
        1,
        triggers.size(),
        'A dynamic CronTrigger should be scheduled'
      );

      // Execute the step. It should clear the timeout in DB.
      Test.startTest();
      WorkflowEngine.runStep(instanceId, null);
      Test.stopTest();

      stepExecs = [
        SELECT Timeout_At__c, Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineTest.TimeoutStep'
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      System.assertEquals(1, stepExecs.size());
      System.assertEquals('Completed', stepExecs[0].Status__c);
      System.assertEquals(
        null,
        stepExecs[0].Timeout_At__c,
        'Watchdog timeout should be cleared upon successful step completion'
      );

      // Verify watchdog CronTrigger was canceled/aborted
      triggers = [
        SELECT Id
        FROM CronTrigger
        WHERE CronJobDetail.Name = :jobName
      ];
      System.assertEquals(
        0,
        triggers.size(),
        'Watchdog CronTrigger should be aborted upon successful step completion'
      );
    }
  }

  @IsTest
  static void testLargeParallelOutputJoin() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.LargeParallelWorkflow',
        'LargeParallelKey',
        null
      );

      // Run SplitStep
      WorkflowEngine.runStep(instanceId, null);

      // Run LargeOutputStep and ParallelStep2
      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksATest.LargeOutputStep'
      );
      WorkflowEngine.runStep(
        instanceId,
        'WorkflowEngineMocksATest.ParallelStep2'
      );

      // Run JoinStep manually
      try {
        new WorkflowOrchestrator(instanceId).execute(null);
      } catch (Exception ex) {
        throw ex;
      }

      Workflow_Instance__c instAfter = [
        SELECT Status__c, Current_Step__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];

      System.assertEquals('Completed', instAfter.Status__c);
    }
  }

  @IsTest
  static void testRetryWorkflowNullCurrentStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Construct and insert the instance manually to avoid enqueuing
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Failed',
        Current_Step__c = null,
        Correlation_Key__c = 'NullStepKey'
      );
      insert inst;
      Id instanceId = inst.Id;

      // Run retry. It should not throw NullPointerException
      Test.startTest();
      WorkflowEngine.retryWorkflow(instanceId);
      Test.stopTest();

      inst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Running', inst.Status__c);
      System.assertEquals(
        'WorkflowEngineTest.HappyStep1',
        inst.Current_Step__c
      );
    }
  }

  @IsTest
  static void testActiveCorrelationKeyUniqueness() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // Active-only dedup scope (preserves the legacy uniqueness window)
      WorkflowEngine.dedupWindowMinutes = 0;

      // Start a first instance - should succeed
      Id instanceId1 = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'UniqueActiveKey',
        null
      );

      // Get-or-start: a second start with the same active key returns the
      // existing instance Id instead of throwing or creating a duplicate.
      Id deduped = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'UniqueActiveKey',
        null
      );
      System.assertEquals(
        instanceId1,
        deduped,
        'Active duplicate must resolve to the existing instance, not throw'
      );
      Integer activeCount = [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c = 'UniqueActiveKey'
      ];
      System.assertEquals(
        1,
        activeCount,
        'Only one instance should exist while the key is active'
      );

      // Run first instance to completion (terminal)
      WorkflowEngine.runStep(instanceId1, null);
      WorkflowEngine.runStep(instanceId1, null);

      // With the window disabled (active-only), a new instance is created
      // because the first one is terminal.
      Id instanceId2 = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'UniqueActiveKey',
        null
      );
      System.assertNotEquals(null, instanceId2);
      System.assertNotEquals(
        instanceId1,
        instanceId2,
        'With window disabled, a terminal key starts a fresh instance'
      );
    }
  }

  @IsTest
  static void testSignalByIdShapedKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Start an instance with correlation key 'UniqueSignalKey'
      Id instanceId1 = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.SignaledWorkflow',
        'UniqueSignalKey',
        null
      );

      // Start a second instance whose correlation key is the string representation of instanceId1's ID!
      String idKey = String.valueOf(instanceId1);
      Id instanceId2 = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.SignaledWorkflow',
        idKey,
        null
      );

      // Run the initial step to transition both instances to Suspended
      WorkflowEngine.runStep(instanceId1, null);
      WorkflowEngine.runStep(instanceId2, null);

      // Send a signal using keyOrId = instanceId1. Since keyOrId casts to ID, it should hit instanceId1, NOT instanceId2 (even though instanceId2's correlation key equals instanceId1's ID string!)
      WorkflowEngine.signal(idKey, 'PaymentReceived', '100');

      // Verify instanceId1 received the signal and changed to Running (resumed)
      Workflow_Instance__c inst1 = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId1
      ];
      System.assertEquals(
        'Running',
        inst1.Status__c,
        'Instance 1 should have been resumed'
      );

      // Verify instanceId2 did NOT receive the signal (still Suspended)
      Workflow_Instance__c inst2 = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId2
      ];
      System.assertEquals(
        'Suspended',
        inst2.Status__c,
        'Instance 2 should not have been resumed'
      );
    }
  }

  @IsTest
  static void testContinueAsNewSuccessorWatchdog() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Start workflow that continues as new to same workflow definition
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.TimeoutContinueWorkflow',
        'StarterKey',
        null
      );

      // Run the step, which continues as new
      WorkflowEngine.runStep(instanceId, null);

      // Find the successor run
      Workflow_Instance__c successor = [
        SELECT Id, Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :instanceId
        LIMIT 1
      ];
      System.assertEquals(
        'WorkflowEngineMocksBTest.TimeoutContinueStep',
        successor.Current_Step__c
      );

      // Verify watchdog job was scheduled for the successor instance's initial step
      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Timeout_At__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :successor.Id
          AND Step_Name__c = :successor.Current_Step__c
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      System.assertEquals(1, stepExecs.size());
      System.assertNotEquals(
        null,
        stepExecs[0].Timeout_At__c,
        'Watchdog timeout should be set on successor initial step'
      );
    }
  }

  @IsTest
  static void testContentVersionVisibility() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'PayloadVisibilityKey',
        null
      );

      // Save a large payload which offloads to ContentVersion
      String largeStr = 'x'.repeat(110000);
      String marker = WorkflowPayloadOffload.savePayloadIfNeeded(
        instanceId,
        largeStr,
        'TestPayload'
      );
      System.assert(marker.contains('$attachmentId'));

      // Extract the docId
      Map<String, Object> markerMap = (Map<String, Object>) JSON.deserializeUntyped(
        marker
      );
      Id docId = (Id) markerMap.get('$attachmentId');

      // Query ContentDocumentLink to verify Visibility is set to 'InternalUsers'
      ContentDocumentLink link = [
        SELECT Visibility
        FROM ContentDocumentLink
        WHERE ContentDocumentId = :docId AND LinkedEntityId = :instanceId
        LIMIT 1
      ];
      // Verify visibility is either InternalUsers (if Communities enabled) or AllUsers (if disabled)
      System.assert(
        link.Visibility == 'InternalUsers' || link.Visibility == 'AllUsers',
        'Invalid visibility: ' + link.Visibility
      );
    }
  }

  @IsTest
  static void testWatchdogRaceAndStatuses() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'RaceKey',
        null
      );

      // Let's create a completed step execution
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = instanceId,
        Step_Name__c = 'WorkflowEngineTest.HappyStep1',
        Status__c = 'Completed'
      );
      insert stepExec;

      // Transition instance status to Completed
      Workflow_Instance__c inst = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      inst.Status__c = 'Completed';
      update inst;

      // If watchdog runs on a completed instance, it should exit without error or changes
      stepExec.Timeout_At__c = DateTime.now().addSeconds(-10);
      update as system stepExec;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Check that step remains Completed
      Workflow_Step_Execution__c checkStep = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExec.Id
      ];
      System.assertEquals('Completed', checkStep.Status__c);
    }
  }

  @IsTest
  static void testBulkStart() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<WorkflowEngine.StartRequest> requests = new List<WorkflowEngine.StartRequest>();
      for (Integer i = 0; i < 5; i++) {
        requests.add(
          new WorkflowEngine.StartRequest(
            'WorkflowEngineTest.HappyWorkflow',
            'BulkKey_' + i,
            'StartVal_' + i
          )
        );
      }

      Test.startTest();
      List<Id> instanceIds = WorkflowEngine.start(requests);
      Test.stopTest(); // Runs HappyStep1 for all of them synchronously

      System.assertEquals(5, instanceIds.size());
      List<Workflow_Instance__c> instances = [
        SELECT Id, Status__c, Correlation_Key__c, Input__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id IN :instanceIds
      ];
      System.assertEquals(5, instances.size());
      for (Workflow_Instance__c inst : instances) {
        System.assertEquals('Running', inst.Status__c);
        System.assert(inst.Correlation_Key__c.startsWith('BulkKey_'));
        System.assertEquals(
          'WorkflowEngineTest.HappyStep2',
          inst.Current_Step__c
        );
      }
    }
  }

  @IsTest
  static void testBulkResume() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 1. Create suspended workflow instances
      List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 5; i++) {
        instances.add(
          new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.SuspendingWorkflow',
            Status__c = 'Suspended',
            Correlation_Key__c = 'BulkResumeKey_' + i,
            Current_Step__c = 'WorkflowEngineTest.SuspendingStep'
          )
        );
      }
      insert instances;

      // Insert active step executions for them
      List<Workflow_Step_Execution__c> stepExecs = new List<Workflow_Step_Execution__c>();
      for (Workflow_Instance__c inst : instances) {
        stepExecs.add(
          new Workflow_Step_Execution__c(
            Workflow_Instance__c = inst.Id,
            Step_Name__c = 'WorkflowEngineTest.SuspendingStep',
            Status__c = 'Pending',
            Retry_Count__c = 0
          )
        );
      }
      insert stepExecs;

      // 2. Publish RESUME events
      List<Workflow_Event__e> events = new List<Workflow_Event__e>();
      for (Integer i = 0; i < 5; i++) {
        events.add(
          new Workflow_Event__e(
            Workflow_Instance_Id__c = 'BulkResumeKey_' + i,
            Event_Type__c = 'RESUME',
            Payload__c = 'ResumeData_' + i
          )
        );
      }

      Test.startTest();
      EventBus.publish(events);
      Test.getEventBus().deliver(); // Executes WorkflowEventTrigger which resumes all in bulk
      Test.stopTest();

      List<Workflow_Instance__c> updatedInstances = [
        SELECT Id, Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id IN :instances
      ];
      for (Workflow_Instance__c inst : updatedInstances) {
        System.assertEquals('Running', inst.Status__c);
        System.assertEquals(
          'WorkflowEngineTest.AfterSuspendStep',
          inst.Current_Step__c
        );
      }
    }
  }

  @IsTest
  static void testBulkSignal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 1. Start workflows that block on signals
      List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 5; i++) {
        instances.add(
          new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineMocksBTest.SignaledWorkflow',
            Status__c = 'Suspended',
            Correlation_Key__c = 'BulkSignalKey_' + i,
            Current_Step__c = 'WorkflowEngineMocksATest.SignaledStep'
          )
        );
      }
      insert instances;

      // 2. Send SIGNAL platform events
      List<Workflow_Event__e> events = new List<Workflow_Event__e>();
      for (Integer i = 0; i < 5; i++) {
        events.add(
          new Workflow_Event__e(
            Workflow_Instance_Id__c = 'BulkSignalKey_' + i,
            Event_Type__c = 'SIGNAL:PaymentReceived',
            Payload__c = '{"amount": ' + (100 + i) + '}'
          )
        );
      }

      Test.startTest();
      EventBus.publish(events);
      Test.getEventBus().deliver(); // Trigger runs, inserts Workflow_Signal__c in bulk, sets to Running
      Test.stopTest();

      List<Workflow_Signal__c> signals = [
        SELECT Id, Signal_Name__c, Payload__c, Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c IN :instances
      ];
      System.assertEquals(5, signals.size());
      for (Workflow_Signal__c sig : signals) {
        System.assertEquals('PaymentReceived', sig.Signal_Name__c);
        System.assertEquals('Consumed', sig.Status__c);
      }
    }
  }

  @IsTest
  static void testLifecycleEventOnCompletion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'LifecycleHappyKey',
        'StartVal'
      );
      Test.stopTest(); // Runs HappyStep1 synchronously

      // Execute the second/terminal step synchronously
      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Instance__c inst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Completed', inst.Status__c);

      // Exactly one lifecycle event, describing the successful terminal outcome.
      System.assertEquals(
        1,
        WorkflowLifecyclePublisher.publishedEvents.size(),
        'A completed workflow publishes exactly one lifecycle event'
      );
      Workflow_Lifecycle__e evt = WorkflowLifecyclePublisher.publishedEvents[0];
      System.assertEquals(instanceId, evt.Workflow_Instance_Id__c);
      System.assertEquals('Completed', evt.Status__c);
      System.assertEquals(true, evt.Is_Success__c);
      System.assertEquals('LifecycleHappyKey', evt.Correlation_Key__c);
      System.assertEquals(
        'LifecycleHappyKey',
        evt.Root_Correlation_Key__c,
        'Root key equals the correlation key for a non-continue-as-new workflow'
      );
      System.assertEquals(
        'WorkflowEngineTest.HappyWorkflow',
        evt.Workflow_Name__c
      );
      System.assertNotEquals(
        null,
        evt.Terminal_At__c,
        'The event carries a terminal transition timestamp for retry-aware dedupe'
      );
    }
  }

  @IsTest
  static void testLifecycleEventOnFailure() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.CustomRetryWorkflow',
        'LifecycleRetryKey',
        null
      );
      Test.stopTest(); // First attempt -> Retrying

      WorkflowEngine.runStep(instanceId); // Second attempt -> Retrying
      WorkflowEngine.runStep(instanceId); // Third attempt -> exceeds max -> Failed

      Workflow_Instance__c inst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Failed', inst.Status__c);

      System.assertEquals(
        1,
        WorkflowLifecyclePublisher.publishedEvents.size(),
        'A failed workflow publishes exactly one lifecycle event'
      );
      Workflow_Lifecycle__e evt = WorkflowLifecyclePublisher.publishedEvents[0];
      System.assertEquals('Failed', evt.Status__c);
      System.assertEquals(false, evt.Is_Success__c);
      System.assertNotEquals(
        null,
        evt.Failure_Detail__c,
        'Failure detail is sourced from Error_Message__c'
      );
      System.assert(
        evt.Failure_Detail__c.contains('Max retries exceeded'),
        'Failure detail carries the engine error message'
      );
    }
  }

  @IsTest
  static void testLifecycleExactlyOnceForContinueAsNewChain() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.DaemonWorkflow',
        'LifecycleDaemonKey',
        0
      );
      // Run 1: counter 0 -> ContinuedAsNew (no event)
      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Instance__c run2 = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :instanceId
      ];
      // Run 2: counter 1 -> ContinuedAsNew (no event)
      new WorkflowOrchestrator(run2.Id).execute(null);

      Workflow_Instance__c run3 = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :run2.Id
      ];
      // Run 3: counter 2 -> Completed (exactly one event for the whole chain)
      new WorkflowOrchestrator(run3.Id).execute(null);

      System.assertEquals(
        'Completed',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :run3.Id]
        .Status__c
      );

      System.assertEquals(
        1,
        WorkflowLifecyclePublisher.publishedEvents.size(),
        'A ContinuedAsNew chain emits exactly one terminal event — on the final successor only'
      );
      Workflow_Lifecycle__e evt = WorkflowLifecyclePublisher.publishedEvents[0];
      System.assertEquals(
        run3.Id,
        evt.Workflow_Instance_Id__c,
        'The single event references the final successor instance'
      );
      System.assertEquals('Completed', evt.Status__c);
      System.assertEquals(true, evt.Is_Success__c);
      // The successor's own key was rewritten (DaemonKey_run3), but the chain root
      // key stays the original start key so the launcher can correlate the event.
      System.assertEquals(
        'LifecycleDaemonKey_run3',
        evt.Correlation_Key__c,
        'The event carries the final successor key'
      );
      System.assertEquals(
        'LifecycleDaemonKey',
        evt.Root_Correlation_Key__c,
        'The event carries the stable chain root key from the original start request'
      );
    }
  }

  @IsTest
  static void testLifecycleEventOnCancellation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.SignaledWorkflow',
        'LifecycleCancelKey',
        null
      );
      Test.stopTest(); // Runs SignaledStep which suspends awaiting a signal

      WorkflowEngine.cancel(instanceId); // No compensations -> Cancelled

      Workflow_Instance__c inst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Cancelled', inst.Status__c);

      System.assertEquals(
        1,
        WorkflowLifecyclePublisher.publishedEvents.size(),
        'A cancelled workflow publishes exactly one lifecycle event'
      );
      Workflow_Lifecycle__e evt = WorkflowLifecyclePublisher.publishedEvents[0];
      System.assertEquals('Cancelled', evt.Status__c);
      System.assertEquals(false, evt.Is_Success__c);
      System.assertEquals(
        'WorkflowEngineMocksBTest.SignaledWorkflow',
        evt.Workflow_Name__c,
        'Cancellation event carries the workflow name (query was widened for it)'
      );
    }
  }

  @IsTest
  static void testLifecycleToggleDisablesEmission() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.publishLifecycleEvents = false;

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'LifecycleToggleKey',
        'StartVal'
      );
      Test.stopTest();
      new WorkflowOrchestrator(instanceId).execute(null);

      System.assertEquals(
        'Completed',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
        .Status__c,
        'Disabling the toggle does not affect the terminal transition itself'
      );
      System.assertEquals(
        0,
        WorkflowLifecyclePublisher.publishedEvents.size(),
        'No lifecycle event is published when the operator toggle is off'
      );
    }
  }

  @IsTest
  static void testLifecyclePublishFailureDoesNotBreakTransition() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowLifecyclePublisher.throwTestException = true;

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'LifecycleIsolationKey',
        'StartVal'
      );
      Test.stopTest();
      // Terminal transition runs through the (failing) publish site and must survive.
      new WorkflowOrchestrator(instanceId).execute(null);

      System.assertEquals(
        'Completed',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
        .Status__c,
        'A publish failure is swallowed and never rolls back the terminal write'
      );
      System.assertEquals(
        0,
        WorkflowLifecyclePublisher.publishedEvents.size(),
        'The simulated publish failure recorded no delivered event'
      );
    }
  }

  @IsTest
  static void testLifecycleEventOnCompensationDrain() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Regression: the compensation drain re-queries the instance, and the
      // terminal publish must carry Correlation_Key__c (was dropped from that
      // re-query, which would have thrown an unqueried-field exception and rolled
      // back the Compensated write).
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Correlation_Key__c = 'LifecycleCompKey',
        Status__c = 'Compensating',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
        ),
        Input__c = '{"test": true}'
      );
      insert inst;

      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep',
        Status__c = 'Completed',
        Input__c = '{"stepInput": 1}',
        Output__c = '{"stepOutput": 2}'
      );

      Test.startTest();
      WorkflowEngine.runStep(inst.Id, null); // Compensate step
      WorkflowEngine.runStep(inst.Id, null); // Stack drained -> Compensated + publish
      Test.stopTest();

      System.assertEquals(
        'Compensated',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id]
        .Status__c,
        'Compensation drain reaches the terminal state (no publish-induced rollback)'
      );
      System.assertEquals(
        1,
        WorkflowLifecyclePublisher.publishedEvents.size(),
        'Compensation drain publishes exactly one lifecycle event'
      );
      Workflow_Lifecycle__e evt = WorkflowLifecyclePublisher.publishedEvents[0];
      System.assertEquals('Compensated', evt.Status__c);
      System.assertEquals(false, evt.Is_Success__c);
      System.assertEquals(
        'LifecycleCompKey',
        evt.Correlation_Key__c,
        'The event carries the correlation key from the widened re-query'
      );
    }
  }

  @IsTest
  static void testLifecycleEventsOnParentChildCancelTree() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // The cancel tree publishes one bulk batch after every node is cancelled, so
      // the best-effort publish never starves a later child cancellation of DML.
      WorkflowEngine.disableQueueableInTest = true;
      Id parentId = WorkflowEngine.start(
        'WorkflowEngineMocksATest.ParentWorkflow',
        'CancelTreeParent',
        null
      );
      WorkflowEngine.runStep(parentId, null); // parent starts child, suspends

      Workflow_Instance__c childInst = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :parentId
        LIMIT 1
      ];

      Test.startTest();
      WorkflowEngine.cancel(parentId); // cancels parent + child, then bulk-publishes
      Test.stopTest();

      System.assertEquals(
        'Cancelled',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :parentId]
        .Status__c
      );
      System.assertEquals(
        'Cancelled',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :childInst.Id]
        .Status__c
      );

      // One lifecycle event per terminally-cancelled node, emitted as a single bulk
      // batch after the whole tree was cancelled.
      Set<Id> eventInstanceIds = new Set<Id>();
      for (
        Workflow_Lifecycle__e evt : WorkflowLifecyclePublisher.publishedEvents
      ) {
        System.assertEquals('Cancelled', evt.Status__c);
        System.assertEquals(false, evt.Is_Success__c);
        eventInstanceIds.add((Id) evt.Workflow_Instance_Id__c);
      }
      System.assertEquals(
        new Set<Id>{ parentId, childInst.Id },
        eventInstanceIds,
        'Both the parent and child cancellations emit exactly one lifecycle event'
      );
    }
  }
}
