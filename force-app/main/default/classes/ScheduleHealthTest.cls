/**
 * @description Tests for ScheduleHealth (issue #126): the overdue and
 * last-fire-failed rules, the SOQL finder and the dashboard summary.
 */
@IsTest
private class ScheduleHealthTest {
  private static final String TEST_WF = 'WorkflowEngineTest.HappyWorkflow';
  private static final Integer GRACE = 10;
  private static final Datetime T0 = Datetime.newInstanceGmt(
    2026,
    9,
    28,
    10,
    0,
    0
  );

  // Builds an in-memory schedule. JSON lets the test set LastModifiedDate.
  private static Workflow_Schedule__c row(Map<String, Object> fields) {
    Map<String, Object> all = new Map<String, Object>{
      'Name' => 'S',
      'Workflow_Name__c' => TEST_WF,
      'Cron_Expression__c' => '0 * * * *',
      'Enabled__c' => true,
      'Dedicated_Slot__c' => false
    };
    all.putAll(fields);
    return (Workflow_Schedule__c) JSON.deserialize(
      JSON.serialize(all),
      Workflow_Schedule__c.class
    );
  }

  private static ScheduleHealth.Assessment assessAt(
    Workflow_Schedule__c sched,
    Datetime now
  ) {
    return ScheduleHealth.assess(sched, now, GRACE);
  }

  @IsTest
  static void overdueWhenCursorLapsesPastOneInterval() {
    Workflow_Schedule__c sched = row(
      new Map<String, Object>{
        'Next_Fire_Window__c' => T0,
        'LastModifiedDate' => T0.addHours(-1)
      }
    );

    ScheduleHealth.Assessment a = assessAt(sched, T0.addMinutes(11));

    Assert.isTrue(a.overdue);
    Assert.isFalse(a.lastFireFailed);
    Assert.areEqual(ScheduleHealth.STATUS_OVERDUE, a.status);
    Assert.areEqual(11, a.lapsedMinutes);
    Assert.areEqual(T0, a.reference);
  }

  @IsTest
  static void notOverdueAtExactlyOneInterval() {
    Workflow_Schedule__c sched = row(
      new Map<String, Object>{
        'Next_Fire_Window__c' => T0,
        'LastModifiedDate' => T0.addHours(-1)
      }
    );

    ScheduleHealth.Assessment a = assessAt(sched, T0.addMinutes(GRACE));

    Assert.isFalse(a.overdue, 'The rule is "more than" one interval');
    Assert.areEqual(ScheduleHealth.STATUS_OK, a.status);
    Assert.isNull(a.lapsedMinutes);
  }

  @IsTest
  static void disabledScheduleIsNeverReported() {
    Workflow_Schedule__c sched = row(
      new Map<String, Object>{
        'Enabled__c' => false,
        'Next_Fire_Window__c' => T0.addDays(-3),
        'LastModifiedDate' => T0.addDays(-3),
        'Last_Outcome__c' => 'Error'
      }
    );

    ScheduleHealth.Assessment a = assessAt(sched, T0);

    Assert.isFalse(a.overdue);
    Assert.isFalse(a.lastFireFailed);
    Assert.areEqual(ScheduleHealth.STATUS_DISABLED, a.status);
  }

  @IsTest
  static void dedicatedScheduleIsNotOverdueButCanFail() {
    Workflow_Schedule__c lapsed = row(
      new Map<String, Object>{
        'Dedicated_Slot__c' => true,
        'Next_Fire_Window__c' => T0.addHours(-5),
        'LastModifiedDate' => T0.addHours(-5)
      }
    );
    Workflow_Schedule__c failed = row(
      new Map<String, Object>{
        'Dedicated_Slot__c' => true,
        'Next_Fire_Window__c' => T0.addHours(1),
        'Last_Outcome__c' => 'Error'
      }
    );

    Assert.areEqual(
      ScheduleHealth.STATUS_OK,
      assessAt(lapsed, T0).status,
      'A CronTrigger zone can differ from Time_Zone__c'
    );
    Assert.areEqual(ScheduleHealth.STATUS_FAILED, assessAt(failed, T0).status);
  }

