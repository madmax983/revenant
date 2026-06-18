/**
 * TDD tests for operator pause/resume (issue #36).
 * Written BEFORE the implementation (red phase) — every test here should fail
 * against code that lacks WorkflowPauseGate and the pause gate in runStep.
 *
 * Scenarios covered:
 *  1. pauseDefinition / isPaused / resumeDefinition basic API
 *  2. Reserved names cannot be paused (deadlock guard)
 *  3. Quiesce at handoff: step in flight completes; next step parks (Paused), not executed
 *  4. Park at start: start() for a paused def creates a Paused instance, no first-step exec
 *  5. Resume re-enters exactly once, no double-exec (serial)
 *  6. Resume re-enters parallel: completed branches not re-run
 *  7. Signal held while paused (Defect B): held Workflow_Signal__c inserted; not lost
 *  8. Watchdog sleep-resume loop skips paused-def sleeping instances
 *  9. Cancel works on a Paused instance
 * 10. Correlation key stays reserved while Paused (Defect A regression)
 * 11. Pause state survives a cache flush (durability: object-backed, not in-memory)
 * 12. * (org-wide) pauses all user defs but NOT the watchdog
 * 13. Controller: pauseDefinition / resumeDefinition / getPausedDefinitions authz + happy paths
 */
@isTest
public class WorkflowPauseTest {
  // ============================================================
  // MOCK WORKFLOWS
  // ============================================================

