@isTest
public class WorkflowScheduleSweeperTest {
  // Cron that always resolves to a past fire minute regardless of test run time.
  // "* * * * *" fires every minute, so previousFireTime = truncated-now.
  private static final String EVERY_MINUTE_CRON = '* * * * *';
  // A workflow that actually exists in the engine test class.
  private static final String TEST_WF = 'WorkflowEngineTest.HappyWorkflow';
  private static final String PREFIX = 'SchedTest';

  private static Workflow_Schedule__c makeSchedule(
    String name,
    String cron,
    Boolean enabled,
    String overlapPolicy
  ) {
    return new Workflow_Schedule__c(
      Name = name,
      Workflow_Name__c = TEST_WF,
      Cron_Expression__c = cron,
      Correlation_Key_Prefix__c = name,
      Enabled__c = enabled,
      Overlap_Policy__c = overlapPolicy,
      Dedicated_Slot__c = false
    );
  }

  // ── AC2 / AC3: due fires exactly once, second sweep is a no-op ──────────

  @isTest
  static void testDueFiresOnce() {
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Schedule__c sched = makeSchedule(PREFIX + '1', EVERY_MINUTE_CRON, true, 'Allow');
    insert sched;

    Test.startTest();
    WorkflowScheduleSweeper.sweep();
    Test.stopTest();

    List<Workflow_Instance__c> instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c LIKE :PREFIX + '1_%'
    ];
    System.assertEquals(1, instances.size(), 'First sweep: exactly one instance should be created');

