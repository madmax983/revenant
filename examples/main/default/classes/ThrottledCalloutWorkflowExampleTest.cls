/**
 * @description Tests for ThrottledCalloutWorkflowExample (#106). An empty
 * bucket or an HTTP 429 makes a durable sleep, not a failure. The callout
 * keeps one effect across a sleep and a resume.
 */
@IsTest
public class ThrottledCalloutWorkflowExampleTest {
  private static final String WF = 'ThrottledCalloutWorkflowExample.ThrottledCalloutWorkflow';
  private static final String ACQUIRE = 'ThrottledCalloutWorkflowExample.AcquireTokenStep';
  private static final String CALLOUT = 'ThrottledCalloutWorkflowExample.ThrottledCalloutStep';
  private static final String SAGA = 'ThrottledCalloutWorkflowExampleTest.GuardedSaga';
  private static final String RESERVE = 'ThrottledCalloutWorkflowExampleTest.ReserveStep';
  private static final String KEY = ThrottledCalloutWorkflowExample.INTEGRATION_KEY;

  /** @description Number of ReserveStep.compensate() calls. */
  public static Integer compensations = 0;

  // ─── fixtures ───────────────────────────────────────────────────────────

  // Sets a bucket that refills 1 token in 1000 s, and the fake API.
  private static void useBucket(Integer capacity) {
    RateLimiter.mockConfigs.put(
      KEY,
      (Rate_Limit_Config__mdt) JSON.deserialize(
        '{"DeveloperName":"' +
          KEY +
          '","Capacity__c":' +
          capacity +
          ',"Refill_Rate_Per_Second__c":0.001}',
        Rate_Limit_Config__mdt.class
      )
    );
    MockThrottledApi.reset();
    compensations = 0;
  }

  // Makes the bucket empty now.
  private static void drainBucket() {
    insert as system new Rate_Limit_State__c(
      Integration_Key__c = KEY,
      Tokens_Remaining__c = 0,
      Last_Refill_Time_Ms__c = System.currentTimeMillis()
    );
  }

