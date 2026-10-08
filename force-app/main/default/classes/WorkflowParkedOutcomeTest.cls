/**
 * @description Tests for wait outcomes that finish after an instance parks
 * (issue #240). Written first (RED). A wait outcome must keep a
 * `DefinitionChanged` or `Paused` park. Release, pause resume and hold release
 * must keep a timer that the step recorded during the park.
 */
@IsTest
public class WorkflowParkedOutcomeTest {
  private static final String WF = 'WorkflowParkedOutcomeTest.ParkWorkflow';
  private static final String STEP = 'WorkflowParkedOutcomeTest.ParkStep';
  private static final String STEP_B = 'WorkflowParkedOutcomeTest.ParkStepB';
  private static final String CHILD_WF = 'WorkflowEngineMocksATest.ChildWorkflow';
  private static final List<String> PARKS = new List<String>{
    'DefinitionChanged',
    'Paused',
    'Held'
  };

  /** @description Two-step definition for the release tests. */
  public class ParkWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the step list.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ STEP, STEP_B };
    }
    /**
     * @description Returns the first step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return STEP;
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

  private static Workflow_Instance__c newInstance(
    String status,
    Datetime sleepUntil
  ) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = status,
      Current_Step__c = STEP,
      Sleep_Until__c = sleepUntil,
      Correlation_Key__c = 'Parked-' + Crypto.getRandomInteger()
    );
    insert inst;
    return inst;
  }

  private static Workflow_Step_Execution__c newStepExec(Id instanceId) {
    Workflow_Step_Execution__c exec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = STEP,
      Status__c = 'Running',
      Retry_Count__c = 0
    );
    insert exec;
    return exec;
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
    outcome.isParallel = false;
    return outcome;
  }

  // A Datetime field keeps whole seconds. The test value has no milliseconds.
  private static Datetime futureWake() {
    return Datetime.newInstance(
      (Datetime.now().addHours(1).getTime() / 1000) * 1000
    );
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
        Held_At__c,
        Parked_At__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
  }

  // A signal in the Received state, with a set creation time.
  private static void newSignal(Workflow_Instance__c inst, Datetime created) {
    Workflow_Signal__c sig = new Workflow_Signal__c(
      Workflow_Instance__c = inst.Id,
      Correlation_Key__c = inst.Correlation_Key__c,
      Signal_Name__c = 'Go',
      Status__c = 'Received'
    );
    insert sig;
    Test.setCreatedDate(sig.Id, created);
  }

  private static Workflow_Instance__c parkedWithStamp(
    String status,
    Datetime parkedAt
  ) {
    Workflow_Instance__c inst = newInstance(status, futureWake());
    inst.Parked_At__c = parkedAt;
    if (status == 'Held') {
      inst.Held_At__c = parkedAt;
    }
    update inst;
    newStepExec(inst.Id);
    return inst;
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

  private static Workflow_Step_Execution__c loadExec(Id execId) {
    return [
      SELECT Status__c, Wait_Type__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :execId
    ];
  }

  // ============================================================
  // WAIT OUTCOMES KEEP THE PARK
  // ============================================================

  @IsTest
  static void testSuspendKeepsPark() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      for (String park : PARKS) {
        Workflow_Instance__c inst = newInstance(park, null);
        Workflow_Step_Execution__c exec = newStepExec(inst.Id);
        WorkflowStepSuspension.handleSuspendOutcome(
          outcomeFor(inst, exec, StepResult.suspend())
        );
        System.assertEquals(park, load(inst.Id).Status__c, park + ' stays');
        System.assertEquals(
          WorkflowWaitDescriptorService.TYPE_GENERIC,
          loadExec(exec.Id).Wait_Type__c,
          'The wait is recorded'
        );
        System.assertEquals('Pending', loadExec(exec.Id).Status__c);
      }
    }
  }

  @IsTest
  static void testTimedSuspendKeepsParkAndTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      for (String park : PARKS) {
        Workflow_Instance__c inst = newInstance(park, null);
        Workflow_Step_Execution__c exec = newStepExec(inst.Id);
        WorkflowStepSuspension.handleSuspendOutcome(
          outcomeFor(inst, exec, StepResult.suspend(600, STEP_B))
        );
        Workflow_Instance__c after = load(inst.Id);
        System.assertEquals(park, after.Status__c, park + ' stays');
        System.assertNotEquals(null, after.Sleep_Until__c, 'Timer is kept');
      }
    }
  }

  @IsTest
  static void testSleepKeepsParkAndTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      for (String park : PARKS) {
        Workflow_Instance__c inst = newInstance(park, null);
        Workflow_Step_Execution__c exec = newStepExec(inst.Id);
        WorkflowStepSuspension.handleSleepOutcome(
          outcomeFor(inst, exec, StepResult.sleep(3600))
        );
        Workflow_Instance__c after = load(inst.Id);
        System.assertEquals(park, after.Status__c, park + ' stays');
        System.assert(after.Sleep_Until__c > Datetime.now(), 'Timer is kept');
        System.assertEquals('Pending', loadExec(exec.Id).Status__c);
      }
    }
  }

  @IsTest
  static void testStartChildKeepsPark() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      for (String park : PARKS) {
        Workflow_Instance__c inst = newInstance(park, null);
        Workflow_Step_Execution__c exec = newStepExec(inst.Id);
        WorkflowStepSuspension.handleStartChildOutcome(
          outcomeFor(
            inst,
            exec,
            StepResult.startChild(CHILD_WF, 'Parked-Child-' + park, 'in')
          )
        );
        System.assertEquals(park, load(inst.Id).Status__c, park + ' stays');
        System.assertEquals(
          WorkflowWaitDescriptorService.TYPE_CHILD,
          loadExec(exec.Id).Wait_Type__c,
          'The child wait is recorded'
        );
      }
    }
  }

  @IsTest
  static void testStartChildrenKeepsPark() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      for (String park : PARKS) {
        Workflow_Instance__c inst = newInstance(park, null);
        Workflow_Step_Execution__c exec = newStepExec(inst.Id);
        WorkflowStepSuspension.handleStartChildrenOutcome(
          outcomeFor(
            inst,
            exec,
            StepResult.startChildren(
              new List<StepResult.ChildRequest>{
                new StepResult.ChildRequest(
                  CHILD_WF,
                  'Parked-Kids-' + park,
                  'in'
                )
              }
            )
          )
        );
        System.assertEquals(park, load(inst.Id).Status__c, park + ' stays');
      }
    }
  }

  @IsTest
  static void testApprovalKeepsPark() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      for (String park : PARKS) {
        Workflow_Instance__c inst = newInstance(park, null);
        Workflow_Step_Execution__c exec = newStepExec(inst.Id);
        WorkflowStepSuspension.handleWaitForApprovalOutcome(
          outcomeFor(inst, exec, StepResult.waitForApproval('Gate', 'Boss'))
        );
        System.assertEquals(park, load(inst.Id).Status__c, park + ' stays');
      }
    }
  }

  @IsTest
  static void testWaitOutcomeStillSuspendsRunningInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newInstance('Running', null);
      Workflow_Step_Execution__c exec = newStepExec(inst.Id);
      WorkflowStepSuspension.handleSuspendOutcome(
        outcomeFor(inst, exec, StepResult.suspend())
      );
      System.assertEquals('Suspended', load(inst.Id).Status__c);
    }
  }

  @IsTest
  static void testParallelFailVerdictStillFailsParkedInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      for (String park : PARKS) {
        Workflow_Instance__c inst = newInstance(park, null);
        inst.Current_Step__c = STEP + ',' + STEP_B;
        update inst;
        insert new List<Workflow_Step_Execution__c>{
          new Workflow_Step_Execution__c(
            Workflow_Instance__c = inst.Id,
            Step_Name__c = STEP,
            Status__c = 'Completed',
            Retry_Count__c = 0
          ),
          new Workflow_Step_Execution__c(
            Workflow_Instance__c = inst.Id,
            Step_Name__c = STEP_B,
            Status__c = 'Failed',
            Retry_Count__c = 0
          )
        };
        WorkflowEngine.StepOutcomeContext outcome = new WorkflowEngine.StepOutcomeContext();
        outcome.instance = load(inst.Id);
        outcome.isParallel = true;
        WorkflowParallelJoin.completeParallelBranch(outcome);
        System.assertEquals(
          'Failed',
          load(inst.Id).Status__c,
          'A failed branch leaves no delivery. The instance ends.'
        );
      }
    }
  }

  // ============================================================
  // RELEASE AND RESUME KEEP THE TIMER
  // ============================================================

  @IsTest
  static void testReleaseKeepsFutureTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Datetime wake = futureWake();
      Workflow_Instance__c inst = newInstance('DefinitionChanged', wake);
      newStepExec(inst.Id);
      WorkflowDefinitionChangeService.release(inst.Id);
      Workflow_Instance__c after = load(inst.Id);
      System.assertEquals('Suspended', after.Status__c, 'Waits for the timer');
      System.assertEquals(wake, after.Sleep_Until__c, 'Timer is kept');
    }
  }

  // A timed wait can end in the park and its timer can end before release. The
  // sweep then routes the timeout fallback. Release must not run the step.
  @IsTest
  static void testReleaseKeepsElapsedTimerForSweep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newInstance(
        'DefinitionChanged',
        Datetime.now().addMinutes(-5)
      );
      newStepExec(inst.Id);
      WorkflowDefinitionChangeService.release(inst.Id);
      System.assertEquals('Suspended', load(inst.Id).Status__c);
    }
  }

  // A signal that arrives in the park stays Received. The step must read it.
  @IsTest
  static void testReleaseRunsWhenSignalArrivedInPark() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newInstance(
        'DefinitionChanged',
        futureWake()
      );
      newStepExec(inst.Id);
      insert new Workflow_Signal__c(
        Workflow_Instance__c = inst.Id,
        Correlation_Key__c = inst.Correlation_Key__c,
        Signal_Name__c = 'Go',
        Status__c = 'Received'
      );
      WorkflowDefinitionChangeService.release(inst.Id);
      System.assertEquals('Running', load(inst.Id).Status__c);
    }
  }

  @IsTest
  static void testPauseResumeRunsWhenSignalArrivedInPark() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newInstance('Paused', futureWake());
      newStepExec(inst.Id);
      insert new Workflow_Signal__c(
        Workflow_Instance__c = inst.Id,
        Correlation_Key__c = inst.Correlation_Key__c,
        Signal_Name__c = 'Go',
        Status__c = 'Received'
      );
      WorkflowPauseGate.resumeDefinition(WF);
      System.assertEquals('Running', load(inst.Id).Status__c);
    }
  }

  // The sweep cannot start a worker per branch. Release drives the branches.
  @IsTest
  static void testReleaseParallelRunsBranches() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newInstance(
        'DefinitionChanged',
        futureWake()
      );
      inst.Current_Step__c = STEP + ',' + STEP_B;
      update inst;
      newStepExec(inst.Id);
      WorkflowDefinitionChangeService.release(inst.Id);
      System.assertEquals('Running', load(inst.Id).Status__c);
    }
  }

  @IsTest
  static void testReleaseWithoutTimerRuns() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newInstance('DefinitionChanged', null);
      newStepExec(inst.Id);
      WorkflowDefinitionChangeService.release(inst.Id);
      System.assertEquals('Running', load(inst.Id).Status__c);
    }
  }

  @IsTest
  static void testPauseResumeKeepsFutureTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Datetime wake = futureWake();
      Workflow_Instance__c sleeping = newInstance('Paused', wake);
      Workflow_Instance__c plain = newInstance('Paused', null);
      newStepExec(sleeping.Id);
      newStepExec(plain.Id);
      WorkflowPauseGate.resumeDefinition(WF);
      System.assertEquals('Suspended', load(sleeping.Id).Status__c);
      System.assertEquals(wake, load(sleeping.Id).Sleep_Until__c);
      System.assertEquals('Running', load(plain.Id).Status__c);
    }
  }

  @IsTest
  static void testPauseResumeKeepsElapsedTimerForSweep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = newInstance(
        'Paused',
        Datetime.now().addMinutes(-5)
      );
      newStepExec(inst.Id);
      WorkflowPauseGate.resumeDefinition(WF);
      System.assertEquals('Suspended', load(inst.Id).Status__c);
    }
  }

  @IsTest
  static void testHoldReleaseKeepsFutureTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Datetime wake = futureWake();
      Workflow_Instance__c inst = newInstance('Held', wake);
      inst.Held_At__c = Datetime.now();
      update inst;
      newStepExec(inst.Id);
      WorkflowInstanceHold.release(inst.Id);
      Workflow_Instance__c after = load(inst.Id);
      System.assertEquals('Suspended', after.Status__c);
      System.assertEquals(wake, after.Sleep_Until__c);
      System.assertEquals(null, after.Held_At__c, 'The hold is gone');
    }
  }

  // ============================================================
  // ONLY A SIGNAL FROM THE PARK OVERRIDES THE TIMER (#311)
  // ============================================================

  // A signal that arrived before the park is old. The timer still rules.
  @IsTest
  static void testOldSignalDoesNotOverrideTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      for (String park : PARKS) {
        Workflow_Instance__c inst = parkedWithStamp(
          park,
          Datetime.now().addMinutes(-1)
        );
        newSignal(inst, Datetime.now().addMinutes(-10));
        releaseFrom(park, inst.Id);
        System.assertEquals(
          'Suspended',
          load(inst.Id).Status__c,
          park + ': an old signal must not end the wait'
        );
      }
    }
  }

  @IsTest
  static void testSignalFromParkOverridesTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      for (String park : PARKS) {
        Workflow_Instance__c inst = parkedWithStamp(
          park,
          Datetime.now().addMinutes(-10)
        );
        newSignal(inst, Datetime.now().addMinutes(-1));
        releaseFrom(park, inst.Id);
        System.assertEquals(
          'Running',
          load(inst.Id).Status__c,
          park + ': a signal from the park must run the step'
        );
      }
    }
  }

  // One old and one new signal: the new one decides.
  @IsTest
  static void testNewestSignalDecides() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = parkedWithStamp(
        'DefinitionChanged',
        Datetime.now().addMinutes(-5)
      );
      newSignal(inst, Datetime.now().addMinutes(-20));
      newSignal(inst, Datetime.now().addMinutes(-1));
      WorkflowDefinitionChangeService.release(inst.Id);
      System.assertEquals('Running', load(inst.Id).Status__c);
    }
  }

  // An instance that parked before the field existed has no stamp. Any
  // Received signal wins, as before.
  @IsTest
  static void testBlankStampKeepsOldRule() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = parkedWithStamp('DefinitionChanged', null);
      newSignal(inst, Datetime.now().addMinutes(-10));
      WorkflowDefinitionChangeService.release(inst.Id);
      System.assertEquals('Running', load(inst.Id).Status__c);
    }
  }

  @IsTest
  static void testLeavingParkClearsStamp() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      for (String park : PARKS) {
        Workflow_Instance__c inst = parkedWithStamp(park, Datetime.now());
        releaseFrom(park, inst.Id);
        System.assertEquals(null, load(inst.Id).Parked_At__c, park);
      }
    }
  }

  // ============================================================
  // THE PARK GATES STAMP THE PARK TIME (#311)
  // ============================================================

  @IsTest
  static void testPausePark_stampsParkTime() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPauseGate.pauseDefinition(WF, 'test');
      Workflow_Instance__c inst = newInstance('Running', null);
      Datetime before = Datetime.now().addSeconds(-1);
      System.assert(WorkflowStepAdmission.parkIfPaused(load(inst.Id)));
      Datetime stamp = load(inst.Id).Parked_At__c;
      System.assertNotEquals(null, stamp, 'The pause park sets the time');
      System.assert(stamp >= before);
    }
  }

  @IsTest
  static void testHoldPark_stampsParkTime() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = newInstance('Running', null);
      inst.Held_At__c = Datetime.now();
      update inst;
      Workflow_Instance__c loaded = [
        SELECT Id, Status__c, Workflow_Name__c, Held__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assert(WorkflowInstanceHoldGate.parkIfHeld(loaded));
      Workflow_Instance__c after = load(inst.Id);
      System.assertEquals('Held', after.Status__c);
      System.assertNotEquals(null, after.Parked_At__c, 'The hold park sets it');
    }
  }

  @IsTest
  static void testDefinitionPark_stampsParkTime() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = newInstance('Running', null);
      inst.Definition_Fingerprint__c = WorkflowDefinitionFingerprint.compute(
        new List<String>{ 'OldStep' }
      );
      update inst;
      Workflow_Instance__c loaded = [
        SELECT
          Id,
          Status__c,
          Workflow_Name__c,
          Current_Step__c,
          Definition_Fingerprint__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assert(WorkflowDefinitionChangeGate.parkIfChanged(loaded));
      Workflow_Instance__c after = load(inst.Id);
      System.assertEquals('DefinitionChanged', after.Status__c);
      System.assertNotEquals(null, after.Parked_At__c, 'The gate sets it');
    }
  }

  // ============================================================
  // PAUSE PARK CLEARS THE OLD TIMER
  // ============================================================

  @IsTest
  static void testPausePark_clearsOldTimer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPauseGate.pauseDefinition(WF, 'test');
      Workflow_Instance__c inst = newInstance(
        'Suspended',
        Datetime.now().addHours(1)
      );
      System.assert(WorkflowStepAdmission.parkIfPaused(load(inst.Id)));
      Workflow_Instance__c after = load(inst.Id);
      System.assertEquals('Paused', after.Status__c);
      System.assertEquals(
        null,
        after.Sleep_Until__c,
        'An old timer must not look like a wait recorded in the park'
      );
    }
  }

  // A delivery with an old status must not clear a timer that a wait stored
  // after the row became Paused.
  @IsTest
  static void testPausePark_keepsTimerWhenRowAlreadyPaused() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPauseGate.pauseDefinition(WF, 'test');
      Datetime wake = futureWake();
      Workflow_Instance__c inst = newInstance('Paused', wake);
      Workflow_Instance__c stale = load(inst.Id);
      stale.Status__c = 'Suspended';
      System.assert(WorkflowStepAdmission.parkIfPaused(stale));
      System.assertEquals(wake, load(inst.Id).Sleep_Until__c);
    }
  }
}