  @IsTest
  static void handledWindowIsNotOverdue() {
    Workflow_Schedule__c sched = row(
      new Map<String, Object>{
        'Next_Fire_Window__c' => T0,
        'Last_Fired_Window__c' => T0,
        'LastModifiedDate' => T0.addHours(-1)
      }
    );

    Assert.isFalse(assessAt(sched, T0.addHours(1)).overdue);
  }

  @IsTest
  static void recentEditGivesOneIntervalOfGrace() {
    // An old cursor on a schedule enabled outside the UI.
    Workflow_Schedule__c sched = row(
      new Map<String, Object>{
        'Next_Fire_Window__c' => T0.addHours(-2),
        'LastModifiedDate' => T0
      }
    );

    Assert.isFalse(assessAt(sched, T0.addMinutes(5)).overdue);
    ScheduleHealth.Assessment late = assessAt(sched, T0.addMinutes(11));
    Assert.isTrue(late.overdue);
    Assert.areEqual(T0, late.reference);
    Assert.areEqual(11, late.lapsedMinutes);
  }

  @IsTest
  static void blankCursorUsesLastModifiedDate() {
    Workflow_Schedule__c sched = row(
      new Map<String, Object>{ 'LastModifiedDate' => T0 }
    );

    Assert.isFalse(assessAt(sched, T0.addMinutes(5)).overdue);
    Assert.isTrue(assessAt(sched, T0.addMinutes(11)).overdue);
  }

  @IsTest
  static void noReferenceIsNotOverdue() {
    Workflow_Schedule__c sched = row(new Map<String, Object>());

    Assert.areEqual(ScheduleHealth.STATUS_OK, assessAt(sched, T0).status);
  }

  @IsTest
  static void onlyFailureOutcomesAreFailed() {
    for (
      String outcome : new List<String>{
        'Error',
        'Invalid cron',
        'Invalid time zone'
      }
    ) {
      ScheduleHealth.Assessment a = assessAt(
        row(
          new Map<String, Object>{
            'Next_Fire_Window__c' => T0.addHours(1),
            'Last_Outcome__c' => outcome
          }
        ),
        T0
      );
      Assert.isTrue(a.lastFireFailed, outcome);
      Assert.areEqual(ScheduleHealth.STATUS_FAILED, a.status, outcome);
    }
    for (
      String outcome : new List<String>{ 'Started', 'Skipped', 'Deduped', null }
    ) {
      ScheduleHealth.Assessment a = assessAt(
        row(
          new Map<String, Object>{
            'Next_Fire_Window__c' => T0.addHours(1),
            'Last_Outcome__c' => outcome
          }
        ),
        T0
      );
      Assert.isFalse(a.lastFireFailed, String.valueOf(outcome));
      Assert.areEqual(ScheduleHealth.STATUS_OK, a.status);
    }
  }

  @IsTest
  static void overdueAndFailedKeepBothFlags() {
    Workflow_Schedule__c sched = row(
      new Map<String, Object>{
        'Next_Fire_Window__c' => T0,
        'LastModifiedDate' => T0.addHours(-1),
        'Last_Outcome__c' => 'Error'
      }
    );

    ScheduleHealth.Assessment a = assessAt(sched, T0.addHours(1));

    Assert.isTrue(a.overdue);
    Assert.isTrue(a.lastFireFailed);
    Assert.areEqual(ScheduleHealth.STATUS_OVERDUE, a.status);
  }

  @IsTest
  static void springForwardGivesNoFalsePositive() {
    // "0 2 * * *" in New York on 2026-03-08: 02:00 local does not exist.
    // The engine fires at the gap boundary, 03:00 EDT = 07:00 UTC.
    Datetime cursor = Datetime.newInstanceGmt(2026, 3, 8, 7, 0, 0);
    Workflow_Schedule__c sched = row(
      new Map<String, Object>{
        'Cron_Expression__c' => '0 2 * * *',
        'Time_Zone__c' => 'America/New_York',
        'Next_Fire_Window__c' => cursor,
        'LastModifiedDate' => cursor.addDays(-1)
      }
    );

    // 03:09 EDT: 69 wall-clock minutes after 02:00, but 9 real minutes.
    Assert.isFalse(assessAt(sched, cursor.addMinutes(9)).overdue);
    Assert.isTrue(assessAt(sched, cursor.addMinutes(11)).overdue);
  }

