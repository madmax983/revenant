/**
 * @description Shared winner-selection helpers for the Revenant read API's
 * correlation-key resolution. Hosts the instance-preference comparator (which of
 * two candidates wins for the same key) and the unresolved-keys set-difference
 * helper, both used by {@link WorkflowStatusWinnerResolver} (direct key resolution)
 * and {@link WorkflowStatusChainWinner} (ContinuedAsNew chain-root resolution).
 * Extracted from `WorkflowEngine`; pure in-memory logic (no SOQL/DML).
 */
public inherited sharing class WorkflowStatusWinnerSupport {
  /**
   * @description Returns true if candidate should replace existing for the same
   * correlation key. A ContinuedAsNew row is a superseded hand-off, so any
   * non-hand-off generation of the chain wins over it (independent of timestamps);
   * otherwise an active run beats a terminal one, and among equals the more
   * recently created wins.
   * @param candidate the candidate instance
   * @param existing the incumbent best instance for the key
   * @return true when candidate is preferred over existing
   */
  public static Boolean isPreferredForGetStatus(
    Workflow_Instance__c candidate,
    Workflow_Instance__c existing
  ) {
    Boolean candidateHandoff = candidate.Status__c == 'ContinuedAsNew';
    Boolean existingHandoff = existing.Status__c == 'ContinuedAsNew';
    if (candidateHandoff != existingHandoff) {
      return !candidateHandoff;
    }
    Boolean candidateActive = WorkflowEngine.ACTIVE_STATUSES.contains(
      candidate.Status__c
    );
    Boolean existingActive = WorkflowEngine.ACTIVE_STATUSES.contains(
      existing.Status__c
    );
    if (candidateActive != existingActive) {
      return candidateActive;
    }
    return candidate.CreatedDate > existing.CreatedDate;
  }

  /**
   * @description Members of allKeys not yet resolved to a winner in the given map.
   * @param allKeys the full key set
   * @param resolved the map of already-resolved keys
   * @return the subset of allKeys absent from resolved
   */
  public static Set<String> unresolved(
    Set<String> allKeys,
    Map<String, Workflow_Instance__c> resolved
  ) {
    Set<String> remaining = new Set<String>();
    for (String k : allKeys) {
      if (!resolved.containsKey(k)) {
        remaining.add(k);
      }
    }
    return remaining;
  }
}
