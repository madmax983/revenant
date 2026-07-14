/**
 * @description Shared mutable cache state for inbound-signal resolution, split
 * out of StepSignals so the resolution logic (StepSignalLoader / StepSignalLatest)
 * can operate on a single coherent state object rather than a long parameter
 * list. Holds only the lazy pending-signal caches; the claim/consume tracking
 * (matched/claimed sets) stays private on StepSignals. No logic lives here.
 */
public inherited sharing class StepSignalState {
  /** Supplies pending signals on demand; resolved lazily on first access. */
  public StepContext.SignalSource signalSource;
  /** The full pending set, loaded lazily when an unscoped accessor needs it. */
  public List<StepContext.Signal> allSignals;
  /** True once the full pending set has been resolved. */
  public Boolean allLoaded = false;
  /** True when the full-list read was truncated by the source row cap. */
  public Boolean allReadCapped = false;
  /** Per-name full results, keyed by lower-cased name. */
  public Map<String, List<StepContext.Signal>> byNameCache = new Map<String, List<StepContext.Signal>>();
  /** Names whose cached per-name list was truncated by the source row cap. */
  public Set<String> partialNameKeys = new Set<String>();
  /** Per-name latest-only results, keyed by lower-cased name. */
  public Map<String, StepContext.Signal> latestByName = new Map<String, StepContext.Signal>();

  /**
   * @description Constructs the signal cache state over a lazy signal source.
   * @param signalSource The SignalSource implementation, or null for none.
   */
  public StepSignalState(StepContext.SignalSource signalSource) {
    this.signalSource = signalSource;
  }
}
