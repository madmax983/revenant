/**
 * Unit tests for CircuitBreakerGate — the durable, per-dependency circuit breaker
 * that fast-fails guarded steps when a shared dependency is unhealthy and
 * auto-recovers once it heals (issue #128).
 *
 * Mirrors ConcurrencyGateTest: configs are injected through
 * CircuitBreakerGate.mockConfigs (a @TestVisible map) so no Circuit_Breaker_Config__mdt
 * deployment is required, and the Circuit_Breaker_State__c row is the durable,
 * FOR UPDATE-locked state. Honest SOQL/DML profiles are pinned with
 * Limits.getQueries()/getDmlStatements() deltas.
 */
@IsTest
private class CircuitBreakerGateTest {
  // Builds an in-memory config without CMDT DML (mirrors ConcurrencyGateTest.mockConfig).
  private static Circuit_Breaker_Config__mdt cfg(
    String developerName,
    List<Integer> params
  ) {
    return (Circuit_Breaker_Config__mdt) JSON.deserialize(
      '{"DeveloperName":"' +
        developerName +
        '","Failure_Threshold__c":' +
        params[0] +
        ',"Rolling_Window_Seconds__c":' +
        params[1] +
        ',"Open_Duration_Seconds__c":' +
        params[2] +
        ',"Half_Open_Probe_Count__c":' +
        params[3] +
        '}',
      Circuit_Breaker_Config__mdt.class
    );
  }

  private static Circuit_Breaker_State__c stateFor(String dependencyKey) {
    return [
      SELECT
        Status__c,
        Failure_Count__c,
        Window_Started_At__c,
        Opened_At__c,
        Half_Open_Probes_Admitted__c
      FROM Circuit_Breaker_State__c
      WHERE Dependency_Key__c = :dependencyKey
    ];
  }

