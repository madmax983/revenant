/**
 * Tests for WorkflowTestHarness: proves the harness drives real example workflows
 * (parallel scatter-gather, sleep, child workflows, human-in-the-loop signals, and
 * saga compensation) to a stable state through the shipped engine execution paths —
 * with no manual WorkflowOrchestrator construction, no Test.getEventBus().deliver()
 * calls, and no direct instance-record mutation in the test body.
 */
@isTest
public class WorkflowTestHarnessTest {
  /**
   * Happy path: one drive() call to the human-in-the-loop suspend, one injectSignal()
   * call to completion. Exercises split/join parallelism, a child workflow with a sleep,
   * and an approval signal — the full OnboardingWorkflowExample DAG.
   */
  @isTest
  static void driveAndInjectSignalRunsOnboardingToCompletion() {
    Map<String, Object> inputMap = new Map<String, Object>{
      'amount' => 15000.0,
      'customerName' => 'Acme Corp',
      'email' => 'admin@acme.com'
    };

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'OnboardingWorkflowExample',
      'Harness_Onboarding_1',
      inputMap
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

    // Drive #1: advance from start through the parallel fan-out/rejoin to the
    // executive-approval suspend, all in a single call.
    WorkflowTestHarness.Result suspended = harness.drive();
    Test.stopTest();

    System.assertEquals(
      'Suspended',
      suspended.status,
      'Workflow should pause for VIP approval'
    );
    System.assert(
      suspended.isSuspended,
      'Result should report the suspended state'
    );
    System.assert(
      suspended.reachedStep('OnboardingWorkflowExample.ProvisionSandboxStep'),
      'Parallel branch ProvisionSandboxStep should have executed'
    );
    System.assert(
      suspended.reachedStep(
        'OnboardingWorkflowExample.CreateBillingAccountStep'
      ),
      'Parallel branch CreateBillingAccountStep should have executed'
    );
    System.assert(
      suspended.reachedStep('OnboardingWorkflowExample.JoinOnboardingStep'),
      'Rejoin step should have executed'
    );

    // Drive #2: provide the approval signal and let the harness resume the child
    // welcome workflow (including its sleep) and run to completion.
    WorkflowTestHarness.Result completed = harness.injectSignal(
      'Harness_Onboarding_1',
      'Approve:VIPOrderApproval',
      '{"approved":true,"comments":"Approved VIP Customer"}'
    );

    System.assertEquals(
      'Completed',
      completed.status,
      'Workflow should reach Completed after approval'
    );
    System.assert(completed.isTerminal, 'Completed is a terminal state');
    System.assert(
      completed.output.contains('"status":"Completed"'),
      'Final output should carry the completed status payload'
    );
    System.assert(
      completed.completedSteps.contains(
        'OnboardingWorkflowExample.CompleteOnboardingStep'
      ),
      'Final step should be recorded as completed'
    );
  }

