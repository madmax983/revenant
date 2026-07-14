/**
 * @description Latest-signal resolution for a step execution, split out of
 * StepSignals. Resolves only the single most-recent signal matching a name --
 * loading just that one payload rather than every duplicate -- with the
 * capped-read fall-through and claim-reconcile logic that keeps a
 * suspend-on-absent branch from a false absence when its own claimed page hides
 * the row from the source's Received view. Pure logic over a StepSignalState.
 */
public inherited sharing class StepSignalLatest {
  /**
   * @description Resolves only the most-recent signal matching a name, loading
   * just that one payload rather than every duplicate. Reuses an already-loaded
   * full set or per-name list when available. Returns null when none matches.
   * @param st The shared signal cache state.
   * @param signalName The signal name to match.
   * @return The most-recent matching signal, or null when none matches.
   */
  public static StepContext.Signal latestFor(
    StepSignalState st,
    String signalName
  ) {
    if (String.isBlank(signalName)) {
      return null;
    }
    // Only trust the in-memory full set for the latest when it is complete. A
    // capped full read is a partial page, so its newest matching row may not be
    // the true latest (or the name may be missing entirely); fall through to the
    // source's getLatestSignal for the authoritative most-recent row.
    if (st.allLoaded && !st.allReadCapped) {
      return newestInList(st.allSignals, signalName);
    }
    String key = signalName.toLowerCase();
    // Only trust a cached per-name list for the latest when it is complete. A
    // truncated list (partialNameKeys) holds only the oldest page, so its last
    // element can be an older payload while newer Received rows go unread; fall
    // through to the source's getLatestSignal for the true most-recent row.
    if (st.byNameCache.containsKey(key) && !st.partialNameKeys.contains(key)) {
      List<StepContext.Signal> matches = st.byNameCache.get(key);
      return matches.isEmpty() ? null : matches[matches.size() - 1];
    }
    if (!st.latestByName.containsKey(key)) {
      st.latestByName.put(
        key,
        (st.signalSource != null)
          ? st.signalSource.getLatestSignal(signalName)
          : null
      );
    }
    return reconcileLatest(st, st.latestByName.get(key), signalName);
  }

  /**
   * @description Case-insensitive scan returning the last (newest,
   * arrival-ordered) match.
   * @param signals The signals to scan.
   * @param signalName The name to match.
   * @return The newest matching signal, or null when none matches.
   */
  public static StepContext.Signal newestInList(
    List<StepContext.Signal> signals,
    String signalName
  ) {
    StepContext.Signal latest = null;
    for (StepContext.Signal s : signals) {
      if (s.name != null && s.name.equalsIgnoreCase(signalName)) {
        latest = s;
      }
    }
    return latest;
  }

  // We only reach here when a read was capped (the full set is partial, or this
  // name's page was truncated). In a parallel branch a capped read has already
  // CLAIMED its rows (Received -> Processing), so the source's getLatestSignal --
  // which sees only still-Received rows -- can miss them and report a false
  // absence, stranding a suspend-on-absent branch whose signal is sitting in its
  // own claimed page. Recover this branch's newest matching cached row and
  // return the later-arriving of it and the source result.
  private static StepContext.Signal reconcileLatest(
    StepSignalState st,
    StepContext.Signal sourceLatest,
    String signalName
  ) {
    StepContext.Signal cachedLatest = newestCachedMatch(st, signalName);
    if (cachedLatest == null) {
      return sourceLatest;
    }
    if (sourceLatest == null || !sourceLatest.isPresent()) {
      return cachedLatest;
    }
    // Compare on the full (CreatedDate, Id) order the source uses for "latest"
    // (ORDER BY CreatedDate DESC, Id DESC) via Signal.compareTo, not the
    // timestamp alone: bulk inserts routinely share a CreatedDate, and a
    // timestamp-only test would wrongly favor the cached row and return an
    // older payload than sourceLatest.
    return cachedLatest.compareTo(sourceLatest) > 0
      ? cachedLatest
      : sourceLatest;
  }

  // Newest matching signal already in this execution's in-memory caches: the
  // (capped) full set if loaded, else the (capped) per-name page. Returns null
  // when neither holds the name. Used so a latest lookup never reports absence
  // for a name whose rows this branch already claimed out of the Received view.
  private static StepContext.Signal newestCachedMatch(
    StepSignalState st,
    String signalName
  ) {
    String key = signalName.toLowerCase();
    StepContext.Signal newest = null;
    if (st.allLoaded) {
      // allSignals is in arrival order and includes rows this branch claimed
      // (loadAll merges them back), so the last match is the newest.
      for (StepContext.Signal s : st.allSignals) {
        if (s.name != null && s.name.equalsIgnoreCase(signalName)) {
          newest = s;
        }
      }
    } else if (st.byNameCache.containsKey(key)) {
      List<StepContext.Signal> cached = st.byNameCache.get(key);
      if (!cached.isEmpty()) {
        newest = cached[cached.size() - 1];
      }
    }
    return newest;
  }

  /**
   * @description Case-insensitive filter matching the source SOQL (Text field
   * equality) and the lower-cased per-name caches; a case-only difference must
   * not make an already-delivered signal look absent.
   * @param signals The signals to filter.
   * @param signalName The name to match, case-insensitively.
   * @return The matching signals in the input order.
   */
  public static List<StepContext.Signal> filterByName(
    List<StepContext.Signal> signals,
    String signalName
  ) {
    List<StepContext.Signal> matches = new List<StepContext.Signal>();
    for (StepContext.Signal s : signals) {
      if (s.name != null && s.name.equalsIgnoreCase(signalName)) {
        matches.add(s);
      }
    }
    return matches;
  }
}
