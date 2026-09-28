/**
 * @description Engine tests for the Workflow_Retry_Config__mdt override
 * (issue #103). The tests drive real retry outcomes with WorkflowTestHarness.
 * They set WorkflowRetryConfigResolver.mockRecords, so org records have no
 * effect.
 */
@IsTest
public class WorkflowRetryConfigTest {
  private static final String PREFIX = 'WorkflowRetryConfigTest.';
  private static final String FIRST = PREFIX + 'FirstStep';
  private static final String PLAIN = PREFIX + 'PlainRetryStep';
  private static final String AUTHOR = PREFIX + 'AuthorRetryStep';
  private static final String CONFIGURED = PREFIX + 'ConfiguredStep';
  private static final String MANAGED = PREFIX + 'ConfigManagedStep';
  private static final String THROWING = PREFIX + 'ThrowingStep';
  private static final String DUAL = PREFIX + 'DualPolicyStep';
  private static final String RESERVE = PREFIX + 'ReserveStep';
  private static final String BREAK_STEP = PREFIX + 'BreakStep';

  /** @description Count of execute() calls, by step name. */
  public static Map<String, Integer> runs = new Map<String, Integer>();
  /** @description Max attempts that a final-attempt step saw, in order. */
  public static List<Integer> maxAttemptsSeen = new List<Integer>();

  /** @description Transient error that ThrowingStep throws. */
  public class PartnerDownException extends Exception {
  }

  private static void bump(String stepName) {
    runs.put(
      stepName,
      (runs.containsKey(stepName) ? runs.get(stepName) : 0) + 1
    );
  }

