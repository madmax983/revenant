/**
 * @description Engine tests for strict determinism mode (issue #102). A step
 * waits, then the engine runs it again with the same inputs (a duplicate
 * delivery or an operator resume). A step that changes its routing decision
 * fails with STEP_NON_DETERMINISM. A step that repeats its wait, reads a new
 * signal, or uses a capture-once value does not fail.
 */
// Public: WorkflowEngine.start authorizes a definition through
// ApexTypeImplementor, which does not list inner classes of a private class.
@IsTest
public class WorkflowStrictDeterminismTest {
  private static final String GATE = 'WorkflowStrictDeterminismTest.GateStep';
  private static final String NEXT = 'WorkflowStrictDeterminismTest.NextStep';
  private static final String OTHER = 'WorkflowStrictDeterminismTest.OtherStep';
  private static final String CHARGE = 'WorkflowStrictDeterminismTest.ChargeStep';
  private static final String COMP_GATE = 'WorkflowStrictDeterminismTest.CompGateStep';
  private static final String RECOVER = 'WorkflowStrictDeterminismTest.RecoverStep';
  private static final String CHILD_WF = 'WorkflowStrictDeterminismTest.ChildWorkflow';

  /** @description Decision the gate steps return on their next run. */
  public static String mode = 'wait';
  /** @description Live value that the capture-once producer reads. */
  public static String liveTier = 'gold';
  /** @description Error message the error-routing workflow received. */
  public static String routedError;

  // ============================================================
  // FIXTURES
  // ============================================================

