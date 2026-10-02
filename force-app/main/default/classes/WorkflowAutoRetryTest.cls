/**
 * @description Tests for auto-retry of thrown step errors (issue #101).
 */
@IsTest
public class WorkflowAutoRetryTest {
  private static final String PREFIX = 'WorkflowAutoRetryTest.';
  private static final String RESERVE = PREFIX + 'ReserveStep';
  private static final String HOLD = PREFIX + 'HoldStep';
  private static final String CHARGE = PREFIX + 'ChargeStep';
  private static final String PROBE = PREFIX + 'ProbeStep';
  private static final String BLIP_MESSAGE = 'HTTP 503 from gateway';
  private static final String LOCK_MESSAGE = 'UNABLE_TO_LOCK_ROW: unable to obtain exclusive access to this record';
  private static final String CALLOUT_MESSAGE = 'You have uncommitted work pending. Please commit or rollback before calling out';

  /** @description Count of throws left for a throwing step. */
  public static Integer throwsLeft = 0;
  /** @description Message of the next thrown exception. */
  public static String throwMessage = BLIP_MESSAGE;
  /** @description True to throw a CalloutException, not a BlipException. */
  public static Boolean throwCallout = false;
  /** @description True to make ChargeStep read the compensation stack. */
  public static Boolean captureStacks = false;
  /** @description Count of execute() calls, by step name. */
  public static Map<String, Integer> runs = new Map<String, Integer>();
  /** @description Instance id that the test drives. */
  public static Id currentInstanceId;
  /** @description Compensation stacks that ChargeStep saw, in order. */
  public static List<String> stacksSeen = new List<String>();
  /** @description Max attempts that a step saw, in order. */
  public static List<Integer> maxAttemptsSeen = new List<Integer>();

  /** @description Transient error that a test step throws. */
  public class BlipException extends Exception {
  }

  private static void bump(String stepName) {
    runs.put(stepName, runsOf(stepName) + 1);
  }

  private static Integer runsOf(String stepName) {
    return runs.containsKey(stepName) ? runs.get(stepName) : 0;
  }

  private static void throwIfBlip() {
    if (throwsLeft > 0) {
      throwsLeft--;
      if (throwCallout) {
        throw new CalloutException(throwMessage);
      }
      throw new BlipException(throwMessage);
    }
  }

  private static void reset(Integer throwCount) {
    throwsLeft = throwCount;
    throwMessage = BLIP_MESSAGE;
    throwCallout = false;
    captureStacks = false;
    runs.clear();
    stacksSeen.clear();
    maxAttemptsSeen.clear();
  }

  // ---------------------------------------------------------------------------
  // Mock definitions
  // ---------------------------------------------------------------------------

  /** @description Linear definition. Steps run in list order. */
  public abstract class LinearDef implements WorkflowDefinition {
    /**
     * @description Returns the steps in run order.
     * @return The step names.
     */
    public abstract List<String> getSteps();

    /**
     * @description Returns the first step.
     * @return The first step name.
     */
    public String getInitialStep() {
      return getSteps()[0];
    }

    /**
     * @description Returns the step after the current step.
     * @param currentStepName The step that completed.
     * @param stepResult The result of that step.
     * @return The next step name, or null at the end.
     */
    public virtual String getNextStep(
      String currentStepName,
      StepResult stepResult
    ) {
      List<String> steps = getSteps();
      Integer idx = steps.indexOf(currentStepName);
      return (idx >= 0 && idx < steps.size() - 1) ? steps[idx + 1] : null;
    }
  }

  /** @description Linear definition with a definition-level auto-retry policy. */
  public abstract class PolicyDef extends LinearDef implements AutoRetryConfigurable {
    /**
     * @description Returns the maximum attempts of the policy.
     * @return The maximum attempts (default 5).
     */
    protected virtual Integer maxAttempts() {
      return 5;
    }

    /**
     * @description Returns the default policy for thrown exceptions.
     * @return The policy.
     */
    public RetryPolicy getAutoRetryPolicy() {
      return new RetryPolicy(1, (Double) 1.0, maxAttempts());
    }
  }

  /** @description Saga with a definition policy (3 attempts). */
  public class PolicySaga extends PolicyDef {
    /**
     * @description Returns the saga steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ RESERVE, HOLD, CHARGE };
    }

    /**
     * @description Returns 3 attempts.
     * @return 3.
     */
    protected override Integer maxAttempts() {
      return 3;
    }
  }

