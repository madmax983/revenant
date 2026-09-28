/**
 * @description Engine tests for approver notifications (issue #123). The SUSPEND
 * publishes one NOTIFY event and one anchor row. The event trigger sends the
 * notification. Tests seed the type Id: a test cannot always query
 * CustomNotificationType. Test context captures each send.
 *
 * Public: Type.forName must resolve the inner fixture classes.
 */
@IsTest
public class WorkflowNotifierTest {
  private static final String WF = 'WorkflowNotifierTest.NotifyWorkflow';
  private static final String WAIT_STEP = 'WorkflowNotifierTest.WaitStep';
  // Any valid Id. Test context does not call send().
  private static final Id FAKE_TYPE_ID = UserInfo.getOrganizationId();
  private static final Id OTHER_TYPE_ID = UserInfo.getProfileId();

  // Recipients of one send call in WorkflowNotifier.
  private static final Integer SEND_CHUNK = 500;

  /** @description Executions of WaitStep in this test. */
  public static Integer waitExecutions = 0;

  // ----- Fixtures

  /** @description One wait step that the input configures. */
  public class NotifyWorkflow implements WorkflowDefinition {
    /**
     * @description Steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ WAIT_STEP, 'WorkflowNotifierTest.TimeoutStep' };
    }
    /**
     * @description Initial step.
     * @return WaitStep.
     */
    public String getInitialStep() {
      return WAIT_STEP;
    }
    /**
     * @description Ends after one step.
     * @param currentStep Current step.
     * @param result Result.
     * @return Null.
     */
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  /**
   * @description Waits for 'Go' (suspend) or 'Approve:Gate' (approval). The
   * workflow input sets the notification.
   */
  public class WaitStep implements WorkflowStep {
    /**
     * @description Suspends with a notification until the signal arrives.
     * @param ctx Step context.
     * @return A wait result, or COMPLETE when the signal is present.
     */
    public StepResult execute(StepContext ctx) {
      waitExecutions++;
      if (
        ctx.signals().getSignal('Go').isPresent() ||
        ctx.signals().getSignal('Approve:Gate').isPresent()
      ) {
        return StepResult.complete(null, 'done');
      }
      Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.workflowInputJson
      );
      if ((Boolean) input.get('none') == true) {
        return StepResult.suspend();
      }
      return waitResult(input).withNotification(notification(input));
    }
  }

