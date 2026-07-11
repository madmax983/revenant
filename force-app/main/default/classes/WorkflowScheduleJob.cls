/**
 * Schedule-aware Schedulable used for dedicated-slot schedules (1 CronTrigger).
 *
 * Unlike the legacy WorkflowScheduler, this job stores only the schedule Id and
 * re-reads the Workflow_Schedule__c row at fire time, so it:
 *   - honours Enabled__c (a disabled schedule's armed job becomes a no-op), and
 *   - resolves the {{fireTime}} / {{scheduleName}} input tokens via the same
 *     WorkflowScheduleSweeper logic as the 0-slot path.
 *
 * NOTE: System.schedule interprets the cron in the arming user's time zone, which
 * differs from the UTC 0-slot path — see docs/recurring-schedules.md.
 */
public inherited sharing class WorkflowScheduleJob implements Schedulable {
  private Id scheduleId;

  public WorkflowScheduleJob(Id scheduleId) {
    this.scheduleId = scheduleId;
  }

  public void execute(SchedulableContext ctx) {
    List<Workflow_Schedule__c> rows = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Cron_Expression__c,
        Correlation_Key_Prefix__c,
        Input_Json__c,
        Enabled__c,
        Overlap_Policy__c,
        Dedicated_Slot__c
      FROM Workflow_Schedule__c
      WHERE Id = :scheduleId
      WITH SYSTEM_MODE
      LIMIT 1
    ];

    if (rows.isEmpty()) {
      // The schedule was deleted outside deleteSchedule (e.g. Object Manager or the
      // API), so no row remains for the UI to abort. Self-abort this CronTrigger so
      // it stops consuming one of the org's scheduled-job slots forever.
      if (ctx != null) {
        System.abortJob(ctx.getTriggerId());
      }
      return;
    }
    Workflow_Schedule__c sched = rows[0];

    // Re-check state at fire time: a disabled or no-longer-dedicated schedule must
    // not start workflows even if its CronTrigger is still armed. If it was toggled
    // off outside the controller (record page/API), self-abort so the CronTrigger
    // doesn't linger consuming a scheduled-job slot with no UI action to remove it
    // (the controller already aborts on its own disable/un-dedicate paths).
    if (!sched.Enabled__c || !sched.Dedicated_Slot__c) {
      if (ctx != null) {
        System.abortJob(ctx.getTriggerId());
      }
      return;
    }

    // Use the scheduled cron window, not the raw execution time: Salesforce may run
    // a "0 2 * * *" job at 02:01, but the fire-window key/state must read 02:00 to
    // match the 0-slot path and dedup correctly. Fall back to now only if the cron
    // yields no window (impossible cron — the CronTrigger shouldn't have fired).
    DateTime now = DateTime.now();
    DateTime fireTime = WorkflowCronEvaluator.previousFireTime(
      sched.Cron_Expression__c,
      now
    );
    if (fireTime == null) {
      fireTime = now;
    }
    String corrKey =
      WorkflowScheduleSweeper.effectivePrefix(sched) +
      '_' +
      fireTime.formatGmt('yyyyMMddHHmm');

    // Route through the shared fire path so dedicated fires honour the overlap
    // policy and record Last_Fired_Window__c / Last_Outcome__c + a fire log,
    // identically to the 0-slot sweep.
    WorkflowScheduleSweeper.FireContext ctx = new WorkflowScheduleSweeper.FireContext();
    ctx.sched = sched;
    ctx.fireTime = fireTime;
    ctx.corrKey = corrKey;
    ctx.logType = 'ScheduleDedicatedFire';
    WorkflowScheduleSweeper.fireScheduled(ctx);
  }
}
