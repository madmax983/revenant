/**
 * @description Tests for WorkflowStallDetector (issue #139): one alert per
 * stall of a non-terminal instance, with no write to step or instance rows.
 */
@IsTest
private class WorkflowStallDetectorTest {
  private static final String FLOW = 'StallTest.Flow';
  private static final String FLOW_KEY = 'StallTest_Flow';

  private static Workflow_Alert_Config__mdt config(
    String devName,
    Boolean enabled,
    Integer threshold,
    String recipients,
    Boolean publishEvent
  ) {
    return (Workflow_Alert_Config__mdt) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'DeveloperName' => devName,
          'Enable_Alerts__c' => enabled,
          'Stall_Threshold_Minutes__c' => threshold,
          'Email_Recipients__c' => recipients,
          'Publish_Alert_Event__c' => publishEvent
        }
      ),
      Workflow_Alert_Config__mdt.class
    );
  }

  private static void useConfig(Integer threshold) {
    WorkflowAlertManager.mockConfigs.put(
      FLOW_KEY,
      config(FLOW_KEY, true, threshold, 'ops@test.com', false)
    );
  }

  // Inserts an instance and one step. Both are idleMinutes old.
  private static Workflow_Instance__c stalled(
    String status,
    Integer idleMinutes
  ) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = FLOW,
      Status__c = status,
      Current_Step__c = 'StallTest.WaitStep'
    );
    insert inst;
    // One more second, so a cut to whole seconds keeps the idle minutes.
    Datetime at = Datetime.now().addMinutes(-idleMinutes).addSeconds(-1);
    Test.setCreatedDate(inst.Id, at);
    addStep(inst.Id, status == 'Suspended' ? 'Pending' : 'Completed', at);
    return inst;
  }

  private static Workflow_Step_Execution__c addStep(
    Id instanceId,
    String status,
    Datetime createdAt
  ) {
    Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = 'StallTest.WaitStep',
      Status__c = status
    );
    insert step;
    Test.setCreatedDate(step.Id, createdAt);
    return step;
  }

  private static List<Workflow_Log__c> stallRows(Id instanceId) {
    return [
      SELECT Id, Fire_Key__c, Message__c
      FROM Workflow_Log__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Log_Type__c = 'WorkflowStallAlert'
    ];
  }

  private static Integer runSweep() {
    WorkflowAlertManager.sentEmailsCount = 0;
    return WorkflowStallDetector.detectAndAlertStalls();
  }

  @IsTest
  static void suspendedSignalWaitPastThresholdSendsOneAlert() {
    useConfig(10);
    Workflow_Instance__c inst = stalled('Suspended', 15);

    Integer sent = runSweep();

    Assert.areEqual(1, sent, 'A hung signal wait must alert.');
    Assert.areEqual(1, WorkflowAlertManager.sentEmailsCount);
    Assert.areEqual(1, stallRows(inst.Id).size());
  }

  @IsTest
  static void emailNamesInstanceDefinitionStepStatusAndIdleTime() {
    useConfig(10);
    Workflow_Instance__c inst = stalled('Running', 15);
    inst = [SELECT Id, Name FROM Workflow_Instance__c WHERE Id = :inst.Id];

    runSweep();

    String body = WorkflowAlertManager.lastHtmlBody;
    Assert.isNotNull(body, 'The sweep must build an email.');
    Assert.isTrue(body.contains(FLOW), 'Definition: ' + body);
    Assert.isTrue(body.contains(inst.Name), 'Instance name: ' + body);
    Assert.isTrue(body.contains(String.valueOf(inst.Id)), 'Id: ' + body);
    Assert.isTrue(body.contains('StallTest.WaitStep'), 'Step: ' + body);
    Assert.isTrue(body.contains('Running'), 'Status: ' + body);
    Assert.isTrue(body.contains('15 minutes'), 'Idle time: ' + body);
  }

  @IsTest
  static void eventMessageNamesCurrentStep() {
    WorkflowAlertManager.mockConfigs.put(
      FLOW_KEY,
      config(FLOW_KEY, true, 10, '', true)
    );
    stalled('Running', 15);
    WorkflowAlertManager.publishedEvents.clear();

    Integer sent = runSweep();

    Assert.areEqual(1, sent);
    Assert.areEqual(1, WorkflowAlertManager.publishedEvents.size());
    Workflow_Alert__e evt = WorkflowAlertManager.publishedEvents[0];
    Assert.areEqual('Stall', evt.Alert_Reason__c);
    Assert.isTrue(
      evt.Error_Message__c.contains('StallTest.WaitStep'),
      evt.Error_Message__c
    );
  }

  @IsTest
  static void disabledDefinitionRecordBlocksDefault() {
    WorkflowAlertManager.mockConfigs.put(
      'Default',
      config('Default', true, 10, 'ops@test.com', false)
    );
    WorkflowAlertManager.mockConfigs.put(
      FLOW_KEY,
      config(FLOW_KEY, false, 10, 'ops@test.com', false)
    );
    Workflow_Instance__c inst = stalled('Running', 15);

    Assert.areEqual(0, runSweep(), 'Enable_Alerts__c = false must win.');
    Assert.areEqual(0, stallRows(inst.Id).size());
  }

  @IsTest
  static void blankThresholdOnDefinitionRecordBlocksDefault() {
    WorkflowAlertManager.mockConfigs.put(
      'Default',
      config('Default', true, 10, 'ops@test.com', false)
    );
    WorkflowAlertManager.mockConfigs.put(
      FLOW_KEY,
      config(FLOW_KEY, true, null, 'ops@test.com', false)
    );
    Workflow_Instance__c inst = stalled('Running', 15);

    Assert.areEqual(0, runSweep(), 'A blank threshold must disable.');
    Assert.areEqual(0, stallRows(inst.Id).size());
  }

  @IsTest
  static void defaultAppliesWhenNoDefinitionRecord() {
    WorkflowAlertManager.mockConfigs.put(
      'Default',
      config('Default', true, 10, 'ops@test.com', false)
    );
    stalled('Running', 15);

    Assert.areEqual(1, runSweep());
  }

  @IsTest
  static void blankThresholdEverywhereDoesNoWorkAndNoQuery() {
    WorkflowAlertManager.mockConfigs.put(
      'Default',
      config('Default', true, null, 'ops@test.com', true)
    );
    Workflow_Instance__c inst = stalled('Running', 600);

    Integer queriesBefore = Limits.getQueries();
    Integer dmlBefore = Limits.getDmlStatements();
    Integer sent = runSweep();

    Assert.areEqual(0, sent);
    Assert.areEqual(queriesBefore, Limits.getQueries(), 'No SOQL.');
    Assert.areEqual(dmlBefore, Limits.getDmlStatements(), 'No DML.');
    Assert.areEqual(0, stallRows(inst.Id).size());
  }

  @IsTest
  static void terminalInstanceSendsNothing() {
    useConfig(10);
    List<Workflow_Instance__c> done = new List<Workflow_Instance__c>();
    for (
      String status : new List<String>{
        'Completed',
        'Failed',
        'Cancelled',
        'Compensated',
        'ContinuedAsNew'
      }
    ) {
      done.add(stalled(status, 60));
    }

    Assert.areEqual(0, runSweep(), 'A terminal instance is not stuck.');
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Log__c
        WHERE Log_Type__c = 'WorkflowStallAlert'
      ]
    );
  }

  @IsTest
  static void sweepWritesNoStepAndNoInstanceField() {
    useConfig(10);
    Workflow_Instance__c inst = stalled('Suspended', 15);
    Workflow_Step_Execution__c before = [
      SELECT Id, Status__c, SystemModstamp
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :inst.Id
    ];
    Datetime instStamp = [
      SELECT SystemModstamp
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ]
    .SystemModstamp;

    Assert.areEqual(1, runSweep());

    Workflow_Step_Execution__c after = [
      SELECT Id, Status__c, SystemModstamp
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :inst.Id
    ];
    Assert.areEqual(before.Status__c, after.Status__c);
    Assert.areEqual(before.SystemModstamp, after.SystemModstamp);
    Workflow_Instance__c reread = [
      SELECT SystemModstamp, Terminal_At__c, Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    Assert.areEqual(instStamp, reread.SystemModstamp, 'No instance write.');
    Assert.isNull(reread.Terminal_At__c, 'Terminal_At__c is not a marker.');
    Assert.areEqual('Suspended', reread.Status__c);
  }

  @IsTest
  static void claimRowHasKeyAndLaterSweepsDoNotRefire() {
    useConfig(10);
    Workflow_Instance__c inst = stalled('Running', 15);

    Assert.areEqual(1, runSweep());
    Assert.areEqual(0, runSweep(), 'The second sweep must not refire.');
    Assert.areEqual(0, runSweep(), 'The third sweep must not refire.');

    List<Workflow_Log__c> rows = stallRows(inst.Id);
    Assert.areEqual(1, rows.size());
    Assert.isTrue(
      rows[0].Fire_Key__c.startsWith('Stall:' + inst.Id + ':'),
      rows[0].Fire_Key__c
    );
  }

  @IsTest
  static void claimHeldByOtherSweepBlocksAlert() {
    useConfig(10);
    Workflow_Instance__c inst = stalled('Running', 15);
    Datetime clock = [
      SELECT CreatedDate
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :inst.Id
    ]
    .CreatedDate;
    // A row that the candidate query cannot see holds the key.
    insert new Workflow_Log__c(
      Log_Type__c = 'Other',
      Fire_Key__c = WorkflowStallDetector.claimKey(inst.Id, clock)
    );

    Assert.areEqual(0, runSweep(), 'Only the claim winner sends.');
    Assert.areEqual(0, WorkflowAlertManager.sentEmailsCount);
  }

  @IsTest
  static void failedEmailReleasesClaimAndNextSweepSends() {
    useConfig(10);
    Workflow_Instance__c inst = stalled('Running', 15);

    WorkflowAlertManager.throwTestException = true;
    Assert.areEqual(0, runSweep());
    Assert.areEqual(0, stallRows(inst.Id).size(), 'Claim is released.');

    WorkflowAlertManager.throwTestException = false;
    Assert.areEqual(1, runSweep(), 'The next sweep tries again.');
    Assert.areEqual(1, stallRows(inst.Id).size());
  }

  @IsTest
  static void noBudgetSendsNothingAndKeepsNoClaim() {
    useConfig(10);
    Workflow_Instance__c inst = stalled('Running', 15);
    WorkflowStallDetector.forceBudgetExhausted = true;

    Assert.areEqual(0, runSweep());
    Assert.areEqual(0, stallRows(inst.Id).size());
  }

  @IsTest
  static void clockStartsAtPastWakeTime() {
    useConfig(10);
    Workflow_Instance__c woke = stalled('Suspended', 60);
    woke.Sleep_Until__c = Datetime.now().addMinutes(-5);
    Workflow_Instance__c late = stalled('Suspended', 60);
    late.Sleep_Until__c = Datetime.now().addMinutes(-15);
    update new List<Workflow_Instance__c>{ woke, late };

    Assert.areEqual(1, runSweep());
    Assert.areEqual(0, stallRows(woke.Id).size(), 'Woke 5 minutes ago.');
    Assert.areEqual(1, stallRows(late.Id).size(), 'Woke 15 minutes ago.');
  }

  @IsTest
  static void futureWakeTimeSendsNothing() {
    useConfig(10);
    Workflow_Instance__c sleeper = stalled('Suspended', 60);
    sleeper.Sleep_Until__c = Datetime.now().addMinutes(30);
    update sleeper;

    Assert.areEqual(0, runSweep(), 'The engine holds a timer.');
  }

  @IsTest
  static void recentStepSendsNothing() {
    useConfig(10);
    Workflow_Instance__c inst = stalled('Running', 60);
    addStep(inst.Id, 'Running', Datetime.now().addMinutes(-2));

    Assert.areEqual(0, runSweep(), 'The instance made progress.');
  }

  @IsTest
  static void newProgressThenNewStallSendsAgain() {
    useConfig(10);
    Workflow_Instance__c inst = stalled('Running', 40);
    Assert.areEqual(1, runSweep());
    Workflow_Log__c first = stallRows(inst.Id)[0];
    Test.setCreatedDate(first.Id, Datetime.now().addMinutes(-30));

    addStep(inst.Id, 'Running', Datetime.now().addMinutes(-20));

    Assert.areEqual(1, runSweep(), 'A new stall sends a new alert.');
    Assert.areEqual(2, stallRows(inst.Id).size());
  }

  @IsTest
  static void soqlDoesNotGrowWithInstanceCount() {
    // Event channel only. An email channel reserves org email capacity for
    // all 20 addresses at once, and a scratch org can refuse that.
    WorkflowAlertManager.mockConfigs.put(
      FLOW_KEY,
      config(FLOW_KEY, true, 10, '', true)
    );
    stalled('Running', 15);
    // Load the pause cache first, so both sweeps start the same.
    WorkflowPauseGate.isDefinitionPaused(FLOW);

    Integer before = Limits.getQueries();
    Assert.areEqual(1, runSweep());
    Integer oneRow = Limits.getQueries() - before;

    for (Integer i = 0; i < 20; i++) {
      stalled('Running', 15);
    }
    before = Limits.getQueries();
    Assert.areEqual(20, runSweep());
    Integer twentyRows = Limits.getQueries() - before;

    Assert.areEqual(oneRow, twentyRows, 'SOQL must not grow.');
    Assert.isTrue(oneRow <= 1, 'One candidate query: ' + oneRow);
  }

  @IsTest
  static void capSendsTheRestInNextSweep() {
    useConfig(10);
    stalled('Running', 15);
    stalled('Running', 15);
    WorkflowStallDetector.maxAlertsPerSweep = 1;

    Assert.areEqual(1, runSweep());
    Assert.areEqual(1, runSweep(), 'The next sweep sends the rest.');
    Assert.areEqual(0, runSweep());
  }

  @IsTest
  static void heartbeatRunsTheDetector() {
    WorkflowWatchdog.forceBootstrapInTest = true;
    WorkflowEngine.disableQueueableInTest = true;
    useConfig(10);
    Workflow_Instance__c inst = stalled('Suspended', 15);

    Test.startTest();
    WorkflowEngine.processWatchdogHeartbeat();
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    Assert.areEqual(1, stallRows(inst.Id).size(), 'One alert per stall.');
  }
  @IsTest
  static void activeStatusesAlertAndParkedStatusesDoNot() {
    useConfig(10);
    List<Workflow_Instance__c> active = new List<Workflow_Instance__c>();
    for (
      String status : new List<String>{
        'Pending',
        'Compensating',
        'Cancelling',
        'DefinitionChanged'
      }
    ) {
      active.add(stalled(status, 15));
    }
    List<Workflow_Instance__c> parked = new List<Workflow_Instance__c>();
    for (
      String status : new List<String>{ 'Held', 'Paused', 'CompensationFailed' }
    ) {
      parked.add(stalled(status, 15));
    }

    Assert.areEqual(4, runSweep());
    for (Workflow_Instance__c inst : active) {
      Assert.areEqual(1, stallRows(inst.Id).size(), 'Active: ' + inst.Id);
    }
    for (Workflow_Instance__c inst : parked) {
      Assert.areEqual(0, stallRows(inst.Id).size(), 'Parked: ' + inst.Id);
    }
  }

  @IsTest
  static void engineWorkflowSendsNothing() {
    WorkflowAlertManager.mockConfigs.put(
      'Default',
      config('Default', true, 10, 'ops@test.com', false)
    );
    Workflow_Instance__c inst = stalled('Running', 15);
    inst.Workflow_Name__c = 'CleanupWorkflow';
    update inst;

    Assert.areEqual(0, runSweep(), 'The engine workflow is excluded.');
  }

  @IsTest
  static void failedEventWithNoEmailReleasesClaim() {
    WorkflowAlertManager.mockConfigs.put(
      FLOW_KEY,
      config(FLOW_KEY, true, 10, '', true)
    );
    Workflow_Instance__c inst = stalled('Running', 15);
    WorkflowAlertManager.forceDmlBudgetExhausted = true;

    Assert.areEqual(0, runSweep());
    Assert.areEqual(0, stallRows(inst.Id).size(), 'Claim is released.');
  }

  @IsTest
  static void failedEmailWithSentEventKeepsClaim() {
    WorkflowAlertManager.mockConfigs.put(
      FLOW_KEY,
      config(FLOW_KEY, true, 10, 'ops@test.com', true)
    );
    Workflow_Instance__c inst = stalled('Running', 15);
    WorkflowAlertManager.throwTestException = true;
    WorkflowAlertManager.publishedEvents.clear();

    Assert.areEqual(1, runSweep(), 'The event sent the alert.');
    Assert.areEqual(1, WorkflowAlertManager.publishedEvents.size());
    Assert.areEqual(1, stallRows(inst.Id).size());
  }

  @IsTest
  static void noEmailCapacityClaimsNothing() {
    useConfig(10);
    Workflow_Instance__c inst = stalled('Running', 15);
    WorkflowStallDetector.forceEmailCapacityExhausted = true;

    Assert.areEqual(0, runSweep());
    Assert.areEqual(0, stallRows(inst.Id).size(), 'No claim churn.');
  }

  @IsTest
  static void emailGoesToAllFailureAlertRecipients() {
    Workflow_Alert_Config__mdt cfg = config(
      FLOW_KEY,
      true,
      10,
      'a@test.com; b@test.com',
      false
    );
    WorkflowAlertManager.StallAlertRequest request = new WorkflowAlertManager.StallAlertRequest();
    request.instance = new Workflow_Instance__c(
      Workflow_Name__c = FLOW,
      Status__c = 'Running'
    );
    request.config = cfg;
    request.idleMinutes = 15;
    request.thresholdMinutes = 10;

    Messaging.SingleEmailMessage mail = WorkflowAlertManager.buildStallEmail(
      request
    );

    Assert.areEqual(
      new List<String>{ 'a@test.com', 'b@test.com' },
      mail.getToAddresses()
    );
    Assert.isTrue(
      WorkflowAlertManager.lastHtmlBody.contains('Current Step:</td><td>N/A'),
      'A missing step shows N/A.'
    );
  }

  @IsTest
  static void failureAlertStillSendsAfterStallAlert() {
    useConfig(10);
    Workflow_Instance__c inst = stalled('Running', 15);
    Assert.areEqual(1, runSweep());

    WorkflowAlertManager.sentEmailsCount = 0;
    inst.Status__c = 'Failed';
    WorkflowAlertManager.sendAlert(inst, 'Boom');

    Assert.areEqual(1, WorkflowAlertManager.sentEmailsCount, 'Independent.');
  }

  @IsTest
  static void truncatedDeveloperNameMatches() {
    String longName = 'StallTest.' + 'A'.repeat(40);
    String key = longName.replace('.', '_').substring(0, 40);
    WorkflowAlertManager.mockConfigs.put(
      'Default',
      config('Default', true, null, 'ops@test.com', false)
    );
    WorkflowAlertManager.mockConfigs.put(
      key,
      config(key, true, 10, 'ops@test.com', false)
    );
    Workflow_Instance__c inst = stalled('Running', 15);
    inst.Workflow_Name__c = longName;
    update inst;

    Assert.areEqual(1, runSweep(), 'The 40-character key matches.');
  }

  @IsTest
  static void mockNowMovesTheClock() {
    useConfig(10);
    Workflow_Instance__c inst = stalled('Running', 0);
    WorkflowEngine.mockNow = Datetime.now().addMinutes(30);

    Assert.areEqual(1, runSweep(), 'The sweep uses the engine clock.');
    Assert.areEqual(1, stallRows(inst.Id).size());
  }
}
