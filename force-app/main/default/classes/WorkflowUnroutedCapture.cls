/**
 * @description Captures signals that matched no active workflow instance as
 * Unrouted rows so they are never silently lost and can be re-delivered by an
 * operator once a matching instance becomes active. Splits the batch into
 * dedup-keyed rows (first-wins, unique Signal_Key__c) and unkeyed rows, then
 * inserts them under one savepoint: the keyed insert uses allOrNone=false so a
 * concurrent-duplicate loser is swallowed as a no-op, while a genuine
 * (non-duplicate) row error -- or a failure of the unkeyed insert -- rolls back
 * the already-captured rows before rethrowing, so a caller that retries the same
 * batch never sees a partial capture. All DML runs in system mode.
 */
public inherited sharing class WorkflowUnroutedCapture {
  /**
   * @description Captures the given unmatched signal requests as Unrouted rows.
   * Keyed rows dedup first-wins and use allOrNone=false so a concurrent
   * duplicate is a no-op; a genuine error (keyed or unkeyed) rolls the whole
   * capture back to the savepoint and rethrows. No-op when there is nothing to
   * capture.
   * @param unmatched the unmatched signal requests to capture (may be null/empty)
   */
  public static void captureUnroutedSignals(
    List<WorkflowEngine.SignalRequest> unmatched
  ) {
    if (unmatched == null || unmatched.isEmpty()) {
      return;
    }

    Map<String, Workflow_Signal__c> keyedRows = new Map<String, Workflow_Signal__c>();
    List<Workflow_Signal__c> unkeyedRows = new List<Workflow_Signal__c>();
    buildUnroutedSignalRows(unmatched, keyedRows, unkeyedRows);

    // A savepoint restores all-or-none semantics: the keyed insert uses
    // allOrNone=false so a concurrent-duplicate loser is swallowed as a no-op,
    // but a genuine (non-duplicate) row error — or a failure of the unkeyed
    // insert below — must roll back the already-captured rows before the method
    // throws. Otherwise a caller that catches the exception and retries the same
    // batch would treat the committed captures as duplicates while the rest of
    // the request never ran.
    if (keyedRows.isEmpty() && unkeyedRows.isEmpty()) {
      return;
    }
    Savepoint sp = Database.setSavepoint();

    if (!keyedRows.isEmpty()) {
      insertKeyedUnroutedSignals(keyedRows.values(), sp);
    }
    if (!unkeyedRows.isEmpty()) {
      try {
        Database.insert(unkeyedRows, true, AccessLevel.SYSTEM_MODE);
      } catch (Exception e) {
        Database.rollback(sp);
        throw e;
      }
    }
  }

  // Build the Unrouted signal rows, splitting them into dedup-keyed rows (kept
  // first-wins in a map) and unkeyed rows (a plain list). Mutates the two
  // supplied collections in place.
  private static void buildUnroutedSignalRows(
    List<WorkflowEngine.SignalRequest> unmatched,
    Map<String, Workflow_Signal__c> keyedRows,
    List<Workflow_Signal__c> unkeyedRows
  ) {
    for (WorkflowEngine.SignalRequest req : unmatched) {
      Workflow_Signal__c sig = new Workflow_Signal__c(
        Correlation_Key__c = req.keyOrId,
        Signal_Name__c = req.signalName,
        Payload__c = req.payload,
        Status__c = 'Unrouted'
      );
      String dedupVal;
      if (String.isNotBlank(req.idempotencyKey)) {
        // Retain the raw caller key so redeliverCapturedSignal can rewrite the
        // correlation-scoped capture key to the instance-scoped routed key once
        // a matching instance becomes active (closes the pre-arrival boundary).
        //
        // Known limitation (issue #48, "Out of Scope: retroactive dedup of
        // already-persisted signals"): if a keyed signal was already routed to an
        // instance that has since gone terminal, an at-least-once redelivery finds
        // no active match and is captured here under a correlation-scoped C: key.
        // That cannot collide with the original I:<instanceId> routed row, so the
        // duplicate persists as Unrouted and could be redelivered to a later
        // successor instance sharing the correlation key. Retiring such
        // post-terminal duplicates would require a dedup-window lookup of the
        // terminal instance plus a routed-row existence check on every keyed
        // capture; that retroactive dedup is intentionally deferred.
        sig.Idempotency_Key__c = req.idempotencyKey;
        dedupVal = WorkflowSignalDedup.deriveUnroutedDedupKey(
          req.keyOrId,
          req.idempotencyKey
        );
      } else {
        dedupVal = req.dedupKey;
      }
      if (String.isNotBlank(dedupVal)) {
        sig.Signal_Key__c = dedupVal;
        if (!keyedRows.containsKey(dedupVal)) {
          keyedRows.put(dedupVal, sig);
        }
      } else {
        unkeyedRows.add(sig);
      }
    }
  }

  // First-wins: insert (allOrNone=false) and swallow per-row DUPLICATE_VALUE so
  // a duplicate capture (same key, possibly different payload/name) is a no-op
  // against the already-captured row — matching the routed keyed path — rather
  // than overwriting it the way an upsert would. A genuine error rolls back to
  // the savepoint and surfaces.
  private static void insertKeyedUnroutedSignals(
    List<Workflow_Signal__c> keyedRows,
    Savepoint sp
  ) {
    Database.SaveResult[] srs = Database.insert(
      keyedRows,
      false,
      AccessLevel.SYSTEM_MODE
    );
    String genuineError = findGenuineSaveError(srs);
    if (genuineError != null) {
      Database.rollback(sp);
      throw new WorkflowEngine.WorkflowException(
        'Failed to capture unrouted signal: ' + genuineError
      );
    }
  }

  // Return the first non-DUPLICATE_VALUE row-error message across the save
  // results, or null when every failure was a swallowed duplicate.
  private static String findGenuineSaveError(Database.SaveResult[] srs) {
    for (Database.SaveResult sr : srs) {
      if (sr.isSuccess()) {
        continue;
      }
      Boolean isDup = false;
      for (Database.Error err : sr.getErrors()) {
        if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
          isDup = true;
          break;
        }
      }
      if (!isDup) {
        return sr.getErrors()[0].getMessage();
      }
    }
    return null;
  }
}
