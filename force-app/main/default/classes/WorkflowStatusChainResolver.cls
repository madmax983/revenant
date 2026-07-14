/**
 * Resolves each WorkflowStatusInvocableAction request to its current workflow
 * instance: it picks a starting instance from the bulk direct-match index and then
 * forward-walks ContinuedAsNew chains so a lookup by correlation key reports the
 * live/terminal successor rather than a stale predecessor.
 *
 * Extracted from WorkflowStatusInvocableAction to keep the action's class-level
 * complexity within thresholds. It is strictly read-only: the only DML/SOQL it
 * performs is the bounded, bulk-safe successor query used to advance chains.
 */
public inherited sharing class WorkflowStatusChainResolver {
  // Statuses representing a workflow that is still live (not finished and not a
  // ContinuedAsNew hand-off). Used to prefer the current run when a non-unique
  // correlation key maps to several instances.
  private static final Set<String> ACTIVE_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended',
    'Compensating',
    'Cancelling'
  };

  // Upper bound on ContinuedAsNew links walked forward, bounding SOQL usage so a
  // pathological/cyclic chain cannot exhaust query governor limits.
  @TestVisible
  private static Integer maxChainDepth = 50;

  /**
   * @description Direct-match index from the action's bulk query: instances keyed by
   * Id and by (preferred) correlation key.
   */
  public class MatchIndex {
    /**
     * @description Matched instances indexed by their record Id.
     */
    public Map<Id, Workflow_Instance__c> byId = new Map<Id, Workflow_Instance__c>();

    /**
     * @description Matched instances indexed by their preferred correlation key.
     */
    public Map<String, Workflow_Instance__c> byKey = new Map<String, Workflow_Instance__c>();
  }

  /**
   * Resolves a starting instance per request (Id matches are precise handles; key
   * matches are walked forward through ContinuedAsNew) and returns the per-request
   * list after the chain walk, correspondingly ordered.
   *
   * @param reqIds The per-request parsed instance Ids (null where not id-shaped), in order.
   * @param reqKeys The per-request raw correlation keys (null where blank), in order.
   * @param index The direct-match index to resolve each request against.
   * @return The per-request resolved instances (null where unmatched), after the chain walk.
   */
  public static List<Workflow_Instance__c> resolveStartingInstances(
    List<Id> reqIds,
    List<String> reqKeys,
    MatchIndex index
  ) {
    List<Workflow_Instance__c> resolved = new List<Workflow_Instance__c>();
    List<Boolean> walkChain = new List<Boolean>();
    for (Integer i = 0; i < reqIds.size(); i++) {
      Workflow_Instance__c match = null;
      Boolean byKey = false;
      if (reqIds[i] != null) {
        match = index.byId.get(reqIds[i]);
      }
      if (match == null && reqKeys[i] != null) {
        match = index.byKey.get(reqKeys[i]);
        byKey = (match != null);
      }
      resolved.add(match);
      walkChain.add(byKey);
    }
    walkContinuedAsNewChains(resolved, walkChain);
    return resolved;
  }

  /**
   * Chooses the better of two instances sharing a correlation key: a live (active)
   * run wins over a finished/handed-off one; among equals, the most recently
   * created wins. This keeps getStatus reporting the current run when a key has
   * been reused across terminal runs or ContinuedAsNew generations.
   *
   * @param candidate The newly-seen instance sharing the correlation key.
   * @param existing The instance already indexed for that correlation key.
   * @return True when the candidate should replace the existing entry.
   */
  public static Boolean isPreferredCandidate(
    Workflow_Instance__c candidate,
    Workflow_Instance__c existing
  ) {
    Boolean candidateActive = ACTIVE_STATUSES.contains(candidate.Status__c);
    Boolean existingActive = ACTIVE_STATUSES.contains(existing.Status__c);
    if (candidateActive != existingActive) {
      return candidateActive;
    }
    return candidate.CreatedDate > existing.CreatedDate;
  }

  /**
   * Forward-walks ContinuedAsNew chains for key-resolved requests whose start instance
   * is still a predecessor. Same-key chains are already resolved to the live generation
   * by the active/latest preference; this walk covers chains whose successor took a
   * different key (e.g. the default `_runN` scheme). Bulk-safe: one SOQL per chain
   * generation, never per row. Bounded by maxChainDepth because SOQL limits make an
   * unbounded link-by-link walk impossible; if a (typically perpetual, different-key)
   * chain exceeds the bound we stop on the furthest generation reached, which is still
   * a ContinuedAsNew row and is therefore reported as non-terminal / non-success --
   * never as a false completed outcome.
   *
   * @param resolved The per-request resolved instances, advanced in place to successors.
   * @param walkChain Per-request flags marking which requests should be forward-walked.
   */
  private static void walkContinuedAsNewChains(
    List<Workflow_Instance__c> resolved,
    List<Boolean> walkChain
  ) {
    for (Integer depth = 0; depth < maxChainDepth; depth++) {
      if (!advanceChainGeneration(resolved, walkChain)) {
        break;
      }
    }
  }

  /**
   * Advances every still-predecessor request by one ContinuedAsNew generation using a
   * single query. Returns false when there is nothing left to advance (no predecessors
   * remain, or no successor was found), signalling the walk to stop.
   *
   * @param resolved The per-request resolved instances, advanced in place to successors.
   * @param walkChain Per-request flags marking which requests should be forward-walked.
   * @return True if any request advanced a generation, false when nothing remains to advance.
   */
  private static Boolean advanceChainGeneration(
    List<Workflow_Instance__c> resolved,
    List<Boolean> walkChain
  ) {
    Set<Id> predecessorIds = collectPredecessors(resolved, walkChain);
    if (predecessorIds.isEmpty()) {
      return false;
    }
    Map<Id, Workflow_Instance__c> successorByPrev = querySuccessors(
      predecessorIds
    );
    return applySuccessors(resolved, walkChain, successorByPrev);
  }

  /**
   * @description Collects the Ids of requests still sitting on a ContinuedAsNew predecessor.
   * @param resolved The per-request resolved instances to inspect.
   * @param walkChain Per-request flags marking which requests should be forward-walked.
   * @return The set of predecessor instance Ids to advance in the next generation.
   */
  private static Set<Id> collectPredecessors(
    List<Workflow_Instance__c> resolved,
    List<Boolean> walkChain
  ) {
    Set<Id> predecessorIds = new Set<Id>();
    for (Integer i = 0; i < resolved.size(); i++) {
      Workflow_Instance__c cur = resolved[i];
      if (walkChain[i] && cur != null && cur.Status__c == 'ContinuedAsNew') {
        predecessorIds.add(cur.Id);
      }
    }
    return predecessorIds;
  }

  /**
   * @description Runs one bulk query mapping each predecessor Id to its ContinuedAsNew successor.
   * @param predecessorIds The predecessor instance Ids whose successors are being sought.
   * @return A map from each predecessor Id to its successor instance.
   */
  private static Map<Id, Workflow_Instance__c> querySuccessors(
    Set<Id> predecessorIds
  ) {
    Map<Id, Workflow_Instance__c> successorByPrev = new Map<Id, Workflow_Instance__c>();
    for (Workflow_Instance__c succ : [
      SELECT
        Id,
        Status__c,
        Output__c,
        Error_Message__c,
        Correlation_Key__c,
        Previous_Instance__c,
        Progress__c,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c IN :predecessorIds
      WITH SYSTEM_MODE
    ]) {
      successorByPrev.put(succ.Previous_Instance__c, succ);
    }
    return successorByPrev;
  }

  /**
   * Replaces each still-predecessor request with its successor where one exists.
   * Returns true if any request advanced.
   *
   * @param resolved The per-request resolved instances, updated in place to successors.
   * @param walkChain Per-request flags marking which requests should be forward-walked.
   * @param successorByPrev The predecessor-to-successor map from the current generation query.
   * @return True if any request was advanced to a successor, otherwise false.
   */
  private static Boolean applySuccessors(
    List<Workflow_Instance__c> resolved,
    List<Boolean> walkChain,
    Map<Id, Workflow_Instance__c> successorByPrev
  ) {
    Boolean advanced = false;
    for (Integer i = 0; i < resolved.size(); i++) {
      Workflow_Instance__c cur = resolved[i];
      if (walkChain[i] && cur != null && cur.Status__c == 'ContinuedAsNew') {
        Workflow_Instance__c succ = successorByPrev.get(cur.Id);
        if (succ != null) {
          resolved[i] = succ;
          advanced = true;
        }
      }
    }
    return advanced;
  }
}
