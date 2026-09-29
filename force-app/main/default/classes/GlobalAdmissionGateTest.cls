/**
 * @description Tests for the global slot counter (issue #136): the ceiling,
 * idempotent acquire and release, the Continue-As-New transfer, the heartbeat
 * reconcile, the emergency stop audit and the System Doctor read.
 */
@IsTest
public class GlobalAdmissionGateTest {
  private static final String WF = 'GlobalAdmissionGateTest.WaitWorkflow';
  private static final String CAN_WF = 'GlobalAdmissionGateTest.ContinueWorkflow';
  private static final String WAIT_STEP = 'GlobalAdmissionGateTest.WaitStep';
  private static final String CAN_STEP = 'GlobalAdmissionGateTest.ContinueStep';

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

  /** @description One step that continues as new. */
  public class ContinueWorkflow implements WorkflowDefinition {
    /**
     * @description The steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ CAN_STEP };
    }
    /**
     * @description The first step.
     * @return The step name.
     */
    public String getInitialStep() {
      return CAN_STEP;
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

  /** @description Continues as new. */
  public class ContinueStep implements WorkflowStep {
    /**
     * @description Continues as new.
     * @param ctx The step context.
     * @return A continue-as-new result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.continueAsNew(null);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  private static void configure(Boolean stop, Integer ceiling) {
    GlobalAdmissionBrake.configOverride = (Revenant_Config__mdt) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'DeveloperName' => 'Default',
          'Emergency_Stop__c' => stop,
          'Auto_Brake_On_Capacity__c' => false,
          'Global_Max_Active_Instances__c' => ceiling
        }
      ),
      Revenant_Config__mdt.class
    );
    GlobalAdmissionBrake.resetCache();
  }

  // Starts and admits one instance: it holds a global slot.
  private static Id admitted(String workflowName, String key) {
    Id id = WorkflowEngine.start(workflowName, key, null);
    WorkflowEngine.runStep(id, null);
    return id;
  }

  private static Workflow_Instance__c reload(Id id) {
    return [
      SELECT Status__c, Global_Admission__c, Concurrency_Parked__c
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

  private static void setGlobalCount(Integer value) {
    Concurrency_State__c row = [
      SELECT Id
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c = :GlobalAdmissionGate.COUNTER_KEY
    ];
    row.In_Flight_Count__c = value;
    update row;
  }

  private static Integer auditRows() {
    return [
      SELECT COUNT()
      FROM Workflow_Log__c
      WHERE
        Log_Type__c = 'OperatorIntervention'
        AND Workflow_Name__c = :GlobalAdmissionGate.AUDIT_NAME
    ];
  }

  // ── Ceiling (AC1, AC4) ─────────────────────────────────────────────────────

  @IsTest
  static void ceilingCapsAdmissionAcrossDefinitions() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 1);

      Id a = WorkflowEngine.start(WF, 'ceil-a', null);
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_AWAITING,
        reload(a).Global_Admission__c,
        'Open with a ceiling: slot at the first hop'
      );
      WorkflowEngine.runStep(a, null);
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_HELD,
        reload(a).Global_Admission__c,
        'a holds the slot'
      );
      Assert.areEqual(1, globalCount(), 'One slot in use');

      GlobalAdmissionBrake.resetCache();
      Id b = WorkflowEngine.start(CAN_WF, 'ceil-b', null);
      Workflow_Instance__c rb = reload(b);
      Assert.areEqual('Suspended', rb.Status__c, 'Another definition parks');
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_PARKED,
        rb.Global_Admission__c,
        'Parked by the ceiling'
      );

      update new Workflow_Instance__c(Id = a, Status__c = 'Completed');
      Assert.areEqual(0, globalCount(), 'Terminal releases the slot');
      Assert.isNull(reload(a).Global_Admission__c, 'Marker cleared');

      GlobalAdmissionBrake.resetCache();
      WorkflowEngine.runStep(b, null);
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_HELD,
        reload(b).Global_Admission__c,
        'b admits when a slot frees'
      );
      Assert.areEqual(1, globalCount(), 'One slot in use');
    }
  }

  @IsTest
  static void ceilingRaceParksAtTheLockedAcquire() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 1);
      Id a = WorkflowEngine.start(WF, 'race-a', null);
      Id b = WorkflowEngine.start(WF, 'race-b', null);
      WorkflowEngine.runStep(a, null);
      WorkflowEngine.runStep(b, null);
      Assert.areEqual(1, globalCount(), 'The lock keeps the ceiling');
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_PARKED,
        reload(b).Global_Admission__c,
        'The loser parks'
      );
    }
  }

  // ── Idempotent accounting (AC6) ────────────────────────────────────────────

  @IsTest
  static void duplicateDeliveryTakesOneSlot() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 5);
      Id a = WorkflowEngine.start(WF, 'dup-a', null);
      // Two deliveries read the row before either one takes the lock.
      Workflow_Instance__c first = staleRead(a);
      Workflow_Instance__c second = staleRead(a);
      WorkflowStepAdmission.admitOrParkForConcurrency(first);
      WorkflowStepAdmission.admitOrParkForConcurrency(second);
      Assert.areEqual(1, globalCount(), 'Redelivery does not double count');
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_HELD,
        reload(a).Global_Admission__c,
        'Held once'
      );
    }
  }

  // The fields that the step runner reads with no lock.
  private static Workflow_Instance__c staleRead(Id id) {
    return [
      SELECT
        Id,
        Workflow_Name__c,
        Status__c,
        Current_Step__c,
        Concurrency_Slot_Held__c,
        Concurrency_Parked__c,
        Global_Admission__c
      FROM Workflow_Instance__c
      WHERE Id = :id
    ];
  }

  @IsTest
  static void terminalResaveReleasesOnce() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 5);
      Id a = admitted(WF, 'rel-a');
      admitted(WF, 'rel-b');
      Assert.areEqual(2, globalCount(), 'Two slots');
      update new Workflow_Instance__c(Id = a, Status__c = 'Completed');
      update new Workflow_Instance__c(Id = a, Status__c = 'Failed');
      Assert.areEqual(1, globalCount(), 'One release only');
    }
  }

  @IsTest
  static void compensationFailedKeepsTheSlot() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 5);
      Id a = admitted(WF, 'cf-a');
      update new Workflow_Instance__c(Id = a, Status__c = 'CompensationFailed');
      Assert.areEqual(1, globalCount(), 'Not terminal: keeps the slot');
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_HELD,
        reload(a).Global_Admission__c,
        'Still held'
      );
    }
  }

  @IsTest
  static void cancelledParkedStartReleasesNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 1);
      admitted(WF, 'cx-a');
      GlobalAdmissionBrake.resetCache();
      Id b = WorkflowEngine.start(WF, 'cx-b', null);
      update new Workflow_Instance__c(Id = b, Status__c = 'Cancelled');
      Assert.areEqual(1, globalCount(), 'A parked start held no slot');
      Assert.isNull(reload(b).Global_Admission__c, 'Marker cleared');
    }
  }

  @IsTest
  static void continueAsNewTransfersTheSlot() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 5);
      Id a = admitted(CAN_WF, 'can-a');
      Assert.areEqual(1, globalCount(), 'One slot');

      WorkflowEngine.runStep(a, null);

      Assert.areEqual('ContinuedAsNew', reload(a).Status__c, 'Continued');
      Assert.isNull(reload(a).Global_Admission__c, 'Predecessor gave it up');
      Workflow_Instance__c successor = [
        SELECT Global_Admission__c, Status__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :a
      ];
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_HELD,
        successor.Global_Admission__c,
        'The successor holds the slot'
      );
      Assert.areEqual(1, globalCount(), 'The chain holds one slot');
    }
  }

  @IsTest
  static void continueAsNewSuccessorIsNotBraked() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 5);
      Id a = admitted(CAN_WF, 'can-b');
      configure(true, 5);
      WorkflowEngine.runStep(a, null);
      Workflow_Instance__c successor = [
        SELECT Status__c, Concurrency_Parked__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :a
      ];
      Assert.areNotEqual(
        'Suspended',
        successor.Status__c,
        'A running chain is not parked'
      );
    }
  }

  @IsTest
  static void fullGlobalCeilingGivesBackTheDefinitionSlot() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      ConcurrencyGate.mockConfigs.put(
        'GlobalAdmissionGateTest_WaitWorkflow',
        (Concurrency_Config__mdt) JSON.deserialize(
          '{"DeveloperName":"GlobalAdmissionGateTest_WaitWorkflow","Max_Concurrent_Instances__c":5}',
          Concurrency_Config__mdt.class
        )
      );
      configure(false, 1);
      Id a = WorkflowEngine.start(WF, 'def-full-a', null);
      Id b = WorkflowEngine.start(WF, 'def-full-b', null);
      WorkflowEngine.runStep(a, null);
      WorkflowEngine.runStep(b, null);
      Assert.areEqual(1, globalCount(), 'One global slot');
      Assert.areEqual(
        1,
        [
          SELECT In_Flight_Count__c
          FROM Concurrency_State__c
          WHERE Workflow_Definition__c = :WF
        ]
        .In_Flight_Count__c,
        'b gave back its definition slot'
      );
      Workflow_Instance__c rb = [
        SELECT Global_Admission__c, Concurrency_Slot_Held__c
        FROM Workflow_Instance__c
        WHERE Id = :b
      ];
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_PARKED,
        rb.Global_Admission__c,
        'b parks'
      );
      Assert.isFalse(rb.Concurrency_Slot_Held__c, 'b holds no slot');
    }
  }

  @IsTest
  static void rollbackOfAWaitingStartClearsTheMarker() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 5);
      Id a = WorkflowEngine.start(WF, 'rb-a', null);
      update new Workflow_Instance__c(Id = a, Status__c = 'Cancelling');
      Assert.isNull(reload(a).Global_Admission__c, 'A rollback never waits');
      Assert.isNull(globalCount(), 'No slot taken or given back');
    }
  }

  @IsTest
  static void heldRollbackReleasesOnceAtTheEnd() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 5);
      Id a = admitted(WF, 'rb-held');
      update new Workflow_Instance__c(Id = a, Status__c = 'Cancelling');
      Assert.areEqual(1, globalCount(), 'A rollback keeps the slot');
      update new Workflow_Instance__c(Id = a, Status__c = 'Cancelled');
      Assert.areEqual(0, globalCount(), 'Released at the terminal status');
    }
  }

  @IsTest
  static void operatorRetryTakesASlot() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 5);
      Id a = admitted(WF, 'retry-a');
      update new Workflow_Instance__c(Id = a, Status__c = 'Failed');
      Assert.areEqual(0, globalCount(), 'Released on Failed');
      WorkflowRetryService.retryWorkflow(a);
      Assert.areEqual(
        GlobalAdmissionPolicy.STATE_HELD,
        reload(a).Global_Admission__c,
        'The retry holds a slot'
      );
      Assert.areEqual(0, globalCount(), 'The retry takes no counter lock');
      GlobalAdmissionGate.reconcile();
      Assert.areEqual(1, globalCount(), 'The reconcile counts the retry');
    }
  }

  @IsTest
  static void heartbeatAppliesReleasesAtTheEnd() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 5);
      Id a = admitted(WF, 'hb-a');
      GlobalAdmissionGate.deferReleasesToReconcile();
      update new Workflow_Instance__c(Id = a, Status__c = 'Completed');
      Assert.areEqual(1, globalCount(), 'No $global lock yet');
      GlobalAdmissionGate.reconcile();
      GlobalAdmissionGate.endDeferral();
      Assert.areEqual(0, globalCount(), 'The reconcile applies it');
    }
  }

  @IsTest
  static void endDeferralAppliesReleasesWithNoReconcile() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 5);
      Id a = admitted(WF, 'hb-b');
      admitted(WF, 'hb-c');
      GlobalAdmissionGate.deferReleasesToReconcile();
      update new Workflow_Instance__c(Id = a, Status__c = 'Completed');
      Assert.areEqual(2, globalCount(), 'Deferred');
      GlobalAdmissionGate.endDeferral();
      Assert.areEqual(
        1,
        globalCount(),
        'Applied when the reconcile did not run'
      );
      update new Workflow_Instance__c(Id = a, Status__c = 'Failed');
      Assert.areEqual(1, globalCount(), 'Normal mode again, no double release');
    }
  }

  // ── Reconcile and audit (AC5, AC6) ─────────────────────────────────────────

  @IsTest
  static void reconcileReclaimsLeakedSlots() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 5);
      admitted(WF, 'leak-a');
      setGlobalCount(7);
      GlobalAdmissionGate.reconcile();
      Assert.areEqual(1, globalCount(), 'Reset to the true count');
    }
  }

  @IsTest
  static void definitionReconcileLeavesTheGlobalRow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 5);
      admitted(WF, 'def-a');
      setGlobalCount(4);
      ConcurrencyGate.reconcileAll();
      Assert.areEqual(4, globalCount(), 'Not a definition counter');
    }
  }

  @IsTest
  static void concurrencyPanelHidesTheGlobalRow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(false, 5);
      admitted(WF, 'panel-a');
      for (
        Map<String, Object> row : WorkflowDashboardStatusService.concurrencyStatus()
      ) {
        Assert.areNotEqual(
          GlobalAdmissionGate.COUNTER_KEY,
          row.get('workflowName'),
          'The global row is not a definition'
        );
      }
    }
  }

  @IsTest
  static void emergencyStopChangesAreAudited() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      configure(true, null);
      GlobalAdmissionGate.reconcile();
      Assert.areEqual(1, auditRows(), 'Engage is recorded');
      GlobalAdmissionGate.reconcile();
      Assert.areEqual(1, auditRows(), 'No change, no new row');
      configure(false, null);
      GlobalAdmissionGate.reconcile();
      Assert.areEqual(2, auditRows(), 'Release is recorded');
      Workflow_Log__c last = [
        SELECT Outcome__c, Message__c
        FROM Workflow_Log__c
        WHERE Workflow_Name__c = :GlobalAdmissionGate.AUDIT_NAME
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      Assert.areEqual('Released', last.Outcome__c, 'Outcome names the change');
    }
  }

  @IsTest
  static void noControlNoCounterRow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      configure(false, null);
      GlobalAdmissionGate.reconcile();
      Assert.isNull(globalCount(), 'The heartbeat writes no row when off');
      Assert.areEqual(0, auditRows(), 'No audit row');
    }
  }

  // ── System Doctor (AC8) ────────────────────────────────────────────────────

  @IsTest
  static void doctorShowsBrakedStateAndParkedCount() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      configure(true, null);
      WorkflowEngine.start(WF, 'doc-a', null);
      WorkflowEngine.start(WF, 'doc-b', null);
      Map<String, Object> s = WorkflowGlobalAdmissionController.getGlobalAdmission();
      Assert.areEqual('BRAKED', s.get('state'), 'Braked');
      Assert.areEqual(
        GlobalAdmissionPolicy.REASON_EMERGENCY_STOP,
        s.get('reason'),
        'Reason'
      );
      Assert.areEqual(2, s.get('parkedCount'), 'Two parked starts');
    }
  }

  @IsTest
  static void doctorShowsOpenState() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      configure(false, 10);
      Map<String, Object> s = WorkflowGlobalAdmissionController.getGlobalAdmission();
      Assert.areEqual('OPEN', s.get('state'), 'Open');
      Assert.areEqual(10, s.get('ceiling'), 'Ceiling shown');
      Assert.areEqual(0, s.get('inFlight'), 'No slot in use');
      Assert.areEqual(0, s.get('parkedCount'), 'Nothing parked');
    }
  }
}