  /** @description Timeout route of the timed suspend. */
  public class TimeoutStep implements WorkflowStep {
    /**
     * @description Completes.
     * @param ctx Step context.
     * @return COMPLETE.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'timedOut');
    }
  }

  public static StepResult waitResult(Map<String, Object> input) {
    if ((Boolean) input.get('approval') == true) {
      return StepResult.waitForApproval('Gate', null);
    }
    if ((Boolean) input.get('timed') == true) {
      return StepResult.suspend(3600, 'WorkflowNotifierTest.TimeoutStep');
    }
    return StepResult.suspend();
  }

  public static WorkflowNotification notification(Map<String, Object> input) {
    WorkflowNotification n = WorkflowNotification.create(
      'Approve order',
      'Order needs your decision'
    );
    if (input.containsKey('recipient')) {
      n.toRecipient(Id.valueOf((String) input.get('recipient')));
    }
    if (input.containsKey('inputField')) {
      n.toInputKey((String) input.get('inputField'));
    }
    if (input.containsKey('ownerOf')) {
      n.toRecordOwner(Id.valueOf((String) input.get('ownerOf')));
    }
    if (input.containsKey('target')) {
      n.withTarget(Id.valueOf((String) input.get('target')));
    }
    if (input.containsKey('type')) {
      n.withNotificationType((String) input.get('type'));
    }
    return n;
  }

  // ----- Helpers

  private static void seedType() {
    WorkflowNotifier.typeIds.put(
      WorkflowNotification.DEFAULT_TYPE,
      FAKE_TYPE_ID
    );
  }

  private static Id startWorkflow(String key, Map<String, Object> input) {
    return WorkflowEngine.start(WF, key, input);
  }

  private static WorkflowTestHarness.Result driveAndDeliver(
    WorkflowTestHarness harness
  ) {
    WorkflowTestHarness.Result r = harness.drive();
    Test.getEventBus().deliver();
    return r;
  }

  private static Workflow_Step_Execution__c waitStepRow(Id instanceId) {
    return [
      SELECT Id, Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Step_Name__c = :WAIT_STEP
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
  }

  private static List<Workflow_Log__c> anchors(Id instanceId) {
    return [
      SELECT Fire_Key__c, Outcome__c, Level__c, Message__c, Workflow_Name__c
      FROM Workflow_Log__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Log_Type__c = :WorkflowNotifier.LOG_TYPE
      WITH SYSTEM_MODE
    ];
  }

  private static String userId() {
    return String.valueOf(UserInfo.getUserId());
  }

  // ----- Suspend surface

  @IsTest
  static void suspendRequestsOneNotification() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-suspend',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowTestHarness.Result r = driveAndDeliver(
      new WorkflowTestHarness(instanceId)
    );
    Test.stopTest();

    Assert.areEqual('Suspended', r.status);
    Workflow_Step_Execution__c row = waitStepRow(instanceId);
    String key = WorkflowNotifier.fireKey(row.Id);
    Assert.areEqual('Notify:' + String.valueOf(row.Id), key);

    Assert.areEqual(1, WorkflowNotifier.publishedEvents.size());
    Workflow_Event__e evt = WorkflowNotifier.publishedEvents[0];
    Assert.areEqual(WorkflowNotifier.EVENT_TYPE, evt.Event_Type__c);
    Assert.areEqual(String.valueOf(instanceId), evt.Workflow_Instance_Id__c);
    Assert.areEqual(key, evt.Idempotency_Key__c);

    List<Workflow_Log__c> logs = anchors(instanceId);
    Assert.areEqual(1, logs.size(), 'One anchor row per logical suspend');
    Assert.areEqual(key, logs[0].Fire_Key__c);
    Assert.areEqual(WorkflowNotifier.OUTCOME_SENT, logs[0].Outcome__c);
    Assert.areEqual('Info', logs[0].Level__c);
    Assert.areEqual(WF, logs[0].Workflow_Name__c);

    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
    WorkflowNotifier.SentNotification sent = WorkflowNotifier.sentNotifications[0];
    Assert.areEqual(FAKE_TYPE_ID, sent.typeId);
    Assert.areEqual('Approve order', sent.title);
    Assert.areEqual('Order needs your decision', sent.body);
    Assert.areEqual(instanceId, sent.targetId, 'Default deep link: instance');
    Assert.areEqual(new Set<String>{ userId() }, sent.recipients);
  }

  @IsTest
  static void approvalWaitRequestsOneNotification() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-approval',
      new Map<String, Object>{
        'approval' => true,
        'inputField' => 'approverId',
        'approverId' => userId()
      }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result r = driveAndDeliver(harness);
    Test.stopTest();

    Assert.areEqual('Suspended', r.status);
    Assert.isTrue(
      waitStepRow(instanceId).Output__c.contains('waitingForApproval'),
      'The approval state must not change'
    );
    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      new Set<String>{ userId() },
      WorkflowNotifier.sentNotifications[0].recipients
    );

    WorkflowTestHarness.Result done = harness.injectSignal(
      'notify-approval',
      'Approve:Gate',
      '{"approved":true}'
    );
    Assert.areEqual('Completed', done.status);
    Assert.areEqual(1, anchors(instanceId).size(), 'Completion adds no row');
  }

  @IsTest
  static void timedSuspendAlsoNotifies() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-timed',
      new Map<String, Object>{ 'timed' => true, 'recipient' => userId() }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    // Keep the timed wait. Else the harness skips the timer and loops.
    harness.disableAutoTimeSkip = true;
    WorkflowTestHarness.Result r = driveAndDeliver(harness);
    Test.stopTest();

    Assert.areEqual('Suspended', r.status);
    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
    Assert.isNotNull(
      [
        SELECT Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
        WITH SYSTEM_MODE
      ]
      .Sleep_Until__c,
      'The timed suspend must keep its deadline'
    );
  }

  @IsTest
  static void noNotificationCostsNothing() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-none',
      new Map<String, Object>{ 'none' => true }
    );
    WorkflowTestHarness.Result r = driveAndDeliver(
      new WorkflowTestHarness(instanceId)
    );
    Test.stopTest();

    Assert.areEqual('Suspended', r.status);
    Assert.areEqual(0, WorkflowNotifier.publishedEvents.size());
    Assert.areEqual(0, anchors(instanceId).size());
  }

  // ----- Recipients

  @IsTest
  static void inputFieldRecipientsResolvedAtSuspend() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-input-list',
      new Map<String, Object>{
        'inputField' => 'approvers',
        'approvers' => new List<Object>{ userId(), 'not-an-id', 42 }
      }
    );
    driveAndDeliver(new WorkflowTestHarness(instanceId));
    Test.stopTest();

    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      new Set<String>{ userId() },
      WorkflowNotifier.sentNotifications[0].recipients,
      'Bad values are ignored'
    );
  }

  @IsTest
  static void recordOwnerResolvedAtSend() {
    seedType();
    Account acct = new Account(Name = 'Notify Owner');
    insert as system acct;
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-owner',
      new Map<String, Object>{ 'ownerOf' => String.valueOf(acct.Id) }
    );
    driveAndDeliver(new WorkflowTestHarness(instanceId));
    Test.stopTest();

    Id ownerId = [
      SELECT OwnerId
      FROM Account
      WHERE Id = :acct.Id
      WITH SYSTEM_MODE
    ]
    .OwnerId;
    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      new Set<String>{ String.valueOf(ownerId) },
      WorkflowNotifier.sentNotifications[0].recipients
    );
  }

  @IsTest
  static void largeAudienceIsSentInChunks() {
    seedType();
    List<Object> approvers = new List<Object>();
    for (Integer i = 1; i <= SEND_CHUNK + 1; i++) {
      approvers.add('005' + String.valueOf(i).leftPad(12, '0'));
    }
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-chunks',
      new Map<String, Object>{
        'inputField' => 'approvers',
        'approvers' => approvers
      }
    );
    driveAndDeliver(new WorkflowTestHarness(instanceId));
    Test.stopTest();

    Assert.areEqual(2, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      SEND_CHUNK,
      WorkflowNotifier.sentNotifications[0].recipients.size()
    );
    Assert.areEqual(1, WorkflowNotifier.sentNotifications[1].recipients.size());
    Assert.areEqual(
      WorkflowNotifier.OUTCOME_SENT,
      anchors(instanceId)[0].Outcome__c
    );
  }

  @IsTest
  static void copiesInOneBatchSendOnce() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-copies',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowEngine.runStep(instanceId);
    Workflow_Event__e evt = WorkflowNotifier.publishedEvents[0];
    // At-least-once delivery: two copies of one event in one batch.
    WorkflowNotifier.handleEvents(
      new List<Workflow_Event__e>{ evt, evt.clone() }
    );
    Test.stopTest();

    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      WorkflowNotifier.OUTCOME_SENT,
      anchors(instanceId)[0].Outcome__c
    );
  }

  @IsTest
  static void forgedEventWithNoAnchorSendsNothing() {
    seedType();
    List<Workflow_Event__e> events = new List<Workflow_Event__e>{
      new Workflow_Event__e(
        Event_Type__c = WorkflowNotifier.EVENT_TYPE,
        Idempotency_Key__c = WorkflowNotifier.fireKey(UserInfo.getUserId()),
        Payload__c = '{"type":"Revenant_Workflow_Notification","title":"x",' +
          '"body":"y","recipients":["' +
          userId() +
          '"]}'
      ),
      new Workflow_Event__e(
        Event_Type__c = WorkflowNotifier.EVENT_TYPE,
        Idempotency_Key__c = 'someCorrelationKey:Started'
      )
    };
    Test.startTest();
    WorkflowNotifier.handleEvents(events);
    Test.stopTest();

    Assert.areEqual(0, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Workflow_Log__c WITH SYSTEM_MODE],
      'A forged event writes no row'
    );
  }

  @IsTest
  static void forgedPayloadIsIgnored() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-forged-payload',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowEngine.runStep(instanceId);
    String key = WorkflowNotifier.publishedEvents[0].Idempotency_Key__c;
    // Same key, forged content: the engine reads the anchor row, not this.
    WorkflowNotifier.handleEvents(
      new List<Workflow_Event__e>{
        new Workflow_Event__e(
          Event_Type__c = WorkflowNotifier.EVENT_TYPE,
          Idempotency_Key__c = key,
          Payload__c = '{"key":"' +
            key +
            '","title":"Forged","body":"x",' +
            '"recipients":["' +
            String.valueOf(UserInfo.getProfileId()) +
            '"]}'
        )
      }
    );
    Test.stopTest();

    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      'Approve order',
      WorkflowNotifier.sentNotifications[0].title
    );
    Assert.areEqual(
      new Set<String>{ userId() },
      WorkflowNotifier.sentNotifications[0].recipients
    );
  }

  @IsTest
  static void sendBudgetDefersTheRest() {
    seedType();
    WorkflowNotifier.sendCallsPerPass = 1;
    Test.startTest();
    Id first = startWorkflow(
      'notify-budget-1',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    Id second = startWorkflow(
      'notify-budget-2',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowEngine.runStep(first);
    WorkflowEngine.runStep(second);
    Test.getEventBus().deliver();
    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size(), 'Pass 1');
    // Pass 2 gets the request that pass 1 published again.
    Test.getEventBus().deliver();
    Test.stopTest();

    Assert.areEqual(2, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      WorkflowNotifier.OUTCOME_SENT,
      anchors(first)[0].Outcome__c
    );
    Assert.areEqual(
      WorkflowNotifier.OUTCOME_SENT,
      anchors(second)[0].Outcome__c
    );
  }

  @IsTest
  static void lowResultDmlSendsNothingAndWaits() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-result-dml',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowEngine.runStep(instanceId);
    WorkflowNotifier.forceResultDmlExhausted = true;
    Test.getEventBus().deliver();
    Assert.areEqual(0, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      WorkflowNotifier.OUTCOME_REQUESTED,
      anchors(instanceId)[0].Outcome__c,
      'No send before the result row can be saved'
    );
    // The pass published the request again. The next pass sends it.
    WorkflowNotifier.forceResultDmlExhausted = false;
    Test.getEventBus().deliver();
    Test.stopTest();

    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      WorkflowNotifier.OUTCOME_SENT,
      anchors(instanceId)[0].Outcome__c
    );
  }

  @IsTest
  static void endedWaitIsSkipped() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-ended-wait',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowEngine.runStep(instanceId);
    // The decision arrives and the step completes before the send.
    WorkflowEngine.signal('notify-ended-wait', 'Go', '{}');
    WorkflowEngine.runStep(instanceId);
    Test.getEventBus().deliver();
    Test.stopTest();

    Assert.areEqual(0, WorkflowNotifier.sentNotifications.size());
    Workflow_Log__c log = anchors(instanceId)[0];
    Assert.areEqual(WorkflowNotifier.OUTCOME_SKIPPED, log.Outcome__c);
    Assert.isTrue(log.Message__c.contains('wait ended'), log.Message__c);
  }

  @IsTest
  static void unrelatedWakeStillNotifies() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-woken-wait',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowEngine.runStep(instanceId);
    // An unrelated signal wakes the instance (Running). The step row is still
    // Pending: the step runs again and waits again. Do not lose the send.
    WorkflowEngine.signal('notify-woken-wait', 'Other', '{}');
    Test.getEventBus().deliver();
    Test.stopTest();

    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      WorkflowNotifier.OUTCOME_SENT,
      anchors(instanceId)[0].Outcome__c
    );
  }

  @IsTest
  static void bufferedSignalAtSuspendDoesNotNotify() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-buffered',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    // The decision arrived before the step waits (a captured signal).
    insert as system new Workflow_Signal__c(
      Correlation_Key__c = 'notify-buffered',
      Signal_Name__c = 'Go',
      Payload__c = '{}',
      Status__c = 'Unrouted'
    );
    // The SUSPEND redelivers it and wakes the instance in one transaction.
    WorkflowEngine.runStep(instanceId);
    Assert.areEqual(
      0,
      anchors(instanceId).size(),
      'No request for a woken wait'
    );
    Assert.areEqual(0, WorkflowNotifier.publishedEvents.size());
    Test.stopTest();
  }

  @IsTest
  static void lowQueryBudgetWaits() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-query-budget',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowEngine.runStep(instanceId);
    WorkflowNotifier.forceQueryBudgetExhausted = true;
    Test.getEventBus().deliver();
    Assert.areEqual(0, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      WorkflowNotifier.OUTCOME_REQUESTED,
      anchors(instanceId)[0].Outcome__c,
      'No query budget: the request waits, it does not fail'
    );
    WorkflowNotifier.forceQueryBudgetExhausted = false;
    Test.getEventBus().deliver();
    Test.stopTest();

    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      WorkflowNotifier.OUTCOME_SENT,
      anchors(instanceId)[0].Outcome__c
    );
  }

  @IsTest
  static void passReadsMaxKeysAndPublishesTheRest() {
    seedType();
    Assert.areEqual(10, WorkflowNotifier.eventsPerPass, 'Default cap');
    WorkflowNotifier.eventsPerPass = 2;
    Test.startTest();
    for (Integer i = 0; i < 3; i++) {
      WorkflowEngine.runStep(
        startWorkflow(
          'notify-cap-' + i,
          new Map<String, Object>{ 'recipient' => userId() }
        )
      );
    }
    Test.getEventBus().deliver();
    Assert.areEqual(2, WorkflowNotifier.sentNotifications.size(), 'Pass 1');
    Test.getEventBus().deliver();
    Test.stopTest();

    Assert.areEqual(3, WorkflowNotifier.sentNotifications.size());
  }

  @IsTest
  static void failedClaimSendsNothingAndWaits() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-claim',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowEngine.runStep(instanceId);
    WorkflowNotifier.forceClaimFailure = true;
    Test.getEventBus().deliver();
    Assert.areEqual(0, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      WorkflowNotifier.OUTCOME_REQUESTED,
      anchors(instanceId)[0].Outcome__c,
      'No send without a claim'
    );
    // The pass published the key again. The next pass claims and sends.
    WorkflowNotifier.forceClaimFailure = false;
    Test.getEventBus().deliver();
    Test.stopTest();

    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      WorkflowNotifier.OUTCOME_SENT,
      anchors(instanceId)[0].Outcome__c
    );
  }

  @IsTest
  static void deferredPublishFailureIsLogged() {
    seedType();
    WorkflowNotifier.sendCallsPerPass = 1;
    Test.startTest();
    Id first = startWorkflow(
      'notify-defer-fail-1',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    Id second = startWorkflow(
      'notify-defer-fail-2',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowEngine.runStep(first);
    WorkflowEngine.runStep(second);
    WorkflowNotifier.throwPublishException = true;
    Test.getEventBus().deliver();
    Test.stopTest();

    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
    List<String> outcomes = new List<String>{
      anchors(first)[0].Outcome__c,
      anchors(second)[0].Outcome__c
    };
    outcomes.sort();
    Assert.areEqual(
      new List<String>{
        WorkflowNotifier.OUTCOME_FAILED,
        WorkflowNotifier.OUTCOME_SENT
      },
      outcomes,
      'The deferred request fails. It does not stay Requested.'
    );
  }

  @IsTest
  static void tooManyRecipientsForOnePassFails() {
    seedType();
    WorkflowNotifier.sendCallsPerPass = 1;
    List<Object> approvers = new List<Object>();
    for (Integer i = 1; i <= SEND_CHUNK + 1; i++) {
      approvers.add('005' + String.valueOf(i).leftPad(12, '0'));
    }
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-too-many',
      new Map<String, Object>{
        'inputField' => 'approvers',
        'approvers' => approvers
      }
    );
    driveAndDeliver(new WorkflowTestHarness(instanceId));
    Test.stopTest();

    Workflow_Log__c log = anchors(instanceId)[0];
    Assert.areEqual(WorkflowNotifier.OUTCOME_FAILED, log.Outcome__c);
    Assert.isTrue(
      log.Message__c.contains('Too many recipients'),
      log.Message__c
    );
    Assert.areEqual(0, WorkflowNotifier.sentNotifications.size());
  }

  @IsTest
  static void nonUserRecipientsAreIgnored() {
    seedType();
    Account acct = new Account(Name = 'Not a recipient');
    insert as system acct;
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-filter',
      new Map<String, Object>{
        'inputField' => 'approvers',
        'approvers' => new List<Object>{ userId(), String.valueOf(acct.Id) }
      }
    );
    driveAndDeliver(new WorkflowTestHarness(instanceId));
    Test.stopTest();

    Assert.areEqual(
      new Set<String>{ userId() },
      WorkflowNotifier.sentNotifications[0].recipients
    );
    Assert.isTrue(
      anchors(instanceId)[0].Message__c.contains('ignored 1'),
      anchors(instanceId)[0].Message__c
    );
  }

  @IsTest
  static void exactlyOneChunkIsOneCall() {
    seedType();
    List<Object> approvers = new List<Object>();
    for (Integer i = 1; i <= SEND_CHUNK; i++) {
      approvers.add('005' + String.valueOf(i).leftPad(12, '0'));
    }
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-one-chunk',
      new Map<String, Object>{
        'inputField' => 'approvers',
        'approvers' => approvers
      }
    );
    driveAndDeliver(new WorkflowTestHarness(instanceId));
    Test.stopTest();

    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      SEND_CHUNK,
      WorkflowNotifier.sentNotifications[0].recipients.size()
    );
  }

  @IsTest
  static void oversizedInputIsNotParsed() {
    seedType();
    WorkflowNotifier.maxInputParseLength = 10;
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-big-input',
      new Map<String, Object>{
        'inputField' => 'approverId',
        'approverId' => userId()
      }
    );
    WorkflowTestHarness.Result r = driveAndDeliver(
      new WorkflowTestHarness(instanceId)
    );
    Test.stopTest();

    Assert.areEqual('Suspended', r.status);
    Workflow_Log__c log = anchors(instanceId)[0];
    Assert.areEqual(WorkflowNotifier.OUTCOME_FAILED, log.Outcome__c);
    Assert.isTrue(log.Message__c.contains('No recipient'), log.Message__c);
  }

  // ----- Deep link and type

  @IsTest
  static void authorTargetAndTypeAreUsed() {
    seedType();
    WorkflowNotifier.typeIds.put('Custom_Approval', OTHER_TYPE_ID);
    Account acct = new Account(Name = 'Notify Target');
    insert as system acct;
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-target',
      new Map<String, Object>{
        'recipient' => userId(),
        'target' => String.valueOf(acct.Id),
        'type' => 'Custom_Approval'
      }
    );
    driveAndDeliver(new WorkflowTestHarness(instanceId));
    Test.stopTest();

    WorkflowNotifier.SentNotification sent = WorkflowNotifier.sentNotifications[0];
    Assert.areEqual(acct.Id, sent.targetId);
    Assert.areEqual(OTHER_TYPE_ID, sent.typeId);
  }

  // ----- Once per logical suspend

  @IsTest
  static void reSuspendDoesNotNotifyAgain() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-resuspend',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    driveAndDeliver(harness);
    Integer firstRuns = waitExecutions;
    Id firstRow = waitStepRow(instanceId).Id;

    // An unrelated signal wakes the step. It runs and suspends again.
    WorkflowTestHarness.Result again = harness.injectSignal(
      'notify-resuspend',
      'Other',
      '{}'
    );
    Test.getEventBus().deliver();
    Test.stopTest();

    Assert.areEqual('Suspended', again.status);
    Assert.isTrue(waitExecutions > firstRuns, 'The step must run again');
    Assert.areEqual(
      firstRow,
      waitStepRow(instanceId).Id,
      'Same logical suspend'
    );
    Assert.areEqual(1, anchors(instanceId).size());
    Assert.areEqual(1, WorkflowNotifier.publishedEvents.size());
    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
  }

  @IsTest
  static void operatorResumeDoesNotNotifyAgain() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-operator-resume',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    driveAndDeliver(harness);
    Integer firstRuns = waitExecutions;

    // An operator resumes the waiting instance. The step runs again on the
    // same row and suspends again.
    WorkflowResumeService.resumeInstance(instanceId, '{}');
    WorkflowTestHarness.Result again = driveAndDeliver(harness);
    Test.stopTest();

    Assert.areEqual('Suspended', again.status);
    Assert.isTrue(waitExecutions > firstRuns, 'The step must run again');
    Assert.areEqual(1, anchors(instanceId).size());
    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
  }

  @IsTest
  static void rolledBackSuspendLeavesNoAnchor() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-rollback',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    Savepoint sp = Database.setSavepoint();
    WorkflowEngine.runStep(instanceId);
    Assert.areEqual(1, anchors(instanceId).size(), 'Anchor rides the SUSPEND');
    Database.rollback(sp);

    Assert.areEqual(0, anchors(instanceId).size(), 'Anchor rolls back');
    Test.getEventBus().deliver();
    Assert.areEqual(
      0,
      WorkflowNotifier.sentNotifications.size(),
      'A rolled-back SUSPEND sends nothing (PublishAfterCommit)'
    );

    // Static captures do not roll back: publishedEvents keeps the first event.
    // The re-run notifies once.
    WorkflowTestHarness.Result r = driveAndDeliver(
      new WorkflowTestHarness(instanceId)
    );
    Test.stopTest();

    Assert.areEqual('Suspended', r.status);
    Assert.areEqual(1, anchors(instanceId).size());
    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
  }

  // ----- Fire-and-forget

  @IsTest
  static void publishFailureDoesNotBlockSuspend() {
    seedType();
    WorkflowNotifier.throwPublishException = true;
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-publish-fail',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowTestHarness.Result r = driveAndDeliver(
      new WorkflowTestHarness(instanceId)
    );
    Test.stopTest();

    Assert.areEqual('Suspended', r.status, 'The SUSPEND must commit');
    List<Workflow_Log__c> logs = anchors(instanceId);
    Assert.areEqual(1, logs.size());
    Assert.areEqual(WorkflowNotifier.OUTCOME_FAILED, logs[0].Outcome__c);
    Assert.areEqual('Error', logs[0].Level__c);
    Assert.isTrue(logs[0].Message__c.contains('Simulated'));
    Assert.areEqual(0, WorkflowNotifier.sentNotifications.size());
  }

  @IsTest
  static void lowDmlBudgetSkipsNotify() {
    seedType();
    WorkflowNotifier.forceDmlBudgetExhausted = true;
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-budget',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowTestHarness.Result r = driveAndDeliver(
      new WorkflowTestHarness(instanceId)
    );
    Test.stopTest();

    Assert.areEqual('Suspended', r.status);
    Assert.areEqual(0, anchors(instanceId).size());
    Assert.areEqual(0, WorkflowNotifier.publishedEvents.size());
  }

  @IsTest
  static void dmlReserveSkipsNotify() {
    seedType();
    // The real budget check: no reserve is left.
    WorkflowNotifier.dmlStatementReserve = Limits.getLimitDmlStatements();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-reserve',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowTestHarness.Result r = driveAndDeliver(
      new WorkflowTestHarness(instanceId)
    );
    Test.stopTest();

    Assert.areEqual('Suspended', r.status);
    Assert.areEqual(0, anchors(instanceId).size());
  }

  @IsTest
  static void sendFailureIsLogged() {
    seedType();
    WorkflowNotifier.throwSendException = true;
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-send-fail',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowTestHarness.Result r = driveAndDeliver(
      new WorkflowTestHarness(instanceId)
    );
    Test.stopTest();

    Assert.areEqual('Suspended', r.status);
    Workflow_Log__c log = anchors(instanceId)[0];
    Assert.areEqual(WorkflowNotifier.OUTCOME_FAILED, log.Outcome__c);
    Assert.areEqual('Error', log.Level__c);
    Assert.isTrue(log.Message__c.contains('Simulated'), log.Message__c);
  }

  @IsTest
  static void unknownTypeIsLogged() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-bad-type',
      new Map<String, Object>{
        'recipient' => userId(),
        'type' => 'No_Such_Type_123'
      }
    );
    driveAndDeliver(new WorkflowTestHarness(instanceId));
    Test.stopTest();

    Workflow_Log__c log = anchors(instanceId)[0];
    Assert.areEqual(WorkflowNotifier.OUTCOME_FAILED, log.Outcome__c);
    Assert.isTrue(log.Message__c.contains('No_Such_Type_123'), log.Message__c);
    Assert.areEqual(0, WorkflowNotifier.sentNotifications.size());
  }

  @IsTest
  static void noRecipientAtSendIsLogged() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-no-recipient',
      new Map<String, Object>{ 'inputField' => 'approverId' }
    );
    driveAndDeliver(new WorkflowTestHarness(instanceId));
    Test.stopTest();

    Workflow_Log__c log = anchors(instanceId)[0];
    Assert.areEqual(WorkflowNotifier.OUTCOME_FAILED, log.Outcome__c);
    Assert.isTrue(log.Message__c.contains('No recipient'), log.Message__c);
    Assert.areEqual(0, WorkflowNotifier.sentNotifications.size());
  }

  @IsTest
  static void badEventPayloadDoesNotThrow() {
    List<Workflow_Event__e> events = new List<Workflow_Event__e>{
      new Workflow_Event__e(
        Event_Type__c = WorkflowNotifier.EVENT_TYPE,
        Payload__c = 'not json'
      ),
      new Workflow_Event__e(Event_Type__c = WorkflowNotifier.EVENT_TYPE)
    };
    Test.startTest();
    new WorkflowEventTriggerHandler(events).handleAfterInsert();
    WorkflowNotifier.handleEvents(events);
    Test.stopTest();
    Assert.areEqual(0, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Log__c
        WHERE Log_Type__c = :WorkflowNotifier.LOG_TYPE
        WITH SYSTEM_MODE
      ],
      'A bad payload writes no row'
    );
  }

  @IsTest
  static void badNotifyDoesNotBlockResumeInSameBatch() {
    Test.startTest();
    Id waiting = startWorkflow(
      'notify-batch-resume',
      new Map<String, Object>{ 'none' => true }
    );
    driveAndDeliver(new WorkflowTestHarness(waiting));
    List<Workflow_Event__e> events = new List<Workflow_Event__e>{
      new Workflow_Event__e(
        Event_Type__c = WorkflowNotifier.EVENT_TYPE,
        Payload__c = '{"key":"Notify:x","owners":["bad"]}'
      ),
      new Workflow_Event__e(
        Event_Type__c = 'RESUME',
        Workflow_Instance_Id__c = String.valueOf(waiting),
        Payload__c = '{}'
      )
    };
    new WorkflowEventTriggerHandler(events).handleAfterInsert();
    // Read before stopTest: the queued resume job runs the step again.
    String status = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :waiting
      WITH SYSTEM_MODE
    ]
    .Status__c;
    Test.stopTest();

    Assert.areNotEqual(
      'Suspended',
      status,
      'The RESUME in the same batch must run'
    );
  }

  @IsTest
  static void eachRequestInABatchIsIsolated() {
    seedType();
    WorkflowNotifier.eventsPerPass = 1;
    Test.startTest();
    Id good = startWorkflow(
      'notify-batch-good',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    Id bad = startWorkflow(
      'notify-batch-bad',
      new Map<String, Object>{
        'recipient' => userId(),
        'type' => 'No_Such_Type_456'
      }
    );
    WorkflowEngine.runStep(good);
    WorkflowEngine.runStep(bad);
    Assert.areEqual(2, WorkflowNotifier.publishedEvents.size());
    // Pass 1 sends one request and publishes the other again. Pass 2 sends it.
    Test.getEventBus().deliver();
    Test.getEventBus().deliver();
    Test.stopTest();

    Assert.areEqual(WorkflowNotifier.OUTCOME_SENT, anchors(good)[0].Outcome__c);
    Assert.areEqual(
      WorkflowNotifier.OUTCOME_FAILED,
      anchors(bad)[0].Outcome__c
    );
    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
  }

  @IsTest
  static void replayedEventDoesNotSendAgain() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-replay',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    driveAndDeliver(new WorkflowTestHarness(instanceId));
    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());

    WorkflowNotifier.handleEvents(
      new List<Workflow_Event__e>{ WorkflowNotifier.publishedEvents[0] }
    );
    Test.stopTest();

    Assert.areEqual(
      1,
      WorkflowNotifier.sentNotifications.size(),
      'A row that is Sent is not sent again'
    );
    Assert.areEqual(1, anchors(instanceId).size());
  }

  // ----- Toggle

  @IsTest
  static void toggleReadsTheDefaultConfig() {
    List<Revenant_Config__mdt> configs = [
      SELECT Send_Notifications__c
      FROM Revenant_Config__mdt
      WHERE DeveloperName = 'Default'
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    Boolean expected = configs.isEmpty() ||
      configs[0].Send_Notifications__c == null
      ? true
      : configs[0].Send_Notifications__c;
    Assert.areEqual(expected, WorkflowEngine.sendNotifications);
  }

  @IsTest
  static void toggleOffPublishesNothing() {
    seedType();
    WorkflowEngine.sendNotifications = false;
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-toggle-off',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowTestHarness.Result r = driveAndDeliver(
      new WorkflowTestHarness(instanceId)
    );
    Test.stopTest();

    Assert.areEqual('Suspended', r.status);
    Assert.areEqual(0, anchors(instanceId).size());
    Assert.areEqual(0, WorkflowNotifier.publishedEvents.size());
    Assert.areEqual(0, WorkflowNotifier.sentNotifications.size());
  }

  @IsTest
  static void toggleOffAtSendSkips() {
    seedType();
    Test.startTest();
    Id instanceId = startWorkflow(
      'notify-toggle-send',
      new Map<String, Object>{ 'recipient' => userId() }
    );
    WorkflowEngine.runStep(instanceId);
    Assert.areEqual(1, WorkflowNotifier.publishedEvents.size());
    WorkflowEngine.sendNotifications = false;
    Test.getEventBus().deliver();
    Test.stopTest();

    Workflow_Log__c log = anchors(instanceId)[0];
    Assert.areEqual(WorkflowNotifier.OUTCOME_SKIPPED, log.Outcome__c);
    Assert.areEqual(0, WorkflowNotifier.sentNotifications.size());
  }
}
