/**
 * @description Subscriber fixture for the frozen global API (issue #122). This
 * class uses only the members in docs/global-api.md. The global-api test
 * compiles it in a foreign namespace against a stub that holds only the global
 * members. In the org, it starts a workflow, runs one async hop, and reads the
 * terminal state.
 */
@IsTest
public class GlobalApiSubscriberTest {
  private static final String WORKFLOW = 'GlobalApiSubscriberTest.SubscriberWorkflow';
  private static final String RESERVE_STEP = 'GlobalApiSubscriberTest.ReserveStep';
  private static final String CONFIRM_STEP = 'GlobalApiSubscriberTest.ConfirmStep';
  private static final String DECISION = 'Decision';

  /**
   * @description Two-step versioned definition: reserve, then confirm.
   */
  public class SubscriberWorkflow implements VersionedWorkflow {
    /**
     * @description Returns the step inventory.
     * @return The two step class names.
     */
    public List<String> getSteps() {
      return new List<String>{ RESERVE_STEP, CONFIRM_STEP };
    }

    /**
     * @description Returns the first step.
     * @return The reserve step name.
     */
    public String getInitialStep() {
      return RESERVE_STEP;
    }

    /**
     * @description Returns the latest version.
     * @return Version 1.
     */
    public Integer getLatestVersion() {
      return 1;
    }

    /**
     * @description Routes with the latest version.
     * @param currentStepName The step that completed.
     * @param result The result of that step.
     * @return The next step name, or null at the end.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return getNextStep(currentStepName, result, getLatestVersion());
    }

    /**
     * @description Uses the step's own route when it gives one. Else goes from
     * reserve to confirm, then ends.
     * @param currentStepName The step that completed.
     * @param result The result of that step.
     * @param version The pinned version.
     * @return The next step name, or null at the end.
     */
    public String getNextStep(
      String currentStepName,
      StepResult result,
      Integer version
    ) {
      String routed = result.directive().nextStepName;
      if (String.isNotBlank(routed)) {
        return routed;
      }
      return currentStepName == RESERVE_STEP ? CONFIRM_STEP : null;
    }
  }

  /**
   * @description Compensatable step with a timeout. Uses the context values and
   * the capture, log, and progress accessors.
   */
  public class ReserveStep implements CompensatableStep, TimeoutConfigurable {
    /**
     * @description Returns the step timeout.
     * @return 120 seconds.
     */
    public Integer getTimeoutSeconds() {
      return 120;
    }

