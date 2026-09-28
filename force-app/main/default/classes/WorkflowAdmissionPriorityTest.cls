/**
 * Integration tests for admission priority (issue #132). The gate runs
 * through `WorkflowEngine.runStep` on a ceiling-bound workflow.
 *
 * AC coverage:
 *  AC3 — higher priority admits before older lower priority.
 *  AC4 — FIFO in one priority class.
 *  AC5 — a low instance admits within the aging bound under a high flood.
 *  AC6 — priority does not change the step trail or the compensation stack.
 *  AC7 — one default class gives FIFO.
 *  AC8 — the dashboard concurrency view shows each waiting priority.
 *  AC9 — a yield adds no scheduled job beyond a normal park.
 */
@IsTest
public class WorkflowAdmissionPriorityTest {
  private static final String WF = 'WorkflowConcurrencyTest.WaitWorkflow';
  private static final String DEV_NAME = 'WorkflowConcurrencyTest_WaitWorkflow';
  private static final String STEP = 'WorkflowConcurrencyTest.WaitStep';

  private static void configure(Integer ceiling, Integer agingMinutes) {
    Map<String, Object> fields = new Map<String, Object>{
      'DeveloperName' => DEV_NAME,
      'Max_Concurrent_Instances__c' => ceiling,
      'Priority_Aging_Minutes__c' => agingMinutes
    };
    ConcurrencyGate.mockConfigs.put(
      DEV_NAME,
      (Concurrency_Config__mdt) JSON.deserialize(
        JSON.serialize(fields),
        Concurrency_Config__mdt.class
      )
    );
  }

