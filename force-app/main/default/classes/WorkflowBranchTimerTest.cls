/**
 * @description Tests for the timer of each parallel branch (issue #311).
 * A sleep or a timed wait records `Wake_At__c` on its
 * step row. Release, resume and hold release keep that deadline for a
 * parallel branch. The sleep sweep starts a due branch by name.
 */
@IsTest
public class WorkflowBranchTimerTest {
  private static final String WF = 'WorkflowParkedOutcomeTest.ParkWorkflow';
  private static final String STEP_A = 'WorkflowParkedOutcomeTest.ParkStep';
  private static final String STEP_B = 'WorkflowParkedOutcomeTest.ParkStepB';
  private static final List<String> PARKS = new List<String>{
    'DefinitionChanged',
    'Paused',
    'Held'
  };

  // A Datetime field keeps whole seconds. The test value has no milliseconds.
  private static Datetime at(Integer minutes) {
    return Datetime.newInstance(
      (Datetime.now().addMinutes(minutes).getTime() / 1000) * 1000
    );
  }

  private static Workflow_Instance__c newParallel(String status) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = status,
      Current_Step__c = STEP_A + ',' + STEP_B,
      Correlation_Key__c = 'Branch-' + Crypto.getRandomInteger()
    );
    insert inst;
    if (status == 'Held') {
      inst.Held_At__c = Datetime.now();
      update inst;
    }
    return inst;
  }

  private static Workflow_Step_Execution__c newBranch(
    Id instanceId,
    String step,
    Datetime wake
  ) {
    Workflow_Step_Execution__c exec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = step,
      Status__c = 'Pending',
      Retry_Count__c = 0,
      Wake_At__c = wake
    );
    insert exec;
    return exec;
  }

  private static Workflow_Instance__c load(Id instanceId) {
    return [
      SELECT
        Id,
        Status__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Current_Step__c,
        Sleep_Until__c,
        Parked_At__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
  }

  // The pause drain has its own record of the branches it starts.
  private static Boolean enqueued(Id instanceId, String step) {
    return WorkflowResumeEnqueue.enqueuedBranchKeys.contains(
        instanceId + '::' + step
      ) ||
      WorkflowPauseResumeDrainer.dispatchedInTest.contains(
        instanceId + '|' + step
      );
  }

  private static void releaseFrom(String park, Id instanceId) {
    if (park == 'DefinitionChanged') {
      WorkflowDefinitionChangeService.release(instanceId);
    } else if (park == 'Held') {
      WorkflowInstanceHold.release(instanceId);
    } else {
      WorkflowPauseGate.resumeDefinition(WF);
    }
  }

  private static WorkflowEngine.StepOutcomeContext outcomeFor(
    Workflow_Instance__c inst,
    Workflow_Step_Execution__c exec,
    StepResult result
  ) {
    WorkflowEngine.StepOutcomeContext outcome = new WorkflowEngine.StepOutcomeContext();
    outcome.instance = load(inst.Id);
    outcome.stepExec = exec;
    outcome.result = result;
    outcome.isParallel = true;
    return outcome;
  }

  // ============================================================
  // THE HANDLERS RECORD THE TIMER OF THE BRANCH
  // ============================================================

  @IsTest
  static void testSleepRecordsWake() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Running');
      Workflow_Step_Execution__c exec = newBranch(inst.Id, STEP_A, null);
      WorkflowStepSuspension.handleSleepOutcome(
        outcomeFor(inst, exec, StepResult.sleep(3600))
      );
      Workflow_Step_Execution__c after = [
        SELECT Wake_At__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :exec.Id
      ];
      System.assertNotEquals(null, after.Wake_At__c, 'Sleep sets the timer');
      System.assertEquals(
        load(inst.Id).Sleep_Until__c,
        after.Wake_At__c,
        'Row and instance share the deadline'
      );
    }
  }

  @IsTest
  static void testTimedSuspendAndApprovalRecordWake() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Running');
      Workflow_Step_Execution__c suspended = newBranch(inst.Id, STEP_A, null);
      WorkflowStepSuspension.handleSuspendOutcome(
        outcomeFor(inst, suspended, StepResult.suspend(600, STEP_B))
      );
      System.assertNotEquals(null, wakeOf(suspended.Id), 'Timed suspend');
      Workflow_Step_Execution__c approval = newBranch(inst.Id, STEP_B, null);
      WorkflowStepSuspension.handleWaitForApprovalOutcome(
        outcomeFor(
          inst,
          approval,
          StepResult.waitForApproval('k', 'r').withApprovalTimeout(600, STEP_A)
        )
      );
      System.assertNotEquals(null, wakeOf(approval.Id), 'Timed approval');
    }
  }

  // A wait without a timer must drop an old deadline of the same row.
  @IsTest
  static void testUntimedWaitClearsWake() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Running');
      Workflow_Step_Execution__c exec = newBranch(inst.Id, STEP_A, at(30));
      WorkflowStepSuspension.handleSuspendOutcome(
        outcomeFor(inst, exec, StepResult.suspend())
      );
      System.assertEquals(null, wakeOf(exec.Id));
    }
  }

  private static Datetime wakeOf(Id execId) {
    return [
      SELECT Wake_At__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :execId
    ]
    .Wake_At__c;
  }

  // A branch that starts again must drop its old deadline. If not, a later
  // release waits for a timer that no longer applies.
  @IsTest
  static void testStepStartClearsWake() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = newParallel('Running');
      Workflow_Step_Execution__c exec = newBranch(inst.Id, STEP_A, at(30));
      WorkflowStepRunner.RunStepContext ctx = new WorkflowStepRunner.RunStepContext();
      ctx.instanceId = inst.Id;
      ctx.stepName = STEP_A;
      ctx.activeStepName = STEP_A;
      System.assertEquals(
        false,
        WorkflowStepExecLock.acquireStepExecutionLog(ctx)
      );
      update as system ctx.stepExec;
      System.assertEquals(null, wakeOf(exec.Id));
      System.assertEquals(
        'Running',
        [
          SELECT Status__c
          FROM Workflow_Step_Execution__c
          WHERE Id = :exec.Id
        ]
        .Status__c
      );
    }
  }

  // ============================================================
  // RELEASE KEEPS THE DEADLINE OF A SLEEPING BRANCH
  // ============================================================

  // Branch A sleeps. Branch B has no timer. B runs. A keeps its deadline.
  @IsTest
  static void testReleaseRunsOnlyTheBranchWithoutTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      for (String park : PARKS) {
        Workflow_Instance__c inst = newParallel(park);
        Datetime wake = at(45);
        newBranch(inst.Id, STEP_A, wake);
        newBranch(inst.Id, STEP_B, null);
        releaseFrom(park, inst.Id);
        Workflow_Instance__c after = load(inst.Id);
        System.assertEquals('Suspended', after.Status__c, park);
        System.assertEquals(wake, after.Sleep_Until__c, park + ': deadline');
        System.assertEquals(false, enqueued(inst.Id, STEP_A), park + ': A');
        System.assertEquals(true, enqueued(inst.Id, STEP_B), park + ': B');
      }
    }
  }

  // The park cleared Sleep_Until__c. The row timer still holds the deadline.
  @IsTest
  static void testReleaseRestoresClearedInstanceTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('DefinitionChanged');
      Datetime wake = at(45);
      newBranch(inst.Id, STEP_A, wake);
      newBranch(inst.Id, STEP_B, null);
      System.assertEquals(null, load(inst.Id).Sleep_Until__c);
      WorkflowDefinitionChangeService.release(inst.Id);
      System.assertEquals(wake, load(inst.Id).Sleep_Until__c);
    }
  }

  // Two branches sleep. The instance keeps the first deadline.
  @IsTest
  static void testReleaseKeepsFirstDeadline() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('DefinitionChanged');
      Datetime first = at(20);
      newBranch(inst.Id, STEP_A, at(50));
      newBranch(inst.Id, STEP_B, first);
      WorkflowDefinitionChangeService.release(inst.Id);
      Workflow_Instance__c after = load(inst.Id);
      System.assertEquals('Suspended', after.Status__c);
      System.assertEquals(first, after.Sleep_Until__c);
      System.assertEquals(false, enqueued(inst.Id, STEP_A));
      System.assertEquals(false, enqueued(inst.Id, STEP_B));
    }
  }

  // A deadline in the past does not hold the branch. It runs now.
  @IsTest
  static void testReleaseRunsBranchWithElapsedDeadline() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('DefinitionChanged');
      newBranch(inst.Id, STEP_A, at(-5));
      newBranch(inst.Id, STEP_B, null);
      WorkflowDefinitionChangeService.release(inst.Id);
      System.assertEquals('Running', load(inst.Id).Status__c);
      System.assertEquals(true, enqueued(inst.Id, STEP_A));
      System.assertEquals(true, enqueued(inst.Id, STEP_B));
    }
  }

  // Only a finished branch is left out. A done branch with a timer is done.
  @IsTest
  static void testReleaseIgnoresTimerOfFinishedBranch() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('DefinitionChanged');
      Workflow_Step_Execution__c done = newBranch(inst.Id, STEP_A, at(45));
      done.Status__c = 'Completed';
      update as system done;
      newBranch(inst.Id, STEP_B, null);
      WorkflowDefinitionChangeService.release(inst.Id);
      System.assertEquals('Running', load(inst.Id).Status__c);
      System.assertEquals(true, enqueued(inst.Id, STEP_B));
    }
  }

  // A signal from the park runs every open branch, as before.
  @IsTest
  static void testSignalFromParkRunsSleepingBranch() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('DefinitionChanged');
      inst.Parked_At__c = Datetime.now().addMinutes(-10);
      update inst;
      newBranch(inst.Id, STEP_A, at(45));
      newBranch(inst.Id, STEP_B, null);
      Workflow_Signal__c sig = new Workflow_Signal__c(
        Workflow_Instance__c = inst.Id,
        Correlation_Key__c = inst.Correlation_Key__c,
        Signal_Name__c = 'Go',
        Status__c = 'Received'
      );
      insert sig;
      Test.setCreatedDate(sig.Id, Datetime.now().addMinutes(-1));
      WorkflowDefinitionChangeService.release(inst.Id);
      System.assertEquals('Running', load(inst.Id).Status__c);
      System.assertEquals(true, enqueued(inst.Id, STEP_A));
      System.assertEquals(true, enqueued(inst.Id, STEP_B));
    }
  }

  // An old signal does not wake the sleeping branch.
  @IsTest
  static void testOldSignalDoesNotWakeSleepingBranch() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('DefinitionChanged');
      inst.Parked_At__c = Datetime.now().addMinutes(-1);
      update inst;
      newBranch(inst.Id, STEP_A, at(45));
      newBranch(inst.Id, STEP_B, null);
      Workflow_Signal__c sig = new Workflow_Signal__c(
        Workflow_Instance__c = inst.Id,
        Correlation_Key__c = inst.Correlation_Key__c,
        Signal_Name__c = 'Go',
        Status__c = 'Received'
      );
      insert sig;
      Test.setCreatedDate(sig.Id, Datetime.now().addMinutes(-10));
      WorkflowDefinitionChangeService.release(inst.Id);
      System.assertEquals('Suspended', load(inst.Id).Status__c);
      System.assertEquals(false, enqueued(inst.Id, STEP_A));
    }
  }

  // A parallel instance with no branch timer runs every branch, as before.
  @IsTest
  static void testReleaseWithoutBranchTimersRunsAll() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      for (String park : PARKS) {
        Workflow_Instance__c inst = newParallel(park);
        newBranch(inst.Id, STEP_A, null);
        newBranch(inst.Id, STEP_B, null);
        releaseFrom(park, inst.Id);
        System.assertEquals('Running', load(inst.Id).Status__c, park);
        System.assertEquals(true, enqueued(inst.Id, STEP_A), park);
        System.assertEquals(null, load(inst.Id).Sleep_Until__c, park);
        System.assertEquals(true, enqueued(inst.Id, STEP_B), park);
      }
    }
  }

  // ============================================================
  // THE SWEEP STARTS A DUE BRANCH BY NAME
  // ============================================================

  @IsTest
  static void testSweepStartsDueBranchAndKeepsNextWake() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Suspended');
      inst.Sleep_Until__c = at(-1);
      update inst;
      newBranch(inst.Id, STEP_A, at(-1));
      Datetime next = at(40);
      newBranch(inst.Id, STEP_B, next);
      WorkflowSleepResumeSweep.processSleepResumptions(Datetime.now());
      Workflow_Instance__c after = load(inst.Id);
      System.assertEquals(true, enqueued(inst.Id, STEP_A), 'A is due');
      System.assertEquals(false, enqueued(inst.Id, STEP_B), 'B is not due');
      System.assertEquals('Suspended', after.Status__c, 'B still sleeps');
      System.assertEquals(next, after.Sleep_Until__c, 'Next wake is kept');
      System.assertEquals(
        null,
        [
          SELECT Wake_At__c
          FROM Workflow_Step_Execution__c
          WHERE Workflow_Instance__c = :inst.Id AND Step_Name__c = :STEP_A
        ]
        .Wake_At__c,
        'The sweep claims the due timer'
      );
    }
  }

  @IsTest
  static void testSweepClearsTimerWhenNoBranchSleeps() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Suspended');
      inst.Sleep_Until__c = at(-1);
      update inst;
      newBranch(inst.Id, STEP_A, at(-1));
      newBranch(inst.Id, STEP_B, at(-2));
      WorkflowSleepResumeSweep.processSleepResumptions(Datetime.now());
      Workflow_Instance__c after = load(inst.Id);
      System.assertEquals(true, enqueued(inst.Id, STEP_A));
      System.assertEquals(true, enqueued(inst.Id, STEP_B));
      System.assertEquals('Running', after.Status__c);
      System.assertEquals(null, after.Sleep_Until__c);
    }
  }

  // A parallel instance with no branch timer keeps the old sweep result.
  @IsTest
  static void testSweepWithoutBranchTimersIsUnchanged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Suspended');
      inst.Sleep_Until__c = at(-1);
      update inst;
      newBranch(inst.Id, STEP_A, null);
      newBranch(inst.Id, STEP_B, null);
      WorkflowSleepResumeSweep.processSleepResumptions(Datetime.now());
      Workflow_Instance__c after = load(inst.Id);
      System.assertEquals('Running', after.Status__c);
      System.assertEquals(null, after.Sleep_Until__c);
      System.assertEquals(false, enqueued(inst.Id, STEP_A));
    }
  }

  // A sibling branch keeps its deadline when another branch waits with no timer.
  @IsTest
  static void testUntimedWaitKeepsSiblingDeadline() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Running');
      Datetime sibling = at(30);
      inst.Sleep_Until__c = sibling;
      update inst;
      newBranch(inst.Id, STEP_A, sibling);
      Workflow_Step_Execution__c exec = newBranch(inst.Id, STEP_B, null);
      WorkflowStepSuspension.handleSuspendOutcome(
        outcomeFor(inst, exec, StepResult.suspend())
      );
      System.assertEquals(sibling, load(inst.Id).Sleep_Until__c);
    }
  }

  // A later sleep must not push the instance timer past an earlier sibling.
  @IsTest
  static void testSleepKeepsEarlierSiblingDeadline() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Running');
      Datetime sibling = at(10);
      inst.Sleep_Until__c = sibling;
      update inst;
      newBranch(inst.Id, STEP_A, sibling);
      Workflow_Step_Execution__c exec = newBranch(inst.Id, STEP_B, null);
      WorkflowStepSuspension.handleSleepOutcome(
        outcomeFor(inst, exec, StepResult.sleep(3600))
      );
      System.assertEquals(sibling, load(inst.Id).Sleep_Until__c);
    }
  }

  // A serial instance keeps the old sweep result.
  @IsTest
  static void testSweepSerialIsUnchanged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Suspended');
      inst.Current_Step__c = STEP_A;
      inst.Sleep_Until__c = at(-1);
      update inst;
      newBranch(inst.Id, STEP_A, null);
      WorkflowSleepResumeSweep.processSleepResumptions(Datetime.now());
      Workflow_Instance__c after = load(inst.Id);
      System.assertEquals('Running', after.Status__c);
      System.assertEquals(null, after.Sleep_Until__c);
      System.assertEquals(false, enqueued(inst.Id, STEP_A));
    }
  }

  // Every park: a signal from the park runs the sleeping branch.
  @IsTest
  static void testSignalFromParkRunsSleepingBranchInEveryPark() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      for (String park : PARKS) {
        Workflow_Instance__c inst = newParallel(park);
        inst.Sleep_Until__c = at(45);
        inst.Parked_At__c = Datetime.now().addMinutes(-10);
        update inst;
        newBranch(inst.Id, STEP_A, at(45));
        newBranch(inst.Id, STEP_B, null);
        Workflow_Signal__c sig = new Workflow_Signal__c(
          Workflow_Instance__c = inst.Id,
          Correlation_Key__c = inst.Correlation_Key__c,
          Signal_Name__c = 'Go',
          Status__c = 'Received'
        );
        insert sig;
        Test.setCreatedDate(sig.Id, Datetime.now().addMinutes(-1));
        releaseFrom(park, inst.Id);
        System.assertEquals('Running', load(inst.Id).Status__c, park);
        System.assertEquals(true, enqueued(inst.Id, STEP_A), park);
      }
    }
  }

  // Every park: all open branches sleep, so no branch starts.
  @IsTest
  static void testAllBranchesSleepStartsNoWorkerInEveryPark() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      for (String park : PARKS) {
        Workflow_Instance__c inst = newParallel(park);
        newBranch(inst.Id, STEP_A, at(20));
        newBranch(inst.Id, STEP_B, at(50));
        releaseFrom(park, inst.Id);
        System.assertEquals('Suspended', load(inst.Id).Status__c, park);
        System.assertEquals(false, enqueued(inst.Id, STEP_A), park);
        System.assertEquals(false, enqueued(inst.Id, STEP_B), park);
      }
    }
  }
}