  // ---------------------------------------------------------------------------
  // Mock definitions and steps
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
    public String getNextStep(String currentStepName, StepResult stepResult) {
      List<String> steps = getSteps();
      Integer idx = steps.indexOf(currentStepName);
      return (idx >= 0 && idx < steps.size() - 1) ? steps[idx + 1] : null;
    }
  }

  /** @description First step completes. The next step uses fromConfig(). */
  public class PlainWorkflow extends LinearDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ FIRST, PLAIN };
    }
  }

  /** @description One step that calls retry(policy) with 5 attempts. */
  public class AuthorWorkflow extends LinearDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ AUTHOR };
    }
  }

  /** @description One RetryConfigurable step that reads isFinalAttempt(). */
  public class ConfiguredWorkflow extends LinearDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ CONFIGURED };
    }
  }

  /** @description One step that throws, with a fromConfig() auto-retry policy. */
  public class ThrowingWorkflow extends LinearDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ THROWING };
    }
  }

  /** @description One step with an author retry policy and a fromConfig() auto policy. */
  public class DualWorkflow extends LinearDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ DUAL };
    }
  }

  /** @description One RetryConfigurable step that returns fromConfig(). */
  public class ManagedWorkflow extends LinearDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ MANAGED };
    }
  }

  /** @description Saga. The second step fails. The rollback uses fromConfig(). */
  public class SagaWorkflow extends LinearDef {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public override List<String> getSteps() {
      return new List<String>{ RESERVE, BREAK_STEP };
    }
  }

  /** @description Completes at once. */
  public class FirstStep implements WorkflowStep {
    /**
     * @description Completes the step.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      bump(FIRST);
      return StepResult.complete(null, 'first-done');
    }
  }

  /** @description Always retries with no author policy. */
  public class PlainRetryStep implements WorkflowStep {
    /**
     * @description Requests a retry with no author policy.
     * @param ctx The step context.
     * @return A retry result.
     */
    public StepResult execute(StepContext ctx) {
      bump(PLAIN);
      return StepResult.retry(RetryPolicy.fromConfig());
    }
  }

  /** @description Always calls retry(policy) with 5 attempts. */
  public class AuthorRetryStep implements WorkflowStep {
    /**
     * @description Requests a retry with an author policy.
     * @param ctx The step context.
     * @return A retry result.
     */
    public StepResult execute(StepContext ctx) {
      bump(AUTHOR);
      return StepResult.retry(new RetryPolicy(1, (Double) 1.0, 5));
    }
  }

  /** @description Retries until the final attempt, then fails cleanly. */
  public class ConfiguredStep implements WorkflowStep, RetryConfigurable {
    /**
     * @description Returns the author policy: 5 attempts.
     * @return The policy.
     */
    public RetryPolicy getRetryPolicy() {
      return new RetryPolicy(1, (Double) 1.0, 5);
    }

    /**
     * @description Fails on the final attempt, else retries.
     * @param ctx The step context.
     * @return A fail or retry result.
     */
    public StepResult execute(StepContext ctx) {
      bump(CONFIGURED);
      maxAttemptsSeen.add(ctx.retry().maxAttempts);
      if (ctx.isFinalAttempt()) {
        return StepResult.fail('Gave up on the final attempt');
      }
      return StepResult.retry(getRetryPolicy());
    }
  }

  /** @description Operator-managed policy. Fails cleanly on the final attempt. */
  public class ConfigManagedStep implements WorkflowStep, RetryConfigurable {
    /**
     * @description Returns the operator-managed policy.
     * @return RetryPolicy.fromConfig().
     */
    public RetryPolicy getRetryPolicy() {
      return RetryPolicy.fromConfig();
    }

    /**
     * @description Fails on the final attempt, else retries.
     * @param ctx The step context.
     * @return A fail or retry result.
     */
    public StepResult execute(StepContext ctx) {
      bump(MANAGED);
      maxAttemptsSeen.add(ctx.retry().maxAttempts);
      if (ctx.isFinalAttempt()) {
        return StepResult.fail('Gave up on the final attempt');
      }
      return StepResult.retry(getRetryPolicy());
    }
  }

  /** @description Always throws. The operator record sets the auto-retry cap. */
  public class ThrowingStep implements WorkflowStep, AutoRetryConfigurable {
    /**
     * @description Returns the operator-managed auto-retry policy.
     * @return RetryPolicy.fromConfig().
     */
    public RetryPolicy getAutoRetryPolicy() {
      return RetryPolicy.fromConfig();
    }

    /**
     * @description Records the cap it sees, then throws.
     * @param ctx The step context.
     * @return Never returns.
     */
    public StepResult execute(StepContext ctx) {
      bump(THROWING);
      maxAttemptsSeen.add(ctx.retry().maxAttempts);
      throw new PartnerDownException('HTTP 503 from partner');
    }
  }

  /** @description Author cap 5 for retry(). Operator cap for thrown errors. */
  public class DualPolicyStep implements WorkflowStep, RetryConfigurable, AutoRetryConfigurable {
    /**
     * @description Returns the author policy for a returned retry.
     * @return A policy with 5 attempts.
     */
    public RetryPolicy getRetryPolicy() {
      return new RetryPolicy(1, (Double) 1.0, 5);
    }

    /**
     * @description Returns the operator-managed auto-retry policy.
     * @return RetryPolicy.fromConfig().
     */
    public RetryPolicy getAutoRetryPolicy() {
      return RetryPolicy.fromConfig();
    }

    /**
     * @description Records the cap it sees, then throws.
     * @param ctx The step context.
     * @return Never returns.
     */
    public StepResult execute(StepContext ctx) {
      bump(DUAL);
      maxAttemptsSeen.add(ctx.retry().maxAttempts);
      throw new PartnerDownException('HTTP 503 from partner');
    }
  }

  /** @description Completes. Its rollback always retries with no author policy. */
  public class ReserveStep implements CompensatableStep {
    /**
     * @description Completes the step.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }

    /**
     * @description Requests a rollback retry with no author policy.
     * @param ctx The step context.
     * @return A retry result.
     */
    public StepResult compensate(StepContext ctx) {
      bump(RESERVE + '_Compensate');
      return StepResult.retry(RetryPolicy.fromConfig());
    }
  }

  /** @description Fails at once, so the saga rolls back. */
  public class BreakStep implements WorkflowStep {
    /**
     * @description Fails the step.
     * @param ctx The step context.
     * @return A fail result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('boom');
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  // Record for a workflow of this class. policy is [interval, backoff,
  // attempts]; null keeps a field blank.
  private static Workflow_Retry_Config__mdt rec(
    String workflowClass,
    String stepName,
    List<Decimal> policy
  ) {
    return new Workflow_Retry_Config__mdt(
      DeveloperName = 'R' + Math.abs(Crypto.getRandomInteger()),
      Workflow_Definition__c = PREFIX + workflowClass,
      Step_Name__c = stepName,
      Initial_Interval_Seconds__c = policy[0],
      Backoff_Coefficient__c = policy[1],
      Maximum_Attempts__c = policy[2],
      Override_Author_Policy__c = false
    );
  }

  private static Workflow_Retry_Config__mdt overriding(
    Workflow_Retry_Config__mdt record
  ) {
    record.Override_Author_Policy__c = true;
    return record;
  }

  private static void useRecords(List<Workflow_Retry_Config__mdt> records) {
    WorkflowRetryConfigResolver.mockRecords = records;
  }

  private static void reset() {
    runs.clear();
    maxAttemptsSeen.clear();
    useRecords(new List<Workflow_Retry_Config__mdt>());
  }

  private static Id start(String workflowClass, String key) {
    return WorkflowEngine.start(PREFIX + workflowClass, key, null);
  }

  private static Workflow_Step_Execution__c stepRow(String stepName) {
    return [
      SELECT Id, Status__c, Retry_Count__c, Output__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE Step_Name__c = :stepName
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
  }

  private static Workflow_Instance__c instanceRow(Id instanceId) {
    return [
      SELECT Status__c, Failure_Category__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
  }

  private static Long secondsUntil(Datetime target) {
    return (target.getTime() - Datetime.now().getTime()) / 1000;
  }

  // ---------------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------------

  @IsTest
  static void noRecordKeepsEngineDefaultOfFiveAttempts() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      reset();
      Test.startTest();
      Id instanceId = start('PlainWorkflow', 'RetryCfg_Default');
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'Retries run out');
      Assert.areEqual(5, runs.get(PLAIN), 'Engine default is 5 attempts');
      Assert.areEqual(
        WorkflowEngine.CAT_RETRIES_EXHAUSTED,
        instanceRow(instanceId).Failure_Category__c,
        'Category is RETRIES_EXHAUSTED'
      );
    }
  }

  @IsTest
  static void definitionRecordCapsRetryWithoutAuthorPolicy() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      reset();
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('PlainWorkflow', null, new List<Decimal>{ 1, 1.0, 2 })
        }
      );
      Test.startTest();
      Id instanceId = start('PlainWorkflow', 'RetryCfg_Def');
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'Retries run out');
      Assert.areEqual(2, runs.get(PLAIN), 'Definition record sets 2');
      Assert.areEqual(2, stepRow(PLAIN).Retry_Count__c, 'Two attempts count');
    }
  }

  @IsTest
  static void stepRecordWinsOverDefinitionRecord() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      reset();
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('PlainWorkflow', null, new List<Decimal>{ 1, 1.0, 4 }),
          rec('PlainWorkflow', PLAIN, new List<Decimal>{ 1, 1.0, 3 })
        }
      );
      Test.startTest();
      Id instanceId = start('PlainWorkflow', 'RetryCfg_Step');
      new WorkflowTestHarness(instanceId).drive();
      Test.stopTest();

      Assert.areEqual(3, runs.get(PLAIN), 'Step record sets 3');
    }
  }

  @IsTest
  static void recordWithoutOverrideKeepsAuthorPolicy() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      reset();
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('AuthorWorkflow', null, new List<Decimal>{ 1, 1.0, 2 })
        }
      );
      Test.startTest();
      Id instanceId = start('AuthorWorkflow', 'RetryCfg_Author');
      new WorkflowTestHarness(instanceId).drive();
      Test.stopTest();

      Assert.areEqual(5, runs.get(AUTHOR), 'Author policy (5) wins');
    }
  }

  @IsTest
  static void overrideRecordWinsOverAuthorPolicy() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      reset();
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          overriding(
            rec('AuthorWorkflow', null, new List<Decimal>{ null, null, 2 })
          )
        }
      );
      Test.startTest();
      Id instanceId = start('AuthorWorkflow', 'RetryCfg_Override');
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'Retries run out');
      Assert.areEqual(2, runs.get(AUTHOR), 'Override record sets 2');
    }
  }

  @IsTest
  static void recordSetsBackoffDelay() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      reset();
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('PlainWorkflow', PLAIN, new List<Decimal>{ 60, 3.0, 5 })
        }
      );
      Test.startTest();
      Id instanceId = start('PlainWorkflow', 'RetryCfg_Backoff');
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      harness.disableAutoTimeSkip = true;
      WorkflowTestHarness.Result first = harness.drive();
      Long firstDelay = secondsUntil(instanceRow(instanceId).Sleep_Until__c);
      WorkflowTestHarness.Result second = harness.fireRetry(PLAIN);
      Long secondDelay = secondsUntil(instanceRow(instanceId).Sleep_Until__c);

      Assert.isTrue(first.isAwaitingRetry, 'First retry is parked');
      Assert.isTrue(second.isAwaitingRetry, 'Second retry is parked');
      Assert.isTrue(
        firstDelay >= 50 && firstDelay <= 60,
        'First delay is the 60 s interval: ' + firstDelay
      );
      Assert.isTrue(
        secondDelay >= 170 && secondDelay <= 180,
        'Second delay is 60 s x 3.0: ' + secondDelay
      );
      Test.stopTest();
    }
  }

  @IsTest
  static void configManagedAutoRetryContextSeesRecordChange() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      reset();
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('ThrowingWorkflow', null, new List<Decimal>{ 1, 1.0, 5 })
        }
      );
      Test.startTest();
      Id instanceId = start('ThrowingWorkflow', 'RetryCfg_AutoLive');
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      harness.disableAutoTimeSkip = true;
      harness.drive();

      // The operator lowers the cap. The persisted cap (5) is now stale.
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('ThrowingWorkflow', null, new List<Decimal>{ 1, 1.0, 2 })
        }
      );
      WorkflowTestHarness.Result result = harness.fireRetry(THROWING);
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'New cap applies');
      Assert.areEqual(
        new List<Integer>{ 5, 2 },
        maxAttemptsSeen,
        'Context shows the new record value, not the persisted cap'
      );
    }
  }

  @IsTest
  static void dualPolicyStepSeesOperatorAutoCapAfterThrow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      reset();
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('DualWorkflow', null, new List<Decimal>{ 1, 1.0, 2 })
        }
      );
      Test.startTest();
      Id instanceId = start('DualWorkflow', 'RetryCfg_Dual');
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      Assert.areEqual('Failed', result.status, 'Operator auto cap (2) applies');
      Assert.areEqual(2, runs.get(DUAL), 'Step runs 2 times');
      Assert.areEqual(
        new List<Integer>{ 5, 2 },
        maxAttemptsSeen,
        'After a throw, the context shows the refreshed auto cap'
      );
    }
  }

  @IsTest
  static void hugeBackoffCapsDelayAtOneDay() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      reset();
      // 86400 x 99999 is more than the Integer maximum.
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('PlainWorkflow', PLAIN, new List<Decimal>{ 86400, 99999, 5 })
        }
      );
      Test.startTest();
      Id instanceId = start('PlainWorkflow', 'RetryCfg_Huge');
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      harness.disableAutoTimeSkip = true;
      harness.drive();
      WorkflowTestHarness.Result second = harness.fireRetry(PLAIN);
      Long secondDelay = secondsUntil(instanceRow(instanceId).Sleep_Until__c);

      Assert.isTrue(second.isAwaitingRetry, 'Second retry is parked');
      Assert.isTrue(
        secondDelay >= 86390 && secondDelay <= 86400,
        'Delay is capped at one day: ' + secondDelay
      );
      Test.stopTest();
    }
  }

  @IsTest
  static void recordChangeAppliesToNextAttemptWithoutOldRowChange() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      reset();
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('PlainWorkflow', null, new List<Decimal>{ 1, 1.0, 5 })
        }
      );
      Test.startTest();
      Id instanceId = start('PlainWorkflow', 'RetryCfg_Live');
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      harness.disableAutoTimeSkip = true;
      WorkflowTestHarness.Result parked = harness.drive();
      Workflow_Step_Execution__c firstBefore = stepRow(FIRST);

      // Incident: the operator lowers the cap in Setup.
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('PlainWorkflow', null, new List<Decimal>{ 1, 1.0, 2 })
        }
      );
      WorkflowTestHarness.Result result = harness.fireRetry(PLAIN);
      Test.stopTest();

      Assert.isTrue(parked.isAwaitingRetry, 'Attempt 1 parks for a retry');
      Assert.areEqual('Failed', result.status, 'New cap applies at once');
      Assert.areEqual(2, runs.get(PLAIN), 'Only one more attempt runs');
      Assert.areEqual(
        WorkflowEngine.CAT_RETRIES_EXHAUSTED,
        instanceRow(instanceId).Failure_Category__c,
        'Category is RETRIES_EXHAUSTED'
      );
      Workflow_Step_Execution__c firstAfter = stepRow(FIRST);
      Assert.areEqual(firstBefore, firstAfter, 'Old step row does not change');
      Assert.areEqual(
        2,
        [
          SELECT COUNT()
          FROM Workflow_Step_Execution__c
          WHERE Workflow_Instance__c = :instanceId
        ],
        'No new step row: the retry reuses its row'
      );
    }
  }

  @IsTest
  static void overrideShowsInIsFinalAttempt() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      reset();
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          overriding(
            rec(
              'ConfiguredWorkflow',
              CONFIGURED,
              new List<Decimal>{ null, null, 2 }
            )
          )
        }
      );
      Test.startTest();
      Id instanceId = start('ConfiguredWorkflow', 'RetryCfg_Final');
      new WorkflowTestHarness(instanceId).drive();
      Test.stopTest();

      Assert.areEqual(2, runs.get(CONFIGURED), 'Step runs 2 times');
      Assert.areEqual(
        new List<Integer>{ 2, 2 },
        maxAttemptsSeen,
        'ctx.retry().maxAttempts shows the override'
      );
      Assert.areEqual(
        WorkflowEngine.CAT_EXPLICIT_FAIL,
        instanceRow(instanceId).Failure_Category__c,
        'Step sees its final attempt and fails cleanly'
      );
    }
  }

  @IsTest
  static void withoutOverrideIsFinalAttemptKeepsAuthorPolicy() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      reset();
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec(
            'ConfiguredWorkflow',
            CONFIGURED,
            new List<Decimal>{ null, null, 2 }
          )
        }
      );
      Test.startTest();
      Id instanceId = start('ConfiguredWorkflow', 'RetryCfg_NoOvr');
      new WorkflowTestHarness(instanceId).drive();
      Test.stopTest();

      Assert.areEqual(5, runs.get(CONFIGURED), 'Author policy (5) wins');
      Assert.areEqual(5, maxAttemptsSeen[0], 'Context shows author policy');
    }
  }

  @IsTest
  static void fromConfigPolicyShowsRecordInContextAndEngine() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      reset();
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('ManagedWorkflow', null, new List<Decimal>{ 1, 1.0, 3 })
        }
      );
      Test.startTest();
      Id instanceId = start('ManagedWorkflow', 'RetryCfg_Managed');
      new WorkflowTestHarness(instanceId).drive();
      Test.stopTest();

      Assert.areEqual(3, runs.get(MANAGED), 'Record sets 3 attempts');
      Assert.areEqual(
        new List<Integer>{ 3, 3, 3 },
        maxAttemptsSeen,
        'Context shows the record from attempt 1'
      );
      Assert.areEqual(
        WorkflowEngine.CAT_EXPLICIT_FAIL,
        instanceRow(instanceId).Failure_Category__c,
        'Step sees its final attempt and fails cleanly'
      );
    }
  }

  @IsTest
  static void compensationRetryUsesStepRecord() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      reset();
      String compStep = RESERVE + '_Compensate';
      useRecords(
        new List<Workflow_Retry_Config__mdt>{
          rec('SagaWorkflow', compStep, new List<Decimal>{ 1, 1.0, 2 })
        }
      );
      Test.startTest();
      Id instanceId = start('SagaWorkflow', 'RetryCfg_Comp');
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      Assert.areEqual(
        'CompensationFailed',
        result.status,
        'Rollback retries run out'
      );
      Assert.areEqual(2, runs.get(compStep), 'Step record sets 2');
      Assert.areEqual(2, stepRow(compStep).Retry_Count__c, 'Two attempts');
    }
  }
}
