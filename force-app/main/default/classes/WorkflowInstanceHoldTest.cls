/**
 * @description Engine tests for per-instance hold and release (issue #119).
 * Written first (RED). They fail on code that has no hold gate.
 *
 * Scenarios:
 *  1. Hold parks at the next boundary. No forward step row while held.
 *  2. Release resumes from the parked step. No completed step runs again.
 *  3. A hold during a step does not stop that step.
 *  4. Siblings run. No pause state is read or written.
 *  5. Hold and release are idempotent.
 *  6. Hold rejects terminal, compensating and engine-workflow instances.
 *  7. Hold and release schedule no job.
 *  8. An awaited signal survives hold and release.
 *  9. Park statuses: signal, cancel, key, harness, parallel join, timeouts.
 * 10. Continue-As-New keeps the hold.
 */
@IsTest
public class WorkflowInstanceHoldTest {
  private static final String WF = 'WorkflowInstanceHoldTest.HoldWorkflow';
  private static final String SIGNAL_WF = 'WorkflowInstanceHoldTest.SignalWorkflow';
  private static final String SELF_WF = 'WorkflowInstanceHoldTest.SelfHoldWorkflow';
  private static final String LOOP_WF = 'WorkflowInstanceHoldTest.LoopWorkflow';
  private static final String STEP_A = 'WorkflowInstanceHoldTest.StepA';
  private static final String STEP_B = 'WorkflowInstanceHoldTest.StepB';
  private static final String STEP_C = 'WorkflowInstanceHoldTest.StepC';
  private static final String WAIT_STEP = 'WorkflowInstanceHoldTest.WaitStep';
  private static final String SELF_STEP = 'WorkflowInstanceHoldTest.SelfHoldStep';
  private static final String LOOP_STEP = 'WorkflowInstanceHoldTest.LoopStep';

  public static Integer stepARuns = 0;
  public static Integer stepBRuns = 0;
  public static Integer stepCRuns = 0;
  public static Integer loopRuns = 0;

  // ============================================================
  // MOCK WORKFLOWS
  // ============================================================

