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
  // Engine-internal workflow names that must never be paused.
  @TestVisible
  private static final Set<String> RESERVED_NAMES = new Set<String>{
    'WatchdogWorkflow',
    'CleanupWorkflow',
    'BulkRedriveWorkflow',
    'BulkCancelWorkflow'
  };

  // Transaction-scope cache: null = not yet loaded this tx
  private static Boolean cachedAnyPaused = null;
  private static Set<String> cachedPausedNames = null;

  /** @description Thrown when a pause/resume operation is invalid, e.g. a blank or reserved workflow name. */
  public class PauseException extends Exception {
  }

  // ──────────────────────────────────────────────────────────────────────────
  // FAST-PATH: any pause record exists at all?
  // Called on every runStep invocation; a false result short-circuits everything.
  // ──────────────────────────────────────────────────────────────────────────
  /**
   * @description Fast-path check for whether any pause record exists at all,
   * transaction-cached so runStep pays at most one SOQL per call stack.
   * @return True if at least one definition (or the wildcard) is paused.
   */
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
  /**
   * @description True when the named definition is paused, either by an explicit
   * pause record or by the org-wide wildcard. Reserved engine workflows are
   * never reported as paused.
   * @param workflowName The workflow definition name to check.
   * @return True if the definition is currently paused.
   */
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
  /**
   * @description True when an org-wide wildcard pause is in effect, so every
   * non-reserved definition is paused.
   * @return True if the '*' wildcard pause is active.
   */
  public static Boolean wildcardPaused() {
    if (cachedPausedNames == null) {
      loadCache();
    }
    return cachedPausedNames.contains('*');
  }

  // The set of explicitly paused definition names (excludes the '*' sentinel).
  // Used to exclude paused definitions from batch queries (e.g. the watchdog
  // resume batch) so they cannot starve resumable rows under a LIMIT.
  /**
   * @description The set of explicitly paused definition names, excluding the
   * wildcard sentinel, so callers can filter paused definitions out of batch
   * queries.
   * @return The explicitly paused definition names (normalized, without '*').
   */
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
  /**
   * @description Pauses a definition (or all definitions via '*') by upserting a
   * durable pause record. Idempotent, and rejects blank or reserved names.
   * @param workflowName The definition name to pause, or '*' for org-wide.
   * @param reason An operator-supplied reason recorded on the pause record.
   */
  public static void pauseDefinition(String workflowName, String reason) {
    if (String.isBlank(workflowName)) {
      throw new PauseException('workflowName must not be blank when pausing.');
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
  /**
   * @description Resumes a definition (or all via '*') by deleting its pause
   * record(s) and re-queueing every parked instance in bounded chunks, then
   * bootstrapping the watchdog so held sleeps/timeouts resume.
   * @param workflowName The definition name to resume, or '*' for org-wide.
   */
  public static void resumeDefinition(String workflowName) {
    if (String.isBlank(workflowName)) {
      throw new PauseException('workflowName must not be blank when resuming.');
    }

    // Delete pause records
    List<Workflow_Pause_State__c> toDelete;
    if (workflowName == '*') {
      // Org-wide resume: every pause record. Bounded by the SOQL row cap (the pause
      // table holds at most one row per paused definition plus the '*' sentinel, far
      // below it) so the LIMIT satisfies AvoidNonRestrictiveQueries while returning the
      // identical result set.
      toDelete = [
        SELECT Id
        FROM Workflow_Pause_State__c
        WITH SYSTEM_MODE
        LIMIT 50000
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
    WorkflowPauseResumeDrainer.resumeParkedChunk(workflowName);

    // Re-drive held sleeps/timeouts via watchdog
    WorkflowWatchdog.bootstrap();
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
    // Every pause record feeds the transaction cache. Bounded by the SOQL row cap (one
    // row per paused definition plus the '*' sentinel, far below it) so the LIMIT
    // satisfies AvoidNonRestrictiveQueries while returning the identical result set.
    List<Workflow_Pause_State__c> records = [
      SELECT Workflow_Name__c
      FROM Workflow_Pause_State__c
      WITH SYSTEM_MODE
      LIMIT 50000
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
}
