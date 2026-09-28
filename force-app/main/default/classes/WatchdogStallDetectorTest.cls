/**
 * @description Tests for WatchdogStallDetector (issue #113): one alert per
 * stall, opt-in config, and detection outside the watchdog chain.
 */
@IsTest
private class WatchdogStallDetectorTest {
  private static final Datetime T0 = Datetime.newInstanceGmt(
    2026,
    9,
    28,
    10,
    0,
    0
  );

  private static Workflow_Alert_Config__mdt alertConfig(
    Boolean enabled,
    String recipients,
    Boolean publishEvent
  ) {
    return (Workflow_Alert_Config__mdt) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'DeveloperName' => 'WatchdogWorkflow',
          'Enable_Alerts__c' => enabled,
          'Email_Recipients__c' => recipients,
          'Publish_Alert_Event__c' => publishEvent
        }
      ),
      Workflow_Alert_Config__mdt.class
    );
  }

  private static void enableAlerts() {
    WorkflowAlertManager.mockConfigs.put(
      'WatchdogWorkflow',
      alertConfig(true, 'ops@test.com', true)
    );
  }

  private static void stamp(Datetime sweptAt) {
    insert new Watchdog_Liveness__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Last_Sweep_At__c = sweptAt,
      Cadence_Minutes__c = 10
    );
  }

  private static void resetCounters() {
    WorkflowAlertManager.publishedEvents.clear();
    WorkflowAlertManager.sentEmailsCount = 0;
  }

  private static List<Workflow_Log__c> stallLogs() {
    return [
      SELECT Fire_Key__c, Log_Type__c, Level__c, Workflow_Name__c, Message__c
      FROM Workflow_Log__c
      WHERE Log_Type__c = :WatchdogStallDetector.LOG_TYPE
      ORDER BY CreatedDate ASC, Id ASC
    ];
  }

  @IsTest
  static void staleWatchdogRaisesOneAlert() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      enableAlerts();
      stamp(T0);
      resetCounters();
      WorkflowEngine.mockNow = T0.addMinutes(45);

      Boolean sent = WorkflowAlertManager.detectAndAlertWatchdogStall();

      Assert.isTrue(sent);
      Assert.areEqual(1, WorkflowAlertManager.publishedEvents.size());
      Assert.areEqual(1, WorkflowAlertManager.sentEmailsCount);
      Workflow_Alert__e evt = WorkflowAlertManager.publishedEvents[0];
      Assert.areEqual('WatchdogWorkflow', evt.Workflow_Name__c);
      Assert.areEqual('SystemWatchdog', evt.Correlation_Key__c);
      Assert.areEqual('Watchdog Stall', evt.Alert_Reason__c);
      Assert.areEqual(20, evt.Stall_Threshold_Minutes__c.intValue());
      Assert.isTrue(evt.Error_Message__c.contains('45 min'));

      List<Workflow_Log__c> logs = stallLogs();
      Assert.areEqual(1, logs.size());
      Assert.areEqual('WatchdogStall:' + T0.getTime(), logs[0].Fire_Key__c);
      Assert.areEqual('Error', logs[0].Level__c);
      Assert.areEqual('WatchdogWorkflow', logs[0].Workflow_Name__c);
    }
  }

  @IsTest
  static void repeatedEvaluationDoesNotRepage() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      enableAlerts();
      stamp(T0);
      resetCounters();

      WorkflowEngine.mockNow = T0.addMinutes(45);
      Assert.isTrue(WatchdogStallDetector.detectAndAlert());
      WorkflowEngine.mockNow = T0.addMinutes(90);
      Assert.isFalse(WatchdogStallDetector.detectAndAlert());
      WorkflowEngine.mockNow = T0.addDays(1);
      Assert.isFalse(WatchdogStallDetector.detectAndAlert());

      Assert.areEqual(1, WorkflowAlertManager.publishedEvents.size());
      Assert.areEqual(1, WorkflowAlertManager.sentEmailsCount);
      Assert.areEqual(1, stallLogs().size());
    }
  }

  @IsTest
  static void claimLostToAnotherTransactionSendsNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      enableAlerts();
      stamp(T0);
      insert new Workflow_Log__c(
        Fire_Key__c = 'WatchdogStall:' + T0.getTime(),
        Log_Type__c = WatchdogStallDetector.LOG_TYPE
      );
      resetCounters();
      WorkflowEngine.mockNow = T0.addMinutes(45);

      Assert.isFalse(WatchdogStallDetector.detectAndAlert());
      Assert.areEqual(0, WorkflowAlertManager.publishedEvents.size());
      Assert.areEqual(0, WorkflowAlertManager.sentEmailsCount);
    }
  }

  @IsTest
  static void healthyWatchdogSendsNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      enableAlerts();
      stamp(T0);
      resetCounters();
      WorkflowEngine.mockNow = T0.addMinutes(5);

      Assert.isFalse(WatchdogStallDetector.detectAndAlert());
      Assert.areEqual(0, WorkflowAlertManager.publishedEvents.size());
      Assert.areEqual(0, stallLogs().size());
    }
  }

  @IsTest
  static void unknownLivenessSendsNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      enableAlerts();
      resetCounters();
      WorkflowEngine.mockNow = T0;

      Assert.isFalse(WatchdogStallDetector.detectAndAlert());
      Assert.areEqual(0, stallLogs().size());
    }
  }

  @IsTest
  static void disabledAlertsSendNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      WorkflowAlertManager.mockConfigs.put(
        'WatchdogWorkflow',
        alertConfig(false, 'ops@test.com', true)
      );
      stamp(T0);
      resetCounters();
      WorkflowEngine.mockNow = T0.addMinutes(45);

      Assert.isFalse(WatchdogStallDetector.detectAndAlert());
      Assert.areEqual(0, WorkflowAlertManager.publishedEvents.size());
      Assert.areEqual(0, stallLogs().size(), 'No claim without alerts');
    }
  }

  @IsTest
  static void enabledWithNoChannelSendsNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      WorkflowAlertManager.mockConfigs.put(
        'WatchdogWorkflow',
        alertConfig(true, null, false)
      );
      stamp(T0);
      resetCounters();
      WorkflowEngine.mockNow = T0.addMinutes(45);

      Assert.isFalse(WatchdogStallDetector.detectAndAlert());
      Assert.areEqual(0, stallLogs().size());
    }
  }

  @IsTest
  static void defaultConfigApplies() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      WorkflowAlertManager.mockConfigs.put(
        'Default',
        alertConfig(true, null, true)
      );
      stamp(T0);
      resetCounters();
      WorkflowEngine.mockNow = T0.addMinutes(45);

      Assert.isTrue(WatchdogStallDetector.detectAndAlert());
      Assert.areEqual(1, WorkflowAlertManager.publishedEvents.size());
      Assert.areEqual(0, WorkflowAlertManager.sentEmailsCount, 'No email');
    }
  }

  @IsTest
  static void emailOnlyConfigSendsNoEvent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      WorkflowAlertManager.mockConfigs.put(
        'WatchdogWorkflow',
        alertConfig(true, 'ops@test.com; oncall@test.com', false)
      );
      stamp(T0);
      resetCounters();
      WorkflowEngine.mockNow = T0.addMinutes(45);

      Assert.isTrue(WatchdogStallDetector.detectAndAlert());
      Assert.areEqual(0, WorkflowAlertManager.publishedEvents.size());
      Assert.areEqual(1, WorkflowAlertManager.sentEmailsCount);
      Assert.isTrue(
        WorkflowAlertManager.lastHtmlBody.contains('Watchdog Stalled')
      );
    }
  }

  @IsTest
  static void newStallAfterResumeAlertsAgain() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      enableAlerts();
      stamp(T0);
      resetCounters();

      WorkflowEngine.mockNow = T0.addMinutes(45);
      Assert.isTrue(WatchdogStallDetector.detectAndAlert());

      // The watchdog resumes: a good sweep clears the stall.
      Datetime resumedAt = T0.addMinutes(50);
      WatchdogLiveness.recordSweep(resumedAt, 10);
      WorkflowEngine.mockNow = resumedAt.addMinutes(5);
      Assert.isFalse(WatchdogStallDetector.detectAndAlert());

      // It stops again: a new stall gives one new alert.
      WorkflowEngine.mockNow = resumedAt.addMinutes(40);
      Assert.isTrue(WatchdogStallDetector.detectAndAlert());
      Assert.isFalse(WatchdogStallDetector.detectAndAlert());

      Assert.areEqual(2, WorkflowAlertManager.publishedEvents.size());
      List<Workflow_Log__c> logs = stallLogs();
      Assert.areEqual(2, logs.size());
      Assert.areEqual(
        'WatchdogStall:' + resumedAt.getTime(),
        logs[1].Fire_Key__c
      );
    }
  }

  @IsTest
  static void detectorDoesNotWriteLiveness() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      enableAlerts();
      stamp(T0);
      WorkflowEngine.mockNow = T0.addMinutes(45);

      WatchdogStallDetector.detectAndAlert();

      Watchdog_Liveness__c row = [
        SELECT Last_Sweep_At__c
        FROM Watchdog_Liveness__c
        LIMIT 1
      ];
      Assert.areEqual(T0, row.Last_Sweep_At__c);
    }
  }

  @IsTest
  static void lowDmlBudgetSendsNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      enableAlerts();
      stamp(T0);
      resetCounters();
      WorkflowEngine.mockNow = T0.addMinutes(45);
      WatchdogStallDetector.forceDmlBudgetExhausted = true;

      Assert.isFalse(WatchdogStallDetector.detectAndAlert());
      Assert.areEqual(0, stallLogs().size());
      Assert.areEqual(0, WorkflowAlertManager.publishedEvents.size());
    }
  }

  @IsTest
  static void scheduledBootstrapDetectsDeadWatchdog() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // The watchdog chain is dead. The schedulable entry point still runs
      // the detector: detection does not depend on the watchdog.
      WorkflowEngine.watchdogDelayMinutes = 10;
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowWatchdog.forceBootstrapInTest = true;
      enableAlerts();
      stamp(T0);
      resetCounters();
      WorkflowEngine.mockNow = T0.addMinutes(45);

      Test.startTest();
      new WorkflowWatchdog().execute(null);
      Test.stopTest();

      Assert.areEqual(1, stallLogs().size());
      Assert.areEqual(1, WorkflowAlertManager.publishedEvents.size());
    }
  }
}
