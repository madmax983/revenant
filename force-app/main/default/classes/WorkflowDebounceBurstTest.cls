/**
 * @description Tests for debounced starts (issue #140): burst coalescing,
 * the whole-second fire time, the sweep lock and the parallel-insert recovery.
 */
@IsTest
private class WorkflowDebounceBurstTest {
  private static final String WORKFLOW = 'WorkflowEngineTest.HappyWorkflow';
  // A whole second near the real time, so other heartbeat sweeps see a
  // normal clock.
  private static final Datetime BASE = Datetime.newInstance(
    (Datetime.now().getTime() / 1000L) * 1000L
  );

  private static void arm(String key, String inputJson, Integer seconds) {
    WorkflowDebouncer.startDebounced(
      new List<WorkflowDebouncer.DebounceRequest>{
        new WorkflowDebouncer.DebounceRequest(WORKFLOW, key, inputJson)
          .withDebounce(seconds)
      }
    );
  }

  private static List<Workflow_Instance__c> instances(String key) {
    return [
      SELECT Id, Input__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :key
    ];
  }

  private static List<Debounce_State__c> states(String key) {
    return [
      SELECT Id, Input_Json__c, Fire_At__c, First_Triggered_At__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = :key
    ];
  }

  private static Datetime at(Long offsetMillis) {
    return Datetime.newInstance(BASE.getTime() + offsetMillis);
  }

  @IsTest
  static void fiftyTriggersStartOnceWithLastInputAfterQuietWindow() {
    WorkflowEngine.disableQueueableInTest = true;
    // 50 triggers, 100 ms apart. The last one is at BASE + 4.9 s.
    for (Integer i = 1; i <= 50; i++) {
      WorkflowEngine.mockNow = at((i - 1) * 100L);
      arm('burst-50', '{"seq":' + i + '}', 10);
    }
    Long lastTrigger = at(4900L).getTime();

    List<Debounce_State__c> pending = states('burst-50');
    System.assertEquals(1, pending.size(), 'One row for the key');
    System.assertEquals(
      BASE.addSeconds(15),
      pending[0].Fire_At__c,
      'Fire at the first whole second at or after last + 10 s'
    );
    System.assert(
      pending[0].Fire_At__c.getTime() >= lastTrigger + 10000L,
      'Never fire before the quiet window ends'
    );

    Test.startTest();
    WorkflowDebounceSweeper.sweep(Datetime.newInstance(lastTrigger + 9999L));
    System.assertEquals(0, instances('burst-50').size(), 'Not yet quiet');

    WorkflowEngine.mockNow = BASE.addSeconds(15);
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    List<Workflow_Instance__c> started = instances('burst-50');
    System.assertEquals(1, started.size(), 'Exactly one instance');
    System.assertEquals('{"seq":50}', started[0].Input__c, 'Last input wins');
    System.assertEquals(0, states('burst-50').size(), 'Row deleted');
  }

  @IsTest
  static void noCapKeepsDeferringWhileTriggersContinue() {
    WorkflowEngine.disableQueueableInTest = true;
    Test.startTest();
    for (Integer i = 1; i <= 20; i++) {
      Datetime now = BASE.addSeconds((i - 1) * 9);
      WorkflowEngine.mockNow = now;
      WorkflowDebounceSweeper.sweep(now);
      arm('no-cap', '{"seq":' + i + '}', 10);
    }
    System.assertEquals(0, instances('no-cap').size(), 'Pure trailing edge');

    // Last trigger at BASE + 171 s.
    WorkflowDebounceSweeper.sweep(BASE.addSeconds(181));
    Test.stopTest();

    List<Workflow_Instance__c> started = instances('no-cap');
    System.assertEquals(1, started.size(), 'One start after the burst');
    System.assertEquals('{"seq":20}', started[0].Input__c, 'Last input wins');
  }

  @IsTest
  static void sweepSkipsRowThatWasReArmedAfterItsRead() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.mockNow = BASE;
    arm('rearm', '{"seq":1}', 10);

    Datetime sweepAt = BASE.addSeconds(11);
    List<Id> dueIds = WorkflowDebounceSweeper.findDueIds(sweepAt);
    System.assertEquals(1, dueIds.size(), 'Due at read time');

    // A new trigger lands after the read and before the lock.
    WorkflowEngine.mockNow = sweepAt;
    arm('rearm', '{"seq":2}', 10);

    System.assertEquals(
      0,
      WorkflowDebounceSweeper.lockDueStates(dueIds, sweepAt).size(),
      'The re-armed row is not due under the lock'
    );

