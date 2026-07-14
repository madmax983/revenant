/**
 * @description Full-set and per-name inbound-signal loading for a step execution,
 * split out of StepSignals. Resolves the lazy pending sets from the SignalSource
 * and merges back rows this branch already claimed (out of the source's Received
 * view) so the accessor's arrival-order and completeness contracts hold. Pure
 * logic over a StepSignalState; delegates case-insensitive filtering to
 * StepSignalLatest.
 */
public inherited sharing class StepSignalLoader {
  /**
   * @description Resolves the full pending set lazily so a step that never
   * touches signals pays no query/heap cost for unrelated unconsumed signals on
   * the instance.
   * @param st The shared signal cache state.
   * @return The full pending set, in arrival order; never null.
   */
  public static List<StepContext.Signal> loadAll(StepSignalState st) {
    if (st.allLoaded) {
      return st.allSignals;
    }
    List<StepContext.Signal> loaded = (st.signalSource != null)
      ? st.signalSource.getPendingSignals(null)
      : null;
    // Remember whether this full read was truncated, so named lookups don't
    // treat the partial page as the authoritative pending set.
    st.allReadCapped =
      (st.signalSource != null) && st.signalSource.readWasCapped();
    List<StepContext.Signal> all = (loaded != null)
      ? loaded
      : new List<StepContext.Signal>();
    // A parallel-branch source claims rows it returns (Received -> Processing),
    // so a row already claimed by an earlier named accessor is no longer in the
    // source's Received view. Merge those cached claims back in so the full
    // list stays consistent with everything this context has observed/claimed.
    Set<Id> present = collectPresentIds(all);
    mergeCachedClaimsInto(st, all, present);
    // Re-sort into arrival order: merged-in claims (out of the source's
    // Received view) must not simply trail the still-Received rows, which
    // would violate the accessor's arrival-order contract.
    all.sort();
    st.allSignals = all;
    st.allLoaded = true;
    return st.allSignals;
  }

  /**
   * @description Collects the non-null ids present in a signal list.
   * @param signals The signals to scan.
   * @return The set of present signal ids.
   */
  private static Set<Id> collectPresentIds(List<StepContext.Signal> signals) {
    Set<Id> present = new Set<Id>();
    for (StepContext.Signal s : signals) {
      if (s.signalId != null) {
        present.add(s.signalId);
      }
    }
    return present;
  }

  // Merges rows this branch already claimed (latest-per-name and named-list
  // caches) back into `all`, skipping ids already present. Mutates both args.
  private static void mergeCachedClaimsInto(
    StepSignalState st,
    List<StepContext.Signal> all,
    Set<Id> present
  ) {
    for (StepContext.Signal cached : st.latestByName.values()) {
      if (cached != null && cached.isPresent()) {
        addUnseen(all, present, cached);
      }
    }
    for (List<StepContext.Signal> cachedList : st.byNameCache.values()) {
      for (StepContext.Signal cached : cachedList) {
        addUnseen(all, present, cached);
      }
    }
  }

  /**
   * @description Appends a cached signal to `all` when its id is not already
   * present, tracking the id. Mutates both arguments.
   * @param all The accumulating signal list.
   * @param present The set of ids already present in `all`.
   * @param cached The cached signal to add when unseen.
   */
  private static void addUnseen(
    List<StepContext.Signal> all,
    Set<Id> present,
    StepContext.Signal cached
  ) {
    if (
      cached != null &&
      cached.signalId != null &&
      !present.contains(cached.signalId)
    ) {
      all.add(cached);
      present.add(cached.signalId);
    }
  }

  /**
   * @description Resolves just the signals matching a name. When the full set is
   * already loaded it filters in memory; otherwise it asks the source for only
   * that name (so a single named lookup never pulls every payload on the
   * instance) and caches the result for a consistent per-name view within this
   * execution.
   * @param st The shared signal cache state.
   * @param signalName The signal name to match.
   * @return The matching pending signals, cached per name.
   */
  public static List<StepContext.Signal> matchesFor(
    StepSignalState st,
    String signalName
  ) {
    // Signal_Name__c is required, so a blank named lookup matches nothing and
    // must never fall through to the unscoped (all-signals) query.
    if (String.isBlank(signalName)) {
      return new List<StepContext.Signal>();
    }
    // Only filter the in-memory full set when it is complete. A capped full
    // read holds a partial page, so a name beyond it would look absent; fall
    // through to the source's per-name accessor instead.
    if (st.allLoaded && !st.allReadCapped) {
      return StepSignalLatest.filterByName(st.allSignals, signalName);
    }
    String key = signalName.toLowerCase();
    if (!st.byNameCache.containsKey(key)) {
      st.byNameCache.put(key, loadNamedMatches(st, key, signalName));
    }
    return st.byNameCache.get(key);
  }

  // Loads the per-name matches from the source and merges back rows this branch
  // already claimed, so neither a guard-then-read pattern nor a capped full read
  // drops a matched payload from the named list.
  private static List<StepContext.Signal> loadNamedMatches(
    StepSignalState st,
    String key,
    String signalName
  ) {
    List<StepContext.Signal> loaded = (st.signalSource != null)
      ? st.signalSource.getPendingSignals(signalName)
      : null;
    // If the source truncated this read, the cached list is a partial (oldest)
    // page, so latestFor() must not treat its last row as the true latest.
    if (st.signalSource != null && st.signalSource.readWasCapped()) {
      st.partialNameKeys.add(key);
    }
    List<StepContext.Signal> matches = (loaded != null)
      ? loaded
      : new List<StepContext.Signal>();
    // Reclaim candidates: the per-name latest claimed by an earlier
    // getSignal/hasSignal, and matching rows from a capped full-set read
    // (reached here only when allReadCapped, since a complete full set returns
    // above).
    if (mergeReclaims(matches, reclaimCandidates(st, key, signalName))) {
      // Keep arrival order after merging the claimed rows back in.
      matches.sort();
    }
    return matches;
  }

  /**
   * @description Appends candidates not already present (by id) to `matches`.
   * @param matches The accumulating match list, mutated in place.
   * @param candidates The candidate rows to merge in.
   * @return True when at least one row was merged.
   */
  private static Boolean mergeReclaims(
    List<StepContext.Signal> matches,
    List<StepContext.Signal> candidates
  ) {
    Set<Id> present = collectPresentIds(matches);
    Boolean merged = false;
    for (StepContext.Signal s : candidates) {
      if (s.signalId != null && present.contains(s.signalId)) {
        continue;
      }
      matches.add(s);
      if (s.signalId != null) {
        present.add(s.signalId);
      }
      merged = true;
    }
    return merged;
  }

  /**
   * @description Collects rows this branch already claimed for a name: the cached
   * per-name latest and, when the full set is loaded, its matching rows.
   * @param st The shared signal cache state.
   * @param key The lower-cased name key.
   * @param signalName The signal name to match.
   * @return The reclaim candidate rows.
   */
  private static List<StepContext.Signal> reclaimCandidates(
    StepSignalState st,
    String key,
    String signalName
  ) {
    List<StepContext.Signal> reclaim = new List<StepContext.Signal>();
    StepContext.Signal cachedLatest = st.latestByName.get(key);
    if (cachedLatest != null && cachedLatest.isPresent()) {
      reclaim.add(cachedLatest);
    }
    if (st.allLoaded) {
      reclaim.addAll(StepSignalLatest.filterByName(st.allSignals, signalName));
    }
    return reclaim;
  }
}
