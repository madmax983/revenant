/**
 * @description Tests for WatchdogLiveness (issue #113): the sweep stamp and
 * the HEALTHY / STALE / UNKNOWN state.
 */
@IsTest
private class WatchdogLivenessTest {
  private static final Datetime T0 = Datetime.newInstanceGmt(
    2026,
    9,
    28,
    10,
    0,
    0
  );

  private static void stamp(Datetime sweptAt, Integer cadence) {
    insert new Watchdog_Liveness__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Last_Sweep_At__c = sweptAt,
      Cadence_Minutes__c = cadence
    );
  }

  @IsTest
  static void noRowIsUnknown() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;

      WatchdogLiveness.Snapshot snap = WatchdogLiveness.evaluate(T0);

      Assert.areEqual(WatchdogLiveness.STATE_UNKNOWN, snap.state);
      Assert.isNull(snap.lastSweepAt);
      Assert.isNull(snap.elapsedMinutes);
      Assert.areEqual(20, snap.thresholdMinutes, '2 x 10 min cadence');
    }
  }

  @IsTest
  static void recentSweepIsHealthy() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      stamp(T0, 10);

      WatchdogLiveness.Snapshot snap = WatchdogLiveness.evaluate(
        T0.addMinutes(3)
      );

      Assert.areEqual(WatchdogLiveness.STATE_HEALTHY, snap.state);
      Assert.areEqual(T0, snap.lastSweepAt);
      Assert.areEqual(3, snap.elapsedMinutes);
      Assert.areEqual(10, snap.cadenceMinutes);
    }
  }

  @IsTest
  static void thresholdBoundary() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      stamp(T0, 10);

      Assert.areEqual(
        WatchdogLiveness.STATE_HEALTHY,
        WatchdogLiveness.evaluate(T0.addMinutes(20)).state,
        'Elapsed equal to the threshold is not stale'
      );
      Assert.areEqual(
        WatchdogLiveness.STATE_STALE,
        WatchdogLiveness.evaluate(T0.addMinutes(20).addSeconds(1)).state,
        'Elapsed over the threshold is stale'
      );
    }
  }

  @IsTest
  static void thresholdFollowsConfiguredCadence() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 2;
      stamp(T0, 2);

      WatchdogLiveness.Snapshot snap = WatchdogLiveness.evaluate(
        T0.addMinutes(5)
      );

      Assert.areEqual(4, snap.thresholdMinutes);
      Assert.areEqual(WatchdogLiveness.STATE_STALE, snap.state);
    }
  }

  @IsTest
  static void longerConfiguredCadenceWins() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Admin raised the cadence after the last sweep: no false alert.
      WorkflowEngine.watchdogDelayMinutes = 10;
      stamp(T0, 1);

      WatchdogLiveness.Snapshot snap = WatchdogLiveness.evaluate(
        T0.addMinutes(15)
      );

      Assert.areEqual(10, snap.cadenceMinutes);
      Assert.areEqual(20, snap.thresholdMinutes);
      Assert.areEqual(WatchdogLiveness.STATE_HEALTHY, snap.state);
    }
  }

  @IsTest
  static void longerRecordedCadenceWins() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Admin lowered the cadence; the running sleep still uses the old one.
      WorkflowEngine.watchdogDelayMinutes = 1;
      stamp(T0, 10);

      Assert.areEqual(
        20,
        WatchdogLiveness.evaluate(T0.addMinutes(15)).thresholdMinutes
      );
    }
  }

  @IsTest
  static void cadenceNormalization() {
    Assert.areEqual(10, WatchdogLiveness.normalizeCadence(null));
    Assert.areEqual(1, WatchdogLiveness.normalizeCadence(0));
    Assert.areEqual(1, WatchdogLiveness.normalizeCadence(-5));
    Assert.areEqual(30, WatchdogLiveness.normalizeCadence(30));
  }

  @IsTest
  static void futureSweepIsHealthy() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      stamp(T0.addMinutes(5), 10);

      WatchdogLiveness.Snapshot snap = WatchdogLiveness.evaluate(T0);

      Assert.areEqual(WatchdogLiveness.STATE_HEALTHY, snap.state);
      Assert.areEqual(0, snap.elapsedMinutes);
    }
  }

  @IsTest
  static void recordSweepInsertsThenUpdatesOneRow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WatchdogLiveness.recordSweep(T0, 5);
      WatchdogLiveness.recordSweep(T0.addMinutes(5), 7);

      List<Watchdog_Liveness__c> rows = [
        SELECT Last_Sweep_At__c, Cadence_Minutes__c, SetupOwnerId
        FROM Watchdog_Liveness__c
      ];
      Assert.areEqual(1, rows.size(), 'Singleton org-default row');
      Assert.areEqual(T0.addMinutes(5), rows[0].Last_Sweep_At__c);
      Assert.areEqual(7, rows[0].Cadence_Minutes__c.intValue());
      Assert.areEqual(UserInfo.getOrganizationId(), rows[0].SetupOwnerId);
    }
  }

  @IsTest
  static void markAlertSentKeepsSweepFields() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      stamp(T0, 10);

      WatchdogLiveness.markAlertSent(T0);

      Watchdog_Liveness__c row = Watchdog_Liveness__c.getOrgDefaults();
      Assert.areEqual(T0, row.Last_Sweep_At__c);
      Assert.areEqual(10, row.Cadence_Minutes__c.intValue());
      Assert.isTrue(WatchdogLiveness.evaluate(T0.addHours(1)).alertSent);

      // A new sweep starts a new stall episode.
      WatchdogLiveness.recordSweep(T0.addHours(1), 10);
      Assert.isFalse(WatchdogLiveness.evaluate(T0.addHours(3)).alertSent);
      Assert.areEqual(
        T0,
        Watchdog_Liveness__c.getOrgDefaults().Last_Alert_Sweep_At__c,
        'The stamp does not change the alert field'
      );
    }
  }

  @IsTest
  static void recordSweepSkipsWhenDmlBudgetIsLow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WatchdogLiveness.forceDmlBudgetExhausted = true;

      WatchdogLiveness.recordSweep(T0, 10);

      Assert.areEqual(
        0,
        [SELECT COUNT() FROM Watchdog_Liveness__c],
        'No stamp when the DML budget is low'
      );
    }
  }

  @IsTest
  static void recordSweepIgnoresNullTime() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WatchdogLiveness.recordSweep(null, 10);

      Assert.areEqual(0, [SELECT COUNT() FROM Watchdog_Liveness__c]);
    }
  }

  @IsTest
  static void heartbeatStampsLiveness() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.watchdogDelayMinutes = 3;
      WorkflowEngine.mockNow = T0;

      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      Watchdog_Liveness__c row = Watchdog_Liveness__c.getOrgDefaults();
      Assert.areEqual(T0, row.Last_Sweep_At__c);
      Assert.areEqual(3, row.Cadence_Minutes__c.intValue());
    }
  }

  @IsTest
  static void resumedHeartbeatClearsStale() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.watchdogDelayMinutes = 10;
      stamp(T0, 10);
      Datetime later = T0.addHours(2);
      Assert.areEqual(
        WatchdogLiveness.STATE_STALE,
        WatchdogLiveness.evaluate(later).state
      );

      WorkflowEngine.mockNow = later;
      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();

      Assert.areEqual(
        WatchdogLiveness.STATE_HEALTHY,
        WatchdogLiveness.evaluate(later).state,
        'A good sweep clears the stale state with no manual cleanup'
      );
    }
  }

  @IsTest
  static void toMapHasDashboardKeys() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.watchdogDelayMinutes = 10;
      stamp(T0, 10);

      Map<String, Object> m = WatchdogLiveness.evaluate(T0.addMinutes(4))
        .toMap();

      Assert.areEqual('HEALTHY', m.get('state'));
      Assert.areEqual(T0, m.get('lastSweepAt'));
      Assert.areEqual(4, m.get('elapsedMinutes'));
      Assert.areEqual(20, m.get('thresholdMinutes'));
      Assert.areEqual(10, m.get('cadenceMinutes'));
    }
  }
}
