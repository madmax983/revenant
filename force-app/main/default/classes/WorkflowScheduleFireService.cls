/**
 * Single-fire execution path lifted out of WorkflowScheduleSweeper to keep that
 * class under its complexity budget.
 *
 * Fires ONE schedule at a time — the dedicated-slot path (fireScheduled, called
 * by WorkflowScheduleJob via the sweeper's delegator) and the manual Run Now log
 * (recordManualStartLog, called by WorkflowScheduleJobManager). Both apply the
 * schedule's overlap policy, advance Last_Fired_Window__c / Last_Outcome__c, and
 * write a Workflow_Log__c audit row identically to the 0-slot sweep.
 *
 * All overlap ordering, guard checks, SOQL/DML (byte-identical, as-system), and
 * correlation-key handling are preserved exactly from the original sweeper.
 */
public inherited sharing class WorkflowScheduleFireService {
  /**
   * @description Fires a single schedule applying its overlap policy, recording the outcome in
   * Last_Fired_Window__c / Last_Outcome__c and a Workflow_Log__c row. Shared by the
   * dedicated-slot WorkflowScheduleJob so dedicated fires honour Skip and keep the
   * same state/audit trail as the 0-slot sweep.
   * @param ctx The fire context identifying the schedule, window, and correlation key.
   */
  public static void fireScheduled(WorkflowScheduleSweeper.FireContext ctx) {
    Workflow_Schedule__c sched = ctx.sched;
    String overlap = String.isNotBlank(sched.Overlap_Policy__c)
      ? sched.Overlap_Policy__c
      : 'Skip';
    String prefix = WorkflowScheduleSweeper.effectivePrefix(sched);

    if (
      overlap == 'Skip' &&
      SchedulePriorRunGuard.hasActivePriorRun(prefix, ctx.corrKey)
    ) {
      ScheduleFireLog.Spec spec = specFor(ctx, 'Skipped');
      spec.message = 'Prior run still active';
      upsert as system ScheduleFireLog.build(spec) Fire_Key__c;
      updateState(ctx, 'Skipped');
      return;
    }

    // Same guards as the 0-slot sweep: a dedicated schedule whose Workflow_Name__c
    // or Input_Json__c was set outside the manager could otherwise fail on every
    // tick with stale UI state. Record an Error and advance instead of throwing.
    if (!ScheduleInputResolver.isValidWorkflowName(sched.Workflow_Name__c)) {
      recordError(
        ctx,
        'Unknown workflow definition: ' + sched.Workflow_Name__c
      );
      return;
    }
    Object resolvedInput;
    try {
      resolvedInput = ScheduleInputResolver.resolveInput(sched, ctx.fireTime);
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
      ScheduleFireLog.Spec spec = specFor(ctx, outcome);
      spec.instanceId = sr.instanceId;
      upsert as system ScheduleFireLog.build(spec) Fire_Key__c;
    }
    updateState(ctx, outcome);
  }

  /**
   * @description Records the Started audit log for a manual (Run Now) fire and persists it.
   * Kept alongside the fire path so the log DML and ScheduleFireLog machinery stay in
   * one place; called by WorkflowScheduleJobManager.runNow.
   * @param ctx The manual fire context identifying the schedule, window, and correlation key.
   * @param instanceId The Id of the started workflow instance recorded on the log.
   * @param message The audit message recorded on the log row.
   */
  public static void recordManualStartLog(
    WorkflowScheduleSweeper.FireContext ctx,
    Id instanceId,
    String message
  ) {
    ScheduleFireLog.Spec spec = specFor(ctx, 'Started');
    spec.instanceId = instanceId;
    spec.message = message;
    upsert as system ScheduleFireLog.build(spec) Fire_Key__c;
  }

  /**
   * @description Records an Error outcome (single log + state advance) for a failed fire.
   * @param ctx The fire context identifying the schedule and window.
   * @param message The error detail recorded on the log row.
   */
  private static void recordError(
    WorkflowScheduleSweeper.FireContext ctx,
    String message
  ) {
    ScheduleFireLog.Spec spec = specFor(ctx, 'Error');
    spec.message = message;
    upsert as system ScheduleFireLog.build(spec) Fire_Key__c;
    updateState(ctx, 'Error');
  }

  /**
   * @description Advances a schedule's last/next window state after a fire. Single-row DML.
   * @param ctx The fire context identifying the schedule and window.
   * @param outcome The outcome label recorded on the schedule.
   */
  private static void updateState(
    WorkflowScheduleSweeper.FireContext ctx,
    String outcome
  ) {
    update as system new Workflow_Schedule__c(
      Id = ctx.sched.Id,
      Last_Fired_Window__c = ctx.fireTime,
      Last_Outcome__c = outcome,
      Next_Fire_Window__c = SalesforceCronTranslator.nextWindow(
        ctx.sched.Cron_Expression__c,
        ctx.fireTime
      )
    );
  }

  /**
   * @description Seeds a ScheduleFireLog.Spec from a fire context and outcome, carrying the
   * schedule, correlation key, window instant, and log type across for the audit row.
   * @param ctx The fire context supplying the schedule, correlation key, window, and log type.
   * @param outcome The outcome recorded on the audit row.
   * @return The partially-populated ScheduleFireLog.Spec (instanceId/message set by callers).
   */
  private static ScheduleFireLog.Spec specFor(
    WorkflowScheduleSweeper.FireContext ctx,
    String outcome
  ) {
    ScheduleFireLog.Spec spec = new ScheduleFireLog.Spec();
    spec.sched = ctx.sched;
    spec.corrKey = ctx.corrKey;
    spec.fireTime = ctx.fireTime;
    spec.logType = ctx.logType;
    spec.outcome = outcome;
    return spec;
  }
}