  /**
   * @description Gate, then Next or Other. The gate's complete() hint selects
   * the next step.
   */
  public class GateWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ GATE, NEXT, OTHER };
    }
    /**
     * @description Names the first step.
     * @return The gate step.
     */
    public String getInitialStep() {
      return GATE;
    }
    /**
     * @description Routes the gate by its hint. Next and Other end the run.
     * @param currentStepName The completed step.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == GATE) {
        String hint = result.directive().nextStepName;
        return String.isNotBlank(hint) ? hint : NEXT;
      }
      return null;
    }
  }

  /**
   * @description Gate workflow that routes a failure to RecoverStep (issue #90).
   */
  public class RoutedGateWorkflow implements ErrorRoutingWorkflow {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ GATE, NEXT, OTHER, RECOVER };
    }
    /**
     * @description Names the first step.
     * @return The gate step.
     */
    public String getInitialStep() {
      return GATE;
    }
    /**
     * @description Routes the gate by its hint. Other steps end the run.
     * @param currentStepName The completed step.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == GATE) {
        String hint = result.directive().nextStepName;
        return String.isNotBlank(hint) ? hint : NEXT;
      }
      return null;
    }
    /**
     * @description Keeps the error message and routes to RecoverStep.
     * @param failedStepName The failed step.
     * @param error The failure details.
     * @return The recovery step.
     */
    public String getErrorStep(String failedStepName, StepError error) {
      routedError = error.errorMessage;
      return RECOVER;
    }
  }

  /**
   * @description Charge (compensatable), then CompGate, then Next.
   */
  public class SagaWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ CHARGE, COMP_GATE, NEXT };
    }
    /**
     * @description Names the first step.
     * @return The charge step.
     */
    public String getInitialStep() {
      return CHARGE;
    }
    /**
     * @description Charge goes to CompGate. CompGate goes to Next.
     * @param currentStepName The completed step.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == CHARGE) {
        return COMP_GATE;
      }
      if (currentStepName == COMP_GATE) {
        return NEXT;
      }
      return null;
    }
  }

  /**
   * @description Child workflow with one step.
   */
  public class ChildWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the step.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ NEXT };
    }
    /**
     * @description Names the first step.
     * @return The next step.
     */
    public String getInitialStep() {
      return NEXT;
    }
    /**
     * @description Ends after the step.
     * @param currentStepName The completed step.
     * @param result The step result.
     * @return Null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  /**
   * @description Returns the decision that the static mode selects.
   */
  public class GateStep implements WorkflowStep {
    /**
     * @description Returns the decision for the current mode.
     * @param ctx The step context.
     * @return The step result.
     */
    public StepResult execute(StepContext ctx) {
      switch on mode {
        when 'complete' {
          return StepResult.complete(OTHER, null);
        }
        when 'timeoutA' {
          return StepResult.suspend(3600, NEXT);
        }
        when 'timeoutB' {
          return StepResult.suspend(3600, OTHER);
        }
        when 'approvalA' {
          return StepResult.waitForApproval('KeyA', null);
        }
        when 'approvalB' {
          return StepResult.waitForApproval('KeyB', null);
        }
        when 'signal' {
          return ctx.signals().hasSignal('Go')
            ? StepResult.complete(NEXT, null)
            : StepResult.suspend();
        }
        when 'resume' {
          return String.isBlank(ctx.stepStateJson)
            ? StepResult.suspend()
            : StepResult.complete(OTHER, null);
        }
        when 'childA' {
          return StepResult.startChild(
            CHILD_WF,
            'ChildA-' + ctx.workflowInstanceId,
            null
          );
        }
        when 'childB' {
          return StepResult.startChild(
            CHILD_WF,
            'ChildB-' + ctx.workflowInstanceId,
            null
          );
        }
        when 'raceSignal' {
          // A signal arrives after the input snapshot, then the step sees it.
          insert new Workflow_Signal__c(
            Workflow_Instance__c = ctx.workflowInstanceId,
            Signal_Name__c = 'Late',
            Status__c = 'Received'
          );
          return StepResult.complete(OTHER, null);
        }
        when 'cfgRoute' {
          // The route depends on the payload of a live Cfg signal.
          StepContext.Signal cfg = ctx.signals().getSignal('Cfg');
          return cfg.isPresent() && cfg.payload == 'B'
            ? StepResult.complete(OTHER, null)
            : StepResult.suspend();
        }
        when 'captured' {
          String tier = (String) ctx.captures()
            .once('tier', new TierProducer());
          return tier == 'gold'
            ? StepResult.suspend()
            : StepResult.complete(OTHER, null);
        }
        when else {
          return StepResult.suspend();
        }
      }
    }
  }

  /**
   * @description Capture-once producer that reads the live tier.
   */
  public class TierProducer implements CaptureProducer {
    /**
     * @description Returns the live tier.
     * @return The tier.
     */
    public Object produce() {
      return liveTier;
    }
  }

  /**
   * @description Compensatable gate: waits, or completes in 'complete' mode.
   */
  public class CompGateStep implements CompensatableStep {
    /**
     * @description Waits, or completes in 'complete' mode.
     * @param ctx The step context.
     * @return The step result.
     */
    public StepResult execute(StepContext ctx) {
      return mode == 'complete'
        ? StepResult.complete(null, null)
        : StepResult.suspend();
    }
    /**
     * @description Undoes nothing.
     * @param ctx The step context.
     * @return A completed result.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  /**
   * @description Compensatable first step of the saga.
   */
  public class ChargeStep implements CompensatableStep {
    /**
     * @description Completes.
     * @param ctx The step context.
     * @return A completed result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
    /**
     * @description Refunds.
     * @param ctx The step context.
     * @return A completed result.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  /** @description Terminal step. */
  public class NextStep implements WorkflowStep {
    /**
     * @description Completes.
     * @param ctx The step context.
     * @return A completed result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  /** @description Terminal step of the divergent route. */
  public class OtherStep implements WorkflowStep {
    /**
     * @description Completes.
     * @param ctx The step context.
     * @return A completed result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  /** @description Error step of RoutedGateWorkflow. */
  public class RecoverStep implements WorkflowStep {
    /**
     * @description Completes.
     * @param ctx The step context.
     * @return A completed result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  // ============================================================
  // HELPERS
  // ============================================================

  // Starts the workflow and runs the first hop. Strict mode is on unless the
  // test turns it off.
  private static Id startAndRun(String workflowName, String firstMode) {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.strictDeterminism = true;
    mode = firstMode;
    Id instId = WorkflowEngine.start(
      workflowName,
      'Strict-' + firstMode + '-' + Crypto.getRandomInteger(),
      null
    );
    WorkflowEngine.runStep(instId);
    return instId;
  }

  private static Workflow_Instance__c load(Id instId) {
    return [
      SELECT
        Status__c,
        Current_Step__c,
        Failure_Category__c,
        Error_Message__c,
        Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Id = :instId
    ];
  }

  private static List<Workflow_Step_Execution__c> rows(
    Id instId,
    String stepName
  ) {
    return [
      SELECT Status__c, Error_Details__c, Decision_Record__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instId AND Step_Name__c = :stepName
      ORDER BY CreatedDate, Id
    ];
  }

  private static Integer divergenceLogCount(Id instId) {
    return [
      SELECT COUNT()
      FROM Workflow_Log__c
      WHERE
        Workflow_Instance__c = :instId
        AND Log_Type__c = :WorkflowDeterminismGuard.LOG_TYPE
    ];
  }

  // ============================================================
  // DIVERGENCE IS DETECTED
  // ============================================================

  @IsTest
  static void divergentRerunFailsBeforeAdvance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRun(GateWorkflow.class.getName(), 'wait');
      Assert.areEqual('Suspended', load(instId).Status__c, 'The gate waits');
      Assert.isNotNull(
        rows(instId, GATE)[0].Decision_Record__c,
        'The wait decision is recorded'
      );

      mode = 'complete'; // live data changed; no new input
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      Workflow_Instance__c inst = load(instId);
      Assert.areEqual(
        'Failed',
        inst.Status__c,
        'The divergence fails the instance'
      );
      Assert.areEqual(
        WorkflowEngine.CAT_STEP_NON_DETERMINISM,
        inst.Failure_Category__c,
        'The category is STEP_NON_DETERMINISM'
      );
      Assert.areEqual(
        GATE,
        inst.Current_Step__c,
        'The instance did not advance'
      );
      Assert.isTrue(
        inst.Error_Message__c.contains(WorkflowDeterminismGuard.MESSAGE_PREFIX),
        'Error names the category: ' + inst.Error_Message__c
      );

      List<Workflow_Step_Execution__c> gateRows = rows(instId, GATE);
      Assert.areEqual(1, gateRows.size(), 'No new gate row');
      Assert.areEqual(
        'Failed',
        gateRows[0].Status__c,
        'The gate row is Failed'
      );
      Assert.isTrue(
        gateRows[0].Error_Details__c.contains('SUSPEND timeout=null'),
        'Error shows the recorded decision: ' + gateRows[0].Error_Details__c
      );
      Assert.isTrue(
        gateRows[0].Error_Details__c.contains('COMPLETE next="' + OTHER + '"'),
        'Error shows the new decision: ' + gateRows[0].Error_Details__c
      );
      Assert.areEqual(
        0,
        rows(instId, OTHER).size(),
        'The divergent next step has no row'
      );
      Assert.areEqual(1, divergenceLogCount(instId), 'One divergence log row');
    }
  }

  @IsTest
  static void divergenceDoesNotPushCompensation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRun(SagaWorkflow.class.getName(), 'wait');
      WorkflowEngine.runStep(instId); // CompGate waits
      Assert.areEqual('Suspended', load(instId).Status__c, 'CompGate waits');

      mode = 'complete';
      WorkflowEngine.runStep(instId);
      Workflow_Instance__c afterDivergence = load(instId);
      Assert.isFalse(
        String.valueOf(afterDivergence.Compensation_Stack__c)
          .contains('CompGateStep'),
        'The divergent step is not on the stack: ' +
        afterDivergence.Compensation_Stack__c
      );

      WorkflowTestHarness.Result result = new WorkflowTestHarness(instId)
        .drive();
      Test.stopTest();

      Assert.areEqual('Compensated', result.status, 'The saga rolls back');
      Assert.areEqual(
        new List<String>{ CHARGE + '_Compensate' },
        result.compensatedSteps,
        'Only the completed forward step is undone'
      );
      Assert.areEqual(1, divergenceLogCount(instId), 'One divergence log row');
    }
  }

  @IsTest
  static void changedTimeoutRouteIsDivergence() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRun(GateWorkflow.class.getName(), 'timeoutA');
      // The first wait writes step state, so the second run records again.
      WorkflowEngine.runStep(instId);
      mode = 'timeoutB';
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      Workflow_Instance__c inst = load(instId);
      Assert.areEqual(
        'Failed',
        inst.Status__c,
        'The divergence fails the instance'
      );
      Assert.areEqual(
        WorkflowEngine.CAT_STEP_NON_DETERMINISM,
        inst.Failure_Category__c,
        'The category is STEP_NON_DETERMINISM'
      );
    }
  }

  @IsTest
  static void changedApprovalKeyIsDivergence() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRun(GateWorkflow.class.getName(), 'approvalA');
      // The first wait writes step state, so the second run records again.
      WorkflowEngine.runStep(instId);
      mode = 'approvalB';
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      Assert.areEqual(
        WorkflowEngine.CAT_STEP_NON_DETERMINISM,
        load(instId).Failure_Category__c,
        'The category is STEP_NON_DETERMINISM'
      );
    }
  }

  @IsTest
  static void changedChildKeyIsDivergence() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRun(GateWorkflow.class.getName(), 'childA');
      // The first wait writes step state, so the second run records again.
      WorkflowEngine.runStep(instId);
      mode = 'childB';
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      Assert.areEqual(
        WorkflowEngine.CAT_STEP_NON_DETERMINISM,
        load(instId).Failure_Category__c,
        'A different child on equal inputs is a divergence'
      );
      Assert.areEqual(
        0,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE
            Parent_Instance__c = :instId
            AND Correlation_Key__c LIKE 'ChildB-%'
        ],
        'The divergent child does not start'
      );
    }
  }

  @IsTest
  static void errorRoutingReceivesDivergence() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRun(RoutedGateWorkflow.class.getName(), 'wait');
      mode = 'complete';
      WorkflowEngine.runStep(instId); // divergence -> RecoverStep
      Assert.areEqual(
        RECOVER,
        load(instId).Current_Step__c,
        'The error step is current'
      );
      WorkflowEngine.runStep(instId); // RecoverStep completes
      Test.stopTest();

      Assert.areEqual(
        'Completed',
        load(instId).Status__c,
        'The error step completes the run'
      );
      Assert.isTrue(
        routedError.startsWith(WorkflowDeterminismGuard.MESSAGE_PREFIX),
        'The error handler sees the category: ' + routedError
      );
      Assert.areEqual(
        0,
        rows(instId, OTHER).size(),
        'The divergent next step has no row'
      );
      Assert.areEqual(
        1,
        divergenceLogCount(instId),
        'The log row keeps the category when the error is routed'
      );
    }
  }

  // ============================================================
  // NO FALSE POSITIVES
  // ============================================================

  @IsTest
  static void sameWaitOnRerunPasses() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRun(GateWorkflow.class.getName(), 'approvalA');
      WorkflowEngine.runStep(instId);
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      Workflow_Instance__c inst = load(instId);
      Assert.areEqual('Suspended', inst.Status__c, 'The step still waits');
      Assert.isNull(inst.Failure_Category__c, 'No failure category');
      Assert.areEqual(0, divergenceLogCount(instId), 'No divergence');
    }
  }

  @IsTest
  static void newSignalAllowsNewDecision() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      WorkflowEngine.strictDeterminism = true;
      mode = 'signal';
      String key = 'Strict-signal-' + Crypto.getRandomInteger();
      Id instId = WorkflowEngine.start(GateWorkflow.class.getName(), key, null);
      WorkflowTestHarness harness = new WorkflowTestHarness(instId);
      WorkflowTestHarness.Result waiting = harness.drive();
      Assert.isTrue(waiting.isSuspended, 'The gate waits for Go');

      WorkflowTestHarness.Result done = harness.injectSignal(key, 'Go', null);
      Test.stopTest();

      Assert.areEqual(
        'Completed',
        done.status,
        'The new signal completes the run'
      );
      Assert.isTrue(done.reachedStep(NEXT), 'The run reaches Next');
      Assert.areEqual(0, divergenceLogCount(instId), 'No divergence');
    }
  }

  @IsTest
  static void liveSignalPayloadEditIsNotDivergence() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      WorkflowEngine.strictDeterminism = true;
      mode = 'cfgRoute';
      Id instId = WorkflowEngine.start(
        GateWorkflow.class.getName(),
        'Strict-cfg-' + Crypto.getRandomInteger(),
        null
      );
      Workflow_Signal__c cfg = new Workflow_Signal__c(
        Workflow_Instance__c = instId,
        Signal_Name__c = 'Cfg',
        Payload__c = 'A',
        Status__c = 'Received'
      );
      insert cfg;
      WorkflowEngine.runStep(instId); // Cfg is A: the gate waits.
      Assert.areEqual('Suspended', load(instId).Status__c, 'The gate waits');

      // An admin edits the live signal. The route change is legal.
      cfg.Payload__c = 'B';
      update cfg;
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      Assert.areEqual(
        1,
        rows(instId, OTHER).size(),
        'The edited signal routes the run to Other'
      );
      Assert.areEqual(0, divergenceLogCount(instId), 'No divergence');
    }
  }

  @IsTest
  static void resumePayloadIsANewInput() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRun(GateWorkflow.class.getName(), 'resume');
      Assert.areEqual('Suspended', load(instId).Status__c, 'The gate waits');

      WorkflowResumeService.resumeInstance(instId, '{"status":200}');
      WorkflowEngine.runStep(instId); // Gate reads the payload -> Other
      WorkflowEngine.runStep(instId); // Other completes
      Test.stopTest();

      Assert.areEqual(
        'Completed',
        load(instId).Status__c,
        'A resume payload lets the step make a new decision'
      );
      Assert.areEqual(0, divergenceLogCount(instId), 'No divergence');
    }
  }

  @IsTest
  static void signalAfterTheSnapshotIsNotDivergence() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRun(GateWorkflow.class.getName(), 'wait');
      mode = 'raceSignal';
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      Assert.areEqual(
        1,
        rows(instId, OTHER).size(),
        'A signal that arrives during the run allows a new decision'
      );
      Assert.areEqual(0, divergenceLogCount(instId), 'No divergence');
    }
  }

  @IsTest
  static void resumeWithoutPayloadKeepsTheRecord() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRun(GateWorkflow.class.getName(), 'wait');
      // An operator resume with no payload is not a new input.
      WorkflowResumeService.resumeInstance(instId, null);
      Assert.isNotNull(
        rows(instId, GATE)[0].Decision_Record__c,
        'A resume without a payload keeps the record'
      );
      mode = 'complete';
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      Assert.areEqual(
        WorkflowEngine.CAT_STEP_NON_DETERMINISM,
        load(instId).Failure_Category__c,
        'A new decision after a payload-less resume is a divergence'
      );
    }
  }

  @IsTest
  static void captureOnceValueIsNotDivergence() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      liveTier = 'gold';
      Id instId = startAndRun(GateWorkflow.class.getName(), 'captured');
      liveTier = 'silver'; // live data changed; once() replays 'gold'
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      Workflow_Instance__c inst = load(instId);
      Assert.areEqual('Suspended', inst.Status__c, 'once() keeps the wait');
      Assert.isNull(inst.Failure_Category__c, 'No failure category');
      Assert.areEqual(0, divergenceLogCount(instId), 'No divergence');
    }
  }

  @IsTest
  static void recordWithoutStrictModeIsIgnored() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRun(GateWorkflow.class.getName(), 'wait');
      Assert.isNotNull(
        rows(instId, GATE)[0].Decision_Record__c,
        'Strict mode records the wait'
      );
      WorkflowEngine.strictDeterminism = false; // operator turns it off
      mode = 'complete';
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      Assert.areEqual(1, rows(instId, OTHER).size(), 'The gate advanced');
      Assert.isNull(
        rows(instId, GATE)[0].Decision_Record__c,
        'Off removes the old record'
      );
      Assert.areEqual(0, divergenceLogCount(instId), 'No divergence');
    }
  }

  @IsTest
  static void strictModeOffKeepsLegacyBehavior() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.strictDeterminism = false;
      mode = 'wait';
      Id instId = WorkflowEngine.start(
        GateWorkflow.class.getName(),
        'Strict-legacy-' + Crypto.getRandomInteger(),
        null
      );
      WorkflowEngine.runStep(instId); // Gate waits
      mode = 'complete';
      WorkflowEngine.runStep(instId); // Gate -> Other
      WorkflowEngine.runStep(instId); // Other completes
      Test.stopTest();

      Workflow_Instance__c inst = load(instId);
      Assert.areEqual('Completed', inst.Status__c, 'Off: the run completes');
      Assert.isNull(inst.Failure_Category__c, 'No failure category');
      Assert.areEqual(
        1,
        rows(instId, OTHER).size(),
        'Off: the gate advances to Other'
      );
      Assert.areEqual(0, divergenceLogCount(instId), 'No divergence');
    }
  }

  @IsTest
  static void strictModeOffWritesNoRecord() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.strictDeterminism = false;
      mode = 'wait';
      Id instId = WorkflowEngine.start(
        GateWorkflow.class.getName(),
        'Strict-off-' + Crypto.getRandomInteger(),
        null
      );
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      Assert.isNull(
        rows(instId, GATE)[0].Decision_Record__c,
        'Off writes no record'
      );
    }
  }

  @IsTest
  static void operatorRetryAcceptsTheNewDecision() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRun(GateWorkflow.class.getName(), 'wait');
      mode = 'complete';
      WorkflowEngine.runStep(instId);
      Assert.areEqual(
        'Failed',
        load(instId).Status__c,
        'The divergence fails the instance'
      );

      WorkflowRetryService.retryWorkflow(instId);
      Assert.isNull(
        rows(instId, GATE)[0].Decision_Record__c,
        'Retry clears the record'
      );
      WorkflowEngine.runStep(instId); // Gate -> Other
      WorkflowEngine.runStep(instId); // Other completes
      Test.stopTest();

      Assert.areEqual(
        'Completed',
        load(instId).Status__c,
        'The retried run completes'
      );
      Assert.areEqual(
        1,
        rows(instId, OTHER).size(),
        'The new decision routes to Other'
      );
    }
  }
}
