/**
 * @description Direct correlation-key winner resolution for the Revenant read API.
 * Resolves the single winning `Workflow_Instance__c` Id for each requested
 * (normalized) correlation key by its OWN correlation/active key using metadata
 * only (never `Output__c`), bounded per key so a hot key reused across many
 * terminal runs cannot crowd out other keys or exhaust the SOQL row governor.
 * ContinuedAsNew hand-offs are then followed to their live/final successor via
 * {@link WorkflowStatusChainWinner}. Extracted from `WorkflowEngine`; consumed by
 * {@link WorkflowStatusRead}. All SOQL runs in system mode. The instance-preference
 * comparator and the "unresolved keys" helper are shared with
 * {@link WorkflowStatusChainWinner}.
 */
public inherited sharing class WorkflowStatusWinnerResolver {
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
   * Resolves the single winning Workflow_Instance__c Id for each requested
   * (normalized) correlation key, keyed by that normalized key. Loads only metadata
   * (never Output__c). Follows ContinuedAsNew chains via the shared
   * Root_Correlation_Key__c — which a before-insert trigger defaults to the
   * instance's own correlation key, so every row carries its chain root — letting a
   * lookup by the original key, or any intermediate successor key, resolve to the
   * live/final generation. Bounded per key so no single hot key (a correlation key
   * reused across many terminal runs) can crowd out other requested keys or exceed
   * the SOQL row governor.
   * @param normalizedKeys normalized (lower-cased) correlation keys to resolve
   * @return map of normalized key to the winning instance Id (keys with no match
   * are absent)
   */
  public static Map<String, Id> resolveWinnerIdByKey(
    Set<String> normalizedKeys
  ) {
    if (normalizedKeys == null || normalizedKeys.isEmpty()) {
      return new Map<String, Id>();
    }
    return normalizedKeys.size() == 1
      ? resolveSingleKeyWinner(new List<String>(normalizedKeys)[0])
      : resolveBulkKeyWinners(normalizedKeys);
  }

  /**
   * Fast path for a single requested key. One metadata query picks the winner; a
   * second runs only when that winner is a ContinuedAsNew hand-off reached via a
   * non-root key (i.e. the requested key is an intermediate generation), in which
   * case the live/final successor lives under the shared root key.
   * @param key the single normalized correlation key to resolve
   * @return a one-entry map of the key to its winning instance Id, or empty when
   * no instance matches
   */
  private static Map<String, Id> resolveSingleKeyWinner(String key) {
    Map<String, Id> winnerByKey = new Map<String, Id>();
    Set<String> single = new Set<String>{ key };
    Workflow_Instance__c winner = pickWinner(
      [
        SELECT
          Id,
          Status__c,
          CreatedDate,
          Active_Correlation_Key__c,
          Correlation_Key__c,
          Root_Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE
          Active_Correlation_Key__c IN :single
          OR Correlation_Key__c IN :single
          OR Root_Correlation_Key__c IN :single
        WITH SYSTEM_MODE
        ORDER BY
          Active_Correlation_Key__c NULLS LAST,
          Terminal_At__c DESC NULLS FIRST,
          CreatedDate DESC
        LIMIT :WorkflowEngine.dedupLookupRowCap
      ]
    );
    if (winner == null) {
      return winnerByKey;
    }

    // Follow the chain forward via its shared root. (Same root-reuse limitation as
    // resolveWinnersByRoot: if the root key was reused for an independent live run,
    // this can resolve to that run — see README.)
    String rootKey = String.isNotBlank(winner.Root_Correlation_Key__c)
      ? normalizeKey(winner.Root_Correlation_Key__c)
      : null;
    if (
      winner.Status__c == 'ContinuedAsNew' &&
      rootKey != null &&
      rootKey != key
    ) {
      Set<String> roots = new Set<String>{ rootKey };
      Workflow_Instance__c chainWinner = pickWinner(
        [
          SELECT
            Id,
            Status__c,
            CreatedDate,
            Active_Correlation_Key__c,
            Correlation_Key__c,
            Root_Correlation_Key__c
          FROM Workflow_Instance__c
          WHERE Root_Correlation_Key__c IN :roots
          WITH SYSTEM_MODE
          ORDER BY
            Active_Correlation_Key__c NULLS LAST,
            Terminal_At__c DESC NULLS FIRST,
            CreatedDate DESC
          LIMIT :WorkflowEngine.dedupLookupRowCap
        ]
      );
      if (
        chainWinner != null &&
        WorkflowStatusWinnerSupport.isPreferredForGetStatus(chainWinner, winner)
      ) {
        winner = chainWinner;
      }
    }

    winnerByKey.put(key, winner.Id);
    return winnerByKey;
  }

  /**
   * Bulk path. Each requested key is resolved by its OWN correlation/active key
   * (never by root), mirroring the start-path findExistingByKey machinery: an active
   * run if any, else the most-recent row by correlation key (an aggregate, so a hot
   * key reused across many terminal runs collapses to one group and cannot crowd out
   * other keys). Matching on the key itself — not on Root_Correlation_Key__c — means
   * a rootless legacy row is still found, and independent runs that merely share a
   * chain root are never conflated. The chain is then followed via the shared root
   * only for keys whose direct winner is a ContinuedAsNew hand-off, exactly as the
   * single-key fast path does, so bulk and single resolution stay consistent.
   * @param keys normalized correlation keys to resolve
   * @return map of each resolved key to its winning instance Id
   */
  private static Map<String, Id> resolveBulkKeyWinners(Set<String> keys) {
    Map<String, Workflow_Instance__c> bestByKey = new Map<String, Workflow_Instance__c>();

    // 1a) Active runs — the unique active-key index bounds this to ~one per key.
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
        (Active_Correlation_Key__c IN :keys
        OR Correlation_Key__c IN :keys)
        AND Status__c IN :WorkflowEngine.ACTIVE_STATUSES
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
    ]) {
      bucketByOwnKey(inst, keys, bestByKey);
    }

    // 1b) Keys with no active run → most-recent row by correlation key.
    resolveRemainingKeyWinners(keys, bestByKey);

    // 2) For keys whose direct winner is a ContinuedAsNew hand-off, follow the
    //    chain to its live/final successor via the shared root key.
    WorkflowStatusChainWinner.expandContinuedAsNewWinners(bestByKey);

    Map<String, Id> winnerByKey = new Map<String, Id>();
    for (String reqKey : bestByKey.keySet()) {
      winnerByKey.put(reqKey, bestByKey.get(reqKey).Id);
    }
    return winnerByKey;
  }

  /**
   * Resolves winners for keys with no active run (phase 1b): the most-recent row
   * by correlation key of any status (so a ContinuedAsNew hand-off is detected
   * for the chain expansion). An aggregate yields one MAX(CreatedDate) per key
   * (a hot key collapses to one group), then a bounded fetch resolves the Id(s)
   * at those timestamps. Mutates bestByKey in place.
   * @param keys the full requested key set (for own-key bucketing)
   * @param bestByKey the accumulating best-instance-per-key map to extend
   */
  private static void resolveRemainingKeyWinners(
    Set<String> keys,
    Map<String, Workflow_Instance__c> bestByKey
  ) {
    Set<String> remaining = WorkflowStatusWinnerSupport.unresolved(
      keys,
      bestByKey
    );
    if (remaining.isEmpty()) {
      return;
    }
    Map<String, Datetime> maxByKey = new Map<String, Datetime>();
    Set<Datetime> maxTimes = new Set<Datetime>();
    for (AggregateResult ar : [
      SELECT Correlation_Key__c ck, MAX(CreatedDate) mc
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :remaining
      WITH SYSTEM_MODE
      GROUP BY Correlation_Key__c
    ]) {
      Datetime mc = (Datetime) ar.get('mc');
      if (mc == null) {
        continue;
      }
      // Guard the put: a case-insensitive GROUP BY can yield separate groups for
      // case variants that normalize to the same key, so keep the latest.
      String nk = normalizeKey((String) ar.get('ck'));
      Datetime existing = maxByKey.get(nk);
      if (existing == null || mc > existing) {
        maxByKey.put(nk, mc);
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
      WHERE Correlation_Key__c IN :remaining AND CreatedDate IN :maxTimes
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
      LIMIT :WorkflowEngine.dedupLookupRowCap
    ]) {
      if (
        inst.CreatedDate == maxByKey.get(normalizeKey(inst.Correlation_Key__c))
      ) {
        bucketByOwnKey(inst, keys, bestByKey);
      }
    }
  }

  /**
   * @description Buckets a candidate under each requested key it carries via its own
   * correlation or active key (not its root), keeping the best per key via the
   * getStatus preference. Matching on the instance's own key avoids conflating
   * independent runs that share a chain root and still resolves rootless legacy rows.
   * @param inst the candidate instance
   * @param keys the requested key set
   * @param bestByKey the accumulating best-instance-per-key map to update
   */
  private static void bucketByOwnKey(
    Workflow_Instance__c inst,
    Set<String> keys,
    Map<String, Workflow_Instance__c> bestByKey
  ) {
    Set<String> own = new Set<String>();
    if (String.isNotBlank(inst.Correlation_Key__c)) {
      own.add(normalizeKey(inst.Correlation_Key__c));
    }
    if (String.isNotBlank(inst.Active_Correlation_Key__c)) {
      own.add(normalizeKey(inst.Active_Correlation_Key__c));
    }
    for (String k : own) {
      if (!keys.contains(k)) {
        continue;
      }
      Workflow_Instance__c existing = bestByKey.get(k);
      if (
        existing == null ||
        WorkflowStatusWinnerSupport.isPreferredForGetStatus(inst, existing)
      ) {
        bestByKey.put(k, inst);
      }
    }
  }

  // Picks the single best instance from a candidate list via the getStatus
  // preference (non-hand-off > active > most-recently created).
  private static Workflow_Instance__c pickWinner(
    List<Workflow_Instance__c> candidates
  ) {
    Workflow_Instance__c winner = null;
    for (Workflow_Instance__c inst : candidates) {
      if (
        winner == null ||
        WorkflowStatusWinnerSupport.isPreferredForGetStatus(inst, winner)
      ) {
        winner = inst;
      }
    }
    return winner;
  }
}
