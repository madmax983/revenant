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
 * The sweep is bulkified: overlap checks are resolved with a single query and all
 * due starts go through the bulk WorkflowEngine.startOrGet(List) so the per-heartbeat
 * SOQL/DML cost stays bounded regardless of how many schedules are due. Schedules are
 * processed least-recently-fired first so none can starve behind the batch limit.
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
  // Max schedules processed per heartbeat. The sweep is bulkified, but this bounds
  // the up-front cron evaluation and keeps a single heartbeat's footprint small.
  @TestVisible
  private static Integer SWEEP_BATCH_SIZE = 50;

  private static final String LOG_TYPE = 'ScheduleFire';
  private static final String LEVEL_INFO = 'Info';

  public class WorkflowScheduleException extends Exception {
  }

  // Internal holder for a schedule that is due this sweep.
  private class DueItem {
    Workflow_Schedule__c sched;
    DateTime fireTime;
    String prefix;
    String corrKey;
    String overlapPolicy;
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /**
   * Main sweep entry point. Called by WorkflowEngine.processWatchdogHeartbeat().
   */
  public static void sweep() {
    DateTime now = DateTime.now();

    // Only rows that are actually due (or never fired) enter the batch, ordered
    // least-recently-due first. Next_Fire_Window__c is a server-side cursor: a
    // handled low-cadence schedule's next window is in the future, so it filters
    // out and cannot pin the batch and starve higher-cadence schedules.
    List<Workflow_Schedule__c> schedules = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Cron_Expression__c,
        Input_Json__c,
        Correlation_Key_Prefix__c,
        Overlap_Policy__c,
        Last_Fired_Window__c,
        Next_Fire_Window__c
      FROM Workflow_Schedule__c
      WHERE
        Enabled__c = TRUE
        AND Dedicated_Slot__c = FALSE
        AND (Next_Fire_Window__c = NULL OR Next_Fire_Window__c <= :now)
      WITH SYSTEM_MODE
      ORDER BY Next_Fire_Window__c ASC NULLS FIRST, Name ASC
      LIMIT :SWEEP_BATCH_SIZE
    ];

    if (schedules.isEmpty()) {
      return;
    }

    List<Workflow_Schedule__c> toUpdate = new List<Workflow_Schedule__c>();
    List<Workflow_Log__c> logsToUpsert = new List<Workflow_Log__c>();

    // Phase 1: determine which schedules are due (cheap, no per-row SOQL/DML).
    List<DueItem> dueItems = new List<DueItem>();
    for (Workflow_Schedule__c sched : schedules) {
      try {
        DateTime fireTime = WorkflowCronEvaluator.previousFireTime(
          sched.Cron_Expression__c,
          now
        );
        if (fireTime == null) {
          continue; // invalid cron or no match in lookback window
        }
        if (
          sched.Last_Fired_Window__c != null &&
          sched.Last_Fired_Window__c == fireTime
        ) {
          // Window already handled. Backfill the cursor if it's missing so this row
          // rotates out of future batches instead of being re-selected every sweep.
          if (sched.Next_Fire_Window__c == null) {
            toUpdate.add(
              new Workflow_Schedule__c(
                Id = sched.Id,
                Next_Fire_Window__c = nextWindow(sched.Cron_Expression__c, fireTime)
              )
            );
          }
          continue;
        }
        DueItem item = new DueItem();
        item.sched = sched;
        item.fireTime = fireTime;
        item.prefix = effectivePrefix(sched);
        item.corrKey = item.prefix + '_' + fireTime.formatGmt('yyyyMMddHHmm');
        item.overlapPolicy = String.isNotBlank(sched.Overlap_Policy__c)
          ? sched.Overlap_Policy__c
          : 'Skip';
        dueItems.add(item);
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.ERROR,
          'WorkflowScheduleSweeper: error evaluating "' +
            sched.Name +
            '": ' +
            ex.getMessage()
        );
      }
    }

    if (dueItems.isEmpty()) {
      // Nothing to fire, but flush any cursor backfills queued above.
      if (!toUpdate.isEmpty()) {
        update as system toUpdate;
      }
      return;
    }

    // Phase 2: bulk-resolve which Skip schedules are blocked by an active prior run.
    Set<String> blockedPrefixes = computeBlockedPrefixes(dueItems);

    // Phase 3: build a single bulk start for everything that should start.
    List<WorkflowEngine.StartRequest> requests = new List<WorkflowEngine.StartRequest>();
    List<DueItem> starting = new List<DueItem>();
    for (DueItem item : dueItems) {
      if (item.overlapPolicy == 'Skip' && blockedPrefixes.contains(item.prefix)) {
        logsToUpsert.add(
          buildLog(
            item.sched,
            item.corrKey,
            item.fireTime,
            'Skipped',
            null,
            'Prior run still active'
          )
        );
        toUpdate.add(
          new Workflow_Schedule__c(
            Id = item.sched.Id,
            Last_Fired_Window__c = item.fireTime,
            Last_Outcome__c = 'Skipped',
            Next_Fire_Window__c = nextWindow(
              item.sched.Cron_Expression__c,
              item.fireTime
            )
          )
        );
      } else {
        requests.add(
          new WorkflowEngine.StartRequest(
            item.sched.Workflow_Name__c,
            item.corrKey,
            resolveInput(item.sched, item.fireTime)
          )
        );
        starting.add(item);
      }
    }

    if (!requests.isEmpty()) {
      List<WorkflowEngine.StartResult> results = WorkflowEngine.startOrGet(
        requests
      );
      for (Integer i = 0; i < starting.size(); i++) {
        DueItem item = starting[i];
        WorkflowEngine.StartResult sr = results[i];
        Boolean isNew = sr != null && sr.isNew;
        String outcome = isNew ? 'Started' : 'Deduped';
        if (isNew) {
          logsToUpsert.add(
            buildLog(
              item.sched,
              item.corrKey,
              item.fireTime,
              outcome,
              sr.instanceId,
              null
            )
          );
        }
        toUpdate.add(
          new Workflow_Schedule__c(
            Id = item.sched.Id,
            Last_Fired_Window__c = item.fireTime,
            Last_Outcome__c = outcome,
            Next_Fire_Window__c = nextWindow(
              item.sched.Cron_Expression__c,
              item.fireTime
            )
          )
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
   * schedule via the schedule-aware WorkflowScheduleJob, which re-reads the record
   * at fire time (so disabling the schedule stops it) and resolves input tokens.
   *
   * NOTE: System.schedule interprets the cron in the ARMING USER'S time zone, unlike
   * the UTC 0-slot path — see docs/recurring-schedules.md.
   */
  public static void registerDedicatedJob(Id scheduleId) {
    Workflow_Schedule__c sched = [
      SELECT Id, Name, Cron_Expression__c
      FROM Workflow_Schedule__c
      WHERE Id = :scheduleId
      WITH SYSTEM_MODE
      LIMIT 1
    ];

    String sfCron = toSalesforceCron(sched.Cron_Expression__c);
    // Keyed by the immutable schedule Id (not the mutable Name) so a later rename
    // can't orphan the CronTrigger from disable/delete/unregister/re-arm.
    System.schedule(dedicatedJobName(sched.Id), sfCron, new WorkflowScheduleJob(sched.Id));
  }

  /** Stable CronTrigger/job name for a dedicated schedule, derived from its Id. */
  public static String dedicatedJobName(Id scheduleId) {
    return 'RevenantSched_' + scheduleId;
  }

  /**
   * Fires a schedule immediately, on demand, independent of its cron cadence.
   * Uses a distinct manual correlation key so it never collides with a cron
   * window. Records a Started log and returns the started instance Id.
   */
  public static Id runNow(Id scheduleId) {
    Workflow_Schedule__c sched = [
      SELECT Id, Name, Workflow_Name__c, Correlation_Key_Prefix__c, Input_Json__c
      FROM Workflow_Schedule__c
      WHERE Id = :scheduleId
      WITH SYSTEM_MODE
      LIMIT 1
    ];

    DateTime now = DateTime.now();
    // Manual runs are meant to be independent, so the key carries millisecond +
    // random entropy: two Run Now clicks in the same second must not collapse into
    // one instance via the engine's active-correlation-key dedup.
    String corrKey =
      effectivePrefix(sched) +
      '_manual_' +
      String.valueOf(now.getTime()) +
      '_' +
      String.valueOf(Crypto.getRandomInteger()).replace('-', '');

    WorkflowEngine.StartResult sr = WorkflowEngine.startOrGet(
      sched.Workflow_Name__c,
      corrKey,
      resolveInput(sched, now)
    );

    Workflow_Log__c log = buildLog(
      sched,
      corrKey,
      now,
      'Started',
      sr.instanceId,
      'Manual run'
    );
    log.Log_Type__c = 'ScheduleManualFire';
    upsert as system log Fire_Key__c;

    return sr.instanceId;
  }

  /**
   * Aborts the dedicated CronTrigger registered for this schedule.
   */
  public static void unregisterDedicatedJob(Id scheduleId) {
    String jobName = dedicatedJobName(scheduleId);
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

  /** Whether a dedicated CronTrigger is currently armed for this schedule. */
  public static Boolean isDedicatedJobArmed(Id scheduleId) {
    String jobName = dedicatedJobName(scheduleId);
    return ![
        SELECT Id
        FROM CronTrigger
        WHERE CronJobDetail.Name = :jobName
        WITH SYSTEM_MODE
        LIMIT 1
      ]
      .isEmpty();
  }

  // ── Shared helpers (also used by WorkflowScheduleJob) ───────────────────────

  public static String effectivePrefix(Workflow_Schedule__c sched) {
    return String.isNotBlank(sched.Correlation_Key_Prefix__c)
      ? sched.Correlation_Key_Prefix__c
      : sched.Name;
  }

  /**
   * Resolves a schedule's Input_Json__c into a workflow input, substituting the
   * {{fireTime}} and {{scheduleName}} tokens. Returns null when no input is set.
   * Shared by the 0-slot sweep, run-now, and the dedicated WorkflowScheduleJob so
   * the three paths cannot drift.
   */
  public static Object resolveInput(Workflow_Schedule__c sched, DateTime fireTime) {
    if (String.isBlank(sched.Input_Json__c)) {
      return null;
    }
    // Token values are JSON-escaped before substitution so a schedule name (or
    // any future token value) containing a quote or backslash can't produce
    // invalid JSON and abort the sweep when JSON.deserializeUntyped runs.
    String jsonStr = sched.Input_Json__c.replace(
        '{{fireTime}}',
        jsonEscape(String.valueOf(fireTime))
      )
      .replace('{{scheduleName}}', jsonEscape(sched.Name));
    return JSON.deserializeUntyped(jsonStr);
  }

  /**
   * Returns the JSON-escaped body of a string WITHOUT the surrounding quotes, so
   * it can be substituted into a quoted token position ("{{scheduleName}}").
   */
  private static String jsonEscape(String raw) {
    if (raw == null) {
      return '';
    }
    String serialized = JSON.serialize(raw); // quoted + fully escaped
    return serialized.substring(1, serialized.length() - 1);
  }

  /**
   * Fires a single schedule applying its overlap policy, recording the outcome in
   * Last_Fired_Window__c / Last_Outcome__c and a Workflow_Log__c row. Shared by the
   * dedicated-slot WorkflowScheduleJob so dedicated fires honour Skip and keep the
   * same state/audit trail as the 0-slot sweep.
   */
  public static void fireScheduled(
    Workflow_Schedule__c sched,
    DateTime fireTime,
    String corrKey,
    String logType
  ) {
    String overlap = String.isNotBlank(sched.Overlap_Policy__c)
      ? sched.Overlap_Policy__c
      : 'Skip';
    String prefix = effectivePrefix(sched);

    if (overlap == 'Skip' && hasActivePriorRun(prefix, corrKey)) {
      Workflow_Log__c skipLog = buildLog(
        sched,
        corrKey,
        fireTime,
        'Skipped',
        null,
        'Prior run still active'
      );
      skipLog.Log_Type__c = logType;
      upsert as system skipLog Fire_Key__c;
      updateState(sched.Id, fireTime, 'Skipped', sched.Cron_Expression__c);
      return;
    }

    WorkflowEngine.StartResult sr = WorkflowEngine.startOrGet(
      sched.Workflow_Name__c,
      corrKey,
      resolveInput(sched, fireTime)
    );
    Boolean isNew = sr != null && sr.isNew;
    String outcome = isNew ? 'Started' : 'Deduped';
    if (isNew) {
      Workflow_Log__c log = buildLog(
        sched,
        corrKey,
        fireTime,
        outcome,
        sr.instanceId,
        null
      );
      log.Log_Type__c = logType;
      upsert as system log Fire_Key__c;
    }
    updateState(sched.Id, fireTime, outcome, sched.Cron_Expression__c);
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /**
   * For all Skip-policy due items, returns the set of prefixes that currently have
   * an ACTIVE instance from a DIFFERENT window (i.e. a prior run still in flight).
   *
   * Uses a single dynamic query (coarse LIKE per prefix) and then an EXACT
   * `startsWith(prefix + '_')` filter in Apex, so an unrelated key such as
   * "JobManual_..." can never falsely block the "Job" schedule, and admin-entered
   * `%`/`_` wildcards in a prefix cannot widen the match.
   */
  private static Set<String> computeBlockedPrefixes(List<DueItem> dueItems) {
    Map<String, DueItem> skipByPrefix = new Map<String, DueItem>();
    for (DueItem item : dueItems) {
      if (item.overlapPolicy == 'Skip') {
        skipByPrefix.put(item.prefix, item);
      }
    }

    Set<String> blocked = new Set<String>();
    if (skipByPrefix.isEmpty()) {
      return blocked;
    }

    Map<String, Object> binds = new Map<String, Object>();
    List<String> ors = new List<String>();
    Integer i = 0;
    for (String prefix : skipByPrefix.keySet()) {
      String key = 'p' + i;
      // Coarse pre-filter only; the exact startsWith below guarantees correctness.
      binds.put(key, prefix + '_%');
      ors.add('Correlation_Key__c LIKE :' + key);
      i++;
    }

    String soql =
      'SELECT Correlation_Key__c FROM Workflow_Instance__c ' +
      'WHERE Active_Correlation_Key__c != null AND (' +
      String.join(ors, ' OR ') +
      ')';

    List<Workflow_Instance__c> active = Database.queryWithBinds(
      soql,
      binds,
      AccessLevel.SYSTEM_MODE
    );

    for (Workflow_Instance__c inst : active) {
      if (inst.Correlation_Key__c == null) {
        continue;
      }
      // Prefixes/keys are case-insensitive (the prefix field is caseSensitive=false
      // and SOQL LIKE ignores case), so compare lowercased — an admin re-casing a
      // prefix must still recognise an in-flight prior run under Skip.
      String lcKey = inst.Correlation_Key__c.toLowerCase();
      for (DueItem item : skipByPrefix.values()) {
        if (
          lcKey.startsWith(item.prefix.toLowerCase() + '_') &&
          inst.Correlation_Key__c != item.corrKey
        ) {
          blocked.add(item.prefix);
        }
      }
    }
    return blocked;
  }

  /**
   * Single-schedule overlap check (case-insensitive): is there an ACTIVE instance
   * whose correlation key shares this prefix but is from a different window?
   */
  private static Boolean hasActivePriorRun(String prefix, String currentCorrKey) {
    String likePattern = prefix + '_%';
    List<Workflow_Instance__c> active = [
      SELECT Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        Active_Correlation_Key__c != NULL
        AND Correlation_Key__c LIKE :likePattern
      WITH SYSTEM_MODE
    ];
    String lcPrefix = prefix.toLowerCase();
    for (Workflow_Instance__c inst : active) {
      if (inst.Correlation_Key__c == null) {
        continue;
      }
      if (
        inst.Correlation_Key__c.toLowerCase().startsWith(lcPrefix + '_') &&
        inst.Correlation_Key__c != currentCorrKey
      ) {
        return true;
      }
    }
    return false;
  }

  /** Advances a schedule's last/next window state after a fire. Single-row DML. */
  private static void updateState(
    Id scheduleId,
    DateTime firedWindow,
    String outcome,
    String cron
  ) {
    update as system new Workflow_Schedule__c(
      Id = scheduleId,
      Last_Fired_Window__c = firedWindow,
      Last_Outcome__c = outcome,
      Next_Fire_Window__c = nextWindow(cron, firedWindow)
    );
  }

  /** Next fire instant strictly after the handled window, or null if unknown. */
  private static DateTime nextWindow(String cron, DateTime firedWindow) {
    if (String.isBlank(cron)) {
      return null;
    }
    try {
      return WorkflowCronEvaluator.nextFireTime(cron, firedWindow);
    } catch (Exception e) {
      return null;
    }
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
      Schedule__c = sched.Id,
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
   *
   * Two Salesforce-specific translations are applied:
   *   - Day-of-week is remapped from this engine's 0–6 (0=Sun) to Salesforce's
   *     1–7 (1=Sun…7=Sat), preserving lists/ranges/steps.
   *   - Salesforce requires exactly one of dom/dow to be '?'. Because Salesforce
   *     cron has no DOM-OR-DOW semantics, a cron that restricts BOTH is rejected
   *     for dedicated mode (the 0-slot evaluator still supports it).
   */
  @TestVisible
  static String toSalesforceCron(String fiveFieldCron) {
    List<String> parts = fiveFieldCron.trim().split('\\s+');
    String minute = parts[0];
    String hour = parts[1];
    String dom = parts[2];
    String month = parts[3];
    String dow = parts[4];

    Boolean domRestricted = dom != '*';
    Boolean dowRestricted = dow != '*';

    if (domRestricted && dowRestricted) {
      throw new WorkflowScheduleException(
        'Dedicated-slot mode cannot schedule a cron that restricts BOTH day-of-month ' +
          'and day-of-week (Salesforce cron has no OR semantics). Use 0-slot mode ' +
          'for "' +
          fiveFieldCron +
          '".'
      );
    }

    String sfDom;
    String sfDow;
    if (dowRestricted) {
      sfDom = '?';
      sfDow = mapDowField(dow);
    } else {
      sfDom = dom; // '*' or a specific day-of-month
      sfDow = '?';
    }

    return '0 ' +
      minute +
      ' ' +
      hour +
      ' ' +
      sfDom +
      ' ' +
      month +
      ' ' +
      sfDow +
      ' *';
  }

  // Remaps a (restricted) day-of-week field from 0–6 (0=Sun) to Salesforce 1–7.
  private static String mapDowField(String dowField) {
    List<String> outParts = new List<String>();
    for (String part : dowField.split(',')) {
      outParts.add(mapDowPart(part.trim()));
    }
    return String.join(outParts, ',');
  }

  private static String mapDowPart(String part) {
    if (part.contains('/')) {
      List<String> sp = part.split('/');
      return mapDowRange(sp[0]) + '/' + sp[1];
    }
    return mapDowRange(part);
  }

  private static String mapDowRange(String token) {
    if (token == '*') {
      return '*';
    }
    if (token.contains('-')) {
      List<String> b = token.split('-');
      return shiftDow(b[0]) + '-' + shiftDow(b[1]);
    }
    return shiftDow(token);
  }

  private static String shiftDow(String value) {
    return String.valueOf(Integer.valueOf(value.trim()) + 1);
  }
}
