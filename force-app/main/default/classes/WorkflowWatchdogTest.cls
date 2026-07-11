@IsTest
public class WorkflowWatchdogTest {
  @IsTest
  static void testWatchdogScheduleAndBootstrap() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;

      Test.startTest();
      System.schedule('TestWatchdogJob', '0 0 0 * * ?', new WorkflowWatchdog());
      Test.stopTest();

      // Verify watchdog instance was started
      List<Workflow_Instance__c> watchdog = [
        SELECT Id, Workflow_Name__c, Status__c
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c = 'SystemWatchdog'
      ];
      System.assertEquals(
        1,
        watchdog.size(),
        'Watchdog workflow should have been started'
      );
      System.assertEquals('WatchdogWorkflow', watchdog[0].Workflow_Name__c);
    }
  }

  @IsTest
  static void testWatchdogWorkflowExecution() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Enable force bootstrap and disable automatic queueable triggers in tests
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // Start a dummy sleeping instance to be resumed by heartbeat
      Workflow_Instance__c dummyInst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Sleep_Until__c = DateTime.now().addSeconds(-10)
      );
      insert dummyInst;

      WorkflowEngine.disableQueueableInTest = false;
      Test.startTest();
      // Start the WatchdogWorkflow (Pending status initially)
      Id watchdogId = WorkflowEngine.start(
        'WatchdogWorkflow',
        'SystemWatchdog',
        null
      );
      WorkflowEngine.disableQueueableInTest = true;
      Test.stopTest(); // Runs heartbeat step asynchronously, transitions to sleep step (Pending)

      // Verify dummy instance is no longer suspended (resumed by processWatchdogHeartbeat during stopTest)
      Workflow_Instance__c updatedDummy = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :dummyInst.Id
      ];
      System.assertEquals(
        'Running',
        updatedDummy.Status__c,
        'Dummy should have been resumed'
      );

      // 2. Execute sleep step manually (transitions to Suspended)
      new WorkflowOrchestrator(watchdogId).execute(null);

      // Verify that the watchdog has slept
      Workflow_Instance__c originalWatchdog = [
        SELECT Status__c, Current_Step__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :watchdogId
      ];
      System.assertEquals(
        'Suspended',
        originalWatchdog.Status__c,
        'Original watchdog should be suspended on sleep step'
      );
      System.assertEquals(
        'WatchdogWorkflow.WatchdogSleepStep',
        originalWatchdog.Current_Step__c
      );

      // Mock watchdog sleep time is past due
      originalWatchdog.Sleep_Until__c = DateTime.now().addSeconds(-10);
      update as system originalWatchdog;

      // Reset bootstrapped flag to allow bootstrap to execute again in test
      WorkflowWatchdog.bootstrapped = false;

      // Call bootstrap to resume it
      WorkflowWatchdog.bootstrap();

      // Confirm it is set to Running
      Workflow_Instance__c resumedWatchdog = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :watchdogId
      ];
      System.assertEquals(
        'Running',
        resumedWatchdog.Status__c,
        'Watchdog should be Running after bootstrap resume'
      );

      // 3. Run the orchestrator manually to execute the sleep resume step and transition to continue step
      new WorkflowOrchestrator(watchdogId).execute(null);

      // 4. Run the orchestrator manually to execute the continue step
      new WorkflowOrchestrator(watchdogId).execute(null);

      // Verify watchdog is now continued-as-new
      Workflow_Instance__c continuedWatchdog = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :watchdogId
      ];
      System.assertEquals(
        'ContinuedAsNew',
        continuedWatchdog.Status__c,
        'Watchdog should be continued-as-new'
      );

      List<Workflow_Instance__c> successor = [
        SELECT Id, Status__c, Previous_Instance__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :watchdogId
      ];
      System.assertEquals(
        1,
        successor.size(),
        'Watchdog successor should have been started'
      );
    }
  }

  @IsTest
  static void testQueueableJobsCoverage() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running'
      );
      insert inst;

      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.HappyStep1',
        Status__c = 'Running'
      );
      insert step;

      Test.startTest();
      // Test QueueableSleepJob
      System.enqueueJob(new WorkflowSleepJob.QueueableSleepJob(inst.Id));

      // Test QueueableRetryJob
      System.enqueueJob(
        new WorkflowRetryJob.QueueableRetryJob(
          inst.Id,
          'WorkflowEngineTest.HappyStep1'
        )
      );

      // Test QueueableTimeoutJob
      System.enqueueJob(
        new WorkflowTimeoutJob.QueueableTimeoutJob(
          inst.Id,
          'WorkflowEngineTest.HappyStep1'
        )
      );
      Test.stopTest();

      // After the sleep/retry/timeout jobs drain, the instance must still be a
      // live, queryable record carrying a status (the jobs process it, never
      // orphan or delete it).
      Workflow_Instance__c processed = [
        SELECT Id, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        inst.Id,
        processed.Id,
        'Instance should still exist after the sleep/retry/timeout jobs run'
      );
      System.assertNotEquals(
        null,
        processed.Status__c,
        'Instance should retain a status after async job processing'
      );
    }
  }

  @IsTest
  static void testWatchdogBootstrapAndConfig() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Save original config values
      Boolean originalUseDynamic = WorkflowEngine.useDynamicScheduling;
      Integer originalDelay = WorkflowEngine.watchdogDelayMinutes;

      try {
        WorkflowEngine.useDynamicScheduling = false;
        WorkflowEngine.watchdogDelayMinutes = 5;

        WorkflowWatchdog.forceBootstrapInTest = true;

        Test.startTest();
        // Test bootstrap logic
        WorkflowWatchdog.bootstrap();
        Test.stopTest();

        // Verify constructors and properties
        WorkflowWatchdog w1 = new WorkflowWatchdog();
        System.assertEquals(5, w1.delayMinutes);

        WorkflowWatchdog w2 = new WorkflowWatchdog(12); // out of bounds 1-10, should default to 10
        System.assertEquals(10, w2.delayMinutes);

        WorkflowWatchdog w3 = new WorkflowWatchdog(-5); // out of bounds, should default to 10
        System.assertEquals(10, w3.delayMinutes);

        WorkflowWatchdog w4 = new WorkflowWatchdog(3); // in bounds
        System.assertEquals(3, w4.delayMinutes);
      } finally {
        // Restore config values
        WorkflowEngine.useDynamicScheduling = originalUseDynamic;
        WorkflowEngine.watchdogDelayMinutes = originalDelay;
      }
    }
  }

  @IsTest
  static void testWatchdogBootstrapWithSuccessor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowWatchdog.bootstrapped = false;

      // Create a mock successor watchdog instance that is suspended
      Workflow_Instance__c successorWatchdog = new Workflow_Instance__c(
        Workflow_Name__c = 'WatchdogWorkflow',
        Correlation_Key__c = 'SystemWatchdog_run2',
        Status__c = 'Suspended',
        Sleep_Until__c = DateTime.now().addMinutes(10)
      );
      insert as system successorWatchdog;

      Test.startTest();
      // Trigger bootstrap, which should see the suspended successor 'SystemWatchdog_run2'
      // and NOT spawn a new watchdog instance
      WorkflowWatchdog.bootstrap();
      Test.stopTest();

      // Verify no new watchdog with key 'SystemWatchdog' was created
      List<Workflow_Instance__c> newWatchdogs = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c = 'SystemWatchdog'
      ];
      System.assertEquals(
        0,
        newWatchdogs.size(),
        'Should not spawn a new watchdog if a successor is active'
      );
    }
  }

  @IsTest
  static void testTimedSuspendBulkSignalWinsDisarmsTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Verifies the bulk signal(List<SignalRequest>) path also clears Sleep_Until__c
      // when a signal wins the race against an armed timed-wait timer.
      WorkflowEngine.disableQueueableInTest = true;

      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineTest.TimedSuspendWorkflow',
        'BulkSignalKey',
        null
      );
      new WorkflowOrchestrator(instanceId).execute(null);

      // Timer should be armed
      Workflow_Instance__c inst = [
        SELECT Status__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Suspended', inst.Status__c);
      System.assertNotEquals(
        null,
        inst.Sleep_Until__c,
        'Timer should be armed before bulk signal'
      );

      // Deliver winning signal via bulk path
      WorkflowEngine.signal(
        new List<WorkflowEngine.SignalRequest>{
          new WorkflowEngine.SignalRequest('BulkSignalKey', 'Resume', '{}')
        }
      );

      // Timer must be disarmed by the bulk signal path
      inst = [
        SELECT Status__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Running',
        inst.Status__c,
        'Should be Running after bulk signal'
      );
      System.assertEquals(
        null,
        inst.Sleep_Until__c,
        'Bulk signal win must disarm the timer (Sleep_Until__c must be null)'
      );

      // Watchdog must not fire a timeout-route after disarm
      WorkflowEngine.processWatchdogHeartbeat();
      List<Workflow_Step_Execution__c> fallbackExecs = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'WorkflowEngineTest.TimeoutFallbackStep'
      ];
      System.assertEquals(
        0,
        fallbackExecs.size(),
        'Watchdog must not create fallback exec after bulk signal wins'
      );
    }
  }

  // Fluent builder replacing the former 4-/5-parameter createMockStallConfig(...)
  // overloads. Produces byte-identical Workflow_Alert_Config__mdt values;
  // publishEvent defaults to false (matching the old 4-arg overload) unless
  // set via publish(...).
  private class StallCfg {
    private String devName;
    private String recipients;
    private Boolean enabled;
    private Integer stallThresholdMinutes;
    private Boolean publishEvent = false;

    private StallCfg(String devName, String recipients, Boolean enabled) {
      this.devName = devName;
      this.recipients = recipients;
      this.enabled = enabled;
    }

    private StallCfg threshold(Integer value) {
      this.stallThresholdMinutes = value;
      return this;
    }

    private StallCfg publish(Boolean value) {
      this.publishEvent = value;
      return this;
    }

    private Workflow_Alert_Config__mdt build() {
      Map<String, Object> fields = new Map<String, Object>{
        'DeveloperName' => devName,
        'Email_Recipients__c' => recipients,
        'Enable_Alerts__c' => enabled,
        'Stall_Threshold_Minutes__c' => stallThresholdMinutes,
        'Publish_Alert_Event__c' => publishEvent
      };
      return (Workflow_Alert_Config__mdt) JSON.deserialize(
        JSON.serialize(fields),
        Workflow_Alert_Config__mdt.class
      );
    }
  }

  // Compact convenience for the common enabled, non-publishing stall config so
  // the repeated per-test setup stays terse (and free of duplicated builder
  // chains). Delegates to the StallCfg builder; identical values.
  private static Workflow_Alert_Config__mdt stallConfig(
    String devName,
    String recipients,
    Integer threshold
  ) {
    return new StallCfg(devName, recipients, true).threshold(threshold).build();
  }

  @IsTest
  static void testWatchdogStallAlertBasicAndDedup() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Mock Config with Stall Threshold = 10 minutes
      WorkflowAlertManager.mockConfigs.put(
        'WorkflowEngineTest_HappyWorkflow',
        stallConfig('WorkflowEngineTest_HappyWorkflow', 'ops@test.com', 10)
      );

      // 2. Create a stalled instance
      Workflow_Instance__c stalledInst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running'
      );
      insert stalledInst;

      // Backdate the instance CreatedDate to 15 minutes ago
      Datetime fifteenMinsAgo = DateTime.now().addMinutes(-15);
      Test.setCreatedDate(stalledInst.Id, fifteenMinsAgo);

      // Create a step execution backdated to 15 minutes ago as well
      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = stalledInst.Id,
        Step_Name__c = 'Step1',
        Status__c = 'Completed'
      );
      insert step;
      Test.setCreatedDate(step.Id, fifteenMinsAgo);

      // Reset alert counter
      WorkflowAlertManager.sentEmailsCount = 0;

      // Run watchdog heartbeat -> should detect stall and send alert
      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      System.assertEquals(
        1,
        WorkflowAlertManager.sentEmailsCount,
        'Stall alert should be sent'
      );

      // Verify dedup marker (Workflow_Log__c) exists
      List<Workflow_Log__c> logs = [
        SELECT Id, Log_Type__c, Message__c
        FROM Workflow_Log__c
        WHERE Workflow_Instance__c = :stalledInst.Id
      ];
      System.assertEquals(1, logs.size(), 'Dedup log should be written');
      System.assertEquals('WorkflowStallAlert', logs[0].Log_Type__c);

      // Run watchdog heartbeat again -> should NOT send duplicate alert
      WorkflowAlertManager.sentEmailsCount = 0;
      WorkflowEngine.processWatchdogHeartbeat();
      System.assertEquals(
        0,
        WorkflowAlertManager.sentEmailsCount,
        'Should not send duplicate alert'
      );
    }
  }

  @IsTest
  static void testWatchdogStallAlertResumeAndStallAgain() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // Mock Config
      WorkflowAlertManager.mockConfigs.put(
        'WorkflowEngineTest_HappyWorkflow',
        stallConfig('WorkflowEngineTest_HappyWorkflow', 'ops@test.com', 10)
      );

      // Create stalled instance
      Workflow_Instance__c stalledInst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running'
      );
      insert stalledInst;

      Datetime fifteenMinsAgo = DateTime.now().addMinutes(-15);
      Test.setCreatedDate(stalledInst.Id, fifteenMinsAgo);

      Workflow_Step_Execution__c step1 = new Workflow_Step_Execution__c(
        Workflow_Instance__c = stalledInst.Id,
        Step_Name__c = 'Step1',
        Status__c = 'Completed'
      );
      insert step1;
      Test.setCreatedDate(step1.Id, fifteenMinsAgo);

      WorkflowAlertManager.sentEmailsCount = 0;
      WorkflowEngine.processWatchdogHeartbeat();
      System.assertEquals(
        1,
        WorkflowAlertManager.sentEmailsCount,
        'First stall alert sent'
      );

      // Retrieve and backdate the stall alert log so it is older than step2's timestamp
      List<Workflow_Log__c> logs = [
        SELECT Id, CreatedDate
        FROM Workflow_Log__c
        WHERE
          Workflow_Instance__c = :stalledInst.Id
          AND Log_Type__c = 'WorkflowStallAlert'
      ];
      System.assertEquals(1, logs.size());
      Datetime fourteenMinsAgo = DateTime.now().addMinutes(-14);
      Test.setCreatedDate(logs[0].Id, fourteenMinsAgo);

      // Simulate forward progress by inserting a new step execution created 5 minutes ago (newer than the alert)
      Datetime fiveMinsAgo = DateTime.now().addMinutes(-5);
      Workflow_Step_Execution__c step2 = new Workflow_Step_Execution__c(
        Workflow_Instance__c = stalledInst.Id,
        Step_Name__c = 'Step2',
        Status__c = 'Running'
      );
      insert step2;
      Test.setCreatedDate(step2.Id, fiveMinsAgo);

      // Run watchdog -> should NOT alert because the latest progress is only 5 minutes old (threshold is 10)
      WorkflowAlertManager.sentEmailsCount = 0;
      WorkflowEngine.processWatchdogHeartbeat();
      System.assertEquals(
        0,
        WorkflowAlertManager.sentEmailsCount,
        'Should not alert before threshold reached'
      );

      // Now backdate the new step execution to 12 minutes ago (so it is now stalled again)
      Datetime twelveMinsAgo = DateTime.now().addMinutes(-12);
      Test.setCreatedDate(step2.Id, twelveMinsAgo);

      // Run watchdog -> should alert again because it stalled again
      WorkflowEngine.processWatchdogHeartbeat();
      System.assertEquals(
        1,
        WorkflowAlertManager.sentEmailsCount,
        'Second stall alert should be sent'
      );
    }
  }

  @IsTest
  static void testWatchdogStallAlertLegitimateSleepExclusion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // Mock Config
      WorkflowAlertManager.mockConfigs.put(
        'WorkflowEngineTest_HappyWorkflow',
        stallConfig('WorkflowEngineTest_HappyWorkflow', 'ops@test.com', 10)
      );

      // Create a suspended instance that is legitimately sleeping until 10 minutes in the future
      Workflow_Instance__c sleepingInst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Sleep_Until__c = DateTime.now().addMinutes(10)
      );
      insert sleepingInst;

      // Backdate CreatedDate to 15 minutes ago
      Datetime fifteenMinsAgo = DateTime.now().addMinutes(-15);
      Test.setCreatedDate(sleepingInst.Id, fifteenMinsAgo);

      WorkflowAlertManager.sentEmailsCount = 0;
      WorkflowEngine.processWatchdogHeartbeat();
      System.assertEquals(
        0,
        WorkflowAlertManager.sentEmailsCount,
        'Legitimate sleeper should not alert'
      );
    }
  }

  @IsTest
  static void testWatchdogStallAlertApprovalWaitExclusion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // Mock Config
      WorkflowAlertManager.mockConfigs.put(
        'WorkflowEngineTest_HappyWorkflow',
        stallConfig('WorkflowEngineTest_HappyWorkflow', 'ops@test.com', 10)
      );

      // Create a suspended instance
      Workflow_Instance__c waitingInst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended'
      );
      insert waitingInst;

      // Backdate CreatedDate to 15 minutes ago
      Datetime fifteenMinsAgo = DateTime.now().addMinutes(-15);
      Test.setCreatedDate(waitingInst.Id, fifteenMinsAgo);

      // Create a pending step execution representing an active approval wait
      Workflow_Step_Execution__c pendingStep = new Workflow_Step_Execution__c(
        Workflow_Instance__c = waitingInst.Id,
        Step_Name__c = 'Step1',
        Status__c = 'Pending'
      );
      insert pendingStep;
      Test.setCreatedDate(pendingStep.Id, fifteenMinsAgo);

      WorkflowAlertManager.sentEmailsCount = 0;
      WorkflowEngine.processWatchdogHeartbeat();
      System.assertEquals(
        0,
        WorkflowAlertManager.sentEmailsCount,
        'Sleeper waiting on pending approval step should not alert'
      );
    }
  }

  @IsTest
  static void testWatchdogStallAlertPausedDefinitionExclusion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // Mock Config
      WorkflowAlertManager.mockConfigs.put(
        'WorkflowEngineTest_HappyWorkflow',
        stallConfig('WorkflowEngineTest_HappyWorkflow', 'ops@test.com', 10)
      );

      // Create a stalled instance
      Workflow_Instance__c stalledInst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running'
      );
      insert stalledInst;

      // Backdate CreatedDate to 15 minutes ago
      Datetime fifteenMinsAgo = DateTime.now().addMinutes(-15);
      Test.setCreatedDate(stalledInst.Id, fifteenMinsAgo);

      // Pause the definition
      WorkflowPauseGate.pauseDefinition(
        'WorkflowEngineTest.HappyWorkflow',
        'test'
      );

      WorkflowAlertManager.sentEmailsCount = 0;
      WorkflowEngine.processWatchdogHeartbeat();
      System.assertEquals(
        0,
        WorkflowAlertManager.sentEmailsCount,
        'Stalled instance on a paused definition should not alert'
      );
    }
  }

  @IsTest
  static void testWatchdogStallAlertCaseInsensitiveResolution() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // Mock Config using lowercase DeveloperName
      WorkflowAlertManager.mockConfigs.put(
        'workflowenginetest_happyworkflow',
        stallConfig('workflowenginetest_happyworkflow', 'ops@test.com', 10)
      );

      // Create stalled instance with mixed case name
      Workflow_Instance__c stalledInst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running'
      );
      insert stalledInst;

      Datetime fifteenMinsAgo = DateTime.now().addMinutes(-15);
      Test.setCreatedDate(stalledInst.Id, fifteenMinsAgo);

      WorkflowAlertManager.sentEmailsCount = 0;
      WorkflowEngine.processWatchdogHeartbeat();

      System.assertEquals(
        1,
        WorkflowAlertManager.sentEmailsCount,
        'Stall alert should be sent using case-insensitive config matching'
      );
    }
  }

  @IsTest
  static void testWatchdogStallAlertDefaultFallback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // Mock 'Default' config ONLY
      WorkflowAlertManager.mockConfigs.put(
        'Default',
        stallConfig('Default', 'ops@test.com', 10)
      );

      // Create stalled instance with a completely unmatched name
      Workflow_Instance__c stalledInst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.SomeRandomWorkflow',
        Status__c = 'Running'
      );
      insert stalledInst;

      Datetime fifteenMinsAgo = DateTime.now().addMinutes(-15);
      Test.setCreatedDate(stalledInst.Id, fifteenMinsAgo);

      WorkflowAlertManager.sentEmailsCount = 0;
      WorkflowEngine.processWatchdogHeartbeat();

      System.assertEquals(
        1,
        WorkflowAlertManager.sentEmailsCount,
        'Stall alert should fallback to Default configuration'
      );
    }
  }

  @IsTest
  static void testWatchdogStallAlertEmptyEmailHandling() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // Mock Config with empty email list
      WorkflowAlertManager.mockConfigs.put(
        'WorkflowEngineTest_HappyWorkflow',
        stallConfig('WorkflowEngineTest_HappyWorkflow', '', 10)
      );

      // Create stalled instance
      Workflow_Instance__c stalledInst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running'
      );
      insert stalledInst;

      Datetime fifteenMinsAgo = DateTime.now().addMinutes(-15);
      Test.setCreatedDate(stalledInst.Id, fifteenMinsAgo);

      WorkflowAlertManager.sentEmailsCount = 0;
      WorkflowEngine.processWatchdogHeartbeat();

      // No emails should be sent
      System.assertEquals(
        0,
        WorkflowAlertManager.sentEmailsCount,
        'No emails should be sent when recipients list is empty'
      );

      // But warning log should still be recorded
      List<Workflow_Log__c> logs = [
        SELECT Id, Log_Type__c
        FROM Workflow_Log__c
        WHERE
          Workflow_Instance__c = :stalledInst.Id
          AND Log_Type__c = 'WorkflowStallAlert'
      ];
      System.assertEquals(
        1,
        logs.size(),
        'Warning log marker should still be recorded'
      );
    }
  }

  @IsTest
  static void testWatchdogStallAlertBulkStallHandling() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // Mock configs
      WorkflowAlertManager.mockConfigs.put(
        'Workflow1',
        stallConfig('Workflow1', 'ops@test.com', 10)
      );
      WorkflowAlertManager.mockConfigs.put(
        'Workflow2',
        stallConfig('Workflow2', 'ops@test.com', 10)
      );

      // Create two stalled instances
      Workflow_Instance__c inst1 = new Workflow_Instance__c(
        Workflow_Name__c = 'Workflow1',
        Status__c = 'Running'
      );
      Workflow_Instance__c inst2 = new Workflow_Instance__c(
        Workflow_Name__c = 'Workflow2',
        Status__c = 'Running'
      );
      insert new List<Workflow_Instance__c>{ inst1, inst2 };

      Datetime fifteenMinsAgo = DateTime.now().addMinutes(-15);
      Test.setCreatedDate(inst1.Id, fifteenMinsAgo);
      Test.setCreatedDate(inst2.Id, fifteenMinsAgo);

      WorkflowAlertManager.sentEmailsCount = 0;
      WorkflowEngine.processWatchdogHeartbeat();

      System.assertEquals(
        2,
        WorkflowAlertManager.sentEmailsCount,
        'Stall alerts for both instances should be sent in bulk'
      );
    }
  }

  @IsTest
  static void testWatchdogStallAlertResumedInstanceExclusion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // Mock config
      WorkflowAlertManager.mockConfigs.put(
        'WorkflowEngineTest_HappyWorkflow',
        stallConfig('WorkflowEngineTest_HappyWorkflow', 'ops@test.com', 10)
      );

      // Create suspended instance that is sleeping (ready to resume)
      Workflow_Instance__c sleepingInst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Sleep_Until__c = DateTime.now().addMinutes(-5) // expired sleep
      );
      insert sleepingInst;

      // Backdate the instance CreatedDate and step execution to 30 minutes ago
      Datetime thirtyMinsAgo = DateTime.now().addMinutes(-30);
      Test.setCreatedDate(sleepingInst.Id, thirtyMinsAgo);

      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = sleepingInst.Id,
        Step_Name__c = 'Step1',
        Status__c = 'Completed'
      );
      insert step;
      Test.setCreatedDate(step.Id, thirtyMinsAgo);

      // Run watchdog heartbeat -> should resume the sleeping instance and NOT flag it as stalled in the same transaction
      WorkflowAlertManager.sentEmailsCount = 0;
      WorkflowEngine.processWatchdogHeartbeat();

      System.assertEquals(
        0,
        WorkflowAlertManager.sentEmailsCount,
        'Recently resumed instance should not trigger a false positive stall alert'
      );

      // Verify it was flipped to Running
      Workflow_Instance__c updatedInst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :sleepingInst.Id
      ];
      System.assertEquals(
        'Running',
        updatedInst.Status__c,
        'Instance should be resumed to Running'
      );
    }
  }

  @IsTest
  static void testWatchdogSweepSignalAutoDelivery() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // Create suspended instance waiting indefinitely (Sleep_Until__c is null)
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'WatchdogCorr-123'
      );
      insert inst;

      // Create an unrouted signal matching the correlation key
      Workflow_Signal__c sig = new Workflow_Signal__c(
        Correlation_Key__c = 'WatchdogCorr-123',
        Signal_Name__c = 'WakeMe',
        Payload__c = '{"data":1}',
        Status__c = 'Unrouted'
      );
      insert sig;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Verify signal is auto-delivered
      Workflow_Signal__c reloadedSig = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Id = :sig.Id
      ];
      System.assertEquals('Received', reloadedSig.Status__c);
      System.assertEquals(inst.Id, reloadedSig.Workflow_Instance__c);

      // Verify instance is resumed to Running
      Workflow_Instance__c reloadedInst = [
        SELECT Status__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals('Running', reloadedInst.Status__c);
      System.assertEquals(null, reloadedInst.Sleep_Until__c);
    }
  }

  @IsTest
  static void testWatchdogSweepSignalAutoDeliveryOldestFirst() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'WatchdogCorr-456'
      );
      insert inst;

      Workflow_Signal__c sig1 = new Workflow_Signal__c(
        Correlation_Key__c = 'WatchdogCorr-456',
        Signal_Name__c = 'WakeMe',
        Payload__c = '{"val":1}',
        Status__c = 'Unrouted'
      );
      insert sig1;

      Workflow_Signal__c sig2 = new Workflow_Signal__c(
        Correlation_Key__c = 'WatchdogCorr-456',
        Signal_Name__c = 'WakeMe',
        Payload__c = '{"val":2}',
        Status__c = 'Unrouted'
      );
      insert sig2;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Oldest signal must be auto-delivered
      Workflow_Signal__c reloadedSig1 = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Id = :sig1.Id
      ];
      System.assertEquals('Received', reloadedSig1.Status__c);
      System.assertEquals(inst.Id, reloadedSig1.Workflow_Instance__c);

      // Newer matching signal must also be auto-delivered in the same sweep
      Workflow_Signal__c reloadedSig2 = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Id = :sig2.Id
      ];
      System.assertEquals('Received', reloadedSig2.Status__c);
      System.assertEquals(inst.Id, reloadedSig2.Workflow_Instance__c);
    }
  }

  @IsTest
  static void testWatchdogSweepSignalKeyNormalization() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // Create suspended instance with mixed case key
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Watchdog-Corr-CASE'
      );
      insert inst;

      // Create unrouted signal with lowercase key
      Workflow_Signal__c sig = new Workflow_Signal__c(
        Correlation_Key__c = 'watchdog-corr-case',
        Signal_Name__c = 'WakeMe',
        Payload__c = '{"val":1}',
        Status__c = 'Unrouted'
      );
      insert sig;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Verify signal is auto-delivered due to case normalization
      Workflow_Signal__c reloadedSig = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Id = :sig.Id
      ];
      System.assertEquals(
        'Received',
        reloadedSig.Status__c,
        'Signal should be delivered due to case-normalization'
      );
      System.assertEquals(inst.Id, reloadedSig.Workflow_Instance__c);
    }
  }

  @IsTest
  static void testWatchdogSweepSignalFilterOutStale() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // Create 50 unmatched unrouted signals
      List<Workflow_Signal__c> staleSignals = new List<Workflow_Signal__c>();
      for (Integer i = 0; i < 50; i++) {
        staleSignals.add(
          new Workflow_Signal__c(
            Correlation_Key__c = 'StaleCorr-' + i,
            Signal_Name__c = 'Unmatched',
            Payload__c = '{}',
            Status__c = 'Unrouted'
          )
        );
      }
      insert staleSignals;

      // Create suspended instance
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'ActiveCorr-1'
      );
      insert inst;

      // Create matching unrouted signal
      Workflow_Signal__c matchingSig = new Workflow_Signal__c(
        Correlation_Key__c = 'ActiveCorr-1',
        Signal_Name__c = 'WakeMe',
        Payload__c = '{}',
        Status__c = 'Unrouted'
      );
      insert matchingSig;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Verify the matching signal is auto-delivered, proving the sweep filtered out the unmatched signals
      Workflow_Signal__c reloadedSig = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Id = :matchingSig.Id
      ];
      System.assertEquals(
        'Received',
        reloadedSig.Status__c,
        'Matching signal should be delivered'
      );
      System.assertEquals(inst.Id, reloadedSig.Workflow_Instance__c);
    }
  }

  @IsTest
  static void testWatchdogSweepSignalDrainsAllSignals() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // Create suspended instance
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'WatchdogCorr-LargeBacklog'
      );
      insert inst;

      // Insert 120 matching unrouted signals
      List<Workflow_Signal__c> signals = new List<Workflow_Signal__c>();
      for (Integer i = 0; i < 120; i++) {
        signals.add(
          new Workflow_Signal__c(
            Correlation_Key__c = 'WatchdogCorr-LargeBacklog',
            Signal_Name__c = 'WakeMe',
            Payload__c = '{"val":' + i + '}',
            Status__c = 'Unrouted'
          )
        );
      }
      insert signals;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Verify all 120 signals are auto-delivered
      List<Workflow_Signal__c> reloadedSignals = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Correlation_Key__c = 'WatchdogCorr-LargeBacklog'
      ];
      System.assertEquals(120, reloadedSignals.size());
      for (Workflow_Signal__c sig : reloadedSignals) {
        System.assertEquals(
          'Received',
          sig.Status__c,
          'All watchdog sweep signals in the large backlog must be auto-delivered'
        );
        System.assertEquals(inst.Id, sig.Workflow_Instance__c);
      }

      // Verify instance is resumed to Running
      Workflow_Instance__c reloadedInst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals('Running', reloadedInst.Status__c);
    }
  }

  @IsTest
  static void testWatchdogAutoReclaimOrphanedInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.reclaimThresholdMinutes = 10;
      WorkflowEngine.mockNow = DateTime.now().addMinutes(15);
      WorkflowEngine.WATCHDOG_TIMEOUT_BATCH_SIZE = 0;

      // Create candidate instance stuck in Running with a dead job ID
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running',
        Async_Job_Id__c = TestIdFactory.generate(AsyncApexJob.SObjectType) // Dead/mock job ID
      );
      insert inst;

      // Set LastModifiedDate to past threshold by updating via test
      Test.setCreatedDate(inst.Id, DateTime.now().addMinutes(-15));

      // Insert a running step execution log that got orphaned
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.HappyStep1',
        Status__c = 'Running',
        Retry_Count__c = 2,
        Error_Details__c = 'Stuck error',
        Timeout_At__c = DateTime.now().addMinutes(-5),
        CPU_Time_Ms__c = 100
      );
      insert stepExec;

      Test.startTest();
      // Run watchdog heartbeat to trigger reclaim
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Verify step execution was reset to Pending
      Workflow_Step_Execution__c updatedStep = [
        SELECT
          Status__c,
          Retry_Count__c,
          Error_Details__c,
          Timeout_At__c,
          CPU_Time_Ms__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExec.Id
      ];
      System.assertEquals('Pending', updatedStep.Status__c);
      System.assertEquals(0, updatedStep.Retry_Count__c);
      System.assertEquals(null, updatedStep.Error_Details__c);
      System.assertEquals(null, updatedStep.Timeout_At__c);
      System.assertEquals(null, updatedStep.CPU_Time_Ms__c);

      // Verify instance remains Running and Async_Job_Id__c was cleared
      Workflow_Instance__c updatedInst = [
        SELECT Status__c, Async_Job_Id__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals('Running', updatedInst.Status__c);
      System.assertEquals(null, updatedInst.Async_Job_Id__c);

      // Verify audit log of type OperatorIntervention was written
      List<Workflow_Log__c> logs = [
        SELECT Message__c, Log_Type__c
        FROM Workflow_Log__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Log_Type__c = 'OperatorIntervention'
      ];
      System.assertEquals(1, logs.size());
      System.assert(
        logs[0].Message__c.contains('Auto-reclaimed orphaned instance')
      );
    }
  }

  @IsTest
  static void testWatchdogAutoReclaimBypassesHealthyInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.reclaimThresholdMinutes = 10;
      WorkflowEngine.mockNow = DateTime.now();

      // Healthy in-flight Running instance (recently modified)
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running'
      );
      insert inst;

      // Running step execution log
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.HappyStep1',
        Status__c = 'Running'
      );
      insert stepExec;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Verify step was NOT reset
      Workflow_Step_Execution__c updatedStep = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExec.Id
      ];
      System.assertEquals('Running', updatedStep.Status__c);
    }
  }

  @IsTest
  static void testWatchdogAutoReclaimBypassesSuspendedInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.reclaimThresholdMinutes = 10;
      WorkflowEngine.mockNow = DateTime.now().addMinutes(15);

      // Suspended instance waiting on signal/approval/timer
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended'
      );
      insert inst;
      Test.setCreatedDate(inst.Id, DateTime.now().addMinutes(-15));

      // Pending step execution log waiting on signal
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.HappyStep1',
        Status__c = 'Pending'
      );
      insert stepExec;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Verify step was NOT reset
      Workflow_Step_Execution__c updatedStep = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExec.Id
      ];
      System.assertEquals('Pending', updatedStep.Status__c);
    }
  }

  @IsTest
  static void testWatchdogAutoReclaimBypassesCompletedStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.reclaimThresholdMinutes = 10;
      WorkflowEngine.mockNow = DateTime.now().addMinutes(15);

      // Candidate instance stuck in Running
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running'
      );
      insert inst;
      Test.setCreatedDate(inst.Id, DateTime.now().addMinutes(-15));

      // Completed step execution log
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.HappyStep1',
        Status__c = 'Completed'
      );
      insert stepExec;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Verify completed step is untouched
      Workflow_Step_Execution__c updatedStep = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExec.Id
      ];
      System.assertEquals('Completed', updatedStep.Status__c);
    }
  }

  @IsTest
  static void testWatchdogAutoReclaimParallelForwardWithCompensation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.reclaimThresholdMinutes = 10;
      WorkflowEngine.mockNow = DateTime.now().addMinutes(15);

      // Create candidate forward running instance with completed compensation step in stack
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running',
        Current_Step__c = 'WorkflowEngineTest.HappyStep1,WorkflowEngineTest.HappyStep2',
        Compensation_Stack__c = '["WorkflowEngineTest.HappyStep0"]',
        Async_Job_Id__c = TestIdFactory.generate(AsyncApexJob.SObjectType) // Dead/mock job ID
      );
      insert inst;
      Test.setCreatedDate(inst.Id, DateTime.now().addMinutes(-15));

      // Two running parallel step executions
      Workflow_Step_Execution__c step1 = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.HappyStep1',
        Status__c = 'Running'
      );
      Workflow_Step_Execution__c step2 = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.HappyStep2',
        Status__c = 'Running'
      );
      insert new List<Workflow_Step_Execution__c>{ step1, step2 };

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Verify both step executions are reset to Pending (proving they were targeted and reset)
      Map<Id, Workflow_Step_Execution__c> reloadedSteps = new Map<Id, Workflow_Step_Execution__c>(
        [
          SELECT Id, Status__c
          FROM Workflow_Step_Execution__c
          WHERE Id IN (:step1.Id, :step2.Id)
        ]
      );
      System.assertEquals('Pending', reloadedSteps.get(step1.Id).Status__c);
      System.assertEquals('Pending', reloadedSteps.get(step2.Id).Status__c);
    }
  }

  @IsTest
  static void testWatchdogStallAlertPublishEvent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowWatchdog.forceBootstrapInTest = true;
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Mock Config with Stall Threshold = 10 minutes and Publish_Alert_Event__c = true (empty email)
      WorkflowAlertManager.mockConfigs.put(
        'WorkflowEngineTest_HappyWorkflow',
        new StallCfg('WorkflowEngineTest_HappyWorkflow', '', true)
          .threshold(10)
          .publish(true)
          .build()
      );

      // 2. Create a stalled instance
      Workflow_Instance__c stalledInst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running'
      );
      insert stalledInst;

      // Backdate the instance CreatedDate to 15 minutes ago
      Datetime fifteenMinsAgo = DateTime.now().addMinutes(-15);
      Test.setCreatedDate(stalledInst.Id, fifteenMinsAgo);

      // Create a step execution backdated to 15 minutes ago as well
      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = stalledInst.Id,
        Step_Name__c = 'Step1',
        Status__c = 'Completed'
      );
      insert step;
      Test.setCreatedDate(step.Id, fifteenMinsAgo);

      // Reset counters and clear events
      WorkflowAlertManager.sentEmailsCount = 0;
      WorkflowAlertManager.publishedEvents.clear();

      // Run watchdog heartbeat -> should detect stall and publish event
      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      // Verify no email was sent (since recipients list is empty)
      System.assertEquals(
        0,
        WorkflowAlertManager.sentEmailsCount,
        'No email should be sent'
      );

      // Verify event is published
      System.assertEquals(
        1,
        WorkflowAlertManager.publishedEvents.size(),
        'Stall alert event should be published'
      );
      Workflow_Alert__e evt = WorkflowAlertManager.publishedEvents[0];
      System.assertEquals(
        'WorkflowEngineTest.HappyWorkflow',
        evt.Workflow_Name__c
      );
      System.assertEquals(stalledInst.Id, evt.Workflow_Instance_Id__c);
      System.assertEquals('Stall', evt.Alert_Reason__c);
      System.assertEquals(10, evt.Stall_Threshold_Minutes__c);
    }
  }
}
