/**
 * Pause Gate API tests (basic pause / isPaused / resume, quiesce, park, and
 * serial/parallel resume) split out of WorkflowPauseTest to keep each test type
 * within the analyzer's per-class size and complexity limits. Mock workflow and
 * step definitions remain in WorkflowPauseTest and are referenced here by their
 * fully-qualified string names, exactly as the engine resolves them.
 */
@IsTest
public class WorkflowPauseGateApiTest {
  @IsTest
  static void testPauseAndResumeDefinition() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  @IsTest
  static void testAnyPausedFastPath() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  @IsTest
  static void testPauseDurability() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  @IsTest
  static void testPauseIdempotent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
      System.assertEquals(
        1,
        records.size(),
        'Should be exactly one pause record'
      );
    }
  }

  // ============================================================
  // 2. RESERVED NAMES CANNOT BE PAUSED
  // ============================================================

  @IsTest
  static void testReservedNamesCannotBePaused() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<String> reserved = new List<String>{
        'WatchdogWorkflow',
        'CleanupWorkflow',
        'BulkRedriveWorkflow',
        'BulkCancelWorkflow'
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
  }

  @IsTest
  static void testReservedNamesNotPausedByWildcard() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  // ============================================================
  // 3. QUIESCE AT HANDOFF — step in flight completes; NEXT step parks
  // ============================================================

  @IsTest
  static void testQuiesceAtHandoff() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c IN ('Running', 'Completed')
      ];
      System.assertEquals(
        0,
        steps.size(),
        'No step should have executed while paused'
      );
    }
  }

  @IsTest
  static void testQuiesceAtChainHandoff() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  // ============================================================
  // 4. PARK AT START
  // ============================================================

  @IsTest
  static void testParkAtStart() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  // ============================================================
  // 5. RESUME RE-ENTERS EXACTLY ONCE — serial
  // ============================================================

  @IsTest
  static void testResumeSerialReentersOnce() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  // ============================================================
  // 6. RESUME PARALLEL — completed branches not re-run
  // ============================================================

  @IsTest
  static void testResumeParallelCompletedBranchNotRerun() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
      new WorkflowOrchestrator(inst.Id, 'WorkflowPauseTest.BranchB')
        .execute(null);
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
  }

  // Regression: on resume of a mid-parallel instance, a Completed branch still
  // present in Current_Step__c must NOT get a timeout job scheduled. If it did,
  // that job would later find no active step row, match the lingering branch name
  // in Current_Step__c, and wrongly fail the whole instance "before starting".
  // Only the still-active (Pending/Running) branch should be re-armed.
  @IsTest
  static void testResumeReArmSkipsCompletedParallelBranch() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.ParallelWorkflow',
        Status__c = 'Running',
        Current_Step__c = 'WorkflowPauseTest.TimeoutBranchA,WorkflowPauseTest.TimeoutBranchB',
        Correlation_Key__c = 'ResumeParTimeout-' + Datetime.now().getTime()
      );
      insert inst;

      // TimeoutBranchA already Completed (no active step row).
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowPauseTest.TimeoutBranchA',
        Status__c = 'Completed',
        Retry_Count__c = 0
      );
      // TimeoutBranchB still Pending (active).
      Workflow_Step_Execution__c branchB = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowPauseTest.TimeoutBranchB',
        Status__c = 'Pending',
        Retry_Count__c = 0
      );
      insert branchB;

      Test.startTest();
      // Exercise the re-arm path directly so only its scheduling/re-stamp runs.
      WorkflowTimeoutReArm.reArmTimeoutsForResume(
        new List<Workflow_Instance__c>{ inst }
      );

      String aJob = 'Timeout_' + inst.Id + '_WorkflowPauseTest_TimeoutBranchA';
      String bJob = 'Timeout_' + inst.Id + '_WorkflowPauseTest_TimeoutBranchB';
      Integer aTriggers = [
        SELECT COUNT()
        FROM CronTrigger
        WHERE CronJobDetail.Name = :aJob
      ];
      Integer bTriggers = [
        SELECT COUNT()
        FROM CronTrigger
        WHERE CronJobDetail.Name = :bJob
      ];
      Test.stopTest();

      System.assertEquals(
        0,
        aTriggers,
        'Completed branch must NOT get a timeout job scheduled on resume'
      );
      System.assertEquals(
        1,
        bTriggers,
        'Active (Pending) branch must get its timeout re-armed on resume'
      );

      // Only the active branch's watchdog deadline is (re)stamped.
      Workflow_Step_Execution__c bAfter = [
        SELECT Timeout_At__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :branchB.Id
      ];
      System.assertNotEquals(
        null,
        bAfter.Timeout_At__c,
        'Active branch should have a fresh Timeout_At__c after re-arm'
      );
    }
  }
}