    /**
     * @description Captures a token and completes with it.
     * @param ctx The step context.
     * @return A COMPLETE result.
     */
    public StepResult execute(StepContext ctx) {
      if (ctx.shouldYield()) {
        return StepResult.yield(ctx.stepStateJson);
      }
      Object token = ctx.captures().once('token', new TokenProducer());
      ctx.logger().log(StepContext.Level.INFO, 'Reserve ' + ctx.workflowName);
      ctx.progress().reportProgress(50, 'Reserved');
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'token' => token,
          'key' => ctx.idempotencyKey,
          'input' => ctx.workflowInputJson,
          'final' => ctx.isFinalAttempt()
        }
      );
    }

    /**
     * @description Undoes the reservation.
     * @param ctx The step context.
     * @return A COMPLETE result.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  /**
   * @description Capture-once producer.
   */
  public class TokenProducer implements CaptureProducer {
    /**
     * @description Returns the value to capture.
     * @return A fixed token.
     */
    public Object produce() {
      return 'token-1';
    }
  }

  /**
   * @description Waits for the decision signal, then completes with its payload.
   */
  public class ConfirmStep implements WorkflowStep, CalloutStep {
    /**
     * @description Suspends until the decision signal is present.
     * @param ctx The step context.
     * @return SUSPEND with no signal, else COMPLETE with the payload.
     */
    public StepResult execute(StepContext ctx) {
      StepContext.Signal decision = ctx.signals().getSignal(DECISION);
      if (!decision.isPresent()) {
        return StepResult.suspend();
      }
      return StepResult.complete(null, decision.payload);
    }
  }

  /**
   * @description Compile probe for the author members that the run tests do not
   * use. No workflow runs this step.
   */
  public class SurfaceStep implements WorkflowStep {
    /**
     * @description Reads each remaining author member.
     * @param ctx The step context.
     * @return A RETRY result.
     */
    public StepResult execute(StepContext ctx) {
      List<Object> seen = new List<Object>{
        ctx.workflowInstanceId,
        ctx.stepName,
        ctx.inputJson,
        ctx.previousStepOutput,
        ctx.workflowVersion,
        ctx.attempt,
        ctx.previousRunAt,
        ctx.retry().maxAttempts,
        ctx.retry().attemptCount,
        ctx.retry().failedStepName,
        ctx.retry().errorMessage,
        ctx.retry().isTimeoutResume(),
        ctx.signals().hasSignal(DECISION),
        ctx.signals().getSignals(DECISION),
        ctx.signals().signalReadWasCapped(),
        ctx.captures().patched('change-1'),
        ctx.captures().patched('change-2', Datetime.now())
      };
      for (StepContext.Signal s : ctx.signals().getSignals()) {
        seen.add(s.name + s.payload);
      }
      StepContext.ChildOutcome child = ctx.signals().getChildOutcome('child-1');
      seen.add(
        child.status +
          child.errorMessage +
          child.output +
          child.isSuccess() +
          child.isPresent()
      );
      seen.add(
        ctx.signals().getChildOutcomes(new List<String>{ 'child-1' }).size()
      );
      ctx.captures().deprecated('change-0');
      ctx.captures().deprecated('change-00', Datetime.now());
      ctx.logger()
        .log(
          StepContext.Level.WARN,
          'Seen',
          new Map<String, Object>{ 'count' => seen.size() }
        );
      seen.add(StepResult.sleep(1, 'Hours', 'Default'));
      ctx.progress().reportProgress(seen);
      ctx.events().emit(new Account(Name = 'probe'));
      return StepResult.retry(new RetryPolicy(1, 2.0, 3));
    }
  }

  @IsTest
  static void startSignalAndOneHopReachCompleted() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      WorkflowEngine.StartResult started = WorkflowEngine.startOrGet(
        new WorkflowEngine.StartRequest(
          WORKFLOW,
          'global-api-run',
          new Map<String, Object>{ 'sku' => 'A-1' }
        )
      );
      WorkflowEngine.signal(
        new WorkflowEngine.SignalRequest('global-api-run', DECISION, 'approved')
          .withIdempotencyKey('decision-1')
      );
      Test.stopTest();

      WorkflowEngine.WorkflowStatus status = WorkflowStatusRead.getStatus(
        started.instanceId
      );
      System.assert(started.isNew, 'The first start must make an instance');
      System.assertEquals('Completed', status.status, status.errorMessage);
      System.assert(status.isTerminal, 'Completed must be terminal');
      System.assertEquals('"approved"', status.output, 'Last step output');
    }
  }

  @IsTest
  static void waitsForSignalThenCancels() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowEngine.start(WORKFLOW, 'global-api-wait', null);
      Test.stopTest();

      WorkflowEngine.WorkflowStatus waiting = WorkflowStatusRead.getStatus(
        'global-api-wait'
      );
      System.assertEquals(instanceId, waiting.instanceId, 'Read by key');
      System.assert(!waiting.isTerminal, 'With no signal, the step must wait');

      WorkflowEngine.cancel(instanceId);
      WorkflowEngine.WorkflowStatus cancelled = WorkflowStatusRead.getStatus(
        instanceId
      );
      System.assertEquals('Cancelled', cancelled.status, 'Cancel is terminal');
      System.assert(cancelled.isTerminal, 'Cancelled must be terminal');
    }
  }

  @IsTest
  static void bulkAndOverloadEntryPointsAreReachable() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.StartRequest first = new WorkflowEngine.StartRequest(
          WORKFLOW,
          'global-api-bulk-1',
          null
        )
        .withAttributes(new Map<String, String>{ 'region' => 'emea' });
      WorkflowEngine.StartRequest second = new WorkflowEngine.StartRequest(
        WORKFLOW,
        'global-api-bulk-2',
        null
      );
      second.causationId = 'trace-122';
      List<WorkflowEngine.StartRequest> requests = new List<WorkflowEngine.StartRequest>{
        first,
        second
      };

      Test.startTest();
      List<Id> ids = WorkflowEngine.start(requests);
      List<WorkflowEngine.StartResult> again = WorkflowEngine.startOrGet(
        requests
      );
      WorkflowEngine.StartResult single = WorkflowEngine.startOrGet(
        WORKFLOW,
        'global-api-bulk-1',
        null
      );
      Id sameId = WorkflowEngine.start(
        new WorkflowEngine.StartRequest(WORKFLOW, 'global-api-bulk-2', null)
      );
      WorkflowEngine.signal('global-api-bulk-1', DECISION, 'yes');
      WorkflowEngine.signal(
        new List<WorkflowEngine.SignalRequest>{
          new WorkflowEngine.SignalRequest('global-api-bulk-2', DECISION, 'no')
            .withDedupKey('dedup-122')
        }
      );
      Test.stopTest();

      System.assertEquals(2, ids.size(), 'One Id for each request');
      System.assertEquals(ids[0], again[0].instanceId, 'Get returns the same');
      System.assertEquals(ids[1], again[1].instanceId, 'Get returns the same');
      System.assert(!again[0].isNew, 'A second start must not make one');
      System.assertEquals(ids[0], single.instanceId, 'Scalar get-or-start');
      System.assert(!single.isNew, 'A second start must not make one');
      System.assertEquals(ids[1], sameId, 'Request start deduplicates');

      List<WorkflowEngine.WorkflowStatus> byId = WorkflowStatusRead.getStatus(
        ids
      );
      List<WorkflowEngine.WorkflowStatus> byKey = WorkflowStatusRead.getStatus(
        new List<String>{ 'global-api-bulk-1', 'global-api-bulk-2' }
      );
      System.assertEquals(ids[0], byKey[0].instanceId, 'Bulk read by key');
      System.assertEquals(ids[1], byKey[1].instanceId, 'Bulk read by key');
      System.assertEquals(WORKFLOW, byId[0].definitionName, 'Definition');
      System.assertEquals('global-api-bulk-1', byId[0].correlationKey, 'Key');
      System.assertEquals('trace-122', byId[1].causationId, 'Causation');
    }
  }

  @IsTest
  static void flowActionsRunToCompleted() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStartInvocableAction.StartRequest start = new WorkflowStartInvocableAction.StartRequest();
      start.workflowName = WORKFLOW;
      start.correlationKey = 'global-api-flow';
      start.inputJson = '{"sku":"A-2"}';
      WorkflowSignalInvocableAction.SignalRequest signal = new WorkflowSignalInvocableAction.SignalRequest();
      signal.targetKey = 'global-api-flow';
      signal.signalName = DECISION;
      signal.payloadJson = 'flow';
      WorkflowStatusInvocableAction.StatusRequest read = new WorkflowStatusInvocableAction.StatusRequest();
      read.workflowKeyOrId = 'global-api-flow';

      Test.startTest();
      List<WorkflowStartInvocableAction.StartResult> started = WorkflowStartInvocableAction.startWorkflow(
        new List<WorkflowStartInvocableAction.StartRequest>{ start }
      );
      WorkflowSignalInvocableAction.signalWorkflow(
        new List<WorkflowSignalInvocableAction.SignalRequest>{ signal }
      );
      Test.stopTest();
      List<WorkflowStatusInvocableAction.StatusResult> statuses = WorkflowStatusInvocableAction.getStatus(
        new List<WorkflowStatusInvocableAction.StatusRequest>{ read }
      );

      System.assert(started[0].isValid, started[0].validationError);
      System.assert(started[0].isNew, 'The Flow start must make an instance');
      System.assert(statuses[0].found, 'The Flow read must find it');
      System.assertEquals(
        started[0].workflowInstanceId,
        statuses[0].workflowInstanceId,
        'Same instance'
      );
      System.assertEquals(
        'Completed',
        statuses[0].status,
        statuses[0].errorMessage
      );
      System.assert(statuses[0].isSuccess, 'Completed is a success');
    }
  }

  @IsTest
  static void resultFactoriesAndRetryPolicyAreReachable() {
    RetryPolicy policy = new RetryPolicy();
    policy.initialIntervalSeconds = 2;
    policy.backoffCoefficient = 1.5;
    policy.maximumAttempts = 4;
    List<StepResult> results = new List<StepResult>{
      StepResult.complete('Next', 'out'),
      StepResult.yield('{}'),
      StepResult.suspend(),
      StepResult.suspend(60, 'Timeout'),
      StepResult.retry(policy),
      StepResult.retry(RetryPolicy.fromConfig()),
      StepResult.sleep(5),
      StepResult.complete(null, null).withStepState('{}'),
      StepResult.startChild('Child', 'child-key', null),
      StepResult.startChildren(
        new List<StepResult.ChildRequest>{
          new StepResult.ChildRequest('Child', 'child-key', null)
        }
      ),
      StepResult.waitForApproval('approval', 'Manager')
        .withApprovalTimeout(60, 'Timeout'),
      StepResult.split(new List<String>{ 'A', 'B' }),
      StepResult.split(new List<String>{ 'A', 'B' }, 'in'),
      StepResult.continueAsNew('next'),
      StepResult.continueAsNew('next', 'next-key'),
      StepResult.fail('reason'),
      StepResult.fail('reason', new Map<String, Object>{ 'code' => 1 })
    };

    for (StepResult r : results) {
      System.assertNotEquals(null, r.directive(), 'Each result has data');
    }
    System.assertEquals('Next', results[0].directive().nextStepName, 'Route');
    System.assertEquals('"out"', results[0].directive().outputJson, 'Output');
    StepResult.ChildRequest child = new StepResult.ChildRequest(
      'Child',
      'child-key',
      'in'
    );
    System.assertEquals('Child', child.workflowName, 'Child name');
    System.assertEquals('child-key', child.correlationKey, 'Child key');
    System.assertEquals('"in"', child.inputJson, 'Child input');
    try {
      throw new WorkflowEngine.WorkflowException('probe');
    } catch (WorkflowEngine.WorkflowException e) {
      System.assertEquals('probe', e.getMessage(), 'Catchable engine error');
    }
  }
}