  public class TwoStepWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'WorkflowPauseTest.StepA';
    }
    public String getNextStep(String current, StepResult result) {
      if (current == 'WorkflowPauseTest.StepA') {
        return 'WorkflowPauseTest.StepB';
      }
      return null;
    }
  }

  public class StepA implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete('WorkflowPauseTest.StepB', 'OutputA');
    }
  }

  public class StepB implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'OutputB');
    }
  }

  public class SuspendingWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'WorkflowPauseTest.SuspendStep';
    }
    public String getNextStep(String current, StepResult result) {
      if (current == 'WorkflowPauseTest.SuspendStep') {
        return 'WorkflowPauseTest.StepB';
      }
      return null;
    }
  }

  // Step that suspends waiting for a named signal
  public class SuspendStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.suspend('WaitSignal', 'Waiting for WaitSignal');
    }
  }

  public class ParallelWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'WorkflowPauseTest.SplitStep';
    }
    public String getNextStep(String current, StepResult result) {
      if (current == 'WorkflowPauseTest.SplitStep') {
        return 'WorkflowPauseTest.JoinStep';
      }
      return null;
    }
  }

  public class SplitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowPauseTest.BranchA',
          'WorkflowPauseTest.BranchB'
        },
        'SplitInput'
      );
    }
  }

  public class BranchA implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'BranchAOut');
    }
  }

  public class BranchB implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'BranchBOut');
    }
  }

  public class JoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Joined');
    }
  }

  // ============================================================
  // 1. PAUSE GATE API — basic pause / isPaused / resume
  // ============================================================

  @isTest
  static void testPauseAndResumeDefinition() {
    Test.startTest();
    WorkflowPauseGate.pauseDefinition(
      'WorkflowPauseTest.TwoStepWorkflow',
      'Test pause'
    );
    Boolean paused = WorkflowPauseGate.isDefinitionPaused(
      'WorkflowPauseTest.TwoStepWorkflow'
    );

    WorkflowPauseGate.resumeDefinition('WorkflowPauseTest.TwoStepWorkflow');
    Boolean resumed = WorkflowPauseGate.isDefinitionPaused(
      'WorkflowPauseTest.TwoStepWorkflow'
    );
    Test.stopTest();

    System.assertEquals(true, paused, 'Definition should be paused');
    System.assertEquals(
      false,
      resumed,
      'Definition should not be paused after resume'
    );
  }

  @isTest
  static void testAnyPausedFastPath() {
    System.assertEquals(
      false,
      WorkflowPauseGate.anyPaused(),
      'Nothing paused initially'
    );

    Test.startTest();
    WorkflowPauseGate.pauseDefinition(
      'WorkflowPauseTest.TwoStepWorkflow',
      null
    );
    Boolean anyPaused = WorkflowPauseGate.anyPaused();
    Test.stopTest();

    System.assertEquals(true, anyPaused, 'anyPaused should be true');
  }

  @isTest
  static void testPauseDurability() {
    WorkflowPauseGate.pauseDefinition(
      'WorkflowPauseTest.TwoStepWorkflow',
      'Durability test'
    );

    // Verify the record is in the database (durable, not in-memory only)
    List<Workflow_Pause_State__c> records = [
      SELECT Workflow_Name__c, Reason__c
      FROM Workflow_Pause_State__c
      WHERE Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow'
    ];
    System.assertEquals(1, records.size(), 'Pause state should be in DB');
    System.assertEquals(
      'Durability test',
      records[0].Reason__c,
      'Reason should be stored'
    );
  }

  @isTest
  static void testPauseIdempotent() {
    // Pausing twice should not throw — upsert semantics
    Test.startTest();
    WorkflowPauseGate.pauseDefinition(
      'WorkflowPauseTest.TwoStepWorkflow',
      'First'
    );
    WorkflowPauseGate.pauseDefinition(
      'WorkflowPauseTest.TwoStepWorkflow',
      'Second'
    );
    Test.stopTest();

    List<Workflow_Pause_State__c> records = [
      SELECT Workflow_Name__c
      FROM Workflow_Pause_State__c
      WHERE Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow'
    ];
    System.assertEquals(1, records.size(), 'Should be exactly one pause record');
  }

  // ============================================================
  // 2. RESERVED NAMES CANNOT BE PAUSED
  // ============================================================

  @isTest
  static void testReservedNamesCannotBePaused() {
    List<String> reserved = new List<String>{
      'WatchdogWorkflow',
      'CleanupWorkflow',
      'BulkRedriveWorkflow'
    };
    for (String name : reserved) {
      Boolean threw = false;
      try {
        WorkflowPauseGate.pauseDefinition(name, 'Should fail');
      } catch (WorkflowPauseGate.PauseException ex) {
        threw = true;
      }
      System.assertEquals(
        true,
        threw,
        'Should reject pause of reserved workflow: ' + name
      );
    }
  }

  @isTest
  static void testReservedNamesNotPausedByWildcard() {
    Test.startTest();
    WorkflowPauseGate.pauseDefinition('*', 'Org-wide pause');
    Boolean watchdogPaused = WorkflowPauseGate.isDefinitionPaused(
      'WatchdogWorkflow'
    );
    Boolean cleanupPaused = WorkflowPauseGate.isDefinitionPaused(
      'CleanupWorkflow'
    );
    Test.stopTest();

    System.assertEquals(
      false,
      watchdogPaused,
      'Watchdog must NEVER be paused by *'
    );
    System.assertEquals(
      false,
      cleanupPaused,
      'CleanupWorkflow must NEVER be paused by *'
    );
  }

  // ============================================================
  // 3. QUIESCE AT HANDOFF — step in flight completes; NEXT step parks
  // ============================================================

  @isTest
  static void testQuiesceAtHandoff() {
    WorkflowEngine.disableQueueableInTest = true;

    // Pause the definition
    WorkflowPauseGate.pauseDefinition(
      'WorkflowPauseTest.TwoStepWorkflow',
      'Incident'
    );

    // Start a new instance (goes Paused immediately in doStart)
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowPauseTest.TwoStepWorkflow',
      'PauseHandoff-' + Datetime.now().getTime(),
      null
    );
    Test.stopTest();

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'Paused',
      inst.Status__c,
      'Instance started under a pause should be Paused'
    );

    // No step execution should be Running/Completed — only Pending
    List<Workflow_Step_Execution__c> steps = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Status__c IN ('Running', 'Completed')
    ];
    System.assertEquals(
      0,
      steps.size(),
      'No step should have executed while paused'
    );
  }

  @isTest
  static void testQuiesceAtChainHandoff() {
    // Simulate the gate stopping the SECOND step: run StepA manually (while paused),
    // then verify StepB is NOT enqueued/executed.
    WorkflowEngine.disableQueueableInTest = true;

    // Create an instance already past StepA, queued for StepB
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
      Status__c = 'Running',
      Current_Step__c = 'WorkflowPauseTest.StepB',
      Correlation_Key__c = 'PauseChain-' + Datetime.now().getTime()
    );
    insert inst;
    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowPauseTest.StepB',
      Status__c = 'Pending',
      Input__c = '"OutputA"',
      Retry_Count__c = 0
    );
    insert stepExec;

    // Pause the definition
    WorkflowPauseGate.pauseDefinition(
      'WorkflowPauseTest.TwoStepWorkflow',
      'Pre-run pause'
    );

    // Drive runStep — gate should park, not execute StepB
    Test.startTest();
    WorkflowEngine.runStep(inst.Id, 'WorkflowPauseTest.StepB');
    Test.stopTest();

    Workflow_Instance__c updated = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      'Paused',
      updated.Status__c,
      'Instance should be Paused at handoff gate'
    );

    // StepB should still be Pending (never executed)
    Workflow_Step_Execution__c updatedStep = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepExec.Id
    ];
    System.assertEquals(
      'Pending',
      updatedStep.Status__c,
      'StepB should remain Pending (parked, not executed)'
    );
  }

  // ============================================================
  // 4. PARK AT START
  // ============================================================

  @isTest
  static void testParkAtStart() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowPauseGate.pauseDefinition(
      'WorkflowPauseTest.TwoStepWorkflow',
      'Park at start'
    );

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowPauseTest.TwoStepWorkflow',
      'ParkStart-' + Datetime.now().getTime(),
      null
    );
    Test.stopTest();

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Paused', inst.Status__c, 'Start should park');
    // The initial step record exists (Pending) so resume has something to drive
    List<Workflow_Step_Execution__c> steps = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Pending'
    ];
    System.assertEquals(
      1,
      steps.size(),
      'Initial step should be pre-created Pending for resume'
    );
    // No step should have started executing
    List<Workflow_Step_Execution__c> running = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Running'
    ];
    System.assertEquals(0, running.size(), 'No step should be running');
  }

  // ============================================================
  // 5. RESUME RE-ENTERS EXACTLY ONCE — serial
  // ============================================================

  @isTest
  static void testResumeSerialReentersOnce() {
    WorkflowEngine.disableQueueableInTest = true;

    // Park an instance mid-workflow at StepB
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
      Status__c = 'Paused',
      Current_Step__c = 'WorkflowPauseTest.StepB',
      Correlation_Key__c = 'ResumeSerial-' + Datetime.now().getTime()
    );
    insert inst;
    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowPauseTest.StepB',
      Status__c = 'Pending',
      Input__c = '"OutputA"',
      Retry_Count__c = 0
    );
    insert stepExec;

    Test.startTest();
    WorkflowPauseGate.resumeDefinition('WorkflowPauseTest.TwoStepWorkflow');
    // Drive the enqueued step manually (disableQueueableInTest skips auto-exec)
    new WorkflowOrchestrator(inst.Id).execute(null);
    Test.stopTest();

    // StepB should have run to Completed exactly once
    List<Workflow_Step_Execution__c> completedSteps = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :inst.Id
        AND Step_Name__c = 'WorkflowPauseTest.StepB'
        AND Status__c = 'Completed'
    ];
    System.assertEquals(
      1,
      completedSteps.size(),
      'StepB should complete exactly once'
    );

    Workflow_Instance__c resumed = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      'Completed',
      resumed.Status__c,
      'Workflow should be Completed after resume'
    );
  }

  // ============================================================
  // 6. RESUME PARALLEL — completed branches not re-run
  // ============================================================

  @isTest
  static void testResumeParallelCompletedBranchNotRerun() {
    WorkflowEngine.disableQueueableInTest = true;

    // Create a paused instance mid-parallel: BranchA done, BranchB pending
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowPauseTest.ParallelWorkflow',
      Status__c = 'Paused',
      Current_Step__c = 'WorkflowPauseTest.BranchA,WorkflowPauseTest.BranchB',
      Correlation_Key__c = 'ResumeParallel-' + Datetime.now().getTime()
    );
    insert inst;

    // BranchA already Completed
    Workflow_Step_Execution__c branchAExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowPauseTest.BranchA',
      Status__c = 'Completed',
      Input__c = '"SplitInput"',
      Output__c = '"BranchAOut"',
      Retry_Count__c = 0
    );
    insert branchAExec;

    // BranchB still Pending
    Workflow_Step_Execution__c branchBExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowPauseTest.BranchB',
      Status__c = 'Pending',
      Input__c = '"SplitInput"',
      Retry_Count__c = 0
    );
    insert branchBExec;

    Test.startTest();
    WorkflowPauseGate.resumeDefinition('WorkflowPauseTest.ParallelWorkflow');
    // Drive BranchB manually
    new WorkflowOrchestrator(inst.Id, 'WorkflowPauseTest.BranchB').execute(
      null
    );
    Test.stopTest();

    // BranchA should still have exactly one Completed record (no double-exec)
    List<Workflow_Step_Execution__c> branchAExecs = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :inst.Id
        AND Step_Name__c = 'WorkflowPauseTest.BranchA'
    ];
    System.assertEquals(
      1,
      branchAExecs.size(),
      'BranchA should not be re-executed'
    );
    System.assertEquals(
      'Completed',
      branchAExecs[0].Status__c,
      'BranchA should remain Completed'
    );
  }

  // ============================================================
  // 7. SIGNAL HELD WHILE PAUSED (Defect B regression)
  // ============================================================

  @isTest
  static void testSignalHeldWhilePaused() {
    WorkflowEngine.disableQueueableInTest = true;

    // Create a Paused instance that is waiting on a signal (Current_Step__c=SuspendStep)
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowPauseTest.SuspendingWorkflow',
      Status__c = 'Paused',
      Current_Step__c = 'WorkflowPauseTest.SuspendStep',
      Correlation_Key__c = 'PauseSignal-' + Datetime.now().getTime()
    );
    insert inst;

    WorkflowPauseGate.pauseDefinition(
      'WorkflowPauseTest.SuspendingWorkflow',
      'Hold signals test'
    );

    Test.startTest();
    // Send a signal to the paused instance — should NOT be lost
    WorkflowEngine.signal(
      inst.Correlation_Key__c,
      'WaitSignal',
      '"SignalPayload"'
    );
    Test.stopTest();

    // Signal should be stored as Received (held, not dropped)
    List<Workflow_Signal__c> signals = [
      SELECT Status__c, Signal_Name__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :inst.Id
    ];
    System.assertEquals(
      1,
      signals.size(),
      'Signal should be stored when instance is Paused'
    );
    System.assertEquals(
      'Received',
      signals[0].Status__c,
      'Signal should be Received (held) while paused'
    );

    // Instance should STILL be Paused (not woken up)
    Workflow_Instance__c updated = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      'Paused',
      updated.Status__c,
      'Paused instance must NOT be woken by signal'
    );
  }

  // ============================================================
  // 8. WATCHDOG SLEEP-RESUME SKIPS PAUSED-DEF INSTANCES
  // ============================================================

  @isTest
  static void testWatchdogSkipsSleepingPausedDefInstance() {
    WorkflowEngine.disableQueueableInTest = true;

    // A Suspended (sleeping) instance whose def is paused
    Workflow_Instance__c sleepingInst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
      Status__c = 'Suspended',
      Sleep_Until__c = DateTime.now().addSeconds(-30),
      Current_Step__c = 'WorkflowPauseTest.StepA',
      Correlation_Key__c = 'WatchdogSkip-' + Datetime.now().getTime()
    );
    insert sleepingInst;

    // A Suspended (sleeping) instance whose def is NOT paused (should still wake)
    Workflow_Instance__c otherInst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Sleep_Until__c = DateTime.now().addSeconds(-30),
      Correlation_Key__c = 'WatchdogOther-' + Datetime.now().getTime()
    );
    insert otherInst;

    WorkflowPauseGate.pauseDefinition(
      'WorkflowPauseTest.TwoStepWorkflow',
      'Skip test'
    );

    Test.startTest();
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    // Paused-def instance should still be Suspended
    Workflow_Instance__c pausedInst = [
      SELECT Status__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :sleepingInst.Id
    ];
    System.assertEquals(
      'Suspended',
      pausedInst.Status__c,
      'Paused-def sleeping instance should stay Suspended'
    );
    System.assertNotEquals(
      null,
      pausedInst.Sleep_Until__c,
      'Sleep_Until__c should be preserved (not cleared) for paused-def instance'
    );

    // Non-paused instance should have been woken
    Workflow_Instance__c woken = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :otherInst.Id
    ];
    System.assertEquals(
      'Running',
      woken.Status__c,
      'Non-paused-def instance should be woken by watchdog'
    );
  }

  // ============================================================
  // 9. CANCEL WORKS ON A PAUSED INSTANCE
  // ============================================================

  @isTest
  static void testCancelWorksOnPausedInstance() {
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
      Status__c = 'Paused',
      Current_Step__c = 'WorkflowPauseTest.StepB',
      Correlation_Key__c = 'CancelPaused-' + Datetime.now().getTime()
    );
    insert inst;

    Test.startTest();
    WorkflowEngine.cancel(inst.Id, false);
    Test.stopTest();

    Workflow_Instance__c cancelled = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      'Cancelled',
      cancelled.Status__c,
      'Paused instance should be cancelable'
    );
  }

  // ============================================================
  // 10. CORRELATION KEY STAYS RESERVED WHILE PAUSED (Defect A regression)
  // ============================================================

  @isTest
  static void testCorrelationKeyReservedWhilePaused() {
    String corrKey = 'DefectA-' + Datetime.now().getTime();

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
      Status__c = 'Paused',
      Current_Step__c = 'WorkflowPauseTest.StepA',
      Correlation_Key__c = corrKey
    );
    insert inst;

    // Verify Active_Correlation_Key__c is set (not null) — trigger should preserve it
    Workflow_Instance__c updated = [
      SELECT Active_Correlation_Key__c, Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      corrKey,
      updated.Active_Correlation_Key__c,
      'Active_Correlation_Key__c must remain set while Paused (reservation intact)'
    );
  }

  @isTest
  static void testCorrelationKeyReservationPreventsDuplicate() {
    WorkflowEngine.disableQueueableInTest = true;
    String corrKey = 'DefectA-Dedup-' + Datetime.now().getTime();

    // Insert a Paused instance manually
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
      Status__c = 'Paused',
      Current_Step__c = 'WorkflowPauseTest.StepA',
      Correlation_Key__c = corrKey
    );
    insert inst;

    // Try to start with the same correlation key — should return the existing instance (dedup)
    WorkflowPauseGate.pauseDefinition(
      'WorkflowPauseTest.TwoStepWorkflow',
      null
    );
    Test.startTest();
    WorkflowEngine.StartResult result = WorkflowEngine.startOrGet(
      'WorkflowPauseTest.TwoStepWorkflow',
      corrKey,
      null
    );
    Test.stopTest();

    System.assertEquals(
      inst.Id,
      result.instanceId,
      'Should return the existing Paused instance, not create a duplicate'
    );
    System.assertEquals(false, result.isNew, 'Should NOT be a new instance');
  }

  // ============================================================
  // 11. PAUSE STATE DURABILITY (not in-memory only)
  // ============================================================

  @isTest
  static void testPauseStateDurability() {
    WorkflowPauseGate.pauseDefinition('WorkflowPauseTest.TwoStepWorkflow', 'D');

    // Simulate a "new transaction / cache flush" by verifying the DB record
    // (static fields would be re-initialized in a fresh execution context)
    List<Workflow_Pause_State__c> records = [
      SELECT Workflow_Name__c
      FROM Workflow_Pause_State__c
    ];
    System.assertEquals(1, records.size(), 'Pause record must be in database');
    System.assertEquals(
      'WorkflowPauseTest.TwoStepWorkflow',
      records[0].Workflow_Name__c
    );
  }

  // ============================================================
  // 12. * PAUSES USER DEFS, NOT WATCHDOG
  // ============================================================

  @isTest
  static void testWildcardPausesUserDefNotWatchdog() {
    Test.startTest();
    WorkflowPauseGate.pauseDefinition('*', 'Org maintenance');

    Boolean userPaused = WorkflowPauseGate.isDefinitionPaused(
      'WorkflowPauseTest.TwoStepWorkflow'
    );
    Boolean watchdogPaused = WorkflowPauseGate.isDefinitionPaused(
      'WatchdogWorkflow'
    );
    Boolean bulkRedrivePaused = WorkflowPauseGate.isDefinitionPaused(
      'BulkRedriveWorkflow'
    );
    Test.stopTest();

    System.assertEquals(true, userPaused, 'User def should be paused by *');
    System.assertEquals(
      false,
      watchdogPaused,
      'WatchdogWorkflow must NEVER be paused by *'
    );
    System.assertEquals(
      false,
      bulkRedrivePaused,
      'BulkRedriveWorkflow must NEVER be paused by *'
    );
  }

  @isTest
  static void testWildcardResumeUnparksAll() {
    WorkflowEngine.disableQueueableInTest = true;

    // Park two instances of different defs
    Workflow_Instance__c inst1 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
      Status__c = 'Paused',
      Current_Step__c = 'WorkflowPauseTest.StepB',
      Correlation_Key__c = 'WildcardResume1-' + Datetime.now().getTime()
    );
    insert inst1;
    Workflow_Instance__c inst2 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowPauseTest.SuspendingWorkflow',
      Status__c = 'Paused',
      Current_Step__c = 'WorkflowPauseTest.SuspendStep',
      Correlation_Key__c = 'WildcardResume2-' + Datetime.now().getTime()
    );
    insert inst2;

    WorkflowPauseGate.pauseDefinition('*', 'All paused');

    Test.startTest();
    WorkflowPauseGate.resumeDefinition('*');
    Test.stopTest();

    List<Workflow_Instance__c> instances = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id IN (:inst1.Id, :inst2.Id)
    ];
    for (Workflow_Instance__c i : instances) {
      System.assertEquals('Running', i.Status__c, 'All parked instances should be Running after * resume');
    }
  }

  // ============================================================
  // 13. DASHBOARD CONTROLLER
  // ============================================================

  @isTest
  static void testControllerPauseDefinition() {
    Test.startTest();
    WorkflowDashboardController.pauseDefinition(
      'WorkflowPauseTest.TwoStepWorkflow',
      'Controller test'
    );
    Test.stopTest();

    List<Workflow_Pause_State__c> records = [
      SELECT Workflow_Name__c
      FROM Workflow_Pause_State__c
      WHERE Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow'
    ];
    System.assertEquals(1, records.size(), 'Pause state should exist after controller call');
  }

  @isTest
  static void testControllerResumeDefinition() {
    WorkflowPauseGate.pauseDefinition('WorkflowPauseTest.TwoStepWorkflow', 'X');

    Test.startTest();
    WorkflowDashboardController.resumeDefinition(
      'WorkflowPauseTest.TwoStepWorkflow'
    );
    Test.stopTest();

    List<Workflow_Pause_State__c> records = [
      SELECT Workflow_Name__c
      FROM Workflow_Pause_State__c
      WHERE Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow'
    ];
    System.assertEquals(
      0,
      records.size(),
      'Pause state should be removed after resume'
    );
  }

  @isTest
  static void testControllerGetPausedDefinitions() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowPauseGate.pauseDefinition('WorkflowPauseTest.TwoStepWorkflow', 'Incident-42');

    // Create a parked instance for this def
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
      Status__c = 'Paused',
      Current_Step__c = 'WorkflowPauseTest.StepB',
      Correlation_Key__c = 'GetPaused-' + Datetime.now().getTime()
    );
    insert inst;

    Test.startTest();
    List<Map<String, Object>> paused = WorkflowDashboardController.getPausedDefinitions();
    Test.stopTest();

    System.assertEquals(1, paused.size(), 'Should return one paused definition');
    Map<String, Object> entry = paused[0];
    System.assertEquals(
      'WorkflowPauseTest.TwoStepWorkflow',
      entry.get('workflowName')
    );
    System.assertEquals('Incident-42', entry.get('reason'));
    System.assertEquals(
      1,
      (Integer) entry.get('parkedCount'),
      'parkedCount should reflect Paused instances'
    );
  }

  @isTest
  static void testControllerGetWatchdogStatusIncludesPausedInfo() {
    WorkflowPauseGate.pauseDefinition('WorkflowPauseTest.TwoStepWorkflow', 'W');

    Test.startTest();
    Map<String, Object> status = WorkflowDashboardController.getWatchdogStatus();
    Test.stopTest();

    System.assertNotEquals(
      null,
      status.get('pausedDefinitions'),
      'getWatchdogStatus should include pausedDefinitions key'
    );
  }
}