  // Inserts a waiting instance: the shape a bounded start leaves (Pending,
  // awaiting-admission marker, Pending initial step).
  private static Id newWaiting(String key, Integer priority) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = 'Pending',
      Current_Step__c = STEP,
      Correlation_Key__c = key,
      Concurrency_Parked__c = true,
      Admission_Priority__c = priority
    );
    insert inst;
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = STEP,
      Status__c = 'Pending',
      Retry_Count__c = 0
    );
    return inst.Id;
  }

  // Admits one instance so the ceiling is full, then returns its Id.
  private static Id fillSlot(String key) {
    Id holder = newWaiting(key, 0);
    WorkflowEngine.runStep(holder, null);
    System.assert(isAdmitted(holder), 'Holder takes the slot');
    return holder;
  }

  private static void finish(Id id) {
    update new Workflow_Instance__c(Id = id, Status__c = 'Completed');
  }

  private static Boolean isAdmitted(Id id) {
    return [
      SELECT Concurrency_Slot_Held__c
      FROM Workflow_Instance__c
      WHERE Id = :id
    ]
    .Concurrency_Slot_Held__c;
  }

  private static Integer cronCount() {
    return [SELECT COUNT() FROM CronTrigger];
  }

  // ── AC3: higher priority wins, regardless of CreatedDate ────────────────
  @IsTest
  static void testHighPriorityAdmitsBeforeOlderLow() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    Id holder = fillSlot('p-holder');
    Id low1 = newWaiting('p-low-1', 0);
    Id low2 = newWaiting('p-low-2', 0);
    Id high = newWaiting('p-high', 9);

    Test.startTest();
    finish(holder);
    WorkflowEngine.runStep(low1, null);
    WorkflowEngine.runStep(low2, null);
    WorkflowEngine.runStep(high, null);
    Test.stopTest();

    System.assert(!isAdmitted(low1), 'Older low yields to high');
    System.assert(!isAdmitted(low2), 'Older low yields to high');
    System.assert(isAdmitted(high), 'Newest high takes the free slot');
  }

  // ── AC4 / AC7: FIFO in one class (the default class) ────────────────────
  @IsTest
  static void testDefaultClassIsFifoByCreatedDate() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, null);
    Id holder = fillSlot('f-holder');
    Id first = newWaiting('f-1', null);
    Id second = newWaiting('f-2', null);
    Id third = newWaiting('f-3', null);

    Test.startTest();
    finish(holder);
    WorkflowEngine.runStep(third, null);
    WorkflowEngine.runStep(second, null);
    WorkflowEngine.runStep(first, null);
    Test.stopTest();

    System.assertEquals(
      0,
      [SELECT Admission_Priority__c FROM Workflow_Instance__c WHERE Id = :first]
      .Admission_Priority__c,
      'No config and no override: default priority 0'
    );
    System.assert(!isAdmitted(third), 'Newer instance yields');
    System.assert(!isAdmitted(second), 'Newer instance yields');
    System.assert(isAdmitted(first), 'Oldest instance admits first');
  }

  // ── AC5: the aging bound stops starvation under a high-priority flood ───
  @IsTest
  static void testLowAdmitsWithinAgingBound() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    Datetime t0 = Datetime.newInstanceGmt(2026, 5, 1, 0, 0, 0);
    Id holder = fillSlot('s-holder');

    WorkflowEngine.mockNow = t0;
    Id low = newWaiting('s-low', 0);
    // Starts 8 h later: inside the 9 h bound ((9 − 0) × 60 min). Passes low.
    WorkflowEngine.mockNow = t0.addHours(8);
    Id earlyHigh = newWaiting('s-high-early', 9);
    // Starts after the bound. Cannot pass low.
    WorkflowEngine.mockNow = t0.addHours(9).addMinutes(1);
    Id lateHigh1 = newWaiting('s-high-late-1', 9);
    Id lateHigh2 = newWaiting('s-high-late-2', 9);
    WorkflowEngine.mockNow = null;

    Test.startTest();
    finish(holder);
    WorkflowEngine.runStep(low, null);
    System.assert(!isAdmitted(low), 'Low yields to a high inside the bound');
    WorkflowEngine.runStep(earlyHigh, null);
    System.assert(isAdmitted(earlyHigh), 'Early high admits');

    finish(earlyHigh);
    WorkflowEngine.runStep(lateHigh1, null);
    WorkflowEngine.runStep(lateHigh2, null);
    WorkflowEngine.runStep(low, null);
    Test.stopTest();

    System.assert(!isAdmitted(lateHigh1), 'Late high cannot pass low');
    System.assert(!isAdmitted(lateHigh2), 'Late high cannot pass low');
    System.assert(isAdmitted(low), 'Low admits within the bound');
  }

  // ── Free slots: admit when fewer rows rank ahead than slots are free ────
  @IsTest
  static void testAdmitsWhenFreeSlotsCoverRowsAhead() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(2, 60);
    Id high = newWaiting('c-high', 9);
    Id low = newWaiting('c-low', 0);

    Test.startTest();
    WorkflowEngine.runStep(low, null);
    Test.stopTest();

    System.assert(isAdmitted(low), 'Two free slots cover one row ahead');
    System.assert(!isAdmitted(high), 'High keeps its place for its own visit');
  }

  // ── Gate result names the rows the visitor yields to ────────────────────
  @IsTest
  static void testGateReportsRowsAhead() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    Id high = newWaiting('g-high', 9);
    Id low = newWaiting('g-low', 0);
    Workflow_Instance__c candidate = [
      SELECT Id, Workflow_Name__c, Admission_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :low
    ];

    Test.startTest();
    ConcurrencyGate.AdmissionResult result = ConcurrencyGate.tryAcquire(
      WF,
      candidate
    );
    Test.stopTest();

    System.assert(!result.admitted, 'Low does not take the slot');
    System.assertEquals(
      new List<Id>{ high },
      result.aheadIds,
      'Result names the row ahead'
    );
    System.assertEquals(
      0,
      [SELECT In_Flight_Count__c FROM Concurrency_State__c LIMIT 1]
      .In_Flight_Count__c,
      'A yield consumes no slot'
    );
  }

  // ── Legacy rows: a blank key ranks first and heals on the gate visit ────
  @IsTest
  static void testLegacyRowRanksFirstAndIsBackfilled() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    Id legacy = newWaiting('l-legacy', 0);
    update new Workflow_Instance__c(
      Id = legacy,
      Admission_Priority__c = null,
      Admission_Key__c = null
    );
    Id high = newWaiting('l-high', 9);

    Test.startTest();
    WorkflowEngine.runStep(high, null);
    System.assert(!isAdmitted(high), 'A blank-key row ranks first');
    // The visit writes the key. Now the legacy row ranks by its real key.
    WorkflowEngine.runStep(legacy, null);
    WorkflowEngine.runStep(high, null);
    Test.stopTest();

    Workflow_Instance__c healed = [
      SELECT Admission_Key__c, Admission_Priority__c, Concurrency_Slot_Held__c
      FROM Workflow_Instance__c
      WHERE Id = :legacy
    ];
    System.assertNotEquals(null, healed.Admission_Key__c, 'Key backfilled');
    System.assertEquals(0, healed.Admission_Priority__c, 'Priority backfilled');
    System.assert(!healed.Concurrency_Slot_Held__c, 'Legacy row yields');
    System.assert(isAdmitted(high), 'High admits once the key is healed');
  }

  // ── AC6: ordering only — no change to step rows or compensation stack ───
  @IsTest
  static void testPriorityDoesNotChangeStepTrail() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    Id holder = fillSlot('t-holder');
    Id low = newWaiting('t-low', 0);
    Id high = newWaiting('t-high', 9);
    update new Workflow_Instance__c(
      Id = low,
      Compensation_Stack__c = '["A","B"]'
    );

    Test.startTest();
    finish(holder);
    WorkflowEngine.runStep(low, null); // yields
    WorkflowEngine.runStep(high, null); // admits
    Test.stopTest();

    List<Workflow_Step_Execution__c> lowSteps = [
      SELECT Step_Name__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :low
    ];
    System.assertEquals(1, lowSteps.size(), 'A yield adds no step row');
    System.assertEquals('Pending', lowSteps[0].Status__c, 'Step not run');
    System.assertEquals(
      '["A","B"]',
      [SELECT Compensation_Stack__c FROM Workflow_Instance__c WHERE Id = :low]
      .Compensation_Stack__c,
      'Compensation stack unchanged'
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :high
      ],
      'Admission adds no step row'
    );
  }

  // ── AC9: a yield schedules no more jobs than a normal park ──────────────
  @IsTest
  static void testYieldAddsNoScheduledJob() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    Id holder = fillSlot('j-holder');
    Id high = newWaiting('j-high', 9);
    Id low = newWaiting('j-low', 0);

    Test.startTest();
    Integer beforePark = cronCount();
    WorkflowEngine.runStep(high, null); // ceiling full: normal park
    Integer parkJobs = cronCount() - beforePark;

    finish(holder);
    Integer beforeYield = cronCount();
    WorkflowEngine.runStep(low, null); // free slot, high ahead: yield
    Integer yieldJobs = cronCount() - beforeYield;
    Test.stopTest();

    System.assert(!isAdmitted(low), 'Low yields');
    System.assertEquals(
      parkJobs,
      yieldJobs,
      'A yield uses the same retry timer as a park'
    );
  }

  // ── AC8: the dashboard shows each waiting instance's priority ───────────
  @IsTest
  static void testDashboardShowsWaitingPriority() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    fillSlot('d-holder');
    Id low = newWaiting('d-low', 0);
    Id high = newWaiting('d-high', 9);

    Test.startTest();
    List<Map<String, Object>> rows = WorkflowDashboardController.getConcurrencyStatus();
    Test.stopTest();

    System.assertEquals(1, rows.size(), 'One governed workflow');
    List<Map<String, Object>> waiting = (List<Map<String, Object>>) rows[0]
      .get('waiting');
    System.assertEquals(2, waiting.size(), 'Both waiting rows listed');
    System.assertEquals(high, waiting[0].get('instanceId'), 'High is next');
    System.assertEquals(9, waiting[0].get('priority'), 'High priority shown');
    System.assertEquals(1, waiting[0].get('position'), 'Queue position 1');
    System.assertEquals(low, waiting[1].get('instanceId'), 'Low is second');
    System.assertEquals(0, waiting[1].get('priority'), 'Low priority shown');
    System.assertEquals(2, rows[0].get('waitingTotal'), 'Waiting total');
    Map<String, Object> classes = (Map<String, Object>) rows[0]
      .get('waitingByPriority');
    System.assertEquals(1, classes.get('9'), 'One waiting at priority 9');
    System.assertEquals(1, classes.get('0'), 'One waiting at priority 0');
  }
}
