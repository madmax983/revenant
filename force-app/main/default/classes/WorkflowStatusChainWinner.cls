/**
 * @description ContinuedAsNew chain-root winner resolution for the Revenant read
 * API. For each requested key whose direct winner is a ContinuedAsNew hand-off,
 * follows the chain forward via the shared `Root_Correlation_Key__c` to its
 * live/final successor: an active run if any, else the most-recent non-hand-off
 * terminal generation, else the most-recent row of any status. Per-root bounded so
 * a reused root cannot exhaust the SOQL row governor. Extracted from
 * `WorkflowEngine`; invoked by {@link WorkflowStatusWinnerResolver}, whose
 * preference comparator and unresolved-keys helper it reuses.
 *
 * Known limitation (by design — see README): the root key is shared by every
 * generation of a chain AND by any independent run that reuses the same correlation
 * key, so following a hand-off by root cannot distinguish the chain's own successor
 * from an unrelated run reusing that key.
 */
public inherited sharing class WorkflowStatusChainWinner {
  /**
   * Canonical form of a correlation key for in-memory dedup maps/sets.
   * @param key the raw correlation key
   * @return the lower-cased key, or null when the input is null
   */
  private static String normalizeKey(String key) {
    return key == null ? null : key.toLowerCase();
  }

  /**
   * @description Follows ContinuedAsNew hand-offs to their live/final successor
   * (phase 2). For each key whose direct winner is a ContinuedAsNew row, the chain
   * root is resolved (falling back to the predecessor's own key when its root is
   * blank) and, when a preferred successor is found, it replaces the winner. Mutates
   * bestByKey in place.
   * @param bestByKey the best-instance-per-key map to expand
   */
  public static void expandContinuedAsNewWinners(
    Map<String, Workflow_Instance__c> bestByKey
  ) {
    Map<String, String> rootByKey = new Map<String, String>();
    Set<String> expandRoots = new Set<String>();
    for (String reqKey : bestByKey.keySet()) {
      Workflow_Instance__c w = bestByKey.get(reqKey);
      if (w.Status__c == 'ContinuedAsNew') {
        // A continueAsNew successor inherits the predecessor's root, falling back to
        // the predecessor's own correlation key when the predecessor predates the
        // root default (blank root). Mirror that fallback so a rootless legacy
        // hand-off still expands to its successor (here reqKey == predecessor key).
        String root = String.isNotBlank(w.Root_Correlation_Key__c)
          ? normalizeKey(w.Root_Correlation_Key__c)
          : reqKey;
        rootByKey.put(reqKey, root);
        expandRoots.add(root);
      }
    }
    if (expandRoots.isEmpty()) {
      return;
    }
    Map<String, Workflow_Instance__c> winnerByRoot = resolveWinnersByRoot(
      expandRoots
    );
    for (String reqKey : rootByKey.keySet()) {
      Workflow_Instance__c cand = winnerByRoot.get(rootByKey.get(reqKey));
      if (
        cand != null &&
        WorkflowStatusWinnerSupport.isPreferredForGetStatus(
          cand,
          bestByKey.get(reqKey)
        )
      ) {
        bestByKey.put(reqKey, cand);
      }
    }
  }

  /**
   * Resolves the winning instance per chain root: an active run if any, else the
   * most-recent non-hand-off terminal generation, else the most-recent row of any
   * status. Per-root bounded so a reused root cannot exhaust the SOQL row governor.
   * @param roots normalized chain-root correlation keys to resolve
   * @return map of each root key to its winning instance record
   */
  private static Map<String, Workflow_Instance__c> resolveWinnersByRoot(
    Set<String> roots
  ) {
    Map<String, Workflow_Instance__c> winnerByRoot = new Map<String, Workflow_Instance__c>();
    addActiveWinners(roots, winnerByRoot);
    addTerminalGenerationWinners(
      WorkflowStatusWinnerSupport.unresolved(roots, winnerByRoot),
      winnerByRoot
    );
    addHandoffFallbackWinners(
      WorkflowStatusWinnerSupport.unresolved(roots, winnerByRoot),
      winnerByRoot
    );
    return winnerByRoot;
  }

  /**
   * Phase 1: buckets the active run per chain (bounded to ~one per chain by the
   * unique active-key index) into the winner map.
   * @param roots the chain-root keys to resolve
   * @param winnerByRoot the accumulating winner map
   */
  private static void addActiveWinners(
    Set<String> roots,
    Map<String, Workflow_Instance__c> winnerByRoot
  ) {
    for (Workflow_Instance__c inst : [
      SELECT
        Id,
        Status__c,
        CreatedDate,
        Active_Correlation_Key__c,
        Correlation_Key__c,
        Root_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        Root_Correlation_Key__c IN :roots
        AND Status__c IN :WorkflowEngine.ACTIVE_STATUSES
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
    ]) {
      putBestByRoot(
        winnerByRoot,
        normalizeKey(inst.Root_Correlation_Key__c),
        inst
      );
    }
  }

  /**
   * Phase 2: for roots with no active run, buckets the most-recent non-hand-off
   * terminal generation into the winner map.
   * @param remainingRoots roots left unresolved after the active phase
   * @param winnerByRoot the accumulating winner map
   */
  private static void addTerminalGenerationWinners(
    Set<String> remainingRoots,
    Map<String, Workflow_Instance__c> winnerByRoot
  ) {
    if (remainingRoots.isEmpty()) {
      return;
    }
    Map<String, Datetime> maxByRoot = new Map<String, Datetime>();
    Set<Datetime> maxTimes = new Set<Datetime>();
    for (AggregateResult ar : [
      SELECT Root_Correlation_Key__c root, MAX(CreatedDate) mc
      FROM Workflow_Instance__c
      WHERE
        Root_Correlation_Key__c IN :remainingRoots
        AND Status__c IN :WorkflowStatusRead.TERMINAL_GETSTATUS_STATUSES
      WITH SYSTEM_MODE
      GROUP BY Root_Correlation_Key__c
    ]) {
      Datetime mc = (Datetime) ar.get('mc');
      if (mc == null) {
        continue;
      }
      String nr = normalizeKey((String) ar.get('root'));
      Datetime existing = maxByRoot.get(nr);
      if (existing == null || mc > existing) {
        maxByRoot.put(nr, mc);
      }
      maxTimes.add(mc);
    }
    if (maxTimes.isEmpty()) {
      return;
    }
    for (Workflow_Instance__c inst : [
      SELECT
        Id,
        Status__c,
        CreatedDate,
        Active_Correlation_Key__c,
        Correlation_Key__c,
        Root_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        Root_Correlation_Key__c IN :remainingRoots
        AND Status__c IN :WorkflowStatusRead.TERMINAL_GETSTATUS_STATUSES
        AND CreatedDate IN :maxTimes
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
      LIMIT :WorkflowEngine.dedupLookupRowCap
    ]) {
      String r = normalizeKey(inst.Root_Correlation_Key__c);
      if (inst.CreatedDate == maxByRoot.get(r)) {
        putBestByRoot(winnerByRoot, r, inst);
      }
    }
  }

  /**
   * Phase 3: fallback for an all-hand-off chain — keeps the most-recent matched
   * row so the caller still sees the latest generation rather than null.
   * @param stuckRoots roots still unresolved after the terminal phase
   * @param winnerByRoot the accumulating winner map
   */
  private static void addHandoffFallbackWinners(
    Set<String> stuckRoots,
    Map<String, Workflow_Instance__c> winnerByRoot
  ) {
    if (stuckRoots.isEmpty()) {
      return;
    }
    for (Workflow_Instance__c inst : [
      SELECT
        Id,
        Status__c,
        CreatedDate,
        Active_Correlation_Key__c,
        Correlation_Key__c,
        Root_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Root_Correlation_Key__c IN :stuckRoots
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
      LIMIT :WorkflowEngine.dedupLookupRowCap
    ]) {
      putBestByRoot(
        winnerByRoot,
        normalizeKey(inst.Root_Correlation_Key__c),
        inst
      );
    }
  }

  // Keeps the best candidate per chain root using the getStatus preference.
  private static void putBestByRoot(
    Map<String, Workflow_Instance__c> winnerByRoot,
    String root,
    Workflow_Instance__c inst
  ) {
    if (root == null) {
      return;
    }
    Workflow_Instance__c existing = winnerByRoot.get(root);
    if (
      existing == null ||
      WorkflowStatusWinnerSupport.isPreferredForGetStatus(inst, existing)
    ) {
      winnerByRoot.put(root, inst);
    }
  }
}