  // Moves the refill clock back 2000 s. The bucket gets a token.
  private static void refillBucket() {
    Rate_Limit_State__c state = [
      SELECT Id, Last_Refill_Time_Ms__c
      FROM Rate_Limit_State__c
      WHERE Integration_Key__c = :KEY
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    state.Last_Refill_Time_Ms__c = state.Last_Refill_Time_Ms__c - 2000000;
    update as system state;
  }

  private static Workflow_Instance__c instance(Id instanceId) {
    return [
      SELECT Status__c, Current_Step__c, Sleep_Until__c, Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
    ];
  }

  private static Integer failedRows(Id instanceId) {
    return [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Failed'
      WITH SYSTEM_MODE
    ];
  }

  // Callout context whose first HTTP 429 was the given seconds ago.
  private static StepContext firstThrottleSecondsAgo(Integer seconds) {
    Long firstMs = System.currentTimeMillis() - seconds * 1000L;
    return new StepContextTestBuilder()
      .stepName(CALLOUT)
      .once(
        ThrottledCalloutWorkflowExample.FIRST_THROTTLE_KEY,
        String.valueOf(firstMs)
      )
      .build();
  }

  private static StepContext context(String stepName) {
    return new StepContextTestBuilder().stepName(stepName).build();
  }

  private static StepResult.StepDirective callout(StepContext ctx) {
    return new ThrottledCalloutWorkflowExample.ThrottledCalloutStep()
      .execute(ctx)
      .directive();
  }

  // Formats an HTTP-date, for example "Mon, 05 Oct 2026 07:28:00 GMT".
  // The weekday is not checked by the parser.
  private static String httpDate(Datetime dt) {
    List<String> months = new List<String>{
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    };
    return 'Mon, ' +
      String.valueOf(dt.dayGmt()).leftPad(2, '0') +
      ' ' +
      months[dt.monthGmt() - 1] +
      ' ' +
      dt.yearGmt() +
      ' ' +
      String.valueOf(dt.hourGmt()).leftPad(2, '0') +
      ':' +
      String.valueOf(dt.minuteGmt()).leftPad(2, '0') +
      ':' +
      String.valueOf(dt.secondGmt()).leftPad(2, '0') +
      ' GMT';
  }

  // ─── harness tests (engine sleep and resume) ────────────────────────────

  @IsTest
  static void emptyBucketSleepsThenCompletesAfterRefill() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      useBucket(1);
      drainBucket();
      Test.startTest();
      Id instanceId = WorkflowEngine.start(WF, 'Throttle-Bucket', null);
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      harness.disableAutoTimeSkip = true;
      WorkflowTestHarness.Result parked = harness.drive();

      Assert.areEqual('Suspended', parked.status, 'Empty bucket suspends');
      Assert.isTrue(parked.isSleeping, 'Empty bucket sleeps');
      Assert.isFalse(parked.reachedStep(CALLOUT), 'No callout step yet');
      Assert.areEqual(0, MockThrottledApi.calls, 'No call yet');
      Workflow_Instance__c inst = instance(instanceId);
      Assert.areEqual(ACQUIRE, inst.Current_Step__c, 'Parked on acquire');
      Assert.isNotNull(inst.Sleep_Until__c, 'Sleep sets the wake marker');
      Assert.isTrue(
        inst.Sleep_Until__c > Datetime.now(),
        'Wake marker is in the future'
      );

      refillBucket();
      harness.disableAutoTimeSkip = false;
      WorkflowTestHarness.Result done = harness.drive();
      Test.stopTest();

      Assert.areEqual('Completed', done.status, 'Resumes and completes');
      Assert.isTrue(done.reachedStep(CALLOUT), 'Callout runs after refill');
      Assert.isTrue(done.compensatedSteps.isEmpty(), 'No rollback');
      Assert.areEqual(0, failedRows(instanceId), 'No failed step row');
      Assert.areEqual(1, MockThrottledApi.effects, 'One effect');
    }
  }

  @IsTest
  static void throttleNeverRollsBackTheSaga() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      useBucket(1);
      drainBucket();
      Test.startTest();
      Id instanceId = WorkflowEngine.start(SAGA, 'Throttle-Saga', null);
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      harness.disableAutoTimeSkip = true;
      WorkflowTestHarness.Result parked = harness.drive();

      Assert.isTrue(parked.isSleeping, 'Throttle sleeps inside the saga');
      Workflow_Instance__c inst = instance(instanceId);
      List<String> stack = (List<String>) JSON.deserialize(
        inst.Compensation_Stack__c,
        List<String>.class
      );
      Assert.isTrue(stack.contains(RESERVE), 'Stack holds the reserve step');
      Assert.areEqual(0, compensations, 'Throttle does not compensate');

      refillBucket();
      harness.disableAutoTimeSkip = false;
      WorkflowTestHarness.Result done = harness.drive();
      Test.stopTest();

      Assert.areEqual('Completed', done.status, 'Saga completes');
      Assert.isTrue(done.compensatedSteps.isEmpty(), 'No step compensated');
      Assert.areEqual(0, compensations, 'compensate() never runs');
      Assert.areEqual(0, failedRows(instanceId), 'No failed step row');
    }
  }

  @IsTest
  static void remoteThrottleKeepsOneEffectAcrossSleepResume() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      useBucket(5);
      MockThrottledApi.queue(429, '5');
      Test.startTest();
      Id instanceId = WorkflowEngine.start(WF, 'Throttle-429', null);
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      harness.disableAutoTimeSkip = true;
      WorkflowTestHarness.Result parked = harness.drive();

      Assert.isTrue(parked.isSleeping, 'HTTP 429 sleeps');
      Assert.areEqual(
        CALLOUT,
        instance(instanceId).Current_Step__c,
        'Parked on the callout step'
      );
      Assert.areEqual(1, MockThrottledApi.calls, 'One call before the sleep');
      Assert.areEqual(0, MockThrottledApi.effects, '429 applies no effect');
      String firstKey = MockThrottledApi.lastRequest.getHeader(
        'Idempotency-Key'
      );
      Assert.isTrue(String.isNotBlank(firstKey), 'Key is sent');

      WorkflowTestHarness.Result done = harness.fireSleep(CALLOUT);
      Test.stopTest();

      Assert.areEqual('Completed', done.status, 'Resumes and completes');
      Assert.areEqual(2, MockThrottledApi.calls, 'Step runs again on resume');
      Assert.areEqual(1, MockThrottledApi.effects, 'One effect');
      Assert.areEqual(
        firstKey,
        MockThrottledApi.lastRequest.getHeader('Idempotency-Key'),
        'Resume sends the same key'
      );
      Assert.isTrue(done.compensatedSteps.isEmpty(), 'No rollback');
    }
  }

  @IsTest
  static void retryBetweenThrottlesKeepsTheKeyAndTheDeadline() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      useBucket(5);
      MockThrottledApi.queue(429, '5');
      MockThrottledApi.queue(503, null);
      MockThrottledApi.queue(429, '5');
      Test.startTest();
      Id instanceId = WorkflowEngine.start(WF, 'Throttle-Retry', null);
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      harness.disableAutoTimeSkip = true;

      Assert.isTrue(harness.drive().isSleeping, '429 sleeps');
      Assert.isTrue(harness.fireSleep(CALLOUT).isAwaitingRetry, '503 retries');
      Assert.isTrue(
        [
            SELECT Captured_Values__c
            FROM Workflow_Step_Execution__c
            WHERE Workflow_Instance__c = :instanceId AND Step_Name__c = :CALLOUT
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
          ]
          .Captured_Values__c.contains(
            ThrottledCalloutWorkflowExample.FIRST_THROTTLE_KEY
          ),
        'The retry keeps the time of the first 429'
      );
      Assert.isTrue(harness.fireRetry(CALLOUT).isSleeping, '429 sleeps again');
      WorkflowTestHarness.Result done = harness.fireSleep(CALLOUT);
      Test.stopTest();

      Assert.areEqual('Completed', done.status, 'Completes after 4 calls');
      Assert.areEqual(4, MockThrottledApi.calls, 'Four calls');
      Assert.areEqual(1, MockThrottledApi.effects, 'One effect');
      Assert.areEqual(1, MockThrottledApi.sentKeys.size(), 'One key');
      Assert.isTrue(done.compensatedSteps.isEmpty(), 'No rollback');
    }
  }

  // ─── step unit tests (StepContextTestBuilder) ───────────────────────────

  @IsTest
  static void acquireStepSleepsWhenBucketIsEmpty() {
    useBucket(1);
    drainBucket();
    StepResult.StepDirective d = new ThrottledCalloutWorkflowExample.AcquireTokenStep()
      .execute(context(ACQUIRE))
      .directive();
    Assert.areEqual(StepResult.ActionType.SLEEP, d.action, 'Sleeps, no throw');
    Assert.isTrue(d.sleepDurationSeconds > 0, 'Sleep time is positive');
  }

  @IsTest
  static void acquireStepRoutesToCalloutWhenTokenIsFree() {
    useBucket(1);
    StepResult.StepDirective d = new ThrottledCalloutWorkflowExample.AcquireTokenStep()
      .execute(context(ACQUIRE))
      .directive();
    Assert.areEqual(StepResult.ActionType.COMPLETE, d.action, 'Token taken');
    Assert.areEqual(
      CALLOUT,
      new ThrottledCalloutWorkflowExample.ThrottledCalloutWorkflow()
        .getNextStep(ACQUIRE, null),
      'getNextStep() routes to the callout step'
    );
  }

  @IsTest
  static void calloutSendsIdempotencyKeyHeader() {
    MockThrottledApi.reset();
    StepContext ctx = context(CALLOUT);
    StepResult.StepDirective d = callout(ctx);
    HttpRequest req = MockThrottledApi.lastRequest;
    Assert.areEqual(StepResult.ActionType.COMPLETE, d.action, '200 completes');
    Assert.areEqual('POST', req.getMethod(), 'Method is POST');
    Assert.areEqual(
      ThrottledCalloutWorkflowExample.ENDPOINT,
      req.getEndpoint(),
      'Endpoint is the constant'
    );
    Assert.areEqual(
      ctx.idempotencyKey,
      req.getHeader('Idempotency-Key'),
      'Header carries ctx.idempotencyKey'
    );
  }

  @IsTest
  static void calloutRerunKeepsOneEffect() {
    MockThrottledApi.reset();
    StepContext first = context(CALLOUT);
    StepContext rerun = new StepContextTestBuilder()
      .workflowInstanceId(first.workflowInstanceId)
      .stepName(CALLOUT)
      .build();
    callout(first);
    callout(rerun);
    Assert.areEqual(2, MockThrottledApi.calls, 'Two calls');
    Assert.areEqual(1, MockThrottledApi.effects, 'One effect');
  }

  @IsTest
  static void tooManyRequestsSleepsForRetryAfter() {
    MockThrottledApi.reset();
    MockThrottledApi.queue(429, '7');
    StepResult.StepDirective d = callout(context(CALLOUT));
    Assert.areEqual(StepResult.ActionType.SLEEP, d.action, '429 sleeps');
    Assert.areEqual(7, d.sleepDurationSeconds, 'Uses Retry-After');
    Assert.areEqual(0, MockThrottledApi.effects, 'No effect');
  }

  @IsTest
  static void badRetryAfterUsesDefaultOrCap() {
    MockThrottledApi.reset();
    Integer fallback = ThrottledCalloutWorkflowExample.DEFAULT_RETRY_AFTER_SECONDS;
    Map<String, Integer> expected = new Map<String, Integer>{
      null => fallback,
      'soon' => fallback,
      '-3' => fallback,
      '0' => fallback,
      '1.5' => fallback,
      '9999999999' => ThrottledCalloutWorkflowExample.MAX_RETRY_AFTER_SECONDS,
      '99999' => ThrottledCalloutWorkflowExample.MAX_RETRY_AFTER_SECONDS,
      '0000000005' => 5,
      '0000000000' => fallback,
      'Sun, 06 Nov 1994 08:49:37 GMT' => fallback,
      'Wed, 21 Oct 2099 07:28:00 GMT' => ThrottledCalloutWorkflowExample.MAX_RETRY_AFTER_SECONDS,
      'Wed, 21 Foo 2099 07:28:00 GMT' => fallback,
      'Wed, 21 Oct 2099 07:28 GMT' => fallback,
      'Wed, xx Oct 2099 07:28:00 GMT' => fallback
    };
    for (String raw : expected.keySet()) {
      MockThrottledApi.queue(429, raw);
      StepResult.StepDirective d = callout(context(CALLOUT));
      Assert.areEqual(StepResult.ActionType.SLEEP, d.action, raw);
      Assert.areEqual(expected.get(raw), d.sleepDurationSeconds, raw);
    }
  }

  @IsTest
  static void httpDateRetryAfterSleepsUntilThatTime() {
    MockThrottledApi.reset();
    MockThrottledApi.queue(429, httpDate(Datetime.now().addSeconds(120)));
    StepResult.StepDirective d = callout(context(CALLOUT));
    Assert.areEqual(StepResult.ActionType.SLEEP, d.action, '429 sleeps');
    Assert.isTrue(
      d.sleepDurationSeconds >= 110 && d.sleepDurationSeconds <= 121,
      'Sleeps until the HTTP-date: ' + d.sleepDurationSeconds
    );
  }

  @IsTest
  static void tooManyRequestsBeforeTheDeadlineSleeps() {
    MockThrottledApi.reset();
    MockThrottledApi.queue(429, '7');
    StepResult.StepDirective d = callout(firstThrottleSecondsAgo(60));
    Assert.areEqual(StepResult.ActionType.SLEEP, d.action, '429 sleeps');
  }

  @IsTest
  static void tooManyRequestsAfterTheDeadlineFailsTheStep() {
    MockThrottledApi.reset();
    MockThrottledApi.queue(429, '7');
    StepResult.StepDirective d = callout(
      firstThrottleSecondsAgo(
        ThrottledCalloutWorkflowExample.MAX_REMOTE_THROTTLE_SECONDS + 60
      )
    );
    Assert.areEqual(StepResult.ActionType.FAIL, d.action, 'Deadline stops it');
    Assert.isTrue(d.failureReason.contains('429'), d.failureReason);
  }

  @IsTest
  static void unknownResultRetriesWithTheSameKey() {
    MockThrottledApi.reset();
    StepContext ctx = context(CALLOUT);
    for (Integer code : new List<Integer>{ 408, 409, 500, 503 }) {
      MockThrottledApi.queue(code, null);
      StepResult.StepDirective d = callout(ctx);
      Assert.areEqual(StepResult.ActionType.RETRY, d.action, 'HTTP ' + code);
      Assert.areEqual(
        4,
        d.retry.policy.maximumAttempts,
        'Uses the step retry policy'
      );
      Assert.areEqual(
        ctx.idempotencyKey,
        MockThrottledApi.lastRequest.getHeader('Idempotency-Key'),
        'Each retry sends the same key'
      );
    }
    Assert.areEqual(0, MockThrottledApi.effects, 'No effect yet');
  }

  @IsTest
  static void clientErrorFailsTheStep() {
    MockThrottledApi.reset();
    MockThrottledApi.queue(400, null);
    StepResult.StepDirective d = callout(context(CALLOUT));
    Assert.areEqual(StepResult.ActionType.FAIL, d.action, 'HTTP 400 fails');
    Assert.isTrue(d.failureReason.contains('400'), d.failureReason);
  }

  @IsTest
  static void thrownCalloutExceptionHasAnAutoRetryPolicy() {
    RetryPolicy policy = new ThrottledCalloutWorkflowExample.ThrottledCalloutStep()
      .getAutoRetryPolicy();
    Assert.isNotNull(policy, 'A timeout retries, it does not fail the saga');
    Assert.areEqual(4, policy.maximumAttempts, 'Four attempts');
  }

  @IsTest
  static void httpTransportSendsTheRequest() {
    MockThrottledApi.reset();
    ThrottledCalloutWorkflowExample.transport = new ThrottledCalloutWorkflowExample.HttpTransport();
    Test.setMock(HttpCalloutMock.class, new MockThrottledApi());
    StepContext ctx = context(CALLOUT);
    StepResult.StepDirective d = callout(ctx);
    Assert.areEqual(StepResult.ActionType.COMPLETE, d.action, '200 completes');
    Assert.areEqual(1, MockThrottledApi.calls, 'Http.send reached the mock');
    Assert.areEqual(
      ctx.idempotencyKey,
      MockThrottledApi.lastRequest.getHeader('Idempotency-Key'),
      'Real request carries the key'
    );
  }

  @IsTest
  static void bucketAdmitsCapacityThenSleepsTheRest() {
    useBucket(3);
    Integer allowed = 0;
    Integer slept = 0;
    for (Integer i = 0; i < 20; i++) {
      StepResult.ActionType action = new ThrottledCalloutWorkflowExample.AcquireTokenStep()
        .execute(context(ACQUIRE))
        .directive()
        .action;
      if (action == StepResult.ActionType.COMPLETE) {
        allowed++;
      } else if (action == StepResult.ActionType.SLEEP) {
        slept++;
      }
    }
    Assert.areEqual(3, allowed, 'Calls stay at the bucket capacity');
    Assert.areEqual(17, slept, 'All other instances sleep; none fail');
  }

  // ─── test-only saga ─────────────────────────────────────────────────────

  /**
   * @description Saga: a compensatable step, then the two example steps.
   */
  public class GuardedSaga implements WorkflowDefinition {
    /**
     * @description Lists the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ RESERVE, ACQUIRE, CALLOUT };
    }

    /**
     * @description Names the first step.
     * @return The reserve step.
     */
    public String getInitialStep() {
      return RESERVE;
    }

    /**
     * @description Names the next step.
     * @param currentStepName The step that completed.
     * @param result The result of that step.
     * @return The next step, or null at the end.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == RESERVE) {
        return ACQUIRE;
      }
      if (currentStepName == ACQUIRE) {
        return CALLOUT;
      }
      return null;
    }
  }

  /**
   * @description Compensatable step. It counts compensate() calls.
   */
  public class ReserveStep implements CompensatableStep {
    /**
     * @description Completes the reserve.
     * @param ctx The step context.
     * @return A COMPLETE result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'reserved' => true }
      );
    }

    /**
     * @description Counts the call and completes.
     * @param ctx The step context.
     * @return A COMPLETE result.
     */
    public StepResult compensate(StepContext ctx) {
      ThrottledCalloutWorkflowExampleTest.compensations++;
      return StepResult.complete(null, null);
    }
  }
}
