/**
 * Dedicated-slot job management lifted out of WorkflowScheduleSweeper to keep that
 * class under its complexity budget.
 *
 * Holds the machinery behind the sweeper's public dedicated-slot API: arming and
 * aborting a schedule's CronTrigger, querying whether one is armed, and the manual
 * on-demand run. WorkflowScheduleSweeper keeps thin public delegators for every
 * method here so external callers (WorkflowScheduleController and the tests) are
 * unaffected.
 *
 * All SOQL, DML, System.schedule/abortJob, cron translation, and correlation-key
 * math are byte-identical to the original sweeper methods. Fire logging is routed
 * through WorkflowScheduleFireService.recordManualStartLog so the audit-log DML
 * stays in one place.
 */
public inherited sharing class WorkflowScheduleJobManager {
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
    if (scheduleId == null) {
      throw new WorkflowScheduleSweeper.WorkflowScheduleException(
        'scheduleId is required to register a dedicated job.'
      );
    }
    Workflow_Schedule__c sched = [
      SELECT Id, Name, Cron_Expression__c
      FROM Workflow_Schedule__c
      WHERE Id = :scheduleId
      WITH SYSTEM_MODE
      LIMIT 1
    ];

    String sfCron = SalesforceCronTranslator.toSalesforceCron(
      sched.Cron_Expression__c
    );
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
    if (scheduleId == null) {
      throw new WorkflowScheduleSweeper.WorkflowScheduleException(
        'scheduleId is required to run a schedule now.'
      );
    }
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
    if (!ScheduleInputResolver.isValidWorkflowName(sched.Workflow_Name__c)) {
      throw new WorkflowScheduleSweeper.WorkflowScheduleException(
        'Unknown workflow definition: ' + sched.Workflow_Name__c
      );
    }

    DateTime now = DateTime.now();
    // Manual runs are meant to be independent, so the key carries millisecond +
    // random entropy: two Run Now clicks in the same second must not collapse into
    // one instance via the engine's active-correlation-key dedup.
    String corrKey =
      WorkflowScheduleSweeper.effectivePrefix(sched) +
      '_manual_' +
      String.valueOf(now.getTime()) +
      '_' +
      String.valueOf(Crypto.getRandomInteger()).replace('-', '');

    WorkflowEngine.StartResult sr = WorkflowEngine.startOrGet(
      sched.Workflow_Name__c,
      corrKey,
      ScheduleInputResolver.resolveInput(sched, now)
    );

    WorkflowScheduleSweeper.FireContext ctx = new WorkflowScheduleSweeper.FireContext();
    ctx.sched = sched;
    ctx.fireTime = now;
    ctx.corrKey = corrKey;
    ctx.logType = 'ScheduleManualFire';
    WorkflowScheduleFireService.recordManualStartLog(
      ctx,
      sr.instanceId,
      'Manual run'
    );

    return sr.instanceId;
  }

  /**
   * @description Aborts the dedicated CronTrigger registered for this schedule.
   * @param scheduleId The Id of the schedule whose CronTrigger should be aborted.
   */
  public static void unregisterDedicatedJob(Id scheduleId) {
    String jobName = dedicatedJobName(scheduleId);
    if (jobName == null) {
      return;
    }
    if (String.isBlank(jobName)) {
      return;
    }
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
}
