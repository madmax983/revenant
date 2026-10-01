/**
 * @description Tests for ScheduleHealthAlert (issue #126): keys, messages,
 * claim rows, events and the email. No SOQL and no DML.
 */
@IsTest
private class ScheduleHealthAlertTest {
  private static final String TEST_WF = 'WorkflowEngineTest.HappyWorkflow';
  // A fake Id: key prefix + 12 digits. No DML.
  private static final Id SCHED_ID = Id.valueOf(
    Workflow_Schedule__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix() + '1'.leftPad(12, '0')
  );
  private static final Datetime T0 = Datetime.newInstanceGmt(
    2026,
    9,
    28,
    2,
    0,
    0
  );

  private static ScheduleHealth.Assessment assessed(
    Map<String, Object> fields,
    Datetime now
  ) {
    Map<String, Object> all = new Map<String, Object>{
      'Id' => SCHED_ID,
      'Name' => 'Nightly',
      'Workflow_Name__c' => TEST_WF,
      'Correlation_Key_Prefix__c' => 'NightlyKey',
      'Enabled__c' => true,
      'Dedicated_Slot__c' => false,
      'LastModifiedDate' => T0.addDays(-1)
    };
    all.putAll(fields);
    Workflow_Schedule__c sched = (Workflow_Schedule__c) JSON.deserialize(
      JSON.serialize(all),
      Workflow_Schedule__c.class
    );
    return ScheduleHealth.assess(sched, now, 10);
  }

  private static Workflow_Alert_Config__mdt config() {
    return (Workflow_Alert_Config__mdt) JSON.deserialize(
      '{"Enable_Alerts__c":true,"Publish_Alert_Event__c":true}',
      Workflow_Alert_Config__mdt.class
    );
  }

  @IsTest
  static void overdueAlertCarriesKeyMessageClaimAndEvent() {
    ScheduleHealth.Assessment a = assessed(
      new Map<String, Object>{ 'Next_Fire_Window__c' => T0 },
      T0.addMinutes(42)
    );

    ScheduleHealthAlert alert = ScheduleHealthAlert.forOverdue(a, config(), 10);

    Assert.areEqual(
      'ScheduleOverdue:' + SCHED_ID + ':' + T0.getTime(),
      alert.key
    );
    Assert.isTrue(alert.overdue);
    Assert.isTrue(alert.message.contains('"Nightly"'), alert.message);
    Assert.isTrue(
      alert.message.contains('2026-09-28 02:00 UTC'),
      alert.message
    );
    Assert.isTrue(alert.message.contains('Late by 42 min'), alert.message);
    Assert.isTrue(alert.message.contains('Grace: 10 min'), alert.message);

    Workflow_Log__c claim = alert.toClaim();
    Assert.areEqual(alert.claim, claim);
    Assert.areEqual(alert.key, claim.Fire_Key__c);
    Assert.areEqual(ScheduleHealthAlert.LOG_TYPE, claim.Log_Type__c);
    Assert.areEqual(ScheduleHealthAlert.OUTCOME_OVERDUE, claim.Outcome__c);
    Assert.areEqual(SCHED_ID, claim.Schedule__c);
    Assert.areEqual('NightlyKey', claim.Correlation_Key__c);
    Assert.areEqual(T0, claim.Fire_Time__c);

    Workflow_Alert__e evt = alert.toEvent();
    Assert.areEqual(ScheduleHealthAlert.REASON_OVERDUE, evt.Alert_Reason__c);
    Assert.areEqual(TEST_WF, evt.Workflow_Name__c);
    Assert.areEqual('NightlyKey', evt.Correlation_Key__c);
    Assert.areEqual(alert.message, evt.Error_Message__c);
  }

  @IsTest
  static void overdueKeyUsesTheReferenceWhenTheCursorIsBlank() {
    ScheduleHealth.Assessment a = assessed(
      new Map<String, Object>(),
      T0.addDays(1)
    );

    ScheduleHealthAlert alert = ScheduleHealthAlert.forOverdue(a, config(), 10);

    Assert.areEqual(
      'ScheduleOverdue:' + SCHED_ID + ':' + T0.addDays(-1).getTime(),
      alert.key
    );
    Assert.isTrue(alert.message.contains('Expected window: none'));
  }

