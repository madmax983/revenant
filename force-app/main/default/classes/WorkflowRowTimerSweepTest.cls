/**
 * @description Tests for the row timer sweep (issue #335). The sweep finds a due
 * parallel branch from its own `Wake_At__c`. A run that a signal publishes
 * claims the timer. The branch read does not grow with the step history. A
 * sleeping branch has no `Timeout_At__c` until its timer ends.
 */
@IsTest
public class WorkflowRowTimerSweepTest {
  private static final String WF = 'WorkflowParkedOutcomeTest.ParkWorkflow';
  private static final String STEP_A = 'WorkflowParkedOutcomeTest.ParkStep';
  private static final String STEP_B = 'WorkflowParkedOutcomeTest.ParkStepB';
  private static final String STEP_C = 'WorkflowParkedOutcomeTest.ParkStepC';
  private static final String TIMED_WF = 'WorkflowRowTimerSweepTest.TimedWorkflow';
  private static final String TIMED_A = 'WorkflowRowTimerSweepTest.TimedStepA';
  private static final String TIMED_B = 'WorkflowRowTimerSweepTest.TimedStepB';

  /** @description Definition with the two timed steps. */
  public class TimedWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the step list.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ TIMED_A, TIMED_B };
    }
    /**
     * @description Returns the first step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return TIMED_A;
    }
    /**
     * @description Ends after the step.
     * @param current The completed step.
     * @param result The step result.
     * @return Always null.
     */
    public String getNextStep(String current, StepResult result) {
      return null;
    }
  }

  /** @description Step with a timeout. */
  public class TimedStepA implements WorkflowStep, TimeoutConfigurable {
    /**
     * @description Returns the timeout.
     * @return 600 seconds.
     */
    public Integer getTimeoutSeconds() {
      return 600;
    }
    /**
     * @description Completes at once.
     * @param context The step context.
     * @return A success result.
     */
    public StepResult execute(StepContext context) {
      return StepResult.complete(null, null);
    }
  }

  /** @description Second step with a timeout. */
  public class TimedStepB implements WorkflowStep, TimeoutConfigurable {
    /**
     * @description Returns the timeout.
     * @return 600 seconds.
     */
    public Integer getTimeoutSeconds() {
      return 600;
    }
    /**
     * @description Completes at once.
     * @param context The step context.
     * @return A success result.
     */
    public StepResult execute(StepContext context) {
      return StepResult.complete(null, null);
    }
  }

  // A Datetime field keeps whole seconds. The test value has no milliseconds.
  private static Datetime at(Integer minutes) {
    return Datetime.newInstance(
      (Datetime.now().addMinutes(minutes).getTime() / 1000) * 1000
    );
  }

  private static Workflow_Instance__c newParallel(
    String status,
    String workflow,
    String steps
  ) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = workflow,
      Status__c = status,
      Current_Step__c = steps,
      Correlation_Key__c = 'RowTimer-' + Crypto.getRandomInteger()
    );
    insert inst;
    return inst;
  }

  private static Workflow_Instance__c newParallel(String status) {
    return newParallel(status, WF, STEP_A + ',' + STEP_B);
  }

  private static Workflow_Step_Execution__c newRow(
    Id instanceId,
    String step,
    String status,
    Datetime wake
  ) {
    Workflow_Step_Execution__c exec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = step,
      Status__c = status,
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

  private static Workflow_Step_Execution__c rowOf(Id instanceId, String step) {
    return [
      SELECT Id, Wake_At__c, Timeout_At__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Step_Name__c = :step
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
  }

  private static Boolean enqueued(Id instanceId, String step) {
    return WorkflowResumeEnqueue.enqueuedBranchKeys.contains(
        instanceId + '::' + step
      ) ||
      WorkflowPauseResumeDrainer.dispatchedInTest.contains(
        instanceId + '|' + step
      );
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
  // THE SWEEP SELECTS BY THE TIMER OF THE BRANCH
  // ============================================================

  // Branch B is due while branch A runs. A then sleeps for longer. The instance
  // timer moves to the deadline of A. B must still start.
  @IsTest
  static void testDueSiblingIsNotReplacedByLaterWait() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Running');
      inst.Sleep_Until__c = at(-5);
      update inst;
      newRow(inst.Id, STEP_B, 'Pending', at(-5));
      Workflow_Step_Execution__c own = newRow(inst.Id, STEP_A, 'Running', null);
      WorkflowStepSuspension.handleSleepOutcome(
        outcomeFor(inst, own, StepResult.sleep(3600))
      );
      System.assertNotEquals(
        null,
        load(inst.Id).Sleep_Until__c,
        'The instance timer is the later deadline'
      );
      WorkflowSleepResumeSweep.processSleepResumptions(Datetime.now());
      System.assertEquals(true, enqueued(inst.Id, STEP_B), 'B is due');
      System.assertEquals(false, enqueued(inst.Id, STEP_A), 'A still sleeps');
      System.assertEquals(null, rowOf(inst.Id, STEP_B).Wake_At__c, 'B claimed');
      System.assertEquals('Suspended', load(inst.Id).Status__c);
    }
  }

  // The instance timer is blank. The row timer alone selects the instance.
  @IsTest
  static void testSweepSelectsDueRowWithBlankInstanceTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Suspended');
      newRow(inst.Id, STEP_A, 'Pending', at(-1));
      newRow(inst.Id, STEP_B, 'Pending', null);
      WorkflowSleepResumeSweep.processSleepResumptions(Datetime.now());
      System.assertEquals(true, enqueued(inst.Id, STEP_A), 'A is due');
      System.assertEquals(false, enqueued(inst.Id, STEP_B), 'B has no timer');
    }
  }

  // A future instance timer does not hide a due row timer.
  @IsTest
  static void testSweepSelectsDueRowWithFutureInstanceTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Suspended');
      Datetime later = at(60);
      inst.Sleep_Until__c = later;
      update inst;
      newRow(inst.Id, STEP_A, 'Pending', at(-1));
      newRow(inst.Id, STEP_B, 'Pending', later);
      WorkflowSleepResumeSweep.processSleepResumptions(Datetime.now());
      System.assertEquals(true, enqueued(inst.Id, STEP_A));
      System.assertEquals(false, enqueued(inst.Id, STEP_B));
      System.assertEquals(later, load(inst.Id).Sleep_Until__c);
    }
  }

  // A serial instance keeps `Sleep_Until__c`. A stale row timer does not wake it.
  @IsTest
  static void testSweepIgnoresRowTimerOfSerialInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Suspended', WF, STEP_A);
      newRow(inst.Id, STEP_A, 'Pending', at(-1));
      WorkflowSleepResumeSweep.processSleepResumptions(Datetime.now());
      System.assertEquals('Suspended', load(inst.Id).Status__c);
    }
  }

  // A row timer in the future selects nothing.
  @IsTest
  static void testSweepIgnoresFutureRowTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Suspended');
      newRow(inst.Id, STEP_A, 'Pending', at(30));
      newRow(inst.Id, STEP_B, 'Pending', null);
      WorkflowSleepResumeSweep.processSleepResumptions(Datetime.now());
      System.assertEquals('Suspended', load(inst.Id).Status__c);
      System.assertEquals(false, enqueued(inst.Id, STEP_A));
    }
  }

  // ============================================================
  // IN-FLIGHT SLEEP FROM BEFORE THE UPGRADE
  // ============================================================

  // The branch has no row timer. The instance timer is due. The sweep runs the
  // Pending branches that have no timer, wait type or retry mark, by name.
  @IsTest
  static void testDueInstanceTimerWithoutRowTimerRunsUntimedBranches() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Suspended');
      inst.Sleep_Until__c = at(30);
      update inst;
      newRow(inst.Id, STEP_A, 'Pending', null);
      newRow(inst.Id, STEP_B, 'Pending', null);
      WorkflowSleepResumeSweep.processSleepResumptions(at(60));
      System.assertEquals('Running', load(inst.Id).Status__c);
      System.assertEquals(true, enqueued(inst.Id, STEP_A));
      System.assertEquals(true, enqueued(inst.Id, STEP_B));
    }
  }

  // A branch that waits for a signal, or retries after a lock, is not a sleeper.
  @IsTest
  static void testFallbackRunsOnlyUntimedSleepers() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel(
        'Suspended',
        WF,
        STEP_A + ',' + STEP_B + ',' + STEP_C
      );
      inst.Sleep_Until__c = at(30);
      update inst;
      newRow(inst.Id, STEP_A, 'Pending', null);
      Workflow_Step_Execution__c signalWait = newRow(
        inst.Id,
        STEP_B,
        'Pending',
        null
      );
      signalWait.Wait_Type__c = WorkflowWaitDescriptorService.TYPE_GENERIC;
      update signalWait;
      Workflow_Step_Execution__c lockRetry = newRow(
        inst.Id,
        STEP_C,
        'Pending',
        null
      );
      lockRetry.Transient_Retry_Count__c = 1;
      update lockRetry;
      WorkflowSleepResumeSweep.processSleepResumptions(at(60));
      System.assertEquals(true, enqueued(inst.Id, STEP_A), 'A may sleep');
      System.assertEquals(
        false,
        enqueued(inst.Id, STEP_B),
        'B waits for a signal'
      );
      System.assertEquals(
        false,
        enqueued(inst.Id, STEP_C),
        'C has its own retry'
      );
    }
  }

  // The fallback does not apply while a branch still has a timer.
  @IsTest
  static void testFallbackWaitsWhileABranchTimerRemains() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Suspended');
      inst.Sleep_Until__c = at(-1);
      update inst;
      newRow(inst.Id, STEP_A, 'Pending', at(40));
      newRow(inst.Id, STEP_B, 'Pending', null);
      WorkflowSleepResumeSweep.processSleepResumptions(Datetime.now());
      System.assertEquals('Suspended', load(inst.Id).Status__c);
      System.assertEquals(false, enqueued(inst.Id, STEP_A));
      System.assertEquals(false, enqueued(inst.Id, STEP_B));
    }
  }

  // ============================================================
  // A SIGNAL WAKE CLAIMS THE TIMER
  // ============================================================

  // A signal wakes the sleeping branch A. A park starts before the worker runs.
  // The release must not treat A as asleep.
  @IsTest
  static void testSignalWakeClaimsTimerBeforeAPark() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Suspended');
      newRow(inst.Id, STEP_A, 'Pending', at(45));
      newRow(inst.Id, STEP_B, 'Pending', null);
      WorkflowBranchResume.enqueueResumeBulk(
        new List<Workflow_Instance__c>{ load(inst.Id) }
      );
      System.assertEquals(true, enqueued(inst.Id, STEP_A), 'Signal wakes A');
      System.assertEquals(null, rowOf(inst.Id, STEP_A).Wake_At__c, 'Claimed');
      // The worker exits at the park. Then the park is released.
      WorkflowResumeEnqueue.enqueuedBranchKeys.clear();
      WorkflowPauseResumeDrainer.dispatchedInTest.clear();
      Workflow_Instance__c parked = load(inst.Id);
      parked.Status__c = 'DefinitionChanged';
      update parked;
      WorkflowDefinitionChangeService.release(inst.Id);
      System.assertEquals('Running', load(inst.Id).Status__c);
      System.assertEquals(true, enqueued(inst.Id, STEP_A), 'A runs at release');
    }
  }

  // A branch that the signal did not run keeps its timer.
  @IsTest
  static void testSkippedBranchKeepsTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('DefinitionChanged');
      Datetime wake = at(45);
      newRow(inst.Id, STEP_A, 'Pending', wake);
      newRow(inst.Id, STEP_B, 'Pending', null);
      WorkflowDefinitionChangeService.release(inst.Id);
      System.assertEquals(false, enqueued(inst.Id, STEP_A));
      System.assertEquals(wake, rowOf(inst.Id, STEP_A).Wake_At__c);
    }
  }

  // A release also claims an elapsed timer that it runs.
  @IsTest
  static void testReleaseClaimsElapsedTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('DefinitionChanged');
      newRow(inst.Id, STEP_A, 'Pending', at(-5));
      newRow(inst.Id, STEP_B, 'Pending', null);
      WorkflowDefinitionChangeService.release(inst.Id);
      System.assertEquals(true, enqueued(inst.Id, STEP_A));
      System.assertEquals(null, rowOf(inst.Id, STEP_A).Wake_At__c);
    }
  }

  // ============================================================
  // THE BRANCH READ DOES NOT GROW WITH THE HISTORY
  // ============================================================

  private static Workflow_Instance__c withLongHistory(String status) {
    Workflow_Instance__c inst = newParallel(status);
    List<Workflow_Step_Execution__c> old = new List<Workflow_Step_Execution__c>();
    for (Integer i = 0; i < 300; i++) {
      old.add(
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst.Id,
          Step_Name__c = STEP_A,
          Status__c = 'Completed',
          Retry_Count__c = 0
        )
      );
    }
    insert old;
    newRow(inst.Id, STEP_A, 'Pending', at(45));
    newRow(inst.Id, STEP_B, 'Pending', null);
    return inst;
  }

  @IsTest
  static void testSignalWakeReadIsBounded() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = withLongHistory('Suspended');
      Workflow_Instance__c current = load(inst.Id);
      Integer before = Limits.getQueryRows();
      WorkflowBranchResume.enqueueResumeBulk(
        new List<Workflow_Instance__c>{ current }
      );
      System.assert(
        Limits.getQueryRows() - before < 50,
        'Rows read: ' + (Limits.getQueryRows() - before)
      );
      System.assertEquals(true, enqueued(inst.Id, STEP_A));
      System.assertEquals(true, enqueued(inst.Id, STEP_B));
    }
  }

  @IsTest
  static void testSettleReadIsBounded() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = withLongHistory('DefinitionChanged');
      Workflow_Instance__c current = load(inst.Id);
      Integer before = Limits.getQueryRows();
      WorkflowParkedTimer.settleAll(new List<Workflow_Instance__c>{ current });
      System.assert(
        Limits.getQueryRows() - before < 50,
        'Rows read: ' + (Limits.getQueryRows() - before)
      );
      System.assertEquals('Suspended', current.Status__c, 'A sleeps');
    }
  }

  @IsTest
  static void testPauseDrainReadIsBounded() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = withLongHistory('Paused');
      Integer before = Limits.getQueryRows();
      WorkflowPauseGate.resumeDefinition(WF);
      System.assert(
        Limits.getQueryRows() - before < 150,
        'Rows read: ' + (Limits.getQueryRows() - before)
      );
      System.assertEquals(true, enqueued(inst.Id, STEP_B));
    }
  }

  // ============================================================
  // WHICH BRANCHES ARE OPEN
  // ============================================================

  // A branch that ran again is open. A finished branch is not. A branch with no
  // row yet is open.
  @IsTest
  static void testSignalWakeRunsLoopingAndNewBranchesOnly() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel(
        'Suspended',
        WF,
        STEP_A + ',' + STEP_B + ',' + STEP_C
      );
      newRow(inst.Id, STEP_A, 'Completed', null);
      newRow(inst.Id, STEP_A, 'Pending', null);
      newRow(inst.Id, STEP_B, 'Completed', null);
      WorkflowBranchResume.enqueueResumeBulk(
        new List<Workflow_Instance__c>{ load(inst.Id) }
      );
      System.assertEquals(true, enqueued(inst.Id, STEP_A), 'A ran again');
      System.assertEquals(false, enqueued(inst.Id, STEP_B), 'B is done');
      System.assertEquals(true, enqueued(inst.Id, STEP_C), 'C has no row');
    }
  }

  // ============================================================
  // A SLEEPING BRANCH HAS NO TIMEOUT UNTIL ITS TIMER ENDS
  // ============================================================

  @IsTest
  static void testReleaseDoesNotArmSleepingBranch() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel(
        'Paused',
        TIMED_WF,
        TIMED_A + ',' + TIMED_B
      );
      newRow(inst.Id, TIMED_A, 'Pending', at(45));
      newRow(inst.Id, TIMED_B, 'Pending', null);
      WorkflowPauseGate.resumeDefinition(TIMED_WF);
      System.assertEquals(
        null,
        rowOf(inst.Id, TIMED_A).Timeout_At__c,
        'A sleeps'
      );
      System.assertNotEquals(
        null,
        rowOf(inst.Id, TIMED_B).Timeout_At__c,
        'B starts now'
      );
    }
  }

  @IsTest
  static void testSweepArmsBranchWhenTimerWakesIt() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel(
        'Suspended',
        TIMED_WF,
        TIMED_A + ',' + TIMED_B
      );
      newRow(inst.Id, TIMED_A, 'Pending', at(-1));
      newRow(inst.Id, TIMED_B, 'Pending', at(40));
      WorkflowSleepResumeSweep.processSleepResumptions(Datetime.now());
      Workflow_Step_Execution__c woken = rowOf(inst.Id, TIMED_A);
      System.assertEquals(null, woken.Wake_At__c, 'Claimed');
      System.assertNotEquals(null, woken.Timeout_At__c, 'Armed');
      System.assertEquals(
        null,
        rowOf(inst.Id, TIMED_B).Timeout_At__c,
        'B still sleeps'
      );
    }
  }

  // The finished-branch read is bounded too. Branch A has a long history and
  // no active row, so the grouped query runs.
  @IsTest
  static void testFinishedBranchReadIsBounded() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Suspended');
      List<Workflow_Step_Execution__c> old = new List<Workflow_Step_Execution__c>();
      for (Integer i = 0; i < 300; i++) {
        old.add(
          new Workflow_Step_Execution__c(
            Workflow_Instance__c = inst.Id,
            Step_Name__c = STEP_A,
            Status__c = 'Completed',
            Retry_Count__c = 0
          )
        );
      }
      insert old;
      newRow(inst.Id, STEP_B, 'Pending', null);
      Workflow_Instance__c current = load(inst.Id);
      Integer before = Limits.getQueryRows();
      WorkflowBranchResume.enqueueResumeBulk(
        new List<Workflow_Instance__c>{ current }
      );
      System.assert(
        Limits.getQueryRows() - before < 50,
        'Rows read: ' + (Limits.getQueryRows() - before)
      );
      System.assertEquals(false, enqueued(inst.Id, STEP_A), 'A is done');
      System.assertEquals(true, enqueued(inst.Id, STEP_B));
    }
  }

  // Many instances cost the same number of queries as one.
  @IsTest
  static void testManyInstancesShareTwoQueries() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 20; i++) {
        insts.add(newParallel('Suspended'));
      }
      List<Workflow_Step_Execution__c> rows = new List<Workflow_Step_Execution__c>();
      for (Integer i = 0; i < insts.size(); i++) {
        // Even: A is done. Odd: A has no row.
        rows.add(
          new Workflow_Step_Execution__c(
            Workflow_Instance__c = insts[i].Id,
            Step_Name__c = STEP_A,
            Status__c = Math.mod(i, 2) == 0 ? 'Completed' : 'Pending',
            Retry_Count__c = 0
          )
        );
      }
      insert rows;
      Integer queries = Limits.getQueries();
      Map<Id, WorkflowBranchTimer.Branches> loaded = WorkflowBranchTimer.load(
        insts
      );
      System.assert(Limits.getQueries() - queries <= 2, 'Queries used');
      for (Integer i = 0; i < insts.size(); i++) {
        List<String> open = loaded.get(insts[i].Id).openNames;
        System.assertEquals(
          Math.mod(i, 2) == 0 ? 1 : 2,
          open.size(),
          'Open branches of instance ' + i
        );
      }
    }
  }

  // A branch whose timer ended gets its timeout at release.
  @IsTest
  static void testReleaseArmsBranchWithElapsedTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel(
        'Paused',
        TIMED_WF,
        TIMED_A + ',' + TIMED_B
      );
      newRow(inst.Id, TIMED_A, 'Pending', at(-5));
      newRow(inst.Id, TIMED_B, 'Pending', null);
      WorkflowPauseGate.resumeDefinition(TIMED_WF);
      System.assertNotEquals(null, rowOf(inst.Id, TIMED_A).Timeout_At__c);
    }
  }

  // The sleep job claims the timer and arms the timeout of a parallel branch.
  // The test does not call stopTest, so the queued worker does not run.
  @IsTest
  static void testSleepJobClaimsAndArmsBranch() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = newParallel(
        'Suspended',
        TIMED_WF,
        TIMED_A + ',' + TIMED_B
      );
      inst.Sleep_Until__c = at(-1);
      update inst;
      newRow(inst.Id, TIMED_A, 'Pending', at(-1));
      newRow(inst.Id, TIMED_B, 'Pending', at(40));
      Test.startTest();
      new WorkflowSleepJob(inst.Id, TIMED_A).execute(null);
      Workflow_Step_Execution__c woken = rowOf(inst.Id, TIMED_A);
      System.assertEquals(null, woken.Wake_At__c, 'Claimed');
      System.assertNotEquals(null, woken.Timeout_At__c, 'Armed');
      System.assertNotEquals(null, rowOf(inst.Id, TIMED_B).Wake_At__c);
    }
  }

  // A row that changed after the deadline is a branch that a run claimed or
  // started. The fallback does not run it again.
  @IsTest
  static void testFallbackSkipsRowChangedAfterDeadline() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Suspended');
      inst.Sleep_Until__c = at(-30);
      update inst;
      newRow(inst.Id, STEP_A, 'Pending', null);
      newRow(inst.Id, STEP_B, 'Pending', null);
      WorkflowSleepResumeSweep.processSleepResumptions(Datetime.now());
      System.assertEquals(false, enqueued(inst.Id, STEP_A));
      System.assertEquals(false, enqueued(inst.Id, STEP_B));
    }
  }

  // A legacy sleeper and a branch with a due row timer wake together.
  @IsTest
  static void testFallbackRunsWithTheLastDueRowTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Suspended');
      inst.Sleep_Until__c = at(30);
      update inst;
      newRow(inst.Id, STEP_A, 'Pending', null);
      newRow(inst.Id, STEP_B, 'Pending', at(40));
      WorkflowSleepResumeSweep.processSleepResumptions(at(60));
      System.assertEquals(true, enqueued(inst.Id, STEP_A), 'Legacy sleeper');
      System.assertEquals(true, enqueued(inst.Id, STEP_B), 'Due row timer');
      System.assertEquals('Running', load(inst.Id).Status__c);
    }
  }

  // A grouped query returns at most 2,000 rows. 200 instances with 11 finished
  // branches each are 2,200 groups. The read must split the query.
  @IsTest
  static void testFinishedReadSplitsLargeBatches() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<String> names = new List<String>();
      for (Integer i = 0; i < 11; i++) {
        names.add('RowTimerStep' + i);
      }
      List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 200; i++) {
        insts.add(
          new Workflow_Instance__c(
            Workflow_Name__c = WF,
            Status__c = 'Suspended',
            Current_Step__c = String.join(names, ','),
            Correlation_Key__c = 'Split-' + i
          )
        );
      }
      insert insts;
      List<Workflow_Step_Execution__c> rows = new List<Workflow_Step_Execution__c>();
      for (Workflow_Instance__c inst : insts) {
        for (String name : names) {
          rows.add(
            new Workflow_Step_Execution__c(
              Workflow_Instance__c = inst.Id,
              Step_Name__c = name,
              Status__c = 'Completed',
              Retry_Count__c = 0
            )
          );
        }
      }
      insert rows;
      Map<Id, WorkflowBranchTimer.Branches> loaded = WorkflowBranchTimer.load(
        insts
      );
      for (Workflow_Instance__c inst : insts) {
        System.assertEquals(0, loaded.get(inst.Id).openNames.size());
      }
    }
  }

  // The claims must not use the last DML rows of the transaction. A branch
  // whose claim does not fit stays asleep. Its timer stays for the sweep.
  @IsTest
  static void testClaimKeepsDmlRowsFree() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel('Suspended');
      Datetime wake = at(45);
      newRow(inst.Id, STEP_A, 'Pending', wake);
      newRow(inst.Id, STEP_B, 'Pending', null);
      WorkflowBranchTimer.claimReserve = Limits.getLimitDmlRows();
      WorkflowBranchResume.enqueueResumeBulk(
        new List<Workflow_Instance__c>{ load(inst.Id) }
      );
      System.assertEquals(false, enqueued(inst.Id, STEP_A), 'A stays asleep');
      System.assertEquals(wake, rowOf(inst.Id, STEP_A).Wake_At__c, 'Kept');
      System.assertEquals(true, enqueued(inst.Id, STEP_B), 'B has no timer');
    }
  }

  // A signal that wakes a sleeping branch arms its timeout. The release did
  // not arm it while the branch slept.
  @IsTest
  static void testSignalWakeArmsSleepingBranch() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newParallel(
        'Suspended',
        TIMED_WF,
        TIMED_A + ',' + TIMED_B
      );
      newRow(inst.Id, TIMED_A, 'Pending', at(45));
      newRow(inst.Id, TIMED_B, 'Pending', null);
      WorkflowBranchResume.enqueueResumeBulk(
        new List<Workflow_Instance__c>{ load(inst.Id) }
      );
      Workflow_Step_Execution__c woken = rowOf(inst.Id, TIMED_A);
      System.assertEquals(null, woken.Wake_At__c, 'Claimed');
      System.assertNotEquals(null, woken.Timeout_At__c, 'Armed');
    }
  }
}
