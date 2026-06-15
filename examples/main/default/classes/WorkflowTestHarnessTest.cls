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
}
