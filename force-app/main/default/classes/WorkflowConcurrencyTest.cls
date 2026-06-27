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
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowConcurrencyTest.WaitStep' };
    }
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

  // A bounded workflow whose initial step declares a timeout — used to prove the
  // initial step's deadline is deferred until admission for configured workflows.
  public class TimeoutWaitWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowConcurrencyTest.TimeoutWaitStep' };
    }
    public String getInitialStep() {
      return 'WorkflowConcurrencyTest.TimeoutWaitStep';
    }
    public String getNextStep(String current, StepResult result) {
      return null;
    }
  }

  public class TimeoutWaitStep implements WorkflowStep, TimeoutConfigurable {
    public Integer getTimeoutSeconds() {
      return 300;
    }
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
    WorkflowEngine.disableQueueableInTest = true;
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
    WorkflowEngine.disableQueueableInTest = true;
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

  // A parked instance carries an admission-retry Sleep_Until__c; admission must
  // clear it so a later SUSPEND/approval wait is not re-driven by the watchdog as a
  // due sleeper without its signal.
  @isTest
  static void testAdmissionClearsSleepDeadline() {
    WorkflowEngine.disableQueueableInTest = true;
    ConcurrencyGate.mockConfigs.put(
      'WorkflowConcurrencyTest_WaitWorkflow',
      cfg(1)
    );
    Id i1 = newPendingInstance('sleep-1');
    Id i2 = newPendingInstance('sleep-2');

    WorkflowEngine.runStep(i1, null); // acquire the only slot
    WorkflowEngine.runStep(i2, null); // park -> Sleep_Until__c set
    System.assertNotEquals(
      null,
      reload(i2).Sleep_Until__c,
      'Parked instance has a retry deadline'
    );

    Test.startTest();
    update new Workflow_Instance__c(Id = i1, Status__c = 'Completed'); // free the slot
    WorkflowEngine.runStep(i2, null); // re-attempt admission -> admitted
    Test.stopTest();

    Workflow_Instance__c r2 = reload(i2);
    System.assert(r2.Concurrency_Slot_Held__c, 'i2 admitted');
    System.assertEquals(
      null,
      r2.Sleep_Until__c,
      'Admission must clear the stale admission-retry sleep deadline'
    );
  }

  // A bounded workflow whose class no longer resolves must fail cleanly without
  // holding a slot (which reconciliation would otherwise count forever).
  @isTest
  static void testUnresolvableWorkflowClassFailsWithoutHoldingSlot() {
    WorkflowEngine.disableQueueableInTest = true;
    ConcurrencyGate.mockConfigs.put(
      'NoSuchClass_Workflow',
      (Concurrency_Config__mdt) JSON.deserialize(
        '{"DeveloperName":"NoSuchClass_Workflow","Max_Concurrent_Instances__c":3}',
        Concurrency_Config__mdt.class
      )
    );
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'NoSuchClass.Workflow',
      Status__c = 'Pending',
      Correlation_Key__c = 'unresolvable-1'
      // Current_Step__c intentionally blank — class can't resolve an initial step.
    );
    insert inst;

    Test.startTest();
    Boolean threw = false;
    try {
      WorkflowEngine.runStep(inst.Id, null);
    } catch (Exception e) {
      threw = true;
      System.assert(
        e.getMessage().contains('Could not resolve workflow definition class'),
        'Expected an unresolved-class failure, got: ' + e.getMessage()
      );
    }
    Test.stopTest();

    System.assert(threw, 'Admission must fail for an unresolvable workflow class');
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Concurrency_State__c
        WHERE Workflow_Definition__c = 'NoSuchClass.Workflow'
      ],
      'No slot should be consumed for an unresolvable workflow class'
    );
    System.assert(
      ![SELECT Concurrency_Slot_Held__c FROM Workflow_Instance__c WHERE Id = :inst.Id]
        .Concurrency_Slot_Held__c,
      'Instance must not hold a slot after a failed admission'
    );
  }

  // A bounded start must NOT arm the initial step's watchdog deadline until a slot
  // is won, so an overflow start sitting Pending in the backlog during a burst can't
  // be failed by the timeout sweep before it ever parks.
  @isTest
  static void testBoundedStartDefersInitialTimeout() {
    WorkflowEngine.disableQueueableInTest = true;
    ConcurrencyGate.mockConfigs.put(
      'WorkflowConcurrencyTest_TimeoutWaitWorkflow',
      (Concurrency_Config__mdt) JSON.deserialize(
        '{"DeveloperName":"WorkflowConcurrencyTest_TimeoutWaitWorkflow","Max_Concurrent_Instances__c":5}',
        Concurrency_Config__mdt.class
      )
    );

    Test.startTest();
    Id id = WorkflowEngine.start(
      'WorkflowConcurrencyTest.TimeoutWaitWorkflow',
      'defer-1',
      null
    );
    // Before the first RUN_STEP/admission runs, the initial step must carry no
    // timeout deadline even though TimeoutWaitStep declares one.
    Workflow_Step_Execution__c step = [
      SELECT Status__c, Timeout_At__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :id
      LIMIT 1
    ];
    Test.stopTest();

    System.assertEquals('Pending', step.Status__c, 'Initial step is Pending pre-admission');
    System.assertEquals(
      null,
      step.Timeout_At__c,
      'Bounded start must defer the initial step timeout until admission'
    );
  }

  // The bulk startOrGet path (Flow/scheduled bulk starts) must mirror doStart: a
  // bounded start gets no initial watchdog deadline until a slot is won, so an
  // overflow item sitting Pending in the backlog during a burst can't be failed by
  // the timeout sweep before it ever reaches the admission gate to park.
  @isTest
  static void testBoundedBulkStartDefersInitialTimeout() {
    WorkflowEngine.disableQueueableInTest = true;
    ConcurrencyGate.mockConfigs.put(
      'WorkflowConcurrencyTest_TimeoutWaitWorkflow',
      (Concurrency_Config__mdt) JSON.deserialize(
        '{"DeveloperName":"WorkflowConcurrencyTest_TimeoutWaitWorkflow","Max_Concurrent_Instances__c":5}',
        Concurrency_Config__mdt.class
      )
    );

    List<WorkflowEngine.StartRequest> reqs = new List<WorkflowEngine.StartRequest>{
      new WorkflowEngine.StartRequest(
        'WorkflowConcurrencyTest.TimeoutWaitWorkflow',
        'bulk-defer-1',
        null
      ),
      new WorkflowEngine.StartRequest(
        'WorkflowConcurrencyTest.TimeoutWaitWorkflow',
        'bulk-defer-2',
        null
      )
    };

    Test.startTest();
    List<WorkflowEngine.StartResult> results = WorkflowEngine.startOrGet(reqs);
    Test.stopTest();

    System.assertEquals(2, results.size(), 'Both bulk starts return a result');
    for (WorkflowEngine.StartResult res : results) {
      Workflow_Step_Execution__c step = [
        SELECT Status__c, Timeout_At__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :res.instanceId
        LIMIT 1
      ];
      System.assertEquals(
        'Pending',
        step.Status__c,
        'Bulk-started bounded step is Pending pre-admission'
      );
      System.assertEquals(
        null,
        step.Timeout_At__c,
        'Bounded bulk start must defer the initial step timeout until admission'
      );
    }
  }

  // A stray scheduled timeout job must never fail a step whose deadline is null when
  // the instance is durably marked as awaiting an admission slot (Concurrency_Parked__c)
  // — the state of a deferred bounded start (or a parked step) awaiting capacity. The
  // skip is scoped to that durable marker, not the live CMDT: an unbounded null-deadline
  // step (parked=false) is the pre-start watchdog and must still fail (see
  // testTimeoutJobFailsNullDeadlinePreStartWatchdog), even if a ceiling is added later.
  @isTest
  static void testTimeoutJobSkipsNullDeadlineStep() {
    // Durable awaiting-admission marker => the null deadline is a deferred-admission
    // state, regardless of the current concurrency config.
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Running',
      Current_Step__c = 'WorkflowConcurrencyTest.WaitStep',
      Correlation_Key__c = 'nulldl-1',
      Concurrency_Parked__c = true
    );
    insert inst;
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowConcurrencyTest.WaitStep',
      Status__c = 'Pending',
      Retry_Count__c = 0
      // Timeout_At__c intentionally left null (deferred/cleared).
    );

    Test.startTest();
    new WorkflowTimeoutJob(inst.Id, 'WorkflowConcurrencyTest.WaitStep')
      .executeInternal();
    Test.stopTest();

    Workflow_Step_Execution__c step = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :inst.Id
      LIMIT 1
    ];
    System.assertEquals(
      'Pending',
      step.Status__c,
      'A null-deadline step must not be failed by a stray timeout job'
    );
    System.assertNotEquals(
      'Failed',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id]
        .Status__c,
      'Instance must not be failed when its step had no armed deadline'
    );
  }

  // The mirror of the above: for an UNBOUNDED instance (no ceiling, no slot), a null
  // deadline on an existing Pending step is the pre-start watchdog — e.g. a child or
  // continueAsNew successor whose initial step was precreated with no deadline and a
  // scheduled timeout job, whose worker was then lost before the step armed its own
  // deadline. The timeout job MUST fail it "before starting" rather than skip it.
  @isTest
  static void testTimeoutJobFailsNullDeadlinePreStartWatchdog() {
    // A ceiling is present NOW (as if an admin added it after this unbounded child
    // scheduled its pre-start watchdog), but the instance was never durably marked as
    // awaiting admission (Concurrency_Parked__c = false). The skip must key off that
    // durable marker, not the live config — so the null-deadline pre-start watchdog
    // still fails the overdue step instead of leaving it Pending forever.
    ConcurrencyGate.mockConfigs.put('WorkflowConcurrencyTest_WaitWorkflow', cfg(1));
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Running',
      Current_Step__c = 'WorkflowConcurrencyTest.WaitStep',
      Correlation_Key__c = 'prestart-1'
    );
    insert inst;
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowConcurrencyTest.WaitStep',
      Status__c = 'Pending',
      Retry_Count__c = 0
      // Timeout_At__c null: precreated handoff step awaiting its first execution.
    );

    Test.startTest();
    new WorkflowTimeoutJob(inst.Id, 'WorkflowConcurrencyTest.WaitStep')
      .executeInternal();
    Test.stopTest();

    System.assertEquals(
      'Failed',
      [SELECT Status__c FROM Workflow_Step_Execution__c WHERE Workflow_Instance__c = :inst.Id LIMIT 1]
        .Status__c,
      'An unbounded null-deadline pre-start step must be failed by its watchdog'
    );
    System.assertEquals(
      'Failed',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id].Status__c,
      'The instance fails when its lost pre-start step times out'
    );
  }

  // The watchdog wake path must not flip a concurrency-parked sleeper to Running: it
  // has not won a slot, so flipping it would leave a Running row holding no slot and
  // hide it from the parked count. It is re-driven through the admission gate while
  // staying Suspended/parked.
  @isTest
  static void testWatchdogWakeKeepsParkedSuspended() {
    WorkflowEngine.disableQueueableInTest = true;
    ConcurrencyGate.mockConfigs.put('WorkflowConcurrencyTest_WaitWorkflow', cfg(1));

    Id i1 = newPendingInstance('wake-1');
    Id i2 = newPendingInstance('wake-2');
    WorkflowEngine.runStep(i1, null); // admits, holds the only slot
    WorkflowEngine.runStep(i2, null); // ceiling full -> parks
    System.assert(reload(i2).Concurrency_Parked__c, 'i2 parked');

    // Make the admission retry due so the watchdog wake path selects it.
    update new Workflow_Instance__c(
      Id = i2,
      Sleep_Until__c = DateTime.now().addSeconds(-60)
    );

    Test.startTest();
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    Workflow_Instance__c r2 = reload(i2);
    System.assertEquals(
      'Suspended',
      r2.Status__c,
      'A concurrency-parked sleeper stays Suspended until admission, not Running'
    );
    System.assert(
      r2.Concurrency_Parked__c,
      'Parked flag preserved through the watchdog wake'
    );
    System.assert(!r2.Concurrency_Slot_Held__c, 'Still holds no slot');
  }

  // When an admin removes/disables a ceiling while an instance is parked under it, the
  // unbounded fallthrough must clear the stale admission-retry markers so a leftover
  // due Sleep_Until__c cannot make the watchdog re-run a later real SUSPEND.
  @isTest
  static void testUnboundedFallthroughClearsStaleParkMarkers() {
    WorkflowEngine.disableQueueableInTest = true;
    // No mockConfig for WF => isConfigured is false (ceiling removed/disabled).
    Id id = newPendingInstance('stale-1');
    // Simulate the row as it looked while parked under a since-removed ceiling.
    update new Workflow_Instance__c(
      Id = id,
      Status__c = 'Suspended',
      Concurrency_Parked__c = true,
      Sleep_Until__c = DateTime.now().addSeconds(-60),
      Async_Job_Id__c = 'STALEJOB123'
    );

    Test.startTest();
    WorkflowEngine.runStep(id, null); // unbounded now -> runs, clearing stale markers
    Test.stopTest();

    Workflow_Instance__c r = [
      SELECT Concurrency_Parked__c, Sleep_Until__c, Async_Job_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :id
    ];
    System.assert(
      !r.Concurrency_Parked__c,
      'Stale parked flag cleared once the workflow is unbounded'
    );
    System.assertEquals(
      null,
      r.Sleep_Until__c,
      'Stale admission-retry wake time cleared'
    );
    System.assertEquals(null, r.Async_Job_Id__c, 'Stale retry job id cleared');
  }

  // reArmTimeoutsForResume (paused-resume and admission-re-drive) must defer the
  // deadline for a bounded instance that has NOT yet won a slot, while still arming
  // one for a slot-holder (the admission path calls it after acquiring).
  @isTest
  static void testReArmDefersTimeoutForBoundedUnadmitted() {
    ConcurrencyGate.mockConfigs.put(
      'WorkflowConcurrencyTest_TimeoutWaitWorkflow',
      (Concurrency_Config__mdt) JSON.deserialize(
        '{"DeveloperName":"WorkflowConcurrencyTest_TimeoutWaitWorkflow","Max_Concurrent_Instances__c":1}',
        Concurrency_Config__mdt.class
      )
    );

    Workflow_Instance__c unadmitted = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowConcurrencyTest.TimeoutWaitWorkflow',
      Status__c = 'Running',
      Current_Step__c = 'WorkflowConcurrencyTest.TimeoutWaitStep',
      Correlation_Key__c = 'rearm-defer',
      Concurrency_Slot_Held__c = false
    );
    Workflow_Instance__c admitted = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowConcurrencyTest.TimeoutWaitWorkflow',
      Status__c = 'Running',
      Current_Step__c = 'WorkflowConcurrencyTest.TimeoutWaitStep',
      Correlation_Key__c = 'rearm-arm',
      Concurrency_Slot_Held__c = true
    );
    insert new List<Workflow_Instance__c>{ unadmitted, admitted };
    insert new List<Workflow_Step_Execution__c>{
      new Workflow_Step_Execution__c(
        Workflow_Instance__c = unadmitted.Id,
        Step_Name__c = 'WorkflowConcurrencyTest.TimeoutWaitStep',
        Status__c = 'Pending',
        Retry_Count__c = 0
      ),
      new Workflow_Step_Execution__c(
        Workflow_Instance__c = admitted.Id,
        Step_Name__c = 'WorkflowConcurrencyTest.TimeoutWaitStep',
        Status__c = 'Pending',
        Retry_Count__c = 0
      )
    };

    Test.startTest();
    WorkflowEngine.reArmTimeoutsForResume(
      new List<Workflow_Instance__c>{ unadmitted, admitted }
    );
    Test.stopTest();

    Workflow_Step_Execution__c deferStep = [
      SELECT Timeout_At__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :unadmitted.Id
      LIMIT 1
    ];
    Workflow_Step_Execution__c armStep = [
      SELECT Timeout_At__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :admitted.Id
      LIMIT 1
    ];
    System.assertEquals(
      null,
      deferStep.Timeout_At__c,
      'An unadmitted bounded instance defers its deadline until admission'
    );
    System.assertNotEquals(
      null,
      armStep.Timeout_At__c,
      'A slot-holding bounded instance is re-armed normally'
    );
  }

  // A signal addressed to a concurrency-parked instance must not wake it to Running
  // before it owns a slot — that would leave a Running row with no slot (violating the
  // no-running-without-slot invariant) and hide it from the parked count. The signal
  // is captured (Received) and observed once admission drives the step.
  @isTest
  static void testSignalDoesNotWakeParkedRow() {
    WorkflowEngine.disableQueueableInTest = true;
    ConcurrencyGate.mockConfigs.put('WorkflowConcurrencyTest_WaitWorkflow', cfg(1));

    Id i1 = newPendingInstance('sig-1');
    Id i2 = newPendingInstance('sig-2');
    WorkflowEngine.runStep(i1, null); // admits, holds the only slot
    WorkflowEngine.runStep(i2, null); // ceiling full -> parks
    System.assert(reload(i2).Concurrency_Parked__c, 'i2 parked');

    Test.startTest();
    WorkflowEngine.signal('sig-2', 'go', null);
    Test.stopTest();

    Workflow_Instance__c r2 = reload(i2);
    System.assertEquals(
      'Suspended',
      r2.Status__c,
      'A concurrency-parked row must not be woken to Running by a signal pre-admission'
    );
    System.assert(r2.Concurrency_Parked__c, 'Parked flag preserved');
    System.assert(!r2.Concurrency_Slot_Held__c, 'Still holds no slot');
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

  // ── Transient row-lock retry (fan-in lock storm) ───────────────────────────
  // A concurrency cap clusters child completions into release waves, so a burst of
  // ChildCompleted signals (each FOR UPDATE-ing the shared parent row) plus the
  // parent's own join can collide as UNABLE_TO_LOCK_ROW. That is retryable, not a
  // crash: the engine must re-drive the step rather than fail the whole parent.
  @isTest
  static void testIsTransientLockErrorClassification() {
    System.assert(
      WorkflowEngine.isTransientLockError(
        new WorkflowEngine.WorkflowException(
          'UNABLE_TO_LOCK_ROW, unable to obtain exclusive access to this record'
        )
      ),
      'UNABLE_TO_LOCK_ROW must be classified transient'
    );
    System.assert(
      WorkflowEngine.isTransientLockError(
        new WorkflowEngine.WorkflowException(
          'Record Currently Unavailable: the record you are attempting to edit ' +
            'is currently being modified by another user. Please try again.'
        )
      ),
      'Record-currently-unavailable must be classified transient'
    );
    System.assert(
      !WorkflowEngine.isTransientLockError(
        new WorkflowEngine.WorkflowException('FIELD_CUSTOM_VALIDATION_EXCEPTION')
      ),
      'A genuine business error must NOT be classified transient'
    );
    System.assert(
      !WorkflowEngine.isTransientLockError(null),
      'Null must not be classified transient'
    );
  }

  @isTest
  static void testTransientLockCrashRetriesInsteadOfFailing() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Running',
      Current_Step__c = 'WorkflowConcurrencyTest.WaitStep',
      Correlation_Key__c = 'lock-retry-1'
    );
    insert inst;
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowConcurrencyTest.WaitStep',
      Status__c = 'Running',
      Retry_Count__c = 0
    );

    Test.startTest();
    WorkflowEngine.handleCrash(
      inst.Id,
      'WorkflowConcurrencyTest.WaitStep',
      new WorkflowEngine.WorkflowException(
        'UNABLE_TO_LOCK_ROW, unable to obtain exclusive access to this record'
      )
    );

    // handleCrash runs synchronously; assert the parked-for-retry state before the
    // scheduled retry job fires at stopTest.
    Workflow_Instance__c r = [
      SELECT Status__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      'Suspended',
      r.Status__c,
      'A transient lock crash suspends for retry rather than failing'
    );
    System.assertNotEquals(
      null,
      r.Sleep_Until__c,
      'A retry wake time is scheduled'
    );
    Workflow_Step_Execution__c s = [
      SELECT Status__c, Transient_Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :inst.Id
      LIMIT 1
    ];
    System.assertNotEquals(
      'Failed',
      s.Status__c,
      'The step must not be failed on a transient lock error'
    );
    System.assertEquals(
      1,
      s.Transient_Retry_Count__c,
      'The consecutive transient-retry counter is incremented'
    );
    Test.stopTest();
  }

  @isTest
  static void testTransientLockRetryBudgetExhaustionFails() {
    WorkflowEngine.maxTransientLockRetries = 2;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Running',
      Current_Step__c = 'WorkflowConcurrencyTest.WaitStep',
      Correlation_Key__c = 'lock-exhaust-1'
    );
    insert inst;
    // Already at the (shrunk) budget, so the next transient crash must fail.
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowConcurrencyTest.WaitStep',
      Status__c = 'Running',
      Retry_Count__c = 0,
      Transient_Retry_Count__c = 2
    );

    Test.startTest();
    WorkflowEngine.handleCrash(
      inst.Id,
      'WorkflowConcurrencyTest.WaitStep',
      new WorkflowEngine.WorkflowException(
        'UNABLE_TO_LOCK_ROW, unable to obtain exclusive access to this record'
      )
    );
    Test.stopTest();

    System.assertEquals(
      'Failed',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id].Status__c,
      'Once the transient-retry budget is spent the workflow fails as a real crash'
    );
  }

  @isTest
  static void testSuccessfulDriveResetsTransientRetryCount() {
    WorkflowEngine.disableQueueableInTest = true;
    Id i = newPendingInstance('lock-reset-1');
    Workflow_Step_Execution__c s = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :i
      LIMIT 1
    ];
    update new Workflow_Step_Execution__c(
      Id = s.Id,
      Transient_Retry_Count__c = 3
    );

    Test.startTest();
    WorkflowEngine.runStep(i, null); // drives WaitStep -> suspend (a successful drive)
    Test.stopTest();

    System.assertEquals(
      0,
      [
        SELECT Transient_Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :s.Id
      ]
      .Transient_Retry_Count__c,
      'A successful drive resets the consecutive transient-retry counter'
    );
  }

  @isTest
  static void testTransientLockRetryClearsStaleTimeout() {
    // A timeout-configured step that crashes on a transient lock keeps its pre-crash
    // (now stale) Timeout_At__c. If left in place, once the backoff sleep flips the
    // parent back to Running the watchdog timeout batch could fail the step before the
    // retry worker re-drives it. The retry must clear that deadline.
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Running',
      Current_Step__c = 'WorkflowConcurrencyTest.WaitStep',
      Correlation_Key__c = 'lock-timeout-1'
    );
    insert inst;
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowConcurrencyTest.WaitStep',
      Status__c = 'Running',
      Retry_Count__c = 0,
      Timeout_At__c = DateTime.now().addMinutes(-5) // already past
    );

    Test.startTest();
    WorkflowEngine.handleCrash(
      inst.Id,
      'WorkflowConcurrencyTest.WaitStep',
      new WorkflowEngine.WorkflowException(
        'UNABLE_TO_LOCK_ROW, unable to obtain exclusive access to this record'
      )
    );

    Workflow_Step_Execution__c s = [
      SELECT Status__c, Timeout_At__c, Transient_Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :inst.Id
      LIMIT 1
    ];
    System.assertEquals(
      null,
      s.Timeout_At__c,
      'The stale deadline is cleared so the watchdog cannot fail the step mid-backoff'
    );
    System.assertNotEquals(
      'Failed',
      s.Status__c,
      'The step must not be failed on a transient lock error'
    );
    System.assertEquals(
      1,
      s.Transient_Retry_Count__c,
      'The consecutive transient-retry counter is incremented'
    );
    Test.stopTest();
  }

  @isTest
  static void testTransientLockRetryParallelBranchWithoutDynamicScheduling() {
    // With dynamic scheduling off, scheduleRetry returns null. The retry must NOT
    // re-drive the branch immediately (that would bypass the backoff and, under a
    // sustained lock storm, burn the retry budget before contention clears). Instead
    // it suspends with a future Sleep_Until__c and persists the branch target as its
    // Pending step (Transient_Retry_Count__c > 0); the watchdog re-drives that branch
    // BY NAME once the backoff is due (see testWatchdogRedrivesParallelTransientBranch).
    Boolean priorDynamic = WorkflowEngine.useDynamicScheduling;
    WorkflowEngine.useDynamicScheduling = false;
    try {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'Running',
        Current_Step__c = 'WorkflowConcurrencyTest.WaitStep,WorkflowConcurrencyTest.OtherBranch',
        Correlation_Key__c = 'lock-parallel-1'
      );
      insert inst;
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowConcurrencyTest.WaitStep',
        Status__c = 'Running',
        Retry_Count__c = 0
      );

      Test.startTest();
      WorkflowEngine.handleCrash(
        inst.Id,
        'WorkflowConcurrencyTest.WaitStep',
        new WorkflowEngine.WorkflowException(
          'UNABLE_TO_LOCK_ROW, unable to obtain exclusive access to this record'
        )
      );
      Test.stopTest();

      Workflow_Instance__c r = [
        SELECT Status__c, Async_Job_Id__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Suspended',
        r.Status__c,
        'A parallel-branch transient crash suspends for retry rather than failing'
      );
      System.assertEquals(
        null,
        r.Async_Job_Id__c,
        'No delayed job is scheduled when dynamic scheduling is off'
      );
      System.assert(
        r.Sleep_Until__c != null && r.Sleep_Until__c > DateTime.now(),
        'The backoff deadline is written so the branch waits before re-drive ' +
          '(not re-driven immediately)'
      );
      Workflow_Step_Execution__c s = [
        SELECT Status__c, Transient_Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :inst.Id
        LIMIT 1
      ];
      System.assertNotEquals(
        'Failed',
        s.Status__c,
        'The branch step is preserved for direct re-drive, not failed'
      );
      System.assertEquals(
        1,
        s.Transient_Retry_Count__c,
        'The branch consecutive transient-retry counter is incremented'
      );
    } finally {
      WorkflowEngine.useDynamicScheduling = priorDynamic;
    }
  }

  // The watchdog sleep-resume must drive a due, parallel, transient-lock-parked
  // instance back to Running and, in production, re-enqueue its retrying branch BY
  // NAME. The actual branch enqueue honors the manual-drive switch, so with it on this
  // exercises the new per-branch re-arm + query path (no exception, correct scoping)
  // and asserts the wake transition without a drained worker carrying the branch to
  // completion. A non-retrying sibling branch is left as-is.
  @isTest
  static void testWatchdogRedrivesParallelTransientBranch() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Suspended',
      Current_Step__c = 'WorkflowConcurrencyTest.WaitStep,WorkflowConcurrencyTest.OtherBranch',
      Correlation_Key__c = 'wd-parallel-1',
      Sleep_Until__c = DateTime.now().addSeconds(-60)
    );
    insert inst;
    // The retrying branch: Pending with a transient-retry marker — the watchdog's
    // re-drive target.
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowConcurrencyTest.WaitStep',
      Status__c = 'Pending',
      Retry_Count__c = 0,
      Transient_Retry_Count__c = 1
    );
    // A sibling branch that is genuinely in-flight (no transient marker) — must not be
    // selected by the per-branch re-drive query.
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowConcurrencyTest.OtherBranch',
      Status__c = 'Running',
      Retry_Count__c = 0,
      Transient_Retry_Count__c = 0
    );

    // Manual-drive switch ON: the per-branch re-arm + query still run (they sit outside
    // the opt-out guard, like the bulk signal path), but the branch enqueue is gated,
    // so no drained worker re-drives WaitStep and flips the instance back to Suspended.
    // This keeps the wake-transition assertion deterministic while covering the new code.
    Boolean priorDisable = WorkflowEngine.disableQueueableInTest;
    WorkflowEngine.disableQueueableInTest = true;
    try {
      Test.startTest();
      WorkflowEngine.processWatchdogHeartbeat();
      Test.stopTest();
    } finally {
      WorkflowEngine.disableQueueableInTest = priorDisable;
    }

    System.assertEquals(
      'Running',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id]
        .Status__c,
      'The due parallel transient-retry sleeper is woken to Running by the watchdog'
    );
    // The non-retrying sibling branch is untouched by the per-branch re-drive query.
    System.assertEquals(
      'Running',
      [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c = 'WorkflowConcurrencyTest.OtherBranch'
        LIMIT 1
      ]
      .Status__c,
      'A genuinely in-flight sibling branch is not disturbed by the watchdog re-drive'
    );
  }

  // Stuck-forever guard: when a parallel sibling completes during a branch's transient-
  // lock backoff (dynamic scheduling off) it can flip the parent to Running and persist
  // it (a CompensatableStep), so the sleep-resume — which only selects Suspended
  // parents — never re-drives the retry branch. The orphaned-retry sweep must catch it:
  // a Running parallel parent with a due Sleep_Until__c and a retry-marked branch is
  // re-driven by name (here observed via the branch's deadline being re-armed, since
  // the actual enqueue honors the manual-drive switch).
  @isTest
  static void testWatchdogRescuesOrphanedTransientRetryBranch() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowConcurrencyTest.TimeoutWaitWorkflow',
      Status__c = 'Running',
      Current_Step__c = 'WorkflowConcurrencyTest.TimeoutWaitStep,WorkflowConcurrencyTest.OtherBranch',
      Correlation_Key__c = 'orphan-1',
      // The backoff deadline survives on the instance even though a sibling flipped the
      // parent to Running — the signal the orphan sweep keys off.
      Sleep_Until__c = DateTime.now().addSeconds(-60)
    );
    insert inst;
    // Retry-marked branch (TimeoutConfigurable) with its deadline cleared for backoff.
    Workflow_Step_Execution__c branch = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowConcurrencyTest.TimeoutWaitStep',
      Status__c = 'Pending',
      Retry_Count__c = 0,
      Transient_Retry_Count__c = 1
    );
    insert branch;

    WorkflowEngine.disableQueueableInTest = true;
    Test.startTest();
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    // The sweep selected the branch despite the parent being Running (not Suspended)
    // and re-armed its watchdog deadline before the re-drive hand-off.
    System.assertNotEquals(
      null,
      [
        SELECT Timeout_At__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :branch.Id
      ]
      .Timeout_At__c,
      'The orphaned retry branch deadline is re-armed by the rescue sweep'
    );
    // The sweep only re-drives the branch; it does not alter the parent status.
    System.assertEquals(
      'Running',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id]
        .Status__c,
      'The Running parent is left as-is by the orphaned-retry sweep'
    );
  }

  public class MultiStepConcurrencyWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowConcurrencyTest.WaitStep',
        'WorkflowConcurrencyTest.TimeoutWaitStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowConcurrencyTest.WaitStep';
    }
    public String getNextStep(String current, StepResult result) {
      if (current == 'WorkflowConcurrencyTest.WaitStep') {
        return 'WorkflowConcurrencyTest.TimeoutWaitStep';
      }
      return null;
    }
  }

  @isTest
  static void testResumePastStepDefersTimeoutForConcurrency() {
    WorkflowEngine.disableQueueableInTest = true;
    
    // 1. Mock concurrency configuration
    ConcurrencyGate.mockConfigs.put(
      'WorkflowConcurrencyTest_MultiStepConcurrencyWorkflow',
      (Concurrency_Config__mdt) JSON.deserialize(
        '{"DeveloperName":"WorkflowConcurrencyTest_MultiStepConcurrencyWorkflow","Max_Concurrent_Instances__c":1}',
        Concurrency_Config__mdt.class
      )
    );

    // 2. Insert a Failed instance of MultiStepConcurrencyWorkflow
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowConcurrencyTest.MultiStepConcurrencyWorkflow',
      Status__c = 'Failed',
      Current_Step__c = 'WorkflowConcurrencyTest.WaitStep',
      Correlation_Key__c = 'defer-skip-2'
    );
    insert inst;

    // 3. Insert a Failed step execution for WaitStep
    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowConcurrencyTest.WaitStep',
      Status__c = 'Failed',
      Retry_Count__c = 0
    );
    insert stepExec;

    // 4. Count scheduled cron/jobs before skip
    Integer jobsBefore = [SELECT Count() FROM AsyncApexJob WHERE JobType = 'ScheduledApex'];

    // 5. Execute skip/resume
    Test.startTest();
    WorkflowEngine.resumePastStep(inst.Id, 'WorkflowConcurrencyTest.WaitStep', '{}');

    // 6. Verify that Concurrency_Parked__c is set to true on the instance before admission runs
    Workflow_Instance__c instMid = [
      SELECT Status__c, Concurrency_Parked__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('Running', instMid.Status__c, 'Parent instance should be set to Running');
    System.assertEquals('WorkflowConcurrencyTest.TimeoutWaitStep', instMid.Current_Step__c, 'Should advance to next step');
    System.assertEquals(true, instMid.Concurrency_Parked__c, 'Concurrency_Parked__c should be set to true before admission');

    // Verify no timeout job was scheduled yet
    Integer jobsAfterMid = [SELECT Count() FROM AsyncApexJob WHERE JobType = 'ScheduledApex'];
    System.assertEquals(jobsBefore, jobsAfterMid, 'No timeout job should have been scheduled during the skip');

    // Verify the newly inserted step execution is Pending and has NULL Timeout_At__c
    Workflow_Step_Execution__c nextExecMid = [
      SELECT Status__c, Timeout_At__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :inst.Id AND Step_Name__c = 'WorkflowConcurrencyTest.TimeoutWaitStep'
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    System.assertEquals('Pending', nextExecMid.Status__c);
    System.assertEquals(null, nextExecMid.Timeout_At__c, 'Timeout_At__c should remain null while parked');

    Test.stopTest();

    // 7. Verify that once stopTest finishes (meaning the enqueued orchestrator has run), the instance gets admitted
    Workflow_Instance__c instFinal = [
      SELECT Status__c, Concurrency_Parked__c, Concurrency_Slot_Held__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('Running', instFinal.Status__c);
    System.assertEquals(false, instFinal.Concurrency_Parked__c, 'Concurrency_Parked__c should be cleared once admitted');
    System.assertEquals(true, instFinal.Concurrency_Slot_Held__c, 'Concurrency_Slot_Held__c should be set once admitted');
  }
}