  /**
   * @description Three-step definition: A, B, C.
   */
  public class HoldWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the step list.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ STEP_A, STEP_B, STEP_C };
    }
    /**
     * @description Returns the first step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return STEP_A;
    }
    /**
     * @description Routes A to B to C.
     * @param current The completed step.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      if (current == STEP_A) {
        return STEP_B;
      }
      if (current == STEP_B) {
        return STEP_C;
      }
      return null;
    }
  }

  /**
   * @description Waits for the Go signal, then runs C.
   */
  public class SignalWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the step list.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ WAIT_STEP, STEP_C };
    }
    /**
     * @description Returns the first step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return WAIT_STEP;
    }
    /**
     * @description Routes the wait step to C.
     * @param current The completed step.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return current == WAIT_STEP ? STEP_C : null;
    }
  }

  /**
   * @description A step holds its own instance, then C runs.
   */
  public class SelfHoldWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the step list.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ SELF_STEP, STEP_C };
    }
    /**
     * @description Returns the first step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return SELF_STEP;
    }
    /**
     * @description Routes the self-hold step to C.
     * @param current The completed step.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return current == SELF_STEP ? STEP_C : null;
    }
  }

  /**
   * @description One step that holds itself and continues as new.
   */
  public class LoopWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the step list.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ LOOP_STEP };
    }
    /**
     * @description Returns the first step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return LOOP_STEP;
    }
    /**
     * @description Ends the workflow.
     * @param current The completed step.
     * @param result The step result.
     * @return Always null.
     */
    public String getNextStep(String current, StepResult result) {
      return null;
    }
  }

  /**
   * @description First step. It pushes itself on the compensation stack.
   */
  public class StepA implements CompensatableStep {
    /**
     * @description Counts the run and completes.
     * @param ctx The step context.
     * @return A COMPLETE result.
     */
    public StepResult execute(StepContext ctx) {
      stepARuns++;
      return StepResult.complete(null, 'OutA');
    }
    /**
     * @description No-op compensation.
     * @param ctx The step context.
     * @return A COMPLETE result.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  /**
   * @description Second step. It counts its runs.
   */
  public class StepB implements WorkflowStep {
    /**
     * @description Counts the run and completes.
     * @param ctx The step context.
     * @return A COMPLETE result.
     */
    public StepResult execute(StepContext ctx) {
      stepBRuns++;
      return StepResult.complete(null, 'OutB');
    }
  }

  /**
   * @description Last step. It counts its runs.
   */
  public class StepC implements WorkflowStep {
    /**
     * @description Counts the run and completes.
     * @param ctx The step context.
     * @return A COMPLETE result.
     */
    public StepResult execute(StepContext ctx) {
      stepCRuns++;
      return StepResult.complete(null, 'OutC');
    }
  }

  /**
   * @description Suspends until the Go signal arrives.
   */
  public class WaitStep implements WorkflowStep {
    /**
     * @description Completes when Go is present, else suspends.
     * @param ctx The step context.
     * @return A COMPLETE or SUSPEND result.
     */
    public StepResult execute(StepContext ctx) {
      if (!ctx.signals().getSignal('Go').isPresent()) {
        return StepResult.suspend();
      }
      return StepResult.complete(null, 'GotGo');
    }
  }

  /**
   * @description Holds its own instance while it runs, then completes.
   */
  public class SelfHoldStep implements WorkflowStep {
    /**
     * @description Places a hold, then completes.
     * @param ctx The step context.
     * @return A COMPLETE result.
     */
    public StepResult execute(StepContext ctx) {
      WorkflowInstanceHold.hold(ctx.workflowInstanceId, 'held during step');
      return StepResult.complete(null, 'OutSelf');
    }
  }

  /**
   * @description Holds its own instance, then continues as new.
   */
  public class LoopStep implements WorkflowStep {
    /**
     * @description Places a hold, then asks for a successor.
     * @param ctx The step context.
     * @return A CONTINUE_AS_NEW result.
     */
    public StepResult execute(StepContext ctx) {
      loopRuns++;
      WorkflowInstanceHold.hold(ctx.workflowInstanceId, 'loop hold');
      return StepResult.continueAsNew(null);
    }
  }

  /**
   * @description Step with a declared timeout.
   */
  public class TimedStep implements WorkflowStep, TimeoutConfigurable {
    /**
     * @description Completes.
     * @param ctx The step context.
     * @return A COMPLETE result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'OutTimed');
    }
    /**
     * @description Returns the step timeout.
     * @return 300 seconds.
     */
    public Integer getTimeoutSeconds() {
      return 300;
    }
  }

  // ============================================================
  // HELPERS
  // ============================================================

  private static String key(String prefix) {
    return 'Hold-' + prefix + '-' + Datetime.now().getTime();
  }

  // Starts WF and runs step A. The instance then waits for step B.
  private static Id startAndRunFirstHop(String correlationKey) {
    WorkflowEngine.disableQueueableInTest = true;
    Id instId = WorkflowEngine.start(WF, correlationKey, null);
    WorkflowEngine.runStep(instId);
    return instId;
  }

  private static Workflow_Instance__c load(Id instId) {
    return [
      SELECT
        Status__c,
        Current_Step__c,
        Compensation_Stack__c,
        Held__c,
        Held_At__c,
        Hold_Reason__c,
        Terminal_At__c,
        Active_Correlation_Key__c,
        Sleep_Until__c,
        Async_Job_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :instId
    ];
  }

  private static Map<Id, Workflow_Step_Execution__c> rows(Id instId) {
    return new Map<Id, Workflow_Step_Execution__c>(
      [
        SELECT Id, Step_Name__c, Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instId
      ]
    );
  }

  private static Integer completedRows(Id instId, String stepName) {
    return [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instId
        AND Step_Name__c = :stepName
        AND Status__c = 'Completed'
    ];
  }

  private static Workflow_Instance__c insertInstance(
    String workflowName,
    String status,
    String currentStep
  ) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = workflowName,
      Status__c = status,
      Current_Step__c = currentStep,
      Correlation_Key__c = key(status + '-' + Crypto.getRandomInteger())
    );
    insert inst;
    return inst;
  }

  // ============================================================
  // 1. HOLD PARKS AT THE NEXT BOUNDARY (AC 2, AC 4)
  // ============================================================

  @IsTest
  static void testHoldParksAtNextBoundaryWithNoForwardRows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(key('Park'));
      Workflow_Instance__c before = load(instId);
      Map<Id, Workflow_Step_Execution__c> rowsBefore = rows(instId);

      WorkflowInstanceHold.HoldResult held = WorkflowInstanceHold.hold(
        instId,
        'investigate'
      );
      Workflow_Instance__c afterHold = load(instId);
      // Three deliveries. The first parks. The next two are stale.
      WorkflowEngine.runStep(instId);
      WorkflowEngine.runStep(instId);
      new WorkflowOrchestrator(instId, STEP_B).execute(null);
      Test.stopTest();

      Workflow_Instance__c after = load(instId);
      System.assertEquals(
        WorkflowInstanceHold.Outcome.HELD,
        held.outcome,
        'Hold must report HELD'
      );
      System.assertEquals(
        before.Status__c,
        afterHold.Status__c,
        'Hold must not change the status before the boundary'
      );
      System.assertEquals(true, afterHold.Held__c, 'Hold is recorded');
      System.assertEquals('investigate', afterHold.Hold_Reason__c, 'Reason');
      System.assertNotEquals(null, afterHold.Held_At__c, 'Held-since');
      System.assertEquals('Held', after.Status__c, 'The gate parks it');
      System.assertEquals(0, stepBRuns, 'StepB must not run while held');
      System.assertEquals(
        rowsBefore.keySet(),
        rows(instId).keySet(),
        'No step row is written while held'
      );
      System.assertEquals(
        before.Current_Step__c,
        after.Current_Step__c,
        'Current step is kept'
      );
      System.assertEquals(
        before.Compensation_Stack__c,
        after.Compensation_Stack__c,
        'Compensation stack is kept'
      );
      System.assertEquals(null, after.Sleep_Until__c, 'Park clears sleep');
      System.assertEquals(null, after.Async_Job_Id__c, 'Park clears job id');
    }
  }

  @IsTest
  static void testHoldBeforeFirstStepParksPendingInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Test.startTest();
      Id instId = WorkflowEngine.start(WF, key('Fresh'), null);
      WorkflowInstanceHold.hold(instId, null);
      WorkflowEngine.runStep(instId);
      Test.stopTest();
      System.assertEquals('Held', load(instId).Status__c, 'Parks at start');
      System.assertEquals(0, stepARuns, 'StepA must not run while held');
    }
  }

  // ============================================================
  // 2. RELEASE RESUMES FROM THE PARKED STEP (AC 5)
  // ============================================================

  @IsTest
  static void testReleaseResumesFromParkedStepOnce() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(key('Release'));
      WorkflowInstanceHold.hold(instId, 'investigate');
      WorkflowEngine.runStep(instId);
      Map<Id, Workflow_Step_Execution__c> parkedRows = rows(instId);

      WorkflowInstanceHold.HoldResult released = WorkflowInstanceHold.release(
        instId
      );
      Workflow_Instance__c afterRelease = load(instId);
      WorkflowEngine.runStep(instId); // StepB
      WorkflowEngine.runStep(instId); // StepC
      Test.stopTest();

      System.assertEquals(
        WorkflowInstanceHold.Outcome.RELEASED,
        released.outcome,
        'Release must report RELEASED'
      );
      System.assertEquals('Running', afterRelease.Status__c, 'Release runs');
      System.assertEquals(false, afterRelease.Held__c, 'Hold is cleared');
      System.assertEquals(null, afterRelease.Hold_Reason__c, 'Reason cleared');
      System.assertEquals(null, afterRelease.Held_At__c, 'Held-since cleared');
      System.assertEquals(
        STEP_B,
        afterRelease.Current_Step__c,
        'Resumes at the parked step'
      );
      System.assertEquals('Completed', load(instId).Status__c, 'Completes');
      System.assertEquals(1, stepARuns, 'StepA never runs again');
      System.assertEquals(1, stepBRuns, 'StepB runs once');
      System.assertEquals(1, completedRows(instId, STEP_A), 'One A row');
      System.assertEquals(1, completedRows(instId, STEP_B), 'One B row');
      Map<Id, Workflow_Step_Execution__c> finalRows = rows(instId);
      for (Workflow_Step_Execution__c row : parkedRows.values()) {
        if (row.Status__c == 'Completed') {
          System.assertEquals(
            row.Output__c,
            finalRows.get(row.Id).Output__c,
            'A completed row does not change'
          );
        }
      }
    }
  }

  @IsTest
  static void testReleaseBeforeParkClearsHoldOnly() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(key('Early'));
      String statusBefore = load(instId).Status__c;
      WorkflowInstanceHold.hold(instId, 'x');
      WorkflowInstanceHold.HoldResult released = WorkflowInstanceHold.release(
        instId
      );
      Workflow_Instance__c afterRelease = load(instId);
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      System.assertEquals(
        WorkflowInstanceHold.Outcome.RELEASED,
        released.outcome,
        'A waiting hold is released'
      );
      System.assertEquals(
        statusBefore,
        afterRelease.Status__c,
        'Release before the park does not change the status'
      );
      System.assertEquals(false, afterRelease.Held__c, 'Hold is cleared');
      System.assertEquals(1, stepBRuns, 'The live chain continues');
    }
  }

  // Race: a delivery loaded the hold, then a release ran. The delivery goes on.
  @IsTest
  static void testStaleHeldDeliveryAfterReleaseContinues() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(key('Race'));
      WorkflowInstanceHold.hold(instId, 'x');
      Workflow_Instance__c stale = [
        SELECT Id, Status__c, Workflow_Name__c, Held__c
        FROM Workflow_Instance__c
        WHERE Id = :instId
      ];
      WorkflowInstanceHold.release(instId);
      Boolean stopped = WorkflowInstanceHoldGate.parkIfHeld(stale);
      Test.stopTest();
      System.assertEquals(false, stopped, 'The released delivery continues');
      System.assertEquals('Running', load(instId).Status__c, 'Not parked');
    }
  }

  @IsTest
  static void testReleaseParallelInstanceResumes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = insertInstance(
        WF,
        'Held',
        STEP_B + ',' + STEP_C
      );
      // No Test.stopTest(): the branch events would run the branches. This
      // test checks the release itself.
      WorkflowInstanceHold.HoldResult released = WorkflowInstanceHold.release(
        inst.Id
      );
      System.assertEquals(
        WorkflowInstanceHold.Outcome.RELEASED,
        released.outcome,
        'A parked parallel instance is released'
      );
      System.assertEquals('Running', load(inst.Id).Status__c, 'Running');
    }
  }

  // ============================================================
  // 3. A HOLD DURING A STEP DOES NOT STOP THAT STEP (AC 4)
  // ============================================================

  @IsTest
  static void testHoldDuringStepLetsStepFinish() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Test.startTest();
      Id instId = WorkflowEngine.start(SELF_WF, key('Mid'), null);
      WorkflowEngine.runStep(instId); // SelfHoldStep holds, then completes.
      Workflow_Instance__c afterStep = load(instId);
      WorkflowEngine.runStep(instId); // Parks before StepC.
      Test.stopTest();

      System.assertEquals(
        1,
        completedRows(instId, SELF_STEP),
        'The running step finishes'
      );
      System.assertEquals(
        true,
        afterStep.Held__c,
        'The step outcome must not overwrite the hold'
      );
      System.assertEquals(STEP_C, afterStep.Current_Step__c, 'Advances to C');
      System.assertEquals('Held', load(instId).Status__c, 'Parks before C');
      System.assertEquals(0, stepCRuns, 'StepC must not run');
    }
  }

  // ============================================================
  // 4. SIBLINGS RUN, NO PAUSE STATE (AC 1, AC 3)
  // ============================================================

  @IsTest
  static void testSiblingRunsWhileOneInstanceIsHeld() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id heldId = startAndRunFirstHop(key('Held'));
      Id siblingId = startAndRunFirstHop(key('Sibling'));
      WorkflowInstanceHold.hold(heldId, 'one only');
      WorkflowEngine.runStep(heldId);
      WorkflowEngine.runStep(siblingId);
      WorkflowEngine.runStep(siblingId);
      Test.stopTest();

      System.assertEquals('Held', load(heldId).Status__c, 'Held parks');
      System.assertEquals(
        'Completed',
        load(siblingId).Status__c,
        'The sibling completes'
      );
      System.assertEquals(false, load(siblingId).Held__c, 'Sibling not held');
      System.assertEquals(
        0,
        [SELECT COUNT() FROM Workflow_Pause_State__c],
        'Hold writes no pause state'
      );
      System.assertEquals(
        false,
        WorkflowPauseGate.isDefinitionPaused(WF),
        'The definition is not paused'
      );
    }
  }

  // ============================================================
  // 5. IDEMPOTENT (AC 6)
  // ============================================================

  @IsTest
  static void testHoldTwiceIsNoOp() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(key('Twice'));
      WorkflowInstanceHold.hold(instId, 'first');
      Workflow_Instance__c first = load(instId);
      WorkflowInstanceHold.HoldResult second = WorkflowInstanceHold.hold(
        instId,
        'second'
      );
      WorkflowEngine.runStep(instId);
      WorkflowInstanceHold.HoldResult third = WorkflowInstanceHold.hold(
        instId,
        'third'
      );
      Test.stopTest();

      System.assertEquals(
        WorkflowInstanceHold.Outcome.ALREADY_HELD,
        second.outcome,
        'A second hold is a no-op'
      );
      System.assertEquals(
        WorkflowInstanceHold.Outcome.ALREADY_HELD,
        third.outcome,
        'A hold on a parked instance is a no-op'
      );
      Workflow_Instance__c after = load(instId);
      System.assertEquals('first', after.Hold_Reason__c, 'Reason is kept');
      System.assertEquals(first.Held_At__c, after.Held_At__c, 'Since is kept');
    }
  }

  @IsTest
  static void testReleaseNotHeldIsNoOp() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(key('NotHeld'));
      WorkflowInstanceHold.HoldResult never = WorkflowInstanceHold.release(
        instId
      );
      WorkflowInstanceHold.hold(instId, 'x');
      WorkflowEngine.runStep(instId);
      WorkflowInstanceHold.release(instId);
      WorkflowInstanceHold.HoldResult again = WorkflowInstanceHold.release(
        instId
      );
      Test.stopTest();

      System.assertEquals(
        WorkflowInstanceHold.Outcome.NOT_HELD,
        never.outcome,
        'Release of a run that was never held is a no-op'
      );
      System.assertEquals(
        WorkflowInstanceHold.Outcome.NOT_HELD,
        again.outcome,
        'A second release is a no-op'
      );
      System.assertEquals('Running', load(instId).Status__c, 'Still running');
    }
  }

  @IsTest
  static void testUnknownInstanceIsNotFound() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = insertInstance(WF, 'Running', STEP_B);
      Id goneId = inst.Id;
      delete inst;
      Test.startTest();
      WorkflowInstanceHold.HoldResult held = WorkflowInstanceHold.hold(
        goneId,
        'x'
      );
      WorkflowInstanceHold.HoldResult released = WorkflowInstanceHold.release(
        goneId
      );
      Test.stopTest();
      System.assertEquals(
        WorkflowInstanceHold.Outcome.NOT_FOUND,
        held.outcome,
        'Hold reports NOT_FOUND'
      );
      System.assertEquals(
        WorkflowInstanceHold.Outcome.NOT_FOUND,
        released.outcome,
        'Release reports NOT_FOUND'
      );
    }
  }

  @IsTest
  static void testNullInstanceIdThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Boolean threw = false;
      try {
        WorkflowInstanceHold.hold(null, 'x');
      } catch (WorkflowEngine.WorkflowException ex) {
        threw = true;
      }
      System.assert(threw, 'A null id is a caller error');
    }
  }

  @IsTest
  static void testLongReasonIsTruncated() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = insertInstance(WF, 'Running', STEP_B);
      Test.startTest();
      WorkflowInstanceHold.hold(inst.Id, 'r'.repeat(400));
      Test.stopTest();
      System.assertEquals(
        255,
        load(inst.Id).Hold_Reason__c.length(),
        'Reason fits the field'
      );
    }
  }

  // ============================================================
  // 6. REJECTIONS (AC 7)
  // ============================================================

  @IsTest
  static void testHoldRejectsTerminalWithoutWrites() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<String> terminal = new List<String>{
        'Completed',
        'Failed',
        'Compensated',
        'Cancelled',
        'ContinuedAsNew'
      };
      List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>();
      for (String status : terminal) {
        insts.add(insertInstance(WF, status, null));
      }
      Map<Id, Workflow_Instance__c> before = new Map<Id, Workflow_Instance__c>(
        [
          SELECT Id, Terminal_At__c, LastModifiedDate
          FROM Workflow_Instance__c
          WHERE Id IN :insts
        ]
      );
      Test.startTest();
      for (Workflow_Instance__c inst : insts) {
        WorkflowInstanceHold.HoldResult result = WorkflowInstanceHold.hold(
          inst.Id,
          'x'
        );
        System.assertEquals(
          WorkflowInstanceHold.Outcome.REJECTED_TERMINAL,
          result.outcome,
          'Hold rejects ' + inst.Status__c
        );
        System.assert(
          String.isNotBlank(result.message),
          'The rejection has a message'
        );
        System.assertEquals(
          WorkflowInstanceHold.Outcome.NOT_HELD,
          WorkflowInstanceHold.release(inst.Id).outcome,
          'Release of a terminal run is a no-op'
        );
      }
      Test.stopTest();
      for (Workflow_Instance__c inst : [
        SELECT Id, Terminal_At__c, Held__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id IN :insts
      ]) {
        System.assertEquals(
          before.get(inst.Id).Terminal_At__c,
          inst.Terminal_At__c,
          'Terminal_At__c is not written'
        );
        System.assertEquals(false, inst.Held__c, 'Not held');
      }
    }
  }

  @IsTest
  static void testHoldRejectsCompensatingAndEngineWorkflows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> comp = new List<Workflow_Instance__c>{
        insertInstance(WF, 'Compensating', STEP_A),
        insertInstance(WF, 'Cancelling', STEP_A),
        insertInstance(WF, 'CompensationFailed', STEP_A)
      };
      Workflow_Instance__c watchdog = insertInstance(
        'WatchdogWorkflow',
        'Suspended',
        'WatchdogStep'
      );
      Test.startTest();
      for (Workflow_Instance__c inst : comp) {
        System.assertEquals(
          WorkflowInstanceHold.Outcome.REJECTED_COMPENSATING,
          WorkflowInstanceHold.hold(inst.Id, 'x').outcome,
          'Hold rejects ' + inst.Status__c
        );
      }
      System.assertEquals(
        WorkflowInstanceHold.Outcome.REJECTED_ENGINE_WORKFLOW,
        WorkflowInstanceHold.hold(watchdog.Id, 'x').outcome,
        'Hold rejects an engine workflow'
      );
      Test.stopTest();
      System.assertEquals(false, load(watchdog.Id).Held__c, 'Not held');
    }
  }

  // ============================================================
  // 7. NO SCHEDULED JOB (AC 9)
  // ============================================================

  @IsTest
  static void testHoldAndReleaseScheduleNoJob() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(key('Jobs'));
      Integer jobsBefore = [SELECT COUNT() FROM CronTrigger];
      WorkflowInstanceHold.hold(instId, 'x');
      WorkflowEngine.runStep(instId);
      WorkflowInstanceHold.release(instId);
      Integer jobsAfter = [SELECT COUNT() FROM CronTrigger];
      Test.stopTest();
      System.assertEquals(jobsBefore, jobsAfter, 'No scheduled job is added');
    }
  }

  // ============================================================
  // 8. AWAITED SIGNAL SURVIVES (AC 2)
  // ============================================================

  @IsTest
  static void testAwaitedSignalSurvivesHoldAndRelease() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      String correlationKey = key('Signal');
      Test.startTest();
      Id instId = WorkflowEngine.start(SIGNAL_WF, correlationKey, null);
      WorkflowEngine.runStep(instId); // WaitStep suspends.
      System.assertEquals('Suspended', load(instId).Status__c, 'Waits');
      WorkflowInstanceHold.hold(instId, 'x');
      System.assertEquals('Suspended', load(instId).Status__c, 'Still waits');
      WorkflowEngine.signal(correlationKey, 'Go', '"payload"');
      WorkflowEngine.runStep(instId); // The wake reaches the gate.
      Workflow_Instance__c parked = load(instId);
      Workflow_Signal__c heldSignal = [
        SELECT Status__c
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :instId
      ];
      WorkflowInstanceHold.release(instId);
      WorkflowEngine.runStep(instId); // WaitStep reads Go.
      WorkflowEngine.runStep(instId); // StepC.
      Test.stopTest();

      System.assertEquals('Held', parked.Status__c, 'The wake parks');
      System.assertEquals(WAIT_STEP, parked.Current_Step__c, 'Step kept');
      System.assertEquals('Received', heldSignal.Status__c, 'Signal kept');
      System.assertEquals(
        'Completed',
        load(instId).Status__c,
        'The released run reads the signal and completes'
      );
    }
  }

  @IsTest
  static void testSignalToParkedInstanceDoesNotWake() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = insertInstance(SIGNAL_WF, 'Held', WAIT_STEP);
      Test.startTest();
      WorkflowEngine.signal(inst.Correlation_Key__c, 'Go', '"p"');
      Test.stopTest();
      System.assertEquals(
        'Received',
        [
          SELECT Status__c
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :inst.Id
        ]
        .Status__c,
        'The signal is stored'
      );
      System.assertEquals('Held', load(inst.Id).Status__c, 'Not woken');
    }
  }

  // ============================================================
  // 9. PARK STATUS LISTS
  // ============================================================

  @IsTest
  static void testCancelClearsHold() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(key('Cancel'));
      WorkflowInstanceHold.hold(instId, 'x');
      WorkflowEngine.runStep(instId);
      WorkflowEngine.cancel(instId);
      Test.stopTest();
      Workflow_Instance__c after = load(instId);
      System.assertEquals('Cancelled', after.Status__c, 'Cancel works');
      System.assertEquals(false, after.Held__c, 'Cancel clears the hold');
      System.assertEquals(null, after.Hold_Reason__c, 'Reason cleared');
    }
  }

  @IsTest
  static void testCorrelationKeyStaysReservedWhileHeld() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String correlationKey = key('Key');
      Test.startTest();
      Id instId = startAndRunFirstHop(correlationKey);
      WorkflowInstanceHold.hold(instId, 'x');
      WorkflowEngine.runStep(instId);
      WorkflowEngine.StartResult dup = WorkflowEngine.startOrGet(
        WF,
        correlationKey,
        null
      );
      Test.stopTest();
      System.assertEquals(
        correlationKey,
        load(instId).Active_Correlation_Key__c,
        'Key stays reserved'
      );
      System.assertEquals(instId, dup.instanceId, 'Dedup returns the run');
      System.assertEquals(false, dup.isNew, 'No second run');
    }
  }

  @IsTest
  static void testHarnessTreatsHeldAsStable() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = insertInstance(
        WF,
        'Held',
        STEP_B + ',' + STEP_C
      );
      Test.startTest();
      Boolean advanceable = WorkflowHarnessAdvancer.isAdvanceable(
        new WorkflowHarnessContext(inst.Id),
        inst
      );
      Test.stopTest();
      System.assertEquals(false, advanceable, 'A held row is stable');
    }
  }

  @IsTest
  static void testInFlightBranchKeepsHeldPark() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = insertInstance(
        WF,
        'Held',
        STEP_B + ',' + STEP_C
      );
      insert new List<Workflow_Step_Execution__c>{
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst.Id,
          Step_Name__c = STEP_B,
          Status__c = 'Completed',
          Retry_Count__c = 0
        ),
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst.Id,
          Step_Name__c = STEP_C,
          Status__c = 'Pending',
          Retry_Count__c = 0,
          CPU_Time_Ms__c = 1
        )
      };
      WorkflowEngine.StepOutcomeContext outcome = new WorkflowEngine.StepOutcomeContext();
      outcome.instance = inst;
      outcome.isParallel = true;
      Test.startTest();
      WorkflowParallelJoin.completeParallelBranch(outcome);
      Test.stopTest();
      System.assertEquals('Held', load(inst.Id).Status__c, 'Park is kept');
    }
  }

  @IsTest
  static void testTimeoutSweepSkipsHeldInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c held = insertInstance(WF, 'Held', STEP_B);
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = held.Id,
        Step_Name__c = STEP_B,
        Status__c = 'Pending',
        Retry_Count__c = 0,
        Timeout_At__c = Datetime.now().addMinutes(-5)
      );
      Workflow_Instance__c live = insertInstance(WF, 'Running', STEP_B);
      Workflow_Step_Execution__c liveStep = new Workflow_Step_Execution__c(
        Workflow_Instance__c = live.Id,
        Step_Name__c = STEP_B,
        Status__c = 'Running',
        Retry_Count__c = 0,
        Timeout_At__c = Datetime.now().addMinutes(-4)
      );
      insert liveStep;
      Test.startTest();
      WorkflowTimeoutSweep.watchdogTimeoutBatchSize = 1;
      WorkflowTimeoutSweep.processTimedOutSteps(
        Datetime.now(),
        new List<Workflow_Instance__c>()
      );
      Test.stopTest();
      System.assertEquals('Held', load(held.Id).Status__c, 'Not failed');
      System.assertEquals(
        'Failed',
        [
          SELECT Status__c
          FROM Workflow_Step_Execution__c
          WHERE Id = :liveStep.Id
        ]
        .Status__c,
        'The sweep skips held rows'
      );
    }
  }

  // The hold waits for the gate. A timeout must not fail the Pending step.
  @IsTest
  static void testTimeoutJobKeepsPendingStepWhileHoldWaits() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = insertInstance(WF, 'Running', STEP_B);
      inst.Held_At__c = Datetime.now();
      update inst;
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = STEP_B,
        Status__c = 'Pending',
        Retry_Count__c = 0,
        Timeout_At__c = Datetime.now().addSeconds(-60)
      );
      Test.startTest();
      new WorkflowTimeoutJob(inst.Id, STEP_B).executeInternal();
      Test.stopTest();
      System.assertEquals('Running', load(inst.Id).Status__c, 'Not failed');
      Workflow_Step_Execution__c step = [
        SELECT Status__c, Timeout_At__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :inst.Id
      ];
      System.assertEquals('Pending', step.Status__c, 'The step stays Pending');
      System.assertEquals(
        null,
        step.Timeout_At__c,
        'The deadline is cleared. Release arms it again.'
      );
    }
  }

  @IsTest
  static void testTimeoutSweepKeepsPendingStepWhileHoldWaits() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = insertInstance(WF, 'Running', STEP_B);
      inst.Held_At__c = Datetime.now();
      update inst;
      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = STEP_B,
        Status__c = 'Pending',
        Retry_Count__c = 0,
        Timeout_At__c = Datetime.now().addMinutes(-5)
      );
      insert step;
      Test.startTest();
      WorkflowTimeoutSweep.processTimedOutSteps(
        Datetime.now(),
        new List<Workflow_Instance__c>()
      );
      Test.stopTest();
      System.assertEquals('Running', load(inst.Id).Status__c, 'Not failed');
      System.assertEquals(
        'Pending',
        [SELECT Status__c FROM Workflow_Step_Execution__c WHERE Id = :step.Id]
        .Status__c,
        'The step stays Pending'
      );
    }
  }

  @IsTest
  static void testStatsCountHeldAsActive() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insertInstance(WF, 'Held', STEP_B);
      Test.startTest();
      WorkflowDashboardController.InstanceQuery statsQuery = new WorkflowDashboardController.InstanceQuery();
      statsQuery.workflowName = WF;
      Map<String, Integer> stats = WorkflowDashboardController.getWorkflowStats(
        statsQuery
      );
      Test.stopTest();
      System.assertEquals(1, stats.get('active'), 'Held counts as active');
    }
  }

  // ============================================================
  // 11. REVIEW REGRESSIONS
  // ============================================================

  @IsTest
  static void testGateOnUnheldInstanceCostsNoSoqlOrDml() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'Running',
        Current_Step__c = STEP_B
      );
      Test.startTest();
      Integer q0 = Limits.getQueries();
      Integer d0 = Limits.getDmlStatements();
      Boolean stopped = WorkflowInstanceHoldGate.parkIfHeld(inst);
      Integer q1 = Limits.getQueries();
      Integer d1 = Limits.getDmlStatements();
      Test.stopTest();
      System.assertEquals(false, stopped, 'A run that is not held goes on');
      System.assertEquals(q0, q1, 'The gate adds no SOQL');
      System.assertEquals(d0, d1, 'The gate adds no DML');
    }
  }

  // Review finding: a branch that ran before the park must not undo it.
  @IsTest
  static void testWaitOutcomeKeepsHeldPark() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c held = insertInstance(WF, 'Held', WAIT_STEP);
      Workflow_Instance__c live = insertInstance(WF, 'Running', WAIT_STEP);
      Test.startTest();
      for (
        Workflow_Instance__c inst : new List<Workflow_Instance__c>{ held, live }
      ) {
        Workflow_Step_Execution__c exec = new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst.Id,
          Step_Name__c = WAIT_STEP,
          Status__c = 'Running',
          Retry_Count__c = 0
        );
        insert exec;
        WorkflowEngine.StepOutcomeContext outcome = new WorkflowEngine.StepOutcomeContext();
        outcome.instance = [
          SELECT Id, Status__c, Correlation_Key__c, Current_Step__c
          FROM Workflow_Instance__c
          WHERE Id = :inst.Id
        ];
        outcome.stepExec = exec;
        outcome.result = StepResult.suspend();
        outcome.isParallel = false;
        WorkflowStepSuspension.handleSuspendOutcome(outcome);
      }
      Test.stopTest();
      System.assertEquals('Held', load(held.Id).Status__c, 'Park is kept');
      System.assertEquals(
        'Suspended',
        load(live.Id).Status__c,
        'A run that is not parked suspends as before'
      );
    }
  }

  // Review finding: the sleep sweep must not route a held timed wait to its
  // fallback step. After release, the next heartbeat routes it.
  @IsTest
  static void testSleepSweepWaitsForReleaseOfTimedWait() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = insertInstance(
        SIGNAL_WF,
        'Suspended',
        WAIT_STEP
      );
      inst.Held_At__c = Datetime.now();
      inst.Sleep_Until__c = Datetime.now().addMinutes(-1);
      update inst;
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = WAIT_STEP,
        Status__c = 'Pending',
        Retry_Count__c = 0,
        Output__c = '{"$timeoutStep":"' + STEP_C + '"}'
      );
      Test.startTest();
      WorkflowSleepResumeSweep.processSleepResumptions(Datetime.now());
      Workflow_Instance__c whileHeld = load(inst.Id);
      Integer rowsWhileHeld = rows(inst.Id).size();
      WorkflowInstanceHold.release(inst.Id);
      WorkflowSleepResumeSweep.processSleepResumptions(Datetime.now());
      Test.stopTest();

      System.assertEquals('Suspended', whileHeld.Status__c, 'Not woken');
      System.assertEquals(WAIT_STEP, whileHeld.Current_Step__c, 'Not routed');
      System.assertEquals(1, rowsWhileHeld, 'No fallback row while held');
      Workflow_Instance__c released = load(inst.Id);
      System.assertEquals(STEP_C, released.Current_Step__c, 'Routed later');
      System.assertEquals('Running', released.Status__c, 'Woken later');
    }
  }

  @IsTest
  static void testHoldRejectsSuspendedCompensation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = insertInstance(
        WF,
        'Suspended',
        STEP_A + '_Compensate'
      );
      inst.Compensation_Stack__c = JSON.serialize(new List<String>{ STEP_A });
      update inst;
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = STEP_A + '_Compensate',
        Status__c = 'Pending',
        Retry_Count__c = 0
      );
      Test.startTest();
      WorkflowInstanceHold.HoldResult result = WorkflowInstanceHold.hold(
        inst.Id,
        'x'
      );
      Test.stopTest();
      System.assertEquals(
        WorkflowInstanceHold.Outcome.REJECTED_COMPENSATING,
        result.outcome,
        'A waiting rollback is rejected'
      );
      System.assertEquals(false, load(inst.Id).Held__c, 'Not held');
    }
  }

  // Review finding: release must not make a run Running with no slot.
  @IsTest
  static void testReleaseKeepsSlotlessRunSuspended() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = insertInstance(WF, 'Held', STEP_A);
      inst.Concurrency_Parked__c = true;
      update inst;
      Test.startTest();
      WorkflowInstanceHold.release(inst.Id);
      Test.stopTest();
      Workflow_Instance__c after = load(inst.Id);
      System.assertEquals('Suspended', after.Status__c, 'Admission decides');
      System.assertNotEquals(null, after.Sleep_Until__c, 'Watchdog backstop');
    }
  }

  @IsTest
  static void testReleaseReArmsStepTimeout() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      String timed = 'WorkflowInstanceHoldTest.TimedStep';
      Workflow_Instance__c inst = insertInstance(WF, 'Held', timed);
      Workflow_Step_Execution__c exec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = timed,
        Status__c = 'Pending',
        Retry_Count__c = 0
      );
      insert exec;
      Test.startTest();
      WorkflowInstanceHold.release(inst.Id);
      Test.stopTest();
      System.assertNotEquals(
        null,
        [
          SELECT Timeout_At__c
          FROM Workflow_Step_Execution__c
          WHERE Id = :exec.Id
        ]
        .Timeout_At__c,
        'Release arms the step deadline again'
      );
    }
  }

  @IsTest
  static void testParkAbortsScheduledJobs() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = insertInstance(WF, 'Running', STEP_B);
      inst.Held_At__c = Datetime.now();
      update inst;
      String jobName = 'WorkflowSleep_' + inst.Id + '_test';
      Test.startTest();
      System.schedule(
        jobName,
        '0 0 0 1 1 ? 2099',
        new WorkflowTimeoutJob(inst.Id, STEP_B)
      );
      Workflow_Instance__c loaded = [
        SELECT Id, Status__c, Workflow_Name__c, Held__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      Boolean stopped = WorkflowInstanceHoldGate.parkIfHeld(loaded);
      Test.stopTest();
      System.assertEquals(true, stopped, 'The gate parks');
      System.assertEquals(
        0,
        [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :jobName],
        'The park aborts the sleep job'
      );
    }
  }

  @IsTest
  static void testHeldRunOnPausedDefinitionParksAsHeld() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(key('PauseOrder'));
      WorkflowInstanceHold.hold(instId, 'x');
      WorkflowPauseGate.pauseDefinition(WF, 'order test');
      WorkflowEngine.runStep(instId);
      Test.stopTest();
      System.assertEquals('Held', load(instId).Status__c, 'Hold parks first');
    }
  }

  @IsTest
  static void testTriggerClearsHoldOffForwardPath() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c failed = insertInstance(WF, 'Running', STEP_B);
      Workflow_Instance__c comp = insertInstance(WF, 'Running', STEP_B);
      Workflow_Instance__c live = insertInstance(WF, 'Running', STEP_B);
      for (
        Workflow_Instance__c inst : new List<Workflow_Instance__c>{
          failed,
          comp,
          live
        }
      ) {
        inst.Held_At__c = Datetime.now();
      }
      update new List<Workflow_Instance__c>{ failed, comp, live };
      Test.startTest();
      failed.Status__c = 'Failed';
      comp.Status__c = 'Compensating';
      live.Status__c = 'Suspended';
      update new List<Workflow_Instance__c>{ failed, comp, live };
      Test.stopTest();
      System.assertEquals(false, load(failed.Id).Held__c, 'Failed clears');
      System.assertEquals(false, load(comp.Id).Held__c, 'Rollback clears');
      System.assertEquals(true, load(live.Id).Held__c, 'Forward path keeps');
    }
  }

  @IsTest
  static void testContinueAsNewWithoutHoldDoesNotHold() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Test.startTest();
      Id instId = WorkflowEngine.start(
        'WorkflowDefinitionChangeTest.LoopWorkflow',
        key('CanFree'),
        null
      );
      WorkflowEngine.runStep(instId);
      Test.stopTest();
      System.assertEquals(
        false,
        [
          SELECT Held__c
          FROM Workflow_Instance__c
          WHERE Previous_Instance__c = :instId
        ]
        .Held__c,
        'A successor of a run that is not held is not held'
      );
    }
  }

  @IsTest
  static void testGateNeverParksEngineWorkflow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c watchdog = insertInstance(
        'WatchdogWorkflow',
        'Running',
        'WatchdogStep'
      );
      watchdog.Held_At__c = Datetime.now(); // Direct DML, not the API.
      update watchdog;
      Test.startTest();
      Boolean stopped = WorkflowInstanceHoldGate.parkIfHeld(
        [
          SELECT Id, Status__c, Workflow_Name__c, Held__c
          FROM Workflow_Instance__c
          WHERE Id = :watchdog.Id
        ]
      );
      Test.stopTest();
      System.assertEquals(false, stopped, 'The watchdog runs on');
      System.assertEquals('Running', load(watchdog.Id).Status__c, 'Not parked');
    }
  }

  // AC 4: release puts the parked chain back on the queue.
  @IsTest
  static void testReleaseEnqueuesParkedChain() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = false;
      Workflow_Instance__c inst = insertInstance(WF, 'Held', STEP_B);
      // No Test.stopTest(): the job must stay queued, not run.
      Integer before = Limits.getQueueableJobs();
      WorkflowInstanceHold.release(inst.Id);
      System.assertEquals(
        before + 1,
        Limits.getQueueableJobs(),
        'Release enqueues one orchestrator'
      );
    }
  }

  // AC 9 with a step timeout: park and release add no scheduled job.
  @IsTest
  static void testTimedStepHoldAddsNoScheduledJob() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      String timed = 'WorkflowInstanceHoldTest.TimedStep';
      Workflow_Instance__c inst = insertInstance(WF, 'Running', timed);
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = timed,
        Status__c = 'Pending',
        Retry_Count__c = 0
      );
      WorkflowTimeoutScheduler.scheduleTimeoutJobIfNeeded(inst.Id, timed);
      Integer jobsBefore = [SELECT COUNT() FROM CronTrigger];
      Test.startTest();
      WorkflowInstanceHold.hold(inst.Id, 'x');
      WorkflowEngine.runStep(inst.Id);
      WorkflowInstanceHold.release(inst.Id);
      Integer jobsAfter = [SELECT COUNT() FROM CronTrigger];
      Test.stopTest();
      System.assert(
        jobsAfter <= jobsBefore,
        'No extra scheduled job: ' + jobsBefore + ' then ' + jobsAfter
      );
    }
  }

  // ============================================================
  // 10. CONTINUE-AS-NEW KEEPS THE HOLD
  // ============================================================

  @IsTest
  static void testContinueAsNewCarriesHold() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Test.startTest();
      Id instId = WorkflowEngine.start(LOOP_WF, key('Can'), null);
      WorkflowEngine.runStep(instId); // Holds itself, continues as new.
      Workflow_Instance__c successor = [
        SELECT Id, Held__c, Hold_Reason__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :instId
      ];
      WorkflowEngine.runStep(successor.Id);
      Test.stopTest();

      Workflow_Instance__c predecessor = load(instId);
      System.assertEquals(
        'ContinuedAsNew',
        predecessor.Status__c,
        'The predecessor ends'
      );
      System.assertEquals(false, predecessor.Held__c, 'Predecessor cleared');
      System.assertEquals(true, successor.Held__c, 'The successor is held');
      System.assertEquals('loop hold', successor.Hold_Reason__c, 'Reason');
      System.assertEquals('Held', load(successor.Id).Status__c, 'Parks');
      System.assertEquals(1, loopRuns, 'The successor step does not run');
    }
  }
}
