/**
 * Due-detection and per-item planning for the 0-slot sweep, lifted out of
 * WorkflowScheduleSweeper to keep that class under its complexity budget.
 *
 * classifyForSweep decides, per schedule, whether to queue a cursor-only update
 * (park an impossible cron, backfill a handled window, seed a never-fired
 * pre-creation window) or to record a due item. planDueItem then turns a due item
 * into a Skipped/Error log + cursor advance, or a bulk StartRequest. Both operate
 * on WorkflowScheduleSweepRunner's DueItem / SweepState working set and reuse its
 * advanceRow / specFor helpers so the sweep pipeline stays consistent.
 *
 * All cron-window math, null/NPE ordering, blocked-prefix guard semantics, and the
 * per-item exception swallowing are byte-identical to the original sweeper helpers.
 */
public inherited sharing class WorkflowScheduleDueClassifier {
  /**
   * @description Classifies one schedule for the sweep: either queues a cursor-only update
   * (park an impossible cron, backfill a handled window, or seed a never-fired pre-creation
   * window) or appends a DueItem to fire. Per-item exceptions are swallowed so one bad
   * schedule cannot abort the whole heartbeat batch.
   * @param sched The schedule row being classified.
   * @param state The mutable sweep working set accumulating updates and due items.
   */
  public static void classifyForSweep(
    Workflow_Schedule__c sched,
    WorkflowScheduleSweepRunner.SweepState state
  ) {
    try {
      // Isolate an unsupported time zone the same way an impossible cron is
      // parked: a row created outside the manager (Setup/API) could carry a bad
      // Time_Zone__c. Record the outcome, park the cursor a day out so it rotates
      // out of future batches, and CONTINUE so one bad row can't abort the sweep.
      if (
        String.isNotBlank(sched.Time_Zone__c) &&
        !WorkflowCronEvaluator.isValidZone(sched.Time_Zone__c)
      ) {
        state.toUpdate.add(
          new Workflow_Schedule__c(
            Id = sched.Id,
            Next_Fire_Window__c = state.now.addDays(1),
            Last_Outcome__c = 'Invalid time zone'
          )
        );
        return;
      }
      DateTime fireTime = WorkflowCronEvaluator.previousFireTime(
        sched.Cron_Expression__c,
        state.now,
        sched.Time_Zone__c
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
              Next_Fire_Window__c = SalesforceCronTranslator.nextWindow(
                sched.Cron_Expression__c,
                fireTime,
                sched.Time_Zone__c
              )
            )
          );
        }
        return;
      }
      if (
        sched.Last_Fired_Window__c == null &&
        fireTime < SchedulePriorRunGuard.truncateToMinute(sched.CreatedDate)
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
            Next_Fire_Window__c = SalesforceCronTranslator.nextWindow(
              sched.Cron_Expression__c,
              fireTime,
              sched.Time_Zone__c
            )
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
  private static WorkflowScheduleSweepRunner.DueItem buildDueItem(
    Workflow_Schedule__c sched,
    DateTime fireTime
  ) {
    WorkflowScheduleSweepRunner.DueItem item = new WorkflowScheduleSweepRunner.DueItem();
    item.sched = sched;
    item.fireTime = fireTime;
    item.prefix = WorkflowScheduleSweeper.effectivePrefix(sched);
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
  public static void planDueItem(
    WorkflowScheduleSweepRunner.DueItem item,
    WorkflowScheduleSweepRunner.SweepState state
  ) {
    if (
      item.overlapPolicy == 'Skip' &&
      state.blockedPrefixes.contains(item.prefix)
    ) {
      ScheduleFireLog.Spec spec = WorkflowScheduleSweepRunner.specFor(
        item,
        'Skipped'
      );
      spec.message = 'Prior run still active';
      state.logsToUpsert.add(ScheduleFireLog.build(spec));
      state.toUpdate.add(
        WorkflowScheduleSweepRunner.advanceRow(item, 'Skipped')
      );
      return;
    }
    // Validate the workflow definition resolves before starting. A schedule created
    // outside the manager with a typo in Workflow_Name__c would otherwise be handed
    // to startOrGet, which builds a Pending instance even when Type.forName can't
    // resolve a class — recording a phantom "Started" that only fails asynchronously.
    if (
      !ScheduleInputResolver.isValidWorkflowName(item.sched.Workflow_Name__c)
    ) {
      ScheduleFireLog.Spec spec = WorkflowScheduleSweepRunner.specFor(
        item,
        'Error'
      );
      spec.message =
        'Unknown workflow definition: ' + item.sched.Workflow_Name__c;
      state.logsToUpsert.add(ScheduleFireLog.build(spec));
      state.toUpdate.add(WorkflowScheduleSweepRunner.advanceRow(item, 'Error'));
      return;
    }
    // resolveInput can throw if Input_Json__c is malformed (a schedule can be
    // created/edited via Setup or Object Manager, bypassing saveSchedule's JSON
    // validation).
    Object resolvedInput;
    try {
      resolvedInput = ScheduleInputResolver.resolveInput(
        item.sched,
        item.fireTime
      );
    } catch (Exception ex) {
      ScheduleFireLog.Spec spec = WorkflowScheduleSweepRunner.specFor(
        item,
        'Error'
      );
      spec.message = 'Invalid input JSON: ' + ex.getMessage();
      state.logsToUpsert.add(ScheduleFireLog.build(spec));
      state.toUpdate.add(WorkflowScheduleSweepRunner.advanceRow(item, 'Error'));
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
}