  /**
   * Saga: a failing forward step triggers compensation. The harness drives the
   * whole rollback through the shipped handleCrash + compensation loop and exposes
   * the LIFO compensate() order from the append-only audit records.
   */
  @isTest
  static void driveRunsSagaCompensationsInLifoOrder() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'SagaWorkflowExample.SagaWorkflow',
      'Harness_Saga_1',
      '{"email":"test@example.com"}'
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.failStep('SagaWorkflowExample.SendWelcomeEmailStep', 'SMTP Server Down');
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals(
      'Compensated',
      result.status,
      'Saga should fully compensate after the SMTP failure'
    );
    System.assertEquals(
      new List<String>{
        'SagaWorkflowExample.ProvisionServiceStep_Compensate',
        'SagaWorkflowExample.ChargeCreditCardStep_Compensate'
      },
      result.compensatedSteps,
      'Compensations must run in reverse (LIFO) order'
    );
  }

  /**
   * Bounded: a budget too small to stabilize fails the test with a clear message
   * rather than hanging or silently passing.
   */
  @isTest
  static void driveFailsWhenBudgetExhausted() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'OnboardingWorkflowExample',
      'Harness_Budget_1',
      new Map<String, Object>{
        'amount' => 15000.0,
        'customerName' => 'Acme Corp',
        'email' => 'admin@acme.com'
      }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

    Boolean threw = false;
    try {
      harness.drive(1);
    } catch (WorkflowTestHarness.HarnessException ex) {
      threw = true;
      System.assert(
        ex.getMessage().contains('did not stabilize'),
        'Message should explain the workflow did not stabilize: ' +
        ex.getMessage()
      );
    }
    Test.stopTest();
    System.assert(threw, 'Exhausting the hop budget should throw');
  }

  /**
   * driveUntilStep: pauses after ChargeCreditCardStep completes, asserts the
   * intermediate state, then resumes to the final Compensated terminal — proving
   * that a harness can be paused and resumed across multiple calls.
   */
  @isTest
  static void driveUntilStepPausesAndResumes() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'SagaWorkflowExample.SagaWorkflow',
      'Harness_UntilStep_1',
      '{"email":"test@example.com"}'
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.failStep('SagaWorkflowExample.SendWelcomeEmailStep', 'SMTP Server Down');

    // Pause after the first forward step completes.
    WorkflowTestHarness.Result mid = harness.driveUntilStep(
      'SagaWorkflowExample.ChargeCreditCardStep'
    );

    System.assert(
      mid.reachedStep('SagaWorkflowExample.ChargeCreditCardStep'),
      'ChargeCreditCardStep should appear in the audit trail'
    );
    System.assert(
      !mid.isTerminal,
      'Workflow should still be running after the first step'
    );

    // Resume from the paused point to the final terminal state.
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals(
      'Compensated',
      result.status,
      'Saga should compensate after the SMTP failure'
    );
    System.assertEquals(
      new List<String>{
        'SagaWorkflowExample.ProvisionServiceStep_Compensate',
        'SagaWorkflowExample.ChargeCreditCardStep_Compensate'
      },
      result.compensatedSteps,
      'Compensations must run in LIFO order'
    );
  }

  /**
   * Watchdog timeout: the harness fires the shipped WorkflowTimeoutJob to fail a
   * pending step, without the author hand-mutating the instance record.
   */
  @isTest
  static void fireTimeoutFailsThroughWorkflowTimeoutJob() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'OnboardingWorkflowExample',
      'Harness_Timeout_1',
      new Map<String, Object>{
        'amount' => 100.0,
        'customerName' => 'Acme Corp',
        'email' => 'admin@acme.com'
      }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    // The initial step is still Pending right after start; fire its timeout.
    WorkflowTestHarness.Result result = harness.fireTimeout(
      'OnboardingWorkflowExample.VerifyOrderStep'
    );
    Test.stopTest();

    System.assertEquals(
      'Failed',
      result.status,
      'Timing out the initial pending step should fail the workflow'
    );
  }

  // --- Test-Only Steps and Workflows for Fault Injection ------------------

  public class SimpleStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, new Map<String, Object>{'done' => true});
    }
  }

  public class RetryStep implements WorkflowStep, RetryConfigurable {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, new Map<String, Object>{'done' => true});
    }
    public RetryPolicy getRetryPolicy() {
      RetryPolicy policy = new RetryPolicy();
      policy.maximumAttempts = 3;
      policy.initialIntervalSeconds = 1;
      policy.backoffCoefficient = 1.0;
      return policy;
    }
  }

  public class MyCompensatableStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, new Map<String, Object>{'done' => true});
    }
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, new Map<String, Object>{'undone' => true});
    }
  }

  public class TestFaultWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowTestHarnessTest.SimpleStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowTestHarnessTest.SimpleStep';
    }
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  public class TestRetryWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowTestHarnessTest.RetryStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowTestHarnessTest.RetryStep';
    }
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  public class TestCompensateWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowTestHarnessTest.MyCompensatableStep',
        'WorkflowTestHarnessTest.SimpleStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowTestHarnessTest.MyCompensatableStep';
    }
    public String getNextStep(String currentStep, StepResult result) {
      if (currentStep == 'WorkflowTestHarnessTest.MyCompensatableStep') {
        return 'WorkflowTestHarnessTest.SimpleStep';
      }
      return null;
    }
  }

  public class StartChildStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String childKey = 'ChildKey';
      StepContext.ChildOutcome outcome = ctx.getChildOutcome(childKey);
      if (outcome.isPresent()) {
        if (outcome.isSuccess()) {
          return StepResult.complete(null, null);
        } else {
          return StepResult.fail('Child failed: ' + outcome.errorMessage);
        }
      }
      return StepResult.startChild('WorkflowTestHarnessTest.TestFaultWorkflow', childKey, null);
    }
  }

  public class TestParentWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowTestHarnessTest.StartChildStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowTestHarnessTest.StartChildStep';
    }
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  // --- Fault Injection Tests -----------------------------------------------

  @isTest
  static void testFaultInjectionForwardPath() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowTestHarnessTest.TestFaultWorkflow',
      'Fault_Forward_1',
      new Map<String, Object>()
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.failStep('WorkflowTestHarnessTest.SimpleStep', 'Injected forward failure');
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('Failed', result.status, 'Workflow should fail due to injected fault');
    System.assert(
      result.output == null || !result.output.contains('"done":true'),
      'Step should not have successfully completed'
    );
  }

  @isTest
  static void testFaultInjectionRetryOnce() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowTestHarnessTest.TestRetryWorkflow',
      'Fault_Retry_1',
      new Map<String, Object>()
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.failStepOnce('WorkflowTestHarnessTest.RetryStep', 'Injected retry failure');
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status, 'Workflow should succeed after retry');
  }

  @isTest
  static void testFaultInjectionCompensate() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowTestHarnessTest.TestCompensateWorkflow',
      'Fault_Comp_1',
      new Map<String, Object>()
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    // Fail the second step forward to trigger compensation of the first
    harness.failStep('WorkflowTestHarnessTest.SimpleStep', 'Trigger rollback');
    // Fail the compensation step itself
    harness.failStep('WorkflowTestHarnessTest.MyCompensatableStep_Compensate', 'Injected compensation failure');
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('CompensationFailed', result.status, 'Rollback should be incomplete');
    
    // Check execution logs
    List<Workflow_Step_Execution__c> logs = [
      SELECT Step_Name__c, Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      ORDER BY CreatedDate ASC
    ];
    
    Boolean foundCompensateFailure = false;
    for (Workflow_Step_Execution__c log : logs) {
      if (log.Step_Name__c == 'WorkflowTestHarnessTest.MyCompensatableStep_Compensate') {
        System.assertEquals('Failed', log.Status__c);
        System.assert(log.Error_Details__c.contains('Injected compensation failure'));
        foundCompensateFailure = true;
      }
    }
    System.assert(foundCompensateFailure, 'Should have executed and failed the compensation step');
  }

  @isTest
  static void testFaultInjectionChildWorkflow() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowTestHarnessTest.TestParentWorkflow',
      'Parent_1',
      new Map<String, Object>()
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    // Register fault on the child workflow step, specifying the child step name
    harness.failStep('WorkflowTestHarnessTest.SimpleStep', 'Injected child step failure');
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    // Verify parent has failed because the child failed
    System.assertEquals('Failed', result.status, 'Parent workflow should fail if child fails');
  }
}

