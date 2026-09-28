/**
 * @description Tests for ScheduleHealthAlerter (issue #126): one alert per
 * problem, config resolution, claim release and read-only behavior.
 */
@IsTest
private class ScheduleHealthAlerterTest {
  private static final String TEST_WF = 'WorkflowEngineTest.HappyWorkflow';
  private static final String TEST_WF_DEV_NAME = 'WorkflowEngineTest_HappyWorkflow';

  // An enabled config. A blank recipient list turns email off.
  private static Workflow_Alert_Config__mdt alertConfig(
    String recipients,
    Boolean publishEvent
  ) {
    return config(true, recipients, publishEvent);
  }

  private static Workflow_Alert_Config__mdt config(
    Boolean enabled,
    String recipients,
    Boolean publishEvent
  ) {
    return (Workflow_Alert_Config__mdt) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'Enable_Alerts__c' => enabled,
          'Email_Recipients__c' => recipients,
          'Publish_Alert_Event__c' => publishEvent
        }
      ),
      Workflow_Alert_Config__mdt.class
    );
  }

  private static void enableDefaultAlerts() {
    WorkflowAlertManager.mockConfigs.put(
      'Default',
      alertConfig('ops@test.com', true)
    );
  }

  private static void setUp() {
    WorkflowEngine.watchdogDelayMinutes = 10;
    WorkflowAlertManager.publishedEvents.clear();
    WorkflowAlertManager.sentEmailsCount = 0;
  }

  // Thirty minutes after the insert: more than one interval later.
  private static Datetime later() {
    return System.now().addMinutes(30);
  }

  private static Workflow_Schedule__c insertSchedule(
    String name,
    Map<String, Object> fields
  ) {
    Workflow_Schedule__c sched = new Workflow_Schedule__c(
      Name = name,
      Workflow_Name__c = TEST_WF,
      Cron_Expression__c = '0 2 * * *',
      Correlation_Key_Prefix__c = name + 'Key',
      Enabled__c = true,
      Dedicated_Slot__c = false
    );
    for (String field : fields.keySet()) {
      sched.put(field, fields.get(field));
    }
    insert sched;
    return [
      SELECT
        Id,
        Name,
        Next_Fire_Window__c,
        Last_Fired_Window__c,
        Last_Outcome__c,
        SystemModstamp
      FROM Workflow_Schedule__c
      WHERE Id = :sched.Id
    ];
  }

  private static Workflow_Schedule__c insertOverdue(String name) {
    return insertSchedule(
      name,
      new Map<String, Object>{
        'Next_Fire_Window__c' => System.now().addHours(-2)
      }
    );
  }

  private static Workflow_Schedule__c insertFailed(String name) {
    return insertSchedule(
      name,
      new Map<String, Object>{
        'Next_Fire_Window__c' => System.now().addDays(1),
        'Last_Fired_Window__c' => System.now().addHours(-1),
        'Last_Outcome__c' => 'Error'
      }
    );
  }

  private static List<Workflow_Log__c> claims() {
    return [
      SELECT
        Fire_Key__c,
        Level__c,
        Outcome__c,
        Schedule__c,
        Schedule_Name__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Message__c
      FROM Workflow_Log__c
      WHERE Log_Type__c = :ScheduleHealthAlert.LOG_TYPE
      ORDER BY Fire_Key__c ASC
    ];
  }

  @IsTest
  static void overdueScheduleRaisesOneAlert() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      Workflow_Schedule__c sched = insertOverdue('Nightly');

      Integer sent = ScheduleHealthAlerter.detectAndAlert(later());

      Assert.areEqual(1, sent);
      Assert.areEqual(1, WorkflowAlertManager.sentEmailsCount);
      Assert.areEqual(1, WorkflowAlertManager.publishedEvents.size());
      Workflow_Alert__e evt = WorkflowAlertManager.publishedEvents[0];
      Assert.areEqual(ScheduleHealthAlert.REASON_OVERDUE, evt.Alert_Reason__c);
      Assert.areEqual(TEST_WF, evt.Workflow_Name__c);
      Assert.areEqual('NightlyKey', evt.Correlation_Key__c);
      Assert.isTrue(evt.Error_Message__c.contains('Nightly'));
      Assert.isTrue(evt.Error_Message__c.contains('overdue'));

      List<Workflow_Log__c> logs = claims();
      Assert.areEqual(1, logs.size());
      Assert.areEqual(
        'ScheduleOverdue:' +
          sched.Id +
          ':' +
          sched.Next_Fire_Window__c.getTime(),
        logs[0].Fire_Key__c
      );
      Assert.areEqual(sched.Id, logs[0].Schedule__c);
      Assert.areEqual('Nightly', logs[0].Schedule_Name__c);
      Assert.areEqual(ScheduleHealthAlert.OUTCOME_OVERDUE, logs[0].Outcome__c);
      Assert.areEqual('Error', logs[0].Level__c);
      Assert.isTrue(
        WorkflowAlertManager.lastHtmlBody.contains('Nightly'),
        'The email names the schedule'
      );
    }
  }

  @IsTest
  static void persistentMissDoesNotRepageOnEachSweep() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      insertOverdue('Nightly');

      Assert.areEqual(1, ScheduleHealthAlerter.detectAndAlert(later()));
      Assert.areEqual(
        0,
        ScheduleHealthAlerter.detectAndAlert(later().addMinutes(10))
      );
      Assert.areEqual(
        0,
        ScheduleHealthAlerter.detectAndAlert(later().addHours(6))
      );

      Assert.areEqual(1, WorkflowAlertManager.publishedEvents.size());
      Assert.areEqual(1, WorkflowAlertManager.sentEmailsCount);
      Assert.areEqual(1, claims().size());
    }
  }

  @IsTest
  static void failedFireRaisesDistinctAlert() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      Workflow_Schedule__c sched = insertFailed('Sync');

      Assert.areEqual(1, ScheduleHealthAlerter.detectAndAlert(later()));

      Workflow_Alert__e evt = WorkflowAlertManager.publishedEvents[0];
      Assert.areEqual(ScheduleHealthAlert.REASON_FAILED, evt.Alert_Reason__c);
      Assert.isTrue(evt.Error_Message__c.contains('Error'));
      List<Workflow_Log__c> logs = claims();
      // No Started or Skipped fire log exists, so the streak key ends in 0.
      Assert.areEqual(
        'ScheduleFailed:' + sched.Id + ':Error:0',
        logs[0].Fire_Key__c
      );
      Assert.areEqual(ScheduleHealthAlert.OUTCOME_FAILED, logs[0].Outcome__c);
    }
  }

  @IsTest
  static void overdueAndFailedSendTwoAlertsInOneEmail() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      insertSchedule(
        'Both',
        new Map<String, Object>{
          'Next_Fire_Window__c' => System.now().addHours(-2),
          'Last_Outcome__c' => 'Invalid cron'
        }
      );

      Assert.areEqual(2, ScheduleHealthAlerter.detectAndAlert(later()));

      Assert.areEqual(1, WorkflowAlertManager.sentEmailsCount);
      Set<String> reasons = new Set<String>();
      for (Workflow_Alert__e evt : WorkflowAlertManager.publishedEvents) {
        reasons.add(evt.Alert_Reason__c);
      }
      Assert.areEqual(
        new Set<String>{
          ScheduleHealthAlert.REASON_OVERDUE,
          ScheduleHealthAlert.REASON_FAILED
        },
        reasons
      );
      Assert.areEqual(2, claims().size());
    }
  }

  @IsTest
  static void newMissAfterRecoveryAlertsAgain() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      Workflow_Schedule__c sched = insertOverdue('Hourly');
      Assert.areEqual(1, ScheduleHealthAlerter.detectAndAlert(later()));

      // The sweep fires again, then the next window is also missed.
      update new Workflow_Schedule__c(
        Id = sched.Id,
        Next_Fire_Window__c = System.now().addHours(-1)
      );

      Assert.areEqual(
        1,
        ScheduleHealthAlerter.detectAndAlert(later().addMinutes(10))
      );
      Assert.areEqual(2, WorkflowAlertManager.publishedEvents.size());
      Assert.areEqual(2, claims().size());
    }
  }

  @IsTest
  static void disabledScheduleNeverAlerts() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      insertSchedule(
        'Paused',
        new Map<String, Object>{
          'Enabled__c' => false,
          'Next_Fire_Window__c' => System.now().addDays(-3),
          'Last_Outcome__c' => 'Error'
        }
      );

      Assert.areEqual(0, ScheduleHealthAlerter.detectAndAlert(later()));
      Assert.areEqual(0, WorkflowAlertManager.publishedEvents.size());
      Assert.areEqual(0, claims().size());
    }
  }

  @IsTest
  static void noConfigSendsNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      // A null mock hides any Default record in the org.
      WorkflowAlertManager.mockConfigs.put('Default', null);
      insertOverdue('NoConfig');

      Assert.areEqual(0, ScheduleHealthAlerter.detectAndAlert(later()));
      Assert.areEqual(0, claims().size());
    }
  }

  @IsTest
  static void disabledConfigSendsNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      WorkflowAlertManager.mockConfigs.put(
        'Default',
        config(false, 'ops@test.com', true)
      );
      insertOverdue('Off');

      Assert.areEqual(0, ScheduleHealthAlerter.detectAndAlert(later()));
      Assert.areEqual(0, claims().size());
    }
  }

  @IsTest
  static void workflowConfigWinsOverDefault() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      WorkflowAlertManager.mockConfigs.put(
        'Default',
        config(false, null, false)
      );
      WorkflowAlertManager.mockConfigs.put(
        TEST_WF_DEV_NAME,
        alertConfig(null, true)
      );
      insertOverdue('ByName');

      Assert.areEqual(1, ScheduleHealthAlerter.detectAndAlert(later()));
      Assert.areEqual(1, WorkflowAlertManager.publishedEvents.size());
      Assert.areEqual(0, WorkflowAlertManager.sentEmailsCount);
    }
  }

  @IsTest
  static void defaultConfigIsTheFallback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      WorkflowAlertManager.mockConfigs.put(
        'Default',
        alertConfig('ops@test.com', false)
      );
      insertOverdue('Fallback');

      Assert.areEqual(1, ScheduleHealthAlerter.detectAndAlert(later()));
      Assert.areEqual(1, WorkflowAlertManager.sentEmailsCount);
      Assert.areEqual(0, WorkflowAlertManager.publishedEvents.size());
    }
  }

  @IsTest
  static void unsentAlertReleasesItsClaim() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      WorkflowAlertManager.mockConfigs.put(
        'Default',
        alertConfig('ops@test.com', false)
      );
      insertOverdue('Retry');

      WorkflowAlertManager.throwTestException = true;
      Assert.areEqual(0, ScheduleHealthAlerter.detectAndAlert(later()));
      Assert.areEqual(0, claims().size(), 'The claim is released');

      WorkflowAlertManager.throwTestException = false;
      Assert.areEqual(
        1,
        ScheduleHealthAlerter.detectAndAlert(later().addMinutes(10))
      );
      Assert.areEqual(1, claims().size());
    }
  }

  @IsTest
  static void claimTakenByAnotherTransactionSendsNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      Workflow_Schedule__c sched = insertOverdue('Race');
      insert new Workflow_Log__c(
        Fire_Key__c = 'ScheduleOverdue:' +
          sched.Id +
          ':' +
          sched.Next_Fire_Window__c.getTime(),
        Log_Type__c = ScheduleHealthAlert.LOG_TYPE
      );

      Assert.areEqual(0, ScheduleHealthAlerter.detectAndAlert(later()));
      Assert.areEqual(0, WorkflowAlertManager.publishedEvents.size());
      Assert.areEqual(0, WorkflowAlertManager.sentEmailsCount);
    }
  }

  @IsTest
  static void alertsPerSweepAreCapped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      ScheduleHealthAlerter.maxAlertsPerSweep = 2;
      insertOverdue('CapA');
      insertOverdue('CapB');
      insertOverdue('CapC');

      Assert.areEqual(2, ScheduleHealthAlerter.detectAndAlert(later()));
      Assert.areEqual(
        1,
        ScheduleHealthAlerter.detectAndAlert(later().addMinutes(10)),
        'The next sweep sends the rest'
      );
      Assert.areEqual(3, claims().size());
    }
  }

  @IsTest
  static void failingChannelDoesNotStarveLaterAlerts() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      // A recipient list with no valid address: the email never sends.
      WorkflowAlertManager.mockConfigs.put(
        'BrokenFlow',
        alertConfig(' ; ', false)
      );
      ScheduleHealthAlerter.maxAlertsPerSweep = 1;
      // The broken schedule has the oldest cursor, so it is first in the list.
      insertSchedule(
        'Broken',
        new Map<String, Object>{
          'Workflow_Name__c' => 'BrokenFlow',
          'Next_Fire_Window__c' => System.now().addHours(-3)
        }
      );
      Workflow_Schedule__c good = insertOverdue('Good');

      // Two sweeps one minute apart start at different positions.
      Datetime first = later();
      ScheduleHealthAlerter.detectAndAlert(first);
      ScheduleHealthAlerter.detectAndAlert(first.addMinutes(1));

      List<Workflow_Log__c> logs = claims();
      Assert.areEqual(1, logs.size(), String.valueOf(logs));
      Assert.areEqual(good.Id, logs[0].Schedule__c);
      Assert.areEqual(1, WorkflowAlertManager.publishedEvents.size());
    }
  }

  @IsTest
  static void lowBudgetSendsNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      insertOverdue('Budget');
      ScheduleHealthAlerter.forceBudgetExhausted = true;

      Assert.areEqual(0, ScheduleHealthAlerter.detectAndAlert(later()));
      Assert.areEqual(0, claims().size());
    }
  }

  @IsTest
  static void detectionDoesNotWriteInstancesStepsOrSchedules() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      Workflow_Schedule__c sched = insertOverdue('ReadOnly');
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = TEST_WF,
        Status__c = 'Failed',
        Correlation_Key__c = 'ReadOnlyKey_1'
      );
      insert inst;
      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.HappyStep1',
        Status__c = 'Failed',
        Retry_Count__c = 0
      );
      insert step;
      Integer stepCount = [SELECT COUNT() FROM Workflow_Step_Execution__c];
      Integer instCount = [SELECT COUNT() FROM Workflow_Instance__c];
      Integer dmlBefore = Limits.getDmlStatements();

      Assert.areEqual(1, ScheduleHealthAlerter.detectAndAlert(later()));

      Assert.areEqual(
        2,
        Limits.getDmlStatements() - dmlBefore,
        'Only the claim insert and the event publish'
      );
      Workflow_Schedule__c after = [
        SELECT
          Next_Fire_Window__c,
          Last_Fired_Window__c,
          Last_Outcome__c,
          Enabled__c
        FROM Workflow_Schedule__c
        WHERE Id = :sched.Id
      ];
      Assert.areEqual(sched.Next_Fire_Window__c, after.Next_Fire_Window__c);
      Assert.areEqual(sched.Last_Fired_Window__c, after.Last_Fired_Window__c);
      Assert.areEqual(sched.Last_Outcome__c, after.Last_Outcome__c);
      Assert.isTrue(after.Enabled__c);
      Assert.areEqual(
        'Failed',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id]
        .Status__c
      );
      Assert.areEqual(
        'Failed',
        [SELECT Status__c FROM Workflow_Step_Execution__c WHERE Id = :step.Id]
        .Status__c
      );
      Assert.areEqual(
        stepCount,
        [SELECT COUNT() FROM Workflow_Step_Execution__c]
      );
      Assert.areEqual(instCount, [SELECT COUNT() FROM Workflow_Instance__c]);
    }
  }

  @IsTest
  static void failureStreakSendsOneAlert() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      Workflow_Schedule__c sched = insertFailed('Streak');
      Assert.areEqual(1, ScheduleHealthAlerter.detectAndAlert(later()));

      // The next window also fails with the same outcome.
      update new Workflow_Schedule__c(
        Id = sched.Id,
        Last_Fired_Window__c = System.now()
      );
      Assert.areEqual(
        0,
        ScheduleHealthAlerter.detectAndAlert(later().addHours(1)),
        'A failure streak sends one alert'
      );

      // A good fire ends the streak. The next failure is a new problem.
      insert new Workflow_Log__c(
        Fire_Key__c = 'StreakKey_1:Started',
        Log_Type__c = 'ScheduleFire',
        Outcome__c = 'Started',
        Schedule__c = sched.Id
      );
      Assert.areEqual(
        1,
        ScheduleHealthAlerter.detectAndAlert(later().addHours(2))
      );
      Assert.areEqual(2, claims().size());
    }
  }

  @IsTest
  static void failedPublishReleasesAnEventOnlyClaim() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      WorkflowAlertManager.mockConfigs.put('Default', alertConfig(null, true));
      WorkflowAlertManager.forceDmlBudgetExhausted = true;
      insertOverdue('NoPublish');

      Assert.areEqual(0, ScheduleHealthAlerter.detectAndAlert(later()));
      Assert.areEqual(0, claims().size(), 'The claim is released');
    }
  }

  @IsTest
  static void sentEmailKeepsTheClaimWhenPublishFails() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      WorkflowAlertManager.forceDmlBudgetExhausted = true;
      insertOverdue('EmailOnly');

      Assert.areEqual(1, ScheduleHealthAlerter.detectAndAlert(later()));
      Assert.areEqual(1, WorkflowAlertManager.sentEmailsCount);
      Assert.areEqual(1, claims().size());
    }
  }

  @IsTest
  static void eachRecipientListGetsOneEmail() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      WorkflowAlertManager.mockConfigs.put(
        TEST_WF_DEV_NAME,
        alertConfig('a@test.com', false)
      );
      WorkflowAlertManager.mockConfigs.put(
        'OtherFlow',
        alertConfig('b@test.com', false)
      );
      insertOverdue('ListA1');
      insertOverdue('ListA2');
      insertSchedule(
        'ListB',
        new Map<String, Object>{
          'Workflow_Name__c' => 'OtherFlow',
          'Next_Fire_Window__c' => System.now().addHours(-2)
        }
      );

      Assert.areEqual(3, ScheduleHealthAlerter.detectAndAlert(later()));
      Assert.areEqual(2, WorkflowAlertManager.sentEmailsCount);
    }
  }

  @IsTest
  static void nullTimeSendsNothing() {
    Assert.areEqual(0, ScheduleHealthAlerter.detectAndAlert(null));
  }

  @IsTest
  static void heartbeatReseedsACursorLeftByASetupEdit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      WorkflowEngine.disableQueueableInTest = true;
      // The cron was edited in Setup: the last window is handled, but the
      // cursor still points to a past window of the old cron.
      String cron = '0 0 1 1 *';
      Workflow_Schedule__c sched = insertSchedule(
        'SetupEdit',
        new Map<String, Object>{
          'Cron_Expression__c' => cron,
          'Last_Fired_Window__c' => WorkflowCronEvaluator.previousFireTime(
            cron,
            System.now()
          ),
          'Last_Outcome__c' => 'Started',
          'Next_Fire_Window__c' => System.now().addHours(-1)
        }
      );
      WorkflowEngine.mockNow = later();

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      Assert.areEqual(0, claims().size(), 'A healthy schedule is not reported');
      Datetime cursor = [
        SELECT Next_Fire_Window__c
        FROM Workflow_Schedule__c
        WHERE Id = :sched.Id
      ]
      .Next_Fire_Window__c;
      Assert.isTrue(cursor > System.now(), 'The sweep reseeds the cursor');
    }
  }

  @IsTest
  static void detectionAddsNoScheduledJobs() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      insertOverdue('NoSlot');
      Integer jobsBefore = [SELECT COUNT() FROM CronTrigger];

      Assert.areEqual(1, ScheduleHealthAlerter.detectAndAlert(later()));

      Assert.areEqual(jobsBefore, [SELECT COUNT() FROM CronTrigger]);
    }
  }

  @IsTest
  static void heartbeatAlertsStarvedSchedule() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      WorkflowEngine.disableQueueableInTest = true;
      // The sweep takes one row. The older cursor goes first. A yearly cron
      // puts the next window of "First" far after "now".
      WorkflowScheduleSweeper.sweepBatchSize = 1;
      insertSchedule(
        'First',
        new Map<String, Object>{
          'Cron_Expression__c' => '0 0 1 1 *',
          'Next_Fire_Window__c' => System.now().addHours(-3)
        }
      );
      Workflow_Schedule__c starved = insertOverdue('Starved');
      WorkflowEngine.mockNow = later();
      Integer jobsBefore = [SELECT COUNT() FROM CronTrigger];

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      List<Workflow_Log__c> logs = claims();
      Assert.areEqual(1, logs.size(), String.valueOf(logs));
      Assert.areEqual(starved.Id, logs[0].Schedule__c);
      Assert.areEqual(ScheduleHealthAlert.OUTCOME_OVERDUE, logs[0].Outcome__c);
      Assert.areEqual(jobsBefore, [SELECT COUNT() FROM CronTrigger]);
    }
  }

  @IsTest
  static void heartbeatAlertsImpossibleCron() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      setUp();
      enableDefaultAlerts();
      WorkflowEngine.disableQueueableInTest = true;
      // "0 0 31 2 *" never fires. The sweep parks it as "Invalid cron".
      Workflow_Schedule__c sched = insertSchedule(
        'Feb31',
        new Map<String, Object>{ 'Cron_Expression__c' => '0 0 31 2 *' }
      );

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      List<Workflow_Log__c> logs = claims();
      Assert.areEqual(1, logs.size(), String.valueOf(logs));
      Assert.areEqual(sched.Id, logs[0].Schedule__c);
      Assert.areEqual(ScheduleHealthAlert.OUTCOME_FAILED, logs[0].Outcome__c);
      Assert.isTrue(logs[0].Fire_Key__c.contains(':Invalid cron:'));
    }
  }
}
