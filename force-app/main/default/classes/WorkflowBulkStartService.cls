/**
 * @description Bulk get-or-start pipeline (INV-3) for the workflow start
 * subsystem. Owns the exactly-once bulk admission sequence: decide per request
 * (dedup to an existing/intra-batch instance or queue a fresh insert), insert
 * fresh instances tolerating per-row DUPLICATE_VALUE from a concurrent winner,
 * resolve concurrent-loser keys to their winners, and assert every request
 * resolved (rolling back on a genuine failure). The mutable `StartOrGetRun`
 * accumulator is a private inner member so it is never publicized across class
 * boundaries; post-insert finalization and activation are delegated to
 * {@link WorkflowBulkStartFinalize} and {@link WorkflowBulkStartActivation} via
 * the specific collections they need. Extracted from `WorkflowStartService`;
 * `WorkflowStartService.startOrGetBulk`/`startBulk` are thin facades delegating
 * here. All DML and SOQL run in system mode with the original all-or-none
 * semantics preserved (no savepoints; the genuine-error path deletes siblings).
 */
public inherited sharing class WorkflowBulkStartService {
  // Mutable accumulator threaded through the startOrGet phase helpers so each
  // helper stays within the parameter and complexity budgets.
  private class StartOrGetRun {
    List<WorkflowEngine.StartRequest> requests;
    List<WorkflowEngine.StartResult> results;
    List<Workflow_Instance__c> toInsert;
    List<Integer> insertReqIndexes;
    List<Workflow_Instance__c> insertedInstances = new List<Workflow_Instance__c>();
    List<Integer> insertedReqIndexes = new List<Integer>();
    Set<String> concurrentLoserKeys = new Set<String>();
    Set<Id> parkedIds = new Set<Id>();
    Set<Id> deferTimeoutIds = new Set<Id>();
    List<Workflow_Instance__c> instancesToPark = new List<Workflow_Instance__c>();
  }

  /**
   * @description Bulk get-or-start pipeline (facade target for {@link
   * WorkflowStartService}). Returns a result per request (index-aligned)
   * reporting the resolved instance Id and whether it was newly created or
   * deduped.
   * @param requests the start requests to process
   * @return StartResults index-aligned with requests (null per null request)
   */
  public static List<WorkflowEngine.StartResult> startOrGetBulk(
    List<WorkflowEngine.StartRequest> requests
  ) {
    List<WorkflowEngine.StartResult> results = new List<WorkflowEngine.StartResult>();
    if (requests == null || requests.isEmpty()) {
      return results;
    }
    StartOrGetRun run = new StartOrGetRun();
    run.requests = requests;
    run.results = results;

    // 1. Validate and gather correlation keys, and pre-validate workflow names in bulk
    Set<String> correlationKeys = WorkflowStartValidation.validateAndPrevalidateStarts(
      requests
    );

    // 2. Pre-resolve existing instances within the dedup scope (keyed by the
    //    normalized correlation key to honor case-insensitive matching).
    Map<String, Workflow_Instance__c> existingByKey = WorkflowStartDedup.findExistingByKey(
      correlationKeys
    );

    // 3. Decide per request (preserving order): dedup to an existing instance,
    //    dedup to an intra-batch sibling, or build a fresh instance to insert.
    decideStartRequests(run, existingByKey);

    // 4. Insert fresh instances, tolerating per-row DUPLICATE_VALUE from a
    //    concurrent winner (the unique Active_Correlation_Key__c backstop).
    insertFreshInstances(run);
    WorkflowBulkStartFinalize.insertStartSearchAttributes(
      run.insertedInstances,
      run.insertedReqIndexes,
      run.requests
    );

    // 5. Build a key -> resolved Id map for newly inserted instances and for
    //    any concurrent winners, then fill remaining results and assert resolution.
    Map<String, Id> resolvedIdByKey = buildResolvedIdByKey(run);
    WorkflowBulkStartFinalize.fillRemainingStartResults(
      run.requests,
      run.results,
      resolvedIdByKey
    );
    assertAllStartsResolved(run);

    // 6. Resolve input payloads for newly inserted instances
    WorkflowBulkStartFinalize.resolveStartInputPayloads(
      run.insertedInstances,
      run.insertedReqIndexes,
      run.requests
    );

    // Operator pause gate and concurrency-bounded deferral (mirror doStart).
    WorkflowBulkStartActivation.applyStartPauseGate(
      run.insertedInstances,
      run.parkedIds,
      run.instancesToPark
    );
    WorkflowBulkStartActivation.applyStartConcurrencyGate(
      run.insertedInstances,
      run.parkedIds,
      run.deferTimeoutIds
    );

    // 7. Construct initial Step Execution logs for inserted instances only
    WorkflowBulkStartActivation.buildInitialStepExecs(
      run.insertedInstances,
      run.parkedIds,
      run.deferTimeoutIds
    );

    // Persist the parked status transition; parked instances are neither scheduled
    // nor enqueued — the resume path drives them when the definition is resumed.
    if (!run.instancesToPark.isEmpty()) {
      Database.update(run.instancesToPark, true, AccessLevel.SYSTEM_MODE);
    }

    // 8. Schedule timeout jobs and enqueue orchestrators for eligible instances.
    WorkflowBulkStartActivation.scheduleAndEnqueueStarts(
      run.insertedInstances,
      run.parkedIds,
      run.deferTimeoutIds
    );

    return results;
  }

  // §3: per request, dedup to an existing/intra-batch instance or queue a fresh
  // instance for insertion, populating run.toInsert / run.insertReqIndexes.
  private static void decideStartRequests(
    StartOrGetRun run,
    Map<String, Workflow_Instance__c> existingByKey
  ) {
    List<WorkflowEngine.StartRequest> requests = run.requests;
    List<WorkflowEngine.StartResult> results = run.results;
    for (Integer i = 0; i < requests.size(); i++) {
      results.add(null);
    }
    List<Workflow_Instance__c> toInsert = new List<Workflow_Instance__c>();
    List<Integer> insertReqIndexes = new List<Integer>();
    Set<String> newKeysInBatch = new Set<String>();

    for (Integer i = 0; i < requests.size(); i++) {
      WorkflowEngine.StartRequest req = requests[i];
      if (req == null) {
        continue;
      }
      String key = req.correlationKey;
      String normKey = WorkflowKeys.normalizeKey(key);

      if (String.isNotBlank(key) && existingByKey.containsKey(normKey)) {
        results[i] = new WorkflowEngine.StartResult(
          existingByKey.get(normKey).Id
        );
        continue;
      }
      if (String.isNotBlank(key) && newKeysInBatch.contains(normKey)) {
        // Intra-batch duplicate; resolved to the sibling's Id after insert.
        continue;
      }

      toInsert.add(WorkflowStartInstanceBuilder.buildInstance(req));
      insertReqIndexes.add(i);
      if (String.isNotBlank(key)) {
        newKeysInBatch.add(normKey);
      }
    }
    run.toInsert = toInsert;
    run.insertReqIndexes = insertReqIndexes;
  }

  // §4a: insert the fresh instances, resolving new results and tolerating
  // per-row DUPLICATE_VALUE losers; a genuine failure deletes siblings + throws.
  private static void insertFreshInstances(StartOrGetRun run) {
    List<Workflow_Instance__c> toInsert = run.toInsert;
    if (toInsert.isEmpty()) {
      return;
    }
    Database.SaveResult[] saveResults = Database.insert(
      toInsert,
      false,
      AccessLevel.SYSTEM_MODE
    );
    String genuineError = null;
    for (Integer j = 0; j < saveResults.size(); j++) {
      String rowError = processStartInsertRow(run, saveResults[j], j);
      if (rowError != null && genuineError == null) {
        genuineError = rowError;
      }
    }
    // A genuine (non-duplicate) row failure restores all-or-none semantics:
    // delete every sibling row that succeeded in this partial insert (no
    // savepoint is spent on the all-success path) and surface the error so no
    // orphan Pending instances are left behind.
    if (genuineError != null) {
      if (!run.insertedInstances.isEmpty()) {
        Database.delete(run.insertedInstances, true, AccessLevel.SYSTEM_MODE);
      }
      throw new WorkflowEngine.WorkflowException(
        'Failed to start workflow: ' + genuineError
      );
    }
  }

  // Handle one insert save-result row: record a success/new result or a
  // concurrent DUPLICATE_VALUE loser key. Returns a genuine error message
  // (a non-duplicate failure, or a duplicate on a blank key) or null.
  private static String processStartInsertRow(
    StartOrGetRun run,
    Database.SaveResult sr,
    Integer j
  ) {
    Integer reqIdx = run.insertReqIndexes[j];
    if (sr.isSuccess()) {
      Workflow_Instance__c inst = run.toInsert[j];
      run.insertedInstances.add(inst);
      run.insertedReqIndexes.add(reqIdx);
      run.results[reqIdx] = new WorkflowEngine.StartResult(inst.Id).markNew();
      return null;
    }
    Boolean isDup = WorkflowStartService.isDuplicateSaveError(sr);
    String key = run.requests[reqIdx].correlationKey;
    if (isDup && String.isNotBlank(key)) {
      run.concurrentLoserKeys.add(key);
      return null;
    }
    return sr.getErrors()[0].getMessage();
  }

  // Build the normalized-key -> Id map from inserted instances and any
  // concurrent winners located for DUPLICATE_VALUE loser keys.
  private static Map<String, Id> buildResolvedIdByKey(StartOrGetRun run) {
    Map<String, Id> resolvedIdByKey = new Map<String, Id>();
    for (Integer j = 0; j < run.insertedInstances.size(); j++) {
      String key = run.requests[run.insertedReqIndexes[j]].correlationKey;
      if (String.isNotBlank(key)) {
        resolvedIdByKey.put(
          WorkflowKeys.normalizeKey(key),
          run.insertedInstances[j].Id
        );
      }
    }
    if (!run.concurrentLoserKeys.isEmpty()) {
      Map<String, Workflow_Instance__c> winners = WorkflowStartDedup.findAnyByKey(
        run.concurrentLoserKeys
      );
      for (String normalized : winners.keySet()) {
        if (!resolvedIdByKey.containsKey(normalized)) {
          resolvedIdByKey.put(normalized, winners.get(normalized).Id);
        }
      }
    }
    return resolvedIdByKey;
  }

  // §5b safety net: a lingering unresolved (non-null) request would mean a
  // duplicate loser whose winner could not be found; roll back and surface it.
  private static void assertAllStartsResolved(StartOrGetRun run) {
    List<WorkflowEngine.StartRequest> requests = run.requests;
    List<WorkflowEngine.StartResult> results = run.results;
    List<String> unresolvedKeys = new List<String>();
    for (Integer i = 0; i < requests.size(); i++) {
      if (requests[i] == null) {
        continue;
      }
      if (results[i] == null) {
        unresolvedKeys.add(requests[i].correlationKey);
      }
    }

    if (unresolvedKeys.isEmpty()) {
      return;
    }
    if (!run.insertedInstances.isEmpty()) {
      Database.delete(run.insertedInstances, true, AccessLevel.SYSTEM_MODE);
    }
    throw new WorkflowEngine.WorkflowException(
      'Failed to resolve workflow start for correlation key(s): ' +
      String.join(unresolvedKeys, ', ')
    );
  }
}
