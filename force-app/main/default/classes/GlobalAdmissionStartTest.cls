/**
 * @description Tests for the global admission brake (issue #136) on the start
 * path, at the first-hop gate and in the watchdog sleep sweep.
 */
@IsTest
public class GlobalAdmissionStartTest {
  private static final String WF = 'GlobalAdmissionStartTest.WaitWorkflow';
  private static final String TWO_STEP_WF = 'GlobalAdmissionStartTest.TwoStepWorkflow';
  private static final String FIRST_STEP = 'GlobalAdmissionStartTest.FirstStep';
  private static final String WAIT_STEP = 'GlobalAdmissionStartTest.WaitStep';

  /** @description One step that suspends. */
  public class WaitWorkflow implements WorkflowDefinition {
    /**
     * @description The steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ WAIT_STEP };
    }
    /**
     * @description The first step.
     * @return The step name.
     */
    public String getInitialStep() {
      return WAIT_STEP;
    }
    /**
     * @description No next step.
     * @param current The step that completed.
     * @param result Its result.
     * @return Null.
     */
    public String getNextStep(String current, StepResult result) {
      return null;
    }
  }

  /** @description FirstStep, then WaitStep. */
  public class TwoStepWorkflow implements WorkflowDefinition {
    /**
     * @description The steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ FIRST_STEP, WAIT_STEP };
    }
    /**
     * @description The first step.
     * @return The step name.
     */
    public String getInitialStep() {
      return FIRST_STEP;
    }
    /**
     * @description WaitStep after FirstStep.
     * @param current The step that completed.
     * @param result Its result.
     * @return The next step name, or null.
     */
    public String getNextStep(String current, StepResult result) {
      return current == FIRST_STEP ? WAIT_STEP : null;
    }
  }

