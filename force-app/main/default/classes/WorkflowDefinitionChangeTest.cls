/**
 * Engine tests for mid-flight definition change detection (issue #89).
 * Written first (RED). They fail on code that has no fingerprint gate.
 *
 * Scenarios:
 *  1. AC test: getSteps() changes between two hops. The instance parks in
 *     DefinitionChanged. The next step does not run.
 *  2. Unchanged definition runs to completion.
 *  3. VersionedWorkflow mismatch is advisory. The step runs.
 *  4. Null stored fingerprint is advisory. The step runs.
 *  5. Gate on a matched instance costs 0 SOQL and 0 DML.
 *  6. A stale delivery to a parked or just-released instance does nothing.
 *  7. Park keeps prior step rows and the compensation stack.
 *  8. Release re-stamps, resumes, and completes.
 *  9. Release refuses a current step that the live definition removed.
 * 10. Release refuses an instance that is not parked.
 * 11. Cancel works on a parked instance.
 * 12. Correlation key stays reserved while parked.
 * 13. Signal to a parked instance is held, not dropped.
 * 14. Start stamps the fingerprint and shape.
 * 15. Timeout sweep skips a parked instance.
 * 16. Engine-internal workflows never park.
 * 17. Cancel cascades to a parked child; pause gate order; unreadable and
 *     parallel release; continue-as-new stamping; in-flight branch keeps park.
 */
@IsTest
public class WorkflowDefinitionChangeTest {
  private static final String WF = 'WorkflowDefinitionChangeTest.MutableWorkflow';
  private static final String VWF = 'WorkflowDefinitionChangeTest.MutableVersionedWorkflow';
  private static final String STEP_A = 'WorkflowDefinitionChangeTest.StepA';
  private static final String STEP_B = 'WorkflowDefinitionChangeTest.StepB';
  private static final String STEP_X = 'WorkflowDefinitionChangeTest.StepX';
  private static final String STEP_C = 'WorkflowDefinitionChangeTest.StepC';

  // 0 = [A, B]; 1 = [A, X, B] (insert); 2 = [A, C] (B removed);
  // 3 = [A, B] plus names too long for the marker Output__c.
  public static Integer shape = 0;
  public static Integer stepBRuns = 0;
  public static Integer stepXRuns = 0;

  // ============================================================
  // MOCK WORKFLOWS
  // ============================================================

  /**
   * @description Plain definition whose step list the test can change.
   */
  public class MutableWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the step list for the current test shape.
     * @return The step names.
     */
    public List<String> getSteps() {
      return stepsForShape();
    }
    /**
     * @description Returns the first step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return STEP_A;
    }
    /**
     * @description Routes by the current test shape.
     * @param current The completed step.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return nextFor(current);
    }
  }

  /**
   * @description Versioned definition whose step list the test can change.
   */
  public class MutableVersionedWorkflow implements VersionedWorkflow {
    /**
     * @description Returns the step list for the current test shape.
     * @return The step names.
     */
    public List<String> getSteps() {
      return stepsForShape();
    }
    /**
     * @description Returns the first step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return STEP_A;
    }
    /**
     * @description Returns the latest version.
     * @return Always 1.
     */
    public Integer getLatestVersion() {
      return 1;
    }
    /**
     * @description Routes by the current test shape.
     * @param current The completed step.
     * @param result The step result.
     * @return The next step, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return nextFor(current);
    }
    /**
     * @description Routes by the current test shape for any version.
     * @param current The completed step.
     * @param result The step result.
     * @param version The instance version.
     * @return The next step, or null.
     */
    public String getNextStep(
      String current,
      StepResult result,
      Integer version
    ) {
      return nextFor(current);
    }
  }

  private static List<String> stepsForShape() {
    if (shape == 1) {
      return new List<String>{ STEP_A, STEP_X, STEP_B };
    }
    if (shape == 2) {
      return new List<String>{ STEP_A, STEP_C };
    }
    if (shape == 3) {
      List<String> huge = new List<String>{ STEP_A, STEP_B };
      for (Integer i = 0; i < 600; i++) {
        huge.add('Unused.Step' + 'x'.repeat(240) + i);
      }
      return huge;
    }
    return new List<String>{ STEP_A, STEP_B };
  }

