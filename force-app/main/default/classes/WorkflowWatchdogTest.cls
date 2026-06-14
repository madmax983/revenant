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

    Test.startTest();
    // Start the WatchdogWorkflow (Pending status initially)
    Id watchdogId = WorkflowEngine.start(
      'WatchdogWorkflow',
      'SystemWatchdog',
      null
    );
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
}
