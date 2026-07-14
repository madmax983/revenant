/**
 * The 0-slot sweep orchestration lifted out of WorkflowScheduleSweeper to keep
 * that class under its complexity budget.
 *
 * run() drives the bulkified heartbeat sweep: load due schedules, classify each
 * (delegated to WorkflowScheduleDueClassifier), resolve overlap-blocked prefixes
 * (SchedulePriorRunGuard), plan the due items, then issue a single bulk start and
 * flush the queued cursor/state updates and audit logs. It owns the DueItem and
 * SweepState working-set value objects shared with the classifier.
 *
 * All SOQL/DML statements, their ORDER, as-system mode, and the Fire_Key__c upsert
 * are byte-identical to the original WorkflowScheduleSweeper.sweep implementation;
 * WorkflowScheduleSweeper.sweep is now a thin delegator to run().
 */
public inherited sharing class WorkflowScheduleSweepRunner {
  /**
   * Holder for a schedule that is due this sweep. Public so the classifier can
   * build and populate it across the class boundary.
   */
  public class DueItem {
    /** @description The due schedule row. */
    public Workflow_Schedule__c sched;
    /** @description The cron window instant this fire corresponds to. */
    public DateTime fireTime;
    /** @description The effective correlation-key prefix for the schedule. */
    public String prefix;
    /** @description The correlation key for this window. */
    public String corrKey;
    /** @description The resolved overlap policy (Skip or Allow). */
    public String overlapPolicy;
  }

  /**
   * Mutable working set threaded through the 0-slot sweep helpers so each stage
   * can append to the shared update/log/start buffers without long parameter
   * lists. Public so the classifier can accumulate into it across classes.
   */
  public class SweepState {
    /** @description The evaluation instant for this sweep. */
    public DateTime now;
    /** @description The schedules found due this sweep. */
    public List<DueItem> dueItems = new List<DueItem>();
    /** @description Queued schedule cursor/state updates to flush. */
    public List<Workflow_Schedule__c> toUpdate = new List<Workflow_Schedule__c>();
    /** @description Queued audit logs to upsert by Fire_Key__c. */
    public List<Workflow_Log__c> logsToUpsert = new List<Workflow_Log__c>();
    /** @description Bulk start requests built for due items that should start. */
    public List<WorkflowEngine.StartRequest> requests = new List<WorkflowEngine.StartRequest>();
    /** @description The due items in the same order as requests, for result pairing. */
    public List<DueItem> starting = new List<DueItem>();
    /** @description Skip-policy prefixes blocked by an active prior run. */
    public Set<String> blockedPrefixes;
  }

  /**
   * @description Main sweep body. Loads due 0-slot schedules, classifies them, resolves
   * overlap-blocked prefixes, plans due items, issues one bulk start, then flushes the
   * queued cursor/state updates and audit logs.
   */
  public static void run() {
    List<Workflow_Schedule__c> schedules = WorkflowScheduleSweeper.loadDueSchedules(
      DateTime.now()
    );
    if (schedules.isEmpty()) {
      return;
    }

    SweepState state = new SweepState();
    state.now = DateTime.now();

    // Phase 1: determine which schedules are due (cheap, no per-row SOQL/DML).
    for (Workflow_Schedule__c sched : schedules) {
      WorkflowScheduleDueClassifier.classifyForSweep(sched, state);
    }

    if (state.dueItems.isEmpty()) {
      // Nothing to fire, but flush any cursor backfills queued above.
      flushUpdates(state.toUpdate);
      return;
    }

    // Phase 2: bulk-resolve which Skip schedules are blocked by an active prior run.
    // Reduce the Skip due items to prefix→current-window-corrKey before handing the
    // concurrency check to SchedulePriorRunGuard (which stays free of DueItem coupling).
    Map<String, String> skipCorrKeyByPrefix = new Map<String, String>();
    for (DueItem item : state.dueItems) {
      if (item.overlapPolicy == 'Skip') {
        skipCorrKeyByPrefix.put(item.prefix, item.corrKey);
      }
    }
    state.blockedPrefixes = SchedulePriorRunGuard.computeBlockedPrefixes(
      skipCorrKeyByPrefix
    );

    // Phase 3: build a single bulk start for everything that should start.
    for (DueItem item : state.dueItems) {
      WorkflowScheduleDueClassifier.planDueItem(item, state);
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
        ScheduleFireLog.Spec spec = specFor(item, outcome);
        spec.instanceId = sr.instanceId;
        state.logsToUpsert.add(ScheduleFireLog.build(spec));
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
  public static Workflow_Schedule__c advanceRow(DueItem item, String outcome) {
    return new Workflow_Schedule__c(
      Id = item.sched.Id,
      Last_Fired_Window__c = item.fireTime,
      Last_Outcome__c = outcome,
      Next_Fire_Window__c = SalesforceCronTranslator.nextWindow(
        item.sched.Cron_Expression__c,
        item.fireTime
      )
    );
  }

  /**
   * @description Seeds a ScheduleFireLog.Spec from a due item and outcome (logType left null so
   * it falls back to the default 0-slot log type). Public so the classifier reuses it.
   * @param item The due item supplying the schedule, correlation key, and window instant.
   * @param outcome The outcome recorded on the audit row.
   * @return The partially-populated ScheduleFireLog.Spec (instanceId/message set by callers).
   */
  public static ScheduleFireLog.Spec specFor(DueItem item, String outcome) {
    ScheduleFireLog.Spec spec = new ScheduleFireLog.Spec();
    spec.sched = item.sched;
    spec.corrKey = item.corrKey;
    spec.fireTime = item.fireTime;
    spec.outcome = outcome;
    return spec;
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
}
