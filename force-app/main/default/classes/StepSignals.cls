/**
 * @description Inbound-signal and child-outcome accessor for a single step
 * execution, split out of StepContext. Owns the claim/consume bookkeeping
 * (matched/claimed sets) that makes signal delivery effectively-once across
 * parallel branches, and exposes the author-facing signal reads. The lazy
 * pending-signal caches live on StepSignalState; the resolution logic lives on
 * StepSignalLoader / StepSignalLatest; child-outcome resolution lives on
 * StepChildOutcomes. Reached by step authors via StepContext.signals().
 * The Signal value type and SignalSource interface remain nested on StepContext.
 */
public inherited sharing class StepSignals {
  /** The lazy pending-signal cache state resolved by the loader/latest helpers. */
  private StepSignalState state;
  /** Child (sub-workflow) outcome resolver bound to this accessor. */
  private StepChildOutcomes childOutcomes;

  // Snapshot signals the step actually matched (saw a payload for). Only these
  // drive engine-managed consumption -- a name that was probed but found absent
  // must NOT consume a same-name signal that arrives later.
  /** Ids of snapshot signals the step actually matched. */
  private Set<Id> matchedSignalIds = new Set<Id>();
  /** Names of the signals the step actually matched. */
  private Set<String> matchedNames = new Set<String>();
  // Subset of matchedSignalIds the source actually CLAIMED (exclusive Processing
  // hold for this branch). Only these may be rolled back or consumed-while-
  // Processing; merely-observed rows must never disturb a sibling's claim.
  /** Ids the source actually CLAIMED for this branch. */
  private Set<Id> claimedSignalIds = new Set<Id>();

  /**
   * @description Constructs the signal accessor over a lazy signal source;
   * signals are not loaded until an accessor is actually called.
   * @param signalSource The SignalSource implementation, or null for none.
   */
  public StepSignals(StepContext.SignalSource signalSource) {
    this.state = new StepSignalState(signalSource);
    this.childOutcomes = new StepChildOutcomes(this);
  }

  /**
   * @description Supplies an explicit, already-resolved pending-signal list (used
   * by tests) instead of a lazy source, marking the full set loaded.
   * @param signals The pending signals to expose; never null.
   */
  public void seedPendingSignals(List<StepContext.Signal> signals) {
    this.state.allSignals = signals;
    this.state.allLoaded = true;
  }

  /**
   * @description Pre-loads the full pending set (without marking) so a bulk
   * child-outcome resolution avoids N+1 queries. Used by StepChildOutcomes.
   */
  public void preloadAll() {
    StepSignalLoader.loadAll(this.state);
  }

  /**
   * @description Returns the pending (unconsumed) signals targeting this
   * instance, in deterministic arrival order. Never null. Reading the full list
   * marks every pending signal observed, so the engine consumes them when the
   * step completes.
   *
   * Recommended primitive for inspecting MANY DISTINCT signal names inside a
   * parallel (scatter-gather) branch: call this once and filter the result in
   * memory. In a parallel branch each read atomically claims the signals it sees
   * (for exactly-once delivery across siblings); getSignals() claims the whole
   * pending page in a single DML statement and stays exactly-once, whereas a
   * per-name getSignal(name) / hasSignal(name) lookup for each name spends one
   * claim statement (and a FOR UPDATE lock query) apiece and, past the engine's
   * internal per-branch claim budget, degrades to at-least-once. See issue #38
   * and ParallelSignalFanInWorkflowExample.
   *
   * @return A cloned list of the pending signals, in arrival order; never null.
   */
  public List<StepContext.Signal> getSignals() {
    List<StepContext.Signal> all = StepSignalLoader.loadAll(this.state);
    for (StepContext.Signal s : all) {
      markMatched(s);
    }
    return all.clone();
  }

  /**
   * @description Returns the pending signals matching the given name, in arrival
   * order. Never null. Marks the name observed.
   * @param signalName The signal name to match.
   * @return A cloned list of matching pending signals, in arrival order.
   */
  public List<StepContext.Signal> getSignals(String signalName) {
    List<StepContext.Signal> matches = StepSignalLoader.matchesFor(
      this.state,
      signalName
    );
    for (StepContext.Signal s : matches) {
      markMatched(s);
    }
    return matches.clone();
  }

  /**
   * @description Returns the most recent (last-arriving) pending signal matching
   * the given name, or a clean empty result (isPresent() == false, payload ==
   * null) when none is pending. Never returns null. Marks the name observed.
   *
   * Inside a parallel branch this claims the matching signal for exactly-once
   * delivery, costing one claim DML statement (and a FOR UPDATE lock query). To
   * inspect MANY distinct names in one branch, prefer a single getSignals() and
   * filter in memory rather than a getSignal() per name (see issue #38): beyond
   * the engine's per-branch claim budget, overflow per-name reads degrade to
   * at-least-once.
   *
   * @param signalName The signal name to match.
   * @return The most-recent matching signal, or an empty (not-present) Signal
   * when none is pending; never null.
   */
  public StepContext.Signal getSignal(String signalName) {
    StepContext.Signal latest = StepSignalLatest.latestFor(
      this.state,
      signalName
    );
    if (latest == null) {
      return new StepContext.Signal();
    }
    markMatched(latest);
    return latest;
  }

  /**
   * @description True when at least one pending signal matches the given name.
   * Marks observed. Inside a parallel branch this claims the matching signal (one
   * claim DML statement); to probe MANY distinct names prefer a single
   * getSignals() and filter in memory rather than a hasSignal() per name (see
   * issue #38).
   * @param signalName The signal name to probe.
   * @return True if at least one pending signal matches the name.
   */
  public Boolean hasSignal(String signalName) {
    StepContext.Signal latest = StepSignalLatest.latestFor(
      this.state,
      signalName
    );
    if (latest == null) {
      return false;
    }
    markMatched(latest);
    return true;
  }

  /**
   * @description Ids of the snapshot signals the step actually matched (saw a
   * payload for), which the engine marks consumed at the COMPLETE transition.
   * @return A cloned set of the matched signal ids.
   */
  public Set<Id> getConsumedSignalIds() {
    return matchedSignalIds.clone();
  }

  /**
   * @description Names of the signals the step actually matched. The engine
   * re-queries still-Received signals filtered to these names at the step's
   * successful transition, so a same-name at-least-once duplicate delivered while
   * the step was executing is consumed too -- while a name that was only probed
   * absent never consumes a signal that arrives afterwards.
   * @return A cloned set of the matched signal names.
   */
  public Set<String> getConsumedSignalNames() {
    return matchedNames.clone();
  }

  /**
   * @description Ids the source actually CLAIMED for this branch (exclusive
   * Processing hold). The engine rolls back only these on a non-completing
   * transition, and may consume these while Processing -- merely-observed rows
   * (not in this set) are only consumed while still Received, so a branch never
   * disturbs a sibling's claim on a row it only read.
   * @return A cloned set of the claimed signal ids.
   */
  public Set<Id> getClaimedSignalIds() {
    return claimedSignalIds.clone();
  }

  /**
   * @description True when any signal read was truncated by a governor-safety
   * cap, so the step may not have seen every pending row of a name. The engine
   * then skips same-name duplicate cleanup, which could otherwise consume backlog
   * rows the step never observed.
   * @return True if any signal read was truncated by a governor-safety cap.
   */
  public Boolean signalReadWasCapped() {
    return state.signalSource != null && state.signalSource.readWasCapped();
  }

  /**
   * @description Records a snapshot signal the step matched, so consumption is
   * scoped to signals the step actually saw rather than every name it probed. A
   * claimed signal is additionally tracked so rollback/consume can target only
   * rows this branch exclusively owns. Public so StepChildOutcomes can mark the
   * child result signals it probes.
   * @param s The signal to mark matched, or null/nameless to ignore.
   */
  public void markMatched(StepContext.Signal s) {
    if (s == null || s.name == null) {
      return;
    }
    matchedNames.add(s.name);
    if (s.signalId == null) {
      return;
    }
    matchedSignalIds.add(s.signalId);
    if (s.isClaimed()) {
      claimedSignalIds.add(s.signalId);
    }
  }

  /**
   * @description Resolves the outcome of a single child (sub-workflow) by its key
   * from the pending ChildCompleted/ChildFailed signals.
   * @param childKey The child key to look up.
   * @return The child's outcome, or an empty (not-present) outcome when none is
   * pending.
   */
  public StepContext.ChildOutcome getChildOutcome(String childKey) {
    return childOutcomes.getChildOutcome(childKey);
  }

  /**
   * @description Resolves the outcomes of several children in one pass, bulk-
   * resolving their payloads to avoid N+1 signal queries.
   * @param childKeys The child keys to resolve, in order.
   * @return A list of outcomes aligned to childKeys; blank/unknown keys yield an
   * empty (not-present) outcome.
   */
  public List<StepContext.ChildOutcome> getChildOutcomes(
    List<String> childKeys
  ) {
    return childOutcomes.getChildOutcomes(childKeys);
  }
}
