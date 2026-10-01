/**
 * @description Tests for the lost-request sweep of approver notifications
 * (issue #274). Rows are inserted directly: the sweep reads only the anchor
 * row. One test runs the full path (suspend, sweep, trigger).
 */
@IsTest
private class WorkflowNotifierSweepTest {
  private static final Datetime T0 = Datetime.newInstanceGmt(
    2030,
    1,
    1,
    12,
    0,
    0
  );
  private static Integer keyCounter = 0;

  // ----- Helpers

  private static Workflow_Log__c anchor(
    String outcome,
    Datetime fireTime,
    Integer attempts
  ) {
    keyCounter++;
    String key = 'Notify:test' + keyCounter;
    Map<String, Object> msg = new Map<String, Object>{ 'key' => key };
    if (attempts != null) {
      msg.put('attempts', attempts);
    }
    return new Workflow_Log__c(
      Log_Type__c = WorkflowNotifier.LOG_TYPE,
      Level__c = 'Info',
      Outcome__c = outcome,
      Fire_Key__c = key,
      Fire_Time__c = fireTime,
      Message__c = JSON.serialize(msg)
    );
  }

  private static Workflow_Log__c reload(Workflow_Log__c row) {
    return [
      SELECT Outcome__c, Level__c, Fire_Time__c, Message__c
      FROM Workflow_Log__c
      WHERE Id = :row.Id
      WITH SYSTEM_MODE
    ];
  }

  private static Integer attemptsOf(Workflow_Log__c row) {
    Map<String, Object> msg = (Map<String, Object>) JSON.deserializeUntyped(
      row.Message__c
    );
    return (Integer) msg.get('attempts');
  }

  // ----- Stale, fresh, other outcomes

  @IsTest
  static void staleRequestedRowIsPublishedAgain() {
    Workflow_Log__c row = anchor('Requested', T0, null);
    insert as system row;

    Integer count = WorkflowNotifierSweep.run(T0.addMinutes(16));

    Assert.areEqual(1, count);
    Assert.areEqual(1, WorkflowNotifierSweep.publishedEvents.size());
    Workflow_Event__e evt = WorkflowNotifierSweep.publishedEvents[0];
    Assert.areEqual(WorkflowNotifier.EVENT_TYPE, evt.Event_Type__c);
    Assert.areEqual(row.Fire_Key__c, evt.Idempotency_Key__c);
    Workflow_Log__c after = reload(row);
    Assert.areEqual('Requested', after.Outcome__c);
    Assert.areEqual(1, attemptsOf(after));
    Assert.areEqual(T0.addMinutes(16), after.Fire_Time__c);
  }

  @IsTest
  static void freshRequestedRowIsLeftAlone() {
    Workflow_Log__c row = anchor('Requested', T0, null);
    insert as system row;

    Integer count = WorkflowNotifierSweep.run(T0.addMinutes(14));

    Assert.areEqual(0, count);
    Assert.areEqual(0, WorkflowNotifierSweep.publishedEvents.size());
    Assert.isNull(attemptsOf(reload(row)));
  }

  @IsTest
  static void rowsThatAreNotRequestedAreLeftAlone() {
    List<Workflow_Log__c> rows = new List<Workflow_Log__c>{
      anchor('Sending', T0, null),
      anchor('Sent', T0, null),
      anchor('Failed', T0, null),
      anchor('Skipped', T0, null)
    };
    insert as system rows;
    Workflow_Log__c other = anchor('Requested', T0, null);
    other.Log_Type__c = 'Schedule';
    insert as system other;

    Integer count = WorkflowNotifierSweep.run(T0.addHours(2));

    Assert.areEqual(0, count);
    Assert.areEqual(0, WorkflowNotifierSweep.publishedEvents.size());
  }

  // ----- Attempts