  @IsTest
  static void failedAlertKeysOnOutcomeAndLastGoodFire() {
    ScheduleHealth.Assessment a = assessed(
      new Map<String, Object>{
        'Next_Fire_Window__c' => T0.addDays(1),
        'Last_Fired_Window__c' => T0,
        'Last_Outcome__c' => 'Error'
      },
      T0
    );

    Datetime lastGood = T0.addDays(-2);
    ScheduleHealthAlert alert = ScheduleHealthAlert.forFailed(
      a,
      config(),
      lastGood
    );

    Assert.areEqual(
      'ScheduleFailed:' + SCHED_ID + ':Error:' + lastGood.getTime(),
      alert.key
    );
    Assert.isTrue(
      alert.message.contains('Last window: 2026-09-28 02:00 UTC'),
      alert.message
    );
    Assert.isFalse(alert.overdue);
    Assert.isTrue(alert.message.contains('Last outcome: Error'));
    Assert.areEqual(
      ScheduleHealthAlert.OUTCOME_FAILED,
      alert.toClaim().Outcome__c
    );
    Assert.areEqual(
      ScheduleHealthAlert.REASON_FAILED,
      alert.toEvent().Alert_Reason__c
    );
  }

  @IsTest
  static void failedKeyUsesZeroWithoutAGoodFire() {
    ScheduleHealth.Assessment a = assessed(
      new Map<String, Object>{
        'Next_Fire_Window__c' => T0.addDays(1),
        'Last_Outcome__c' => 'Invalid cron'
      },
      T0
    );

    Assert.areEqual(
      'ScheduleFailed:' + SCHED_ID + ':Invalid cron:0',
      ScheduleHealthAlert.forFailed(a, config(), null).key
    );
  }

  @IsTest
  static void emailListsEachAlertAndEscapesHtml() {
    ScheduleHealth.Assessment a = assessed(
      new Map<String, Object>{
        'Name' => '<b>Tag</b>',
        'Next_Fire_Window__c' => T0
      },
      T0.addHours(1)
    );
    List<ScheduleHealthAlert> alerts = new List<ScheduleHealthAlert>{
      ScheduleHealthAlert.forOverdue(a, config(), 10),
      ScheduleHealthAlert.forFailed(a, config(), null)
    };

    Messaging.SingleEmailMessage mail = ScheduleHealthAlert.buildEmail(
      'a@test.com; b@test.com',
      alerts
    );

    Assert.isNotNull(mail);
    Assert.areEqual(2, mail.getToAddresses().size());
    Assert.isTrue(mail.getSubject().contains('2 problem(s)'));
    Assert.isTrue(mail.getHtmlBody().contains('&lt;b&gt;Tag&lt;/b&gt;'));
    Assert.isFalse(mail.getHtmlBody().contains('<b>Tag</b>'));
  }

  @IsTest
  static void emailIsNullWithoutRecipientsOrAlerts() {
    ScheduleHealth.Assessment a = assessed(
      new Map<String, Object>{ 'Next_Fire_Window__c' => T0 },
      T0.addHours(1)
    );
    List<ScheduleHealthAlert> alerts = new List<ScheduleHealthAlert>{
      ScheduleHealthAlert.forOverdue(a, config(), 10)
    };

    Assert.isNull(ScheduleHealthAlert.buildEmail(' , ', alerts));
    Assert.isNull(
      ScheduleHealthAlert.buildEmail(
        'a@test.com',
        new List<ScheduleHealthAlert>()
      )
    );
    Assert.isNull(ScheduleHealthAlert.buildEmail(null, alerts));
  }

  /**
   * @description Invalid addresses are skipped. A malformed-only list sends nothing (#265).
   */
  @IsTest
  static void emailSkipsInvalidAddresses() {
    ScheduleHealth.Assessment a = assessed(
      new Map<String, Object>{ 'Next_Fire_Window__c' => T0 },
      T0.addHours(1)
    );
    List<ScheduleHealthAlert> alerts = new List<ScheduleHealthAlert>{
      ScheduleHealthAlert.forOverdue(a, config(), 10)
    };

    Messaging.SingleEmailMessage mail = ScheduleHealthAlert.buildEmail(
      'a@test.com; bad',
      alerts
    );
    Assert.areEqual(new List<String>{ 'a@test.com' }, mail.getToAddresses());
    Assert.isNull(ScheduleHealthAlert.buildEmail('bad', alerts));
  }