  private static String nextFor(String current) {
    if (current == STEP_A) {
      return shape == 1 ? STEP_X : (shape == 2 ? STEP_C : STEP_B);
    }
    if (current == STEP_X) {
      return STEP_B;
    }
    return null;
  }

  /**
   * @description First step. It pushes itself on the compensation stack.
   */
  public class StepA implements CompensatableStep {
    /**
     * @description Completes and lets the definition route.
     * @param ctx The step context.
     * @return A COMPLETE result.
     */
    public StepResult execute(StepContext ctx) {
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
   * @description Terminal step. It counts its runs.
   */
  public class StepB implements WorkflowStep {
    /**
     * @description Counts the run and completes the workflow.
     * @param ctx The step context.
     * @return A terminal COMPLETE result.
     */
    public StepResult execute(StepContext ctx) {
      stepBRuns++;
      return StepResult.complete(null, 'OutB');
    }
  }

  /**
   * @description Inserted step. It counts its runs.
   */
  public class StepX implements WorkflowStep {
    /**
     * @description Counts the run and completes.
     * @param ctx The step context.
     * @return A COMPLETE result.
     */
    public StepResult execute(StepContext ctx) {
      stepXRuns++;
      return StepResult.complete(null, 'OutX');
    }
  }

  /**
   * @description Replacement step for shape 2.
   */
  public class StepC implements WorkflowStep {
    /**
     * @description Completes the workflow.
     * @param ctx The step context.
     * @return A terminal COMPLETE result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'OutC');
    }
  }

  /**
   * @description One-step workflow that continues as new once.
   */
  public class LoopWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the step list.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowDefinitionChangeTest.LoopStep' };
    }
    /**
     * @description Returns the first step.
     * @return The initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowDefinitionChangeTest.LoopStep';
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
   * @description Step that asks for a continue-as-new successor.
   */
  public class LoopStep implements WorkflowStep {
    /**
     * @description Continues as new.
     * @param ctx The step context.
     * @return A CONTINUE_AS_NEW result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.continueAsNew(null);
    }
  }

  // ============================================================
  // HELPERS
  // ============================================================

  private static Id startAndRunFirstHop(String workflowName, String key) {
    WorkflowEngine.disableQueueableInTest = true;
    shape = 0;
    Id instId = WorkflowEngine.start(workflowName, key, null);
    WorkflowEngine.runStep(instId);
    return instId;
  }

  private static Workflow_Instance__c load(Id instId) {
    return [
      SELECT
        Status__c,
        Current_Step__c,
        Compensation_Stack__c,
        Definition_Fingerprint__c,
        Definition_Shape__c,
        Error_Message__c,
        Active_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :instId
    ];
  }

  private static List<Workflow_Step_Execution__c> markers(Id instId) {
    return [
      SELECT Status__c, Error_Details__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instId
        AND Step_Name__c = :WorkflowDefinitionChangeGate.MARKER_STEP_NAME
    ];
  }

  private static Id parkWithInsertedStep(String key) {
    Id instId = startAndRunFirstHop(WF, key);
    shape = 1; // redeploy between hops: insert StepX
    WorkflowEngine.runStep(instId);
    return instId;
  }

  // ============================================================
  // 1. AC TEST: CHANGE BETWEEN HOPS PARKS WITH ZERO EXECUTION
  // ============================================================

  @IsTest
  static void testStepListChangeBetweenHopsParksInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(
        WF,
        'DefChg-AC-' + Datetime.now().getTime()
      );
      Workflow_Instance__c afterHop1 = load(instId);
      System.assertEquals(
        STEP_B,
        afterHop1.Current_Step__c,
        'Hop 1 must route to StepB'
      );
      shape = 1;
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      Workflow_Instance__c parked = load(instId);
      System.assertEquals(
        'DefinitionChanged',
        parked.Status__c,
        'A changed step list must park the instance'
      );
      System.assertEquals(0, stepBRuns, 'StepB must not run');
      System.assertEquals(0, stepXRuns, 'StepX must not run');
      Integer nonPendingNewShapeRows = [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instId
          AND Step_Name__c IN (:STEP_B, :STEP_X)
          AND Status__c != 'Pending'
      ];
      System.assertEquals(
        0,
        nonPendingNewShapeRows,
        'No step may execute against the changed shape'
      );
      List<Workflow_Step_Execution__c> halt = markers(instId);
      System.assertEquals(1, halt.size(), 'Park must append one halt marker');
      System.assertEquals(
        'DefinitionChanged',
        halt[0].Status__c,
        'Marker status must be DefinitionChanged'
      );
      System.assert(
        halt[0].Output__c.contains(STEP_X),
        'Marker must record the live step list'
      );
      System.assert(
        String.isNotBlank(parked.Error_Message__c),
        'Park must explain the halt'
      );
    }
  }

  // Codex review: a live list larger than Output__c must not roll back the park.
  @IsTest
  static void testParkWithOversizedLiveListStillParks() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(
        WF,
        'DefChg-Huge-' + Datetime.now().getTime()
      );
      shape = 3;
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      System.assertEquals(
        'DefinitionChanged',
        load(instId).Status__c,
        'An oversized live list must still park'
      );
      List<Workflow_Step_Execution__c> halt = markers(instId);
      System.assertEquals(1, halt.size(), 'One marker');
      System.assert(
        halt[0].Output__c.contains('liveStepsOmitted'),
        'The marker must flag the omitted list'
      );
      System.assertEquals(0, stepBRuns, 'StepB must not run');
    }
  }

  // ============================================================
  // 2. UNCHANGED DEFINITION RUNS
  // ============================================================

  @IsTest
  static void testUnchangedDefinitionCompletes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(
        WF,
        'DefChg-Same-' + Datetime.now().getTime()
      );
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      System.assertEquals('Completed', load(instId).Status__c, 'Must complete');
      System.assertEquals(1, stepBRuns, 'StepB must run once');
      System.assertEquals(0, markers(instId).size(), 'No marker on a match');
    }
  }

  // ============================================================
  // 3. VERSIONED MISMATCH IS ADVISORY
  // ============================================================

  @IsTest
  static void testVersionedWorkflowMismatchIsAdvisory() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(
        VWF,
        'DefChg-Ver-' + Datetime.now().getTime()
      );
      shape = 1;
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      System.assertNotEquals(
        'DefinitionChanged',
        load(instId).Status__c,
        'A VersionedWorkflow must never park'
      );
      System.assertEquals(
        1,
        stepBRuns,
        'StepB must run for a versioned workflow'
      );
      System.assertEquals(0, markers(instId).size(), 'No marker when advisory');
    }
  }

  // ============================================================
  // 4. NULL FINGERPRINT IS ADVISORY
  // ============================================================

  @IsTest
  static void testNullFingerprintIsAdvisory() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(
        WF,
        'DefChg-Null-' + Datetime.now().getTime()
      );
      // Simulate an instance that started before the field existed.
      update new Workflow_Instance__c(
        Id = instId,
        Definition_Fingerprint__c = null
      );
      shape = 1;
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      System.assertEquals(
        'Completed',
        load(instId).Status__c,
        'A null fingerprint must never block'
      );
      System.assertEquals(1, stepBRuns, 'StepB must run');
    }
  }

  // ============================================================
  // 5. HOT-PATH COST
  // ============================================================

  @IsTest
  static void testGateOnMatchCostsNoSoqlOrDml() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      shape = 0;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'Running',
        Current_Step__c = STEP_B,
        Definition_Fingerprint__c = WorkflowDefinitionFingerprint.compute(
          stepsForShape()
        )
      );
      Test.startTest();
      Integer q0 = Limits.getQueries();
      Integer d0 = Limits.getDmlStatements();
      Boolean stopped = WorkflowDefinitionChangeGate.parkIfChanged(inst);
      Integer q1 = Limits.getQueries();
      Integer d1 = Limits.getDmlStatements();
      Test.stopTest();

      System.assertEquals(false, stopped, 'A match must not stop the delivery');
      System.assertEquals(q0, q1, 'Gate must add no SOQL on a match');
      System.assertEquals(d0, d1, 'Gate must add no DML on a match');
    }
  }

  // Review finding: a parked watchdog stops every sweep, so the gate must never
  // park an engine-internal workflow, even when its step list changed.
  @IsTest
  static void testGateNeverParksEngineWorkflows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String staleFingerprint = WorkflowDefinitionFingerprint.compute(
        new List<String>{ 'OldWatchdogStep' }
      );
      Test.startTest();
      Integer d0 = Limits.getDmlStatements();
      for (
        String name : new List<String>{
          'WatchdogWorkflow',
          'CleanupWorkflow',
          'BulkRedriveWorkflow',
          'BulkCancelWorkflow',
          'ArchiveWorkflow'
        }
      ) {
        Workflow_Instance__c inst = new Workflow_Instance__c(
          Workflow_Name__c = name,
          Status__c = 'Running',
          Definition_Fingerprint__c = staleFingerprint
        );
        System.assertEquals(
          false,
          WorkflowDefinitionChangeGate.parkIfChanged(inst),
          name + ' must never park'
        );
      }
      Integer d1 = Limits.getDmlStatements();
      Test.stopTest();
      System.assertEquals(d0, d1, 'No park DML for engine workflows');
    }
  }

  // ============================================================
  // 6. STALE DELIVERY TO A PARKED INSTANCE
  // ============================================================

  @IsTest
  static void testStaleDeliveryToParkedInstanceIsNoOp() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = parkWithInsertedStep(
        'DefChg-Stale-' + Datetime.now().getTime()
      );
      new WorkflowOrchestrator(instId, STEP_B).execute(null);
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      System.assertEquals(
        'DefinitionChanged',
        load(instId).Status__c,
        'A stale delivery must not move a parked instance'
      );
      System.assertEquals(0, stepBRuns, 'StepB must not run');
      System.assertEquals(1, markers(instId).size(), 'Only one marker');
    }
  }

  // Regression (Codex review): a stale delivery that loaded the old
  // fingerprint before a release must not park the released instance again.
  @IsTest
  static void testStaleDeliveryAfterReleaseDoesNotRepark() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = parkWithInsertedStep(
        'DefChg-StaleRel-' + Datetime.now().getTime()
      );
      Workflow_Instance__c stale = [
        SELECT Id, Status__c, Workflow_Name__c, Definition_Fingerprint__c
        FROM Workflow_Instance__c
        WHERE Id = :instId
      ];
      stale.Status__c = 'Running'; // As loaded before the park.
      WorkflowDefinitionChangeService.release(instId);
      Boolean stopped = WorkflowDefinitionChangeGate.parkIfChanged(stale);
      Test.stopTest();

      System.assertEquals(true, stopped, 'The stale delivery must stop');
      System.assertEquals(
        'Running',
        load(instId).Status__c,
        'The release must win over the stale delivery'
      );
      System.assertEquals(1, markers(instId).size(), 'No second marker');
    }
  }

  // Review finding: a parallel branch that was in flight when the instance
  // parked must not overwrite the park with Suspended. Otherwise the open
  // branch has no delivery and no Release action, and the instance strands.
  @IsTest
  static void testInFlightBranchCompletionKeepsPark() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      for (
        String parkedStatus : new List<String>{ 'DefinitionChanged', 'Paused' }
      ) {
        Workflow_Instance__c inst = new Workflow_Instance__c(
          Workflow_Name__c = WF,
          Status__c = parkedStatus,
          Current_Step__c = STEP_A + ',' + STEP_B,
          Correlation_Key__c = 'DefChg-Par-' +
            parkedStatus +
            Datetime.now().getTime()
        );
        insert inst;
        insert new List<Workflow_Step_Execution__c>{
          new Workflow_Step_Execution__c(
            Workflow_Instance__c = inst.Id,
            Step_Name__c = STEP_A,
            Status__c = 'Completed',
            Retry_Count__c = 0
          ),
          new Workflow_Step_Execution__c(
            Workflow_Instance__c = inst.Id,
            Step_Name__c = STEP_B,
            Status__c = 'Pending',
            Retry_Count__c = 0,
            // A Pending row with CPU time is waiting work, so the verdict is
            // SUSPEND. Without CPU time it counts as RUNNING and no write runs.
            CPU_Time_Ms__c = 1
          )
        };
        WorkflowEngine.StepOutcomeContext outcome = new WorkflowEngine.StepOutcomeContext();
        outcome.instance = inst;
        outcome.isParallel = true;

        WorkflowParallelJoin.completeParallelBranch(outcome);

        System.assertEquals(
          parkedStatus,
          load(inst.Id).Status__c,
          'An in-flight branch must not undo a ' + parkedStatus + ' park'
        );
      }
    }
  }

  // Codex review: the test harness must treat a parked parallel instance as
  // stable. Otherwise drive() spends its hop budget on gate no-ops and throws.
  @IsTest
  static void testHarnessTreatsParkedParallelInstanceAsStable() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'DefinitionChanged',
        Current_Step__c = STEP_X + ',' + STEP_B,
        Correlation_Key__c = 'DefChg-Harness-' + Datetime.now().getTime()
      );
      insert inst;
      Test.startTest();
      Boolean advanceable = WorkflowHarnessAdvancer.isAdvanceable(
        new WorkflowHarnessContext(inst.Id),
        inst
      );
      Test.stopTest();
      System.assertEquals(
        false,
        advanceable,
        'A parked instance with unrun branches must not be advanceable'
      );
    }
  }

  // ============================================================
  // 7. APPEND-ONLY AUDIT AND LIFO STACK UNTOUCHED
  // ============================================================

  @IsTest
  static void testParkKeepsHistoryAndCompensationStack() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(
        WF,
        'DefChg-Audit-' + Datetime.now().getTime()
      );
      Workflow_Instance__c before = load(instId);
      Map<Id, Workflow_Step_Execution__c> rowsBefore = new Map<Id, Workflow_Step_Execution__c>(
        [
          SELECT Id, Status__c, Step_Name__c, Output__c
          FROM Workflow_Step_Execution__c
          WHERE Workflow_Instance__c = :instId
        ]
      );
      shape = 1;
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      Workflow_Instance__c after = load(instId);
      System.assertEquals(
        before.Compensation_Stack__c,
        after.Compensation_Stack__c,
        'Park must not change the compensation stack'
      );
      System.assert(
        after.Compensation_Stack__c.contains(STEP_A),
        'StepA must stay on the stack'
      );
      for (Workflow_Step_Execution__c row : [
        SELECT Id, Status__c, Step_Name__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE Id IN :rowsBefore.keySet()
      ]) {
        Workflow_Step_Execution__c old = rowsBefore.get(row.Id);
        System.assertEquals(
          old.Status__c,
          row.Status__c,
          'Prior row status unchanged'
        );
        System.assertEquals(
          old.Output__c,
          row.Output__c,
          'Prior row output unchanged'
        );
      }
    }
  }

  // ============================================================
  // 8. RELEASE RESUMES
  // ============================================================

  @IsTest
  static void testReleaseRestampsAndResumes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = parkWithInsertedStep(
        'DefChg-Rel-' + Datetime.now().getTime()
      );
      WorkflowDefinitionChangeService.release(instId);
      Workflow_Instance__c released = load(instId);
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      System.assertEquals(
        'Running',
        released.Status__c,
        'Release sets Running'
      );
      System.assertEquals(
        WorkflowDefinitionFingerprint.compute(stepsForShape()),
        released.Definition_Fingerprint__c,
        'Release must re-stamp the live fingerprint'
      );
      System.assertEquals(
        stepsForShape(),
        WorkflowDefinitionFingerprint.parseShape(released.Definition_Shape__c),
        'Release must re-stamp the live shape'
      );
      System.assertEquals(
        null,
        released.Error_Message__c,
        'Release clears the reason'
      );
      System.assertEquals(
        'Completed',
        load(instId).Status__c,
        'Released run completes'
      );
      System.assertEquals(1, stepBRuns, 'StepB runs once after release');
      System.assertEquals(
        1,
        markers(instId).size(),
        'Marker stays in the audit trail'
      );
    }
  }

  // ============================================================
  // 9. RELEASE GUARDS A REMOVED CURRENT STEP
  // ============================================================

  @IsTest
  static void testReleaseRefusesRemovedCurrentStep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(
        WF,
        'DefChg-Gone-' + Datetime.now().getTime()
      );
      shape = 2; // StepB removed
      WorkflowEngine.runStep(instId);
      String error;
      try {
        WorkflowDefinitionChangeService.release(instId);
      } catch (WorkflowEngine.WorkflowException ex) {
        error = ex.getMessage();
      }
      Test.stopTest();

      System.assertNotEquals(null, error, 'Release must refuse a removed step');
      System.assert(error.contains(STEP_B), 'Error must name the missing step');
      System.assertEquals(
        'DefinitionChanged',
        load(instId).Status__c,
        'A refused release keeps the park'
      );
    }
  }

  // ============================================================
  // 10. RELEASE REFUSES A NON-PARKED INSTANCE
  // ============================================================

  @IsTest
  static void testReleaseRefusesInstanceThatIsNotParked() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(
        WF,
        'DefChg-NotParked-' + Datetime.now().getTime()
      );
      Boolean threw = false;
      try {
        WorkflowDefinitionChangeService.release(instId);
      } catch (WorkflowEngine.WorkflowException ex) {
        threw = true;
      }
      Test.stopTest();
      System.assert(
        threw,
        'Release must refuse an instance that is not parked'
      );
    }
  }

  // ============================================================
  // 11. CANCEL A PARKED INSTANCE
  // ============================================================

  @IsTest
  static void testCancelWorksOnParkedInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = parkWithInsertedStep(
        'DefChg-Cancel-' + Datetime.now().getTime()
      );
      WorkflowEngine.cancel(instId);
      Test.stopTest();
      System.assertEquals(
        'Cancelled',
        load(instId).Status__c,
        'A parked instance must be cancellable'
      );
    }
  }

  @IsTest
  static void testCancelCascadesToParkedChild() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      String stamp = String.valueOf(Datetime.now().getTime());
      Workflow_Instance__c parent = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'Suspended',
        Current_Step__c = STEP_A,
        Correlation_Key__c = 'DefChg-Parent-' + stamp
      );
      insert parent;
      Workflow_Instance__c child = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'DefinitionChanged',
        Current_Step__c = STEP_B,
        Parent_Instance__c = parent.Id,
        Correlation_Key__c = 'DefChg-Child-' + stamp
      );
      insert child;
      Test.startTest();
      WorkflowEngine.cancel(parent.Id);
      Test.stopTest();
      System.assertEquals(
        'Cancelled',
        load(child.Id).Status__c,
        'Cancel must cascade to a parked child'
      );
    }
  }

  // Review finding: the gate must run before the pause gate. Otherwise a
  // stale delivery on a paused definition turns the park into Paused.
  @IsTest
  static void testParkedInstanceStaysParkedWhenDefinitionPaused() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = parkWithInsertedStep(
        'DefChg-PauseOrder-' + Datetime.now().getTime()
      );
      WorkflowPauseGate.pauseDefinition(WF, 'order test');
      WorkflowEngine.runStep(instId);
      Test.stopTest();
      System.assertEquals(
        'DefinitionChanged',
        load(instId).Status__c,
        'A paused definition must not overwrite the park'
      );
    }
  }

  @IsTest
  static void testReleaseRefusesUnreadableDefinition() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'No_Such_Workflow_89',
        Status__c = 'DefinitionChanged',
        Current_Step__c = STEP_B,
        Correlation_Key__c = 'DefChg-NoDef-' + Datetime.now().getTime()
      );
      insert inst;
      String error;
      Test.startTest();
      try {
        WorkflowDefinitionChangeService.release(inst.Id);
      } catch (WorkflowEngine.WorkflowException ex) {
        error = ex.getMessage();
      }
      Test.stopTest();
      System.assert(
        error != null && error.contains('Cannot read the live definition'),
        'Release must refuse an unreadable definition: ' + error
      );
      Map<String, Object> change = WorkflowDefinitionChangeService.describe(
        inst
      );
      System.assertEquals(
        false,
        change.get('liveAvailable'),
        'Live unreadable'
      );
      System.assertEquals(
        false,
        change.get('currentStepInLive'),
        'No live list means no current-step match'
      );
    }
  }

  // Codex review: a finished parallel branch that the live definition removed
  // must not block release. An open branch that was removed must block it.
  @IsTest
  static void testReleaseChecksOnlyOpenParallelBranches() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      shape = 0; // Live list [A, B]: StepX is removed.
      List<Id> ids = new List<Id>();
      for (String xStatus : new List<String>{ 'Completed', 'Pending' }) {
        Workflow_Instance__c inst = new Workflow_Instance__c(
          Workflow_Name__c = WF,
          Status__c = 'DefinitionChanged',
          Current_Step__c = STEP_X + ',' + STEP_B,
          Definition_Fingerprint__c = 'v1:old',
          Correlation_Key__c = 'DefChg-Open-' +
            xStatus +
            Datetime.now().getTime()
        );
        insert inst;
        insert new List<Workflow_Step_Execution__c>{
          new Workflow_Step_Execution__c(
            Workflow_Instance__c = inst.Id,
            Step_Name__c = STEP_X,
            Status__c = xStatus,
            Retry_Count__c = 0
          ),
          new Workflow_Step_Execution__c(
            Workflow_Instance__c = inst.Id,
            Step_Name__c = STEP_B,
            Status__c = 'Pending',
            Retry_Count__c = 0
          )
        };
        ids.add(inst.Id);
      }
      // X finished: only B is open, and B is live.
      WorkflowDefinitionChangeService.release(ids[0]);
      System.assertEquals(
        'Running',
        load(ids[0]).Status__c,
        'A removed but finished branch must not block release'
      );
      // X still open and removed: release must refuse.
      String error;
      try {
        WorkflowDefinitionChangeService.release(ids[1]);
      } catch (WorkflowEngine.WorkflowException ex) {
        error = ex.getMessage();
      }
      System.assert(
        error != null && error.contains(STEP_X),
        'An open removed branch must block release: ' + error
      );
    }
  }

  @IsTest
  static void testReleaseParallelInstanceResumes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      shape = 1;
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'DefinitionChanged',
        Current_Step__c = STEP_X + ',' + STEP_B,
        Definition_Fingerprint__c = 'v1:old',
        Correlation_Key__c = 'DefChg-ParRel-' + Datetime.now().getTime()
      );
      insert inst;
      // No Test.stopTest(): with disableQueueableInTest no branch runs, so this
      // test checks the release itself.
      WorkflowDefinitionChangeService.release(inst.Id);
      Workflow_Instance__c released = load(inst.Id);
      System.assertEquals(
        'Running',
        released.Status__c,
        'Release sets Running'
      );
      System.assertEquals(
        WorkflowDefinitionFingerprint.compute(stepsForShape()),
        released.Definition_Fingerprint__c,
        'Release stamps the live fingerprint on a parallel instance'
      );
    }
  }

  // ============================================================
  // 12. CORRELATION KEY RESERVED
  // ============================================================

  @IsTest
  static void testCorrelationKeyStaysReservedWhileParked() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String key = 'DefChg-Key-' + Datetime.now().getTime();
      Test.startTest();
      Id instId = parkWithInsertedStep(key);
      WorkflowEngine.StartResult dup = WorkflowEngine.startOrGet(WF, key, null);
      Test.stopTest();

      System.assertEquals(
        key,
        load(instId).Active_Correlation_Key__c,
        'Key must stay reserved while parked'
      );
      System.assertEquals(
        instId,
        dup.instanceId,
        'Dedup must return the parked run'
      );
      System.assertEquals(false, dup.isNew, 'No duplicate run');
    }
  }

  // ============================================================
  // 13. SIGNAL HELD
  // ============================================================

  @IsTest
  static void testSignalToParkedInstanceIsHeld() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String key = 'DefChg-Sig-' + Datetime.now().getTime();
      Test.startTest();
      Id instId = parkWithInsertedStep(key);
      WorkflowEngine.signal(key, 'Ping', '"x"');
      Test.stopTest();

      List<Workflow_Signal__c> signals = [
        SELECT Status__c
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :instId
      ];
      System.assertEquals(1, signals.size(), 'Signal must be stored');
      System.assertEquals(
        'Received',
        signals[0].Status__c,
        'Signal must be held'
      );
      System.assertEquals(
        'DefinitionChanged',
        load(instId).Status__c,
        'A signal must not wake a parked instance'
      );
    }
  }

  // ============================================================
  // 14. START STAMPS
  // ============================================================

  @IsTest
  static void testStartStampsFingerprintAndShape() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      shape = 0;
      Test.startTest();
      Id instId = WorkflowEngine.start(
        WF,
        'DefChg-Stamp-' + Datetime.now().getTime(),
        null
      );
      Test.stopTest();

      Workflow_Instance__c inst = load(instId);
      System.assertEquals(
        WorkflowDefinitionFingerprint.compute(stepsForShape()),
        inst.Definition_Fingerprint__c,
        'Start must stamp the fingerprint'
      );
      System.assertEquals(
        stepsForShape(),
        WorkflowDefinitionFingerprint.parseShape(inst.Definition_Shape__c),
        'Start must stamp the shape'
      );
    }
  }

  @IsTest
  static void testChildPlannerStampsFingerprint() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      shape = 0;
      StepResult.ChildRequest req = new StepResult.ChildRequest(
        WF,
        'child-89',
        null
      );
      Workflow_Instance__c child = WorkflowChildBulkPlanner.buildChildInstance(
        req,
        null,
        null
      );
      System.assertEquals(
        WorkflowDefinitionFingerprint.compute(stepsForShape()),
        child.Definition_Fingerprint__c,
        'A bulk child must be stamped'
      );
    }
  }

  @IsTest
  static void testContinueAsNewSuccessorIsStamped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Test.startTest();
      Id instId = WorkflowEngine.start(
        'WorkflowDefinitionChangeTest.LoopWorkflow',
        'DefChg-Can-' + Datetime.now().getTime(),
        null
      );
      WorkflowEngine.runStep(instId);
      Test.stopTest();
      List<Workflow_Instance__c> successors = [
        SELECT Definition_Fingerprint__c, Definition_Shape__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :instId
      ];
      System.assertEquals(1, successors.size(), 'One successor');
      System.assertEquals(
        WorkflowDefinitionFingerprint.compute(
          new List<String>{ 'WorkflowDefinitionChangeTest.LoopStep' }
        ),
        successors[0].Definition_Fingerprint__c,
        'The successor takes the live fingerprint'
      );
    }
  }

  // ============================================================
  // 15. TIMEOUT SWEEP SKIPS A PARKED INSTANCE
  // ============================================================

  @IsTest
  static void testTimeoutSweepSkipsParkedInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id parkedId = parkWithInsertedStep(
        'DefChg-Timeout-' + Datetime.now().getTime()
      );
      Workflow_Step_Execution__c pendingB = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :parkedId AND Step_Name__c = :STEP_B
        LIMIT 1
      ];
      pendingB.Timeout_At__c = Datetime.now().addMinutes(-5);
      update pendingB;
      // A later, runnable instance with an overdue step.
      Workflow_Instance__c live = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'Running',
        Current_Step__c = STEP_B,
        Correlation_Key__c = 'DefChg-TimeoutLive-' + Datetime.now().getTime()
      );
      insert live;
      Workflow_Step_Execution__c liveStep = new Workflow_Step_Execution__c(
        Workflow_Instance__c = live.Id,
        Step_Name__c = STEP_B,
        Status__c = 'Running',
        Retry_Count__c = 0,
        Timeout_At__c = Datetime.now().addMinutes(-5)
      );
      insert liveStep;
      // With a batch of one, a selected parked row would starve the live row.
      WorkflowTimeoutSweep.watchdogTimeoutBatchSize = 1;
      WorkflowTimeoutSweep.processTimedOutSteps(
        Datetime.now(),
        new List<Workflow_Instance__c>()
      );
      Test.stopTest();

      System.assertEquals(
        'DefinitionChanged',
        load(parkedId).Status__c,
        'The watchdog must not fail a parked instance'
      );
      System.assertEquals(
        'Failed',
        [
          SELECT Status__c
          FROM Workflow_Step_Execution__c
          WHERE Id = :liveStep.Id
        ]
        .Status__c,
        'The sweep must skip parked rows and time out the live step'
      );
    }
  }
}
