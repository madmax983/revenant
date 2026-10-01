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
    Integer waiting = 0;
    for (Workflow_Log__c row : [
      SELECT Message__c
      FROM Workflow_Log__c
      WITH SYSTEM_MODE
    ]) {
      if (!row.Message__c.contains('attempts')) {
        waiting++;
      }
    }
    Assert.areEqual(2, waiting, 'The oldest rows go first; two rows wait');
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
    Id instanceId = WorkflowEngine.start(
      'WorkflowNotifierTest.NotifyWorkflow',
      'sweep-e2e',
      new Map<String, Object>{
        'recipient' => String.valueOf(UserInfo.getUserId())
      }
    );
    new WorkflowTestHarness(instanceId).drive();
    Workflow_Log__c row = [
      SELECT Id, Outcome__c
      FROM Workflow_Log__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Log_Type__c = :WorkflowNotifier.LOG_TYPE
      WITH SYSTEM_MODE
    ];
    Assert.areEqual('Requested', row.Outcome__c, 'No event ran yet');

    WorkflowNotifierSweep.run(Datetime.now().addHours(1));
    Test.getEventBus().deliver();
    WorkflowNotifierSweep.run(Datetime.now().addHours(2));
    Test.getEventBus().deliver();
    Test.stopTest();

    Assert.areEqual('Sent', reload(row).Outcome__c);
    Assert.areEqual(
      1,
      WorkflowNotifier.sentNotifications.size(),
      'Two events for one key send one notification'
    );
    Assert.areEqual(
      1,
      WorkflowNotifierSweep.publishedEvents.size(),
      'A Sent row is not published again'
    );
  }
}
