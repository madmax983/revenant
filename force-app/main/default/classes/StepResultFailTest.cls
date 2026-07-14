/**
 * Tests for StepResult.fail() — explicit terminal step failures (issue #37).
 *
 * Covers the acceptance criteria: a deliberate fail() with a non-empty
 * compensation stack drives the saga through the existing LIFO rollback path
 * (Compensating -> Compensated) with ZERO retry hops; a fail() with no stack
 * lands terminal Failed; the author-supplied reason is surfaced verbatim on the
 * instance Error_Message__c; and optional structured failureData is persisted on
 * the failing step's Error_Details__c for downstream inspection.
 */
@IsTest
public class StepResultFailTest {
  // ==========================================
  // MOCK WORKFLOWS & STEPS
  // ==========================================

  // --- fail() with no compensatable steps -> terminal Failed ---------------
  /**
   * @description Single-step fixture workflow whose only step calls fail() with no
   * compensatable predecessors, exercising the terminal-Failed path.
   */
  public class FailNoCompWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the workflow's single step.
     * @return The single-element list containing FailNoCompStep.
     */
    public List<String> getSteps() {
      return new List<String>{ 'StepResultFailTest.FailNoCompStep' };
    }
    /**
     * @description Names the first step to run.
     * @return The FailNoCompStep step name.
     */
    public String getInitialStep() {
      return 'StepResultFailTest.FailNoCompStep';
    }
    /**
     * @description Terminates after the single step.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  /**
   * @description Fixture step that deliberately fails with a business reason and no
   * compensation stack.
   */
  public class FailNoCompStep implements WorkflowStep {
    /**
     * @description Returns an explicit fail() to drive the terminal-Failed path.
     * @param ctx The durable step context.
     * @return A fail StepResult carrying the business reason.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('Order already refunded');
    }
  }

  // --- fail() with a compensatable predecessor -> Compensating/Compensated --
  /**
   * @description Fixture workflow with a compensatable charge step followed by a
   * failing step, exercising LIFO rollback to Compensated.
   */
  public class FailWithCompWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the charge step followed by the failing step.
     * @return The list of CompChargeStep and FailForwardStep names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'StepResultFailTest.CompChargeStep',
        'StepResultFailTest.FailForwardStep'
      };
    }
    /**
     * @description Names the first step to run.
     * @return The CompChargeStep step name.
     */
    public String getInitialStep() {
      return 'StepResultFailTest.CompChargeStep';
    }
    /**
     * @description Routes from the charge step to the failing step, then terminates.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return The next step name, or null once complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'StepResultFailTest.CompChargeStep') {
        return 'StepResultFailTest.FailForwardStep';
      }
      return null;
    }
  }

  /**
   * @description Compensatable fixture step that charges on the forward path and
   * refunds on compensation.
   */
  public class CompChargeStep implements CompensatableStep {
    /**
     * @description Records a charge and completes.
     * @param ctx The durable step context.
     * @return A completed StepResult carrying the charge id.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'chargeId' => 'ch_77777' }
      );
    }
    /**
     * @description Refunds the charge during LIFO rollback.
     * @param ctx The durable step context for compensation.
     * @return A completed StepResult carrying the refund id.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'refundId' => 'rf_77777' }
      );
    }
  }

  /**
   * @description Fixture step that deliberately fails after a compensatable
   * predecessor, triggering rollback.
   */
  public class FailForwardStep implements WorkflowStep {
    /**
     * @description Returns a terminal fail() to trigger compensation of the charge.
     * @param ctx The durable step context.
     * @return A fail StepResult carrying the business reason.
     */
    public StepResult execute(StepContext ctx) {
      // A deliberate, terminal business failure — not a crash, not a retry.
      return StepResult.fail('Account closed');
    }
  }

  // --- fail() carrying structured failureData ------------------------------
  /**
   * @description Single-step fixture workflow whose step fails with structured
   * failureData, verifying it persists on the step record.
   */
  public class FailWithDataWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the workflow's single step.
     * @return The single-element list containing FailWithDataStep.
     */
    public List<String> getSteps() {
      return new List<String>{ 'StepResultFailTest.FailWithDataStep' };
    }
    /**
     * @description Names the first step to run.
     * @return The FailWithDataStep step name.
     */
    public String getInitialStep() {
      return 'StepResultFailTest.FailWithDataStep';
    }
    /**
     * @description Terminates after the single step.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  /**
   * @description Fixture step that fails with a reason and structured failureData
   * payload.
   */
  public class FailWithDataStep implements WorkflowStep {
    /**
     * @description Returns a fail() carrying structured failureData for persistence.
     * @param ctx The durable step context.
     * @return A fail StepResult carrying the reason and failureData map.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.fail(
        'KYC rejected',
        new Map<String, Object>{ 'code' => 'KYC_FAIL', 'attempts' => 3 }
      );
    }
  }

  // ==========================================
  // FACTORY UNIT TESTS (no DML)
  // ==========================================

  @IsTest
  static void testFailFactoryDefaults() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepResult r = StepResult.fail('boom');
      System.assertEquals(StepResult.ActionType.FAIL, r.directive().action);
      System.assertEquals('boom', r.directive().failureReason);
      System.assertEquals(
        null,
        r.directive().failureDataJson,
        'No failureData -> null json'
      );
    }
  }

  @IsTest
  static void testFailFactoryWithData() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepResult r = StepResult.fail(
        'boom',
        new Map<String, Object>{ 'k' => 'v' }
      );
      System.assertEquals(StepResult.ActionType.FAIL, r.directive().action);
      System.assertEquals('boom', r.directive().failureReason);
      System.assert(
        r.directive().failureDataJson != null &&
        r.directive().failureDataJson.contains('"v"'),
        'failureData should be serialized to JSON'
      );
    }
  }

  @IsTest
  static void testFailBlankReasonThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Boolean threw = false;
      try {
        StepResult.fail('   ');
      } catch (IllegalArgumentException e) {
        threw = true;
      }
      System.assert(threw, 'Blank reason must throw IllegalArgumentException');
    }
  }

  // ==========================================
  // ENGINE INTEGRATION TESTS
  // ==========================================

  @IsTest
  static void testFailWithoutCompensationStackGoesToFailed() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'StepResultFailTest.FailNoCompWorkflow',
        'FailNoCompKey',
        null
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      System.assertEquals(
        'Failed',
        result.status,
        'fail() with no compensation stack lands terminal Failed'
      );

      Workflow_Instance__c inst = [
        SELECT Status__c, Error_Message__c, Terminal_At__c, Failure_Category__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Failed', inst.Status__c);
      System.assert(
        inst.Error_Message__c.contains('Order already refunded'),
        'Author reason must appear verbatim in Error_Message__c, got: ' +
        inst.Error_Message__c
      );
      System.assertEquals('EXPLICIT_FAIL', inst.Failure_Category__c);
      System.assertNotEquals(
        null,
        inst.Terminal_At__c,
        'Terminal_At__c stamped on the terminal transition'
      );

      // Exactly one terminal step record (append-only), zero retry hops.
      List<Workflow_Step_Execution__c> steps = [
        SELECT Status__c, Retry_Count__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'StepResultFailTest.FailNoCompStep'
      ];
      System.assertEquals(1, steps.size(), 'One terminal step write only');
      System.assertEquals('Failed', steps[0].Status__c);
      System.assertEquals(
        0,
        steps[0].Retry_Count__c,
        'fail() performs zero retry hops'
      );
      System.assert(
        steps[0].Error_Details__c.contains('Order already refunded'),
        'Reason recorded on the step Error_Details__c'
      );
    }
  }

  @IsTest
  static void testFailWithCompensationStackCompensates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'StepResultFailTest.FailWithCompWorkflow',
        'FailWithCompKey',
        null
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      System.assertEquals(
        'Compensated',
        result.status,
        'fail() with a compensation stack runs LIFO rollback to Compensated'
      );
      System.assertEquals(
        new List<String>{ 'StepResultFailTest.CompChargeStep_Compensate' },
        result.compensatedSteps,
        'The compensatable predecessor must be rolled back'
      );

      Workflow_Instance__c inst = [
        SELECT Status__c, Error_Message__c, Terminal_At__c, Failure_Category__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Compensated', inst.Status__c);
      System.assert(
        inst.Error_Message__c.contains('Account closed'),
        'Author reason must appear verbatim in Error_Message__c, got: ' +
        inst.Error_Message__c
      );
      System.assertEquals(null, inst.Failure_Category__c);
      System.assertNotEquals(null, inst.Terminal_At__c);

      // The failing forward step took zero retry hops.
      Workflow_Step_Execution__c failStep = [
        SELECT Status__c, Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'StepResultFailTest.FailForwardStep'
        LIMIT 1
      ];
      System.assertEquals('Failed', failStep.Status__c);
      System.assertEquals(
        0,
        failStep.Retry_Count__c,
        'fail() performs zero retry hops even with a compensation stack'
      );
    }
  }

  @IsTest
  static void testFailureDataPersisted() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'StepResultFailTest.FailWithDataWorkflow',
        'FailWithDataKey',
        null
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      harness.drive();
      Test.stopTest();

      Workflow_Step_Execution__c step = [
        SELECT Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'StepResultFailTest.FailWithDataStep'
        LIMIT 1
      ];
      System.assert(
        step.Error_Details__c.contains('KYC rejected'),
        'Reason persisted alongside failureData'
      );
      System.assert(
        step.Error_Details__c.contains('KYC_FAIL'),
        'Structured failureData persisted and retrievable on the step record'
      );
    }
  }

  // --- fail() returned from a compensation step ----------------------------
  /**
   * @description Fixture workflow whose forward failure triggers a compensation
   * step that itself fails, exercising the CompensationFailed terminal state.
   */
  public class FailCompWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the compensatable charge step followed by the failing step.
     * @return The list of CompensatableChargeStep and AlwaysFailStep names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'StepResultFailTest.CompensatableChargeStep',
        'StepResultFailTest.AlwaysFailStep'
      };
    }
    /**
     * @description Names the first step to run.
     * @return The CompensatableChargeStep step name.
     */
    public String getInitialStep() {
      return 'StepResultFailTest.CompensatableChargeStep';
    }
    /**
     * @description Routes from the charge step to the failing step, then terminates.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return The next step name, or null once complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'StepResultFailTest.CompensatableChargeStep') {
        return 'StepResultFailTest.AlwaysFailStep';
      }
      return null;
    }
  }

  /**
   * @description Compensatable fixture step whose compensation deliberately fails,
   * to drive the CompensationFailed path.
   */
  public class CompensatableChargeStep implements CompensatableStep {
    /**
     * @description Records a charge and completes.
     * @param ctx The durable step context.
     * @return A completed StepResult carrying the charge marker.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'charged');
    }
    /**
     * @description Deliberately fails compensation to exercise CompensationFailed.
     * @param ctx The durable step context for compensation.
     * @return A fail StepResult carrying the compensation failure reason.
     */
    public StepResult compensate(StepContext ctx) {
      // Compensation step deliberately fails (e.g. reversal account locked).
      return StepResult.fail('Reversal account locked');
    }
  }

  /**
   * @description Fixture step that always fails, triggering rollback of the
   * compensatable predecessor.
   */
  public class AlwaysFailStep implements WorkflowStep {
    /**
     * @description Returns a terminal fail() to trigger compensation.
     * @param ctx The durable step context.
     * @return A fail StepResult carrying the trigger reason.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('Trigger compensation');
    }
  }

  @IsTest
  static void testCompensationStepFailLandsInCompensationFailed() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'StepResultFailTest.FailCompWorkflow',
        'FailCompKey',
        null
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      System.assertEquals(
        'CompensationFailed',
        result.status,
        'fail() from a compensation step must land in CompensationFailed'
      );

      Workflow_Instance__c inst = [
        SELECT Status__c, Error_Message__c, Failure_Category__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('CompensationFailed', inst.Status__c);
      System.assert(
        inst.Error_Message__c.contains('Reversal account locked'),
        'Author compensation reason must appear in Error_Message__c, got: ' +
        inst.Error_Message__c
      );
      System.assertEquals('COMPENSATION_FAILED', inst.Failure_Category__c);

      Workflow_Step_Execution__c compStep = [
        SELECT Status__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'StepResultFailTest.CompensatableChargeStep_Compensate'
        LIMIT 1
      ];
      System.assertEquals('Failed', compStep.Status__c);
      System.assert(
        compStep.Error_Details__c.contains('Reversal account locked'),
        'Compensation reason must appear in step Error_Details__c'
      );
    }
  }
}
