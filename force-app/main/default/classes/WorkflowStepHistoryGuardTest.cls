/**
 * @description Tests for the step-history guard (issue #112). Below the warn
 * threshold nothing changes. At the warn threshold the engine writes one
 * warning row and the dashboard shows it. At the ceiling the engine fails the
 * instance with STEP_HISTORY_LIMIT. Continue-As-New starts a new count.
 */
// Public: WorkflowEngine.start authorizes a definition through
// ApexTypeImplementor, which does not list inner classes of a private class.
@IsTest
public class WorkflowStepHistoryGuardTest {
  private static final String LOOP_STEP = 'WorkflowStepHistoryGuardTest.LoopStep';
  private static final String DONE = 'WorkflowStepHistoryGuardTest.DoneStep';
  private static final String CHARGE = 'WorkflowStepHistoryGuardTest.ChargeStep';
  private static final String RECOVER = 'WorkflowStepHistoryGuardTest.RecoverStep';
  private static final String CAN_STEP = 'WorkflowStepHistoryGuardTest.CanStep';

  /** @description Loop visits left before LoopStep routes to DoneStep. */
  public static Integer loopsLeft = 100;
  /** @description Number of LoopStep runs. */
  public static Integer loopRuns = 0;
  /** @description True when the engine asked for an error step. */
  public static Boolean errorStepAsked = false;
  /** @description CanStep runs in the current generation. */
  public static Integer canHop = 0;
  /** @description Continue-As-New calls left. */
  public static Integer generationsLeft = 1;

  // ============================================================
  // FIXTURES
  // ============================================================

