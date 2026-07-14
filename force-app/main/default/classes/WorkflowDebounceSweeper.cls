/**
 * @description Sweeps due Debounce_State__c rows and fires their coalesced
 * workflow starts effectively-once: it bulk-starts the batch under a savepoint,
 * falls back to per-state individual starts on failure, and applies bounded
 * per-state retry with quarantine. Extracted from WorkflowDebouncer, which
 * retains the enqueue/upsert registration path and delegates sweeping here.
 */
public inherited sharing class WorkflowDebounceSweeper {
  /**
   * @description Mutable working set threaded through the sweep pipeline: the due
   * states being fired, their derived start requests, the sweep timestamp, and
   * the rows accumulated for deletion (fired) or update (retried).
   */
  private class SweepContext {
    /**
     * @description The due debounce states loaded for this sweep, index-aligned
     * with startRequests.
     */
    List<Debounce_State__c> dueStates;
    /**
     * @description The start requests derived from dueStates, index-aligned with
     * dueStates.
     */
    List<WorkflowEngine.StartRequest> startRequests;
    /**
     * @description The sweep timestamp used for retry backoff and quarantine math.
     */
    Datetime now;
    /**
     * @description States that fired successfully and should be deleted.
     */
    List<Debounce_State__c> toDelete = new List<Debounce_State__c>();
    /**
     * @description States that failed and should be updated with retry bookkeeping.
     */
    List<Debounce_State__c> toUpdate = new List<Debounce_State__c>();
  }

  /**
   * @description Sweeps and fires due debounce states, deleting them after
   * starting. Sole public entry point; the sweep timestamp is supplied by the
   * caller so the engine's mock clock remains authoritative.
   * @param now The sweep timestamp used to select due states and drive retry math.
   */
  public static void sweep(Datetime now) {
    List<Debounce_State__c> dueStates = loadDueStates(now);
    if (dueStates.isEmpty()) {
      return;
    }

    SweepContext ctx = new SweepContext();
    ctx.dueStates = dueStates;
    ctx.startRequests = buildStartRequests(dueStates);
    ctx.now = now;

    fireDueStates(ctx);
  }

  /**
   * @description Loads up to 100 due, non-exhausted debounce states ordered for
   * stable, deterministic firing.
   * @param now The cutoff timestamp; states with Fire_At__c at or before this fire.
   * @return The due debounce states, ordered by Fire_At__c then Id.
   */
  private static List<Debounce_State__c> loadDueStates(Datetime now) {
    return [
      SELECT
        Id,
        Workflow_Name__c,
        Correlation_Key__c,
        Input_Json__c,
        Attributes_Json__c,
        Causation_Id__c,
        Fire_At__c,
        Retry_Count__c,
        Error_Message__c
      FROM Debounce_State__c
      WHERE Fire_At__c <= :now AND (Retry_Count__c = NULL OR Retry_Count__c < 3)
      WITH SYSTEM_MODE
      ORDER BY Fire_At__c ASC, Id ASC
      LIMIT 100
    ];
  }

  /**
   * @description Builds the engine start requests for the due states, preserving
   * the stored JSON payloads verbatim to avoid re-serialization.
   * @param dueStates The due debounce states to convert.
   * @return The start requests, index-aligned with dueStates.
   */
  private static List<WorkflowEngine.StartRequest> buildStartRequests(
    List<Debounce_State__c> dueStates
  ) {
    List<WorkflowEngine.StartRequest> startRequests = new List<WorkflowEngine.StartRequest>();
    for (Debounce_State__c state : dueStates) {
      Map<String, String> attributes = WorkflowInvocableInputParser.parseAttributesJsonLenient(
        state.Attributes_Json__c
      );

      // Pass null to input since we set inputJson directly, saving CPU deserialization cycles.
      WorkflowEngine.StartRequest req = new WorkflowEngine.StartRequest(
          state.Workflow_Name__c,
          state.Correlation_Key__c,
          null
        )
        .withAttributes(attributes);
      req.inputJson = state.Input_Json__c;
      req.causationId = state.Causation_Id__c;
      startRequests.add(req);
    }
    return startRequests;
  }

  /**
   * @description Fires the due states as a single batch under a savepoint; on
   * failure rolls back and falls back to individual starts, then flushes the
   * accumulated deletes and updates.
   * @param ctx The sweep working set to fire and mutate.
   */
  private static void fireDueStates(SweepContext ctx) {
    Savepoint sp = Database.setSavepoint();
    try {
      WorkflowEngine.startOrGet(ctx.startRequests);
      ctx.toDelete.addAll(ctx.dueStates);
    } catch (Exception ex) {
      Database.rollback(sp);
      // Fallback: start them individually
      fireIndividually(ctx);
    } finally {
      if (!ctx.toDelete.isEmpty()) {
        delete as system ctx.toDelete;
      }
      if (!ctx.toUpdate.isEmpty()) {
        update as system ctx.toUpdate;
      }
    }
  }

  /**
   * @description Starts each due state on its own, halting before governor
   * limits, and routes each state to the delete or update bucket by outcome.
   * @param ctx The sweep working set to fire individually and mutate.
   */
  private static void fireIndividually(SweepContext ctx) {
    for (Integer i = 0; i < ctx.startRequests.size(); i++) {
      // Halt if approaching SOQL or DML limits to prevent uncatchable governor exceptions
      if (Limits.getQueries() >= 90 || Limits.getDmlStatements() >= 135) {
        break;
      }
      Debounce_State__c state = ctx.dueStates[i];
      if (startIndividual(ctx.startRequests[i], state, ctx.now)) {
        ctx.toDelete.add(state);
      } else {
        ctx.toUpdate.add(state);
      }
    }
  }

  /**
   * @description Starts a single request under a savepoint, recording retry
   * bookkeeping on the state and rolling back on failure.
   * @param req The start request to fire.
   * @param state The debounce state backing the request.
   * @param now The sweep timestamp used for retry backoff and quarantine math.
   * @return True if the start succeeded; false if it failed and was recorded for retry.
   */
  private static Boolean startIndividual(
    WorkflowEngine.StartRequest req,
    Debounce_State__c state,
    Datetime now
  ) {
    Savepoint individualSp = Database.setSavepoint();
    try {
      WorkflowEngine.startOrGet(new List<WorkflowEngine.StartRequest>{ req });
      return true;
    } catch (Exception innerEx) {
      Database.rollback(individualSp);
      recordRetry(state, innerEx, now);
      return false;
    }
  }

  /**
   * @description Applies bounded exponential-backoff retry bookkeeping to a
   * failed state: increments the retry count, stamps a (truncated) error
   * message, and either schedules the next attempt or quarantines the state.
   * @param state The failed debounce state to update in place.
   * @param innerEx The exception captured from the failed start.
   * @param now The sweep timestamp used for retry backoff and quarantine math.
   */
  private static void recordRetry(
    Debounce_State__c state,
    Exception innerEx,
    Datetime now
  ) {
    Integer currentRetries = state.Retry_Count__c == null
      ? 0
      : (Integer) state.Retry_Count__c;
    currentRetries++;
    state.Retry_Count__c = currentRetries;

    String errMsg = innerEx.getMessage();
    if (innerEx.getStackTraceString() != null) {
      errMsg += '\n' + innerEx.getStackTraceString();
    }
    if (errMsg.length() > 32768) {
      errMsg = errMsg.substring(0, 32768);
    }
    state.Error_Message__c = errMsg;

    if (currentRetries >= 3) {
      state.Fire_At__c = now.addYears(100); // Quarantine
    } else {
      // Exponential backoff retry in 1 or 2 minutes
      state.Fire_At__c = now.addSeconds(currentRetries * 60);
    }
  }
}
