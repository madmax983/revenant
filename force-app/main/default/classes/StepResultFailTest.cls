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
  public class FailNoCompWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'StepResultFailTest.FailNoCompStep' };
    }
    public String getInitialStep() {
      return 'StepResultFailTest.FailNoCompStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  public class FailNoCompStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('Order already refunded');
    }
  }

  // --- fail() with a compensatable predecessor -> Compensating/Compensated --
  public class FailWithCompWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepResultFailTest.CompChargeStep',
        'StepResultFailTest.FailForwardStep'
      };
    }
    public String getInitialStep() {
      return 'StepResultFailTest.CompChargeStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'StepResultFailTest.CompChargeStep') {
        return 'StepResultFailTest.FailForwardStep';
      }
      return null;
    }
  }

  public class CompChargeStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'chargeId' => 'ch_77777' }
      );
    }
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'refundId' => 'rf_77777' }
      );
    }
  }

  public class FailForwardStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // A deliberate, terminal business failure — not a crash, not a retry.
      return StepResult.fail('Account closed');
    }
  }

  // --- fail() carrying structured failureData ------------------------------
  public class FailWithDataWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'StepResultFailTest.FailWithDataStep' };
    }
    public String getInitialStep() {
      return 'StepResultFailTest.FailWithDataStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  public class FailWithDataStep implements WorkflowStep {
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
    StepResult r = StepResult.fail('boom');
    System.assertEquals(StepResult.ActionType.FAIL, r.action);
    System.assertEquals('boom', r.failureReason);
    System.assertEquals(null, r.failureDataJson, 'No failureData -> null json');
  }

  @IsTest
  static void testFailFactoryWithData() {
    StepResult r = StepResult.fail(
      'boom',
      new Map<String, Object>{ 'k' => 'v' }
    );
    System.assertEquals(StepResult.ActionType.FAIL, r.action);
    System.assertEquals('boom', r.failureReason);
    System.assert(
      r.failureDataJson != null && r.failureDataJson.contains('"v"'),
      'failureData should be serialized to JSON'
    );
  }

  @IsTest
  static void testFailBlankReasonThrows() {
    Boolean threw = false;
    try {
      StepResult.fail('   ');
    } catch (IllegalArgumentException e) {
      threw = true;
    }
    System.assert(threw, 'Blank reason must throw IllegalArgumentException');
  }

  // ==========================================
  // ENGINE INTEGRATION TESTS
  // ==========================================

  @IsTest
  static void testFailWithoutCompensationStackGoesToFailed() {
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

  @IsTest
  static void testFailWithCompensationStackCompensates() {
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

  @IsTest
  static void testFailureDataPersisted() {
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

  // --- fail() returned from a compensation step ----------------------------
  public class FailCompWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepResultFailTest.CompensatableChargeStep',
        'StepResultFailTest.AlwaysFailStep'
      };
    }
    public String getInitialStep() {
      return 'StepResultFailTest.CompensatableChargeStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'StepResultFailTest.CompensatableChargeStep') {
        return 'StepResultFailTest.AlwaysFailStep';
      }
      return null;
    }
  }

  public class CompensatableChargeStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'charged');
    }
    public StepResult compensate(StepContext ctx) {
      // Compensation step deliberately fails (e.g. reversal account locked).
      return StepResult.fail('Reversal account locked');
    }
  }

  public class AlwaysFailStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('Trigger compensation');
    }
  }

  @IsTest
  static void testCompensationStepFailLandsInCompensationFailed() {
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
