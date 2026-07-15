/**
 * @description Read API for the Revenant engine. Returns the current status and
 * rehydrated output for a workflow instance by Id or correlation key (single or
 * bulk), resolving key lookups to the winning generation via
 * {@link WorkflowStatusWinnerResolver} (preferring live/active runs and following
 * ContinuedAsNew chains) and projecting DTOs via {@link WorkflowStatusProjection}
 * (which rehydrates any offloaded `Output__c`). Read-only: a small constant number
 * of SOQL queries and zero DML. Extracted from `WorkflowEngine`; returns the
 * resident public DTO `WorkflowEngine.WorkflowStatus`.
 */
public inherited sharing class WorkflowStatusRead {
  // Terminal statuses for the read API. ContinuedAsNew is deliberately excluded
  // (it is a hand-off, not an outcome) and CompensationFailed is excluded
  // (it is non-terminal — the rollback can still be resumed/retried). Public so
  // the winner/chain resolvers, the projection layer, and the resident
  // signal-target check share one source of truth.
  public static final Set<String> TERMINAL_GETSTATUS_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled'
  };

  /**
   * Canonical form of a correlation key for in-memory dedup maps/sets.
   * Correlation_Key__c is case-insensitive (and the unique
   * Active_Correlation_Key__c index is too), but Apex Map/Set keys are
   * case-sensitive, so keys are lower-cased to match the database semantics.
   * @param key the raw correlation key
   * @return the lower-cased key, or null when the input is null
   */
  private static String normalizeKey(String key) {
    return key == null ? null : key.toLowerCase();
  }

  /**
   * Returns the current status and rehydrated output for a workflow instance by Id,
   * or null if no instance with that Id exists.
   * Costs at most 2 SOQL queries and zero DML.
   * @param instanceId Id of the workflow instance to read
   * @return the instance status DTO, or null when no such instance exists
   */
  public static WorkflowEngine.WorkflowStatus getStatus(Id instanceId) {
    List<WorkflowEngine.WorkflowStatus> results = getStatus(
      new List<Id>{ instanceId }
    );
    return results[0];
  }

  /**
   * Returns the current status and rehydrated output for a workflow instance by
   * correlation key (prefers a live/active run, and follows a continue-as-new chain
   * via its shared root key), or null if no matching instance exists. Blank/null key
   * returns null. Costs a small constant number of SOQL queries and zero DML.
   * @param correlationKey correlation key to resolve
   * @return the status DTO for the resolved instance, or null when none matches
   */
  public static WorkflowEngine.WorkflowStatus getStatus(String correlationKey) {
    List<WorkflowEngine.WorkflowStatus> results = getStatus(
      new List<String>{ correlationKey }
    );
    return results[0];
  }

  /**
   * Bulk variant — accepts a list of instance Ids and returns a correspondingly
   * ordered list of WorkflowStatus DTOs (null where an Id was not found).
   * Costs at most 2 SOQL queries total regardless of list size, and zero DML.
   * @param instanceIds instance Ids to read
   * @return status DTOs positionally aligned with instanceIds (null per missing Id)
   */
  public static List<WorkflowEngine.WorkflowStatus> getStatus(
    List<Id> instanceIds
  ) {
    List<WorkflowEngine.WorkflowStatus> out = new List<WorkflowEngine.WorkflowStatus>();
    if (instanceIds == null || instanceIds.isEmpty()) {
      return out;
    }

    Set<Id> lookupIds = new Set<Id>(instanceIds);
    Map<Id, Workflow_Instance__c> instById = new Map<Id, Workflow_Instance__c>();
    for (Workflow_Instance__c inst : [
      SELECT
        Id,
        Workflow_Name__c,
        Correlation_Key__c,
        Status__c,
        Error_Message__c,
        Output__c,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id IN :lookupIds
      WITH SYSTEM_MODE
    ]) {
      instById.put(inst.Id, inst);
    }

    // Bulk-resolve all offloaded outputs in a single ContentVersion query.
    Map<Id, String> resolvedOutputByDocId = WorkflowStatusProjection.bulkResolveOffloadedOutputs(
      instById.values()
    );

    for (Id reqId : instanceIds) {
      Workflow_Instance__c inst = instById.get(reqId);
      out.add(
        inst == null
          ? null
          : WorkflowStatusProjection.buildStatus(inst, resolvedOutputByDocId)
      );
    }
    return out;
  }

  /**
   * Normalizes the non-blank correlation keys for consistent in-memory bucketing.
   * Correlation key fields are case-insensitive in SOQL but Apex Set/Map lookups
   * are case-sensitive, so all bucketing is done on the normalized (lower-cased)
   * key to keep in-memory matching consistent with what the query returns.
   * @param correlationKeys the requested correlation keys
   * @return the set of normalized non-blank keys
   */
  private static Set<String> normalizeStatusKeys(List<String> correlationKeys) {
    Set<String> normalizedKeys = new Set<String>();
    for (String k : correlationKeys) {
      if (String.isNotBlank(k)) {
        normalizedKeys.add(normalizeKey(k));
      }
    }
    return normalizedKeys;
  }

  /**
   * Bulk variant — accepts a list of correlation keys and returns a correspondingly
   * ordered list of WorkflowStatus DTOs (null where no instance was found or the
   * key entry is blank). A live/active run is preferred over a terminal one when a
   * key maps to several rows; a ContinuedAsNew hand-off always loses to a real
   * generation of its chain. Lookup follows a continue-as-new chain via the shared
   * Root_Correlation_Key__c, so polling the original key — or any intermediate
   * successor key — resolves to the live/final generation.
   *
   * Winners are resolved from metadata only (Output__c is fetched solely for the
   * winners), per key (no single hot key can crowd out others or exhaust the heap).
   * Costs a small constant number of SOQL queries regardless of list size, and zero
   * DML. (The Id-based overloads remain bounded at <= 2 SOQL.)
   * @param correlationKeys correlation keys to resolve
   * @return status DTOs positionally aligned with correlationKeys (null per blank
   * or unmatched key)
   */
  public static List<WorkflowEngine.WorkflowStatus> getStatus(
    List<String> correlationKeys
  ) {
    List<WorkflowEngine.WorkflowStatus> out = new List<WorkflowEngine.WorkflowStatus>();
    if (correlationKeys == null || correlationKeys.isEmpty()) {
      return out;
    }

    Set<String> normalizedKeys = normalizeStatusKeys(correlationKeys);

    // Resolve the winning instance Id per requested key using metadata only (no
    // Output__c), so a hot key's many candidate rows can never load enough inline
    // payloads to exhaust the heap. Resolution is per-key bounded (no single key can
    // crowd out others) and follows ContinuedAsNew chains via the shared root key.
    Map<String, Id> winnerIdByKey = WorkflowStatusWinnerResolver.resolveWinnerIdByKey(
      normalizedKeys
    );

    // Fetch Output__c (and the remaining DTO fields) only for the winners, then
    // rehydrate any offloaded outputs in one ContentVersion query — the same bounded
    // tail used by the Id-based overload.
    Map<Id, Workflow_Instance__c> instById = WorkflowStatusProjection.queryWinnerInstances(
      new Set<Id>(winnerIdByKey.values())
    );

    Map<Id, String> resolvedOutputByDocId = WorkflowStatusProjection.bulkResolveOffloadedOutputs(
      instById.values()
    );

    for (String k : correlationKeys) {
      if (String.isBlank(k)) {
        out.add(null);
        continue;
      }
      Id winnerId = winnerIdByKey.get(normalizeKey(k));
      Workflow_Instance__c inst = winnerId == null
        ? null
        : instById.get(winnerId);
      out.add(
        inst == null
          ? null
          : WorkflowStatusProjection.buildStatus(inst, resolvedOutputByDocId)
      );
    }
    return out;
  }
}