  @IsTest
  static void attemptsAreSpacedAndEndInFailed() {
    Workflow_Log__c row = anchor('Requested', T0, null);
    insert as system row;

    Assert.areEqual(1, WorkflowNotifierSweep.run(T0.addMinutes(16)));
    Assert.areEqual(
      0,
      WorkflowNotifierSweep.run(T0.addMinutes(20)),
      'An attempt waits for the full threshold'
    );
    Assert.areEqual(1, WorkflowNotifierSweep.run(T0.addMinutes(32)));
    Assert.areEqual(1, WorkflowNotifierSweep.run(T0.addMinutes(48)));
    Assert.areEqual(3, attemptsOf(reload(row)));
    Assert.areEqual(3, WorkflowNotifierSweep.publishedEvents.size());

    Assert.areEqual(
      0,
      WorkflowNotifierSweep.run(T0.addMinutes(64)),
      'The fourth sweep publishes nothing'
    );
    Workflow_Log__c after = reload(row);
    Assert.areEqual('Failed', after.Outcome__c);
    Assert.areEqual('Error', after.Level__c);
    Assert.isTrue(after.Message__c.contains('result'));
    Assert.areEqual(3, WorkflowNotifierSweep.publishedEvents.size());
  }

  @IsTest
  static void rowAtMaxAttemptsFailsAtOnce() {
    Workflow_Log__c row = anchor(
      'Requested',
      T0,
      WorkflowNotifierSweep.MAX_ATTEMPTS
    );
    insert as system row;

    Assert.areEqual(0, WorkflowNotifierSweep.run(T0.addMinutes(16)));

    Assert.areEqual('Failed', reload(row).Outcome__c);
    Assert.areEqual(0, WorkflowNotifierSweep.publishedEvents.size());
  }

  @IsTest
  static void unreadableMessageFails() {
    Workflow_Log__c row = anchor('Requested', T0, null);
    row.Message__c = '{not json';
    insert as system row;

    Assert.areEqual(0, WorkflowNotifierSweep.run(T0.addMinutes(16)));

    Workflow_Log__c after = reload(row);
    Assert.areEqual('Failed', after.Outcome__c);
    Assert.isTrue(after.Message__c.contains('not readable'));
    Assert.areEqual(0, WorkflowNotifierSweep.publishedEvents.size());
  }

  @IsTest
  static void rowAtExactThresholdIsNotStale() {
    insert as system anchor('Requested', T0, null);

    Assert.areEqual(0, WorkflowNotifierSweep.run(T0.addMinutes(15)));
    Assert.areEqual(
      1,
      WorkflowNotifierSweep.run(T0.addMinutes(15).addSeconds(1))
    );
  }

  @IsTest
  static void freshRowsDoNotBlockStaleRows() {
    Workflow_Log__c fresh = anchor('Requested', T0.addMinutes(20), null);
    Workflow_Log__c stale = anchor('Requested', T0, null);
    insert as system new List<Workflow_Log__c>{ fresh, stale };

    Assert.areEqual(1, WorkflowNotifierSweep.run(T0.addMinutes(30)));
    Assert.areEqual(
      stale.Fire_Key__c,
      WorkflowNotifierSweep.publishedEvents[0].Idempotency_Key__c
    );
    Assert.isNull(attemptsOf(reload(fresh)));
  }

  @IsTest
  static void oversizeUnreadableMessageStillFails() {
    Workflow_Log__c row = anchor('Requested', T0, null);
    row.Message__c = '{'.repeat(131000);
    insert as system row;

    Assert.areEqual(0, WorkflowNotifierSweep.run(T0.addMinutes(16)));

    Workflow_Log__c after = reload(row);
    Assert.areEqual('Failed', after.Outcome__c, 'The save does not fail');
    Assert.isTrue(after.Message__c.length() <= 131000);
  }

  // ----- Limits and errors

