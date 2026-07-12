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
  private static Integer sweepBatchSize = 50;

  private static final String LOG_TYPE = 'ScheduleFire';
  private static final String LEVEL_INFO = 'Info';

  /**
   * @description Thrown for schedule-management errors, such as a cron that
   * cannot be expressed in Salesforce's dedicated-slot format or a fire targeting
   * an unknown workflow definition.
   */
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

  /**
   * Bundles the identity of a single dedicated-slot fire (the schedule, the window
   * instant, the correlation key for that window, and the log type). Grouped into a
   * value object so the shared fire path takes a single argument rather than a long
   * parameter list. Public so WorkflowScheduleJob can populate it.
   */
  public class FireContext {
    public Workflow_Schedule__c sched;
    public DateTime fireTime;
    public String corrKey;
    public String logType;
  }

  // Mutable working set threaded through the 0-slot sweep helpers so each stage can
  // append to the shared update/log/start buffers without long parameter lists.
  private class SweepState {
    DateTime now;
    List<DueItem> dueItems = new List<DueItem>();
    List<Workflow_Schedule__c> toUpdate = new List<Workflow_Schedule__c>();
    List<Workflow_Log__c> logsToUpsert = new List<Workflow_Log__c>();
    List<WorkflowEngine.StartRequest> requests = new List<WorkflowEngine.StartRequest>();
    List<DueItem> starting = new List<DueItem>();
    Set<String> blockedPrefixes;
  }

  // Assembles the fields of one fire's audit log. Bundled into a single value
  // object so buildLog needs no long parameter list. logType null → LOG_TYPE.
  private class LogSpec {
    Workflow_Schedule__c sched;
    String corrKey;
    DateTime fireTime;
    String logType;
    String outcome;
    Id instanceId;
    String message;

    LogSpec(DueItem item, String outcome) {
      this.sched = item.sched;
      this.corrKey = item.corrKey;
      this.fireTime = item.fireTime;
      this.outcome = outcome;
    }

    LogSpec(FireContext ctx, String outcome) {
      this.sched = ctx.sched;
      this.corrKey = ctx.corrKey;
      this.fireTime = ctx.fireTime;
      this.logType = ctx.logType;
      this.outcome = outcome;
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /**
   * Main sweep entry point. Called by WorkflowEngine.processWatchdogHeartbeat().
   */
  public static void sweep() {
    List<Workflow_Schedule__c> schedules = loadDueSchedules(DateTime.now());
    if (schedules.isEmpty()) {
      return;
    }

    SweepState state = new SweepState();
    state.now = DateTime.now();

    // Phase 1: determine which schedules are due (cheap, no per-row SOQL/DML).
    for (Workflow_Schedule__c sched : schedules) {
      classifyForSweep(sched, state);
    }

    if (state.dueItems.isEmpty()) {
      // Nothing to fire, but flush any cursor backfills queued above.
      flushUpdates(state.toUpdate);
      return;
    }

    // Phase 2: bulk-resolve which Skip schedules are blocked by an active prior run.
    state.blockedPrefixes = computeBlockedPrefixes(state.dueItems);

    // Phase 3: build a single bulk start for everything that should start.
    for (DueItem item : state.dueItems) {
      planDueItem(item, state);
    }

    if (!state.requests.isEmpty()) {
      startAndRecord(state);
    }

    flushUpdates(state.toUpdate);
    if (!state.logsToUpsert.isEmpty()) {
      upsert as system state.logsToUpsert Fire_Key__c;
    }
  }

  /**
   * @description Loads the due (or never-fired) 0-slot schedules for this sweep, ordered
   * least-recently-due first. Next_Fire_Window__c is a server-side cursor: a handled
   * low-cadence schedule's next window is in the future, so it filters out and cannot
   * pin the batch and starve higher-cadence schedules.
   * @param now The evaluation instant used as the due cutoff.
   * @return The batch of enabled, non-dedicated schedules that may be due.
   */
  private static List<Workflow_Schedule__c> loadDueSchedules(DateTime now) {
    return [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Cron_Expression__c,
        Input_Json__c,
        Correlation_Key_Prefix__c,
        Overlap_Policy__c,
        Last_Fired_Window__c,
        Next_Fire_Window__c,
        CreatedDate
      FROM Workflow_Schedule__c
      WHERE
        Enabled__c = TRUE
        AND Dedicated_Slot__c = FALSE
        AND (Next_Fire_Window__c = NULL
        OR Next_Fire_Window__c <= :now)
      WITH SYSTEM_MODE
      ORDER BY Next_Fire_Window__c ASC NULLS FIRST, Name ASC
      LIMIT :sweepBatchSize
    ];
  }

  /**
   * @description Classifies one schedule for the sweep: either queues a cursor-only update
   * (park an impossible cron, backfill a handled window, or seed a never-fired pre-creation
   * window) or appends a DueItem to fire. Per-item exceptions are swallowed so one bad
   * schedule cannot abort the whole heartbeat batch.
   * @param sched The schedule row being classified.
   * @param state The mutable sweep working set accumulating updates and due items.
   */
  private static void classifyForSweep(
    Workflow_Schedule__c sched,
    SweepState state
  ) {
    try {
      DateTime fireTime = WorkflowCronEvaluator.previousFireTime(
        sched.Cron_Expression__c,
        state.now
      );
      if (fireTime == null) {
        // Syntactically valid but impossible cron (e.g. "0 0 31 2 *") never
        // yields a window, so previousFireTime walks the full lookback and
        // returns null. Leaving the cursor null would re-select this row on
        // every heartbeat (NULLS FIRST) and starve real schedules behind the
        // batch limit. Park it a day out with an Invalid outcome so it rotates
        // out; a later edit via saveSchedule resets the cursor to re-arm it.
        state.toUpdate.add(
          new Workflow_Schedule__c(
            Id = sched.Id,
            Next_Fire_Window__c = state.now.addDays(1),
            Last_Outcome__c = 'Invalid cron'
          )
        );
        return;
      }
      if (
        sched.Last_Fired_Window__c != null &&
        sched.Last_Fired_Window__c == fireTime
      ) {
        // Window already handled. Backfill the cursor if it's missing so this row
        // rotates out of future batches instead of being re-selected every sweep.
        if (sched.Next_Fire_Window__c == null) {
          state.toUpdate.add(
            new Workflow_Schedule__c(
              Id = sched.Id,
              Next_Fire_Window__c = nextWindow(
                sched.Cron_Expression__c,
                fireTime
              )
            )
          );
        }
        return;
      }
      if (
        sched.Last_Fired_Window__c == null &&
        fireTime < truncateToMinute(sched.CreatedDate)
      ) {
        // Never-fired schedule whose most-recent window predates the record's
        // creation MINUTE (e.g. an hourly schedule created via Setup at 14:37 — the
        // 14:00 window is before it existed). Compared at minute granularity so an
        // every-minute schedule created mid-minute still fires that same minute's
        // window. UI-created schedules seed the cursor at save, so this only affects
        // direct inserts. Don't fire a pre-creation window; just seed the cursor to
        // the next future window and rotate out.
        state.toUpdate.add(
          new Workflow_Schedule__c(
            Id = sched.Id,
            Next_Fire_Window__c = nextWindow(sched.Cron_Expression__c, fireTime)
          )
        );
        return;
      }
      state.dueItems.add(buildDueItem(sched, fireTime));
    } catch (Exception ignored) {
    }
  }

  /**
   * @description Builds the DueItem (prefix + correlation key + overlap policy) for a fire.
   * @param sched The schedule being fired.
   * @param fireTime The cron window instant this fire corresponds to.
   * @return The assembled DueItem describing the pending fire.
   */
  private static DueItem buildDueItem(
    Workflow_Schedule__c sched,
    DateTime fireTime
  ) {
    DueItem item = new DueItem();
    item.sched = sched;
    item.fireTime = fireTime;
    item.prefix = effectivePrefix(sched);
    item.corrKey = item.prefix + '_' + fireTime.formatGmt('yyyyMMddHHmm');
    item.overlapPolicy = String.isNotBlank(sched.Overlap_Policy__c)
      ? sched.Overlap_Policy__c
      : 'Skip';
    return item;
  }

  /**
   * @description Plans a single due item: records a Skipped log (overlap-blocked) or an
   * Error log (unknown workflow / bad input JSON) and advances the cursor, or otherwise
   * queues a bulk StartRequest. resolveInput is isolated per item so one malformed
   * schedule cannot abort the batch.
   * @param item The due item to plan.
   * @param state The mutable sweep working set collecting logs, updates, and requests.
   */
  private static void planDueItem(DueItem item, SweepState state) {
    if (
      item.overlapPolicy == 'Skip' &&
      state.blockedPrefixes.contains(item.prefix)
    ) {
      LogSpec spec = new LogSpec(item, 'Skipped');
      spec.message = 'Prior run still active';
      state.logsToUpsert.add(buildLog(spec));
      state.toUpdate.add(advanceRow(item, 'Skipped'));
      return;
    }
    // Validate the workflow definition resolves before starting. A schedule created
    // outside the manager with a typo in Workflow_Name__c would otherwise be handed
    // to startOrGet, which builds a Pending instance even when Type.forName can't
    // resolve a class — recording a phantom "Started" that only fails asynchronously.
    if (!isValidWorkflowName(item.sched.Workflow_Name__c)) {
      LogSpec spec = new LogSpec(item, 'Error');
      spec.message =
        'Unknown workflow definition: ' + item.sched.Workflow_Name__c;
      state.logsToUpsert.add(buildLog(spec));
      state.toUpdate.add(advanceRow(item, 'Error'));
      return;
    }
    // resolveInput can throw if Input_Json__c is malformed (a schedule can be
    // created/edited via Setup or Object Manager, bypassing saveSchedule's JSON
    // validation).
    Object resolvedInput;
    try {
      resolvedInput = resolveInput(item.sched, item.fireTime);
    } catch (Exception ex) {
      LogSpec spec = new LogSpec(item, 'Error');
      spec.message = 'Invalid input JSON: ' + ex.getMessage();
      state.logsToUpsert.add(buildLog(spec));
      state.toUpdate.add(advanceRow(item, 'Error'));
      return;
    }
    state.requests.add(
      new WorkflowEngine.StartRequest(
        item.sched.Workflow_Name__c,
        item.corrKey,
        resolvedInput
      )
    );
    state.starting.add(item);
  }

  /**
   * @description Runs the bulk start and records Started/Deduped logs + cursor advances.
   * @param state The sweep working set holding the built requests and starting items.
   */
  private static void startAndRecord(SweepState state) {
    List<WorkflowEngine.StartResult> results = WorkflowEngine.startOrGet(
      state.requests
    );
    for (Integer i = 0; i < state.starting.size(); i++) {
      DueItem item = state.starting[i];
      WorkflowEngine.StartResult sr = results[i];
      Boolean isNew = sr != null && sr.isNew;
      String outcome = isNew ? 'Started' : 'Deduped';
      if (isNew) {
        LogSpec spec = new LogSpec(item, outcome);
        spec.instanceId = sr.instanceId;
        state.logsToUpsert.add(buildLog(spec));
      }
      state.toUpdate.add(advanceRow(item, outcome));
    }
  }

  /**
   * @description Builds the cursor-advancing update row (last/next window + outcome) for a fire.
   * @param item The due item whose schedule cursor is being advanced.
   * @param outcome The outcome label recorded on the schedule (Started, Skipped, etc.).
   * @return An in-memory Workflow_Schedule__c carrying the advanced cursor fields.
   */
  private static Workflow_Schedule__c advanceRow(DueItem item, String outcome) {
    return new Workflow_Schedule__c(
      Id = item.sched.Id,
      Last_Fired_Window__c = item.fireTime,
      Last_Outcome__c = outcome,
      Next_Fire_Window__c = nextWindow(
        item.sched.Cron_Expression__c,
        item.fireTime
      )
    );
  }

  /**
   * @description Single-guarded bulk update for the sweep's queued cursor/state changes.
   * @param toUpdate The schedule rows to persist; a no-op when empty.
   */
  private static void flushUpdates(List<Workflow_Schedule__c> toUpdate) {
    if (!toUpdate.isEmpty()) {
      update as system toUpdate;
    }
  }

  /**
   * @description Arms a dedicated CronTrigger (1 scheduled-job slot) for a Dedicated_Slot__c
   * schedule via the schedule-aware WorkflowScheduleJob, which re-reads the record
   * at fire time (so disabling the schedule stops it) and resolves input tokens.
   *
   * NOTE: System.schedule interprets the cron in the ARMING USER'S time zone, unlike
   * the UTC 0-slot path — see docs/recurring-schedules.md.
   * @param scheduleId The Id of the schedule to arm a dedicated CronTrigger for.
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
    System.schedule(
      dedicatedJobName(sched.Id),
      sfCron,
      new WorkflowScheduleJob(sched.Id)
    );
  }

  /**
   * @description Stable CronTrigger/job name for a dedicated schedule, derived from its Id.
   * @param scheduleId The Id of the schedule.
   * @return The deterministic job name used to arm, find, and abort its CronTrigger.
   */
  public static String dedicatedJobName(Id scheduleId) {
    return 'RevenantSched_' + scheduleId;
  }

  /**
   * @description Fires a schedule immediately, on demand, independent of its cron cadence.
   * Uses a distinct manual correlation key so it never collides with a cron
   * window. Records a Started log and returns the started instance Id.
   * @param scheduleId The Id of the schedule to run now.
   * @return The Id of the started workflow instance.
   */
  public static Id runNow(Id scheduleId) {
    Workflow_Schedule__c sched = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Correlation_Key_Prefix__c,
        Input_Json__c
      FROM Workflow_Schedule__c
      WHERE Id = :scheduleId
      WITH SYSTEM_MODE
      LIMIT 1
    ];

    // Same guard as scheduled fires: a typo'd or removed Workflow_Name__c would
    // otherwise be handed to startOrGet, which builds a phantom Pending instance
    // that this method would report as "Started".
    if (!isValidWorkflowName(sched.Workflow_Name__c)) {
      throw new WorkflowScheduleException(
        'Unknown workflow definition: ' + sched.Workflow_Name__c
      );
    }

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

    FireContext ctx = new FireContext();
    ctx.sched = sched;
    ctx.fireTime = now;
    ctx.corrKey = corrKey;
    ctx.logType = 'ScheduleManualFire';
    LogSpec spec = new LogSpec(ctx, 'Started');
    spec.instanceId = sr.instanceId;
    spec.message = 'Manual run';
    upsert as system buildLog(spec) Fire_Key__c;

    return sr.instanceId;
  }

  /**
   * @description Aborts the dedicated CronTrigger registered for this schedule.
   * @param scheduleId The Id of the schedule whose CronTrigger should be aborted.
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

  /**
   * @description Whether a dedicated CronTrigger is currently armed for this schedule.
   * @param scheduleId The Id of the schedule to check.
   * @return True if a CronTrigger for this schedule exists, false otherwise.
   */
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

  /**
   * @description Returns the correlation-key prefix for a schedule, falling back to
   * the schedule Name when no explicit Correlation_Key_Prefix__c is configured.
   * @param sched The schedule whose effective prefix is needed.
   * @return The configured prefix, or the schedule Name when none is set.
   */
  public static String effectivePrefix(Workflow_Schedule__c sched) {
    return String.isNotBlank(sched.Correlation_Key_Prefix__c)
      ? sched.Correlation_Key_Prefix__c
      : sched.Name;
  }

  /**
   * @description Resolves a schedule's Input_Json__c into a workflow input, substituting the
   * {{fireTime}} and {{scheduleName}} tokens. Returns null when no input is set.
   * Shared by the 0-slot sweep, run-now, and the dedicated WorkflowScheduleJob so
   * the three paths cannot drift.
   * @param sched The schedule supplying the input template.
   * @param fireTime The window instant substituted for the {{fireTime}} token.
   * @return The deserialized workflow input, or null when no input is configured.
   */
  public static Object resolveInput(
    Workflow_Schedule__c sched,
    DateTime fireTime
  ) {
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
   * @description Returns the JSON-escaped body of a string WITHOUT the surrounding quotes, so
   * it can be substituted into a quoted token position ("{{scheduleName}}").
   * @param raw The raw string to escape.
   * @return The escaped body without surrounding quotes, or empty string when null.
   */
  private static String jsonEscape(String raw) {
    if (raw == null) {
      return '';
    }
    String serialized = JSON.serialize(raw); // quoted + fully escaped
    return serialized.substring(1, serialized.length() - 1);
  }

  /**
   * @description Fires a single schedule applying its overlap policy, recording the outcome in
   * Last_Fired_Window__c / Last_Outcome__c and a Workflow_Log__c row. Shared by the
   * dedicated-slot WorkflowScheduleJob so dedicated fires honour Skip and keep the
   * same state/audit trail as the 0-slot sweep.
   * @param ctx The fire context identifying the schedule, window, and correlation key.
   */
  public static void fireScheduled(FireContext ctx) {
    Workflow_Schedule__c sched = ctx.sched;
    String overlap = String.isNotBlank(sched.Overlap_Policy__c)
      ? sched.Overlap_Policy__c
      : 'Skip';
    String prefix = effectivePrefix(sched);

    if (overlap == 'Skip' && hasActivePriorRun(prefix, ctx.corrKey)) {
      LogSpec spec = new LogSpec(ctx, 'Skipped');
      spec.message = 'Prior run still active';
      upsert as system buildLog(spec) Fire_Key__c;
      updateState(ctx, 'Skipped');
      return;
    }

    // Same guards as the 0-slot sweep: a dedicated schedule whose Workflow_Name__c
    // or Input_Json__c was set outside the manager could otherwise fail on every
    // tick with stale UI state. Record an Error and advance instead of throwing.
    if (!isValidWorkflowName(sched.Workflow_Name__c)) {
      recordError(
        ctx,
        'Unknown workflow definition: ' + sched.Workflow_Name__c
      );
      return;
    }
    Object resolvedInput;
    try {
      resolvedInput = resolveInput(sched, ctx.fireTime);
    } catch (Exception ex) {
      recordError(ctx, 'Invalid input JSON: ' + ex.getMessage());
      return;
    }

    WorkflowEngine.StartResult sr = WorkflowEngine.startOrGet(
      sched.Workflow_Name__c,
      ctx.corrKey,
      resolvedInput
    );
    Boolean isNew = sr != null && sr.isNew;
    String outcome = isNew ? 'Started' : 'Deduped';
    if (isNew) {
      LogSpec spec = new LogSpec(ctx, outcome);
      spec.instanceId = sr.instanceId;
      upsert as system buildLog(spec) Fire_Key__c;
    }
    updateState(ctx, outcome);
  }

  /**
   * @description True when workflowName resolves to a class that implements WorkflowDefinition.
   * Used to reject schedules pointing at a missing/typo'd definition before they
   * reach startOrGet (which would otherwise create a phantom Pending instance).
   * @param workflowName The workflow definition name to validate.
   * @return True if the name resolves to a WorkflowDefinition, false otherwise.
   */
  public static Boolean isValidWorkflowName(String workflowName) {
    if (String.isBlank(workflowName)) {
      return false;
    }
    Type wflowType = WorkflowTypeResolver.resolve(workflowName);
    if (wflowType == null) {
      return false;
    }
    try {
      return wflowType.newInstance() instanceof WorkflowDefinition;
    } catch (Exception e) {
      return false;
    }
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /**
   * @description Records an Error outcome (single log + state advance) for a failed fire.
   * @param ctx The fire context identifying the schedule and window.
   * @param message The error detail recorded on the log row.
   */
  private static void recordError(FireContext ctx, String message) {
    LogSpec spec = new LogSpec(ctx, 'Error');
    spec.message = message;
    upsert as system buildLog(spec) Fire_Key__c;
    updateState(ctx, 'Error');
  }

  /**
   * @description For all Skip-policy due items, returns the set of prefixes that currently have
   * an ACTIVE instance from a DIFFERENT window (i.e. a prior run still in flight).
   *
   * Uses a single dynamic query (coarse LIKE per prefix) and then an EXACT
   * `startsWith(prefix + '_')` filter in Apex, so an unrelated key such as
   * "JobManual_..." can never falsely block the "Job" schedule, and admin-entered
   * `%`/`_` wildcards in a prefix cannot widen the match.
   * @param dueItems The due items being planned this sweep.
   * @return The set of Skip-policy prefixes blocked by an active prior run.
   */
  private static Set<String> computeBlockedPrefixes(List<DueItem> dueItems) {
    Map<String, DueItem> skipByPrefix = new Map<String, DueItem>();
    for (DueItem item : dueItems) {
      if (item.overlapPolicy == 'Skip') {
        skipByPrefix.put(item.prefix, item);
      }
    }

    if (skipByPrefix.isEmpty()) {
      return new Set<String>();
    }

    Map<String, Object> binds = new Map<String, Object>();
    String soql = buildActivePriorRunQuery(skipByPrefix.keySet(), binds);
    List<Workflow_Instance__c> active = Database.queryWithBinds(
      soql,
      binds,
      AccessLevel.SYSTEM_MODE
    );

    return collectBlockedPrefixes(active, skipByPrefix.values());
  }

  /**
   * @description Builds the coarse LIKE-per-prefix query for in-flight instances, populating the
   * bind map. The exact startsWith filter in collectBlockedPrefixes guarantees
   * correctness, so this pre-filter can be broad.
   * @param prefixes The Skip-policy prefixes to match against active instances.
   * @param binds The bind map populated with one LIKE pattern per prefix.
   * @return The dynamic SOQL string querying active instances by prefix.
   */
  private static String buildActivePriorRunQuery(
    Set<String> prefixes,
    Map<String, Object> binds
  ) {
    List<String> ors = new List<String>();
    Integer i = 0;
    for (String prefix : prefixes) {
      String key = 'p' + i;
      binds.put(key, prefix + '_%');
      ors.add('Correlation_Key__c LIKE :' + key);
      i++;
    }
    return 'SELECT Correlation_Key__c FROM Workflow_Instance__c ' +
      'WHERE Active_Correlation_Key__c != null AND (' +
      String.join(ors, ' OR ') +
      ')';
  }

  /**
   * @description From the coarse query result, returns the set of Skip prefixes that have an
   * ACTIVE instance from a DIFFERENT window (a prior run still in flight). Prefixes/
   * keys are compared case-insensitively (the prefix field is caseSensitive=false and
   * SOQL LIKE ignores case) so an admin re-casing a prefix still recognises a prior run.
   * @param active The active instances returned by the coarse prefix query.
   * @param skipItems The Skip-policy due items to test for a blocking prior run.
   * @return The set of prefixes with an active prior run from a different window.
   */
  private static Set<String> collectBlockedPrefixes(
    List<Workflow_Instance__c> active,
    List<DueItem> skipItems
  ) {
    Set<String> blocked = new Set<String>();
    for (Workflow_Instance__c inst : active) {
      if (inst.Correlation_Key__c == null) {
        continue;
      }
      String lcKey = inst.Correlation_Key__c.toLowerCase();
      for (DueItem item : skipItems) {
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
   * @description Single-schedule overlap check (case-insensitive): is there an ACTIVE instance
   * whose correlation key shares this prefix but is from a different window?
   * @param prefix The correlation-key prefix identifying the schedule.
   * @param currentCorrKey The current window's correlation key, excluded from the match.
   * @return True when an active instance from a different window shares the prefix.
   */
  private static Boolean hasActivePriorRun(
    String prefix,
    String currentCorrKey
  ) {
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

  /**
   * @description Truncates a DateTime to the start of its minute in UTC (seconds = 0).
   * @param dt The DateTime to truncate.
   * @return The same instant with seconds zeroed, in UTC.
   */
  private static DateTime truncateToMinute(DateTime dt) {
    return DateTime.newInstanceGmt(
      dt.yearGmt(),
      dt.monthGmt(),
      dt.dayGmt(),
      dt.hourGmt(),
      dt.minuteGmt(),
      0
    );
  }

  /**
   * @description Advances a schedule's last/next window state after a fire. Single-row DML.
   * @param ctx The fire context identifying the schedule and window.
   * @param outcome The outcome label recorded on the schedule.
   */
  private static void updateState(FireContext ctx, String outcome) {
    update as system new Workflow_Schedule__c(
      Id = ctx.sched.Id,
      Last_Fired_Window__c = ctx.fireTime,
      Last_Outcome__c = outcome,
      Next_Fire_Window__c = nextWindow(
        ctx.sched.Cron_Expression__c,
        ctx.fireTime
      )
    );
  }

  /**
   * @description Next fire instant STRICTLY after the handled window, or null if unknown.
   * WorkflowCronEvaluator.nextFireTime is inclusive (returns the window itself if
   * it matches), so we evaluate from one minute past the handled window — cron
   * windows are minute-granular — to guarantee the cursor advances and the row
   * rotates out of future batches.
   * @param cron The schedule's cron expression.
   * @param firedWindow The window instant just handled.
   * @return The next window strictly after firedWindow, or null when unknown.
   */
  private static DateTime nextWindow(String cron, DateTime firedWindow) {
    if (String.isBlank(cron) || firedWindow == null) {
      return null;
    }
    try {
      return WorkflowCronEvaluator.nextFireTime(
        cron,
        firedWindow.addMinutes(1)
      );
    } catch (Exception e) {
      return null;
    }
  }

  private static Workflow_Log__c buildLog(LogSpec spec) {
    return new Workflow_Log__c(
      Fire_Key__c = spec.corrKey + ':' + spec.outcome,
      Log_Type__c = String.isNotBlank(spec.logType) ? spec.logType : LOG_TYPE,
      Level__c = LEVEL_INFO,
      Outcome__c = spec.outcome,
      Schedule__c = spec.sched.Id,
      Schedule_Name__c = spec.sched.Name,
      Workflow_Name__c = spec.sched.Workflow_Name__c,
      Correlation_Key__c = spec.corrKey,
      Fire_Time__c = spec.fireTime,
      Workflow_Instance__c = spec.instanceId,
      Message__c = spec.message
    );
  }

  /**
   * @description Converts a 5-field cron (min hour dom month dow) to the 7-field Salesforce
   * format required by System.schedule: seconds minutes hours dom month dow year.
   *
   * Two Salesforce-specific translations are applied:
   *   - Day-of-week is remapped from this engine's 0–6 (0=Sun) to Salesforce's
   *     1–7 (1=Sun…7=Sat), preserving lists/ranges/steps.
   *   - Salesforce requires exactly one of dom/dow to be '?'. Because Salesforce
   *     cron has no DOM-OR-DOW semantics, a cron that restricts BOTH is rejected
   *     for dedicated mode (the 0-slot evaluator still supports it).
   * @param fiveFieldCron The 5-field cron expression to convert.
   * @return The equivalent 7-field Salesforce cron string.
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
