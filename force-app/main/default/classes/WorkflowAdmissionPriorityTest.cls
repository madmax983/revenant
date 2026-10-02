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
 *  #275 — a resumed paused bounded start joins the queue before its worker.
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

  // Wake jobs enqueued in this test, before Test.stopTest runs them.
  private static Integer wakeJobs() {
    return [
      SELECT COUNT()
      FROM AsyncApexJob
      WHERE ApexClass.Name = 'ConcurrencyAdmissionWake'
    ];
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
  // Inserts `count` waiting rows at one priority in one DML per object.
  private static List<Id> newWaitingFlood(
    String prefix,
    Integer count,
    Integer priority
  ) {
    List<Workflow_Instance__c> rows = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < count; i++) {
      rows.add(
        new Workflow_Instance__c(
          Workflow_Name__c = WF,
          Status__c = 'Pending',
          Current_Step__c = STEP,
          Correlation_Key__c = prefix + i,
          Concurrency_Parked__c = true,
          Admission_Priority__c = priority
        )
      );
    }
    insert rows;
    List<Workflow_Step_Execution__c> steps = new List<Workflow_Step_Execution__c>();
    List<Id> ids = new List<Id>();
    for (Workflow_Instance__c row : rows) {
      ids.add(row.Id);
      steps.add(
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = row.Id,
          Step_Name__c = STEP,
          Status__c = 'Pending',
          Retry_Count__c = 0
        )
      );
    }
    insert steps;
    return ids;
  }

  @IsTest
  static void testLowAdmitsWithinAgingBound() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    Datetime t0 = Datetime.newInstanceGmt(2026, 5, 1, 0, 0, 0);
    Id holder = fillSlot('s-holder');

    WorkflowEngine.mockNow = t0;
    Id low = newWaiting('s-low', 0);
    // Starts 8 h later: inside the 9 h bound ((9 − 0) × 60 min). Goes first.
    WorkflowEngine.mockNow = t0.addHours(8);
    Id earlyHigh = newWaiting('s-high-early', 9);
    // A flood that starts after the bound. It cannot go before low.
    WorkflowEngine.mockNow = t0.addHours(9).addMinutes(1);
    List<Id> flood = newWaitingFlood('s-flood-', 25, 9);
    WorkflowEngine.mockNow = null;

    Test.startTest();
    finish(holder);
    WorkflowEngine.runStep(low, null);
    System.assert(!isAdmitted(low), 'Low yields to a high inside the bound');
    WorkflowEngine.runStep(earlyHigh, null);
    System.assert(isAdmitted(earlyHigh), 'Early high admits');

    finish(earlyHigh);
    WorkflowEngine.runStep(flood[24], null);
    WorkflowEngine.runStep(flood[0], null);
    WorkflowEngine.runStep(low, null);
    Test.stopTest();

    System.assert(isAdmitted(low), 'Low admits within the bound');
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Id IN :flood AND Concurrency_Slot_Held__c = TRUE
      ],
      'No flood row goes before low'
    );
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

  // ── The ahead scan is capped. A full capped scan yields ─────────────────
  @IsTest
  static void testCappedScanYieldsWhenFull() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(5, 60);
    ConcurrencyAdmissionOrder.maxAheadScan = 1;
    Id high = newWaiting('cap-high', 9);
    Id low = newWaiting('cap-low', 0);

    Test.startTest();
    WorkflowEngine.runStep(low, null); // 5 free, scan cap 1, 1 row ahead
    WorkflowEngine.runStep(high, null); // nothing ahead
    Test.stopTest();

    System.assert(!isAdmitted(low), 'A full capped scan yields');
    System.assert(isAdmitted(high), 'The head admits');
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

  // ── Legacy rows: a blank key ranks first, in Id order ──────────────────
  // Makes a row look like it was inserted before this feature.
  private static Id newLegacyWaiting(String key) {
    Id legacy = newWaiting(key, 0);
    update new Workflow_Instance__c(
      Id = legacy,
      Admission_Priority__c = null,
      Admission_Key__c = null
    );
    return legacy;
  }

  @IsTest
  static void testLegacyRowRanksFirst() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    Id legacy = newLegacyWaiting('l-legacy');
    Id high = newWaiting('l-high', 9);

    Test.startTest();
    WorkflowEngine.runStep(high, null);
    WorkflowEngine.runStep(legacy, null);
    Test.stopTest();

    System.assert(!isAdmitted(high), 'A blank-key row ranks first');
    System.assert(isAdmitted(legacy), 'The legacy row admits');
    System.assertEquals(
      null,
      [SELECT Admission_Key__c FROM Workflow_Instance__c WHERE Id = :legacy]
      .Admission_Key__c,
      'The gate does not write a key'
    );
  }

  // A backlog of legacy rows drains in Id order. It does not stall.
  @IsTest
  static void testLegacyBacklogDrainsInIdOrder() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    Id first = newLegacyWaiting('lb-1');
    Id second = newLegacyWaiting('lb-2');
    Id third = newLegacyWaiting('lb-3');

    Test.startTest();
    WorkflowEngine.runStep(third, null);
    WorkflowEngine.runStep(second, null);
    WorkflowEngine.runStep(first, null);
    Test.stopTest();

    System.assert(!isAdmitted(third), 'Later legacy row yields');
    System.assert(!isAdmitted(second), 'Later legacy row yields');
    System.assert(isAdmitted(first), 'Oldest legacy row admits');
  }

  // ── Admission aborts the old retry timer ────────────────────────────────
  @IsTest
  static void testAdmissionAbortsOldRetryTimer() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.useDynamicScheduling = true;
    configure(1, 60);
    Id holder = fillSlot('a-holder');
    Id waiting = newWaiting('a-waiting', 0);
    WorkflowEngine.runStep(waiting, null); // ceiling full: park with a timer
    String jobId = [
      SELECT Async_Job_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :waiting
    ]
    .Async_Job_Id__c;
    System.assertNotEquals(null, jobId, 'The park scheduled a retry timer');

    Test.startTest();
    finish(holder);
    WorkflowEngine.runStep(waiting, null); // admits
    Test.stopTest();

    System.assert(isAdmitted(waiting), 'The row admits');
    System.assertEquals(
      0,
      [SELECT COUNT() FROM CronTrigger WHERE Id = :jobId],
      'The old retry timer is aborted'
    );
  }

  // ── Admit-only wake: admits a waiting head, never runs a step ───────────
  @IsTest
  static void testWakeAdmitsWithoutRunningStep() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    Id high = newWaiting('w-high', 9);

    Test.startTest();
    new ConcurrencyAdmissionWake(new List<Id>{ high }).execute(null);
    Test.stopTest();

    System.assert(isAdmitted(high), 'The wake admits the head');
    System.assertEquals(
      'Pending',
      [
        SELECT Status__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :high
      ]
      .Status__c,
      'The wake runs no step'
    );
  }

  // Regression: a wake with more than five rows admits each row.
  @IsTest
  static void testWakeAdmitsMoreThanFiveRows() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(10, 60);
    List<Id> rows = newWaitingFlood('m-', 7, 0);

    Test.startTest();
    new ConcurrencyAdmissionWake(rows).execute(null);
    Test.stopTest();

    System.assertEquals(
      7,
      [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Id IN :rows AND Concurrency_Slot_Held__c = TRUE
      ],
      'Each row in the wake admits'
    );
  }

  @IsTest
  static void testWakeIsNoOpForAdmittedRow() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    Id holder = fillSlot('n-holder');
    Workflow_Instance__c before = [
      SELECT Status__c, LastModifiedDate
      FROM Workflow_Instance__c
      WHERE Id = :holder
    ];

    Test.startTest();
    new ConcurrencyAdmissionWake(new List<Id>{ holder }).execute(null);
    Test.stopTest();

    Workflow_Instance__c after = [
      SELECT Status__c, Concurrency_Slot_Held__c
      FROM Workflow_Instance__c
      WHERE Id = :holder
    ];
    System.assertEquals(before.Status__c, after.Status__c, 'No change');
    System.assert(after.Concurrency_Slot_Held__c, 'Slot kept');
    System.assertEquals(
      1,
      [SELECT In_Flight_Count__c FROM Concurrency_State__c LIMIT 1]
      .In_Flight_Count__c,
      'No second slot'
    );
  }

  // ── An admit with rows ahead also wakes them ────────────────────────────
  @IsTest
  static void testAdmitAlsoWakesRowsAhead() {
    WorkflowEngine.disableQueueableInTest = false;
    WorkflowEngine.useDynamicScheduling = false;
    configure(2, 60);
    newWaiting('aw-high', 9);
    Id low = newWaiting('aw-low', 0);

    Test.startTest();
    WorkflowEngine.runStep(low, null);
    System.assert(isAdmitted(low), 'Two free slots: low admits');
    System.assertEquals(1, wakeJobs(), 'The admit also wakes the row ahead');
    Test.stopTest();
  }

  // ── A yield wakes the rows ahead with one admit-only Queueable ──────────
  @IsTest
  static void testYieldEnqueuesOneWake() {
    WorkflowEngine.disableQueueableInTest = false;
    WorkflowEngine.useDynamicScheduling = false;
    configure(1, 60);
    newWaiting('q-high', 9);
    Id low = newWaiting('q-low', 0);

    Test.startTest();
    WorkflowEngine.runStep(low, null);
    System.assert(!isAdmitted(low), 'Low yields');
    System.assertEquals(1, wakeJobs(), 'One wake job for the rows ahead');
    Test.stopTest();
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
    WorkflowEngine.useDynamicScheduling = true;
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

  // ── Issue #275: a resume puts a paused bounded start in the queue ───────
  // The shape a paused start leaves: Paused, no marker, no slot.
  private static Id newPausedStart(String key, Integer priority) {
    Id id = newWaiting(key, priority);
    update new Workflow_Instance__c(
      Id = id,
      Status__c = 'Paused',
      Concurrency_Parked__c = false
    );
    return id;
  }

  private static Workflow_Instance__c load(Id id) {
    return [
      SELECT Status__c, Concurrency_Parked__c, Admission_Queue__c
      FROM Workflow_Instance__c
      WHERE Id = :id
    ];
  }

  @IsTest
  static void testResumedPausedStartJoinsQueueBeforeWorker() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    Id paused = newPausedStart('r-paused', 9);

    Test.startTest();
    WorkflowPauseResumeDrainer.resumeParkedChunk(WF);
    Test.stopTest();

    Workflow_Instance__c row = load(paused);
    System.assertEquals('Running', row.Status__c, 'Resumed');
    System.assertEquals(true, row.Concurrency_Parked__c, 'Marker set');
    System.assertEquals(WF, row.Admission_Queue__c, 'In the queue');
  }

  @IsTest
  static void testLowYieldsToResumedHighStart() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    Id holder = fillSlot('y-holder');
    Id high = newPausedStart('y-high', 9);
    Id low = newWaiting('y-low', 0);

    Test.startTest();
    WorkflowPauseResumeDrainer.resumeParkedChunk(WF);
    System.assertEquals(WF, load(high).Admission_Queue__c, 'High is queued');
    finish(holder);
    WorkflowEngine.runStep(low, null);
    Test.stopTest();

    System.assert(!isAdmitted(low), 'Low yields to the resumed high start');
    WorkflowEngine.runStep(high, null);
    System.assert(isAdmitted(high), 'High takes the free slot');
  }

  @IsTest
  static void testResumedUnboundedStartIsNotMarked() {
    WorkflowEngine.disableQueueableInTest = true;
    Id paused = newPausedStart('u-paused', 0);

    Test.startTest();
    WorkflowPauseResumeDrainer.resumeParkedChunk(WF);
    Test.stopTest();

    Workflow_Instance__c row = load(paused);
    System.assertEquals('Running', row.Status__c, 'Resumed');
    System.assertEquals(false, row.Concurrency_Parked__c, 'No marker');
    System.assertEquals(null, row.Admission_Queue__c, 'Not queued');
  }

  @IsTest
  static void testResumedSlotHolderIsNotMarked() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    Id holder = fillSlot('h-holder');
    update new Workflow_Instance__c(Id = holder, Status__c = 'Paused');

    Test.startTest();
    WorkflowPauseResumeDrainer.resumeParkedChunk(WF);
    Test.stopTest();

    Workflow_Instance__c row = load(holder);
    System.assertEquals(
      null,
      row.Admission_Queue__c,
      'Slot holder is not queued'
    );
    System.assert(isAdmitted(holder), 'Slot kept');
  }

  @IsTest
  static void testResumedMarkedStartStaysQueued() {
    WorkflowEngine.disableQueueableInTest = true;
    configure(1, 60);
    Id marked = newWaiting('m-marked', 0);
    update new Workflow_Instance__c(Id = marked, Status__c = 'Paused');

    Test.startTest();
    WorkflowPauseResumeDrainer.resumeParkedChunk(WF);
    Test.stopTest();

    Workflow_Instance__c row = load(marked);
    System.assertEquals('Running', row.Status__c, 'Resumed');
    System.assertEquals(WF, row.Admission_Queue__c, 'Still queued');
  }

  // ── #277: the queue read order is fixed, and a skipped queue is flagged ─
  private static void newGovernedWaiting(String workflowName) {
    insert new Concurrency_State__c(
      Workflow_Definition__c = workflowName,
      In_Flight_Count__c = 1
    );
    insert new Workflow_Instance__c(
      Workflow_Name__c = workflowName,
      Status__c = 'Pending',
      Correlation_Key__c = 'trunc-' + workflowName,
      Concurrency_Parked__c = true
    );
  }

  @IsTest
  static void testDashboardFlagsSkippedQueuesInNameOrder() {
    WorkflowEngine.disableQueueableInTest = true;
    for (String name : new List<String>{ 'WfC', 'WfA', 'WfB' }) {
      newGovernedWaiting(name);
    }
    WorkflowDashboardStatusService.maxQueueReadsOverride = 2;

    Test.startTest();
    List<Map<String, Object>> rows = WorkflowDashboardStatusService.concurrencyStatus();
    Test.stopTest();

    Map<String, Map<String, Object>> byName = new Map<String, Map<String, Object>>();
    for (Map<String, Object> row : rows) {
      byName.put((String) row.get('workflowName'), row);
    }
    System.assertEquals(
      1,
      ((List<Object>) byName.get('WfA').get('waiting')).size(),
      'The first name in order is read'
    );
    System.assertEquals(
      1,
      ((List<Object>) byName.get('WfB').get('waiting')).size(),
      'The second name in order is read'
    );
    System.assertEquals(false, byName.get('WfA').get('waitingTruncated'));
    System.assertEquals(false, byName.get('WfB').get('waitingTruncated'));
    System.assertEquals(
      0,
      ((List<Object>) byName.get('WfC').get('waiting')).size(),
      'The last name in order is skipped'
    );
    System.assertEquals(
      true,
      byName.get('WfC').get('waitingTruncated'),
      'The skipped queue is flagged'
    );
    System.assertEquals(
      1,
      byName.get('WfC').get('waitingTotal'),
      'Count stays'
    );
  }

  @IsTest
  static void testDashboardDoesNotFlagWorkflowWithNoWaiters() {
    WorkflowEngine.disableQueueableInTest = true;
    insert new Concurrency_State__c(
      Workflow_Definition__c = 'WfIdle',
      In_Flight_Count__c = 1
    );

    Test.startTest();
    List<Map<String, Object>> rows = WorkflowDashboardStatusService.concurrencyStatus();
    Test.stopTest();

    System.assertEquals(
      false,
      rows[0].get('waitingTruncated'),
      'An empty queue is not truncated'
    );
  }
}
