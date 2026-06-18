/**
 * Operator-facing pause/resume gate for workflow definitions.
 *
 * Pause state is durable: stored in Workflow_Pause_State__c (keyed by
 * Workflow_Name__c). Presence of a record = that definition (or * for all) is
 * paused. Resume deletes the record and re-queues all parked instances.
 *
 * ENGINE INTEGRATION
 *   WorkflowEngine.runStep calls anyPaused() + isDefinitionPaused() to decide
 *   whether to park an instance instead of executing its next step. The check
 *   is transaction-cached for performance (one SOQL per call stack, not per
 *   step).
 *
 * RESERVED NAMES
 *   Engine-internal workflows (WatchdogWorkflow, CleanupWorkflow,
 *   BulkRedriveWorkflow) are NEVER paused — not by an explicit record and not
 *   by the wildcard *. Pausing the watchdog would deadlock the resume path
 *   itself.
 */
public inherited sharing class WorkflowPauseGate {
  public class PauseException extends Exception {
  }

  // Engine-internal workflow names that must never be paused.
  @TestVisible
  private static final Set<String> RESERVED_NAMES = new Set<String>{
    'WatchdogWorkflow',
    'CleanupWorkflow',
    'BulkRedriveWorkflow'
  };

  // Transaction-scope cache: null = not yet loaded this tx
  private static Boolean cachedAnyPaused = null;
  private static Set<String> cachedPausedNames = null;

  // Max parked instances flipped back to Running per transaction on resume; the
  // remainder is drained by a chained Queueable. @TestVisible so tests can lower
  // it to exercise the chunk boundary without inserting hundreds of rows.
  @TestVisible
  private static Integer RESUME_CHUNK_SIZE = 200;

  // ──────────────────────────────────────────────────────────────────────────
  // FAST-PATH: any pause record exists at all?
  // Called on every runStep invocation; a false result short-circuits everything.
  // ──────────────────────────────────────────────────────────────────────────
  public static Boolean anyPaused() {
    if (cachedAnyPaused == null) {
      loadCache();
    }
    return cachedAnyPaused;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Is a specific definition paused (by name or by wildcard *)?
  // Reserved names always return false regardless of pause records.
  // ──────────────────────────────────────────────────────────────────────────
  public static Boolean isDefinitionPaused(String workflowName) {
    if (isReserved(workflowName)) {
      return false;
    }
    if (cachedPausedNames == null) {
      loadCache();
    }
    // Workflow_Name__c is a case-insensitive unique external id, so the in-memory
    // cache is normalized to lower case and the lookup key is too — otherwise a
    // pause stored as 'foo' would be missed when the engine checks 'Foo'.
    return cachedPausedNames.contains(normalize(workflowName)) ||
      cachedPausedNames.contains('*');
  }

  // True when an org-wide '*' pause is in effect (every non-reserved definition
  // is paused). Callers that batch-select instances use this to short-circuit.
  public static Boolean wildcardPaused() {
    if (cachedPausedNames == null) {
      loadCache();
    }
    return cachedPausedNames.contains('*');
  }

  // The set of explicitly paused definition names (excludes the '*' sentinel).
  // Used to exclude paused definitions from batch queries (e.g. the watchdog
  // resume batch) so they cannot starve resumable rows under a LIMIT.
  public static Set<String> pausedNames() {
    if (cachedPausedNames == null) {
      loadCache();
    }
    Set<String> names = new Set<String>(cachedPausedNames);
    names.remove('*');
    return names;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Pause a definition (or * for org-wide). Idempotent (upsert).
  // Throws PauseException for blank or reserved names.
  // ──────────────────────────────────────────────────────────────────────────
  public static void pauseDefinition(String workflowName, String reason) {
    if (String.isBlank(workflowName)) {
      throw new PauseException(
        'workflowName must not be blank when pausing.'
      );
    }
    if (isReserved(workflowName)) {
      throw new PauseException(
        'Cannot pause reserved engine workflow: ' +
        workflowName +
        '. Reserved workflows keep the engine running.'
      );
    }
    Workflow_Pause_State__c record = new Workflow_Pause_State__c(
      Workflow_Name__c = workflowName,
      Reason__c = reason
    );
    upsert as system record Workflow_Name__c;
    invalidateCache();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Resume a definition (or * for all). Deletes the pause record(s) and
  // re-queues every instance that was parked (Status__c = 'Paused').
  // Also kicks WorkflowWatchdog.bootstrap() so held sleeps/timeouts resume.
  // ──────────────────────────────────────────────────────────────────────────
  public static void resumeDefinition(String workflowName) {
    if (String.isBlank(workflowName)) {
      throw new PauseException(
        'workflowName must not be blank when resuming.'
      );
    }

    // Delete pause records
    List<Workflow_Pause_State__c> toDelete;
    if (workflowName == '*') {
      toDelete = [
        SELECT Id
        FROM Workflow_Pause_State__c
        WITH SYSTEM_MODE
      ];
    } else {
      // Resume only the named definition. A wildcard ('*') pause is org-wide
      // maintenance mode and must NOT be lifted by a single-definition resume —
      // doing so would un-pause every other definition and strand their parked
      // instances with no remaining pause record to explain or release them.
      toDelete = [
        SELECT Id
        FROM Workflow_Pause_State__c
        WHERE Workflow_Name__c = :workflowName
        WITH SYSTEM_MODE
      ];
    }
    if (!toDelete.isEmpty()) {
      delete as system toDelete;
    }
    invalidateCache();

    // If an org-wide '*' pause is still in effect, a single-definition resume
    // cannot truly un-pause this definition — the wildcard still gates it, so any
    // instance flipped to Running would immediately re-park at the next handoff.
    // Leave its instances parked; they resume when the wildcard pause is lifted.
    if (workflowName != '*' && isDefinitionPaused(workflowName)) {
      WorkflowWatchdog.bootstrap();
      return;
    }

    // Drain parked instances in bounded chunks. A long-lived or org-wide pause
    // can park more than the 10k-row DML limit; flipping every row in one
    // transaction would fail and re-queue nothing. The first chunk runs
    // synchronously for a responsive operator action and any remainder is drained
    // by a chained Queueable (off the synchronous path, governor-safe).
    // resumeParkedChunk enqueues its own continuation (with a reserved queueable
    // slot) when more chunks remain, so no enqueue is needed here.
    resumeParkedChunk(workflowName);

    // Re-drive held sleeps/timeouts via watchdog
    WorkflowWatchdog.bootstrap();
  }

  // Flips up to RESUME_CHUNK_SIZE parked instances for the scope back to Running
  // and re-enqueues them (serial via bulk publish, parallel via branch fan-out).
  // Returns true if a full chunk was processed, meaning more may remain to drain.
  // Each call re-queries only still-Paused rows, so already-resumed instances
  // (now Running) are naturally excluded — no offset paging needed.
  private static Boolean resumeParkedChunk(String workflowName) {
    List<Workflow_Instance__c> parked;
    if (workflowName == '*') {
      parked = [
        SELECT Id, Current_Step__c, Status__c, Compensation_Stack__c
        FROM Workflow_Instance__c
        WHERE Status__c = 'Paused'
        WITH SYSTEM_MODE
        LIMIT :RESUME_CHUNK_SIZE
        FOR UPDATE
      ];
    } else {
      parked = [
        SELECT Id, Current_Step__c, Status__c, Compensation_Stack__c
        FROM Workflow_Instance__c
        WHERE Status__c = 'Paused' AND Workflow_Name__c = :workflowName
        WITH SYSTEM_MODE
        LIMIT :RESUME_CHUNK_SIZE
        FOR UPDATE
      ];
    }

    if (parked.isEmpty()) {
      return false;
    }

    List<Workflow_Instance__c> toUpdate = new List<Workflow_Instance__c>();
    List<Id> serialIds = new List<Id>();
    List<Workflow_Instance__c> parallelInsts = new List<Workflow_Instance__c>();

    for (Workflow_Instance__c inst : parked) {
      inst.Status__c = 'Running';
      toUpdate.add(inst);

      if (
        String.isNotBlank(inst.Current_Step__c) &&
        inst.Current_Step__c.contains(',')
      ) {
        parallelInsts.add(inst);
      } else {
        serialIds.add(inst.Id);
      }
    }
    update as system toUpdate;

    // Reserve the queueable slot for the next drain chunk BEFORE re-arming timeouts.
    // reArmTimeoutsForResume enqueues best-effort timeout queueables that can consume
    // every available slot; the drain is load-bearing (skipping it strands the parked
    // backlog), so it must claim its slot first. The timeout jobs that follow fall back
    // to System.schedule when no slot remains and retain their watchdog Timeout_At__c
    // safety net. Both callers (resumeDefinition and ResumeChunkQueueable) route the
    // continuation through here so the reservation is applied uniformly and guarded.
    Boolean moreRemain = parked.size() == RESUME_CHUNK_SIZE;
    if (
      moreRemain &&
      !Test.isRunningTest() &&
      Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()
    ) {
      System.enqueueJob(new ResumeChunkQueueable(workflowName));
    }

    // Re-arm step timeouts BEFORE enqueueing the resumed workers, so a delayed worker
    // (or a step that defers its pre-exec DML) still has an enforced watchdog deadline.
    WorkflowEngine.reArmTimeoutsForResume(toUpdate);

    if (!serialIds.isEmpty()) {
      WorkflowEngine.enqueueOrchestrators(serialIds);
    }
    if (!parallelInsts.isEmpty()) {
      enqueueResumeBulkParallel(parallelInsts);
    }

    return moreRemain;
  }

  // Drains the remaining parked-instance backlog for a resumed scope in chunks,
  // re-chaining until none remain. Kept off the synchronous resume path so a
  // large backlog cannot exceed governor limits in a single transaction.
  public class ResumeChunkQueueable implements Queueable {
    private final String workflowName;
    public ResumeChunkQueueable(String workflowName) {
      this.workflowName = workflowName;
    }
    public void execute(QueueableContext ctx) {
      // resumeParkedChunk chains the next continuation itself (reserving the single
      // queueable slot allowed in this context for the drain ahead of best-effort
      // timeout jobs), so no re-chain is needed here.
      resumeParkedChunk(this.workflowName);
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // INTERNAL HELPERS
  // ──────────────────────────────────────────────────────────────────────────

  // Lower-cases a name for case-insensitive matching ('*' is unchanged). Mirrors the
  // case-insensitive external id on Workflow_Pause_State__c.Workflow_Name__c.
  private static String normalize(String workflowName) {
    return workflowName == null ? null : workflowName.toLowerCase();
  }

  // Case-insensitive so a reserved engine workflow is never pausable regardless of the
  // casing the caller supplies.
  private static Boolean isReserved(String workflowName) {
    String lower = normalize(workflowName);
    for (String reserved : RESERVED_NAMES) {
      if (reserved.toLowerCase() == lower) {
        return true;
      }
    }
    return false;
  }

  private static void loadCache() {
    List<Workflow_Pause_State__c> records = [
      SELECT Workflow_Name__c
      FROM Workflow_Pause_State__c
      WITH SYSTEM_MODE
    ];
    cachedPausedNames = new Set<String>();
    for (Workflow_Pause_State__c r : records) {
      // Normalize for case-insensitive membership checks (the record keeps its
      // original-case Workflow_Name__c for display).
      cachedPausedNames.add(normalize(r.Workflow_Name__c));
    }
    cachedAnyPaused = !cachedPausedNames.isEmpty();
  }

  @TestVisible
  private static void invalidateCache() {
    cachedAnyPaused = null;
    cachedPausedNames = null;
  }

  // Fan-out a resume enqueue per unfinished parallel branch (mirrors the logic
  // in WorkflowEngine.enqueueResumeBulk but called from outside the engine).
  private static void enqueueResumeBulkParallel(
    List<Workflow_Instance__c> instances
  ) {
    List<Workflow_Event__e> events = new List<Workflow_Event__e>();
    Set<String> branchKeys = new Set<String>();

    // Current_Step__c retains every branch name until the join, including ones
    // whose step row is already Completed. Resolve the latest status per
    // (instance, branch) so completed branches are skipped — driving a no-op
    // worker per finished branch would waste the resume publish/DML budget and
    // could roll back the resume (mirrors WorkflowEngine.enqueueResumeBulk).
    Set<Id> instanceIds = new Set<Id>();
    Set<String> branchNames = new Set<String>();
    for (Workflow_Instance__c inst : instances) {
      instanceIds.add(inst.Id);
      for (String branch : inst.Current_Step__c.split(',')) {
        branchNames.add(branch.trim());
      }
    }
    Map<String, String> latestStatusByKey = new Map<String, String>();
    for (Workflow_Step_Execution__c se : [
      SELECT Workflow_Instance__c, Step_Name__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instanceIds
        AND Step_Name__c IN :branchNames
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      String statusKey = se.Workflow_Instance__c + '|' + se.Step_Name__c;
      if (!latestStatusByKey.containsKey(statusKey)) {
        latestStatusByKey.put(statusKey, se.Status__c);
      }
    }

    for (Workflow_Instance__c inst : instances) {
      List<String> branches = inst.Current_Step__c.split(',');
      for (String branch : branches) {
        String key = inst.Id + '|' + branch.trim();
        if (latestStatusByKey.get(key) == 'Completed') {
          continue; // branch already finished — no worker needed
        }
        if (!branchKeys.contains(key)) {
          branchKeys.add(key);
          if (!Test.isRunningTest()) {
            events.add(
              new Workflow_Event__e(
                Workflow_Instance_Id__c = inst.Id,
                Event_Type__c = 'RUN_STEP',
                Payload__c = branch.trim()
              )
            );
          } else {
            if (
              Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()
            ) {
              System.enqueueJob(
                new WorkflowOrchestrator(inst.Id, branch.trim())
              );
            }
          }
        }
      }
    }
    if (!events.isEmpty()) {
      List<Database.SaveResult> results = EventBus.publish(events);
      for (Database.SaveResult sr : results) {
        if (!sr.isSuccess()) {
          // A rejected branch event would leave that branch Running with no worker
          // to drive it. Surface the failure so the resume transaction rolls back
          // rather than silently stranding parked branches.
          String msg = (sr.getErrors() != null && !sr.getErrors().isEmpty())
            ? sr.getErrors()[0].getMessage()
            : 'unknown error';
          throw new PauseException(
            'Failed to publish resume event for a parallel branch: ' + msg
          );
        }
      }
    }
  }
}
