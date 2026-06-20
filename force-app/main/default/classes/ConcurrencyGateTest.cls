/**
 * Unit tests for ConcurrencyGate — the durable per-workflow-definition slot
 * semaphore that caps simultaneously in-flight instances (issue #28).
 *
 * Mirrors RateLimiterTest: configs are injected through ConcurrencyGate.mockConfigs
 * (a @TestVisible map) so no Concurrency_Config__mdt deployment is required, and the
 * Concurrency_State__c counter row is the durable, FOR UPDATE-locked state.
 */
@isTest
public class ConcurrencyGateTest {
  private static Concurrency_Config__mdt mockConfig(
    String developerName,
    Integer ceiling
  ) {
    return (Concurrency_Config__mdt) JSON.deserialize(
      '{"DeveloperName":"' +
        developerName +
        '","Max_Concurrent_Instances__c":' +
        ceiling +
        '}',
      Concurrency_Config__mdt.class
    );
  }

  // ── AC1: CMDT resolution by DeveloperName, with Default fallback ────────────
  @isTest
  static void testCeilingResolvesByDeveloperName() {
    ConcurrencyGate.mockConfigs.put('MyWorkflow', mockConfig('MyWorkflow', 5));
    Test.startTest();
    System.assertEquals(
      5,
      ConcurrencyGate.getCeiling('MyWorkflow'),
      'Exact DeveloperName match should resolve the ceiling'
    );
    Test.stopTest();
  }

  @isTest
  static void testCeilingNormalizesInnerClassName() {
    // Inner/nested class names map dots to underscores, like Workflow_Alert_Config__mdt.
    ConcurrencyGate.mockConfigs.put(
      'Outer_Inner',
      mockConfig('Outer_Inner', 3)
    );
    Test.startTest();
    System.assertEquals(
      3,
      ConcurrencyGate.getCeiling('Outer.Inner'),
      'Dotted class name should normalize to the underscore DeveloperName'
    );
    Test.stopTest();
  }

  @isTest
  static void testCeilingFallsBackToDefault() {
    ConcurrencyGate.mockConfigs.put('Default', mockConfig('Default', 7));
    Test.startTest();
    System.assertEquals(
      7,
      ConcurrencyGate.getCeiling('SomeUnconfiguredWorkflow'),
      'A workflow with no specific record should fall back to Default'
    );
    Test.stopTest();
  }

  @isTest
  static void testUnconfiguredIsUnbounded() {
    Test.startTest();
    System.assertEquals(
      null,
      ConcurrencyGate.getCeiling('NothingConfigured'),
      'No config and no Default should resolve to null (unbounded)'
    );
    System.assertEquals(
      false,
      ConcurrencyGate.isConfigured('NothingConfigured'),
      'isConfigured should be false when unbounded'
    );
    Test.stopTest();
  }

  @isTest
  static void testEngineWorkflowsAreExempt() {
    // A Default config must never throttle the engine's perpetual watchdog.
    ConcurrencyGate.mockConfigs.put('Default', mockConfig('Default', 1));
    Test.startTest();
    System.assertEquals(
      null,
      ConcurrencyGate.getCeiling('WatchdogWorkflow'),
      'WatchdogWorkflow must be exempt from concurrency gating'
    );
    Test.stopTest();
  }

  // ── Acquire / release against the durable counter ──────────────────────────
  @isTest
  static void testAcquireUpToCeilingThenDeny() {
    ConcurrencyGate.mockConfigs.put('Cap2', mockConfig('Cap2', 2));
    Test.startTest();
    ConcurrencyGate.AdmissionResult a1 = ConcurrencyGate.tryAcquire('Cap2');
    ConcurrencyGate.AdmissionResult a2 = ConcurrencyGate.tryAcquire('Cap2');
    ConcurrencyGate.AdmissionResult a3 = ConcurrencyGate.tryAcquire('Cap2');
    Test.stopTest();

    System.assert(a1.admitted && a1.slotConsumed, 'First acquire admitted');
    System.assert(a2.admitted && a2.slotConsumed, 'Second acquire admitted');
    System.assert(!a3.admitted, 'Third acquire denied at ceiling');
    System.assert(!a3.slotConsumed, 'Denied acquire consumes no slot');

    Concurrency_State__c state = [
      SELECT In_Flight_Count__c
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c = 'Cap2'
    ];
    System.assertEquals(2, state.In_Flight_Count__c, 'Counter capped at 2');
  }

