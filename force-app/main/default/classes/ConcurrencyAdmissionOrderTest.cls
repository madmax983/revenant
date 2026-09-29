/**
 * Unit tests for admission priority (issue #132): priority resolution, the
 * clamp, the rank key, the insert stamp and the start-API override.
 */
@IsTest
public class ConcurrencyAdmissionOrderTest {
  private static final String WF = 'WorkflowConcurrencyTest.WaitWorkflow';
  private static final String DEV_NAME = 'WorkflowConcurrencyTest_WaitWorkflow';
  private static final Long MINUTE_MS = 60000L;

  private static Concurrency_Config__mdt cfg(
    String developerName,
    Integer priority,
    Integer agingMinutes
  ) {
    Map<String, Object> fields = new Map<String, Object>{
      'DeveloperName' => developerName,
      'Max_Concurrent_Instances__c' => 1,
      'Admission_Priority__c' => priority,
      'Priority_Aging_Minutes__c' => agingMinutes
    };
    return (Concurrency_Config__mdt) JSON.deserialize(
      JSON.serialize(fields),
      Concurrency_Config__mdt.class
    );
  }

  private static Workflow_Instance__c reload(Id id) {
    return [
      SELECT Admission_Priority__c, Admission_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :id
    ];
  }

  @IsTest
  static void testKeyIsStartTimeMinusPriorityCredit() {
    Datetime t0 = Datetime.newInstanceGmt(2026, 1, 1, 12, 0, 0);
    Test.startTest();
    Long base = ConcurrencyAdmissionOrder.admissionKey(t0, 0, 60);
    Long high = ConcurrencyAdmissionOrder.admissionKey(t0, 2, 60);
    Test.stopTest();
    System.assertEquals(t0.getTime(), base, 'Priority 0 key is start ms');
    System.assertEquals(
      t0.getTime() - 2 * 60 * MINUTE_MS,
      high,
      'Each level subtracts one aging window'
    );
  }

  @IsTest
  static void testOverrideIsClampedToRange() {
    Test.startTest();
    Integer tooHigh = ConcurrencyAdmissionOrder.resolvePriority(WF, 42);
    Integer tooLow = ConcurrencyAdmissionOrder.resolvePriority(WF, -3);
    Integer inRange = ConcurrencyAdmissionOrder.resolvePriority(WF, 7);
    Test.stopTest();
    System.assertEquals(9, tooHigh, 'Clamp to MAX_PRIORITY');
    System.assertEquals(0, tooLow, 'Clamp to MIN_PRIORITY');
    System.assertEquals(7, inRange, 'In-range override is kept');
  }

  @IsTest
  static void testNoConfigGivesDefaultPriorityAndAging() {
    Test.startTest();
    Integer priority = ConcurrencyAdmissionOrder.resolvePriority(WF, null);
    Integer aging = ConcurrencyAdmissionOrder.resolveAgingMinutes(WF);
    Test.stopTest();
    System.assertEquals(0, priority, 'No config: priority 0');
    System.assertEquals(
      ConcurrencyAdmissionOrder.DEFAULT_AGING_MINUTES,
      aging,
      'No config: default aging'
    );
  }

  @IsTest
  static void testConfigPriorityUsesNameThenDefault() {
    ConcurrencyGate.mockConfigs.put('Default', cfg('Default', 3, 30));
    Test.startTest();
    Integer fromDefault = ConcurrencyAdmissionOrder.resolvePriority(WF, null);
    ConcurrencyGate.mockConfigs.put(DEV_NAME, cfg(DEV_NAME, 6, 15));
    Integer fromName = ConcurrencyAdmissionOrder.resolvePriority(WF, null);
    Integer aging = ConcurrencyAdmissionOrder.resolveAgingMinutes(WF);
    Integer overridden = ConcurrencyAdmissionOrder.resolvePriority(WF, 1);
    Test.stopTest();
    System.assertEquals(3, fromDefault, 'Default record applies');
    System.assertEquals(6, fromName, 'Named record wins over Default');
    System.assertEquals(15, aging, 'Named record aging applies');
    System.assertEquals(1, overridden, 'Per-start override wins');
  }

