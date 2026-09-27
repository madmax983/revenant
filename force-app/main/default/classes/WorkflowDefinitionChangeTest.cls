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
 *  6. A stale delivery to a parked instance does nothing.
 *  7. Park keeps prior step rows and the compensation stack.
 *  8. Release re-stamps, resumes, and completes.
 *  9. Release refuses a current step that the live definition removed.
 * 10. Release refuses an instance that is not parked.
 * 11. Cancel works on a parked instance.
 * 12. Correlation key stays reserved while parked.
 * 13. Signal to a parked instance is held, not dropped.
 * 14. Start stamps the fingerprint and shape.
 * 15. Timeout sweep skips a parked instance.
 */
@IsTest
public class WorkflowDefinitionChangeTest {
  private static final String WF = 'WorkflowDefinitionChangeTest.MutableWorkflow';
  private static final String VWF = 'WorkflowDefinitionChangeTest.MutableVersionedWorkflow';
  private static final String STEP_A = 'WorkflowDefinitionChangeTest.StepA';
  private static final String STEP_B = 'WorkflowDefinitionChangeTest.StepB';
  private static final String STEP_X = 'WorkflowDefinitionChangeTest.StepX';
  private static final String STEP_C = 'WorkflowDefinitionChangeTest.StepC';

  // 0 = [A, B]; 1 = [A, X, B] (insert); 2 = [A, C] (B removed).
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

  // ============================================================
  // 15. TIMEOUT SWEEP SKIPS A PARKED INSTANCE
  // ============================================================

  @IsTest
  static void testTimeoutSweepSkipsParkedInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = parkWithInsertedStep(
        'DefChg-Timeout-' + Datetime.now().getTime()
      );
      Workflow_Step_Execution__c pendingB = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instId AND Step_Name__c = :STEP_B
        LIMIT 1
      ];
      pendingB.Timeout_At__c = Datetime.now().addMinutes(-5);
      update pendingB;
      WorkflowTimeoutSweep.processTimedOutSteps(
        Datetime.now(),
        new List<Workflow_Instance__c>()
      );
      Test.stopTest();

      System.assertEquals(
        'DefinitionChanged',
        load(instId).Status__c,
        'The watchdog must not fail a parked instance'
      );
    }
  }
}