  // ── Unconfigured: admit with 0 SOQL / 0 DML ────────────────────────────────
  @IsTest
  static void testUnconfiguredAdmitsWithZeroGovernorCost() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Integer q0 = Limits.getQueries();
      Integer d0 = Limits.getDmlStatements();
      CircuitBreakerGate.BreakerDecision dec = CircuitBreakerGate.tryAdmit(
        'NoBreakerHere'
      );
      System.assertEquals(
        q0,
        Limits.getQueries(),
        'Unconfigured tryAdmit must consume 0 SOQL'
      );
      System.assertEquals(
        d0,
        Limits.getDmlStatements(),
        'Unconfigured tryAdmit must consume 0 DML'
      );
      Test.stopTest();
      System.assert(dec.admitted, 'Unconfigured always admits');
      System.assert(!dec.isProbe, 'Unconfigured admit is not a probe');
      System.assert(
        !CircuitBreakerGate.isConfigured('NoBreakerHere'),
        'isConfigured false when no breaker'
      );
    }
  }

  // ── Closed admission (configured, no row): 1 SOQL, 0 DML ───────────────────
  @IsTest
  static void testClosedAdmitsHealthyDependency() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerGate.mockConfigs.put(
        'PaymentsApi',
        cfg('PaymentsApi', new List<Integer>{ 3, 60, 30, 1 })
      );
      Test.startTest();
      Integer q0 = Limits.getQueries();
      Integer d0 = Limits.getDmlStatements();
      CircuitBreakerGate.BreakerDecision dec = CircuitBreakerGate.tryAdmit(
        'PaymentsApi'
      );
      System.assertEquals(
        q0 + 1,
        Limits.getQueries(),
        'Configured no-row tryAdmit locks the (absent) row: exactly 1 SOQL'
      );
      System.assertEquals(
        d0,
        Limits.getDmlStatements(),
        'A healthy no-row closed admit writes 0 DML'
      );
      Test.stopTest();
      System.assert(dec.admitted && !dec.isProbe, 'Closed admits, not a probe');
      System.assertEquals(
        0,
        [
          SELECT COUNT()
          FROM Circuit_Breaker_State__c
          WHERE Dependency_Key__c = 'PaymentsApi'
        ],
        'No state row provisioned for a healthy closed admit'
      );
    }
  }

  // ── Failure threshold trips the breaker Open ───────────────────────────────
  @IsTest
  static void testFailuresInWindowTripOpen() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerGate.mockConfigs.put(
        'DepX',
        cfg('DepX', new List<Integer>{ 3, 60, 30, 1 })
      );
      Test.startTest();
      CircuitBreakerGate.recordFailure('DepX');
      CircuitBreakerGate.recordFailure('DepX');
      System.assertEquals(
        'Closed',
        stateFor('DepX').Status__c,
        'Below threshold stays Closed'
      );
      CircuitBreakerGate.recordFailure('DepX');
      Test.stopTest();
      Circuit_Breaker_State__c s = stateFor('DepX');
      System.assertEquals('Open', s.Status__c, 'Threshold reached trips Open');
      System.assertEquals(3, s.Failure_Count__c, 'Count reflects the failures');
      System.assertNotEquals(null, s.Opened_At__c, 'Opened_At stamped on trip');
    }
  }

  // ── Open rejects (fast-fail) ───────────────────────────────────────────────
  @IsTest
  static void testOpenBreakerRejects() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerGate.mockConfigs.put(
        'DepX',
        cfg('DepX', new List<Integer>{ 1, 60, 30, 1 })
      );
      CircuitBreakerGate.recordFailure('DepX'); // threshold 1 -> Open, Opened_At now
      Test.startTest();
      CircuitBreakerGate.BreakerDecision dec = CircuitBreakerGate.tryAdmit(
        'DepX'
      );
      Test.stopTest();
      System.assert(!dec.admitted, 'Open breaker rejects (fast-fail)');
      System.assert(!dec.isProbe, 'A rejection is not a probe');
    }
  }

  // ── Rolling window elapse resets the failure count ─────────────────────────
  @IsTest
  static void testWindowElapseResetsCount() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerGate.mockConfigs.put(
        'DepW',
        cfg('DepW', new List<Integer>{ 5, 60, 30, 1 })
      );
      CircuitBreakerGate.recordFailure('DepW');
      CircuitBreakerGate.recordFailure('DepW'); // count 2
      // Backdate the window so the next failure lands in a fresh window.
      Circuit_Breaker_State__c s = stateFor('DepW');
      update new Circuit_Breaker_State__c(
        Id = s.Id,
        Window_Started_At__c = Datetime.now().addSeconds(-120)
      );
      Test.startTest();
      CircuitBreakerGate.recordFailure('DepW');
      Test.stopTest();
      Circuit_Breaker_State__c after = stateFor('DepW');
      System.assertEquals(
        1,
        after.Failure_Count__c,
        'An elapsed window resets the count before applying the new failure'
      );
      System.assertEquals(
        'Closed',
        after.Status__c,
        'Still Closed after reset'
      );
    }
  }

  // tryAdmit itself resets an elapsed window (1 DML on that reset), then admits.
  @IsTest
  static void testTryAdmitResetsElapsedWindow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerGate.mockConfigs.put(
        'DepR',
        cfg('DepR', new List<Integer>{ 5, 60, 30, 1 })
      );
      CircuitBreakerGate.recordFailure('DepR');
      CircuitBreakerGate.recordFailure('DepR'); // count 2, Closed
      Circuit_Breaker_State__c s = stateFor('DepR');
      update new Circuit_Breaker_State__c(
        Id = s.Id,
        Window_Started_At__c = Datetime.now().addSeconds(-120)
      );
      Test.startTest();
      Integer q0 = Limits.getQueries();
      Integer d0 = Limits.getDmlStatements();
      CircuitBreakerGate.BreakerDecision dec = CircuitBreakerGate.tryAdmit(
        'DepR'
      );
      System.assertEquals(
        q0 + 1,
        Limits.getQueries(),
        'Window-reset admit: 1 SOQL'
      );
      System.assertEquals(
        d0 + 1,
        Limits.getDmlStatements(),
        'Window-reset admit writes exactly 1 DML'
      );
      Test.stopTest();
      System.assert(
        dec.admitted && !dec.isProbe,
        'Reset-then-admit stays closed'
      );
      System.assertEquals(
        0,
        stateFor('DepR').Failure_Count__c,
        'tryAdmit reset the elapsed window count to 0'
      );
    }
  }

  // ── Open + open-duration elapsed -> Half-Open probes up to the budget ──────
  @IsTest
  static void testHalfOpenProbeBudgetThenReject() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerGate.mockConfigs.put(
        'DepH',
        cfg('DepH', new List<Integer>{ 1, 60, 30, 2 })
      );
      CircuitBreakerGate.recordFailure('DepH'); // -> Open, Opened_At now
      // Backdate Opened_At so the open duration has elapsed.
      Circuit_Breaker_State__c s = stateFor('DepH');
      update new Circuit_Breaker_State__c(
        Id = s.Id,
        Opened_At__c = Datetime.now().addSeconds(-60)
      );

      Test.startTest();
      CircuitBreakerGate.BreakerDecision d1 = CircuitBreakerGate.tryAdmit(
        'DepH'
      );
      CircuitBreakerGate.BreakerDecision d2 = CircuitBreakerGate.tryAdmit(
        'DepH'
      );
      CircuitBreakerGate.BreakerDecision d3 = CircuitBreakerGate.tryAdmit(
        'DepH'
      );
      Test.stopTest();

      System.assert(
        d1.admitted && d1.isProbe,
        'First half-open admit is a probe'
      );
      System.assert(
        d2.admitted && d2.isProbe,
        'Second probe within budget of 2'
      );
      System.assert(!d3.admitted, 'Third probe rejected: budget spent');
      Circuit_Breaker_State__c after = stateFor('DepH');
      System.assertEquals('HalfOpen', after.Status__c, 'Now Half-Open');
      System.assertEquals(
        2,
        after.Half_Open_Probes_Admitted__c,
        'Exactly the probe budget was admitted'
      );
    }
  }

  // ── Probe success closes the breaker ───────────────────────────────────────
  @IsTest
  static void testProbeSuccessClosesBreaker() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerGate.mockConfigs.put(
        'DepS',
        cfg('DepS', new List<Integer>{ 3, 60, 30, 1 })
      );
      insert new Circuit_Breaker_State__c(
        Dependency_Key__c = 'DepS',
        Status__c = 'HalfOpen',
        Failure_Count__c = 3,
        Half_Open_Probes_Admitted__c = 1,
        Opened_At__c = Datetime.now().addSeconds(-60)
      );
      Test.startTest();
      CircuitBreakerGate.recordSuccess('DepS');
      Test.stopTest();
      Circuit_Breaker_State__c s = stateFor('DepS');
      System.assertEquals(
        'Closed',
        s.Status__c,
        'Probe success closes the breaker'
      );
      System.assertEquals(
        0,
        s.Failure_Count__c,
        'Closing resets the failure count'
      );
      System.assertEquals(
        0,
        s.Half_Open_Probes_Admitted__c,
        'Closing resets the probe counter'
      );
    }
  }

  // ── Probe failure re-opens the breaker ─────────────────────────────────────
  @IsTest
  static void testProbeFailureReopensBreaker() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerGate.mockConfigs.put(
        'DepF',
        cfg('DepF', new List<Integer>{ 3, 60, 30, 1 })
      );
      insert new Circuit_Breaker_State__c(
        Dependency_Key__c = 'DepF',
        Status__c = 'HalfOpen',
        Failure_Count__c = 3,
        Half_Open_Probes_Admitted__c = 1,
        Opened_At__c = Datetime.now().addSeconds(-60)
      );
      Test.startTest();
      CircuitBreakerGate.recordFailure('DepF');
      Test.stopTest();
      Circuit_Breaker_State__c s = stateFor('DepF');
      System.assertEquals(
        'Open',
        s.Status__c,
        'Probe failure re-opens the breaker'
      );
      System.assertEquals(
        0,
        s.Half_Open_Probes_Admitted__c,
        'Re-open resets the probe counter'
      );
      System.assert(
        s.Opened_At__c >= Datetime.now().addSeconds(-5),
        'Opened_At refreshed'
      );
    }
  }

  // ── recordSuccess on a Closed breaker (with a row) is 0 DML; unconfigured 0/0 ─
  @IsTest
  static void testRecordSuccessNoOpProfiles() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      // Unconfigured: 0 SOQL / 0 DML.
      Integer q0 = Limits.getQueries();
      Integer d0 = Limits.getDmlStatements();
      CircuitBreakerGate.recordSuccess('Nope');
      System.assertEquals(
        q0,
        Limits.getQueries(),
        'Unconfigured success: 0 SOQL'
      );
      System.assertEquals(
        d0,
        Limits.getDmlStatements(),
        'Unconfigured success: 0 DML'
      );

      // Configured + Closed row: reads the row (1 SOQL) but writes 0 DML.
      CircuitBreakerGate.mockConfigs.put(
        'DepC',
        cfg('DepC', new List<Integer>{ 5, 300, 30, 1 })
      );
      CircuitBreakerGate.recordFailure('DepC'); // provisions a Closed row
      Integer q1 = Limits.getQueries();
      Integer d1 = Limits.getDmlStatements();
      CircuitBreakerGate.recordSuccess('DepC');
      System.assertEquals(
        q1 + 1,
        Limits.getQueries(),
        'Closed success reads 1 SOQL'
      );
      System.assertEquals(
        d1,
        Limits.getDmlStatements(),
        'Closed success writes 0 DML'
      );
      Test.stopTest();
      System.assertEquals(
        'Closed',
        stateFor('DepC').Status__c,
        'A closed-state success is a no-op transition'
      );
    }
  }

  // ── Steady CLOSED tryAdmit does 0 DML (RateLimiter-style skip) ─────────────
  @IsTest
  static void testSteadyClosedAdmitZeroDml() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerGate.mockConfigs.put(
        'DepSteady',
        cfg('DepSteady', new List<Integer>{ 5, 300, 30, 1 })
      );
      CircuitBreakerGate.recordFailure('DepSteady'); // provisions Closed row, fresh window
      Test.startTest();
      Integer q0 = Limits.getQueries();
      Integer d0 = Limits.getDmlStatements();
      CircuitBreakerGate.BreakerDecision dec = CircuitBreakerGate.tryAdmit(
        'DepSteady'
      );
      System.assertEquals(
        q0 + 1,
        Limits.getQueries(),
        'Steady closed admit: 1 SOQL'
      );
      System.assertEquals(
        d0,
        Limits.getDmlStatements(),
        'Steady closed admit (no window reset) writes 0 DML'
      );
      Test.stopTest();
      System.assert(dec.admitted && !dec.isProbe, 'Steady closed admits');
    }
  }

  // ── recordFailureBulk records each key ─────────────────────────────────────
  @IsTest
  static void testRecordFailureBulk() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerGate.mockConfigs.put(
        'DepA',
        cfg('DepA', new List<Integer>{ 2, 60, 30, 1 })
      );
      CircuitBreakerGate.mockConfigs.put(
        'DepB',
        cfg('DepB', new List<Integer>{ 3, 60, 30, 1 })
      );
      Test.startTest();
      CircuitBreakerGate.recordFailureBulk(
        new Map<String, Integer>{ 'DepA' => 2, 'DepB' => 1 }
      );
      Test.stopTest();
      System.assertEquals(
        'Open',
        stateFor('DepA').Status__c,
        'DepA reached its threshold of 2 and opened'
      );
      Circuit_Breaker_State__c b = stateFor('DepB');
      System.assertEquals(
        'Closed',
        b.Status__c,
        'DepB below its threshold stays Closed'
      );
      System.assertEquals(1, b.Failure_Count__c, 'DepB recorded 1 failure');
    }
  }

  // ── Sibling safety (#226): one bad key must not sink valid siblings ────────
  @IsTest
  static void testRecordFailureBulkIsolatesBadKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // An over-100-char dependency key fails the Dependency_Key__c length rule on
      // provision (a genuine per-row DML fault), while a valid sibling records fine.
      String longKey = 'D'.repeat(130);
      CircuitBreakerGate.mockConfigs.put(
        'D'.repeat(40),
        cfg('D'.repeat(40), new List<Integer>{ 1, 60, 30, 1 })
      );
      CircuitBreakerGate.mockConfigs.put(
        'DepOk',
        cfg('DepOk', new List<Integer>{ 2, 60, 30, 1 })
      );

      Test.startTest();
      CircuitBreakerGate.recordFailureBulk(
        new Map<String, Integer>{
          longKey => 1,
          'DepOk' => 2,
          '' => 5,
          'DepNull' => null
        }
      );
      Test.stopTest();

      System.assertEquals(
        'Open',
        stateFor('DepOk').Status__c,
        'The valid sibling still recorded and tripped despite the bad key'
      );
      System.assertEquals(
        0,
        [
          SELECT COUNT()
          FROM Circuit_Breaker_State__c
          WHERE Dependency_Key__c = :longKey
        ],
        'The over-long key provisioned no row'
      );
      System.assert(
        [
          SELECT COUNT()
          FROM Workflow_Log__c
          WHERE Log_Type__c = 'CircuitBreaker'
        ] > 0,
        'The isolated per-key failure is logged, not thrown'
      );
    }
  }

  // ── sweepHalfOpen flips eligible Open rows (zero-traffic recovery) ─────────
  @IsTest
  static void testSweepHalfOpenFlipsEligibleRows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerGate.mockConfigs.put(
        'DepDue',
        cfg('DepDue', new List<Integer>{ 1, 60, 30, 1 })
      );
      CircuitBreakerGate.mockConfigs.put(
        'DepNotDue',
        cfg('DepNotDue', new List<Integer>{ 1, 60, 300, 1 })
      );
      insert new List<Circuit_Breaker_State__c>{
        new Circuit_Breaker_State__c(
          Dependency_Key__c = 'DepDue',
          Status__c = 'Open',
          Failure_Count__c = 1,
          Half_Open_Probes_Admitted__c = 0,
          Opened_At__c = Datetime.now().addSeconds(-60)
        ),
        new Circuit_Breaker_State__c(
          Dependency_Key__c = 'DepNotDue',
          Status__c = 'Open',
          Failure_Count__c = 1,
          Half_Open_Probes_Admitted__c = 0,
          Opened_At__c = Datetime.now().addSeconds(-60)
        )
      };
      Test.startTest();
      CircuitBreakerGate.sweepHalfOpen();
      Test.stopTest();
      System.assertEquals(
        'HalfOpen',
        stateFor('DepDue').Status__c,
        'An Open breaker whose open duration elapsed flips to Half-Open'
      );
      System.assertEquals(
        'Open',
        stateFor('DepNotDue').Status__c,
        'An Open breaker still within its open duration is left Open'
      );
    }
  }

  // ── DUPLICATE_VALUE lazy-provision race recovery ───────────────────────────
  @IsTest
  static void testLazyProvisionDuplicateRace() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerGate.mockConfigs.put(
        'DepRace',
        cfg('DepRace', new List<Integer>{ 5, 60, 30, 1 })
      );
      insert new Circuit_Breaker_State__c(
        Dependency_Key__c = 'DepRace',
        Status__c = 'Closed',
        Failure_Count__c = 0,
        Half_Open_Probes_Admitted__c = 0
      );
      CircuitBreakerStateStore.simulateDuplicateOnInsert = true;
      Test.startTest();
      CircuitBreakerGate.recordFailure('DepRace');
      Test.stopTest();
      System.assertEquals(
        1,
        stateFor('DepRace').Failure_Count__c,
        'Recovered from the duplicate-insert race and incremented the existing row'
      );
    }
  }

  // ── secondsUntilHalfOpen computes the remaining open window ─────────────────
  @IsTest
  static void testSecondsUntilHalfOpen() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerGate.mockConfigs.put(
        'DepT',
        cfg('DepT', new List<Integer>{ 1, 60, 100, 1 })
      );
      insert new Circuit_Breaker_State__c(
        Dependency_Key__c = 'DepT',
        Status__c = 'Open',
        Failure_Count__c = 1,
        Half_Open_Probes_Admitted__c = 0,
        Opened_At__c = Datetime.now().addSeconds(-40)
      );
      Test.startTest();
      Integer secs = CircuitBreakerGate.secondsUntilHalfOpen('DepT');
      Integer none = CircuitBreakerGate.secondsUntilHalfOpen('Unconfigured');
      Test.stopTest();
      System.assert(
        secs != null && secs > 0 && secs <= 65,
        'Remaining open window is ~60s (100 open - 40 elapsed), got ' + secs
      );
      System.assertEquals(null, none, 'Unconfigured dependency returns null');
    }
  }

  /**
   * @description A CircuitBreakerGuarded fixture step (not started as a workflow —
   * only `new`ed for the instanceof hot-path check).
   */
  private class GuardedFixtureStep implements WorkflowStep, CircuitBreakerGuarded {
    /**
     * @description Names the fixture dependency this step guards.
     * @return The fixture dependency key.
     */
    public String dependencyKey() {
      return 'MixDep';
    }
    /**
     * @description Completes immediately (never actually executed in the hot-path test).
     * @param ctx The durable step context.
     * @return A completion result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  /** @description A plain (unguarded) fixture step. */
  private class PlainFixtureStep implements WorkflowStep {
    /**
     * @description Completes immediately.
     * @param ctx The durable step context.
     * @return A completion result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  // ── Bulk-safe hot path (requirement 1): in a mixed batch, unguarded steps
  // contribute 0 SOQL/0 DML to the breaker while guarded ones pay exactly the
  // profiled cost. Exercises the EXACT predicate the WorkflowStepInvoke hook uses. ─
  @IsTest
  static void testMixedBatchOnlyGuardedStepsTouchBreaker() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerGate.mockConfigs.put(
        'MixDep',
        cfg('MixDep', new List<Integer>{ 3, 60, 30, 1 })
      );
      List<WorkflowStep> batch = new List<WorkflowStep>{
        new PlainFixtureStep(),
        new GuardedFixtureStep(),
        new PlainFixtureStep(),
        new GuardedFixtureStep(),
        new PlainFixtureStep()
      };

      Test.startTest();
      Integer q0 = Limits.getQueries();
      Integer d0 = Limits.getDmlStatements();
      Integer admitted = 0;
      for (WorkflowStep step : batch) {
        // Mirror WorkflowStepInvoke.parkedByBreaker's flattened breaker hook exactly.
        if (!(step instanceof CircuitBreakerGuarded)) {
          continue;
        }
        String depKey = ((CircuitBreakerGuarded) step).dependencyKey();
        if (
          String.isBlank(depKey) || !CircuitBreakerGate.isConfigured(depKey)
        ) {
          continue;
        }
        if (CircuitBreakerGate.tryAdmit(depKey).admitted) {
          admitted++;
        }
      }
      Integer queryDelta = Limits.getQueries() - q0;
      Integer dmlDelta = Limits.getDmlStatements() - d0;
      Test.stopTest();

      System.assertEquals(
        2,
        queryDelta,
        'Only the 2 guarded steps consult the breaker (1 SOQL each, healthy closed); the 3 unguarded steps add 0 SOQL'
      );
      System.assertEquals(
        0,
        dmlDelta,
        'A healthy closed breaker admits with 0 DML for every guarded step; unguarded steps add 0 DML'
      );
      System.assertEquals(
        2,
        admitted,
        'Both guarded steps admitted (closed breaker)'
      );
      System.assertEquals(
        0,
        [SELECT COUNT() FROM Circuit_Breaker_State__c],
        'A healthy mixed batch provisions no breaker state at all'
      );
    }
  }

  // ── Park observability: a breaker park emits a distinct Warn signal ─────────
  @IsTest
  static void testParkForCircuitBreakerEmitsDistinctSignal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Boolean priorDynamic = WorkflowEngine.useDynamicScheduling;
      WorkflowEngine.useDynamicScheduling = false; // avoid scheduling a real job
      try {
        CircuitBreakerGate.mockConfigs.put(
          'DepPark',
          cfg('DepPark', new List<Integer>{ 1, 60, 120, 1 })
        );
        insert new Circuit_Breaker_State__c(
          Dependency_Key__c = 'DepPark',
          Status__c = 'Open',
          Failure_Count__c = 1,
          Half_Open_Probes_Admitted__c = 0,
          Opened_At__c = Datetime.now()
        );
        Workflow_Instance__c inst = new Workflow_Instance__c(
          Workflow_Name__c = 'CircuitBreakerGateTest.Fixture',
          Status__c = 'Running',
          Current_Step__c = 'CircuitBreakerGateTest.GuardedStep',
          Correlation_Key__c = 'park-obs-1'
        );
        insert inst;
        insert new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst.Id,
          Step_Name__c = 'CircuitBreakerGateTest.GuardedStep',
          Status__c = 'Pending',
          Retry_Count__c = 0,
          Timeout_At__c = Datetime.now().addMinutes(5)
        );

        Test.startTest();
        CircuitBreakerPark.parkForCircuitBreaker(
          inst,
          'CircuitBreakerGateTest.GuardedStep',
          'DepPark'
        );
        Test.stopTest();

        Workflow_Instance__c r = [
          SELECT Status__c, Sleep_Until__c
          FROM Workflow_Instance__c
          WHERE Id = :inst.Id
        ];
        System.assertEquals(
          'Suspended',
          r.Status__c,
          'Breaker park suspends the instance'
        );
        System.assertNotEquals(
          null,
          r.Sleep_Until__c,
          'Breaker park sets a wake time'
        );
        System.assertEquals(
          'Pending',
          [
            SELECT Status__c
            FROM Workflow_Step_Execution__c
            WHERE Workflow_Instance__c = :inst.Id
            LIMIT 1
          ]
          .Status__c,
          'The parked step is reset to Pending'
        );
        List<Workflow_Log__c> logs = [
          SELECT Level__c, Log_Type__c, Message__c
          FROM Workflow_Log__c
          WHERE
            Workflow_Instance__c = :inst.Id
            AND Log_Type__c = 'CircuitBreaker'
        ];
        System.assertEquals(1, logs.size(), 'Exactly one breaker-park signal');
        System.assertEquals(
          'Warn',
          logs[0].Level__c,
          'The park signal is Warn level'
        );
        System.assert(
          logs[0].Message__c.contains('parked by circuit breaker DepPark'),
          'The signal names the dependency key, distinguishing it from a plain sleep'
        );
      } finally {
        WorkflowEngine.useDynamicScheduling = priorDynamic;
      }
    }
  }
}