  @IsTest
  static void fallBackUsesRealElapsedTime() {
    // "30 1 * * *" in New York on 2026-11-01: 01:30 occurs two times. The
    // engine fires on the first (01:30 EDT = 05:30 UTC).
    Datetime cursor = Datetime.newInstanceGmt(2026, 11, 1, 5, 30, 0);
    Workflow_Schedule__c sched = row(
      new Map<String, Object>{
        'Cron_Expression__c' => '30 1 * * *',
        'Time_Zone__c' => 'America/New_York',
        'Next_Fire_Window__c' => cursor,
        'LastModifiedDate' => cursor.addDays(-1)
      }
    );

    Assert.isFalse(assessAt(sched, cursor.addMinutes(9)).overdue);
    // 01:35 EST: 5 wall-clock minutes after 01:30, but 65 real minutes.
    ScheduleHealth.Assessment a = assessAt(sched, cursor.addMinutes(65));
    Assert.isTrue(a.overdue);
    Assert.areEqual(65, a.lapsedMinutes);
  }

  @IsTest
  static void zoneOffsetGivesNoFalsePositive() {
    // "0 9 * * *" in Tokyo = 00:00 UTC. At 23:55 UTC the day before, the
    // local time is 08:55. The window is still in the future.
    Datetime cursor = Datetime.newInstanceGmt(2026, 9, 29, 0, 0, 0);
    Workflow_Schedule__c sched = row(
      new Map<String, Object>{
        'Cron_Expression__c' => '0 9 * * *',
        'Time_Zone__c' => 'Asia/Tokyo',
        'Next_Fire_Window__c' => cursor,
        'LastModifiedDate' => cursor.addDays(-1)
      }
    );

    Assert.isFalse(assessAt(sched, cursor.addMinutes(-5)).overdue);
    Assert.isFalse(assessAt(sched, cursor.addMinutes(GRACE)).overdue);
    Assert.isTrue(assessAt(sched, cursor.addMinutes(GRACE + 1)).overdue);
  }

  @IsTest
  static void assessmentMapCarriesDisplayFields() {
    Workflow_Schedule__c sched = row(
      new Map<String, Object>{
        'Name' => 'Nightly',
        'Next_Fire_Window__c' => T0,
        'LastModifiedDate' => T0.addHours(-1),
        'Last_Outcome__c' => 'Invalid cron'
      }
    );

    Map<String, Object> m = assessAt(sched, T0.addMinutes(30)).toMap();

    Assert.areEqual('Nightly', m.get('name'));
    Assert.areEqual(TEST_WF, m.get('workflowName'));
    Assert.areEqual(ScheduleHealth.STATUS_OVERDUE, m.get('status'));
    Assert.areEqual(true, m.get('overdue'));
    Assert.areEqual(true, m.get('lastFireFailed'));
    Assert.areEqual('Invalid cron', m.get('lastOutcome'));
    Assert.areEqual(T0, m.get('nextFireWindow'));
    Assert.areEqual(30, m.get('lapsedMinutes'));
  }

  // ── SOQL finder and summary ───────────────────────────────────────────

  private static Workflow_Schedule__c insertSchedule(
    String name,
    Map<String, Object> fields
  ) {
    Workflow_Schedule__c sched = new Workflow_Schedule__c(
      Name = name,
      Workflow_Name__c = TEST_WF,
      Cron_Expression__c = '0 2 * * *',
      Correlation_Key_Prefix__c = name,
      Enabled__c = true,
      Dedicated_Slot__c = false
    );
    for (String field : fields.keySet()) {
      sched.put(field, fields.get(field));
    }
    insert sched;
    return sched;
  }

  // One row per state. "now" is 30 minutes after the insert, so each
  // LastModifiedDate is more than one interval old.
  private static void insertMixedSchedules() {
    Datetime past = System.now().addHours(-2);
    Datetime future = System.now().addDays(1);
    insertSchedule(
      'HOverdue',
      new Map<String, Object>{ 'Next_Fire_Window__c' => past }
    );
    insertSchedule(
      'HFailed',
      new Map<String, Object>{
        'Next_Fire_Window__c' => future,
        'Last_Outcome__c' => 'Error'
      }
    );
    insertSchedule(
      'HHealthy',
      new Map<String, Object>{
        'Next_Fire_Window__c' => future,
        'Last_Outcome__c' => 'Started'
      }
    );
    insertSchedule(
      'HDisabled',
      new Map<String, Object>{
        'Enabled__c' => false,
        'Next_Fire_Window__c' => past,
        'Last_Outcome__c' => 'Error'
      }
    );
    insertSchedule(
      'HDedicated',
      new Map<String, Object>{
        'Dedicated_Slot__c' => true,
        'Next_Fire_Window__c' => past
      }
    );
  }