  @IsTest
  static void sweepIsBounded() {
    List<Workflow_Log__c> rows = new List<Workflow_Log__c>();
    for (Integer i = 0; i < WorkflowNotifierSweep.MAX_ROWS + 2; i++) {
      rows.add(anchor('Requested', T0.addSeconds(i), null));
    }
    insert as system rows;

    Integer count = WorkflowNotifierSweep.run(T0.addHours(1));

    Assert.areEqual(WorkflowNotifierSweep.MAX_ROWS, count);
    Set<String> waiting = new Set<String>();
    for (Workflow_Log__c row : [
      SELECT Fire_Key__c, Message__c
      FROM Workflow_Log__c
      WITH SYSTEM_MODE
    ]) {
      if (!row.Message__c.contains('attempts')) {
        waiting.add(row.Fire_Key__c);
      }
    }
    Assert.areEqual(
      new Set<String>{
        rows[WorkflowNotifierSweep.MAX_ROWS].Fire_Key__c,
        rows[WorkflowNotifierSweep.MAX_ROWS + 1].Fire_Key__c
      },
      waiting,
      'The oldest rows go first: the two newest rows wait'
    );
  }

  @IsTest
  static void noDmlBudgetChangesNothing() {
    Workflow_Log__c row = anchor('Requested', T0, null);
    insert as system row;
    WorkflowNotifierSweep.forceDmlBudgetExhausted = true;

    Assert.areEqual(0, WorkflowNotifierSweep.run(T0.addMinutes(16)));

    Assert.areEqual(0, WorkflowNotifierSweep.publishedEvents.size());
    Assert.isNull(attemptsOf(reload(row)));
  }

  @IsTest
  static void failedPublishKeepsRowRequestedWithCount() {
    Workflow_Log__c row = anchor('Requested', T0, null);
    insert as system row;
    WorkflowNotifierSweep.throwPublishException = true;

    Assert.areEqual(0, WorkflowNotifierSweep.run(T0.addMinutes(16)));

    Workflow_Log__c after = reload(row);
    Assert.areEqual('Requested', after.Outcome__c);
    Assert.areEqual(1, attemptsOf(after), 'The failed attempt is counted');
  }

  // ----- Integration

  @IsTest
  static void heartbeatRunsTheSweep() {
    Workflow_Log__c row = anchor('Requested', T0, null);
    insert as system row;
    WorkflowEngine.mockNow = T0.addMinutes(16);

    WorkflowEngine.processWatchdogHeartbeat();

    Assert.areEqual(1, WorkflowNotifierSweep.publishedEvents.size());
    Assert.areEqual(1, attemptsOf(reload(row)));
  }

  @IsTest
  static void lostRequestIsSentOnceThroughTheTrigger() {
    WorkflowEngine.sendNotifications = true;
    WorkflowNotifier.typeIds.put(
      WorkflowNotification.DEFAULT_TYPE,
      UserInfo.getOrganizationId()
    );
    Test.startTest();
    // The input 'none' suspends with no notification: a Pending step row
    // with no anchor row and no event, as after a lost publish.
    Id instanceId = WorkflowEngine.start(
      'WorkflowNotifierTest.NotifyWorkflow',
      'sweep-e2e',
      new Map<String, Object>{ 'none' => true }
    );
    new WorkflowTestHarness(instanceId).drive();
    Workflow_Step_Execution__c step = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Pending'
      WITH SYSTEM_MODE
    ];
    String key = WorkflowNotifier.fireKey(step.Id);
    Workflow_Log__c row = anchor('Requested', Datetime.now(), null);
    row.Fire_Key__c = key;
    row.Workflow_Instance__c = instanceId;
    row.Message__c = JSON.serialize(
      new Map<String, Object>{
        'key' => key,
        'type' => WorkflowNotification.DEFAULT_TYPE,
        'title' => 'Approve order',
        'body' => 'Order needs your decision',
        'target' => instanceId,
        'recipients' => new List<String>{
          String.valueOf(UserInfo.getUserId())
        },
        'owners' => new List<Id>()
      }
    );
    insert as system row;
    Test.getEventBus().deliver();
    Assert.areEqual('Requested', reload(row).Outcome__c, 'No event: lost');

    WorkflowNotifierSweep.run(Datetime.now().addHours(1));
    Test.getEventBus().deliver();
    WorkflowNotifierSweep.run(Datetime.now().addHours(2));
    Test.getEventBus().deliver();
    Test.stopTest();

    Assert.areEqual('Sent', reload(row).Outcome__c);
    Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
    Assert.areEqual(
      1,
      WorkflowNotifierSweep.publishedEvents.size(),
      'A Sent row is not published again'
    );
  }
}
