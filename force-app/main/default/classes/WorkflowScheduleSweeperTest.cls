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

    // Verify the 0-slot sweep ignores dedicated schedules BEFORE registering the
    // dedicated job (so Test.stopTest cannot fire the job and create an instance
    // that would be counted here).
    WorkflowScheduleSweeper.sweep();
    List<Workflow_Instance__c> instancesBefore = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c LIKE :PREFIX + '8_%'
    ];
    System.assertEquals(
      0,
      instancesBefore.size(),
      'Dedicated-slot schedule should not be swept by 0-slot sweeper'
    );

    Integer before = [SELECT COUNT() FROM CronTrigger];

    Test.startTest();
    WorkflowScheduleSweeper.registerDedicatedJob(sched.Id);
    Test.stopTest();

    Integer afterRegister = [SELECT COUNT() FROM CronTrigger];
    System.assertEquals(before + 1, afterRegister, 'registerDedicatedJob should add 1 CronTrigger');

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
    WorkflowScheduleSweeper.sweepBatchSize = 2;

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

  // ── Impossible cron parks the row out of the batch (no starvation) ─────────

  @isTest
  static void testImpossibleCronParksRow() {
    WorkflowEngine.disableQueueableInTest = true;
    // "0 0 31 2 *" (Feb 31) is syntactically valid but never fires, so
    // previousFireTime returns null after the full lookback walk.
    Workflow_Schedule__c impossible = makeSchedule('Impossible', '0 0 31 2 *', true, 'Allow');
    insert impossible;

    Test.startTest();
    WorkflowScheduleSweeper.sweep();
    Test.stopTest();

    // No instance is created for the impossible cron…
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'Impossible_%'],
      'Impossible cron must not start an instance'
    );
    // …and its cursor is advanced + outcome flagged so it rotates out of the
    // NULLS-FIRST batch instead of being re-selected every heartbeat.
    Workflow_Schedule__c after = [
      SELECT Next_Fire_Window__c, Last_Outcome__c
      FROM Workflow_Schedule__c
      WHERE Id = :impossible.Id
    ];
    System.assertNotEquals(
      null,
      after.Next_Fire_Window__c,
      'Impossible cron should get a parked (non-null) cursor so it rotates out'
    );
    System.assert(
      after.Next_Fire_Window__c > DateTime.now(),
      'Parked cursor should be in the future so the row leaves the batch'
    );
    System.assertEquals(
      'Invalid cron',
      after.Last_Outcome__c,
      'Impossible cron should record an Invalid cron outcome'
    );
  }

  @isTest
  static void testImpossibleCronDoesNotStarveValidSchedule() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowScheduleSweeper.sweepBatchSize = 1;

    // Impossible cron sorts first (null cursor). Without parking, it would pin the
    // batch of 1 forever and a valid schedule would never fire.
    Workflow_Schedule__c bad = makeSchedule('AImpossible', '0 0 31 2 *', true, 'Allow');
    Workflow_Schedule__c good = makeSchedule('BValid', EVERY_MINUTE_CRON, true, 'Allow');
    insert new List<Workflow_Schedule__c>{ bad, good };

    Test.startTest();
    WorkflowScheduleSweeper.sweep(); // parks the impossible row
    WorkflowScheduleSweeper.sweep(); // now the valid row gets the batch slot
    Test.stopTest();

    System.assertEquals(
      1,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'BValid_%'],
      'A valid schedule must not be starved behind a parked impossible cron'
    );
  }

  // ── Bad input JSON on one schedule must not abort the whole sweep batch ────

  @isTest
  static void testBadInputJsonIsolatedFromBatch() {
    WorkflowEngine.disableQueueableInTest = true;

    // A schedule with malformed Input_Json__c (as if created via Setup, bypassing
    // saveSchedule's JSON validation).
    Workflow_Schedule__c bad = new Workflow_Schedule__c(
      Name = 'BadJsonSched',
      Workflow_Name__c = TEST_WF,
      Cron_Expression__c = EVERY_MINUTE_CRON,
      Correlation_Key_Prefix__c = 'BadJsonSched',
      Enabled__c = true,
      Overlap_Policy__c = 'Allow',
      Dedicated_Slot__c = false,
      Input_Json__c = '{not valid json'
    );
    // A healthy, due schedule that must still fire on the same heartbeat.
    Workflow_Schedule__c good = makeSchedule('GoodJsonSched', EVERY_MINUTE_CRON, true, 'Allow');
    insert new List<Workflow_Schedule__c>{ bad, good };

    Test.startTest();
    WorkflowScheduleSweeper.sweep();
    Test.stopTest();

    // The healthy schedule fires despite the malformed sibling in the same batch.
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'GoodJsonSched_%'],
      'A malformed-JSON schedule must not abort unrelated due schedules in the batch'
    );
    // The bad schedule starts nothing but is recorded as an Error and advanced.
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'BadJsonSched_%'],
      'A malformed-JSON schedule must not start an instance'
    );
    Workflow_Schedule__c afterBad = [
      SELECT Last_Outcome__c, Last_Fired_Window__c, Next_Fire_Window__c
      FROM Workflow_Schedule__c
      WHERE Id = :bad.Id
    ];
    System.assertEquals('Error', afterBad.Last_Outcome__c, 'Bad JSON schedule should record an Error outcome');
    System.assertNotEquals(null, afterBad.Last_Fired_Window__c, 'Bad JSON schedule window should be marked handled');
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Log__c
        WHERE Schedule__c = :bad.Id AND Outcome__c = 'Error'
      ],
      'Bad JSON schedule should write an Error log'
    );
  }

  // ── Unknown workflow name records Error instead of a phantom Started ───────

  @isTest
  static void testUnknownWorkflowRecordsError() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Schedule__c bad = makeSchedule('BadWf', EVERY_MINUTE_CRON, true, 'Allow');
    bad.Workflow_Name__c = 'Nope.NotARealWorkflow123';
    insert bad;

    Test.startTest();
    WorkflowScheduleSweeper.sweep();
    Test.stopTest();

    System.assertEquals(
      0,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'BadWf_%'],
      'A typo\'d workflow name must not create a phantom Started instance'
    );
    Workflow_Schedule__c after = [
      SELECT Last_Outcome__c, Last_Fired_Window__c, Next_Fire_Window__c
      FROM Workflow_Schedule__c
      WHERE Id = :bad.Id
    ];
    System.assertEquals('Error', after.Last_Outcome__c, 'Unknown workflow should record an Error outcome');
    System.assertNotEquals(null, after.Last_Fired_Window__c, 'Window should be marked handled');
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Log__c
        WHERE Schedule__c = :bad.Id AND Outcome__c = 'Error'
      ],
      'Unknown workflow should write an Error log'
    );
  }

  // ── Dedicated job: fire window comes from the cron, not the execution minute ─

  @isTest
  static void testDedicatedJobUsesCronWindow() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Schedule__c sched = makeSchedule('DedWindow', '0 2 * * *', true, 'Allow');
    sched.Dedicated_Slot__c = true;
    insert sched;

    // The fire key must reflect the scheduled 02:00 window, regardless of when the
    // test (or Salesforce) actually runs the job.
    DateTime expected = WorkflowCronEvaluator.previousFireTime('0 2 * * *', DateTime.now());
    String expectedKey = 'DedWindow_' + expected.formatGmt('yyyyMMddHHmm');

    Test.startTest();
    new WorkflowScheduleJob(sched.Id).execute(null);
    Test.stopTest();

    System.assertEquals(
      1,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c = :expectedKey],
      'Dedicated fire must key on the cron window, not the raw execution minute'
    );
  }

  // ── Dedicated job: bad input JSON records Error instead of failing every tick ─

  @isTest
  static void testDedicatedJobBadJsonRecordsError() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Schedule__c sched = new Workflow_Schedule__c(
      Name = 'DedBadJson',
      Workflow_Name__c = TEST_WF,
      Cron_Expression__c = '0 2 * * *',
      Correlation_Key_Prefix__c = 'DedBadJson',
      Enabled__c = true,
      Overlap_Policy__c = 'Allow',
      Dedicated_Slot__c = true,
      Input_Json__c = '{not valid json'
    );
    insert sched;

    Test.startTest();
    new WorkflowScheduleJob(sched.Id).execute(null);
    Test.stopTest();

    System.assertEquals(
      0,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'DedBadJson_%'],
      'Dedicated malformed JSON must not start an instance'
    );
    Workflow_Schedule__c after = [
      SELECT Last_Outcome__c
      FROM Workflow_Schedule__c
      WHERE Id = :sched.Id
    ];
    System.assertEquals(
      'Error',
      after.Last_Outcome__c,
      'Dedicated malformed JSON should record an Error outcome (not throw and leave stale state)'
    );
  }

  // ── Dedicated job self-aborts when its schedule row is gone ────────────────

  @isTest
  static void testDedicatedJobSelfAbortsWhenScheduleDeleted() {
    Workflow_Schedule__c sched = makeSchedule('DedGone', '0 2 * * *', true, 'Allow');
    sched.Dedicated_Slot__c = true;
    insert sched;
    String jobName = WorkflowScheduleSweeper.dedicatedJobName(sched.Id);

    Test.startTest();
    WorkflowScheduleSweeper.registerDedicatedJob(sched.Id);
    // Delete the row OUTSIDE deleteSchedule, leaving the CronTrigger orphaned.
    delete sched;
    // stopTest runs the scheduled job with a real SchedulableContext; with no row
    // left it must self-abort.
    Test.stopTest();

    System.assertEquals(
      0,
      [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :jobName],
      'A dedicated job whose schedule row is gone must self-abort its CronTrigger'
    );
  }

  @isTest
  static void testDedicatedJobSelfAbortsWhenDisabledOutOfBand() {
    Workflow_Schedule__c sched = makeSchedule('DedDisabledAbort', '0 2 * * *', true, 'Allow');
    sched.Dedicated_Slot__c = true;
    insert sched;
    String jobName = WorkflowScheduleSweeper.dedicatedJobName(sched.Id);

    Test.startTest();
    WorkflowScheduleSweeper.registerDedicatedJob(sched.Id);
    // Disable OUTSIDE the controller (raw update) so the CronTrigger is left armed.
    sched.Enabled__c = false;
    update sched;
    // stopTest runs the job with a real context; it must self-abort when ineligible.
    Test.stopTest();

    System.assertEquals(
      0,
      [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :jobName],
      'A dedicated job disabled out-of-band must self-abort its CronTrigger'
    );
  }

  // ── Direct (Setup/API) inserts must not fire a pre-creation window ─────────

  @isTest
  static void testDirectInsertSkipsPreCreationWindow() {
    WorkflowEngine.disableQueueableInTest = true;
    // A yearly cron (Jan 1 00:00) whose most-recent window is up to ~365 days in
    // the past — comfortably inside the evaluator's ~4-year lookback. A low-cadence
    // cron lets us model a realistic direct insert (a record created mid-period
    // whose previous window predates it) WITHOUT shoving CreatedDate into the
    // future. A future CreatedDate is itself an illegal state to update: the
    // platform stamps LastModifiedDate = now, which would precede CreatedDate and
    // throw FIELD_INTEGRITY_EXCEPTION when sweep() flushes the cursor seed.
    Workflow_Schedule__c sched = makeSchedule('PreCreate', '0 0 1 1 *', true, 'Allow');
    insert sched;
    // Created a minute ago: in the PAST (so the cursor-seed update is legal), yet
    // its most-recent fire window (last Jan 1) still predates the creation minute.
    Test.setCreatedDate(sched.Id, DateTime.now().addMinutes(-1));

    Test.startTest();
    WorkflowScheduleSweeper.sweep();
    Test.stopTest();

    System.assertEquals(
      0,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'PreCreate_%'],
      'A window before the record creation minute must not fire'
    );
    Workflow_Schedule__c after = [
      SELECT Next_Fire_Window__c
      FROM Workflow_Schedule__c
      WHERE Id = :sched.Id
    ];
    System.assertNotEquals(
      null,
      after.Next_Fire_Window__c,
      'A skipped pre-creation window should seed the cursor to a future window'
    );
  }

  // ── runNow validates the workflow definition ──────────────────────────────

  @isTest
  static void testRunNowRejectsUnknownWorkflow() {
    Workflow_Schedule__c sched = makeSchedule('RNBad', '0 2 * * *', true, 'Allow');
    sched.Workflow_Name__c = 'Nope.NotARealWorkflow123';
    insert sched;

    Boolean threw = false;
    Test.startTest();
    try {
      WorkflowScheduleSweeper.runNow(sched.Id);
    } catch (Exception e) {
      threw = true;
    }
    Test.stopTest();

    System.assert(threw, 'runNow must reject a schedule pointing at an unknown workflow definition');
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Correlation_Key__c LIKE 'RNBad_manual_%'],
      'No manual instance should be created for an unknown workflow'
    );
  }
}
