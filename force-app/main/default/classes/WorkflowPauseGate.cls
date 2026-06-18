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
    return cachedPausedNames.contains(workflowName) ||
      cachedPausedNames.contains('*');
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
      toDelete = [
        SELECT Id
        FROM Workflow_Pause_State__c
        WHERE Workflow_Name__c = :workflowName OR Workflow_Name__c = '*'
        WITH SYSTEM_MODE
      ];
    }
    if (!toDelete.isEmpty()) {
      delete as system toDelete;
    }
    invalidateCache();

    // Find all Paused instances for the resumed scope
    List<Workflow_Instance__c> parked;
    if (workflowName == '*') {
      parked = [
        SELECT Id, Current_Step__c, Status__c
        FROM Workflow_Instance__c
        WHERE Status__c = 'Paused'
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
    } else {
      parked = [
        SELECT Id, Current_Step__c, Status__c
        FROM Workflow_Instance__c
        WHERE Status__c = 'Paused' AND Workflow_Name__c = :workflowName
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
    }

    if (parked.isEmpty()) {
      WorkflowWatchdog.bootstrap();
      return;
    }

    // Transition all parked instances back to Running
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

    // Re-enqueue: serial instances via bulk publish, parallel via branch fan-out
    if (!serialIds.isEmpty()) {
      WorkflowEngine.enqueueOrchestrators(serialIds);
    }
    if (!parallelInsts.isEmpty()) {
      enqueueResumeBulkParallel(parallelInsts);
    }

    // Re-drive held sleeps/timeouts via watchdog
    WorkflowWatchdog.bootstrap();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // INTERNAL HELPERS
  // ──────────────────────────────────────────────────────────────────────────

  private static Boolean isReserved(String workflowName) {
    return RESERVED_NAMES.contains(workflowName);
  }

  private static void loadCache() {
    List<Workflow_Pause_State__c> records = [
      SELECT Workflow_Name__c
      FROM Workflow_Pause_State__c
      WITH SYSTEM_MODE
    ];
    cachedPausedNames = new Set<String>();
    for (Workflow_Pause_State__c r : records) {
      cachedPausedNames.add(r.Workflow_Name__c);
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

    for (Workflow_Instance__c inst : instances) {
      List<String> branches = inst.Current_Step__c.split(',');
      for (String branch : branches) {
        String key = inst.Id + '|' + branch.trim();
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
      EventBus.publish(events);
    }
  }
}