    Test.startTest();
    WorkflowDebounceSweeper.sweep(sweepAt);
    System.assertEquals(0, instances('rearm').size(), 'No early start');
    WorkflowDebounceSweeper.sweep(BASE.addSeconds(21));
    Test.stopTest();

    List<Workflow_Instance__c> started = instances('rearm');
    System.assertEquals(1, started.size(), 'One start');
    System.assertEquals('{"seq":2}', started[0].Input__c, 'Last input wins');
  }

  @IsTest
  static void lockedReadGivesTheNewestInput() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.mockNow = BASE;
    WorkflowDebouncer.startDebounced(
      new List<WorkflowDebouncer.DebounceRequest>{
        new WorkflowDebouncer.DebounceRequest(WORKFLOW, 'fresh', '{"seq":1}')
          .withDebounce(10)
          .withMaxWait(5)
      }
    );
    Datetime sweepAt = BASE.addSeconds(6);
    List<Id> dueIds = WorkflowDebounceSweeper.findDueIds(sweepAt);

    // The cap keeps the row due, but the input changes.
    WorkflowEngine.mockNow = sweepAt;
    WorkflowDebouncer.startDebounced(
      new List<WorkflowDebouncer.DebounceRequest>{
        new WorkflowDebouncer.DebounceRequest(WORKFLOW, 'fresh', '{"seq":2}')
          .withDebounce(10)
          .withMaxWait(5)
      }
    );

    List<Debounce_State__c> locked = WorkflowDebounceSweeper.lockDueStates(
      dueIds,
      sweepAt
    );
    System.assertEquals(1, locked.size(), 'Still due');
    System.assertEquals(
      '{"seq":2}',
      WorkflowPayloadCodecs.decode(locked[0].Input_Json__c),
      'The lock read gives the newest input'
    );
  }

  @IsTest
  static void parallelFirstInsertUpdatesTheOtherRow() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.mockNow = BASE;
    arm('parallel', '{"seq":1}', 10);

    // Another transaction committed the row after this read.
    WorkflowDebouncer.skipExistingLoadForTest = true;
    WorkflowEngine.mockNow = BASE.addSeconds(2);
    arm('parallel', '{"seq":2}', 10);
    WorkflowDebouncer.skipExistingLoadForTest = false;

    List<Debounce_State__c> rows = states('parallel');
    System.assertEquals(1, rows.size(), 'One row for the key');
    System.assertEquals('{"seq":2}', rows[0].Input_Json__c, 'New input');
    System.assertEquals(BASE.addSeconds(12), rows[0].Fire_At__c, 'Re-armed');
    System.assertEquals(
      BASE,
      rows[0].First_Triggered_At__c,
      'The first trigger time stays'
    );
  }

  @IsTest
  static void redeliveredFireCollapsesToOneInstance() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.mockNow = BASE;
    arm('redeliver', '{"seq":1}', 10);
    Debounce_State__c copy = [
      SELECT
        Debounce_Key__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Input_Json__c,
        Fire_At__c,
        First_Triggered_At__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'redeliver'
    ];

    Test.startTest();
    WorkflowDebounceSweeper.sweep(BASE.addSeconds(10));
    insert copy.clone(false, true);
    WorkflowDebounceSweeper.sweep(BASE.addSeconds(10));
    Test.stopTest();

    System.assertEquals(1, instances('redeliver').size(), 'One instance');
    System.assertEquals(0, states('redeliver').size(), 'Rows deleted');
  }

  @IsTest
  static void laterBurstAfterFinishedRunStartsAgain() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.dedupWindowMinutes = 1440;
    WorkflowEngine.mockNow = BASE;
    arm('repeat', '{"seq":1}', 10);

    Test.startTest();
    WorkflowDebounceSweeper.sweep(BASE.addSeconds(10));
    Workflow_Instance__c first = instances('repeat')[0];
    first.Status__c = 'Completed';
    first.Terminal_At__c = BASE.addSeconds(11);
    update first;

    // A new burst in the dedup window. It must not go to the finished run.
    WorkflowEngine.mockNow = BASE.addSeconds(20);
    arm('repeat', '{"seq":2}', 10);
    WorkflowDebounceSweeper.sweep(BASE.addSeconds(30));
    Test.stopTest();

    List<Workflow_Instance__c> runs = [
      SELECT Id, Input__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = 'repeat' AND Id != :first.Id
    ];
    System.assertEquals(1, runs.size(), 'The second burst starts a new run');
    System.assertEquals('{"seq":2}', runs[0].Input__c, 'It gets its input');
  }

  @IsTest
  static void armAndSweepAddNoScheduledJob() {
    WorkflowEngine.mockNow = BASE;
    Integer cronBefore = [SELECT COUNT() FROM CronTrigger];
    Integer asyncBefore = [SELECT COUNT() FROM AsyncApexJob];

    Test.startTest();
    // The queueable switch is off here. An arm that enqueued a job shows.
    for (Integer i = 0; i < 10; i++) {
      arm('slots-' + i, '{}', 10);
    }
    Integer queueablesAfterArm = Limits.getQueueableJobs();
    Integer asyncAfterArm = [SELECT COUNT() FROM AsyncApexJob];
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowDebounceSweeper.sweep(BASE.addSeconds(10));
    Test.stopTest();

    System.assertEquals(0, queueablesAfterArm, 'Arm enqueues no job');
    System.assertEquals(asyncBefore, asyncAfterArm, 'Arm adds no async job');
    System.assertEquals(
      cronBefore,
      [SELECT COUNT() FROM CronTrigger],
      'No scheduled-job slot'
    );
    System.assertEquals(
      10,
      [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c LIKE 'slots-%'
      ],
      'Each key starts once'
    );
  }

  @IsTest
  static void capFiresSustainedBurstOnceWithLastInputBeforeCap() {
    WorkflowEngine.disableQueueableInTest = true;
    Test.startTest();
    // 10 triggers, 3 s apart. Window 10 s, cap 15 s. The cap fires at 15 s.
    for (Integer i = 1; i <= 10; i++) {
      Datetime now = BASE.addSeconds((i - 1) * 3);
      WorkflowEngine.mockNow = now;
      WorkflowDebounceSweeper.sweep(now);
      System.assertEquals(
        now >= BASE.addSeconds(15) ? 1 : 0,
        instances('capped').size(),
        'The cap fires at first + 15 s, not before'
      );
      WorkflowDebouncer.startDebounced(
        new WorkflowDebouncer.DebounceRequest(
            WORKFLOW,
            'capped',
            '{"seq":' + i + '}'
          )
          .withDebounce(10)
          .withMaxWait(15)
      );
    }
    Test.stopTest();

    List<Workflow_Instance__c> started = instances('capped');
    System.assertEquals(1, started.size(), 'One start for the capped burst');
    // The trigger at 12 s (seq 5) is the last one before the cap.
    System.assertEquals('{"seq":5}', started[0].Input__c, 'Last input wins');
    System.assertEquals(1, states('capped').size(), 'Later triggers re-arm');
  }

  @IsTest
  static void flowBurstStartsOnceWithLastInput() {
    WorkflowEngine.disableQueueableInTest = true;
    for (Integer i = 1; i <= 10; i++) {
      WorkflowEngine.mockNow = BASE.addSeconds(i);
      WorkflowStartInvocableAction.StartRequest req = new WorkflowStartInvocableAction.StartRequest();
      req.workflowName = WORKFLOW;
      req.correlationKey = 'flow-burst';
      req.inputJson = '{"seq":' + i + '}';
      req.debounceSeconds = 10;
      WorkflowStartInvocableAction.StartResult result = WorkflowStartInvocableAction.startWorkflow(
        new List<WorkflowStartInvocableAction.StartRequest>{ req }
      )[0];
      System.assert(result.isValid, 'The Flow row is armed');
      System.assertEquals(null, result.workflowInstanceId, 'No instance yet');
    }

    Test.startTest();
    WorkflowDebounceSweeper.sweep(BASE.addSeconds(20));
    Test.stopTest();

    List<Workflow_Instance__c> started = instances('flow-burst');
    System.assertEquals(1, started.size(), 'One instance');
    System.assertEquals('{"seq":10}', started[0].Input__c, 'Last input wins');
  }

  @IsTest
  static void overlongWorkflowNameIsRejectedBeforeAnyWrite() {
    try {
      WorkflowDebouncer.startDebounced(
        new WorkflowDebouncer.DebounceRequest('n'.repeat(256), 'long', '{}')
          .withDebounce(10)
      );
      System.assert(false, 'An overlong name must fail');
    } catch (WorkflowEngine.WorkflowException ex) {
      System.assert(ex.getMessage().contains('255'), ex.getMessage());
    }
    System.assertEquals(0, [SELECT COUNT() FROM Debounce_State__c], 'No row');
  }

  @IsTest
  static void scalarOverloadArmsOneRow() {
    WorkflowEngine.mockNow = BASE;
    WorkflowDebouncer.startDebounced(
      new WorkflowDebouncer.DebounceRequest(WORKFLOW, 'scalar', '{"a":1}')
        .withDebounce(0)
    );
    List<Debounce_State__c> rows = states('scalar');
    System.assertEquals(1, rows.size(), 'One row');
    System.assertEquals(BASE, rows[0].Fire_At__c, 'Zero window fires now');
  }
}