  private static Workflow_Alert_Config__mdt emailConfig(String recipients) {
    return (Workflow_Alert_Config__mdt) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'Enable_Alerts__c' => true,
          'Email_Recipients__c' => recipients
        }
      ),
      Workflow_Alert_Config__mdt.class
    );
  }

  @IsTest
  static void groupsAlertsByRecipientList() {
    ScheduleHealth.Assessment a = assessed(
      new Map<String, Object>{ 'Next_Fire_Window__c' => T0 },
      T0.addHours(1)
    );
    List<ScheduleHealthAlert> alerts = new List<ScheduleHealthAlert>{
      ScheduleHealthAlert.forOverdue(a, emailConfig('a@test.com'), 10),
      ScheduleHealthAlert.forFailed(a, emailConfig('a@test.com'), null),
      ScheduleHealthAlert.forOverdue(a, emailConfig('b@test.com'), 10),
      ScheduleHealthAlert.forOverdue(a, config(), 10),
      ScheduleHealthAlert.forOverdue(a, emailConfig(' ; '), 10)
    };

    Map<String, List<ScheduleHealthAlert>> groups = ScheduleHealthAlert.groupByRecipients(
      alerts
    );

    Assert.areEqual(
      2,
      groups.size(),
      'An alert with no recipient or only separators is left out'
    );
    Assert.areEqual(2, groups.get('a@test.com').size());
    Assert.areEqual(1, groups.get('b@test.com').size());
  }

  @IsTest
  static void markAllSentMarksEachAlert() {
    ScheduleHealth.Assessment a = assessed(
      new Map<String, Object>{ 'Next_Fire_Window__c' => T0 },
      T0.addHours(1)
    );
    List<ScheduleHealthAlert> alerts = new List<ScheduleHealthAlert>{
      ScheduleHealthAlert.forOverdue(a, config(), 10),
      ScheduleHealthAlert.forFailed(a, config(), null)
    };
    Assert.isFalse(alerts[0].sent);

    ScheduleHealthAlert.markAllSent(alerts);

    Assert.isTrue(alerts[0].sent);
    Assert.isTrue(alerts[1].sent);
  }

  @IsTest
  static void neverTriedAlertsSortFirstThenOldestAttempt() {
    ScheduleHealth.Assessment a = assessed(
      new Map<String, Object>{ 'Next_Fire_Window__c' => T0 },
      T0.addHours(1)
    );
    ScheduleHealthAlert recent = ScheduleHealthAlert.forOverdue(
      a,
      config(),
      10
    );
    ScheduleHealthAlert older = ScheduleHealthAlert.forOverdue(a, config(), 10);
    ScheduleHealthAlert fresh = ScheduleHealthAlert.forOverdue(a, config(), 10);
    ScheduleHealthAlert fresher = ScheduleHealthAlert.forOverdue(
      a,
      config(),
      10
    );
    recent.setQueueData(0, T0.addMinutes(20));
    older.setQueueData(1, T0.addMinutes(10));
    fresh.setQueueData(2, null);
    fresher.setQueueData(3, null);
    List<ScheduleHealthAlert> alerts = new List<ScheduleHealthAlert>{
      recent,
      older,
      fresher,
      fresh
    };

    alerts.sort();

    Assert.areEqual(fresh, alerts[0]);
    Assert.areEqual(fresher, alerts[1]);
    Assert.areEqual(older, alerts[2]);
    Assert.areEqual(recent, alerts[3]);
  }

  @IsTest
  static void attemptRowCarriesItsOwnKey() {
    ScheduleHealth.Assessment a = assessed(
      new Map<String, Object>{ 'Next_Fire_Window__c' => T0 },
      T0.addHours(1)
    );
    ScheduleHealthAlert alert = ScheduleHealthAlert.forOverdue(a, config(), 10);

    Workflow_Log__c row = alert.toAttempt(T0.addHours(1));

    Assert.areEqual(alert.key + ':attempt', row.Fire_Key__c);
    Assert.areEqual(alert.attemptKey(), row.Fire_Key__c);
    Assert.areEqual(ScheduleHealthAlert.ATTEMPT_LOG_TYPE, row.Log_Type__c);
    Assert.areEqual(T0.addHours(1), row.Fire_Time__c);
    Assert.isNull(row.Schedule__c, 'Attempt rows stay out of View Logs');
  }
}