  /** @description Same saga with no auto-retry policy. */
  public class PlainSaga extends LinearDef {
    /**
     * @description Returns the saga steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ RESERVE, HOLD, CHARGE };
    }
  }

  /** @description No definition policy. The step has its own policy. */
  public class StepPolicyWorkflow extends LinearDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ PREFIX + 'StepPolicyStep' };
    }
  }

  /** @description Definition policy (5). The step policy (2) overrides it. */
  public class OverrideWorkflow extends PolicyDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ PREFIX + 'StepPolicyStep' };
    }
  }

  /** @description Definition policy (5). The step opts out with null. */
  public class OptOutWorkflow extends PolicyDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ PREFIX + 'OptOutStep' };
    }
  }

  /** @description Definition policy (5). The step returns fail(). */
  public class FailWorkflow extends PolicyDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ PREFIX + 'FailStep' };
    }
  }

  /** @description Definition policy (5). The step returns retry() with 2. */
  public class ExplicitRetryWorkflow extends PolicyDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ PREFIX + 'ExplicitRetryStep' };
    }
  }

  /** @description Definition policy (3) with one ProbeStep. */
  public class ProbeWorkflow extends PolicyDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ PROBE };
    }

    /**
     * @description Returns 3 attempts.
     * @return 3.
     */
    protected override Integer maxAttempts() {
      return 3;
    }
  }

  /** @description Definition policy (3). The step writes a record, then throws. */
  public class DmlWorkflow extends PolicyDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ PREFIX + 'DmlStep' };
    }

    /**
     * @description Returns 3 attempts.
     * @return 3.
     */
    protected override Integer maxAttempts() {
      return 3;
    }
  }

  /** @description No definition policy. The step has two policies. */
  public class DualWorkflow extends LinearDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ PREFIX + 'DualStep' };
    }
  }

  /** @description Definition policy (1). Splits into two parallel branches. */
  public class SplitWorkflow extends PolicyDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ PREFIX + 'SplitStep', PREFIX + 'OkStep', PROBE };
    }

    /**
     * @description Returns 1 attempt.
     * @return 1.
     */
    protected override Integer maxAttempts() {
      return 1;
    }

    /**
     * @description The branches end the workflow.
     * @param currentStepName The step that completed.
     * @param stepResult The result of that step.
     * @return Null.
     */
    public override String getNextStep(
      String currentStepName,
      StepResult stepResult
    ) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Mock steps
  // ---------------------------------------------------------------------------

  /** @description Compensatable step that always completes. */
  public class ReserveStep implements CompensatableStep {
    /**
     * @description Completes the step.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      bump(RESERVE);
      return StepResult.complete(null, 'reserved');
    }

    /**
     * @description Undoes the step.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, 'released');
    }
  }

  /** @description Second compensatable step that always completes. */
  public class HoldStep implements CompensatableStep {
    /**
     * @description Completes the step.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      bump(HOLD);
      return StepResult.complete(null, 'held');
    }

    /**
     * @description Undoes the step.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, 'unheld');
    }
  }

  /** @description Forward step. Throws while throwsLeft is more than 0. */
  public class ChargeStep implements WorkflowStep {
    /**
     * @description Reads the stack (when enabled), throws or completes.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      bump(CHARGE);
      if (captureStacks) {
        stacksSeen.add(
          [
            SELECT Compensation_Stack__c
            FROM Workflow_Instance__c
            WHERE Id = :currentInstanceId
          ]
          .Compensation_Stack__c
        );
      }
      throwIfBlip();
      return StepResult.complete(null, 'charged');
    }
  }

  /** @description Step with its own policy (2 attempts). */
  public class StepPolicyStep implements WorkflowStep, AutoRetryConfigurable {
    /**
     * @description Throws or completes.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      bump(PREFIX + 'StepPolicyStep');
      throwIfBlip();
      return StepResult.complete(null, 'done');
    }

    /**
     * @description Returns the step policy for thrown exceptions.
     * @return The policy.
     */
    public RetryPolicy getAutoRetryPolicy() {
      return new RetryPolicy(1, (Double) 1.0, 2);
    }
  }

  /** @description Step that opts out of the definition policy. */
  public class OptOutStep implements WorkflowStep, AutoRetryConfigurable {
    /**
     * @description Throws or completes.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      bump(PREFIX + 'OptOutStep');
      throwIfBlip();
      return StepResult.complete(null, 'done');
    }

    /**
     * @description Returns null to disable auto-retry for this step.
     * @return Null.
     */
    public RetryPolicy getAutoRetryPolicy() {
      return null;
    }
  }

  /** @description Step whose policy getter throws. */
  public class BrokenPolicyStep implements WorkflowStep, AutoRetryConfigurable {
    /**
     * @description Completes the step.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'done');
    }

    /**
     * @description Throws.
     * @return Nothing.
     */
    public RetryPolicy getAutoRetryPolicy() {
      throw new BlipException('broken getter');
    }
  }

  /** @description Step that implements the CalloutStep marker. */
  public class MarkedCalloutStep implements WorkflowStep, CalloutStep {
    /**
     * @description Completes the step.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'done');
    }
  }

  /** @description Step that returns an explicit fail(). */
  public class FailStep implements WorkflowStep {
    /**
     * @description Fails the step on purpose.
     * @param ctx The step context.
     * @return A fail result.
     */
    public StepResult execute(StepContext ctx) {
      bump(PREFIX + 'FailStep');
      return StepResult.fail('Order already refunded');
    }
  }

  /** @description Step that always returns retry() with 2 attempts. */
  public class ExplicitRetryStep implements WorkflowStep {
    /**
     * @description Requests a retry.
     * @param ctx The step context.
     * @return A retry result.
     */
    public StepResult execute(StepContext ctx) {
      bump(PREFIX + 'ExplicitRetryStep');
      return StepResult.retry(new RetryPolicy(1, (Double) 1.0, 2));
    }
  }

  /** @description Step that records max attempts, then throws or completes. */
  public class ProbeStep implements WorkflowStep {
    /**
     * @description Records the attempt data, throws or completes.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      bump(PROBE);
      maxAttemptsSeen.add(ctx.retry().maxAttempts);
      throwIfBlip();
      return StepResult.complete(null, 'probed');
    }
  }

  /** @description Step that writes a probe record, then throws or completes. */
  public class DmlStep implements WorkflowStep {
    /**
     * @description Inserts a probe log, throws or completes.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      bump(PREFIX + 'DmlStep');
      Database.insert(
        new Workflow_Log__c(Log_Type__c = 'Probe', Message__c = 'probe'),
        AccessLevel.SYSTEM_MODE
      );
      throwIfBlip();
      return StepResult.complete(null, 'written');
    }
  }

  /** @description Step with RetryConfigurable (5) and AutoRetryConfigurable (2). */
  public class DualStep implements WorkflowStep, RetryConfigurable, AutoRetryConfigurable {
    /**
     * @description Records max attempts, throws or completes.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      bump(PREFIX + 'DualStep');
      maxAttemptsSeen.add(ctx.retry().maxAttempts);
      throwIfBlip();
      return StepResult.complete(null, 'done');
    }

    /**
     * @description Returns the policy for a returned retry().
     * @return The policy (5 attempts).
     */
    public RetryPolicy getRetryPolicy() {
      return new RetryPolicy(1, (Double) 1.0, 5);
    }

    /**
     * @description Returns the policy for thrown exceptions.
     * @return The policy (2 attempts).
     */
    public RetryPolicy getAutoRetryPolicy() {
      return new RetryPolicy(1, (Double) 1.0, 2);
    }
  }

  /** @description Step that splits into OkStep and ProbeStep. */
  public class SplitStep implements WorkflowStep {
    /**
     * @description Splits into two parallel branches.
     * @param ctx The step context.
     * @return A split result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.split(new List<String>{ PREFIX + 'OkStep', PROBE });
    }
  }

  /** @description Parallel branch that always completes. */
  public class OkStep implements WorkflowStep {
    /**
     * @description Completes the step.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'ok');
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  private static User runAsUser() {
    return new User(Id = UserInfo.getUserId());
  }

  private static WorkflowTestHarness harnessFor(
    String workflowName,
    String key
  ) {
    currentInstanceId = WorkflowEngine.start(PREFIX + workflowName, key, null);
    return new WorkflowTestHarness(currentInstanceId);
  }

  private static WorkflowTestHarness.Result runWorkflow(
    String workflowName,
    String key
  ) {
    return harnessFor(workflowName, key).drive();
  }

  // Runs one step directly (no harness) and returns the exception it throws.
  private static Exception runStepDirect(String key, Object input) {
    WorkflowEngine.disableQueueableInTest = true;
    currentInstanceId = WorkflowEngine.start(
      PREFIX + 'ProbeWorkflow',
      key,
      input
    );
    try {
      WorkflowEngine.runStep(currentInstanceId);
    } catch (Exception ex) {
      return ex;
    }
    return null;
  }

  private static Workflow_Step_Execution__c latestExec(String stepName) {
    return [
      SELECT
        Status__c,
        Retry_Count__c,
        Transient_Retry_Count__c,
        Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :currentInstanceId
        AND Step_Name__c = :stepName
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
  }

  private static Integer retryCount(String stepName) {
    return latestExec(stepName).Retry_Count__c.intValue();
  }

  private static Integer execCount(String stepName) {
    return [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :currentInstanceId
        AND Step_Name__c = :stepName
    ];
  }

  private static List<Workflow_Log__c> logsOfType(String logType) {
    return [
      SELECT Message__c
      FROM Workflow_Log__c
      WHERE Log_Type__c = :logType
      ORDER BY CreatedDate ASC, Id ASC
    ];
  }

  private static Workflow_Instance__c loadInstance() {
    return [
      SELECT Status__c, Failure_Category__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :currentInstanceId
    ];
  }

  private static List<String> lifo() {
    return new List<String>{ HOLD + '_Compensate', RESERVE + '_Compensate' };
  }

  // ---------------------------------------------------------------------------
  // Engine tests
  // ---------------------------------------------------------------------------

  @IsTest
  static void transientThrowRetriesThenCompletesWithZeroCompensation() {
    System.runAs(runAsUser()) {
      reset(1);
      captureStacks = true;
      Test.startTest();
      WorkflowTestHarness.Result result = runWorkflow('PolicySaga', 'AR_1');
      Test.stopTest();

      Assert.areEqual('Completed', result.status, 'Blip must not fail saga');
      Assert.isTrue(
        result.compensatedSteps.isEmpty(),
        'No compensation may run after a recovered blip'
      );
      Assert.areEqual(2, runsOf(CHARGE), 'Charge runs twice: throw, pass');
      Assert.areEqual(1, runsOf(RESERVE), 'Earlier steps do not run again');
      Assert.areEqual(
        'Completed',
        latestExec(CHARGE).Status__c,
        'Charge row completes'
      );
      Assert.areEqual(1, retryCount(CHARGE), 'One auto-retry is counted');
      Assert.areEqual(1, execCount(CHARGE), 'Retry reuses the same row');
      Assert.areEqual(
        new List<String>{
          JSON.serialize(new List<String>{ RESERVE, HOLD }),
          JSON.serialize(new List<String>{ RESERVE, HOLD })
        },
        stacksSeen,
        'Retry path must not change the compensation stack'
      );
      List<Workflow_Log__c> logs = logsOfType('AutoRetry');
      Assert.areEqual(1, logs.size(), 'One log for the retried attempt');
      Assert.isTrue(
        logs[0].Message__c.contains('attempt 1 of 3 failed: ' + BLIP_MESSAGE),
        'Log shows the attempt and the message: ' + logs[0].Message__c
      );
    }
  }

  @IsTest
  static void exhaustedPolicyFailsOnceThenCompensatesLifo() {
    System.runAs(runAsUser()) {
      reset(99);
      Test.startTest();
      WorkflowTestHarness.Result result = runWorkflow('PolicySaga', 'AR_2');
      Test.stopTest();

      Assert.areEqual('Compensated', result.status, 'Saga compensates at end');
      Assert.areEqual(lifo(), result.compensatedSteps, 'Compensation is LIFO');
      Assert.areEqual(3, runsOf(CHARGE), 'Charge runs maximumAttempts times');
      Workflow_Step_Execution__c chargeExec = latestExec(CHARGE);
      Assert.areEqual('Failed', chargeExec.Status__c, 'Charge row fails');
      Assert.areEqual(3, retryCount(CHARGE), 'Retry count equals attempts');
      Assert.areEqual(1, execCount(CHARGE), 'Terminal failure is written once');
      Assert.isTrue(
        chargeExec.Error_Details__c.startsWith(
          'Auto-retry exhausted after 3 attempts: ' + BLIP_MESSAGE
        ),
        'Details show auto-retry exhaustion: ' + chargeExec.Error_Details__c
      );
      Assert.isTrue(
        chargeExec.Error_Details__c.contains(
          'WorkflowAutoRetryTest.ChargeStep'
        ),
        'Details keep the original stack trace: ' + chargeExec.Error_Details__c
      );
      Assert.isTrue(
        loadInstance().Error_Message__c.contains('Auto-retry exhausted'),
        'Instance error shows auto-retry exhaustion'
      );
    }
  }

  @IsTest
  static void noPolicyFailsFastAndCompensatesAsToday() {
    System.runAs(runAsUser()) {
      reset(1);
      Test.startTest();
      WorkflowTestHarness.Result result = runWorkflow('PlainSaga', 'AR_3');
      Test.stopTest();

      Assert.areEqual('Compensated', result.status, 'No policy: fail fast');
      Assert.areEqual(lifo(), result.compensatedSteps, 'Compensation is LIFO');
      Assert.areEqual(1, runsOf(CHARGE), 'No auto-retry without a policy');
      Workflow_Step_Execution__c chargeExec = latestExec(CHARGE);
      Assert.areEqual('Failed', chargeExec.Status__c, 'Charge row fails');
      Assert.areEqual(0, retryCount(CHARGE), 'No retry is counted');
      Assert.isTrue(
        chargeExec.Error_Details__c.startsWith(BLIP_MESSAGE),
        'Crash details keep the message: ' + chargeExec.Error_Details__c
      );
      Assert.isFalse(
        chargeExec.Error_Details__c.contains('Auto-retry'),
        'Fail-fast is not labeled as auto-retry'
      );
      Assert.isTrue(
        loadInstance().Error_Message__c.contains('Transaction crashed'),
        'Instance error is the crash message'
      );
      Assert.isTrue(logsOfType('AutoRetry').isEmpty(), 'No auto-retry log');
    }
  }

  @IsTest
  static void stepPolicyWithoutStackExhaustsWithRetriesExhaustedCategory() {
    System.runAs(runAsUser()) {
      reset(99);
      Test.startTest();
      WorkflowTestHarness.Result result = runWorkflow(
        'StepPolicyWorkflow',
        'AR_4'
      );
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'Step policy exhausts');
      Assert.areEqual(
        2,
        runsOf(PREFIX + 'StepPolicyStep'),
        'Step policy allows 2 attempts'
      );
      Workflow_Instance__c inst = loadInstance();
      Assert.areEqual(
        WorkflowEngine.CAT_RETRIES_EXHAUSTED,
        inst.Failure_Category__c,
        'Category is RETRIES_EXHAUSTED'
      );
      Assert.isTrue(
        inst.Error_Message__c.contains(
          'Auto-retry exhausted after 2 attempts: ' + BLIP_MESSAGE
        ),
        'Instance error shows attempts and message: ' + inst.Error_Message__c
      );
    }
  }

  @IsTest
  static void stepPolicyOverridesDefinitionPolicy() {
    System.runAs(runAsUser()) {
      reset(99);
      Test.startTest();
      WorkflowTestHarness.Result result = runWorkflow(
        'OverrideWorkflow',
        'AR_5'
      );
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'Step policy exhausts');
      Assert.areEqual(
        2,
        runsOf(PREFIX + 'StepPolicyStep'),
        'Step policy (2) wins over definition policy (5)'
      );
    }
  }

  @IsTest
  static void noPolicyWithoutStackFailsWithStepExceptionCategory() {
    System.runAs(runAsUser()) {
      reset(0);
      Test.startTest();
      WorkflowTestHarness harness = harnessFor('PlainSaga', 'AR_6');
      harness.failStep(RESERVE, BLIP_MESSAGE);
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'First step fails fast');
      Assert.areEqual(
        WorkflowEngine.CAT_STEP_EXCEPTION,
        loadInstance().Failure_Category__c,
        'Fail-fast keeps the STEP_EXCEPTION category'
      );
    }
  }

  @IsTest
  static void stepNullPolicyOptsOutOfDefinitionPolicy() {
    System.runAs(runAsUser()) {
      reset(1);
      Test.startTest();
      WorkflowTestHarness.Result result = runWorkflow('OptOutWorkflow', 'AR_7');
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'Opted-out step fails fast');
      Assert.areEqual(
        1,
        runsOf(PREFIX + 'OptOutStep'),
        'A null step policy disables auto-retry'
      );
      Assert.areEqual(
        WorkflowEngine.CAT_STEP_EXCEPTION,
        loadInstance().Failure_Category__c,
        'Fail-fast keeps the STEP_EXCEPTION category'
      );
    }
  }

  @IsTest
  static void explicitFailOverridesDefaultPolicy() {
    System.runAs(runAsUser()) {
      reset(0);
      Test.startTest();
      WorkflowTestHarness.Result result = runWorkflow('FailWorkflow', 'AR_8');
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'fail() stops the workflow');
      Assert.areEqual(1, runsOf(PREFIX + 'FailStep'), 'fail() is not retried');
      Assert.areEqual(
        WorkflowEngine.CAT_EXPLICIT_FAIL,
        loadInstance().Failure_Category__c,
        'Category is EXPLICIT_FAIL'
      );
      Assert.areEqual(0, retryCount(PREFIX + 'FailStep'), 'No retry counted');
    }
  }

  @IsTest
  static void explicitRetryOverridesDefaultPolicy() {
    System.runAs(runAsUser()) {
      reset(0);
      Test.startTest();
      WorkflowTestHarness.Result result = runWorkflow(
        'ExplicitRetryWorkflow',
        'AR_9'
      );
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'retry() policy exhausts');
      Assert.areEqual(
        2,
        runsOf(PREFIX + 'ExplicitRetryStep'),
        'retry() policy (2) wins over default policy (5)'
      );
      Assert.areEqual(
        'Max retries (2) exceeded.',
        latestExec(PREFIX + 'ExplicitRetryStep').Error_Details__c,
        'Explicit retry keeps the standard message'
      );
    }
  }

  @IsTest
  static void injectedBlipWithPolicyCompletes() {
    System.runAs(runAsUser()) {
      reset(0);
      Test.startTest();
      WorkflowTestHarness harness = harnessFor('PolicySaga', 'AR_10');
      harness.failStepOnce(CHARGE, BLIP_MESSAGE);
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      Assert.areEqual('Completed', result.status, 'Injected blip is retried');
      Assert.isTrue(
        result.compensatedSteps.isEmpty(),
        'Zero compensation after an injected blip'
      );
    }
  }

  @IsTest
  static void injectedBlipWithoutPolicyCompensates() {
    System.runAs(runAsUser()) {
      reset(0);
      Test.startTest();
      WorkflowTestHarness harness = harnessFor('PlainSaga', 'AR_11');
      harness.failStepOnce(CHARGE, BLIP_MESSAGE);
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      Assert.areEqual('Compensated', result.status, 'No policy: fail fast');
      Assert.areEqual(lifo(), result.compensatedSteps, 'Compensation is LIFO');
    }
  }

  @IsTest
  static void firstAttemptSeesAutoPolicyMaxAttempts() {
    System.runAs(runAsUser()) {
      reset(1);
      Test.startTest();
      WorkflowTestHarness.Result result = runWorkflow('ProbeWorkflow', 'AR_12');
      Test.stopTest();

      Assert.areEqual('Completed', result.status, 'Probe completes');
      Assert.areEqual(
        new List<Integer>{ 3, 3 },
        maxAttemptsSeen,
        'ctx.retry().maxAttempts shows the auto policy on each attempt'
      );
    }
  }

  @IsTest
  static void retriedAttemptSeesPolicyThatRetriedIt() {
    System.runAs(runAsUser()) {
      reset(99);
      Test.startTest();
      WorkflowTestHarness.Result result = runWorkflow('DualWorkflow', 'AR_13');
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'Auto policy (2) exhausts');
      Assert.areEqual(
        new List<Integer>{ 5, 2 },
        maxAttemptsSeen,
        'After an auto-retry, maxAttempts is the auto policy value'
      );
    }
  }

  @IsTest
  static void savepointUndoesStepDmlBeforeTheThrow() {
    System.runAs(runAsUser()) {
      reset(1);
      Test.startTest();
      WorkflowTestHarness.Result result = runWorkflow('DmlWorkflow', 'AR_14');
      Test.stopTest();

      Assert.areEqual('Completed', result.status, 'Step completes on retry');
      Assert.areEqual(2, runsOf(PREFIX + 'DmlStep'), 'Step runs twice');
      Assert.areEqual(
        1,
        logsOfType('Probe').size(),
        'DML from the failed attempt is rolled back'
      );
    }
  }

  @IsTest
  static void calloutBlockedBySavepointFailsFastWithGuidance() {
    System.runAs(runAsUser()) {
      reset(99);
      throwCallout = true;
      throwMessage = CALLOUT_MESSAGE;
      Test.startTest();
      WorkflowTestHarness.Result result = runWorkflow('ProbeWorkflow', 'AR_15');
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'Conflict fails fast');
      Assert.areEqual(1, runsOf(PROBE), 'Conflict is not retried');
      Workflow_Instance__c inst = loadInstance();
      Assert.areEqual(
        WorkflowEngine.CAT_STEP_EXCEPTION,
        inst.Failure_Category__c,
        'Conflict uses the crash path'
      );
      Assert.isTrue(
        inst.Error_Message__c.contains('must implement CalloutStep'),
        'Error tells the author what to do: ' + inst.Error_Message__c
      );
    }
  }

  @IsTest
  static void parallelBranchExhaustionNamesTheBranch() {
    System.runAs(runAsUser()) {
      reset(99);
      Test.startTest();
      WorkflowTestHarness.Result result = runWorkflow('SplitWorkflow', 'AR_16');
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'Branch exhausts at once');
      String errorMessage = loadInstance().Error_Message__c;
      Assert.isTrue(
        errorMessage.startsWith(
          'Failed at step ' + PROBE + ': Auto-retry exhausted'
        ),
        'Error names the branch, not the branch list: ' + errorMessage
      );
    }
  }

  @IsTest
  static void rowLockErrorKeepsTransientLockPath() {
    System.runAs(runAsUser()) {
      reset(1);
      throwMessage = LOCK_MESSAGE;
      Exception thrown = runStepDirect('AR_17', null);

      Assert.isNotNull(thrown, 'Row-lock error is not converted to a retry');
      Assert.areEqual(0, retryCount(PROBE), 'Business retry budget is unused');
      WorkflowEngine.handleCrash(currentInstanceId, PROBE, thrown);
      Assert.areEqual(
        1,
        latestExec(PROBE).Transient_Retry_Count__c.intValue(),
        'The transient lock path handles the error'
      );
      Assert.areEqual(
        'Suspended',
        loadInstance().Status__c,
        'Instance waits for the transient retry'
      );
    }
  }

  @IsTest
  static void timeoutFallbackRunDoesNotAutoRetry() {
    System.runAs(runAsUser()) {
      reset(1);
      Exception thrown = runStepDirect(
        'AR_18',
        new Map<String, Object>{ '$timeoutResume' => true }
      );

      Assert.isNotNull(thrown, 'Timeout fallback run fails fast');
      Assert.areEqual(1, runsOf(PROBE), 'Step runs once');
      Assert.areEqual(
        new List<Integer>{ 1 },
        maxAttemptsSeen,
        'Fallback run does not see the auto policy'
      );
      Assert.areEqual(0, retryCount(PROBE), 'No retry is counted');
      Assert.isTrue(logsOfType('AutoRetry').isEmpty(), 'No auto-retry log');
    }
  }

  @IsTest
  static void timeoutFallbackRunIgnoresOverrideCap() {
    System.runAs(runAsUser()) {
      reset(1);
      // Issue #103: an override record must not make the fallback non-final.
      WorkflowRetryConfigResolver.mockRecords = new List<Workflow_Retry_Config__mdt>{
        new Workflow_Retry_Config__mdt(
          DeveloperName = 'ProbeOverride',
          Workflow_Definition__c = PREFIX + 'ProbeWorkflow',
          Maximum_Attempts__c = 4,
          Override_Author_Policy__c = true
        )
      };
      runStepDirect(
        'AR_18b',
        new Map<String, Object>{ '$timeoutResume' => true }
      );

      Assert.areEqual(
        new List<Integer>{ 1 },
        maxAttemptsSeen,
        'Fallback run stays final with an override record'
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Unit tests: WorkflowAutoRetry
  // ---------------------------------------------------------------------------

  private static Workflow_Instance__c instanceFor(String workflowName) {
    return new Workflow_Instance__c(Workflow_Name__c = PREFIX + workflowName);
  }

  @IsTest
  static void resolvePolicyPrefersStepPolicy() {
    RetryPolicy policy = WorkflowAutoRetry.resolvePolicy(
      instanceFor('OverrideWorkflow'),
      new StepPolicyStep()
    );
    Assert.areEqual(2, policy.maximumAttempts, 'Step policy wins');
  }

  @IsTest
  static void resolvePolicyFallsBackToDefinitionPolicy() {
    RetryPolicy policy = WorkflowAutoRetry.resolvePolicy(
      instanceFor('PolicySaga'),
      new ChargeStep()
    );
    Assert.areEqual(3, policy.maximumAttempts, 'Definition policy applies');
  }

  @IsTest
  static void resolvePolicyReturnsNullWithoutUsablePolicy() {
    Assert.isNull(
      WorkflowAutoRetry.resolvePolicy(
        instanceFor('PlainSaga'),
        new ChargeStep()
      ),
      'No declaration means no policy'
    );
    Assert.isNull(
      WorkflowAutoRetry.resolvePolicy(
        instanceFor('OptOutWorkflow'),
        new OptOutStep()
      ),
      'A null step policy wins over the definition policy'
    );
    Assert.isNull(
      WorkflowAutoRetry.resolvePolicy(
        instanceFor('PolicySaga'),
        new BrokenPolicyStep()
      ),
      'A getter that throws means no policy'
    );
    Assert.isNull(
      WorkflowAutoRetry.resolvePolicy(
        new Workflow_Instance__c(Workflow_Name__c = 'No_Such_Workflow_Xyz'),
        new ChargeStep()
      ),
      'An unknown definition means no policy'
    );
    Assert.isNull(
      WorkflowAutoRetry.resolvePolicy(
        instanceFor('ChargeStep'),
        new ChargeStep()
      ),
      'A name that is not a definition means no policy'
    );
  }

  @IsTest
  static void rollbackAndExclusionRules() {
    Assert.isTrue(
      WorkflowAutoRetry.canRollBack(new ChargeStep()),
      'A plain step gets a savepoint'
    );
    Assert.isFalse(
      WorkflowAutoRetry.canRollBack(new MarkedCalloutStep()),
      'A CalloutStep gets no savepoint'
    );
    Assert.isTrue(
      WorkflowAutoRetry.isExcluded(new BlipException(LOCK_MESSAGE)),
      'A row-lock error is excluded'
    );
    Assert.isFalse(
      WorkflowAutoRetry.isExcluded(new BlipException(BLIP_MESSAGE)),
      'A blip is not excluded'
    );
    Assert.isTrue(
      WorkflowAutoRetry.isCalloutConflict(
        new CalloutException(CALLOUT_MESSAGE)
      ),
      'Uncommitted-work callout error is a conflict'
    );
    Assert.isFalse(
      WorkflowAutoRetry.isCalloutConflict(new BlipException(CALLOUT_MESSAGE)),
      'Only a CalloutException is a conflict'
    );
  }

  @IsTest
  static void exhaustedTextsKeepMessageAndStack() {
    Exception caught;
    try {
      throw new BlipException(BLIP_MESSAGE);
    } catch (BlipException ex) {
      caught = ex;
    }
    Assert.areEqual(
      'Auto-retry exhausted after 4 attempts: ' + BLIP_MESSAGE,
      WorkflowAutoRetry.exhaustedMessage(4, caught),
      'Message has the prefix, count and original message'
    );
    String details = WorkflowAutoRetry.exhaustedDetails(3, 4, caught);
    Assert.isTrue(
      details.startsWith(WorkflowAutoRetry.exhaustedMessage(4, caught) + '\n'),
      'Details start with the message'
    );
    Assert.isTrue(
      details.contains('WorkflowAutoRetryTest'),
      'Details keep the stack trace: ' + details
    );
    Assert.isTrue(
      WorkflowAutoRetry.exhaustedMessage(1, new BlipException())
        .contains('BlipException'),
      'A blank message falls back to the type name'
    );
  }

  @IsTest
  static void exhaustedTextsForReturnedRetryAreUnchanged() {
    Assert.areEqual(
      'Max retries exceeded.',
      WorkflowAutoRetry.exhaustedMessage(4, null),
      'Returned retry() keeps the standard message'
    );
    Assert.areEqual(
      'Max retries (3) exceeded.',
      WorkflowAutoRetry.exhaustedDetails(3, 4, null),
      'Returned retry() keeps the standard details'
    );
  }
}
