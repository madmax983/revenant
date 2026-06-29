@isTest
public class WorkflowWatchdogTest {
  @isTest
  static void testWatchdogScheduleAndBootstrap() {
    WorkflowWatchdog.forceBootstrapInTest = true;

    Test.startTest();
    String jobId = System.schedule(
      'TestWatchdogJob',
      '0 0 0 * * ?',
      new WorkflowWatchdog()
    );
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

  @isTest
  static void testWatchdogWorkflowExecution() {
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

  @isTest
  static void testQueueableJobsCoverage() {
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
  }

  @isTest
  static void testWatchdogBootstrapAndConfig() {
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

  @isTest
  static void testWatchdogBootstrapWithSuccessor() {
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
    System.assertEquals(0, newWatchdogs.size(), 'Should not spawn a new watchdog if a successor is active');
  }

  @isTest
  static void testTimedSuspend_BulkSignalWins_DisarmsTimer() {
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
    System.assertNotEquals(null, inst.Sleep_Until__c, 'Timer should be armed before bulk signal');

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
    System.assertEquals('Running', inst.Status__c, 'Should be Running after bulk signal');
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

  private static Workflow_Alert_Config__mdt createMockStallConfig(
    String devName,
    String recipients,
    Boolean enabled,
    Integer stallThresholdMinutes
  ) {
    Map<String, Object> fields = new Map<String, Object>{
      'DeveloperName' => devName,
      'Email_Recipients__c' => recipients,
      'Enable_Alerts__c' => enabled,
      'Stall_Threshold_Minutes__c' => stallThresholdMinutes
    };
    return (Workflow_Alert_Config__mdt) JSON.deserialize(
      JSON.serialize(fields),
      Workflow_Alert_Config__mdt.class
    );
  }

  @isTest
  static void testWatchdogStallAlertBasicAndDedup() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Mock Config with Stall Threshold = 10 minutes
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockStallConfig('WorkflowEngineTest_HappyWorkflow', 'ops@test.com', true, 10)
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

    System.assertEquals(1, WorkflowAlertManager.sentEmailsCount, 'Stall alert should be sent');

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
    System.assertEquals(0, WorkflowAlertManager.sentEmailsCount, 'Should not send duplicate alert');
  }

  @isTest
  static void testWatchdogStallAlertResumeAndStallAgain() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;

    // Mock Config
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockStallConfig('WorkflowEngineTest_HappyWorkflow', 'ops@test.com', true, 10)
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
    System.assertEquals(1, WorkflowAlertManager.sentEmailsCount, 'First stall alert sent');

    // Retrieve and backdate the stall alert log so it is older than step2's timestamp
    List<Workflow_Log__c> logs = [
      SELECT Id, CreatedDate
      FROM Workflow_Log__c
      WHERE Workflow_Instance__c = :stalledInst.Id AND Log_Type__c = 'WorkflowStallAlert'
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
    System.assertEquals(0, WorkflowAlertManager.sentEmailsCount, 'Should not alert before threshold reached');

    // Now backdate the new step execution to 12 minutes ago (so it is now stalled again)
    Datetime twelveMinsAgo = DateTime.now().addMinutes(-12);
    Test.setCreatedDate(step2.Id, twelveMinsAgo);

    // Run watchdog -> should alert again because it stalled again
    WorkflowEngine.processWatchdogHeartbeat();
    System.assertEquals(1, WorkflowAlertManager.sentEmailsCount, 'Second stall alert should be sent');
  }

  @isTest
  static void testWatchdogStallAlertLegitimateSleepExclusion() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;

    // Mock Config
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockStallConfig('WorkflowEngineTest_HappyWorkflow', 'ops@test.com', true, 10)
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
    System.assertEquals(0, WorkflowAlertManager.sentEmailsCount, 'Legitimate sleeper should not alert');
  }

  @isTest
  static void testWatchdogStallAlertApprovalWaitExclusion() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;

    // Mock Config
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockStallConfig('WorkflowEngineTest_HappyWorkflow', 'ops@test.com', true, 10)
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
    System.assertEquals(0, WorkflowAlertManager.sentEmailsCount, 'Sleeper waiting on pending approval step should not alert');
  }

  @isTest
  static void testWatchdogStallAlertPausedDefinitionExclusion() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;

    // Mock Config
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockStallConfig('WorkflowEngineTest_HappyWorkflow', 'ops@test.com', true, 10)
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
    WorkflowPauseGate.pauseDefinition('WorkflowEngineTest.HappyWorkflow', 'test');

    WorkflowAlertManager.sentEmailsCount = 0;
    WorkflowEngine.processWatchdogHeartbeat();
    System.assertEquals(0, WorkflowAlertManager.sentEmailsCount, 'Stalled instance on a paused definition should not alert');
  }

