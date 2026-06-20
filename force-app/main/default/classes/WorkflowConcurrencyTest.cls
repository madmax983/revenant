/**
 * TDD tests for per-workflow-definition concurrency limits (issue #28).
 * Written BEFORE the implementation (red phase): every test here should fail
 * against code that lacks ConcurrencyGate, the admission gate in runStep, the
 * terminal slot-release in WorkflowInstanceTrigger, and the watchdog reconcile sweep.
 *
 * Acceptance-criteria coverage:
 *  AC2/AC3 — admission caps in-flight at N; the (N+1)th start parks (Suspended +
 *            Concurrency_Parked__c) and does not execute its step.
 *  AC4     — every terminal transition (Completed/Failed/Cancelled/Compensated)
 *            releases the slot so a parked instance is admitted afterward.
 *  AC5     — the watchdog reconcile sweep reclaims a leaked slot within one sweep.
 *  AC6     — a workflow with no config (and no Default) is unbounded, exactly as today.
 *  AC8     — append-only step records and the compensation stack are unaffected.
 */
@isTest
public class WorkflowConcurrencyTest {
  private static final String WF = 'WorkflowConcurrencyTest.WaitWorkflow';

  // A workflow whose single step suspends (waits for a signal), so an admitted
  // instance stays in-flight holding its slot until it is driven terminal.
  public class WaitWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'WorkflowConcurrencyTest.WaitStep';
    }
    public String getNextStep(String current, StepResult result) {
      return null;
    }
  }

  public class WaitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.suspend();
    }
  }

  private static Concurrency_Config__mdt cfg(Integer ceiling) {
    return (Concurrency_Config__mdt) JSON.deserialize(
      '{"DeveloperName":"WorkflowConcurrencyTest_WaitWorkflow","Max_Concurrent_Instances__c":' +
        ceiling +
        '}',
      Concurrency_Config__mdt.class
    );
  }

  // Creates a fresh, not-yet-admitted instance (mirrors doStart's pre-enqueue
  // shape: Pending instance + Pending initial step), so runStep drives admission.
  private static Id newPendingInstance(String key) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Pending',
      Current_Step__c = 'WorkflowConcurrencyTest.WaitStep',
      Correlation_Key__c = key
    );
    insert inst;
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowConcurrencyTest.WaitStep',
      Status__c = 'Pending',
      Retry_Count__c = 0
    );
    return inst.Id;
  }

  private static Workflow_Instance__c reload(Id id) {
    return [
      SELECT Status__c, Concurrency_Slot_Held__c, Concurrency_Parked__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :id
    ];
  }

  private static Decimal counter() {
    List<Concurrency_State__c> rows = [
      SELECT In_Flight_Count__c
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c = :WF
    ];
    return rows.isEmpty() ? null : rows[0].In_Flight_Count__c;
  }

  // ── AC2 / AC3: admission caps in-flight at the ceiling ─────────────────────
  @isTest
  static void testAdmissionCapsInFlight() {
    WorkflowEngine.disableQueueableInTest = true;
    ConcurrencyGate.mockConfigs.put(
      'WorkflowConcurrencyTest_WaitWorkflow',
      cfg(2)
    );

    Id i1 = newPendingInstance('conc-1');
    Id i2 = newPendingInstance('conc-2');
    Id i3 = newPendingInstance('conc-3');

    Test.startTest();
    WorkflowEngine.runStep(i1, null); // acquires slot 1 (admission re-hop)
    WorkflowEngine.runStep(i2, null); // acquires slot 2
    WorkflowEngine.runStep(i3, null); // ceiling full -> parks
    Test.stopTest();

    System.assertEquals(2, counter(), 'Only 2 slots consumed at ceiling=2');

    System.assert(reload(i1).Concurrency_Slot_Held__c, 'i1 holds a slot');
    System.assert(reload(i2).Concurrency_Slot_Held__c, 'i2 holds a slot');

    Workflow_Instance__c r3 = reload(i3);
    System.assertEquals('Suspended', r3.Status__c, 'i3 parks as Suspended');
    System.assert(r3.Concurrency_Parked__c, 'i3 is flagged parked');
    System.assert(!r3.Concurrency_Slot_Held__c, 'i3 holds no slot');
    System.assertNotEquals(null, r3.Sleep_Until__c, 'i3 has an admission-retry wake time');

    // Running/Compensating instances never exceed the ceiling (AC3).
    Integer running = [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE Workflow_Name__c = :WF AND Status__c IN ('Running', 'Compensating')
    ];
    System.assert(running <= 2, 'Running/Compensating never exceeds the ceiling');

    // i3's step must not have executed while parked (AC2).
    Integer executed = [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :i3 AND Status__c IN ('Running', 'Completed')
    ];
    System.assertEquals(0, executed, 'A parked instance executes no step');
  }

  // ── AC4: terminal transition releases the slot; a parked instance admits ───
  @isTest
  static void testTerminalReleaseAdmitsParked() {
    WorkflowEngine.disableQueueableInTest = true;
    ConcurrencyGate.mockConfigs.put(
      'WorkflowConcurrencyTest_WaitWorkflow',
      cfg(1)
    );

    Id i1 = newPendingInstance('rel-1');
    Id i2 = newPendingInstance('rel-2');

    WorkflowEngine.runStep(i1, null); // acquires the only slot
    WorkflowEngine.runStep(i2, null); // parks
    System.assertEquals(1, counter(), 'Slot full');
    System.assert(reload(i2).Concurrency_Parked__c, 'i2 parked');

    Test.startTest();
    // Drive i1 to a terminal state — the instance trigger releases its slot.
    update new Workflow_Instance__c(Id = i1, Status__c = 'Completed');
    System.assertEquals(0, counter(), 'Terminal transition decrements the counter');

    // Re-attempt admission for the parked instance: now there is a free slot.
    WorkflowEngine.runStep(i2, null);
    Test.stopTest();

    Workflow_Instance__c r2 = reload(i2);
    System.assert(r2.Concurrency_Slot_Held__c, 'i2 admitted after a slot freed');
    System.assert(!r2.Concurrency_Parked__c, 'i2 no longer parked once admitted');
    System.assertEquals(1, counter(), 'Counter back to 1 after re-admission');
  }

  @isTest
  static void testEachTerminalTypeReleasesSlot() {
    ConcurrencyGate.mockConfigs.put(
      'WorkflowConcurrencyTest_WaitWorkflow',
      cfg(10)
    );
    for (String terminal : new List<String>{
      'Completed',
      'Failed',
      'Cancelled',
      'Compensated'
    }) {
      Id id = newPendingInstance('term-' + terminal);
      WorkflowEngine.runStep(id, null); // acquire
      Decimal before = counter();
      update new Workflow_Instance__c(Id = id, Status__c = terminal);
      System.assertEquals(
        before - 1,
        counter(),
        terminal + ' must release the slot'
      );
      System.assert(
        !reload(id).Concurrency_Slot_Held__c,
        terminal + ' clears the slot-held flag'
      );
    }
  }

  // CompensationFailed is non-terminal (recoverable) and must keep its slot.
  @isTest
  static void testCompensationFailedKeepsSlot() {
    ConcurrencyGate.mockConfigs.put(
      'WorkflowConcurrencyTest_WaitWorkflow',
      cfg(10)
    );
    Id id = newPendingInstance('cf-1');
    WorkflowEngine.runStep(id, null);
    Decimal before = counter();
    Test.startTest();
    update new Workflow_Instance__c(Id = id, Status__c = 'CompensationFailed');
    Test.stopTest();
    System.assertEquals(before, counter(), 'CompensationFailed retains its slot');
    System.assert(
      reload(id).Concurrency_Slot_Held__c,
      'A recoverable rollback still holds its slot'
    );
  }

  // ── AC6: no config -> unbounded, behaves exactly as today ──────────────────
  @isTest
  static void testUnconfiguredIsUnbounded() {
    WorkflowEngine.disableQueueableInTest = true;
    // No mockConfig and no Default record => unbounded.
    Id i1 = newPendingInstance('unb-1');
    Id i2 = newPendingInstance('unb-2');
    Id i3 = newPendingInstance('unb-3');

    Test.startTest();
    WorkflowEngine.runStep(i1, null);
    WorkflowEngine.runStep(i2, null);
    WorkflowEngine.runStep(i3, null);
    Test.stopTest();

    // No state row, no parking, no slot flags — all instances proceed.
    System.assertEquals(null, counter(), 'No counter row for an unbounded workflow');
    for (Id id : new List<Id>{ i1, i2, i3 }) {
      Workflow_Instance__c r = reload(id);
      System.assert(!r.Concurrency_Parked__c, 'Unbounded never parks for concurrency');
      System.assert(!r.Concurrency_Slot_Held__c, 'Unbounded holds no slot');
    }
  }

  // ── AC5: watchdog reconcile reclaims a leaked slot within one sweep ────────
  @isTest
  static void testWatchdogReconcilesLeakedSlot() {
    insert new Concurrency_State__c(
      Workflow_Definition__c = WF,
      In_Flight_Count__c = 5 // leaked: more than reality
    );
    // Exactly one instance genuinely holds a slot in a non-terminal state.
    insert new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Suspended',
      Correlation_Key__c = 'recon-alive',
      Concurrency_Slot_Held__c = true
    );

    Test.startTest();
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    System.assertEquals(
      1,
      counter(),
      'Watchdog reconcile reclaims leaked slots within one sweep'
    );
  }

  // ── AC8: step records stay append-only; compensation stack untouched ───────
  @isTest
  static void testAppendOnlyStepRecordsAcrossParkAndAdmit() {
    WorkflowEngine.disableQueueableInTest = true;
    ConcurrencyGate.mockConfigs.put(
      'WorkflowConcurrencyTest_WaitWorkflow',
      cfg(1)
    );
    Id i1 = newPendingInstance('ao-1');
    Id i2 = newPendingInstance('ao-2');

    WorkflowEngine.runStep(i1, null); // acquire
    Integer stepsAfterStart = [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :i2
    ];

    Test.startTest();
    WorkflowEngine.runStep(i2, null); // park
    WorkflowEngine.runStep(i2, null); // re-attempt (still full) -> re-park
    Test.stopTest();

    Integer stepsAfterPark = [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :i2
    ];
    System.assertEquals(
      stepsAfterStart,
      stepsAfterPark,
      'Parking and re-parking must not append or remove step audit records'
    );
    System.assertEquals(
      null,
      [SELECT Compensation_Stack__c FROM Workflow_Instance__c WHERE Id = :i2]
      .Compensation_Stack__c,
      'Slot accounting must not touch the compensation stack'
    );
  }
}
