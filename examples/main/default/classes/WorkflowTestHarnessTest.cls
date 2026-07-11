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
    harness.failStep(
      'SagaWorkflowExample.SendWelcomeEmailStep',
      'SMTP Server Down'
    );
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
    harness.failStep(
      'SagaWorkflowExample.SendWelcomeEmailStep',
      'SMTP Server Down'
    );

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

  /**
   * @description Trivial step fixture that completes immediately.
   */
  public class SimpleStep implements WorkflowStep {
    /**
     * @description Completes with a fixed done marker.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'done' => true }
      );
    }
  }

  /**
   * @description Retry-configurable step fixture used to exercise the retry policy path.
   */
  public class RetryStep implements WorkflowStep, RetryConfigurable {
    /**
     * @description Completes with a fixed done marker.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'done' => true }
      );
    }
    /**
     * @description Supplies the fixture's retry policy (up to 3 attempts, 1s interval).
     * @return The retry policy the engine applies to this step.
     */
    public RetryPolicy getRetryPolicy() {
      RetryPolicy policy = new RetryPolicy();
      policy.maximumAttempts = 3;
      policy.initialIntervalSeconds = 1;
      policy.backoffCoefficient = 1.0;
      return policy;
    }
  }

  /**
   * @description Compensatable step fixture whose execute and compensate both succeed.
   */
  public class MyCompensatableStep implements CompensatableStep {
    /**
     * @description Completes the forward action with a done marker.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result marking the forward action.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'done' => true }
      );
    }
    /**
     * @description Completes the compensating action with an undone marker.
     * @param ctx The durable step context for this execution.
     * @return A COMPLETE result marking compensation.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'undone' => true }
      );
    }
  }

  /**
   * @description Single-step workflow fixture over SimpleStep for fault-injection tests.
   */
  public class TestFaultWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the sole fixture step name.
     * @return A one-element list naming SimpleStep.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowTestHarnessTest.SimpleStep' };
    }
    /**
     * @description Returns the step the fixture begins with.
     * @return The SimpleStep name.
     */
    public String getInitialStep() {
      return 'WorkflowTestHarnessTest.SimpleStep';
    }
    /**
     * @description Terminal single-step fixture: there is no successor step.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  /**
   * @description Single-step workflow fixture over RetryStep for retry-path tests.
   */
  public class TestRetryWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the sole fixture step name.
     * @return A one-element list naming RetryStep.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowTestHarnessTest.RetryStep' };
    }
    /**
     * @description Returns the step the fixture begins with.
     * @return The RetryStep name.
     */
    public String getInitialStep() {
      return 'WorkflowTestHarnessTest.RetryStep';
    }
    /**
     * @description Terminal single-step fixture: there is no successor step.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  /**
   * @description Two-step workflow fixture (compensatable then simple) for
   * compensation-path tests.
   */
  public class TestCompensateWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered fixture step names.
     * @return The compensatable and simple step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowTestHarnessTest.MyCompensatableStep',
        'WorkflowTestHarnessTest.SimpleStep'
      };
    }
    /**
     * @description Returns the step the fixture begins with.
     * @return The compensatable step name.
     */
    public String getInitialStep() {
      return 'WorkflowTestHarnessTest.MyCompensatableStep';
    }
    /**
     * @description Advances from the compensatable step to the simple step, then ends.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return The next step name, or null once the simple step completes.
     */
    public String getNextStep(String currentStep, StepResult result) {
      if (currentStep == 'WorkflowTestHarnessTest.MyCompensatableStep') {
        return 'WorkflowTestHarnessTest.SimpleStep';
      }
      return null;
    }
  }

  /**
   * @description Parent step fixture that starts a child workflow and resumes on its
   * outcome, exercising parent/child composition in the harness.
   */
  public class StartChildStep implements WorkflowStep {
    /**
     * @description Starts the child on first run and suspends; on the child's outcome
     * completes on success or fails on child failure.
     * @param ctx The durable step context exposing the child outcome.
     * @return startChild while awaiting the child, or COMPLETE/FAIL on its outcome.
     */
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
      return StepResult.startChild(
        'WorkflowTestHarnessTest.TestFaultWorkflow',
        childKey,
        null
      );
    }
  }

  /**
   * @description Single-step parent workflow fixture over StartChildStep.
   */
  public class TestParentWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the sole fixture step name.
     * @return A one-element list naming StartChildStep.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowTestHarnessTest.StartChildStep' };
    }
    /**
     * @description Returns the step the fixture begins with.
     * @return The StartChildStep name.
     */
    public String getInitialStep() {
      return 'WorkflowTestHarnessTest.StartChildStep';
    }
    /**
     * @description Terminal single-step fixture: there is no successor step.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  /**
   * @description Two-step child workflow fixture (compensatable then simple) used as
   * the child in compensating parent/child tests.
   */
  public class TestCompensatableChildWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered fixture step names.
     * @return The compensatable and simple step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowTestHarnessTest.MyCompensatableStep',
        'WorkflowTestHarnessTest.SimpleStep'
      };
    }
    /**
     * @description Returns the step the fixture begins with.
     * @return The compensatable step name.
     */
    public String getInitialStep() {
      return 'WorkflowTestHarnessTest.MyCompensatableStep';
    }
    /**
     * @description Advances from the compensatable step to the simple step, then ends.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return The next step name, or null once the simple step completes.
     */
    public String getNextStep(String currentStep, StepResult result) {
      if (currentStep == 'WorkflowTestHarnessTest.MyCompensatableStep') {
        return 'WorkflowTestHarnessTest.SimpleStep';
      }
      return null;
    }
  }

  /**
   * @description Parent step fixture that starts a compensatable child workflow and
   * resumes on its outcome.
   */
  public class StartCompensatableChildStep implements WorkflowStep {
    /**
     * @description Starts the compensatable child on first run and suspends; on its
     * outcome completes on success or fails on child failure.
     * @param ctx The durable step context exposing the child outcome.
     * @return startChild while awaiting the child, or COMPLETE/FAIL on its outcome.
     */
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
      return StepResult.startChild(
        'WorkflowTestHarnessTest.TestCompensatableChildWorkflow',
        childKey,
        null
      );
    }
  }

  /**
   * @description Single-step parent workflow fixture over StartCompensatableChildStep.
   */
  public class TestCompensatableParentWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the sole fixture step name.
     * @return A one-element list naming StartCompensatableChildStep.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowTestHarnessTest.StartCompensatableChildStep'
      };
    }
    /**
     * @description Returns the step the fixture begins with.
     * @return The StartCompensatableChildStep name.
     */
    public String getInitialStep() {
      return 'WorkflowTestHarnessTest.StartCompensatableChildStep';
    }
    /**
     * @description Terminal single-step fixture: there is no successor step.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, ending the workflow.
     */
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
    harness.failStep(
      'WorkflowTestHarnessTest.SimpleStep',
      'Injected forward failure'
    );
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals(
      'Failed',
      result.status,
      'Workflow should fail due to injected fault'
    );
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
    harness.failStepOnce(
      'WorkflowTestHarnessTest.RetryStep',
      'Injected retry failure'
    );
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals(
      'Completed',
      result.status,
      'Workflow should succeed after retry'
    );
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
    harness.failStep(
      'WorkflowTestHarnessTest.MyCompensatableStep_Compensate',
      'Injected compensation failure'
    );
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals(
      'CompensationFailed',
      result.status,
      'Rollback should be incomplete'
    );

    // Check execution logs
    List<Workflow_Step_Execution__c> logs = [
      SELECT Step_Name__c, Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      ORDER BY CreatedDate ASC
    ];

    Boolean foundCompensateFailure = false;
    for (Workflow_Step_Execution__c log : logs) {
      if (
        log.Step_Name__c ==
        'WorkflowTestHarnessTest.MyCompensatableStep_Compensate'
      ) {
        System.assertEquals('Failed', log.Status__c);
        System.assert(
          log.Error_Details__c.contains('Injected compensation failure')
        );
        foundCompensateFailure = true;
      }
    }
    System.assert(
      foundCompensateFailure,
      'Should have executed and failed the compensation step'
    );
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
    harness.failStep(
      'WorkflowTestHarnessTest.SimpleStep',
      'Injected child step failure'
    );
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    // Verify parent has failed because the child failed
    System.assertEquals(
      'Failed',
      result.status,
      'Parent workflow should fail if child fails'
    );
  }

  @isTest
  static void testFaultInjectionChildWorkflowCompensate() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowTestHarnessTest.TestCompensatableParentWorkflow',
      'Parent_Comp_1',
      new Map<String, Object>()
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    // Register fault to fail the second step of the child, causing it to roll back
    harness.failStep(
      'WorkflowTestHarnessTest.SimpleStep',
      'Injected child step failure'
    );
    // Register fault to fail the compensation of the first step of the child
    harness.failStep(
      'WorkflowTestHarnessTest.MyCompensatableStep_Compensate',
      'Injected child compensation failure'
    );

    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    // Verify parent has failed because the child failed
    System.assertEquals(
      'Failed',
      result.status,
      'Parent workflow should fail if child fails'
    );

    // Retrieve child workflow instances
    List<Workflow_Instance__c> children = [
      SELECT Id, Status__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :instanceId
    ];
    System.assertEquals(
      1,
      children.size(),
      'Should have started one child workflow'
    );
    Workflow_Instance__c child = children[0];
    System.assertEquals(
      'CompensationFailed',
      child.Status__c,
      'Child workflow should be in CompensationFailed state'
    );

    // Verify child step execution log for compensation step is Failed
    List<Workflow_Step_Execution__c> logs = [
      SELECT Step_Name__c, Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :child.Id
      ORDER BY CreatedDate ASC
    ];
    Boolean foundCompensateFailure = false;
    for (Workflow_Step_Execution__c log : logs) {
      if (
        log.Step_Name__c ==
        'WorkflowTestHarnessTest.MyCompensatableStep_Compensate'
      ) {
        System.assertEquals('Failed', log.Status__c);
        System.assert(
          log.Error_Details__c.contains('Injected child compensation failure')
        );
        foundCompensateFailure = true;
      }
    }
  }

  // ==========================================================================
  // ISSUE 110: DETERMINISTIC SLEEP & RETRY TIME-SKIP TEST ARTIFACTS
  // ==========================================================================

  /**
   * @description Single-step workflow fixture that sleeps, used to verify the
   * harness's deterministic sleep time-skip.
   */
  public class TimeSkipSleepWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the sole fixture step name.
     * @return A one-element list naming the time-skip sleep step.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowTestHarnessTest.TimeSkipSleepStep' };
    }
    /**
     * @description Returns the step the fixture begins with.
     * @return The time-skip sleep step name.
     */
    public String getInitialStep() {
      return 'WorkflowTestHarnessTest.TimeSkipSleepStep';
    }
    /**
     * @description Terminal single-step fixture: there is no successor step.
     * @param currentStepName The name of the step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Step fixture that sleeps for 60s on first run and completes when the
   * harness skips time and resumes it.
   */
  public class TimeSkipSleepStep implements WorkflowStep {
    /**
     * @description Sleeps on first run; completes once resumed with sleep state.
     * @param ctx The durable step context; a non-null step state marks the post-sleep resume.
     * @return A SLEEP result on first run, or COMPLETE once resumed.
     */
    public StepResult execute(StepContext ctx) {
      if (ctx.stepStateJson != null) {
        return StepResult.complete(null, 'ResumedSuccessfully');
      }
      return StepResult.sleep(60, 'resumed_state');
    }
  }

  /**
   * @description Single-step workflow fixture that retries, used to verify the
   * harness's deterministic retry time-skip.
   */
  public class TimeSkipRetryWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the sole fixture step name.
     * @return A one-element list naming the time-skip retry step.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowTestHarnessTest.TimeSkipRetryStep' };
    }
    /**
     * @description Returns the step the fixture begins with.
     * @return The time-skip retry step name.
     */
    public String getInitialStep() {
      return 'WorkflowTestHarnessTest.TimeSkipRetryStep';
    }
    /**
     * @description Terminal single-step fixture: there is no successor step.
     * @param currentStepName The name of the step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Step fixture that retries until its third attempt, then completes.
   */
  public class TimeSkipRetryStep implements WorkflowStep {
    /**
     * @description Retries while the attempt count is below three, then completes.
     * @param ctx The durable step context exposing the current attempt number.
     * @return A RETRY result before the third attempt, or COMPLETE on it.
     */
    public StepResult execute(StepContext ctx) {
      if (ctx.attempt < 3) {
        return StepResult.retry(5);
      }
      return StepResult.complete(null, 'RetryComplete');
    }
  }

  /**
   * @description Workflow fixture that splits into two parallel sleeping branches,
   * used to verify time-skip across concurrent branches.
   */
  public class ParallelSleepWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the fixture step names, including the parallel branch pair.
     * @return The split step followed by the comma-joined parallel branch names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowTestHarnessTest.ParallelSleepSplitStep',
        'WorkflowTestHarnessTest.ParallelSleepA,WorkflowTestHarnessTest.ParallelSleepB'
      };
    }
    /**
     * @description Returns the step the fixture begins with.
     * @return The split step name.
     */
    public String getInitialStep() {
      return 'WorkflowTestHarnessTest.ParallelSleepSplitStep';
    }
    /**
     * @description Routing is driven by the split result, so no static successor is given.
     * @param currentStepName The name of the step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null; the parallel branches are launched by the split.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Step fixture that splits execution into the two parallel sleep branches.
   */
  public class ParallelSleepSplitStep implements WorkflowStep {
    /**
     * @description Splits into the ParallelSleepA and ParallelSleepB branches.
     * @param ctx The durable step context for this execution.
     * @return A SPLIT result fanning out to the two parallel branches.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowTestHarnessTest.ParallelSleepA',
          'WorkflowTestHarnessTest.ParallelSleepB'
        }
      );
    }
  }

  /**
   * @description Parallel branch fixture that sleeps then completes.
   */
  public class ParallelSleepA implements WorkflowStep {
    /**
     * @description Sleeps for 10s on first run; completes once resumed with sleep state.
     * @param ctx The durable step context; a non-null step state marks the post-sleep resume.
     * @return A SLEEP result on first run, or COMPLETE once resumed.
     */
    public StepResult execute(StepContext ctx) {
      if (ctx.stepStateJson != null) {
        return StepResult.complete(null, 'ResumedA');
      }
      return StepResult.sleep(10, 'slept_state_a');
    }
  }

  /**
   * @description Parallel branch fixture that suspends until its signal arrives.
   */
  public class ParallelSleepB implements WorkflowStep {
    /**
     * @description Completes once its branch signal is present, otherwise suspends.
     * @param ctx The durable step context exposing the branch signal.
     * @return COMPLETE when signaled, or SUSPEND while awaiting the signal.
     */
    public StepResult execute(StepContext ctx) {
      if (ctx.getSignal('WorkflowTestHarnessTest.ParallelSleepB').isPresent()) {
        return StepResult.complete(null, 'done_b');
      }
      return StepResult.suspend();
    }
  }

  @isTest
  static void testSleepWorkflowTimeSkip() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowTestHarnessTest.TimeSkipSleepWorkflow',
      'SleepKey',
      null
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.disableAutoTimeSkip = true;

    // Drive the initial step (TimeSkipSleepStep)
    WorkflowTestHarness.Result result = harness.step();

    System.assertEquals('Suspended', result.status);
    System.assertEquals(
      true,
      result.isSleeping,
      'Should be marked as sleeping'
    );
    System.assertEquals(
      false,
      result.isAwaitingRetry,
      'Should not be retrying'
    );

    // Fire the sleep and drive to completion
    WorkflowTestHarness.Result finalResult = harness.fireSleep(
      'WorkflowTestHarnessTest.TimeSkipSleepStep'
    );
    Test.stopTest();

    System.assertEquals('Completed', finalResult.status);
  }

  @isTest
  static void testRetryWorkflowTimeSkip() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowTestHarnessTest.TimeSkipRetryWorkflow',
      'RetryKey',
      null
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.disableAutoTimeSkip = true;

    // Drive the initial step (TimeSkipRetryStep first attempt which retries)
    WorkflowTestHarness.Result result = harness.step();

    System.assertEquals('Suspended', result.status);
    System.assertEquals(false, result.isSleeping, 'Should not be sleeping');
    System.assertEquals(
      true,
      result.isAwaitingRetry,
      'Should be marked as retrying'
    );

    // Fire the retry once (will run second attempt and retry again)
    WorkflowTestHarness.Result secondResult = harness.fireRetry(
      'WorkflowTestHarnessTest.TimeSkipRetryStep'
    );
    System.assertEquals('Suspended', secondResult.status);
    System.assertEquals(true, secondResult.isAwaitingRetry);

    // Fire the retry again (will run third attempt and complete)
    WorkflowTestHarness.Result finalResult = harness.fireRetry(
      'WorkflowTestHarnessTest.TimeSkipRetryStep'
    );
    Test.stopTest();

    System.assertEquals('Completed', finalResult.status);
  }

  @isTest
  static void testFireSleepOnNonSleepingStepThrows() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowTestHarnessTest.TimeSkipSleepWorkflow',
      'SleepKey2',
      null
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.drive();
    Test.stopTest();

    try {
      harness.fireSleep('WorkflowTestHarnessTest.TimeSkipSleepStep');
      System.assert(false, 'Should have thrown HarnessException');
    } catch (WorkflowTestHarness.HarnessException ex) {
      System.assert(
        ex.getMessage().contains('is not currently sleeping'),
        'Actionable message expected: ' + ex.getMessage()
      );
    }
  }

  @isTest
  static void testFireRetryOnNonRetryingStepThrows() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowTestHarnessTest.TimeSkipRetryWorkflow',
      'RetryKey2',
      null
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.drive();
    Test.stopTest();

    try {
      harness.fireRetry('WorkflowTestHarnessTest.TimeSkipRetryStep');
      System.assert(false, 'Should have thrown HarnessException');
    } catch (WorkflowTestHarness.HarnessException ex) {
      System.assert(
        ex.getMessage().contains('is not currently awaiting retry'),
        'Actionable message expected: ' + ex.getMessage()
      );
    }
  }

  @isTest
  static void testJobsGracefulNullContext() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowTestHarnessTest.TimeSkipSleepWorkflow',
      'SleepKeyJobs',
      null
    );
    Id retryInstanceId = WorkflowEngine.start(
      'WorkflowTestHarnessTest.TimeSkipRetryWorkflow',
      'RetryKeyJobs',
      null
    );
    // Call Schedulable execute directly with null context.
    // It should run without throwing since we guarded System.abortJob.
    new WorkflowSleepJob(instanceId).execute(null);
    new WorkflowRetryJob(
        retryInstanceId,
        'WorkflowTestHarnessTest.TimeSkipRetryStep'
      )
      .execute(null);

    // Validate that constructors throw on null instance ID
    try {
      new WorkflowSleepJob(null);
      System.assert(
        false,
        'Expected WorkflowSleepJob to throw WorkflowException'
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      System.assertEquals('instanceId is required.', ex.getMessage());
    }

    try {
      new WorkflowRetryJob(null, 'WorkflowTestHarnessTest.TimeSkipRetryStep');
      System.assert(
        false,
        'Expected WorkflowRetryJob to throw WorkflowException'
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      System.assertEquals('instanceId is required.', ex.getMessage());
    }

    Test.stopTest();
  }

  @isTest
  static void testParallelSleepBranchDifferentiated() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowTestHarnessTest.ParallelSleepWorkflow',
      'ParallelSleepKey',
      null
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.disableAutoTimeSkip = true;

    // Run first step (ParallelSleepSplitStep) which splits the flow
    WorkflowTestHarness.Result splitResult = harness.step();
    System.assertEquals('Running', splitResult.status);

    // Run the next step execution (runs ParallelSleepA which returns SLEEP and suspends)
    WorkflowTestHarness.Result resultA = harness.step();
    System.assertEquals('Suspended', resultA.status);
    System.assertEquals(true, resultA.isSleeping);

    // Run the next step execution (runs ParallelSleepB which returns SUSPEND and suspends)
    WorkflowTestHarness.Result resultB = harness.step();
    System.assertEquals('Suspended', resultB.status);

    // Firing sleep on ParallelSleepB (which is plain suspended, not sleeping) must throw HarnessException
    try {
      harness.fireSleep('WorkflowTestHarnessTest.ParallelSleepB');
      System.assert(
        false,
        'Expected fireSleep on ParallelSleepB to throw HarnessException'
      );
    } catch (WorkflowTestHarness.HarnessException ex) {
      System.assert(
        ex.getMessage().contains('is not currently sleeping'),
        'Actionable message expected: ' + ex.getMessage()
      );
    }

    // Firing sleep on ParallelSleepA (which is actually sleeping) must succeed and wait on the remaining branch B
    WorkflowTestHarness.Result awakeA = harness.fireSleep(
      'WorkflowTestHarnessTest.ParallelSleepA'
    );
    System.assertEquals('Suspended', awakeA.status);

    // Resuming B via signal must succeed and drive to completion
    WorkflowTestHarness.Result finalResult = harness.injectSignal(
      'ParallelSleepKey',
      'WorkflowTestHarnessTest.ParallelSleepB',
      null
    );
    Test.stopTest();

    System.assertEquals('Completed', finalResult.status);
  }
}
