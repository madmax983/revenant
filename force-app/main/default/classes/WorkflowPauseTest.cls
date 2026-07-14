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
@IsTest
public class WorkflowPauseTest {
  // Parent workflow whose first step spawns a child (used to exercise the pause
  // gate on the START_CHILD path). The child correlation key is read from a static
  // so the test can locate the spawned child.
  public static String spawnChildKey;

  // ============================================================
  // MOCK WORKFLOWS
  // ============================================================

  /**
   * @description Mock two-step (StepA -> StepB) linear workflow used to exercise the
   * pause gate at a normal step handoff.
   */
  public class TwoStepWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the ordered step names in this workflow.
     * @return The step names in execution order.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowPauseTest.StepA',
        'WorkflowPauseTest.StepB'
      };
    }
    /**
     * @description Names the first step to run when an instance starts.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowPauseTest.StepA';
    }
    /**
     * @description Routes StepA to StepB and ends after StepB.
     * @param current The name of the step that just completed.
     * @param result The result of the completed step.
     * @return StepB after StepA, or null when complete.
     */
    public String getNextStep(String current, StepResult result) {
      if (current == 'WorkflowPauseTest.StepA') {
        return 'WorkflowPauseTest.StepB';
      }
      return null;
    }
  }

  /**
   * @description Mock first step that completes and hands off to StepB.
   */
  public class StepA implements WorkflowStep {
    /**
     * @description Completes with OutputA and routes to StepB.
     * @param ctx The durable step context for this execution.
     * @return A completion result routing to StepB.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete('WorkflowPauseTest.StepB', 'OutputA');
    }
  }

  /**
   * @description Mock terminal step that completes the workflow.
   */
  public class StepB implements WorkflowStep {
    /**
     * @description Completes the workflow with OutputB.
     * @param ctx The durable step context for this execution.
     * @return A terminal completion result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'OutputB');
    }
  }

  /**
   * @description Mock workflow whose first step suspends waiting for a signal, used
   * to test signal-hold behavior while paused.
   */
  public class SuspendingWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the ordered step names in this workflow.
     * @return The step names in execution order.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowPauseTest.SuspendStep',
        'WorkflowPauseTest.StepB'
      };
    }
    /**
     * @description Names the first step to run when an instance starts.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowPauseTest.SuspendStep';
    }
    /**
     * @description Routes SuspendStep to StepB and ends after StepB.
     * @param current The name of the step that just completed.
     * @param result The result of the completed step.
     * @return StepB after SuspendStep, or null when complete.
     */
    public String getNextStep(String current, StepResult result) {
      if (current == 'WorkflowPauseTest.SuspendStep') {
        return 'WorkflowPauseTest.StepB';
      }
      return null;
    }
  }

  // Step that suspends waiting for a signal. The signal name is not a suspend
  // argument — a resumed step matches signals via ctx.getPendingSignals(name);
  // suspend() just yields the SUSPEND action.
  /**
   * @description Mock step that suspends, modeling a step parked waiting on a signal.
   */
  public class SuspendStep implements WorkflowStep {
    /**
     * @description Yields a SUSPEND action so the instance parks.
     * @param ctx The durable step context for this execution.
     * @return A suspend result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.suspend();
    }
  }

  /**
   * @description Mock scatter-gather workflow (split into BranchA/BranchB, join)
   * used to test pause/resume across parallel branches.
   */
  public class ParallelWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the ordered step names in this workflow.
     * @return The step names in execution order.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowPauseTest.SplitStep',
        'WorkflowPauseTest.BranchA',
        'WorkflowPauseTest.BranchB',
        'WorkflowPauseTest.JoinStep'
      };
    }
    /**
     * @description Names the first step to run when an instance starts.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowPauseTest.SplitStep';
    }
    /**
     * @description Routes the split step to the join step; branches end their path.
     * @param current The name of the step that just completed.
     * @param result The result of the completed step.
     * @return The join step after the split, or null otherwise.
     */
    public String getNextStep(String current, StepResult result) {
      if (current == 'WorkflowPauseTest.SplitStep') {
        return 'WorkflowPauseTest.JoinStep';
      }
      return null;
    }
  }

  /**
   * @description Mock step that fans out into BranchA and BranchB.
   */
  public class SplitStep implements WorkflowStep {
    /**
     * @description Splits execution into the two mock branches.
     * @param ctx The durable step context for this execution.
     * @return A split result into BranchA and BranchB.
     */
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

  /**
   * @description Mock parallel branch A that completes immediately.
   */
  public class BranchA implements WorkflowStep {
    /**
     * @description Completes branch A.
     * @param ctx The durable step context for this execution.
     * @return A completion result for branch A.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'BranchAOut');
    }
  }

  /**
   * @description Mock parallel branch B that completes immediately.
   */
  public class BranchB implements WorkflowStep {
    /**
     * @description Completes branch B.
     * @param ctx The durable step context for this execution.
     * @return A completion result for branch B.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'BranchBOut');
    }
  }

  /**
   * @description Mock join step that completes after the branches merge.
   */
  public class JoinStep implements WorkflowStep {
    /**
     * @description Completes the joined workflow.
     * @param ctx The durable step context for this execution.
     * @return A terminal completion result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Joined');
    }
  }

  // Timeout-configured parallel branches used to assert that the resume re-arm
  // path schedules a dynamic timeout job only for branches with an active step
  // row — never for a Completed branch still lingering in Current_Step__c.
  /**
   * @description Mock timeout-configured parallel branch A, used to assert the
   * resume re-arm path only schedules a timeout for a branch with an active step.
   */
  public class TimeoutBranchA implements WorkflowStep, TimeoutConfigurable {
    /**
     * @description Reports this branch's per-step timeout.
     * @return The timeout in seconds.
     */
    public Integer getTimeoutSeconds() {
      return 120;
    }
    /**
     * @description Completes branch A.
     * @param ctx The durable step context for this execution.
     * @return A completion result for branch A.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'BranchAOut');
    }
  }

  /**
   * @description Mock timeout-configured parallel branch B, counterpart to
   * TimeoutBranchA in the resume re-arm assertions.
   */
  public class TimeoutBranchB implements WorkflowStep, TimeoutConfigurable {
    /**
     * @description Reports this branch's per-step timeout.
     * @return The timeout in seconds.
     */
    public Integer getTimeoutSeconds() {
      return 120;
    }
    /**
     * @description Completes branch B.
     * @param ctx The durable step context for this execution.
     * @return A completion result for branch B.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'BranchBOut');
    }
  }

  /**
   * @description Mock parent workflow whose single step spawns a child, used to
   * exercise the pause gate on the START_CHILD path.
   */
  public class ChildSpawningWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the ordered step names in this workflow.
     * @return The single-element list of step names.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowPauseTest.SpawnChildStep' };
    }
    /**
     * @description Names the first step to run when an instance starts.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowPauseTest.SpawnChildStep';
    }
    /**
     * @description Ends after the single spawn step.
     * @param current The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, since this workflow has one step.
     */
    public String getNextStep(String current, StepResult result) {
      return null;
    }
  }

  /**
   * @description Mock step that starts a child TwoStepWorkflow via START_CHILD.
   */
  public class SpawnChildStep implements WorkflowStep {
    /**
     * @description Spawns the child workflow keyed by the shared spawnChildKey.
     * @param ctx The durable step context for this execution.
     * @return A start-child result for the child workflow.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.startChild(
        'WorkflowPauseTest.TwoStepWorkflow',
        spawnChildKey,
        null
      );
    }
  }

  // Regression: a paused run keeps its correlation key reserved, so startOrGet
  // dedup (ACTIVE_STATUSES) must resolve to the live paused instance rather than a
  // stale recently-terminal run for the same key within the dedup window.
  @IsTest
  static void testPausedInstanceWinsDedupOverTerminalRow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      String key = 'PausedDedup-' + Datetime.now().getTime();

      // A recent terminal run for the key (within the default dedup window). The
      // trigger clears its Active_Correlation_Key__c and stamps Terminal_At__c.
      insert new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Completed',
        Correlation_Key__c = key
      );
      // The live parked run for the same key (reserves the active key).
      Workflow_Instance__c parked = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Paused',
        Current_Step__c = 'WorkflowPauseTest.StepB',
        Correlation_Key__c = key
      );
      insert parked;

      Test.startTest();
      WorkflowEngine.StartResult res = WorkflowEngine.startOrGet(
        'WorkflowPauseTest.TwoStepWorkflow',
        key,
        null
      );
      Test.stopTest();

      System.assertEquals(
        parked.Id,
        res.instanceId,
        'Dedup must resolve to the live paused instance, not the stale terminal row'
      );
      System.assertEquals(
        false,
        res.isNew,
        'startOrGet must return an existing instance, not start a new one'
      );
    }
  }

  // Regression: a timeout job armed by a pre-pause handoff must NOT fail a step
  // while its definition is paused. The parked step is held and re-armed on resume;
  // failing it here would corrupt an in-flight run "before starting".
  @IsTest
  static void testTimeoutJobSkipsPausedDefinition() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String key = 'PausedTimeoutJob-' + Datetime.now().getTime();
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Running',
        Current_Step__c = 'WorkflowPauseTest.StepB',
        Correlation_Key__c = key
      );
      insert inst;
      // A pending next step with an already-overdue watchdog deadline (as a
      // pre-pause handoff would leave it).
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowPauseTest.StepB',
        Status__c = 'Pending',
        Timeout_At__c = Datetime.now().addSeconds(-60),
        Retry_Count__c = 0
      );
      WorkflowPauseGate.pauseDefinition(
        'WorkflowPauseTest.TwoStepWorkflow',
        'timeoutjob'
      );

      Test.startTest();
      new WorkflowTimeoutJob(inst.Id, 'WorkflowPauseTest.StepB')
        .executeInternal();
      Test.stopTest();

      Workflow_Instance__c after = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Running',
        after.Status__c,
        'Timeout job must not fail an instance whose definition is paused'
      );
      Workflow_Step_Execution__c stepAfter = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c = 'WorkflowPauseTest.StepB'
      ];
      System.assertEquals(
        'Pending',
        stepAfter.Status__c,
        'Paused step must remain Pending, not be timed out to Failed'
      );
    }
  }

  // Regression: the watchdog timeout heartbeat must not fail a step whose
  // definition is paused while the parent is still Pending/Running (handoff armed
  // the deadline before the delayed RUN_STEP parked it). It clears the stale
  // deadline instead, so a post-resume heartbeat cannot fire it instantly.
  @IsTest
  static void testHeartbeatSkipsAndClearsPausedDefinitionTimeout() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String key = 'PausedHeartbeat-' + Datetime.now().getTime();
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Running',
        Current_Step__c = 'WorkflowPauseTest.StepB',
        Correlation_Key__c = key
      );
      insert inst;
      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowPauseTest.StepB',
        Status__c = 'Pending',
        Timeout_At__c = Datetime.now().addSeconds(-60),
        Retry_Count__c = 0
      );
      insert step;
      WorkflowPauseGate.pauseDefinition(
        'WorkflowPauseTest.TwoStepWorkflow',
        'heartbeat'
      );

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      Workflow_Instance__c after = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Running',
        after.Status__c,
        'Heartbeat must not fail an instance whose definition is paused'
      );
      Workflow_Step_Execution__c stepAfter = [
        SELECT Status__c, Timeout_At__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :step.Id
      ];
      System.assertEquals(
        'Pending',
        stepAfter.Status__c,
        'Paused-definition step must remain Pending, not be timed out'
      );
      System.assertEquals(
        null,
        stepAfter.Timeout_At__c,
        'Stale deadline must be cleared so a post-resume heartbeat cannot fire it'
      );
    }
  }

  // Regression: a stale RUN_STEP for a row still in Status='Paused' must be a
  // no-op even after the definition's pause record is lifted (the chunked resume
  // drain owns the Paused -> Running flip + re-arm).
  @IsTest
  static void testStalePausedRunStepIsNoOpAfterResume() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      String key = 'StalePaused-' + Datetime.now().getTime();
      // Row is Paused, but no pause record exists (definition already resumed) —
      // this row simply has not been drained yet.
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Paused',
        Current_Step__c = 'WorkflowPauseTest.StepB',
        Correlation_Key__c = key
      );
      insert inst;
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowPauseTest.StepB',
        Status__c = 'Pending',
        Retry_Count__c = 0
      );

      Test.startTest();
      new WorkflowOrchestrator(inst.Id, 'WorkflowPauseTest.StepB')
        .execute(null);
      Test.stopTest();

      Workflow_Instance__c after = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Paused',
        after.Status__c,
        'A still-Paused row must not be advanced by a stale RUN_STEP'
      );
      Workflow_Step_Execution__c stepAfter = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c = 'WorkflowPauseTest.StepB'
      ];
      System.assertEquals(
        'Pending',
        stepAfter.Status__c,
        'The step must not execute while the row is still Paused'
      );
    }
  }

  // Regression: resuming a parallel instance must drive a worker only for the
  // still-active branch(es); a Completed branch lingering in Current_Step__c must
  // be skipped rather than spending the resume publish/DML budget on a no-op.
  @IsTest
  static void testParallelResumeSkipsCompletedBranch() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      String key = 'ParResumeSkip-' + Datetime.now().getTime();
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.ParallelWorkflow',
        Status__c = 'Paused',
        Current_Step__c = 'WorkflowPauseTest.BranchA,WorkflowPauseTest.BranchB',
        Correlation_Key__c = key
      );
      insert inst;
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowPauseTest.BranchA',
        Status__c = 'Completed',
        Retry_Count__c = 0
      );
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowPauseTest.BranchB',
        Status__c = 'Pending',
        Retry_Count__c = 0
      );
      WorkflowPauseGate.pauseDefinition(
        'WorkflowPauseTest.ParallelWorkflow',
        'parresume'
      );

      Test.startTest();
      WorkflowPauseGate.resumeDefinition('WorkflowPauseTest.ParallelWorkflow');
      Test.stopTest();

      // Only the pending branch should have been driven: BranchA stays a single
      // Completed row (no re-execution), BranchB advances past Pending.
      List<Workflow_Step_Execution__c> branchA = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c = 'WorkflowPauseTest.BranchA'
      ];
      System.assertEquals(
        1,
        branchA.size(),
        'Completed branch must not be re-driven on resume'
      );
      System.assertEquals(
        'Completed',
        branchA[0].Status__c,
        'BranchA stays done'
      );
    }
  }

  // ============================================================
  // 7. SIGNAL HELD WHILE PAUSED (Defect B regression)
  // ============================================================

  @IsTest
  static void testSignalHeldWhilePaused() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  // ============================================================
  // 8. WATCHDOG SLEEP-RESUME SKIPS PAUSED-DEF INSTANCES
  // ============================================================

  @IsTest
  static void testWatchdogSkipsSleepingPausedDefInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  // ============================================================
  // 9. CANCEL WORKS ON A PAUSED INSTANCE
  // ============================================================

  @IsTest
  static void testCancelWorksOnPausedInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Paused',
        Current_Step__c = 'WorkflowPauseTest.StepB',
        Correlation_Key__c = 'CancelPaused-' + Datetime.now().getTime()
      );
      insert inst;

      Test.startTest();
      WorkflowEngine.cancel(inst.Id);
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
  }

  // ============================================================
  // 10. CORRELATION KEY STAYS RESERVED WHILE PAUSED (Defect A regression)
  // ============================================================

  @IsTest
  static void testCorrelationKeyReservedWhilePaused() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  @IsTest
  static void testCorrelationKeyReservationPreventsDuplicate() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  // ============================================================
  // 11. PAUSE STATE DURABILITY (not in-memory only)
  // ============================================================

  @IsTest
  static void testPauseStateDurability() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPauseGate.pauseDefinition(
        'WorkflowPauseTest.TwoStepWorkflow',
        'D'
      );

      // Simulate a "new transaction / cache flush" by verifying the DB record
      // (static fields would be re-initialized in a fresh execution context)
      List<Workflow_Pause_State__c> records = [
        SELECT Workflow_Name__c
        FROM Workflow_Pause_State__c
      ];
      System.assertEquals(
        1,
        records.size(),
        'Pause record must be in database'
      );
      System.assertEquals(
        'WorkflowPauseTest.TwoStepWorkflow',
        records[0].Workflow_Name__c
      );
    }
  }

  // ============================================================
  // 12. * PAUSES USER DEFS, NOT WATCHDOG
  // ============================================================

  @IsTest
  static void testWildcardPausesUserDefNotWatchdog() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
      Boolean bulkCancelPaused = WorkflowPauseGate.isDefinitionPaused(
        'BulkCancelWorkflow'
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
      System.assertEquals(
        false,
        bulkCancelPaused,
        'BulkCancelWorkflow must NEVER be paused by *'
      );
    }
  }

  @IsTest
  static void testWildcardResumeUnparksAll() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
        System.assertEquals(
          'Running',
          i.Status__c,
          'All parked instances should be Running after * resume'
        );
      }
    }
  }

  // ============================================================
  // 13. DASHBOARD CONTROLLER
  // ============================================================

  @IsTest
  static void testControllerPauseDefinition() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      WorkflowDashboardCommandController.pauseDefinition(
        'WorkflowPauseTest.TwoStepWorkflow',
        'Controller test'
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
        'Pause state should exist after controller call'
      );
    }
  }

  @IsTest
  static void testControllerResumeDefinition() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPauseGate.pauseDefinition(
        'WorkflowPauseTest.TwoStepWorkflow',
        'X'
      );

      Test.startTest();
      WorkflowDashboardCommandController.resumeDefinition(
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
  }

  @IsTest
  static void testControllerGetPausedDefinitions() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowPauseGate.pauseDefinition(
        'WorkflowPauseTest.TwoStepWorkflow',
        'Incident-42'
      );

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

      System.assertEquals(
        1,
        paused.size(),
        'Should return one paused definition'
      );
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
  }

  @IsTest
  static void testControllerGetWatchdogStatusIncludesPausedInfo() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowPauseGate.pauseDefinition(
        'WorkflowPauseTest.TwoStepWorkflow',
        'W'
      );

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

  // ============================================================
  // 14. PR #78 REVIEW REGRESSIONS
  // ============================================================

  // A duplicate/stale RUN_STEP arriving for an instance that is ALREADY Paused
  // must NOT fall through and execute the step (the gate's prior status guard let
  // it through). It must return without executing.
  @IsTest
  static void testDuplicateRunStepWhileAlreadyPausedDoesNotExecute() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Paused',
        Current_Step__c = 'WorkflowPauseTest.StepB',
        Correlation_Key__c = 'DupRunStep-' + Datetime.now().getTime()
      );
      insert inst;
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowPauseTest.StepB',
        Status__c = 'Pending',
        Input__c = '"OutputA"',
        Retry_Count__c = 0
      );
      WorkflowPauseGate.pauseDefinition(
        'WorkflowPauseTest.TwoStepWorkflow',
        'dup'
      );

      Test.startTest();
      WorkflowEngine.runStep(inst.Id, 'WorkflowPauseTest.StepB');
      Test.stopTest();

      Workflow_Instance__c after = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals('Paused', after.Status__c, 'Should remain Paused');
      List<Workflow_Step_Execution__c> ran = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Status__c IN ('Running', 'Completed')
      ];
      System.assertEquals(
        0,
        ran.size(),
        'A duplicate RUN_STEP must NOT execute the step while paused'
      );
    }
  }

  // Resuming a single definition while an org-wide '*' pause is in effect must NOT
  // delete the wildcard record (which would lift maintenance mode for every other
  // definition and strand their parked instances).
  @IsTest
  static void testSingleResumePreservesWildcardPause() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c instA = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Paused',
        Current_Step__c = 'WorkflowPauseTest.StepB',
        Correlation_Key__c = 'WResumeA-' + Datetime.now().getTime()
      );
      Workflow_Instance__c instB = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.SuspendingWorkflow',
        Status__c = 'Paused',
        Current_Step__c = 'WorkflowPauseTest.SuspendStep',
        Correlation_Key__c = 'WResumeB-' + Datetime.now().getTime()
      );
      insert new List<Workflow_Instance__c>{ instA, instB };

      WorkflowPauseGate.pauseDefinition('*', 'Org-wide');

      Test.startTest();
      WorkflowPauseGate.resumeDefinition('WorkflowPauseTest.TwoStepWorkflow');
      Test.stopTest();

      List<Workflow_Pause_State__c> wildcard = [
        SELECT Id
        FROM Workflow_Pause_State__c
        WHERE Workflow_Name__c = '*'
      ];
      System.assertEquals(
        1,
        wildcard.size(),
        'Single-definition resume must NOT delete the org-wide * pause'
      );

      // While '*' is still active both defs stay parked (the wildcard still gates
      // them; flipping to Running would only re-park at the next handoff).
      Workflow_Instance__c afterA = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instA.Id
      ];
      Workflow_Instance__c afterB = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instB.Id
      ];
      System.assertEquals(
        'Paused',
        afterA.Status__c,
        'Named def stays parked while wildcard pause remains in effect'
      );
      System.assertEquals(
        'Paused',
        afterB.Status__c,
        'Other definitions must stay parked while * is active'
      );
    }
  }

  // The bulk start path (used by scheduled jobs / the Flow invocable) must apply
  // the pause gate, not just the scalar start.
  @IsTest
  static void testBulkStartParksDuringPause() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowPauseGate.pauseDefinition(
        'WorkflowPauseTest.TwoStepWorkflow',
        'bulk'
      );

      Test.startTest();
      List<WorkflowEngine.StartResult> results = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{
          new WorkflowEngine.StartRequest(
            'WorkflowPauseTest.TwoStepWorkflow',
            'BulkPark-' + Datetime.now().getTime(),
            null
          )
        }
      );
      Test.stopTest();

      System.assertEquals(1, results.size(), 'One result expected');
      Workflow_Instance__c inst = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :results[0].instanceId
      ];
      System.assertEquals(
        'Paused',
        inst.Status__c,
        'Bulk start during a pause must park the instance'
      );
      List<Workflow_Step_Execution__c> steps = [
        SELECT Status__c, Timeout_At__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :results[0].instanceId
      ];
      System.assertEquals(1, steps.size(), 'Initial Pending step should exist');
      System.assertEquals('Pending', steps[0].Status__c, 'Step stays Pending');
      System.assertEquals(
        null,
        steps[0].Timeout_At__c,
        'Parked step must not start the timeout clock'
      );
    }
  }

  // A Cancel signal sent via the scalar signal() overload must reach and cancel a
  // Paused instance (Paused was missing from that overload's lookup statuses).
  @IsTest
  static void testScalarCancelSignalReachesPausedInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      String corrKey = 'ScalarCancel-' + Datetime.now().getTime();
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Paused',
        Current_Step__c = 'WorkflowPauseTest.StepB',
        Correlation_Key__c = corrKey
      );
      insert inst;

      Test.startTest();
      WorkflowEngine.signal(corrKey, 'Cancel', '{"runCompensations":false}');
      Test.stopTest();

      Workflow_Instance__c after = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Cancelled',
        after.Status__c,
        'A Cancel signal must reach and cancel a paused instance'
      );
    }
  }

  // Cancelling a parent must include Paused descendants in the traversal, or a
  // parked child is orphaned (still holding an active correlation reservation).
  @IsTest
  static void testCancelParentCancelsPausedChild() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c parent = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Running',
        Current_Step__c = 'WorkflowPauseTest.StepA',
        Correlation_Key__c = 'CancelParent-' + Datetime.now().getTime()
      );
      insert parent;
      Workflow_Instance__c child = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.SuspendingWorkflow',
        Status__c = 'Paused',
        Current_Step__c = 'WorkflowPauseTest.SuspendStep',
        Parent_Instance__c = parent.Id,
        Correlation_Key__c = 'CancelChild-' + Datetime.now().getTime()
      );
      insert child;

      Test.startTest();
      WorkflowEngine.cancel(parent.Id);
      Test.stopTest();

      Workflow_Instance__c afterChild = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :child.Id
      ];
      System.assertNotEquals(
        'Paused',
        afterChild.Status__c,
        'A paused child must be included in the parent cancellation traversal'
      );
      System.assert(
        afterChild.Status__c == 'Cancelled' ||
          afterChild.Status__c == 'Cancelling',
        'Paused child should be Cancelled/Cancelling, was: ' +
        afterChild.Status__c
      );
    }
  }

  // ============================================================
  // 15. PR #78 ROUND 2 REGRESSIONS
  // ============================================================

  // A running parent spawning a child whose definition is paused must park the
  // child (START_CHILD path was bypassing the pause gate).
  @IsTest
  static void testChildStartParksWhenChildDefPaused() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      spawnChildKey = 'PausedChild-' + Datetime.now().getTime();

      // Pause the CHILD definition (the parent is not paused).
      WorkflowPauseGate.pauseDefinition(
        'WorkflowPauseTest.TwoStepWorkflow',
        'child paused'
      );

      Workflow_Instance__c parent = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.ChildSpawningWorkflow',
        Status__c = 'Running',
        Current_Step__c = 'WorkflowPauseTest.SpawnChildStep',
        Correlation_Key__c = 'Parent-' + Datetime.now().getTime()
      );
      insert parent;
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = parent.Id,
        Step_Name__c = 'WorkflowPauseTest.SpawnChildStep',
        Status__c = 'Pending',
        Retry_Count__c = 0
      );

      Test.startTest();
      WorkflowEngine.runStep(parent.Id, 'WorkflowPauseTest.SpawnChildStep');
      Test.stopTest();

      List<Workflow_Instance__c> children = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c = :spawnChildKey
      ];
      System.assertEquals(1, children.size(), 'Child instance should exist');
      System.assertEquals(
        'Paused',
        children[0].Status__c,
        'Child of a paused definition must be parked, not executed'
      );
    }
  }

  // The dashboard Redeliver action must attach a captured (Unrouted) signal to a
  // matching Paused instance as Received (held), without waking it.
  @IsTest
  static void testRedeliverSignalToPausedInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      String corrKey = 'RedeliverPaused-' + Datetime.now().getTime();
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.SuspendingWorkflow',
        Status__c = 'Paused',
        Current_Step__c = 'WorkflowPauseTest.SuspendStep',
        Correlation_Key__c = corrKey
      );
      insert inst;
      Workflow_Signal__c sig = new Workflow_Signal__c(
        Signal_Name__c = 'WaitSignal',
        Correlation_Key__c = corrKey,
        Status__c = 'Unrouted'
      );
      insert sig;

      Test.startTest();
      Boolean matched = WorkflowEngine.redeliverCapturedSignal(sig.Id);
      Test.stopTest();

      System.assertEquals(
        true,
        matched,
        'Redeliver should match the paused instance'
      );
      Workflow_Signal__c after = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Id = :sig.Id
      ];
      System.assertEquals(
        'Received',
        after.Status__c,
        'Redelivered signal should be held (Received)'
      );
      System.assertEquals(
        inst.Id,
        after.Workflow_Instance__c,
        'Signal should be linked to the paused instance'
      );
      Workflow_Instance__c instAfter = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Paused',
        instAfter.Status__c,
        'Paused instance must NOT be woken by redelivery'
      );
    }
  }

  // Version drain must count Paused instances as non-terminal so a version with
  // parked work is not reported as safe to retire.
  @IsTest
  static void testVersionDrainTreatsPausedAsNonTerminal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String wf = 'WorkflowPauseTest.TwoStepWorkflow';
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = wf,
        Status__c = 'Paused',
        Definition_Version__c = 1,
        Current_Step__c = 'WorkflowPauseTest.StepB',
        Correlation_Key__c = 'VersionDrain-' + Datetime.now().getTime()
      );
      insert inst;

      Test.startTest();
      List<Map<String, Object>> drain = WorkflowDashboardController.getVersionDrain(
        wf
      );
      Test.stopTest();

      System.assertEquals(1, drain.size(), 'One version expected');
      System.assertEquals(
        1,
        (Integer) drain[0].get('nonTerminalCount'),
        'Paused instance must count as non-terminal'
      );
      System.assertEquals(
        false,
        drain[0].get('safeToRetire'),
        'A version with parked instances must NOT be safe to retire'
      );
    }
  }

  // The watchdog timeout batch must skip overdue steps whose parent is Paused, so
  // parked rows neither time out spuriously nor starve the bounded batch.
  @IsTest
  static void testWatchdogTimeoutSkipsPausedParentStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Paused',
        Current_Step__c = 'WorkflowPauseTest.StepB',
        Correlation_Key__c = 'PausedTimeout-' + Datetime.now().getTime()
      );
      insert inst;
      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowPauseTest.StepB',
        Status__c = 'Pending',
        Retry_Count__c = 0,
        Timeout_At__c = DateTime.now().addSeconds(-60)
      );
      insert step;
      WorkflowPauseGate.pauseDefinition(
        'WorkflowPauseTest.TwoStepWorkflow',
        'paused'
      );

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      Workflow_Step_Execution__c after = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :step.Id
      ];
      System.assertEquals(
        'Pending',
        after.Status__c,
        'A paused parent\'s overdue step must NOT be timed out by the watchdog'
      );
    }
  }

  // Pause matching is case-insensitive (Workflow_Name__c is a case-insensitive
  // external id), so a pause stored in one case is honored when checked in another.
  @IsTest
  static void testPauseNameMatchingIsCaseInsensitive() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      WorkflowPauseGate.pauseDefinition(
        'workflowpausetest.twostepworkflow',
        'lower'
      );
      Boolean paused = WorkflowPauseGate.isDefinitionPaused(
        'WorkflowPauseTest.TwoStepWorkflow'
      );
      Test.stopTest();

      System.assertEquals(
        true,
        paused,
        'isDefinitionPaused must match regardless of name casing'
      );
    }
  }

  // Smoke test for the resume re-arm path: resuming a parked instance flips it to
  // Running and runs reArmTimeoutsForResume without error.
  @IsTest
  static void testResumeReArmsTimeoutsWithoutError() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Paused',
        Current_Step__c = 'WorkflowPauseTest.StepB',
        Correlation_Key__c = 'ResumeReArm-' + Datetime.now().getTime()
      );
      insert inst;
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowPauseTest.StepB',
        Status__c = 'Pending',
        Retry_Count__c = 0
      );
      WorkflowPauseGate.pauseDefinition(
        'WorkflowPauseTest.TwoStepWorkflow',
        'rearm'
      );

      Test.startTest();
      WorkflowPauseGate.resumeDefinition('WorkflowPauseTest.TwoStepWorkflow');
      Test.stopTest();

      Workflow_Instance__c after = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Running',
        after.Status__c,
        'Resumed instance should be Running after re-arm'
      );
    }
  }

  // ============================================================
  // 16. PR #78 ROUND 7 REGRESSIONS
  // ============================================================

  // A Running (stuck) step must time out even when its definition is paused.
  // The pause gate only holds Pending (pre-start) steps; Running steps that are
  // stuck in a dead queueable stay Running (not parked), so reArmTimeoutsForResume
  // will not re-arm them on resume — clearing their deadline leaves them
  // permanently unenforceable.
  @IsTest
  static void testTimeoutJobTimesOutRunningStepDuringPause() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Running',
        Current_Step__c = 'WorkflowPauseTest.StepB',
        Correlation_Key__c = 'R7-Running-' + Datetime.now().getTime()
      );
      insert inst;
      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowPauseTest.StepB',
        Status__c = 'Running',
        Retry_Count__c = 0,
        Timeout_At__c = DateTime.now().addSeconds(-60)
      );
      insert step;
      WorkflowPauseGate.pauseDefinition(
        'WorkflowPauseTest.TwoStepWorkflow',
        'R7 running-step test'
      );

      Test.startTest();
      new WorkflowTimeoutJob(inst.Id, 'WorkflowPauseTest.StepB')
        .executeInternal();
      Test.stopTest();

      Workflow_Step_Execution__c after = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :step.Id
      ];
      System.assertEquals(
        'Failed',
        after.Status__c,
        'Running step must time out even during a pause (not be left hanging)'
      );
    }
  }

  // The watchdog heartbeat must also enforce timeouts on Running stuck steps
  // during a pause — symmetric with the WorkflowTimeoutJob fix.
  @IsTest
  static void testWatchdogTimesOutRunningStepDuringPause() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Running',
        Current_Step__c = 'WorkflowPauseTest.StepB',
        Correlation_Key__c = 'R7-HBRun-' + Datetime.now().getTime()
      );
      insert inst;
      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowPauseTest.StepB',
        Status__c = 'Running',
        Retry_Count__c = 0,
        Timeout_At__c = DateTime.now().addSeconds(-60)
      );
      insert step;
      WorkflowPauseGate.pauseDefinition(
        'WorkflowPauseTest.TwoStepWorkflow',
        'R7 heartbeat-running test'
      );

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      Workflow_Step_Execution__c after = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :step.Id
      ];
      System.assertEquals(
        'Failed',
        after.Status__c,
        'Watchdog must time out a Running stuck step even during a pause'
      );
    }
  }

  // A stale QueueableTimeoutJob that fires after a pause/resume re-arm must NOT
  // fail a step whose Timeout_At__c is still in the future (re-armed deadline).
  @IsTest
  static void testStaleTimeoutJobSkipsStepWithFutureDeadline() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Running',
        Current_Step__c = 'WorkflowPauseTest.StepB',
        Correlation_Key__c = 'R7-Stale-' + Datetime.now().getTime()
      );
      insert inst;
      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowPauseTest.StepB',
        Status__c = 'Pending',
        Retry_Count__c = 0,
        Timeout_At__c = DateTime.now().addSeconds(600)
      );
      insert step;

      Test.startTest();
      new WorkflowTimeoutJob(inst.Id, 'WorkflowPauseTest.StepB')
        .executeInternal();
      Test.stopTest();

      Workflow_Step_Execution__c after = [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :step.Id
      ];
      System.assertEquals(
        'Pending',
        after.Status__c,
        'Stale timeout job must not fail a step whose deadline is still in the future'
      );
    }
  }

  // Paused instances must appear in the active bucket of getWorkflowStats(),
  // not silently disappear from all three counters.
  @IsTest
  static void testGetWorkflowStatsCountsPausedAsActive() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowPauseTest.TwoStepWorkflow',
        Status__c = 'Paused',
        Current_Step__c = 'WorkflowPauseTest.StepB',
        Correlation_Key__c = 'R7-Stats-' + Datetime.now().getTime()
      );
      insert inst;

      Test.startTest();
      WorkflowDashboardController.InstanceQuery statsQuery = new WorkflowDashboardController.InstanceQuery();
      statsQuery.workflowName = 'WorkflowPauseTest.TwoStepWorkflow';
      Map<String, Integer> stats = WorkflowDashboardController.getWorkflowStats(
        statsQuery
      );
      Test.stopTest();

      System.assertEquals(1, stats.get('total'), 'One total instance expected');
      System.assertEquals(
        1,
        stats.get('active'),
        'Paused instance must count as active in getWorkflowStats'
      );
      System.assertEquals(0, stats.get('completed'), 'No completed');
      System.assertEquals(0, stats.get('failed'), 'No failed');
    }
  }
}