  @IsTest
  static void findUnhealthyReturnsOnlyEnabledProblems() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insertMixedSchedules();

      List<ScheduleHealth.Assessment> found = ScheduleHealth.findUnhealthy(
        System.now().addMinutes(30),
        GRACE
      );

      Map<String, String> statusByName = new Map<String, String>();
      for (ScheduleHealth.Assessment a : found) {
        statusByName.put(a.schedule.Name, a.status);
      }
      Assert.areEqual(2, statusByName.size(), String.valueOf(statusByName));
      Assert.areEqual(
        ScheduleHealth.STATUS_OVERDUE,
        statusByName.get('HOverdue')
      );
      Assert.areEqual(
        ScheduleHealth.STATUS_FAILED,
        statusByName.get('HFailed')
      );
    }
  }

  @IsTest
  static void findUnhealthyIsEmptyWhenAllFireOnTime() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insertSchedule(
        'HOnTime',
        new Map<String, Object>{
          'Next_Fire_Window__c' => System.now().addHours(1)
        }
      );

      Assert.isTrue(
        ScheduleHealth.findUnhealthy(System.now().addMinutes(30), GRACE)
          .isEmpty()
      );
    }
  }

  @IsTest
  static void summaryCountsEachProblem() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = GRACE;
      insertMixedSchedules();
      WorkflowEngine.mockNow = System.now().addMinutes(30);

      Map<String, Object> summary = ScheduleHealth.summary();

      Assert.areEqual(1, summary.get('overdueCount'));
      Assert.areEqual(1, summary.get('failedCount'));
      Assert.areEqual(GRACE, summary.get('graceMinutes'));
      Assert.areEqual(false, summary.get('truncated'));
      Assert.areEqual(2, ((List<Object>) summary.get('rows')).size());
    }
  }

  @IsTest
  static void graceIsOneSweepInterval() {
    WorkflowEngine.watchdogDelayMinutes = 4;

    Assert.areEqual(4, ScheduleHealth.graceMinutes());
  }

  @IsTest
  static void systemDoctorShowsScheduleHealth() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = GRACE;
      insertMixedSchedules();
      WorkflowEngine.mockNow = System.now().addMinutes(30);

      Map<String, Object> status = WorkflowDashboardController.getWatchdogStatus();

      Map<String, Object> health = (Map<String, Object>) status.get(
        'scheduleHealth'
      );
      Assert.isNotNull(health);
      Assert.areEqual(1, health.get('overdueCount'));
      Assert.areEqual(1, health.get('failedCount'));
    }
  }

  @IsTest
  static void scheduleManagerRowsCarryHealth() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = GRACE;
      insertMixedSchedules();
      WorkflowEngine.mockNow = System.now().addMinutes(30);

      Map<String, Map<String, Object>> byName = new Map<String, Map<String, Object>>();
      for (
        Map<String, Object> r : WorkflowScheduleController.getSchedules('0')
      ) {
        byName.put((String) r.get('Name'), r);
      }

      Assert.areEqual(
        ScheduleHealth.STATUS_OVERDUE,
        byName.get('HOverdue').get('healthStatus')
      );
      Assert.areEqual(true, byName.get('HOverdue').get('overdue'));
      Assert.areEqual(
        ScheduleHealth.STATUS_FAILED,
        byName.get('HFailed').get('healthStatus')
      );
      Assert.areEqual(true, byName.get('HFailed').get('lastFireFailed'));
      Assert.areEqual(
        ScheduleHealth.STATUS_OK,
        byName.get('HHealthy').get('healthStatus')
      );
      Assert.areEqual(
        ScheduleHealth.STATUS_DISABLED,
        byName.get('HDisabled').get('healthStatus')
      );
      Assert.areEqual(
        ScheduleHealth.STATUS_OK,
        byName.get('HDedicated').get('healthStatus')
      );
    }
  }
}
