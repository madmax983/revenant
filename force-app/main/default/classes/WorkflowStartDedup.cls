/**
 * @description Correlation-key dedup query engine for the workflow start
 * subsystem (INV-2). Read-only SOQL helpers that resolve the get-or-start winner
 * for one or many correlation keys within the configured dedup window, shared by
 * both the scalar admission path ({@link WorkflowStartService}) and the bulk
 * pipeline ({@link WorkflowBulkStartService}). Extracted from
 * `WorkflowStartService` so the scalar and bulk sequences both call one cohesive
 * query unit. All queries run in system mode and deliberately take no `FOR
 * UPDATE` lock; the unique `Active_Correlation_Key__c` index is the hard
 * active/active backstop and terminal-window dedup is best-effort under
 * concurrency.
 */
public inherited sharing class WorkflowStartDedup {
  // Upper bound (~100 years) applied to the dedup window before it is subtracted
  // from "now", so a large/misconfigured Dedup_Window_Minutes__c cannot push the
  // computed lower bound outside Salesforce's valid DateTime range and fault
  // every start.
  private static final Integer MAX_DEDUP_WINDOW_MINUTES = 52560000;

  /**
   * @description Resolves the dedup-winner instance per key including
   * recently-terminal matches within the configured window (the get-or-start
   * default). Boolean-free public seam shared by the scalar admission path and
   * the bulk pipeline.
   * @param keys normalized correlation keys to resolve
   * @return map of normalized key to its dedup-winning instance
   */
  public static Map<String, Workflow_Instance__c> findExistingByKey(
    Set<String> keys
  ) {
    return resolveExistingByKey(keys, true);
  }

  /**
   * @description Resolves the dedup-winner instance per key considering active
   * instances only (never terminal). Boolean-free public seam used by the
   * singleton start path, which must always restart a dead terminal run.
   * @param keys normalized correlation keys to resolve
   * @return map of normalized key to its active dedup-winning instance
   */
  public static Map<String, Workflow_Instance__c> findActiveByKey(
    Set<String> keys
  ) {
    return resolveExistingByKey(keys, false);
  }

  /**
   * Fast path for a single requested key: one indexed LIMIT 1 query returns the
   * single most-relevant row (an active instance preferred via NULLS FIRST, else
   * the newest in-window terminal), bounding the row governor regardless of how
   * many historical terminal runs the key has.
   * @param keys the single-element requested key set
   * @param terminalEnabled when true, allow an in-window terminal instance to win
   * @return the (at most one) resolved key-to-instance mapping
   */
  private static Map<String, Workflow_Instance__c> findSingleKeyWinner(
    Set<String> keys,
    Boolean terminalEnabled
  ) {
    Map<String, Workflow_Instance__c> result = new Map<String, Workflow_Instance__c>();
    DateTime windowStart = terminalEnabled
      ? dedupWindowStart()
      : DateTime.now().addYears(1000);
    for (Workflow_Instance__c inst : [
      SELECT Id, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        Correlation_Key__c IN :keys
        AND (Status__c IN :WorkflowEngine.ACTIVE_STATUSES
        OR Terminal_At__c >= :windowStart)
      WITH SYSTEM_MODE
      ORDER BY Terminal_At__c DESC NULLS FIRST, CreatedDate DESC
      LIMIT 1
    ]) {
      result.put(WorkflowKeys.normalizeKey(inst.Correlation_Key__c), inst);
    }
    return result;
  }

  /**
   * Computes the maximum in-window Terminal_At__c per remaining key via an
   * aggregate (each grouped result counts as a single SOQL row, so a hot key
   * cannot exhaust the row limit), filling maxTimeByKey and returning the set of
   * distinct max timestamps for the follow-up bounded fetch.
   * @param remaining the keys still unresolved after the active-instance pass
   * @param windowStart the dedup-window lower bound
   * @param maxTimeByKey out: normalized key to its max Terminal_At__c
   * @return the distinct max timestamps across the remaining keys
   */
  private static Set<Datetime> computeMaxTerminalTimes(
    Set<String> remaining,
    DateTime windowStart,
    Map<String, Datetime> maxTimeByKey
  ) {
    Set<Datetime> maxTimes = new Set<Datetime>();
    for (AggregateResult ar : [
      SELECT Correlation_Key__c ck, MAX(Terminal_At__c) mt
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :remaining AND Terminal_At__c >= :windowStart
      WITH SYSTEM_MODE
      GROUP BY Correlation_Key__c
    ]) {
      Datetime mt = (Datetime) ar.get('mt');
      if (mt == null) {
        continue;
      }
      String n = WorkflowKeys.normalizeKey((String) ar.get('ck'));
      Datetime existing = maxTimeByKey.get(n);
      if (existing == null || mt > existing) {
        maxTimeByKey.put(n, mt);
      }
      maxTimes.add(mt);
    }
    return maxTimes;
  }

  /**
   * Bulk terminal pass (phase 2): resolves the most-recent in-window terminal
   * instance for each key not already resolved to an active instance. Mutates
   * result in place.
   * @param keys the full requested key set
   * @param result the accumulating key-to-instance map to extend
   */
  private static void resolveTerminalWinners(
    Set<String> keys,
    Map<String, Workflow_Instance__c> result
  ) {
    Set<String> remaining = new Set<String>();
    for (String k : keys) {
      if (!result.containsKey(WorkflowKeys.normalizeKey(k))) {
        remaining.add(k);
      }
    }
    if (remaining.isEmpty()) {
      return;
    }

    DateTime windowStart = dedupWindowStart();
    Map<String, Datetime> maxTimeByKey = new Map<String, Datetime>();
    Set<Datetime> maxTimes = computeMaxTerminalTimes(
      remaining,
      windowStart,
      maxTimeByKey
    );
    if (maxTimes.isEmpty()) {
      return;
    }

    for (Workflow_Instance__c inst : [
      SELECT Id, Correlation_Key__c, Terminal_At__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :remaining AND Terminal_At__c IN :maxTimes
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
    ]) {
      String n = WorkflowKeys.normalizeKey(inst.Correlation_Key__c);
      if (
        !result.containsKey(n) && inst.Terminal_At__c == maxTimeByKey.get(n)
      ) {
        result.put(n, inst);
      }
    }
  }

  /**
   * Resolves the dedup-winner instance for each correlation key: an active
   * instance if one exists, otherwise (when includeTerminal is true) the most
   * recent terminal instance that became terminal within the configured dedup
   * window. The returned map is keyed by the normalized correlation key.
   * @param keys normalized correlation keys to resolve
   * @param includeTerminal when true, allow a recently-terminal instance to win
   * @return map of normalized key to its dedup-winning instance
   */
  private static Map<String, Workflow_Instance__c> resolveExistingByKey(
    Set<String> keys,
    Boolean includeTerminal
  ) {
    Map<String, Workflow_Instance__c> result = new Map<String, Workflow_Instance__c>();
    if (keys == null || keys.isEmpty()) {
      return result;
    }
    Boolean terminalEnabled =
      includeTerminal &&
      WorkflowEngine.dedupWindowMinutes != null &&
      WorkflowEngine.dedupWindowMinutes > 0;

    // Fast path: a single key needs only the single most-relevant row. SOQL
    // equality is case-insensitive, so a stored "Foo" matches a requested "foo".
    if (keys.size() == 1) {
      return findSingleKeyWinner(keys, terminalEnabled);
    }

    // Bulk path: resolve each key independently so no single hot key can crowd
    // out another, and without reading every historical terminal row.
    // 1) Active instances — bounded to at most one per key by the unique
    //    Active_Correlation_Key__c index.
    for (Workflow_Instance__c inst : [
      SELECT Id, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        Correlation_Key__c IN :keys
        AND Status__c IN :WorkflowEngine.ACTIVE_STATUSES
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
    ]) {
      String n = WorkflowKeys.normalizeKey(inst.Correlation_Key__c);
      if (!result.containsKey(n)) {
        result.put(n, inst);
      }
    }
    if (!terminalEnabled) {
      return result;
    }

    // 2) Most-recent terminal per key not already resolved to an active instance.
    resolveTerminalWinners(keys, result);
    return result;
  }

  /**
   * Resolves the existing instance per key regardless of the dedup window,
   * preferring an active instance then the most recent terminal one. Used as the
   * post-DUPLICATE_VALUE concurrency backstop, where a sibling is known to exist
   * and the loser must always resolve to the winner per the get-or-start
   * contract (even if the winner completed mid-race, and even when the window is
   * disabled). Row-bounded for the same governor-safety reason as
   * findExistingByKey.
   * @param keys normalized correlation keys to resolve
   * @return map of normalized key to the preferred (active, else latest terminal)
   * instance
   */
  public static Map<String, Workflow_Instance__c> findAnyByKey(
    Set<String> keys
  ) {
    Map<String, Workflow_Instance__c> result = new Map<String, Workflow_Instance__c>();
    if (keys == null || keys.isEmpty()) {
      return result;
    }
    Integer rowLimit = keys.size() == 1 ? 1 : WorkflowEngine.dedupLookupRowCap;
    for (Workflow_Instance__c inst : [
      SELECT Id, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :keys
      WITH SYSTEM_MODE
      ORDER BY Terminal_At__c DESC NULLS FIRST, CreatedDate DESC
      LIMIT :rowLimit
    ]) {
      String normalized = WorkflowKeys.normalizeKey(inst.Correlation_Key__c);
      if (!result.containsKey(normalized)) {
        result.put(normalized, inst);
      }
    }
    return result;
  }

  /**
   * Lower bound for the terminal dedup window. When the window is at its
   * minimum (<= 0) a far-future sentinel is returned so no terminal instance
   * matches, preserving active-only dedup behavior. The window is clamped to a
   * safe maximum so a misconfigured value cannot underflow the valid DateTime
   * range.
   * @return the lower-bound timestamp for terminal dedup, or a far-future sentinel
   * when the window is disabled
   */
  private static DateTime dedupWindowStart() {
    if (
      WorkflowEngine.dedupWindowMinutes != null &&
      WorkflowEngine.dedupWindowMinutes > 0
    ) {
      Integer minutes = Math.min(
        WorkflowEngine.dedupWindowMinutes,
        MAX_DEDUP_WINDOW_MINUTES
      );
      return DateTime.now().addMinutes(-minutes);
    }
    return DateTime.now().addYears(1000);
  }
}