    // Second sweep — Last_Fired_Window__c is now set → not due → no new instance.
    WorkflowScheduleSweeper.sweep();
    instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c LIKE :PREFIX + '1_%'
    ];
    System.assertEquals(1, instances.size(), 'Second sweep: should remain exactly one instance');
  }

  // ── AC3: not-due schedule (Last_Fired_Window__c already set) skips ───────

  @isTest
  static void testNotDueSkips() {
    WorkflowEngine.disableQueueableInTest = true;

    DateTime now = DateTime.now();
    // Pre-set Last_Fired_Window__c to the current window so it looks already done.
    DateTime fireTime = WorkflowCronEvaluator.previousFireTime(EVERY_MINUTE_CRON, now);

    Workflow_Schedule__c sched = makeSchedule(PREFIX + '2', EVERY_MINUTE_CRON, true, 'Allow');
    sched.Last_Fired_Window__c = fireTime;
    insert sched;

    WorkflowScheduleSweeper.sweep();

    List<Workflow_Instance__c> instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c LIKE :PREFIX + '2_%'
    ];
    System.assertEquals(0, instances.size(), 'Already-fired window should not start a new instance');
  }

  @isTest
  static void testNeverMatchCronSkips() {
    WorkflowEngine.disableQueueableInTest = true;

    // Feb 31 never exists → previousFireTime returns null → sweep skips.
    Workflow_Schedule__c sched = makeSchedule(PREFIX + '3', '0 0 31 2 *', true, 'Allow');
    insert sched;

    WorkflowScheduleSweeper.sweep();

    List<Workflow_Instance__c> instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c LIKE :PREFIX + '3_%'
    ];
    System.assertEquals(0, instances.size(), 'Never-match cron should not start any instance');
  }

  // ── AC4: Overlap=Skip records a Skipped log, does not start new instance ─

  @isTest
  static void testOverlapSkip() {
    WorkflowEngine.disableQueueableInTest = true;

    DateTime now = DateTime.now();
    DateTime fireTime = WorkflowCronEvaluator.previousFireTime(EVERY_MINUTE_CRON, now);

    Workflow_Schedule__c sched = makeSchedule(PREFIX + '4', EVERY_MINUTE_CRON, true, 'Skip');
    insert sched;

    // Pre-insert an OLDER active instance (different key) so it looks like last run is still going.
    String oldKey = PREFIX + '4_197001010000';
    Workflow_Instance__c priorRun = new Workflow_Instance__c(
      Workflow_Name__c = TEST_WF,
      Correlation_Key__c = oldKey,
      Status__c = 'Running'
    );
    insert priorRun;

    Test.startTest();
    WorkflowScheduleSweeper.sweep();
    Test.stopTest();

    // No new instance for the new window.
    String currentKey = PREFIX + '4_' + fireTime.formatGmt('yyyyMMddHHmm');
    List<Workflow_Instance__c> newInstances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :currentKey
    ];
    System.assertEquals(0, newInstances.size(), 'Overlap=Skip: should not start a new instance');

    // Skipped log exists.
    List<Workflow_Log__c> logs = [
      SELECT Outcome__c
      FROM Workflow_Log__c
      WHERE Schedule_Name__c = :(PREFIX + '4') AND Outcome__c = 'Skipped'
    ];
    System.assertEquals(1, logs.size(), 'Overlap=Skip: a Skipped log entry should exist');
  }

  // ── AC5: Overlap=Allow starts a new instance even with prior in-flight ───

  @isTest
  static void testOverlapAllow() {
    WorkflowEngine.disableQueueableInTest = true;

    DateTime now = DateTime.now();
    DateTime fireTime = WorkflowCronEvaluator.previousFireTime(EVERY_MINUTE_CRON, now);

    Workflow_Schedule__c sched = makeSchedule(PREFIX + '5', EVERY_MINUTE_CRON, true, 'Allow');
    insert sched;

    // Older active instance still running.
    String oldKey = PREFIX + '5_197001010000';
    Workflow_Instance__c priorRun = new Workflow_Instance__c(
      Workflow_Name__c = TEST_WF,
      Correlation_Key__c = oldKey,
      Status__c = 'Running'
    );
    insert priorRun;

    Test.startTest();
    WorkflowScheduleSweeper.sweep();
    Test.stopTest();

    // New instance for the current window was created.
    String currentKey = PREFIX + '5_' + fireTime.formatGmt('yyyyMMddHHmm');
    List<Workflow_Instance__c> newInstances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :currentKey
    ];
    System.assertEquals(1, newInstances.size(), 'Overlap=Allow: new-window instance should be created');

    // Total = 2 (old + new).
    List<Workflow_Instance__c> all = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c LIKE :PREFIX + '5_%'
    ];
    System.assertEquals(2, all.size(), 'Overlap=Allow: both the prior and new instances should exist');
  }

  // ── AC1 / AC8: Disabled schedule does not fire ───────────────────────────

  @isTest
  static void testDisabledNoFire() {
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Schedule__c sched = makeSchedule(PREFIX + '6', EVERY_MINUTE_CRON, false, 'Allow');
    insert sched;

    WorkflowScheduleSweeper.sweep();

    List<Workflow_Instance__c> instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c LIKE :PREFIX + '6_%'
    ];
    System.assertEquals(0, instances.size(), 'Disabled schedule should not fire');
  }

  // ── AC6: 0-slot invariant — enabling N schedules adds 0 CronTrigger rows ─

  @isTest
  static void testZeroSlotInvariant() {
    WorkflowEngine.disableQueueableInTest = true;

    Integer beforeCount = [SELECT COUNT() FROM CronTrigger];

    List<Workflow_Schedule__c> schedules = new List<Workflow_Schedule__c>();
    for (Integer i = 0; i < 5; i++) {
      schedules.add(makeSchedule(PREFIX + 'ZS' + i, EVERY_MINUTE_CRON, true, 'Allow'));
    }
    insert schedules;

    WorkflowScheduleSweeper.sweep();

    Integer afterCount = [SELECT COUNT() FROM CronTrigger];
    System.assertEquals(
      beforeCount,
      afterCount,
      '0-slot: enabling N schedules must add 0 CronTrigger rows'
    );

    // Also verify instances were actually created (sweep ran).
    List<Workflow_Instance__c> instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c LIKE :PREFIX + 'ZS%'
    ];
    System.assertEquals(5, instances.size(), '0-slot: all 5 schedules should have fired');
  }

  // ── Log idempotency: repeat sweep does not duplicate Workflow_Log__c ─────

  @isTest
  static void testLogIdempotency() {
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Schedule__c sched = makeSchedule(PREFIX + '7', EVERY_MINUTE_CRON, true, 'Allow');
    insert sched;

    // First sweep.
    WorkflowScheduleSweeper.sweep();
    // Manually reset Last_Fired_Window__c so second sweep also fires.
    sched = [SELECT Id, Last_Fired_Window__c FROM Workflow_Schedule__c WHERE Id = :sched.Id];
    sched.Last_Fired_Window__c = null;
    update sched;

    // Second sweep (same fire key → upsert should not duplicate).
    WorkflowScheduleSweeper.sweep();

    List<Workflow_Log__c> logs = [
      SELECT Id
      FROM Workflow_Log__c
      WHERE Schedule_Name__c = :(PREFIX + '7') AND Outcome__c = 'Started'
    ];
    System.assertEquals(1, logs.size(), 'Log upsert: same fire key should not produce duplicate log rows');
  }

  // ── Dedicated-slot helper: converts cron and registers/aborts CronTrigger ─

  @isTest
  static void testDedicatedSlotHelper() {
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Schedule__c sched = makeSchedule(PREFIX + '8', '0 2 * * *', true, 'Allow');
    sched.Dedicated_Slot__c = true;
    insert sched;

    Integer before = [SELECT COUNT() FROM CronTrigger];

    Test.startTest();
    WorkflowScheduleSweeper.registerDedicatedJob(sched.Id);
    Test.stopTest();

    Integer afterRegister = [SELECT COUNT() FROM CronTrigger];
    System.assertEquals(before + 1, afterRegister, 'registerDedicatedJob should add 1 CronTrigger');

    // Dedicated schedule must NOT be swept by the 0-slot sweeper.
    WorkflowScheduleSweeper.sweep();
    List<Workflow_Instance__c> instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c LIKE :PREFIX + '8_%'
    ];
    System.assertEquals(0, instances.size(), 'Dedicated-slot schedule should not be swept by 0-slot sweeper');

    // Jobs are keyed by the immutable schedule Id (not the mutable Name).
    String dedJobName = WorkflowScheduleSweeper.dedicatedJobName(sched.Id);
    System.assertEquals(
      1,
      [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :dedJobName],
      'registerDedicatedJob should arm a CronTrigger named by schedule Id'
    );
    System.assert(
      WorkflowScheduleSweeper.isDedicatedJobArmed(sched.Id),
      'isDedicatedJobArmed should report the armed job'
    );

    // Unregister by Id removes it even though it was never named by Name.
    WorkflowScheduleSweeper.unregisterDedicatedJob(sched.Id);
    Integer afterAbort = [
      SELECT COUNT()
      FROM CronTrigger
      WHERE CronJobDetail.Name = :dedJobName
    ];
    System.assertEquals(0, afterAbort, 'unregisterDedicatedJob should remove the CronTrigger');
  }

  // ── Dedicated job honours Skip and records state/logs (parity with 0-slot) ─

  @isTest
  static void testDedicatedJobAppliesSkipAndRecordsState() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Schedule__c sched = makeSchedule('DedSkip', '0 2 * * *', true, 'Skip');
    sched.Dedicated_Slot__c = true;
    insert sched;

    // A prior run for this schedule is still active (different window).
    insert new Workflow_Instance__c(
      Workflow_Name__c = TEST_WF,
      Correlation_Key__c = 'DedSkip_197001010000',
      Status__c = 'Running'
    );

    Test.startTest();
    new WorkflowScheduleJob(sched.Id).execute(null);
    Test.stopTest();

    // Skip → no new instance for the current minute window.
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'DedSkip_%'],
      'Dedicated Skip must not start a second concurrent run'
    );
    // State + a Skipped log are recorded (parity with the 0-slot path).
    Workflow_Schedule__c after = [
      SELECT Last_Outcome__c, Last_Fired_Window__c
      FROM Workflow_Schedule__c
      WHERE Id = :sched.Id
    ];
    System.assertEquals('Skipped', after.Last_Outcome__c, 'Dedicated Skip should record Last_Outcome__c');
    System.assertNotEquals(null, after.Last_Fired_Window__c, 'Dedicated fire should record Last_Fired_Window__c');
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Log__c
        WHERE Schedule__c = :sched.Id AND Outcome__c = 'Skipped'
      ],
      'Dedicated Skip should write a Skipped log linked by schedule Id'
    );
  }

  @isTest
  static void testDedicatedJobRecordsStartedState() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Schedule__c sched = makeSchedule('DedState', '0 2 * * *', true, 'Allow');
    sched.Dedicated_Slot__c = true;
    insert sched;

    Test.startTest();
    new WorkflowScheduleJob(sched.Id).execute(null);
    Test.stopTest();

    Workflow_Schedule__c after = [
      SELECT Last_Outcome__c, Last_Fired_Window__c
      FROM Workflow_Schedule__c
      WHERE Id = :sched.Id
    ];
    System.assertEquals('Started', after.Last_Outcome__c, 'Dedicated fire should record Started');
    System.assertNotEquals(null, after.Last_Fired_Window__c, 'Dedicated fire should set Last_Fired_Window__c');
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Log__c
        WHERE Schedule__c = :sched.Id AND Outcome__c = 'Started'
      ],
      'Dedicated fire should write a Started log linked by schedule Id'
    );
  }

  // ── Token values are JSON-escaped (a quote in the name must not break JSON) ─

  @isTest
  static void testTokenSubstitutionEscapesSpecialChars() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Schedule__c sched = new Workflow_Schedule__c(
      Name = 'Quote " and \\ back',
      Workflow_Name__c = TEST_WF,
      Cron_Expression__c = EVERY_MINUTE_CRON,
      Correlation_Key_Prefix__c = 'TokEsc',
      Enabled__c = true,
      Overlap_Policy__c = 'Allow',
      Dedicated_Slot__c = false,
      Input_Json__c = '{"src":"{{scheduleName}}"}'
    );
    insert sched;

    Test.startTest();
    WorkflowScheduleSweeper.sweep();
    Test.stopTest();

    // The fire must succeed (no JSON parse exception aborting the sweep).
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'TokEsc_%'],
      'A schedule name with quotes/backslashes must still produce valid JSON and fire'
    );
  }

  // ── Manual run keys are unique even within the same second ────────────────

  @isTest
  static void testManualRunKeysUnique() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Schedule__c sched = makeSchedule('ManyManual', '0 2 * * *', true, 'Allow');
    insert sched;

    Test.startTest();
    Id i1 = WorkflowScheduleSweeper.runNow(sched.Id);
    Id i2 = WorkflowScheduleSweeper.runNow(sched.Id);
    Test.stopTest();

    System.assertNotEquals(i1, i2, 'Two Run Now calls must produce distinct instances');
    System.assertEquals(
      2,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'ManyManual_manual_%'],
      'Two manual runs in the same second must not collapse into one instance'
    );
  }

  // ── Cursor advances strictly past the handled window (no re-selection) ────

  @isTest
  static void testCursorAdvancesPastHandledWindow() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Schedule__c sched = makeSchedule('CursorAdv', EVERY_MINUTE_CRON, true, 'Allow');
    insert sched;

    Test.startTest();
    WorkflowScheduleSweeper.sweep();
    Test.stopTest();

    Workflow_Schedule__c after = [
      SELECT Last_Fired_Window__c, Next_Fire_Window__c
      FROM Workflow_Schedule__c
      WHERE Id = :sched.Id
    ];
    System.assertNotEquals(null, after.Next_Fire_Window__c, 'Cursor should be set after a fire');
    System.assert(
      after.Next_Fire_Window__c > after.Last_Fired_Window__c,
      'Next_Fire_Window__c must be strictly after the handled window, not equal to it'
    );
  }

  // ── Overlap Skip is case-insensitive on the prefix ────────────────────────

  @isTest
  static void testOverlapSkipCaseInsensitive() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Schedule__c sched = makeSchedule('CaseJob', EVERY_MINUTE_CRON, true, 'Skip');
    insert sched;

    // Prior active run keyed with a different-case prefix (correlation keys are
    // case-insensitive); Skip must still recognise it as the prior run.
    insert new Workflow_Instance__c(
      Workflow_Name__c = TEST_WF,
      Correlation_Key__c = 'casejob_197001010000',
      Status__c = 'Running'
    );

    DateTime fireTime = WorkflowCronEvaluator.previousFireTime(EVERY_MINUTE_CRON, DateTime.now());
    String currentKey = 'CaseJob_' + fireTime.formatGmt('yyyyMMddHHmm');

    Test.startTest();
    WorkflowScheduleSweeper.sweep();
    Test.stopTest();

    System.assertEquals(
      0,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c = :currentKey],
      'Skip must treat a different-cased prefix as the same prior run'
    );
  }

  // ── Heartbeat integration: sweep runs inside processWatchdogHeartbeat ─────

  @isTest
  static void testHeartbeatIntegration() {
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Schedule__c sched = makeSchedule(PREFIX + '9', EVERY_MINUTE_CRON, true, 'Allow');
    insert sched;

    Integer cronBefore = [SELECT COUNT() FROM CronTrigger];

    WorkflowEngine.processWatchdogHeartbeat();

    Integer cronAfter = [SELECT COUNT() FROM CronTrigger];
    System.assertEquals(cronBefore, cronAfter, 'Heartbeat: schedule sweep must not add CronTrigger rows');

    List<Workflow_Instance__c> instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c LIKE :PREFIX + '9_%'
    ];
    System.assertEquals(1, instances.size(), 'Heartbeat: schedule should fire through processWatchdogHeartbeat');
  }

  // ── runNow: manual one-off fire independent of cron ──────────────────────

  @isTest
  static void testRunNow() {
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Schedule__c sched = makeSchedule(PREFIX + 'RN', '0 2 * * *', true, 'Allow');
    insert sched;

    Test.startTest();
    Id instanceId = WorkflowScheduleSweeper.runNow(sched.Id);
    Test.stopTest();

    System.assertNotEquals(null, instanceId, 'runNow should return an instance Id');
    List<Workflow_Instance__c> instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c LIKE :PREFIX + 'RN_manual_%'
    ];
    System.assertEquals(1, instances.size(), 'runNow should start exactly one manual instance');

    List<Workflow_Log__c> logs = [
      SELECT Id
      FROM Workflow_Log__c
      WHERE Schedule_Name__c = :(PREFIX + 'RN') AND Log_Type__c = 'ScheduleManualFire'
    ];
    System.assertEquals(1, logs.size(), 'runNow should write a ScheduleManualFire log');
  }

  // ── Token substitution in Input_Json__c ──────────────────────────────────

  @isTest
  static void testTokenSubstitution() {
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Schedule__c sched = new Workflow_Schedule__c(
      Name = PREFIX + 'Token',
      Workflow_Name__c = TEST_WF,
      Cron_Expression__c = EVERY_MINUTE_CRON,
      Correlation_Key_Prefix__c = PREFIX + 'Token',
      Enabled__c = true,
      Overlap_Policy__c = 'Allow',
      Dedicated_Slot__c = false,
      Input_Json__c = '{"scheduledAt":"{{fireTime}}","src":"{{scheduleName}}"}'
    );
    insert sched;

    WorkflowScheduleSweeper.sweep();

    List<Workflow_Instance__c> instances = [
      SELECT Input__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c LIKE :PREFIX + 'Token_%'
    ];
    System.assertEquals(1, instances.size(), 'Token test: one instance should be created');
    System.assertNotEquals(null, instances[0].Input__c, 'Input should not be null');
    System.assert(
      !instances[0].Input__c.contains('{{fireTime}}'),
      'Token {{fireTime}} should have been substituted'
    );
    System.assert(
      !instances[0].Input__c.contains('{{scheduleName}}'),
      'Token {{scheduleName}} should have been substituted'
    );
  }

  // ── Fairness: least-recently-fired first, no starvation past the batch limit ─

  @isTest
  static void testNoStarvationOrdering() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowScheduleSweeper.SWEEP_BATCH_SIZE = 2;

    Workflow_Schedule__c a = makeSchedule('StarveA', EVERY_MINUTE_CRON, true, 'Allow');
    Workflow_Schedule__c b = makeSchedule('StarveB', EVERY_MINUTE_CRON, true, 'Allow');
    Workflow_Schedule__c c = makeSchedule('StarveC', EVERY_MINUTE_CRON, true, 'Allow');
    // A and B never fired (null window) → highest priority; C fired long ago.
    c.Last_Fired_Window__c = DateTime.now().addHours(-2);
    insert new List<Workflow_Schedule__c>{ a, b, c };

    Test.startTest();
    WorkflowScheduleSweeper.sweep();
    Test.stopTest();

    System.assertEquals(
      1,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'StarveA_%'],
      'Never-fired A should be processed first'
    );
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'StarveB_%'],
      'Never-fired B should be processed first'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'StarveC_%'],
      'C is beyond the batch this sweep but will be picked next sweep (oldest window)'
    );
  }

  // ── Overlap Skip must NOT false-positive on a wildcard-overlapping key ────

  @isTest
  static void testOverlapSkipNoFalsePositive() {
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Schedule__c sched = makeSchedule('Job', EVERY_MINUTE_CRON, true, 'Skip');
    insert sched;

    // Active instance for an UNRELATED prefix that the coarse "Job_%" LIKE matches
    // (because "_" is a wildcard) but is not actually this schedule's prior run.
    insert new Workflow_Instance__c(
      Workflow_Name__c = TEST_WF,
      Correlation_Key__c = 'JobManual_197001010000',
      Status__c = 'Running'
    );

    DateTime fireTime = WorkflowCronEvaluator.previousFireTime(EVERY_MINUTE_CRON, DateTime.now());
    String currentKey = 'Job_' + fireTime.formatGmt('yyyyMMddHHmm');

    Test.startTest();
    WorkflowScheduleSweeper.sweep();
    Test.stopTest();

    System.assertEquals(
      1,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c = :currentKey],
      'Unrelated "JobManual" instance must not skip the "Job" schedule'
    );
  }

  // ── toSalesforceCron: DOW remap + DOM/DOW rejection ───────────────────────

  @isTest
  static void testToSalesforceCron_dowRemap() {
    System.assertEquals(
      '0 0 9 ? * 2 *',
      WorkflowScheduleSweeper.toSalesforceCron('0 9 * * 1'),
      'Monday (engine 1) should map to Salesforce 2'
    );
    System.assertEquals(
      '0 0 9 ? * 1 *',
      WorkflowScheduleSweeper.toSalesforceCron('0 9 * * 0'),
      'Sunday (engine 0) should map to Salesforce 1'
    );
    System.assertEquals(
      '0 0 9 ? * 2-6 *',
      WorkflowScheduleSweeper.toSalesforceCron('0 9 * * 1-5'),
      'Weekday range should remap each bound'
    );
    System.assertEquals(
      '0 0 2 * * ? *',
      WorkflowScheduleSweeper.toSalesforceCron('0 2 * * *'),
      'Daily uses ? for day-of-week'
    );
    System.assertEquals(
      '0 0 0 1 * ? *',
      WorkflowScheduleSweeper.toSalesforceCron('0 0 1 * *'),
      'Day-of-month uses ? for day-of-week'
    );
  }

  @isTest
  static void testToSalesforceCron_rejectsDomAndDow() {
    Boolean threw = false;
    try {
      WorkflowScheduleSweeper.toSalesforceCron('0 9 1 * 1');
    } catch (WorkflowScheduleSweeper.WorkflowScheduleException e) {
      threw = true;
    }
    System.assert(threw, 'Restricting both DOM and DOW must be rejected for dedicated mode');
  }

  // ── WorkflowScheduleJob: enabled re-check + token resolution ──────────────

  @isTest
  static void testDedicatedJobFires() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Schedule__c sched = makeSchedule('DedJobOn', '0 2 * * *', true, 'Allow');
    sched.Dedicated_Slot__c = true;
    insert sched;

    Test.startTest();
    new WorkflowScheduleJob(sched.Id).execute(null);
    Test.stopTest();

    System.assertEquals(
      1,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'DedJobOn_%'],
      'Enabled dedicated job should start an instance'
    );
  }

  @isTest
  static void testDedicatedJobNoopWhenDisabled() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Schedule__c sched = makeSchedule('DedJobOff', '0 2 * * *', false, 'Allow');
    sched.Dedicated_Slot__c = true;
    insert sched;

    Test.startTest();
    new WorkflowScheduleJob(sched.Id).execute(null);
    Test.stopTest();

    System.assertEquals(
      0,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'DedJobOff_%'],
      'Disabled dedicated job must be a no-op even if its CronTrigger fires'
    );
  }
}