  @isTest
  static void testWatchdogStallAlertCaseInsensitiveResolution() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;

    // Mock Config using lowercase DeveloperName
    WorkflowAlertManager.mockConfigs.put(
      'workflowenginetest_happyworkflow',
      createMockStallConfig('workflowenginetest_happyworkflow', 'ops@test.com', true, 10)
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

    System.assertEquals(1, WorkflowAlertManager.sentEmailsCount, 'Stall alert should be sent using case-insensitive config matching');
  }

  @isTest
  static void testWatchdogStallAlertDefaultFallback() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;

    // Mock 'Default' config ONLY
    WorkflowAlertManager.mockConfigs.put(
      'Default',
      createMockStallConfig('Default', 'ops@test.com', true, 10)
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

    System.assertEquals(1, WorkflowAlertManager.sentEmailsCount, 'Stall alert should fallback to Default configuration');
  }

  @isTest
  static void testWatchdogStallAlertEmptyEmailHandling() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;

    // Mock Config with empty email list
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockStallConfig('WorkflowEngineTest_HappyWorkflow', '', true, 10)
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
    System.assertEquals(0, WorkflowAlertManager.sentEmailsCount, 'No emails should be sent when recipients list is empty');

    // But warning log should still be recorded
    List<Workflow_Log__c> logs = [
      SELECT Id, Log_Type__c
      FROM Workflow_Log__c
      WHERE Workflow_Instance__c = :stalledInst.Id AND Log_Type__c = 'WorkflowStallAlert'
    ];
    System.assertEquals(1, logs.size(), 'Warning log marker should still be recorded');
  }

  @isTest
  static void testWatchdogStallAlertBulkStallHandling() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;

    // Mock configs
    WorkflowAlertManager.mockConfigs.put(
      'Workflow1',
      createMockStallConfig('Workflow1', 'ops@test.com', true, 10)
    );
    WorkflowAlertManager.mockConfigs.put(
      'Workflow2',
      createMockStallConfig('Workflow2', 'ops@test.com', true, 10)
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

    System.assertEquals(2, WorkflowAlertManager.sentEmailsCount, 'Stall alerts for both instances should be sent in bulk');
  }

  @isTest
  static void testWatchdogStallAlertResumedInstanceExclusion() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;

    // Mock config
    WorkflowAlertManager.mockConfigs.put(
      'WorkflowEngineTest_HappyWorkflow',
      createMockStallConfig('WorkflowEngineTest_HappyWorkflow', 'ops@test.com', true, 10)
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

    System.assertEquals(0, WorkflowAlertManager.sentEmailsCount, 'Recently resumed instance should not trigger a false positive stall alert');
    
    // Verify it was flipped to Running
    Workflow_Instance__c updatedInst = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :sleepingInst.Id];
    System.assertEquals('Running', updatedInst.Status__c, 'Instance should be resumed to Running');
  }

  @isTest
  static void testWatchdogSweepSignalAutoDelivery() {
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

  @isTest
  static void testWatchdogSweepSignalAutoDeliveryOldestFirst() {
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

  @isTest
  static void testWatchdogSweepSignalKeyNormalization() {
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
    System.assertEquals('Received', reloadedSig.Status__c, 'Signal should be delivered due to case-normalization');
    System.assertEquals(inst.Id, reloadedSig.Workflow_Instance__c);
  }

  @isTest
  static void testWatchdogSweepSignalFilterOutStale() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;

    // Create 50 unmatched unrouted signals
    List<Workflow_Signal__c> staleSignals = new List<Workflow_Signal__c>();
    for (Integer i = 0; i < 50; i++) {
      staleSignals.add(new Workflow_Signal__c(
        Correlation_Key__c = 'StaleCorr-' + i,
        Signal_Name__c = 'Unmatched',
        Payload__c = '{}',
        Status__c = 'Unrouted'
      ));
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
    System.assertEquals('Received', reloadedSig.Status__c, 'Matching signal should be delivered');
    System.assertEquals(inst.Id, reloadedSig.Workflow_Instance__c);
  }

  @isTest
  static void testWatchdogSweepSignalDrainsAllSignals() {
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
      signals.add(new Workflow_Signal__c(
        Correlation_Key__c = 'WatchdogCorr-LargeBacklog',
        Signal_Name__c = 'WakeMe',
        Payload__c = '{"val":' + i + '}',
        Status__c = 'Unrouted'
      ));
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
      System.assertEquals('Received', sig.Status__c, 'All watchdog sweep signals in the large backlog must be auto-delivered');
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