  /** @description Completes at once. */
  public class FirstStep implements WorkflowStep {
    /**
     * @description Completes.
     * @param ctx The step context.
     * @return A complete result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(WAIT_STEP, null);
    }
  }

  /** @description Suspends. */
  public class WaitStep implements WorkflowStep {
    /**
     * @description Suspends.
     * @param ctx The step context.
     * @return A suspend result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.suspend();
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  private static void configure(
    Boolean stop,
    Boolean autoBrake,
    Integer ceiling
  ) {
    GlobalAdmissionBrake.configOverride = (Revenant_Config__mdt) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'DeveloperName' => 'Default',
          'Emergency_Stop__c' => stop,
          'Auto_Brake_On_Capacity__c' => autoBrake,
          'Global_Max_Active_Instances__c' => ceiling
        }
      ),
      Revenant_Config__mdt.class
    );
    GlobalAdmissionBrake.resetCache();
  }

  private static Id startOne(String key) {
    return WorkflowEngine.start(WF, key, null);
  }

  private static Workflow_Instance__c reload(Id id) {
    return [
      SELECT
        Status__c,
        Global_Admission__c,
        Concurrency_Parked__c,
        Concurrency_Slot_Held__c,
        Sleep_Until__c,
        Async_Job_Id__c,
        Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Id = :id
    ];
  }

  private static Decimal globalCount() {
    List<Concurrency_State__c> rows = [
      SELECT In_Flight_Count__c
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c = :GlobalAdmissionGate.COUNTER_KEY
    ];
    return rows.isEmpty() ? null : rows[0].In_Flight_Count__c;
  }

  private static Integer executedSteps(Id id) {
    return [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :id
        AND Status__c IN ('Running', 'Completed', 'Suspended')
    ];
  }

  // ── Zero change (AC9) and cost (AC7) ───────────────────────────────────────

  @IsTest
  static void notGovernedStartIsUnchanged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, false, null);
      Integer queries = Limits.getQueries();
      GlobalAdmissionPolicy.Decision d = GlobalAdmissionBrake.evaluate();
      Assert.areEqual(queries, Limits.getQueries(), 'No SOQL when off');
      Assert.isFalse(d.governed, 'Not governed');

      Id id = startOne('zero-1');
      Workflow_Instance__c r = reload(id);
      Assert.isNull(r.Global_Admission__c, 'No marker');
      Assert.isFalse(r.Concurrency_Parked__c, 'No park flag');
      Assert.areEqual('Pending', r.Status__c, 'Normal start');
    }
  }

  @IsTest
  static void notGovernedStartEnqueuesTheFirstHop() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      configure(false, false, null);
      Test.startTest();
      Integer before = Limits.getQueueableJobs();
      startOne('zero-2');
      Assert.areEqual(
        before + 1,
        Limits.getQueueableJobs(),
        'The first hop is enqueued as today'
      );
      Test.stopTest();
    }
  }

  @IsTest
  static void checkCostIsBoundedAndCached() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      configure(true, true, 10);
      Integer queries = Limits.getQueries();
      GlobalAdmissionBrake.evaluate();
      Assert.areEqual(
        queries,
        Limits.getQueries(),
        'Emergency stop brakes with no read'
      );

      configure(false, false, 10);
      queries = Limits.getQueries();
      GlobalAdmissionBrake.evaluate();
      Assert.areEqual(
        queries + 1,
        Limits.getQueries(),
        'Ceiling: one counter read'
      );
      GlobalAdmissionBrake.evaluate();
      Assert.areEqual(
        queries + 1,
        Limits.getQueries(),
        'The decision is cached for the transaction'
      );
    }
  }

  // ── Emergency stop (AC2, AC5) ──────────────────────────────────────────────

  @IsTest
  static void emergencyStopParksNewStartWithNoEnqueue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      configure(true, false, null);
      Test.startTest();
      Integer before = Limits.getQueueableJobs();
      Id id = startOne('stop-1');
      Assert.areEqual(
        before,
        Limits.getQueueableJobs(),
        'A braked start does not enqueue the first hop'
      );
      Test.stopTest();

      Workflow_Instance__c r = reload(id);
      Assert.areEqual('Suspended', r.Status__c, 'Parked, not dropped');
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_PARKED,
        r.Global_Admission__c,
        'Parked by the brake'
      );
      Assert.isTrue(r.Concurrency_Parked__c, 'Uses the park plumbing');
      Assert.isNotNull(r.Sleep_Until__c, 'Due for the watchdog sweep');
      Assert.isNull(r.Async_Job_Id__c, 'No scheduled job');
      Assert.areEqual(0, executedSteps(id), 'No step ran');
    }
  }

  @IsTest
  static void bulkStartParksEveryNewStart() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      configure(true, false, null);
      List<WorkflowEngine.StartRequest> reqs = new List<WorkflowEngine.StartRequest>();
      for (Integer i = 0; i < 3; i++) {
        reqs.add(new WorkflowEngine.StartRequest(WF, 'bulk-' + i, null));
      }
      Test.startTest();
      Integer before = Limits.getQueueableJobs();
      List<Id> ids = WorkflowEngine.start(reqs);
      Assert.areEqual(before, Limits.getQueueableJobs(), 'No first hop');
      Test.stopTest();
      for (Workflow_Instance__c r : [
        SELECT Status__c, Global_Admission__c, Concurrency_Parked__c
        FROM Workflow_Instance__c
        WHERE Id IN :ids
      ]) {
        Assert.areEqual('Suspended', r.Status__c, 'Parked');
        Assert.areEqual(
          GlobalAdmissionPolicy.STATE_PARKED,
          r.Global_Admission__c,
          'Parked by the brake'
        );
      }
    }
  }

  @IsTest
  static void emergencyStopDoesNotTouchInFlight() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, false, null);
      Id id = WorkflowEngine.start(TWO_STEP_WF, 'inflight-1', null);

      configure(true, false, null);
      WorkflowEngine.runStep(id, null);

      Workflow_Instance__c r = reload(id);
      Assert.isNull(r.Global_Admission__c, 'Never gated');
      Assert.isFalse(r.Concurrency_Parked__c, 'Not parked');
      Assert.areEqual(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Step_Execution__c
          WHERE
            Workflow_Instance__c = :id
            AND Step_Name__c = :FIRST_STEP
            AND Status__c = 'Completed'
        ],
        'The in-flight step ran'
      );
    }
  }

  @IsTest
  static void gateKeepsStartParkedWhileBraked() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(true, false, null);
      Id id = startOne('gate-1');
      WorkflowEngine.runStep(id, null);
      Workflow_Instance__c r = reload(id);
      Assert.areEqual('Suspended', r.Status__c, 'Still parked');
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_PARKED,
        r.Global_Admission__c,
        'Still parked by the brake'
      );
      Assert.isNull(r.Async_Job_Id__c, 'No timer job');
      Assert.areEqual(0, executedSteps(id), 'No step ran');
    }
  }

  @IsTest
  static void releasedStopAdmitsParkedStart() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(true, false, null);
      Id id = startOne('release-1');

      configure(false, false, null);
      WorkflowEngine.runStep(id, null);

      Workflow_Instance__c r = reload(id);
      Assert.isNull(r.Global_Admission__c, 'Admitted, no slot to hold');
      Assert.isFalse(r.Concurrency_Parked__c, 'No longer parked');
      Assert.areEqual('Running', r.Status__c, 'Admitted');
    }
  }

  @IsTest
  static void brakeWritesNoStepOrStackMutation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(true, false, null);
      Id id = startOne('append-1');
      Workflow_Step_Execution__c before = [
        SELECT Id, Status__c, Timeout_At__c, SystemModstamp
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :id
      ];
      WorkflowEngine.runStep(id, null);
      List<Workflow_Step_Execution__c> after = [
        SELECT Id, Status__c, Timeout_At__c, SystemModstamp
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :id
      ];
      Assert.areEqual(1, after.size(), 'No step row added');
      Assert.areEqual(before.Status__c, after[0].Status__c, 'Same status');
      Assert.isNull(after[0].Timeout_At__c, 'No deadline while parked');
      Assert.isNull(reload(id).Compensation_Stack__c, 'Stack not touched');
    }
  }

  @IsTest
  static void parkedStartStaysOutOfTheDefinitionQueue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(true, false, null);
      Id id = startOne('queue-1');
      Workflow_Instance__c r = [
        SELECT Admission_Queue__c, Concurrency_Parked__c
        FROM Workflow_Instance__c
        WHERE Id = :id
      ];
      Assert.isTrue(r.Concurrency_Parked__c, 'Parked');
      Assert.isNull(
        r.Admission_Queue__c,
        'A braked start cannot make a definition candidate yield'
      );
    }
  }

  // ── Sweep (AC4) ────────────────────────────────────────────────────────────

  @IsTest
  static void sweepSkipsParkedStartsWhileBraked() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      configure(true, false, null);
      Id id = startOne('sweep-1');
      Assert.areEqual(
        new Set<String>{ GlobalAdmissionPolicy.STATE_PARKED },
        GlobalAdmissionBrake.sweepExclusions(),
        'Braked: exclude parked starts'
      );
      Test.startTest();
      Integer before = Limits.getQueueableJobs();
      WorkflowSleepResumeSweep.processSleepResumptions(
        DateTime.now().addMinutes(1)
      );
      Assert.areEqual(
        before,
        Limits.getQueueableJobs(),
        'A braked backlog costs no async job'
      );
      Test.stopTest();
      Assert.areEqual('Suspended', reload(id).Status__c, 'Still parked');
    }
  }

  @IsTest
  static void sweepRedrivesParkedStartsWhenOpen() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      configure(true, false, null);
      startOne('sweep-2');
      configure(false, false, null);
      Assert.isTrue(
        GlobalAdmissionBrake.sweepExclusions().isEmpty(),
        'Open: exclude nothing'
      );
      Test.startTest();
      Integer before = Limits.getQueueableJobs();
      WorkflowSleepResumeSweep.processSleepResumptions(
        DateTime.now().addMinutes(1)
      );
      Assert.areEqual(
        before + 1,
        Limits.getQueueableJobs(),
        'The sweep re-drives the parked start to the gate'
      );
      Test.stopTest();
    }
  }

  // ── Auto-brake (AC1) and fail open (AC7) ───────────────────────────────────

  @IsTest
  static void criticalCapacityParksWhenAutoBrakeIsOn() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, true, null);
      GlobalAdmissionBrake.capacityStatusOverride = 'CRITICAL';
      Id id = startOne('cap-1');
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_PARKED,
        reload(id).Global_Admission__c,
        'Critical capacity parks the start'
      );
      Assert.areEqual(
        GlobalAdmissionPolicy.REASON_CAPACITY_CRITICAL,
        GlobalAdmissionBrake.evaluate().reason,
        'Reason is capacity'
      );
    }
  }

  @IsTest
  static void criticalCapacityIsIgnoredWhenAutoBrakeIsOff() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, false, null);
      GlobalAdmissionBrake.capacityStatusOverride = 'CRITICAL';
      Id id = startOne('cap-2');
      Assert.isNull(reload(id).Global_Admission__c, 'Not governed');
    }
  }

  @IsTest
  static void failedCapacityReadFailsOpen() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, true, null);
      GlobalAdmissionBrake.failCapacityRead = true;
      Id id = startOne('open-1');
      Workflow_Instance__c r = reload(id);
      Assert.areEqual('Pending', r.Status__c, 'Admitted');
      Assert.isNull(r.Global_Admission__c, 'No marker');
    }
  }

  @IsTest
  static void failedCounterReadFailsOpenAtStart() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      insert new Concurrency_State__c(
        Workflow_Definition__c = GlobalAdmissionGate.COUNTER_KEY,
        In_Flight_Count__c = 1
      );
      configure(false, false, 1);
      GlobalAdmissionBrake.failCounterRead = true;
      Id id = startOne('open-2');
      Workflow_Instance__c r = reload(id);
      Assert.areEqual('Pending', r.Status__c, 'Not parked');
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_AWAITING,
        r.Global_Admission__c,
        'The gate takes the slot at the first hop'
      );
    }
  }

  @IsTest
  static void failedCounterLockFailsOpenAtGate() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, false, 1);
      Id id = startOne('open-3');
      GlobalAdmissionGate.failLock = true;
      WorkflowEngine.runStep(id, null);
      Workflow_Instance__c r = reload(id);
      Assert.areEqual('Running', r.Status__c, 'Admitted');
      Assert.isNull(r.Global_Admission__c, 'Admitted with no slot');
      Assert.isNull(globalCount(), 'No counter written');
    }
  }

  // ── Exemptions ─────────────────────────────────────────────────────────────

  @IsTest
  static void engineWorkflowsAreExempt() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      configure(true, false, null);
      Assert.isNull(
        GlobalAdmissionBrake.stateForStart('WatchdogWorkflow', false),
        'The watchdog is never parked'
      );
      Assert.isNull(
        GlobalAdmissionBrake.stateForStart('ns.ArchiveWorkflow', false),
        'Engine workflows are never parked'
      );
    }
  }

  @IsTest
  static void startWithParentIsExempt() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, false, null);
      Id parentId = startOne('parent-2');
      configure(true, false, null);
      Id childId = WorkflowEngine.start(
        new WorkflowEngine.StartRequest(WF, 'child-2', null)
          .withParent(parentId)
      );
      Assert.isNull(
        reload(childId).Global_Admission__c,
        'A start under a parent is part of a running root'
      );
    }
  }

  @IsTest
  static void childStartIsExempt() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, false, null);
      Id parentId = startOne('parent-1');
      configure(true, false, null);
      WorkflowChildService.ChildWorkflowStartRequest req = new WorkflowChildService.ChildWorkflowStartRequest();
      req.parentId = parentId;
      req.workflowName = WF;
      req.correlationKey = 'child-1';
      WorkflowChildService.startChildWorkflow(req);
      Workflow_Instance__c child = [
        SELECT Status__c, Global_Admission__c
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :parentId
      ];
      Assert.isNull(child.Global_Admission__c, 'A child is never parked');
      Assert.areNotEqual('Suspended', child.Status__c, 'The child runs');
    }
  }
}
