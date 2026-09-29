/**
 * @description Tests for GlobalAdmissionPolicy (issue #136). The policy is pure:
 * no SOQL, no DML.
 */
@IsTest
private class GlobalAdmissionPolicyTest {
  private static GlobalAdmissionPolicy.Inputs inputs() {
    return new GlobalAdmissionPolicy.Inputs();
  }

  @IsTest
  static void notGovernedWhenAllControlsAreOff() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      GlobalAdmissionPolicy.Decision d = GlobalAdmissionPolicy.decide(inputs());
      Assert.isFalse(d.governed, 'No control set means not governed');
      Assert.isFalse(d.braked, 'Not governed means open');
      Assert.isNull(d.reason, 'Open has no reason');
      Assert.isTrue(d.reasons.isEmpty(), 'Open has no reasons');
    }
  }

  @IsTest
  static void emergencyStopBrakesWithNoReads() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      GlobalAdmissionPolicy.Inputs i = inputs();
      i.emergencyStop = true;
      GlobalAdmissionPolicy.Decision d = GlobalAdmissionPolicy.decide(i);
      Assert.isTrue(d.governed, 'Emergency stop governs');
      Assert.isTrue(d.braked, 'Emergency stop brakes');
      Assert.areEqual(
        GlobalAdmissionPolicy.REASON_EMERGENCY_STOP,
        d.reason,
        'Reason is the emergency stop'
      );
    }
  }

  @IsTest
  static void autoBrakeEngagesOnlyOnCritical() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      for (String status : new List<String>{ 'HEALTHY', 'DEGRADED' }) {
        GlobalAdmissionPolicy.Inputs i = inputs();
        i.autoBrake = true;
        i.capacityStatus = status;
        Assert.isFalse(
          GlobalAdmissionPolicy.decide(i).braked,
          status + ' does not brake'
        );
      }
      GlobalAdmissionPolicy.Inputs critical = inputs();
      critical.autoBrake = true;
      critical.capacityStatus = 'CRITICAL';
      GlobalAdmissionPolicy.Decision d = GlobalAdmissionPolicy.decide(critical);
      Assert.isTrue(d.braked, 'Critical brakes');
      Assert.areEqual(
        GlobalAdmissionPolicy.REASON_CAPACITY_CRITICAL,
        d.reason,
        'Reason is capacity'
      );
    }
  }

  @IsTest
  static void capacityFailsOpen() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      for (String status : new List<String>{ 'UNKNOWN', null, 'toString' }) {
        GlobalAdmissionPolicy.Inputs i = inputs();
        i.autoBrake = true;
        i.capacityStatus = status;
        GlobalAdmissionPolicy.Decision d = GlobalAdmissionPolicy.decide(i);
        Assert.isTrue(d.governed, 'Auto-brake governs');
        Assert.isFalse(d.braked, status + ' fails open');
      }
    }
  }

  @IsTest
  static void criticalWithAutoBrakeOffDoesNotBrake() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      GlobalAdmissionPolicy.Inputs i = inputs();
      i.capacityStatus = 'CRITICAL';
      Assert.isFalse(
        GlobalAdmissionPolicy.decide(i).braked,
        'Auto-brake off ignores capacity'
      );
    }
  }

  @IsTest
  static void ceilingBrakesAtOrAboveTheLimit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      GlobalAdmissionPolicy.Inputs i = inputs();
      i.ceiling = 3;
      i.inFlight = 2;
      Assert.isFalse(GlobalAdmissionPolicy.decide(i).braked, '2 of 3 is open');
      i.inFlight = 3;
      GlobalAdmissionPolicy.Decision d = GlobalAdmissionPolicy.decide(i);
      Assert.isTrue(d.braked, '3 of 3 brakes');
      Assert.areEqual(
        GlobalAdmissionPolicy.REASON_CEILING,
        d.reason,
        'Reason is the ceiling'
      );
      i.inFlight = 9;
      Assert.isTrue(GlobalAdmissionPolicy.decide(i).braked, '9 of 3 brakes');
    }
  }

  @IsTest
  static void unreadCounterFailsOpen() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      GlobalAdmissionPolicy.Inputs i = inputs();
      i.ceiling = 1;
      i.inFlight = null;
      GlobalAdmissionPolicy.Decision d = GlobalAdmissionPolicy.decide(i);
      Assert.isTrue(d.governed, 'A ceiling governs');
      Assert.isFalse(d.braked, 'No counter value fails open');
    }
  }

  @IsTest
  static void reasonsKeepPrecedenceOrder() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      GlobalAdmissionPolicy.Inputs i = inputs();
      i.emergencyStop = true;
      i.autoBrake = true;
      i.capacityStatus = 'CRITICAL';
      i.ceiling = 1;
      i.inFlight = 1;
      GlobalAdmissionPolicy.Decision d = GlobalAdmissionPolicy.decide(i);
      Assert.areEqual(
        new List<String>{
          GlobalAdmissionPolicy.REASON_EMERGENCY_STOP,
          GlobalAdmissionPolicy.REASON_CAPACITY_CRITICAL,
          GlobalAdmissionPolicy.REASON_CEILING
        },
        d.reasons,
        'All reasons, in precedence order'
      );
      Assert.areEqual(
        GlobalAdmissionPolicy.REASON_EMERGENCY_STOP,
        d.reason,
        'The first reason wins'
      );
    }
  }

  @IsTest
  static void normalizeCeilingRejectsNonPositive() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.isNull(GlobalAdmissionPolicy.normalizeCeiling(null), 'Blank');
      Assert.isNull(GlobalAdmissionPolicy.normalizeCeiling(0), 'Zero');
      Assert.isNull(GlobalAdmissionPolicy.normalizeCeiling(-4), 'Negative');
      Assert.areEqual(
        25,
        GlobalAdmissionPolicy.normalizeCeiling(25),
        'Positive'
      );
    }
  }

  @IsTest
  static void startStateMatrix() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      GlobalAdmissionPolicy.Decision open = GlobalAdmissionPolicy.decide(
        inputs()
      );
      Assert.isNull(
        GlobalAdmissionPolicy.startState(open, false),
        'Not governed: no marker'
      );
      Assert.isNull(
        GlobalAdmissionPolicy.startState(open, true),
        'Not governed and paused: no marker'
      );

      GlobalAdmissionPolicy.Inputs stop = inputs();
      stop.emergencyStop = true;
      GlobalAdmissionPolicy.Decision braked = GlobalAdmissionPolicy.decide(
        stop
      );
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_PARKED,
        GlobalAdmissionPolicy.startState(braked, false),
        'Braked start parks'
      );
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_AWAITING,
        GlobalAdmissionPolicy.startState(braked, true),
        'Braked and paused: the pause parks, the gate decides later'
      );

      GlobalAdmissionPolicy.Inputs ceiling = inputs();
      ceiling.ceiling = 5;
      ceiling.inFlight = 0;
      GlobalAdmissionPolicy.Decision openCeiling = GlobalAdmissionPolicy.decide(
        ceiling
      );
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_AWAITING,
        GlobalAdmissionPolicy.startState(openCeiling, false),
        'Open with a ceiling: take a slot at the first hop'
      );

      GlobalAdmissionPolicy.Inputs auto = inputs();
      auto.autoBrake = true;
      auto.capacityStatus = 'HEALTHY';
      Assert.isNull(
        GlobalAdmissionPolicy.startState(
          GlobalAdmissionPolicy.decide(auto),
          false
        ),
        'Open with no ceiling: admitted now, no marker'
      );
    }
  }

  @IsTest
  static void awaitingStates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.isTrue(
        GlobalAdmissionPolicy.isAwaiting(GlobalAdmissionPolicy.STATE_AWAITING),
        'Awaiting waits'
      );
      Assert.isTrue(
        GlobalAdmissionPolicy.isAwaiting(GlobalAdmissionPolicy.STATE_PARKED),
        'Parked waits'
      );
      Assert.isFalse(
        GlobalAdmissionPolicy.isAwaiting(GlobalAdmissionPolicy.STATE_HELD),
        'Held does not wait'
      );
      Assert.isFalse(GlobalAdmissionPolicy.isAwaiting(null), 'Blank');
    }
  }
}
