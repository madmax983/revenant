/**
 * Processes due Workflow_Schedule__c records as part of the watchdog heartbeat,
 * consuming zero additional scheduled-job slots.
 *
 * Called from WorkflowEngine.processWatchdogHeartbeat() (Sweep 3).
 *
 * Due-detection: for each Enabled, non-dedicated schedule, compute the most-recent
 * fire instant ≤ now via WorkflowCronEvaluator. If Last_Fired_Window__c already
 * equals that instant the window has been handled; otherwise it is due.
 *
 * Overlap policies:
 *   Skip  — if the prior run for this schedule is still active, log Skipped and
 *            do not start a new instance. Still advances Last_Fired_Window__c.
 *   Allow — start a new instance regardless of any in-flight prior run.
 *
 * Correlation key per window: prefix + '_' + fireTime formatted as yyyyMMddHHmm.
 * Re-evaluating the same window produces the same key, so WorkflowEngine's own
 * active-correlation-key uniqueness constraint acts as a safety net against
 * duplicates even if Last_Fired_Window__c state is somehow lost.
 *
 * Input tokens: {{fireTime}} and {{scheduleName}} in Input_Json__c are substituted
 * before JSON deserialization. Static JSON passes through unchanged.
 */
public inherited sharing class WorkflowScheduleSweeper {
  // Max schedules processed per heartbeat to respect governor limits.
  @TestVisible
  private static Integer SWEEP_BATCH_SIZE = 200;

  private static final String LOG_TYPE = 'ScheduleFire';
  private static final String LEVEL_INFO = 'Info';

  // ── Public API ─────────────────────────────────────────────────────────────

  /**
   * Main sweep entry point. Called by WorkflowEngine.processWatchdogHeartbeat().
   */
  public static void sweep() {
    DateTime now = DateTime.now();

    List<Workflow_Schedule__c> schedules = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Cron_Expression__c,
        Input_Json__c,
        Correlation_Key_Prefix__c,
        Overlap_Policy__c,
        Last_Fired_Window__c
      FROM Workflow_Schedule__c
      WHERE Enabled__c = TRUE AND Dedicated_Slot__c = FALSE
      WITH SYSTEM_MODE
      LIMIT :SWEEP_BATCH_SIZE
    ];

    if (schedules.isEmpty()) {
      return;
    }

    List<Workflow_Schedule__c> toUpdate = new List<Workflow_Schedule__c>();
    List<Workflow_Log__c> logsToUpsert = new List<Workflow_Log__c>();

    for (Workflow_Schedule__c sched : schedules) {
      try {
        processSingleSchedule(sched, now, toUpdate, logsToUpsert);
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.ERROR,
          'WorkflowScheduleSweeper: error processing schedule "' +
            sched.Name +
            '": ' +
            ex.getMessage()
        );
      }
    }

    if (!toUpdate.isEmpty()) {
      update as system toUpdate;
    }
    if (!logsToUpsert.isEmpty()) {
      upsert as system logsToUpsert Fire_Key__c;
    }
  }

  /**
   * Arms a dedicated CronTrigger (1 scheduled-job slot) for a Dedicated_Slot__c
   * schedule. The schedule is excluded from the 0-slot sweep while Dedicated_Slot__c
   * is true. Use this for sub-cadence precision.
   */
  public static void registerDedicatedJob(Id scheduleId) {
    Workflow_Schedule__c sched = [
      SELECT Id, Name, Workflow_Name__c, Cron_Expression__c, Correlation_Key_Prefix__c, Input_Json__c
      FROM Workflow_Schedule__c
      WHERE Id = :scheduleId
      WITH SYSTEM_MODE
      LIMIT 1
    ];

    String sfCron = toSalesforceCron(sched.Cron_Expression__c);
    String jobName = 'RevenantSched_' + sched.Name;
    WorkflowScheduler scheduler = new WorkflowScheduler(
      sched.Workflow_Name__c,
      sched.Correlation_Key_Prefix__c,
      sched.Input_Json__c
    );
    System.schedule(jobName, sfCron, scheduler);
  }

  /**
   * Aborts the dedicated CronTrigger registered for this schedule.
   */
  public static void unregisterDedicatedJob(Id scheduleId) {
    Workflow_Schedule__c sched = [
      SELECT Name
      FROM Workflow_Schedule__c
      WHERE Id = :scheduleId
      WITH SYSTEM_MODE
      LIMIT 1
    ];

    String jobName = 'RevenantSched_' + sched.Name;
    List<CronTrigger> triggers = [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name = :jobName
      WITH SYSTEM_MODE
    ];
    for (CronTrigger ct : triggers) {
      System.abortJob(ct.Id);
    }
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  private static void processSingleSchedule(
    Workflow_Schedule__c sched,
    DateTime now,
    List<Workflow_Schedule__c> toUpdate,
    List<Workflow_Log__c> logsToUpsert
  ) {
    DateTime fireTime = WorkflowCronEvaluator.previousFireTime(sched.Cron_Expression__c, now);
    if (fireTime == null) {
      return; // Invalid cron or no match in lookback window.
    }

    // Check if this window has already been handled.
    if (sched.Last_Fired_Window__c != null && sched.Last_Fired_Window__c == fireTime) {
      return; // Not due.
    }

    String prefix = String.isNotBlank(sched.Correlation_Key_Prefix__c)
      ? sched.Correlation_Key_Prefix__c
      : sched.Name;
    String corrKey = prefix + '_' + fireTime.formatGmt('yyyyMMddHHmm');
    String overlapPolicy = String.isNotBlank(sched.Overlap_Policy__c)
      ? sched.Overlap_Policy__c
      : 'Skip';

    String outcome;
    Id instanceId;

    if (overlapPolicy == 'Skip') {
      // Check for any currently active instance with this schedule's prefix.
      List<Workflow_Instance__c> activeRuns = [
        SELECT Id, Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE
          Correlation_Key__c LIKE :prefix + '_%'
          AND Active_Correlation_Key__c != NULL
        WITH SYSTEM_MODE
        LIMIT 1
      ];

      if (!activeRuns.isEmpty() && activeRuns[0].Correlation_Key__c != corrKey) {
        // A different window's instance is still active → skip this window.
        outcome = 'Skipped';
        logsToUpsert.add(buildLog(sched, corrKey, fireTime, outcome, null, 'Prior run still active'));
      } else {
        // No conflicting active run; start (or dedup to existing current window).
        WorkflowEngine.StartResult sr = WorkflowEngine.startOrGet(
          sched.Workflow_Name__c,
          corrKey,
          resolveInput(sched, fireTime)
        );
        instanceId = sr.instanceId;
        outcome = sr.isNew ? 'Started' : 'Deduped';
        if (sr.isNew) {
          logsToUpsert.add(buildLog(sched, corrKey, fireTime, outcome, instanceId, null));
        }
      }
    } else {
      // Allow: start regardless of in-flight runs.
      WorkflowEngine.StartResult sr = WorkflowEngine.startOrGet(
        sched.Workflow_Name__c,
        corrKey,
        resolveInput(sched, fireTime)
      );
      instanceId = sr.instanceId;
      outcome = sr.isNew ? 'Started' : 'Deduped';
      if (sr.isNew) {
        logsToUpsert.add(buildLog(sched, corrKey, fireTime, outcome, instanceId, null));
      }
    }

    // Advance the window marker so this window isn't retried.
    toUpdate.add(
      new Workflow_Schedule__c(
        Id = sched.Id,
        Last_Fired_Window__c = fireTime,
        Last_Outcome__c = outcome
      )
    );
  }

  private static Object resolveInput(Workflow_Schedule__c sched, DateTime fireTime) {
    if (String.isBlank(sched.Input_Json__c)) {
      return null;
    }
    String json = sched.Input_Json__c
      .replace('{{fireTime}}', String.valueOf(fireTime))
      .replace('{{scheduleName}}', sched.Name);
    return JSON.deserializeUntyped(json);
  }

  private static Workflow_Log__c buildLog(
    Workflow_Schedule__c sched,
    String corrKey,
    DateTime fireTime,
    String outcome,
    Id instanceId,
    String message
  ) {
    return new Workflow_Log__c(
      Fire_Key__c = corrKey + ':' + outcome,
      Log_Type__c = LOG_TYPE,
      Level__c = LEVEL_INFO,
      Outcome__c = outcome,
      Schedule_Name__c = sched.Name,
      Workflow_Name__c = sched.Workflow_Name__c,
      Correlation_Key__c = corrKey,
      Fire_Time__c = fireTime,
      Workflow_Instance__c = instanceId,
      Message__c = message
    );
  }

  /**
   * Converts a 5-field cron (min hour dom month dow) to the 7-field Salesforce
   * format required by System.schedule: seconds minutes hours dom month dow year.
   * Seconds default to 0, year defaults to *.
   *
   * Salesforce requires exactly one of dom/dow to be '?'. Rules applied:
   *   - dom is '*' and dow is '*'      → use ? for dom (fire every day)
   *   - dom is specific, dow is '*'    → use ? for dow (dom takes precedence)
   *   - dom is '*', dow is specific    → use ? for dom (dow takes precedence)
   *   - both specific (OR semantics)   → dom takes precedence, dow replaced with ?
   */
  @TestVisible
  static String toSalesforceCron(String fiveFieldCron) {
    List<String> parts = fiveFieldCron.trim().split('\\s+');
    String sfDom = parts[2];
    String sfDow = parts[4];
    if (sfDom == '*') {
      sfDom = '?'; // Defer to dow (or wildcard if dow is * too).
    } else {
      sfDow = '?'; // dom is specific; don't also restrict dow.
    }
    // seconds minutes hours dom month dow year
    return '0 ' + parts[0] + ' ' + parts[1] + ' ' + sfDom + ' ' + parts[3] + ' ' + sfDow + ' *';
  }
}
