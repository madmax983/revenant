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
 *
 * This class is the public facade for schedule processing. To keep it under the
 * complexity budget the mechanics live in cohesive collaborators, each reached via
 * a thin delegator here so external callers are unaffected:
 *   - SalesforceCronTranslator     — cron conversion + next-window math
 *   - SchedulePriorRunGuard        — overlap / blocked-prefix concurrency guard
 *   - WorkflowScheduleJobManager   — dedicated-slot CronTrigger + manual run
 *   - WorkflowScheduleSweepRunner  — 0-slot sweep orchestration + working set
 *   - WorkflowScheduleDueClassifier— due-detection + per-item planning
 *   - WorkflowScheduleFireService  — single-fire (dedicated + manual) execution
 *   - ScheduleFireLog              — audit-log row assembly
 * The shared helpers (effectivePrefix, resolveInput, isValidWorkflowName) and the
 * FireContext value object remain here because every path depends on them.
 */
public inherited sharing class WorkflowScheduleSweeper {
  // Max schedules processed per heartbeat. The sweep is bulkified, but this bounds
  // the up-front cron evaluation and keeps a single heartbeat's footprint small.
  @TestVisible
  private static Integer sweepBatchSize = 50;

  /**
   * @description Thrown for schedule-management errors, such as a cron that
   * cannot be expressed in Salesforce's dedicated-slot format or a fire targeting
   * an unknown workflow definition.
   */
  public class WorkflowScheduleException extends Exception {
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

  // ── Public API ─────────────────────────────────────────────────────────────

  /**
   * @description Main sweep entry point. Called by WorkflowEngine.processWatchdogHeartbeat().
   * Delegates the 0-slot sweep orchestration to WorkflowScheduleSweepRunner.
   */
  public static void sweep() {
    WorkflowScheduleSweepRunner.run();
  }

  /**
   * @description Loads the due (or never-fired) 0-slot schedules for this sweep, ordered
   * least-recently-due first. Next_Fire_Window__c is a server-side cursor: a handled
   * low-cadence schedule's next window is in the future, so it filters out and cannot
   * pin the batch and starve higher-cadence schedules. Kept here (not in the runner)
   * because it reads the @TestVisible sweepBatchSize governor tests set on this class.
   * @param now The evaluation instant used as the due cutoff.
   * @return The batch of enabled, non-dedicated schedules that may be due.
   */
  public static List<Workflow_Schedule__c> loadDueSchedules(DateTime now) {
    return [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Cron_Expression__c,
        Input_Json__c,
        Correlation_Key_Prefix__c,
        Overlap_Policy__c,
        Time_Zone__c,
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
   * @description Arms a dedicated CronTrigger (1 scheduled-job slot) for a Dedicated_Slot__c
   * schedule via the schedule-aware WorkflowScheduleJob, which re-reads the record
   * at fire time (so disabling the schedule stops it) and resolves input tokens.
   *
   * NOTE: System.schedule interprets the cron in the ARMING USER'S time zone, unlike
   * the UTC 0-slot path — see docs/recurring-schedules.md.
   * @param scheduleId The Id of the schedule to arm a dedicated CronTrigger for.
   */
  public static void registerDedicatedJob(Id scheduleId) {
    WorkflowScheduleJobManager.registerDedicatedJob(scheduleId);
  }

  /**
   * @description Stable CronTrigger/job name for a dedicated schedule, derived from its Id.
   * @param scheduleId The Id of the schedule.
   * @return The deterministic job name used to arm, find, and abort its CronTrigger.
   */
  public static String dedicatedJobName(Id scheduleId) {
    return WorkflowScheduleJobManager.dedicatedJobName(scheduleId);
  }

  /**
   * @description Fires a schedule immediately, on demand, independent of its cron cadence.
   * Uses a distinct manual correlation key so it never collides with a cron
   * window. Records a Started log and returns the started instance Id.
   * @param scheduleId The Id of the schedule to run now.
   * @return The Id of the started workflow instance.
   */
  public static Id runNow(Id scheduleId) {
    return WorkflowScheduleJobManager.runNow(scheduleId);
  }

  /**
   * @description Aborts the dedicated CronTrigger registered for this schedule.
   * @param scheduleId The Id of the schedule whose CronTrigger should be aborted.
   */
  public static void unregisterDedicatedJob(Id scheduleId) {
    WorkflowScheduleJobManager.unregisterDedicatedJob(scheduleId);
  }

  /**
   * @description Whether a dedicated CronTrigger is currently armed for this schedule.
   * @param scheduleId The Id of the schedule to check.
   * @return True if a CronTrigger for this schedule exists, false otherwise.
   */
  public static Boolean isDedicatedJobArmed(Id scheduleId) {
    return WorkflowScheduleJobManager.isDedicatedJobArmed(scheduleId);
  }

  // ── Shared helpers (also used by WorkflowScheduleJob and the collaborators) ──

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
   * @description Fires a single schedule applying its overlap policy, recording the outcome in
   * Last_Fired_Window__c / Last_Outcome__c and a Workflow_Log__c row. Shared by the
   * dedicated-slot WorkflowScheduleJob so dedicated fires honour Skip and keep the
   * same state/audit trail as the 0-slot sweep. Delegates to WorkflowScheduleFireService.
   * @param ctx The fire context identifying the schedule, window, and correlation key.
   */
  public static void fireScheduled(FireContext ctx) {
    WorkflowScheduleFireService.fireScheduled(ctx);
  }

  /**
   * @description Converts a 5-field cron (min hour dom month dow) to the 7-field Salesforce
   * format required by System.schedule. Delegates to SalesforceCronTranslator; retained
   * here (@TestVisible) because the cron-translation tests exercise it on this class.
   * @param fiveFieldCron The 5-field cron expression to convert.
   * @return The equivalent 7-field Salesforce cron string.
   */
  @TestVisible
  static String toSalesforceCron(String fiveFieldCron) {
    return SalesforceCronTranslator.toSalesforceCron(fiveFieldCron);
  }
}