  @IsTest
  static void testBadConfigFallsBackToSafeValues() {
    ConcurrencyGate.mockConfigs.put(DEV_NAME, cfg(DEV_NAME, 99, 0));
    Test.startTest();
    Integer priority = ConcurrencyAdmissionOrder.resolvePriority(WF, null);
    Integer aging = ConcurrencyAdmissionOrder.resolveAgingMinutes(WF);
    Test.stopTest();
    System.assertEquals(9, priority, 'Config priority is clamped');
    System.assertEquals(
      ConcurrencyAdmissionOrder.DEFAULT_AGING_MINUTES,
      aging,
      'Non-positive aging uses the default'
    );
  }

  @IsTest
  static void testInsertStampsPriorityAndKey() {
    ConcurrencyGate.mockConfigs.put(DEV_NAME, cfg(DEV_NAME, 4, 10));
    Datetime t0 = Datetime.newInstanceGmt(2026, 3, 1, 8, 0, 0);
    WorkflowEngine.mockNow = t0;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Pending',
      Correlation_Key__c = 'stamp-1'
    );
    Test.startTest();
    insert inst;
    Test.stopTest();
    Workflow_Instance__c r = reload(inst.Id);
    System.assertEquals(4, r.Admission_Priority__c, 'Config priority stamped');
    System.assertEquals(
      t0.getTime() - 4 * 10 * MINUTE_MS,
      r.Admission_Key__c.longValue(),
      'Key stamped from start time, priority and aging'
    );
  }

  @IsTest
  static void testInsertKeepsPresetKeyAndClampsPriority() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Pending',
      Correlation_Key__c = 'stamp-2',
      Admission_Priority__c = 42,
      Admission_Key__c = 12345
    );
    Test.startTest();
    insert inst;
    Test.stopTest();
    Workflow_Instance__c r = reload(inst.Id);
    System.assertEquals(9, r.Admission_Priority__c, 'Preset priority clamped');
    System.assertEquals(12345, r.Admission_Key__c, 'Preset key is kept');
  }

  @IsTest
  static void testUpdateDoesNotRestamp() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Pending',
      Correlation_Key__c = 'stamp-3'
    );
    insert inst;
    Test.startTest();
    update new Workflow_Instance__c(
      Id = inst.Id,
      Admission_Priority__c = null,
      Admission_Key__c = null
    );
    Test.stopTest();
    Workflow_Instance__c r = reload(inst.Id);
    System.assertEquals(null, r.Admission_Key__c, 'Only insert stamps');
  }

  @IsTest
  static void testHugeAgingIsClamped() {
    ConcurrencyGate.mockConfigs.put(DEV_NAME, cfg(DEV_NAME, 1, 2147483647));
    Test.startTest();
    Integer aging = ConcurrencyAdmissionOrder.resolveAgingMinutes(WF);
    Test.stopTest();
    System.assertEquals(
      ConcurrencyAdmissionOrder.MAX_AGING_MINUTES,
      aging,
      'Aging above the maximum uses the maximum'
    );
  }

  @IsTest
  static void testQueueFieldIsSetOnlyWhileWaiting() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Pending',
      Correlation_Key__c = 'queue-1',
      Concurrency_Parked__c = true
    );
    insert inst;
    String waiting = [
      SELECT Admission_Queue__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ]
    .Admission_Queue__c;
    Test.startTest();
    update new Workflow_Instance__c(
      Id = inst.Id,
      Status__c = 'Running',
      Concurrency_Parked__c = false,
      Concurrency_Slot_Held__c = true
    );
    Test.stopTest();
    String admitted = [
      SELECT Admission_Queue__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ]
    .Admission_Queue__c;
    System.assertEquals(WF, waiting, 'A waiting row is in the queue');
    System.assertEquals(null, admitted, 'An admitted row leaves the queue');
  }

  @IsTest
  static void testBackfillQueueFindsRowsFromBeforeFeature() {
    ConcurrencyAdmissionOrder.skipQueueSync = true;
    Workflow_Instance__c legacy = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Suspended',
      Correlation_Key__c = 'queue-legacy-1',
      Concurrency_Parked__c = true
    );
    Workflow_Instance__c running = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Running',
      Correlation_Key__c = 'queue-legacy-2',
      Concurrency_Slot_Held__c = true
    );
    insert new List<Workflow_Instance__c>{ legacy, running };
    ConcurrencyAdmissionOrder.skipQueueSync = false;

    Test.startTest();
    Integer fixed = ConcurrencyAdmissionOrder.backfillQueue(200);
    Integer again = ConcurrencyAdmissionOrder.backfillQueue(200);
    Test.stopTest();

    System.assertEquals(1, fixed, 'Only the waiting row is fixed');
    System.assertEquals(0, again, 'A second call has nothing to fix');
    System.assertEquals(
      WF,
      [
        SELECT Admission_Queue__c
        FROM Workflow_Instance__c
        WHERE Id = :legacy.Id
      ]
      .Admission_Queue__c,
      'The waiting row is in the queue'
    );
  }

  // Rows that always fail the backfill must not block the rows after them.
  @IsTest
  static void testBackfillSkipsPastFailingPage() {
    ConcurrencyAdmissionOrder.skipQueueSync = true;
    List<Workflow_Instance__c> rows = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < 3; i++) {
      rows.add(
        new Workflow_Instance__c(
          Workflow_Name__c = WF,
          Status__c = 'Suspended',
          Correlation_Key__c = 'queue-fail-' + i,
          Concurrency_Parked__c = true
        )
      );
    }
    insert rows;
    ConcurrencyAdmissionOrder.skipQueueSync = false;
    List<Workflow_Instance__c> ordered = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Id IN :rows
      ORDER BY Id ASC
    ];
    ConcurrencyAdmissionOrder.backfillFailIds = new Set<Id>{
      ordered[0].Id,
      ordered[1].Id
    };

    Test.startTest();
    Integer fixed = ConcurrencyAdmissionOrder.backfillQueue(2);
    Test.stopTest();

    System.assertEquals(1, fixed, 'The row after the failing page is fixed');
    System.assertEquals(
      WF,
      [
        SELECT Admission_Queue__c
        FROM Workflow_Instance__c
        WHERE Id = :ordered[2].Id
      ]
      .Admission_Queue__c,
      'The third row is in the queue'
    );
  }

  // A rollback does not use admission. A compensation step that suspends
  // later must not join the queue.
  @IsTest
  static void testRollbackClearsMarkerAndLeavesQueue() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Pending',
      Correlation_Key__c = 'queue-rollback-1',
      Concurrency_Parked__c = true
    );
    insert inst;
    Test.startTest();
    update new Workflow_Instance__c(Id = inst.Id, Status__c = 'Cancelling');
    update new Workflow_Instance__c(Id = inst.Id, Status__c = 'Suspended');
    Test.stopTest();
    Workflow_Instance__c r = [
      SELECT Concurrency_Parked__c, Admission_Queue__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assert(!r.Concurrency_Parked__c, 'Rollback clears the marker');
    System.assertEquals(null, r.Admission_Queue__c, 'Not in the queue');
  }

  @IsTest
  static void testTerminalRowLeavesQueue() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Suspended',
      Correlation_Key__c = 'queue-2',
      Concurrency_Parked__c = true
    );
    insert inst;
    Test.startTest();
    update new Workflow_Instance__c(Id = inst.Id, Status__c = 'Cancelled');
    Test.stopTest();
    System.assertEquals(
      null,
      [SELECT Admission_Queue__c FROM Workflow_Instance__c WHERE Id = :inst.Id]
      .Admission_Queue__c,
      'A terminal row leaves the queue'
    );
  }

  @IsTest
  static void testStartRequestOverrideIsAdditive() {
    WorkflowEngine.StartRequest plain = new WorkflowEngine.StartRequest(
      WF,
      'api-1',
      null
    );
    WorkflowEngine.StartRequest prioritized = new WorkflowEngine.StartRequest(
        WF,
        'api-2',
        null
      )
      .withPriority(8);
    Test.startTest();
    System.assertEquals(null, plain.priority, 'Priority is optional');
    System.assertEquals(8, prioritized.priority, 'withPriority sets it');
    Test.stopTest();
  }

  @IsTest
  static void testStartAppliesOverrideOrConfig() {
    WorkflowEngine.disableQueueableInTest = true;
    ConcurrencyGate.mockConfigs.put(DEV_NAME, cfg(DEV_NAME, 2, 60));
    Test.startTest();
    Id plainId = WorkflowEngine.start(
      new WorkflowEngine.StartRequest(WF, 'start-plain', null)
    );
    Id highId = WorkflowEngine.start(
      new WorkflowEngine.StartRequest(WF, 'start-high', null).withPriority(9)
    );
    List<Id> bulkIds = WorkflowEngine.start(
      new List<WorkflowEngine.StartRequest>{
        new WorkflowEngine.StartRequest(WF, 'start-bulk', null).withPriority(5)
      }
    );
    Test.stopTest();
    System.assertEquals(
      2,
      reload(plainId).Admission_Priority__c,
      'Omitted override: config priority'
    );
    System.assertEquals(
      9,
      reload(highId).Admission_Priority__c,
      'Scalar start override applies'
    );
    System.assertEquals(
      5,
      reload(bulkIds[0]).Admission_Priority__c,
      'Bulk start override applies'
    );
  }

  @IsTest
  static void testContinueAsNewKeepsPriority() {
    WorkflowEngine.disableQueueableInTest = true;
    Id runOne = WorkflowEngine.start(
      new WorkflowEngine.StartRequest(
          'WorkflowEngineMocksBTest.DaemonWorkflow',
          'priority-daemon',
          0
        )
        .withPriority(6)
    );
    Test.startTest();
    new WorkflowOrchestrator(runOne).execute(null);
    Test.stopTest();
    Workflow_Instance__c runTwo = [
      SELECT Admission_Priority__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :runOne
    ];
    System.assertEquals(
      6,
      runTwo.Admission_Priority__c,
      'Successor keeps the priority'
    );
  }

  @IsTest
  static void testFlowSignalOrStartPassesPriority() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowSignalOrStartInvocableAction.SignalOrStartRequest req = new WorkflowSignalOrStartInvocableAction.SignalOrStartRequest();
    req.workflowName = WF;
    req.correlationKey = 'flow-sos-priority-1';
    req.signalName = 'Go';
    req.priority = 8;
    Test.startTest();
    List<WorkflowSignalOrStartInvocableAction.SignalOrStartResult> results = WorkflowSignalOrStartInvocableAction.signalOrStartWorkflow(
      new List<WorkflowSignalOrStartInvocableAction.SignalOrStartRequest>{ req }
    );
    Test.stopTest();
    System.assertEquals(
      8,
      reload(results[0].workflowInstanceId).Admission_Priority__c,
      'Flow signal-or-start priority applies'
    );
  }

  @IsTest
  static void testFlowStartPassesPriority() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowStartInvocableAction.StartRequest req = new WorkflowStartInvocableAction.StartRequest();
    req.workflowName = WF;
    req.correlationKey = 'flow-priority-1';
    req.priority = 7;
    Test.startTest();
    List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
      new List<WorkflowStartInvocableAction.StartRequest>{ req }
    );
    Test.stopTest();
    System.assertEquals(
      7,
      reload(results[0].workflowInstanceId).Admission_Priority__c,
      'Flow input priority applies'
    );
  }
}