  @isTest
  static void testUnboundedConsumesNoSlot() {
    Test.startTest();
    ConcurrencyGate.AdmissionResult a = ConcurrencyGate.tryAcquire('Unbounded');
    Test.stopTest();
    System.assert(a.admitted, 'Unbounded always admitted');
    System.assert(!a.slotConsumed, 'Unbounded consumes no slot');
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Concurrency_State__c WHERE Workflow_Definition__c = 'Unbounded'],
      'No state row created for an unbounded workflow'
    );
  }

  @isTest
  static void testReleaseDecrementsAndAdmits() {
    ConcurrencyGate.mockConfigs.put('Cap1', mockConfig('Cap1', 1));
    Test.startTest();
    System.assert(ConcurrencyGate.tryAcquire('Cap1').admitted, 'First admitted');
    System.assert(!ConcurrencyGate.tryAcquire('Cap1').admitted, 'Second denied (full)');
    ConcurrencyGate.release('Cap1', 1);
    System.assert(
      ConcurrencyGate.tryAcquire('Cap1').admitted,
      'After release a parked instance can be admitted'
    );
    Test.stopTest();
  }

  @isTest
  static void testReleaseFloorsAtZero() {
    ConcurrencyGate.mockConfigs.put('Cap3', mockConfig('Cap3', 3));
    Test.startTest();
    ConcurrencyGate.tryAcquire('Cap3');
    ConcurrencyGate.release('Cap3', 5); // over-release must not go negative
    Test.stopTest();
    Concurrency_State__c state = [
      SELECT In_Flight_Count__c
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c = 'Cap3'
    ];
    System.assertEquals(0, state.In_Flight_Count__c, 'Counter floored at 0');
  }

  @isTest
  static void testReleaseBulkGroupsByWorkflow() {
    ConcurrencyGate.mockConfigs.put('CapA', mockConfig('CapA', 5));
    ConcurrencyGate.mockConfigs.put('CapB', mockConfig('CapB', 5));
    ConcurrencyGate.tryAcquire('CapA');
    ConcurrencyGate.tryAcquire('CapA');
    ConcurrencyGate.tryAcquire('CapB');

    Test.startTest();
    ConcurrencyGate.releaseBulk(
      new Map<String, Integer>{ 'CapA' => 2, 'CapB' => 1 }
    );
    Test.stopTest();

    Map<String, Decimal> byKey = new Map<String, Decimal>();
    for (Concurrency_State__c s : [
      SELECT Workflow_Definition__c, In_Flight_Count__c
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c IN ('CapA', 'CapB')
    ]) {
      byKey.put(s.Workflow_Definition__c, s.In_Flight_Count__c);
    }
    System.assertEquals(0, byKey.get('CapA'), 'CapA released by 2');
    System.assertEquals(0, byKey.get('CapB'), 'CapB released by 1');
  }

  // ── AC5: reconciliation reclaims leaked slots ──────────────────────────────
  @isTest
  static void testReconcileReclaimsLeakedSlots() {
    ConcurrencyGate.mockConfigs.put('LeakWf', mockConfig('LeakWf', 10));
    // Simulate a leaked counter: 3 reserved, but only 1 instance genuinely holds a
    // slot in a non-terminal state. The other 2 "died" (e.g. a terminal transition
    // that lost its decrement, or a forced kill).
    insert new Concurrency_State__c(
      Workflow_Definition__c = 'LeakWf',
      In_Flight_Count__c = 3
    );
    insert new Workflow_Instance__c(
      Workflow_Name__c = 'LeakWf',
      Status__c = 'Running',
      Correlation_Key__c = 'leak-alive',
      Concurrency_Slot_Held__c = true
    );
    // A terminal instance that still carries a stale flag must NOT be counted.
    insert new Workflow_Instance__c(
      Workflow_Name__c = 'LeakWf',
      Status__c = 'Completed',
      Correlation_Key__c = 'leak-dead',
      Concurrency_Slot_Held__c = true
    );

    Test.startTest();
    ConcurrencyGate.reconcile('LeakWf');
    Test.stopTest();

    Concurrency_State__c state = [
      SELECT In_Flight_Count__c
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c = 'LeakWf'
    ];
    System.assertEquals(
      1,
      state.In_Flight_Count__c,
      'Reconcile should set the counter to the true non-terminal slot-holder count'
    );
  }

  @isTest
  static void testReconcileAllSweepsEveryStateRow() {
    insert new Concurrency_State__c(
      Workflow_Definition__c = 'SweepWf',
      In_Flight_Count__c = 4
    );
    insert new Workflow_Instance__c(
      Workflow_Name__c = 'SweepWf',
      Status__c = 'Running',
      Correlation_Key__c = 'sweep-1',
      Concurrency_Slot_Held__c = true
    );

    Test.startTest();
    ConcurrencyGate.reconcileAll();
    Test.stopTest();

    System.assertEquals(
      1,
      [
        SELECT In_Flight_Count__c
        FROM Concurrency_State__c
        WHERE Workflow_Definition__c = 'SweepWf'
      ]
      .In_Flight_Count__c,
      'reconcileAll should reconcile every existing state row'
    );
  }

  @isTest
  static void testLazyProvisionDuplicateRace() {
    ConcurrencyGate.mockConfigs.put('RaceWf', mockConfig('RaceWf', 5));
    insert new Concurrency_State__c(
      Workflow_Definition__c = 'RaceWf',
      In_Flight_Count__c = 0
    );
    ConcurrencyGate.simulateDuplicateOnInsert = true;

    Test.startTest();
    ConcurrencyGate.AdmissionResult a = ConcurrencyGate.tryAcquire('RaceWf');
    Test.stopTest();

    System.assert(
      a.admitted && a.slotConsumed,
      'Should recover from a duplicate-insert race and consume the existing row'
    );
    System.assertEquals(
      1,
      [
        SELECT In_Flight_Count__c
        FROM Concurrency_State__c
        WHERE Workflow_Definition__c = 'RaceWf'
      ]
      .In_Flight_Count__c,
      'Existing row incremented after race recovery'
    );
  }
}
