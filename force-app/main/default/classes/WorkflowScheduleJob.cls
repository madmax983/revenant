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
        Correlation_Key_Prefix__c,
        Input_Json__c,
        Enabled__c,
        Dedicated_Slot__c
      FROM Workflow_Schedule__c
      WHERE Id = :scheduleId
      WITH SYSTEM_MODE
      LIMIT 1
    ];

    if (rows.isEmpty()) {
      return; // schedule was deleted
    }
    Workflow_Schedule__c sched = rows[0];

    // Re-check state at fire time: a disabled or no-longer-dedicated schedule must
    // not start workflows even if its CronTrigger is still armed.
    if (!sched.Enabled__c || !sched.Dedicated_Slot__c) {
      return;
    }

    DateTime now = DateTime.now();
    String corrKey =
      WorkflowScheduleSweeper.effectivePrefix(sched) +
      '_' +
      now.formatGmt('yyyyMMddHHmm');

    WorkflowEngine.startOrGet(
      sched.Workflow_Name__c,
      corrKey,
      WorkflowScheduleSweeper.resolveInput(sched, now)
    );
  }
}