  /** @description LoopStep loops to itself, then DoneStep ends the run. */
  public class LoopWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ LOOP_STEP, DONE };
    }
    /**
     * @description Names the first step.
     * @return The loop step.
     */
    public String getInitialStep() {
      return LOOP_STEP;
    }
    /**
     * @description Routes by the step hint.
     * @param currentStepName The completed step.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return result.directive().nextStepName;
    }
  }

  /** @description LoopWorkflow with an error step (issue #90). */
  public class RoutedLoopWorkflow implements ErrorRoutingWorkflow {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ LOOP_STEP, DONE, RECOVER };
    }
    /**
     * @description Names the first step.
     * @return The loop step.
     */
    public String getInitialStep() {
      return LOOP_STEP;
    }
    /**
     * @description Routes by the step hint.
     * @param currentStepName The completed step.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return result.directive().nextStepName;
    }
    /**
     * @description Records the call and routes to RecoverStep.
     * @param failedStepName The failed step.
     * @param error The failure details.
     * @return The recovery step.
     */
    public String getErrorStep(String failedStepName, StepError error) {
      errorStepAsked = true;
      return RECOVER;
    }
  }

  /** @description ChargeStep (compensatable), then LoopStep. */
  public class SagaLoopWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ CHARGE, LOOP_STEP, DONE };
    }
    /**
     * @description Names the first step.
     * @return The charge step.
     */
    public String getInitialStep() {
      return CHARGE;
    }
    /**
     * @description Charge goes to LoopStep. Other steps use the hint.
     * @param currentStepName The completed step.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == CHARGE) {
        return LOOP_STEP;
      }
      return result.directive().nextStepName;
    }
  }

  /** @description CanStep only. It continues as new. */
  public class CanWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ CAN_STEP };
    }
    /**
     * @description Names the first step.
     * @return The CAN step.
     */
    public String getInitialStep() {
      return CAN_STEP;
    }
    /**
     * @description Routes by the step hint.
     * @param currentStepName The completed step.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return result.directive().nextStepName;
    }
  }

  /** @description Loops to itself while loopsLeft > 0. */
  public class LoopStep implements WorkflowStep {
    /**
     * @description Loops or ends.
     * @param ctx The step context.
     * @return COMPLETE to LoopStep or DoneStep.
     */
    public StepResult execute(StepContext ctx) {
      loopRuns++;
      if (loopsLeft > 0) {
        loopsLeft--;
        return StepResult.complete(LOOP_STEP, null);
      }
      return StepResult.complete(DONE, null);
    }
  }

  /** @description Ends the run. */
  public class DoneStep implements WorkflowStep {
    /**
     * @description Completes.
     * @param ctx The step context.
     * @return COMPLETE with no next step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  /** @description Error step. */
  public class RecoverStep implements WorkflowStep {
    /**
     * @description Completes.
     * @param ctx The step context.
     * @return COMPLETE with no next step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  /** @description Compensatable step. */
  public class ChargeStep implements CompensatableStep {
    /**
     * @description Completes.
     * @param ctx The step context.
     * @return COMPLETE.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
    /**
     * @description Undoes the charge.
     * @param ctx The step context.
     * @return COMPLETE.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  /**
   * @description Visit 1 loops. Visit 2 continues as new while
   * generationsLeft > 0, else ends the run.
   */
  public class CanStep implements WorkflowStep {
    /**
     * @description Loops, continues as new, or ends.
     * @param ctx The step context.
     * @return COMPLETE or CONTINUE_AS_NEW.
     */
    public StepResult execute(StepContext ctx) {
      canHop++;
      if (canHop == 1) {
        return StepResult.complete(CAN_STEP, null);
      }
      canHop = 0;
      if (generationsLeft > 0) {
        generationsLeft--;
        return StepResult.continueAsNew(null);
      }
      return StepResult.complete(null, null);
    }
  }

  // ============================================================
  // HELPERS
  // ============================================================

  private static void setThresholds(Integer warn, Integer ceiling) {
    WorkflowEngine.stepHistoryWarnThreshold = warn;
    WorkflowEngine.stepHistoryCeiling = ceiling;
  }

  private static Id start(String workflowName) {
    WorkflowEngine.disableQueueableInTest = true;
    return WorkflowEngine.start(
      workflowName,
      'History-' + Crypto.getRandomInteger(),
      null
    );
  }

  // Inserts completed filler rows so that the instance has `total` rows.
  private static void seedRows(Id instId, Integer total) {
    Integer existing = rowCount(instId);
    List<Workflow_Step_Execution__c> filler = new List<Workflow_Step_Execution__c>();
    for (Integer i = existing; i < total; i++) {
      filler.add(
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = instId,
          Step_Name__c = 'Seed_' + i,
          Status__c = 'Completed',
          Retry_Count__c = 0
        )
      );
    }
    insert filler;
  }

  private static Integer rowCount(Id instId) {
    return [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instId
    ];
  }

  private static List<Workflow_Step_Execution__c> snapshot(Id instId) {
    return [
      SELECT
        Id,
        Step_Name__c,
        Status__c,
        Output__c,
        Timeout_At__c,
        SystemModstamp
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instId
      ORDER BY Id
    ];
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

  private static List<Workflow_Log__c> warnings(Id instId) {
    return [
      SELECT Level__c, Message__c, Fire_Key__c, Workflow_Instance__c
      FROM Workflow_Log__c
      WHERE
        Workflow_Instance__c = :instId
        AND Log_Type__c = :WorkflowStepHistoryGuard.LOG_TYPE
    ];
  }

  private static WorkflowStepRunner.RunStepContext ctxFor(
    Workflow_Instance__c inst
  ) {
    WorkflowStepRunner.RunStepContext ctx = new WorkflowStepRunner.RunStepContext();
    ctx.instanceId = inst.Id;
    ctx.instance = inst;
    ctx.activeStepName = LOOP_STEP;
    return ctx;
  }

  // ============================================================
  // SPEC: resolve and evaluate
  // ============================================================

  @IsTest
  static void resolveUsesDefaultsForBlankOrNegative() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepHistoryGuard.Thresholds t = WorkflowStepHistoryGuard.resolve(
        null,
        null
      );
      Assert.areEqual(5000, t.warn, 'Blank warn uses the default');
      Assert.areEqual(10000, t.ceiling, 'Blank ceiling uses the default');

      t = WorkflowStepHistoryGuard.resolve(-1, -5);
      Assert.areEqual(5000, t.warn, 'Negative warn uses the default');
      Assert.areEqual(10000, t.ceiling, 'Negative ceiling uses the default');
    }
  }

  @IsTest
  static void resolveZeroTurnsACheckOff() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepHistoryGuard.Thresholds t = WorkflowStepHistoryGuard.resolve(
        0,
        800
      );
      Assert.areEqual(0, t.warn, 'Warn 0 is off');
      Assert.areEqual(800, t.ceiling, 'Ceiling is kept');

      t = WorkflowStepHistoryGuard.resolve(300, 0);
      Assert.areEqual(300, t.warn, 'Warn is kept');
      Assert.areEqual(0, t.ceiling, 'Ceiling 0 is off');
    }
  }

  @IsTest
  static void resolveClampsToTheMaximum() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepHistoryGuard.Thresholds t = WorkflowStepHistoryGuard.resolve(
        0,
        45000
      );
      Assert.areEqual(
        WorkflowStepHistoryGuard.MAX_THRESHOLD,
        t.ceiling,
        'Ceiling is clamped'
      );

      t = WorkflowStepHistoryGuard.resolve(60000, 0);
      Assert.areEqual(
        WorkflowStepHistoryGuard.MAX_THRESHOLD,
        t.warn,
        'Warn is clamped'
      );
    }
  }

  @IsTest
  static void resolveKeepsWarnBelowCeiling() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepHistoryGuard.Thresholds t = WorkflowStepHistoryGuard.resolve(
        900,
        600
      );
      Assert.areEqual(300, t.warn, 'Warn >= ceiling uses half the ceiling');
      Assert.areEqual(600, t.ceiling, 'Ceiling is kept');

      t = WorkflowStepHistoryGuard.resolve(600, 600);
      Assert.areEqual(300, t.warn, 'Warn = ceiling uses half the ceiling');
    }
  }

  @IsTest
  static void evaluateFollowsTheDecisionTable() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepHistoryGuard.Thresholds t = new WorkflowStepHistoryGuard.Thresholds(
        3,
        5
      );
      Assert.areEqual(
        WorkflowStepHistoryGuard.Verdict.OK,
        WorkflowStepHistoryGuard.evaluate(2, t),
        'Below warn'
      );
      Assert.areEqual(
        WorkflowStepHistoryGuard.Verdict.WARN,
        WorkflowStepHistoryGuard.evaluate(3, t),
        'At warn'
      );
      Assert.areEqual(
        WorkflowStepHistoryGuard.Verdict.WARN,
        WorkflowStepHistoryGuard.evaluate(4, t),
        'Between warn and ceiling'
      );
      Assert.areEqual(
        WorkflowStepHistoryGuard.Verdict.HALT,
        WorkflowStepHistoryGuard.evaluate(5, t),
        'At ceiling'
      );

      WorkflowStepHistoryGuard.Thresholds warnOff = new WorkflowStepHistoryGuard.Thresholds(
        0,
        5
      );
      Assert.areEqual(
        WorkflowStepHistoryGuard.Verdict.OK,
        WorkflowStepHistoryGuard.evaluate(4, warnOff),
        'Warn off'
      );
      Assert.areEqual(
        WorkflowStepHistoryGuard.Verdict.HALT,
        WorkflowStepHistoryGuard.evaluate(5, warnOff),
        'Ceiling still on'
      );

      WorkflowStepHistoryGuard.Thresholds ceilingOff = new WorkflowStepHistoryGuard.Thresholds(
        3,
        0
      );
      Assert.areEqual(
        WorkflowStepHistoryGuard.Verdict.WARN,
        WorkflowStepHistoryGuard.evaluate(99999, ceilingOff),
        'Ceiling off never halts'
      );
    }
  }

  @IsTest
  static void engineWorkflowsAreExempt() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      for (
        String name : new List<String>{
          'WatchdogWorkflow',
          'CleanupWorkflow',
          'BulkRedriveWorkflow',
          'BulkCancelWorkflow',
          'ArchiveWorkflow',
          'ns.WatchdogWorkflow'
        }
      ) {
        Assert.isTrue(
          WorkflowStepHistoryGuard.isExempt(name),
          name + ' is exempt'
        );
      }
      Assert.isFalse(
        WorkflowStepHistoryGuard.isExempt(LoopWorkflow.class.getName()),
        'A user workflow is not exempt'
      );
    }
  }

  // ============================================================
  // COST
  // ============================================================

  @IsTest
  static void guardAddsOneSoqlAndNoDmlOnAHopBelowWarn() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id warmId = start(LoopWorkflow.class.getName());
      Id offId = start(LoopWorkflow.class.getName());
      Id onId = start(LoopWorkflow.class.getName());

      Test.startTest();
      setThresholds(0, 0);
      WorkflowEngine.runStep(warmId); // Warm the transaction caches.

      Integer q0 = Limits.getQueries();
      Integer d0 = Limits.getDmlStatements();
      WorkflowEngine.runStep(offId);
      Integer offQueries = Limits.getQueries() - q0;
      Integer offDml = Limits.getDmlStatements() - d0;

      setThresholds(100, 200);
      q0 = Limits.getQueries();
      d0 = Limits.getDmlStatements();
      WorkflowEngine.runStep(onId);
      Integer onQueries = Limits.getQueries() - q0;
      Integer onDml = Limits.getDmlStatements() - d0;
      Test.stopTest();

      Assert.areEqual(
        offQueries + 1,
        onQueries,
        'The guard adds exactly one SOQL'
      );
      Assert.areEqual(offDml, onDml, 'The guard adds no DML below warn');
    }
  }

  @IsTest
  static void guardOffCostsNoSoql() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instId = start(LoopWorkflow.class.getName());
      Workflow_Instance__c inst = [
        SELECT Id, Workflow_Name__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instId
      ];
      setThresholds(0, 0);
      Test.startTest();
      Integer q0 = Limits.getQueries();
      Boolean stopped = WorkflowStepHistoryGuard.check(ctxFor(inst));
      Integer used = Limits.getQueries() - q0;
      Test.stopTest();

      Assert.isFalse(stopped, 'Off never stops');
      Assert.areEqual(0, used, 'Off costs no SOQL');
    }
  }

  @IsTest
  static void checkWritesNoDmlOnWarnSoCalloutsStillWork() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instId = start(LoopWorkflow.class.getName());
      seedRows(instId, 3);
      Workflow_Instance__c inst = [
        SELECT Id, Workflow_Name__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instId
      ];
      setThresholds(2, 100);
      Test.startTest();
      Integer d0 = Limits.getDmlStatements();
      WorkflowStepRunner.RunStepContext ctx = ctxFor(inst);
      Boolean stopped = WorkflowStepHistoryGuard.check(ctx);
      Integer dml = Limits.getDmlStatements() - d0;
      Test.stopTest();

      Assert.isFalse(stopped, 'Warn does not stop');
      Assert.areEqual(0, dml, 'The check does no DML before execute()');
      Assert.isNotNull(ctx.stepHistoryWarning, 'The warning is kept on ctx');
      Assert.isTrue(
        ctx.stepHistoryWarning.contains('Continue-As-New'),
        'The warning names the fix: ' + ctx.stepHistoryWarning
      );
    }
  }

  // Apex Developer Guide: COUNT() without GROUP BY uses one query row. This
  // test measures it. Per-row cost would take the worst hop to 4 x ceiling.
  @IsTest
  static void countUsesOneQueryRow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instId = start(LoopWorkflow.class.getName());
      seedRows(instId, 50);
      Workflow_Instance__c inst = [
        SELECT Id, Workflow_Name__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instId
      ];
      setThresholds(0, 100);
      Test.startTest();
      Integer rows0 = Limits.getQueryRows();
      Boolean stopped = WorkflowStepHistoryGuard.check(ctxFor(inst));
      Integer rowsUsed = Limits.getQueryRows() - rows0;
      Test.stopTest();

      Assert.isFalse(stopped, 'Below the ceiling');
      Assert.areEqual(1, rowsUsed, 'COUNT() of 50 rows uses one query row');
    }
  }

  @IsTest
  static void exemptWorkflowCostsNoSoql() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WatchdogWorkflow',
        Status__c = 'Running'
      );
      setThresholds(1, 2);
      Test.startTest();
      Integer q0 = Limits.getQueries();
      Boolean stopped = WorkflowStepHistoryGuard.check(ctxFor(inst));
      Integer used = Limits.getQueries() - q0;
      Test.stopTest();

      Assert.isFalse(stopped, 'An engine workflow never stops');
      Assert.areEqual(0, used, 'An engine workflow costs no SOQL');
    }
  }

  // ============================================================
  // BELOW WARN: NO CHANGE
  // ============================================================

  @IsTest
  static void belowWarnRunsUnchanged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      loopsLeft = 1;
      Id instId = start(LoopWorkflow.class.getName());
      setThresholds(100, 200);
      Test.startTest();
      WorkflowEngine.runStep(instId); // LOOP_STEP -> LOOP_STEP
      WorkflowEngine.runStep(instId); // LOOP_STEP -> DONE
      WorkflowEngine.runStep(instId); // DONE -> end
      Test.stopTest();

      Workflow_Instance__c inst = load(instId);
      Assert.areEqual('Completed', inst.Status__c, 'The run completes');
      Assert.isNull(inst.Failure_Category__c, 'No failure category');
      Assert.areEqual(0, warnings(instId).size(), 'No warning row');
      Assert.areEqual(
        0,
        WorkflowStepHistoryGuard.warnedInstanceIds(new Set<Id>{ instId })
          .size(),
        'No dashboard flag'
      );
      Assert.isNull(
        WorkflowStepHistoryGuard.describeWarning(instId),
        'No detail warning'
      );
    }
  }

  // ============================================================
  // WARN: ONE WARNING ROW, DASHBOARD FLAG, NO CHANGE TO EXECUTION
  // ============================================================

  @IsTest
  static void crossingWarnWritesOneWarningAndKeepsRunning() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      loopsLeft = 1;
      Id instId = start(LoopWorkflow.class.getName());
      seedRows(instId, 3);
      setThresholds(3, 100);
      Test.startTest();
      WorkflowEngine.runStep(instId); // count 3: WARN. LOOP_STEP -> LOOP_STEP
      WorkflowEngine.runStep(instId); // count 4: WARN. LOOP_STEP -> DONE
      WorkflowEngine.runStep(instId); // count 5: WARN. DONE -> end
      Test.stopTest();

      Workflow_Instance__c inst = load(instId);
      Assert.areEqual(
        'Completed',
        inst.Status__c,
        'Warn does not change execution'
      );
      List<Workflow_Log__c> logs = warnings(instId);
      Assert.areEqual(1, logs.size(), 'One warning row per instance');
      Assert.areEqual('Warn', logs[0].Level__c, 'Level is Warn');
      Assert.areEqual(
        WorkflowStepHistoryGuard.fireKey(instId),
        logs[0].Fire_Key__c,
        'The row uses the instance key'
      );
      Assert.isTrue(
        logs[0].Message__c.contains('Continue-As-New'),
        'The message recommends Continue-As-New: ' + logs[0].Message__c
      );
      Assert.isTrue(
        logs[0].Message__c.contains('100'),
        'The message names the ceiling: ' + logs[0].Message__c
      );
    }
  }

  @IsTest
  static void dashboardShowsTheWarning() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      loopsLeft = 5;
      Id instId = start(LoopWorkflow.class.getName());
      Id quietId = start(LoopWorkflow.class.getName());
      seedRows(instId, 3);
      setThresholds(3, 100);
      Test.startTest();
      WorkflowEngine.runStep(instId); // WARN
      WorkflowEngine.runStep(quietId); // OK
      List<Map<String, Object>> rows = WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter(LoopWorkflow.class.getName(), '', '')
          .page(10, 0, 'history')
          .build()
      );
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        instId
      );
      Map<String, Object> quietDetails = WorkflowDashboardController.getInstanceDetails(
        quietId
      );
      Test.stopTest();

      Map<Id, Boolean> flagById = new Map<Id, Boolean>();
      for (Map<String, Object> row : rows) {
        flagById.put(
          (Id) row.get('Id'),
          (Boolean) row.get('stepHistoryWarning')
        );
      }
      Assert.areEqual(true, flagById.get(instId), 'The list row is flagged');
      Assert.areEqual(
        false,
        flagById.get(quietId),
        'A quiet row is not flagged'
      );

      Map<String, Object> warning = (Map<String, Object>) details.get(
        'stepHistoryWarning'
      );
      Assert.isNotNull(warning, 'The detail pane carries the warning');
      Assert.isTrue(
        ((String) warning.get('message')).contains('Continue-As-New'),
        'The detail message recommends Continue-As-New'
      );
      Assert.isNotNull(warning.get('createdDate'), 'The detail has a date');
      Assert.isNull(
        quietDetails.get('stepHistoryWarning'),
        'A quiet instance has no detail warning'
      );
    }
  }

  @IsTest
  static void stalledViewShowsTheWarning() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>{
        new Workflow_Instance__c(
          Workflow_Name__c = LoopWorkflow.class.getName(),
          Status__c = 'Suspended',
          Correlation_Key__c = 'History-Stalled-Warned'
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = LoopWorkflow.class.getName(),
          Status__c = 'Suspended',
          Correlation_Key__c = 'History-Stalled-Quiet'
        )
      };
      insert insts;
      insert new Workflow_Log__c(
        Log_Type__c = WorkflowStepHistoryGuard.LOG_TYPE,
        Level__c = 'Warn',
        Message__c = 'Step history reached 3 rows.',
        Fire_Key__c = WorkflowStepHistoryGuard.fireKey(insts[0].Id),
        Workflow_Instance__c = insts[0].Id
      );

      Test.startTest();
      List<Map<String, Object>> rows = WorkflowDashboardController.getStalledInstances(
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria(LoopWorkflow.class.getName(), '', -1)
          .page(10, 0, 'history')
          .build()
      );
      Test.stopTest();

      Map<Id, Object> flagById = new Map<Id, Object>();
      for (Map<String, Object> row : rows) {
        flagById.put((Id) row.get('Id'), row.get('stepHistoryWarning'));
      }
      Assert.areEqual(2, flagById.size(), 'Both rows are stalled');
      Assert.areEqual(true, flagById.get(insts[0].Id), 'Warned row is flagged');
      Assert.areEqual(false, flagById.get(insts[1].Id), 'Quiet row is not');
    }
  }

  // ============================================================
  // CEILING: FAILED STATUS, NO CHANGE TO STEP ROWS
  // ============================================================

  @IsTest
  static void ceilingFailsWithAnActionableMessage() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      loopsLeft = 100;
      Id instId = start(LoopWorkflow.class.getName());
      // The open row of the active step has an armed timeout.
      Workflow_Step_Execution__c open = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instId AND Step_Name__c = :LOOP_STEP
      ];
      open.Timeout_At__c = Datetime.now().addHours(1);
      update open;
      seedRows(instId, 5);
      setThresholds(3, 5);
      List<Workflow_Step_Execution__c> before = snapshot(instId);
      Test.startTest();
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      Workflow_Instance__c inst = load(instId);
      Assert.areEqual('Failed', inst.Status__c, 'The ceiling fails the run');
      Assert.areEqual(
        WorkflowEngine.CAT_STEP_HISTORY_LIMIT,
        inst.Failure_Category__c,
        'The category is STEP_HISTORY_LIMIT'
      );
      Assert.isTrue(
        inst.Error_Message__c.contains('Failed at step ' + LOOP_STEP),
        'The message names the active step: ' + inst.Error_Message__c
      );
      Assert.isTrue(
        inst.Error_Message__c.contains('Step history reached 5 rows'),
        'The message names the ceiling: ' + inst.Error_Message__c
      );
      Assert.isTrue(
        inst.Error_Message__c.contains('Continue-As-New'),
        'The message names the fix: ' + inst.Error_Message__c
      );
      Assert.areEqual(0, loopRuns, 'The step does not run at the ceiling');

      List<Workflow_Step_Execution__c> after = snapshot(instId);
      Assert.areEqual(before.size(), after.size(), 'No step row is added');
      for (Integer i = 0; i < before.size(); i++) {
        Assert.areEqual(before[i].Id, after[i].Id, 'Same rows');
        if (before[i].Id == open.Id) {
          Assert.areEqual('Failed', after[i].Status__c, 'Open row is closed');
          Assert.isNull(after[i].Timeout_At__c, 'Open row timeout is cleared');
          continue;
        }
        Assert.areEqual(
          before[i].Status__c,
          after[i].Status__c,
          'Closed row status is not changed'
        );
        Assert.areEqual(
          before[i].Output__c,
          after[i].Output__c,
          'Closed row output is not changed'
        );
        Assert.areEqual(
          before[i].SystemModstamp,
          after[i].SystemModstamp,
          'Closed row is not updated'
        );
      }
    }
  }

  @IsTest
  static void staleNamedDeliveryHaltsUnderTheActiveStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      loopsLeft = 100;
      Id instId = start(LoopWorkflow.class.getName());
      setThresholds(0, 100);
      WorkflowEngine.runStep(instId); // Current step is LOOP_STEP.
      seedRows(instId, 5);
      setThresholds(0, 5);
      Test.startTest();
      WorkflowEngine.runStep(instId, DONE); // Stale: DONE is not active.
      Test.stopTest();

      Workflow_Instance__c inst = load(instId);
      Assert.areEqual('Failed', inst.Status__c, 'The ceiling fails the run');
      Assert.isTrue(
        inst.Error_Message__c.contains('Failed at step ' + LOOP_STEP + ':'),
        'The message names the active step: ' + inst.Error_Message__c
      );
    }
  }

  @IsTest
  static void ceilingSkipsErrorRouting() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instId = start(RoutedLoopWorkflow.class.getName());
      seedRows(instId, 4);
      setThresholds(0, 4);
      Test.startTest();
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      Workflow_Instance__c inst = load(instId);
      Assert.areEqual('Failed', inst.Status__c, 'The run fails');
      Assert.areEqual(
        WorkflowEngine.CAT_STEP_HISTORY_LIMIT,
        inst.Failure_Category__c,
        'The category is STEP_HISTORY_LIMIT'
      );
      Assert.isFalse(errorStepAsked, 'Error routing is skipped');
      Assert.areEqual(
        0,
        [
          SELECT COUNT()
          FROM Workflow_Step_Execution__c
          WHERE Workflow_Instance__c = :instId AND Step_Name__c = :RECOVER
        ],
        'No error step row'
      );
    }
  }

  @IsTest
  static void ceilingStartsCompensationAndKeepsTheStack() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      loopsLeft = 100;
      Id instId = start(SagaLoopWorkflow.class.getName());
      setThresholds(0, 100);
      WorkflowEngine.runStep(instId); // CHARGE -> LOOP_STEP. Stack: [CHARGE]
      String stackBefore = load(instId).Compensation_Stack__c;
      seedRows(instId, 6);
      setThresholds(0, 6);

      Test.startTest();
      WorkflowEngine.runStep(instId); // count 6: HALT
      Workflow_Instance__c halted = load(instId);
      new WorkflowTestHarness(instId).drive();
      Test.stopTest();

      Assert.areEqual(
        'Compensating',
        halted.Status__c,
        'The ceiling starts compensation'
      );
      Assert.areEqual(
        stackBefore,
        halted.Compensation_Stack__c,
        'The guard keeps the stack order'
      );
      Assert.isTrue(
        halted.Error_Message__c.contains('Continue-As-New'),
        'The message names the fix: ' + halted.Error_Message__c
      );
      Assert.areEqual(
        'Compensated',
        load(instId).Status__c,
        'Compensation runs past the ceiling'
      );
    }
  }

  @IsTest
  static void concurrentTerminalStatusIsNotFailedAgain() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instId = start(LoopWorkflow.class.getName());
      seedRows(instId, 3);
      Workflow_Instance__c inMemory = [
        SELECT Id, Workflow_Name__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instId
      ];
      inMemory.Status__c = 'Running';
      // A sibling thread cancels the instance after this delivery loaded it.
      update new Workflow_Instance__c(Id = instId, Status__c = 'Cancelled');
      setThresholds(0, 3);
      Test.startTest();
      Boolean stopped = WorkflowStepHistoryGuard.check(ctxFor(inMemory));
      Test.stopTest();

      Workflow_Instance__c inst = load(instId);
      Assert.isTrue(stopped, 'The delivery stops');
      Assert.areEqual('Cancelled', inst.Status__c, 'The status is kept');
      Assert.isNull(inst.Failure_Category__c, 'No failure category');
    }
  }

  // ============================================================
  // CONTINUE-AS-NEW: NEW GENERATION, NEW COUNT
  // ============================================================

  @IsTest
  static void continueAsNewStartsANewCount() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      canHop = 0;
      generationsLeft = 1;
      // Each generation has max 2 rows at the check. Together they have 4,
      // more than the ceiling of 3.
      setThresholds(0, 3);
      Id firstId = start(CanWorkflow.class.getName());
      WorkflowEngine.runStep(firstId); // count 1. Loop.
      WorkflowEngine.runStep(firstId); // count 2. Continue-As-New.

      Workflow_Instance__c successor = [
        SELECT Id, Status__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :firstId
      ];
      Test.startTest();
      WorkflowEngine.runStep(successor.Id); // count 1. Loop.
      WorkflowEngine.runStep(successor.Id); // count 2. End.
      Test.stopTest();

      Assert.areEqual(
        'ContinuedAsNew',
        load(firstId).Status__c,
        'Generation 1 continues as new'
      );
      Workflow_Instance__c second = load(successor.Id);
      Assert.areEqual('Completed', second.Status__c, 'Generation 2 completes');
      Assert.isNull(second.Failure_Category__c, 'No failure category');
      Assert.isTrue(
        rowCount(firstId) + rowCount(successor.Id) >= 3,
        'Both generations together pass the ceiling'
      );
    }
  }
}
