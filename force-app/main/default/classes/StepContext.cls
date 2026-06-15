public inherited sharing class StepContext {
  public Id workflowInstanceId { get; set; }
  public String workflowName { get; set; }
  public String stepName { get; set; }
  public String inputJson { get; set; }
  public String previousStepOutput { get; set; }
  public String stepStateJson { get; set; }
  public String workflowInputJson { get; set; }
  public Integer workflowVersion { get; set; }

  @TestVisible
  private static Double mockQueryRowsFraction = null;
  @TestVisible
  private static Double mockAsyncExecutionsFraction = null;

  /**
   * Read-only view of an inbound signal that targets this workflow instance.
   * Carries the author-interpreted name and payload string; the internal record
   * id is exposed so the engine can tie consumption to the step's transition.
   */
  public class Signal implements Comparable {
    public Id signalId { get; private set; }
    public String name { get; private set; }
    public String payload { get; private set; }
    // Arrival timestamp (Workflow_Signal__c.CreatedDate). Used to keep merged
    // signal lists in deterministic arrival order even when a row was already
    // claimed out of a later re-query. Null for the empty sentinel and for
    // signals built from an explicit in-memory list (tests).
    public Datetime createdDate { get; private set; }
    // True when the source atomically CLAIMED this row (flipped it to an
    // exclusive Processing state for this branch), as opposed to merely reading
    // it while still Received. The engine uses this to roll back / consume only
    // rows this branch actually owns, never a sibling's claim.
    private Boolean claimed;
    private Boolean present;

    public Signal(Id signalId, String name, String payload) {
      this(signalId, name, payload, null, false);
    }

    public Signal(
      Id signalId,
      String name,
      String payload,
      Datetime createdDate
    ) {
      this(signalId, name, payload, createdDate, false);
    }

    public Signal(
      Id signalId,
      String name,
      String payload,
      Datetime createdDate,
      Boolean claimed
    ) {
      this.signalId = signalId;
      this.name = name;
      this.payload = payload;
      this.createdDate = createdDate;
      this.claimed = claimed;
      this.present = true;
    }

    private Signal() {
      this.present = false;
      this.claimed = false;
    }

    /** True when this represents a real pending signal (not the empty result). */
    public Boolean isPresent() {
      return present;
    }

    /** True when the engine holds an exclusive claim on this row for this branch. */
    public Boolean isClaimed() {
      return claimed;
    }

    // Orders by arrival (CreatedDate, then Id) so a merged list preserves the
    // engine's deterministic signal ordering. Nulls (in-memory signals) sort
    // first, then by id, which is a stable fallback when no timestamp is known.
    public Integer compareTo(Object other) {
      Signal o = (Signal) other;
      if (this.createdDate != o.createdDate) {
        if (this.createdDate == null) {
          return -1;
        }
        if (o.createdDate == null) {
          return 1;
        }
        return this.createdDate < o.createdDate ? -1 : 1;
      }
      String a = (this.signalId == null) ? '' : String.valueOf(this.signalId);
      String b = (o.signalId == null) ? '' : String.valueOf(o.signalId);
      return a.compareTo(b);
    }
  }

  /**
   * Supplies pending signals on demand so a step that never reads signals pays
   * no query/heap cost. A non-blank signalName lets a named accessor load (and
   * pay heap for) only that name's payloads instead of every pending signal on
   * the instance; a blank/null name requests the full set. getLatestSignal loads
   * only the single most-recent matching signal, so reading one decision does
   * not pull every duplicate payload. readWasCapped() reports whether any read
   * was truncated by a governor-safety cap, so consumption can avoid cleaning up
   * same-name rows that were never exposed to the step. Implemented by the
   * engine; resolved lazily on first signal access.
   */
  public interface SignalSource {
    List<Signal> getPendingSignals(String signalName);
    Signal getLatestSignal(String signalName);
    Boolean readWasCapped();
  }

  private SignalSource signalSource;
  // Full pending set, loaded lazily only when an unscoped accessor needs it.
  private List<Signal> allSignals;
  private Boolean allLoaded = false;
  // True when the unscoped full-list read was truncated by the source row cap.
  // The cached allSignals is then only a partial page, so named latest/list
  // lookups must NOT be answered from it (they could miss a pending row and
  // report a false absence) -- they fall through to the source instead.
  private Boolean allReadCapped = false;
  // Per-name full results, loaded lazily so a single named lookup does not pull
  // every pending signal/payload on the instance. Keyed by lower-cased name.
  private Map<String, List<Signal>> byNameCache = new Map<String, List<Signal>>();
  // Names whose byNameCache list the source truncated (row-budget cap). Such a
  // list is only the oldest page, so its last element is NOT necessarily the
  // most-recent pending signal: latestFor() must not satisfy a latest lookup
  // from it and instead asks the source for the true most-recent row.
  private Set<String> partialNameKeys = new Set<String>();
  // Per-name latest-only results for getSignal/hasSignal, so reading one
  // decision never loads every duplicate payload. Keyed by lower-cased name.
  private Map<String, Signal> latestByName = new Map<String, Signal>();
  // Snapshot signals the step actually matched (saw a payload for). Only these
  // drive engine-managed consumption -- a name that was probed but found absent
  // must NOT consume a same-name signal that arrives later.
  private Set<Id> matchedSignalIds = new Set<Id>();
  private Set<String> matchedNames = new Set<String>();
  // Subset of matchedSignalIds the source actually CLAIMED (exclusive Processing
  // hold for this branch). Only these may be rolled back or consumed-while-
  // Processing; merely-observed rows must never disturb a sibling's claim.
  private Set<Id> claimedSignalIds = new Set<Id>();

  public StepContext(
    Id workflowInstanceId,
    String workflowName,
    String stepName,
    String inputJson,
    String previousStepOutput,
    String stepStateJson,
    String workflowInputJson
  ) {
    this(
      workflowInstanceId,
      workflowName,
      stepName,
      inputJson,
      previousStepOutput,
      stepStateJson,
      workflowInputJson,
      1
    );
  }

  public StepContext(
    Id workflowInstanceId,
    String workflowName,
    String stepName,
    String inputJson,
    String previousStepOutput,
    String stepStateJson,
    String workflowInputJson,
    Integer workflowVersion
  ) {
    this(
      workflowInstanceId,
      workflowName,
      stepName,
      inputJson,
      previousStepOutput,
      stepStateJson,
      workflowInputJson,
      workflowVersion,
      (List<Signal>) null
    );
  }

  public StepContext(
    Id workflowInstanceId,
    String workflowName,
    String stepName,
    String inputJson,
    String previousStepOutput,
    String stepStateJson,
    String workflowInputJson,
    Integer workflowVersion,
    List<Signal> pendingSignals
  ) {
    this.workflowInstanceId = workflowInstanceId;
    this.workflowName = workflowName;
    this.stepName = stepName;
    this.inputJson = inputJson;
    this.previousStepOutput = previousStepOutput;
    this.stepStateJson = stepStateJson;
    this.workflowInputJson = workflowInputJson;
    this.workflowVersion = workflowVersion;
    // An explicit list is already resolved -- no lazy loading needed.
    this.allSignals = (pendingSignals != null)
      ? pendingSignals
      : new List<Signal>();
    this.allLoaded = true;
  }

  public StepContext(
    Id workflowInstanceId,
    String workflowName,
    String stepName,
    String inputJson,
    String previousStepOutput,
    String stepStateJson,
    String workflowInputJson,
    Integer workflowVersion,
    SignalSource signalSource
  ) {
    this.workflowInstanceId = workflowInstanceId;
    this.workflowName = workflowName;
    this.stepName = stepName;
    this.inputJson = inputJson;
    this.previousStepOutput = previousStepOutput;
    this.stepStateJson = stepStateJson;
    this.workflowInputJson = workflowInputJson;
    this.workflowVersion = workflowVersion;
    // Defer loading until a signal accessor is actually called.
    this.signalSource = signalSource;
  }

  // Resolves the full pending set lazily so a step that never touches signals
  // pays no query/heap cost for unrelated unconsumed signals on the instance.
  private List<Signal> loadAll() {
    if (!allLoaded) {
      List<Signal> loaded = (signalSource != null)
        ? signalSource.getPendingSignals(null)
        : null;
      // Remember whether this full read was truncated, so named lookups don't
      // treat the partial page as the authoritative pending set.
      this.allReadCapped = (signalSource != null) && signalSource.readWasCapped();
      List<Signal> all = (loaded != null) ? loaded : new List<Signal>();
      // A parallel-branch source claims rows it returns (Received -> Processing),
      // so a row already claimed by an earlier named accessor is no longer in the
      // source's Received view. Merge those cached claims back in so the full
      // list stays consistent with everything this context has observed/claimed.
      Set<Id> present = new Set<Id>();
      for (Signal s : all) {
        if (s.signalId != null) {
          present.add(s.signalId);
        }
      }
      for (Signal cached : latestByName.values()) {
        if (
          cached != null &&
          cached.isPresent() &&
          cached.signalId != null &&
          !present.contains(cached.signalId)
        ) {
          all.add(cached);
          present.add(cached.signalId);
        }
      }
      for (List<Signal> cachedList : byNameCache.values()) {
        for (Signal cached : cachedList) {
          if (
            cached != null &&
            cached.signalId != null &&
            !present.contains(cached.signalId)
          ) {
            all.add(cached);
            present.add(cached.signalId);
          }
        }
      }
      // Re-sort into arrival order: merged-in claims (out of the source's
      // Received view) must not simply trail the still-Received rows, which
      // would violate the accessor's arrival-order contract.
      all.sort();
      this.allSignals = all;
      this.allLoaded = true;
    }
    return this.allSignals;
  }

  // Resolves just the signals matching a name. When the full set is already
  // loaded it filters in memory; otherwise it asks the source for only that
  // name (so a single named lookup never pulls every payload on the instance)
  // and caches the result for a consistent per-name view within this execution.
  private List<Signal> matchesFor(String signalName) {
    // Signal_Name__c is required, so a blank named lookup matches nothing and
    // must never fall through to the unscoped (all-signals) query.
    if (String.isBlank(signalName)) {
      return new List<Signal>();
    }
    // Only filter the in-memory full set when it is complete. A capped full
    // read holds a partial page, so a name beyond it would look absent; fall
    // through to the source's per-name accessor instead.
    if (allLoaded && !allReadCapped) {
      List<Signal> matches = new List<Signal>();
      for (Signal s : allSignals) {
        // Case-insensitive to match the source SOQL (Text field equality) and
        // the lower-cased per-name caches; a case-only difference must not make
        // an already-delivered signal look absent.
        if (s.name != null && s.name.equalsIgnoreCase(signalName)) {
          matches.add(s);
        }
      }
      return matches;
    }
    String key = signalName.toLowerCase();
    if (!byNameCache.containsKey(key)) {
      List<Signal> loaded = (signalSource != null)
        ? signalSource.getPendingSignals(signalName)
        : null;
      // If the source truncated this read, the cached list is a partial (oldest)
      // page, so latestFor() must not treat its last row as the true latest.
      if (signalSource != null && signalSource.readWasCapped()) {
        partialNameKeys.add(key);
      }
      List<Signal> matches = (loaded != null) ? loaded : new List<Signal>();
      // A prior getSignal/hasSignal for this name may have already claimed the
      // latest matching row (flipping it out of the source's Received view in a
      // parallel branch), so merge that cached claim back in. Otherwise a
      // guard-then-read pattern (hasSignal/getSignal then getSignals(name)) would
      // omit the very payload it matched while still consuming it at COMPLETE.
      Signal cachedLatest = latestByName.get(key);
      if (cachedLatest != null && cachedLatest.isPresent()) {
        Boolean alreadyIn = false;
        for (Signal s : matches) {
          if (s.signalId != null && s.signalId == cachedLatest.signalId) {
            alreadyIn = true;
            break;
          }
        }
        if (!alreadyIn) {
          matches.add(cachedLatest);
          // Keep arrival order after merging the claimed latest back in.
          matches.sort();
        }
      }
      byNameCache.put(key, matches);
    }
    return byNameCache.get(key);
  }

  // Resolves only the most-recent signal matching a name, loading just that one
  // payload rather than every duplicate. Reuses an already-loaded full set or
  // per-name list when available. Returns null when none matches.
  private Signal latestFor(String signalName) {
    if (String.isBlank(signalName)) {
      return null;
    }
    // Only trust the in-memory full set for the latest when it is complete. A
    // capped full read is a partial page, so its newest matching row may not be
    // the true latest (or the name may be missing entirely); fall through to the
    // source's getLatestSignal for the authoritative most-recent row.
    if (allLoaded && !allReadCapped) {
      Signal latest = null;
      for (Signal s : allSignals) {
        // Case-insensitive, matching the source SOQL and lower-cased caches.
        if (s.name != null && s.name.equalsIgnoreCase(signalName)) {
          latest = s;
        }
      }
      return latest;
    }
    String key = signalName.toLowerCase();
    // Only trust a cached per-name list for the latest when it is complete. A
    // truncated list (partialNameKeys) holds only the oldest page, so its last
    // element can be an older payload while newer Received rows go unread; fall
    // through to the source's getLatestSignal for the true most-recent row.
    if (byNameCache.containsKey(key) && !partialNameKeys.contains(key)) {
      List<Signal> matches = byNameCache.get(key);
      return matches.isEmpty() ? null : matches[matches.size() - 1];
    }
    if (!latestByName.containsKey(key)) {
      latestByName.put(
        key,
        (signalSource != null) ? signalSource.getLatestSignal(signalName) : null
      );
    }
    return latestByName.get(key);
  }

  /**
   * Returns the pending (unconsumed) signals targeting this instance, in
   * deterministic arrival order. Never null. Reading the full list marks every
   * pending signal observed, so the engine consumes them when the step completes.
   */
  public List<Signal> getSignals() {
    List<Signal> all = loadAll();
    for (Signal s : all) {
      markMatched(s);
    }
    return all.clone();
  }

  /**
   * Returns the pending signals matching the given name, in arrival order.
   * Never null. Marks the name observed.
   */
  public List<Signal> getSignals(String signalName) {
    List<Signal> matches = matchesFor(signalName);
    for (Signal s : matches) {
      markMatched(s);
    }
    return matches.clone();
  }

  /**
   * Returns the most recent (last-arriving) pending signal matching the given
   * name, or a clean empty result (isPresent() == false, payload == null) when
   * none is pending. Never returns null. Marks the name observed.
   */
  public Signal getSignal(String signalName) {
    Signal latest = latestFor(signalName);
    if (latest == null) {
      return new Signal();
    }
    markMatched(latest);
    return latest;
  }

  /** True when at least one pending signal matches the given name. Marks observed. */
  public Boolean hasSignal(String signalName) {
    Signal latest = latestFor(signalName);
    if (latest == null) {
      return false;
    }
    markMatched(latest);
    return true;
  }

  /**
   * Ids of the pending signals the step observed during execution. The engine
   * marks these consumed at the step's successful (COMPLETE) transition. When a
   * name is observed, every pending signal of that name is included so that
   * at-least-once redelivered duplicates do not reappear to a later step.
   */
  /** Ids of the snapshot signals the step actually matched (saw a payload for). */
  public Set<Id> getConsumedSignalIds() {
    return matchedSignalIds.clone();
  }

  /**
   * Names of the signals the step actually matched. The engine re-queries
   * still-Received signals filtered to these names at the step's successful
   * transition, so a same-name at-least-once duplicate delivered while the step
   * was executing is consumed too -- while a name that was only probed absent
   * never consumes a signal that arrives afterwards.
   */
  public Set<String> getConsumedSignalNames() {
    return matchedNames.clone();
  }

  /**
   * Ids the source actually CLAIMED for this branch (exclusive Processing hold).
   * The engine rolls back only these on a non-completing transition, and may
   * consume these while Processing -- merely-observed rows (not in this set) are
   * only consumed while still Received, so a branch never disturbs a sibling's
   * claim on a row it only read.
   */
  public Set<Id> getClaimedSignalIds() {
    return claimedSignalIds.clone();
  }

  /**
   * True when any signal read was truncated by a governor-safety cap, so the
   * step may not have seen every pending row of a name. The engine then skips
   * same-name duplicate cleanup, which could otherwise consume backlog rows the
   * step never observed.
   */
  public Boolean signalReadWasCapped() {
    return signalSource != null && signalSource.readWasCapped();
  }

  // Records a snapshot signal the step matched, so consumption is scoped to
  // signals the step actually saw rather than every name it probed. A claimed
  // signal is additionally tracked so rollback/consume can target only rows this
  // branch exclusively owns.
  private void markMatched(Signal s) {
    if (s != null && s.name != null) {
      matchedNames.add(s.name);
      if (s.signalId != null) {
        matchedSignalIds.add(s.signalId);
        if (s.isClaimed()) {
          claimedSignalIds.add(s.signalId);
        }
      }
    }
  }

  /**
   * Checks if the current transaction is approaching governor limits.
   * Returns true if any monitored limit (CPU, SOQL, DML statements, DML rows, or Heap size) is > 80% consumed.
   */
  public Boolean shouldYield() {
    // CPU Time
    if (
      Limits.getLimitCpuTime() > 0 &&
      ((Double) Limits.getCpuTime() / Limits.getLimitCpuTime()) > 0.80
    ) {
      return true;
    }
    // SOQL Queries
    if (
      Limits.getLimitQueries() > 0 &&
      ((Double) Limits.getQueries() / Limits.getLimitQueries()) > 0.80
    ) {
      return true;
    }
    // SOQL Query Rows
    Double queryRowsFraction = mockQueryRowsFraction != null
      ? mockQueryRowsFraction
      : (Limits.getLimitQueryRows() > 0
          ? ((Double) Limits.getQueryRows() / Limits.getLimitQueryRows())
          : 0.0);
    if (queryRowsFraction > 0.80) {
      return true;
    }
    // DML Statements
    if (
      Limits.getLimitDmlStatements() > 0 &&
      ((Double) Limits.getDmlStatements() / Limits.getLimitDmlStatements()) >
      0.80
    ) {
      return true;
    }
    // DML Rows
    if (
      Limits.getLimitDmlRows() > 0 &&
      ((Double) Limits.getDmlRows() / Limits.getLimitDmlRows()) > 0.80
    ) {
      return true;
    }
    // Heap Size
    if (
      Limits.getLimitHeapSize() > 0 &&
      ((Double) Limits.getHeapSize() / Limits.getLimitHeapSize()) > 0.80
    ) {
      return true;
    }
    // Daily Async Apex Executions Limit (accounts for Beta Elastic Limits if enabled)
    Double asyncFraction = mockAsyncExecutionsFraction;
    if (asyncFraction == null) {
      Map<String, System.OrgLimit> limitsMap = System.OrgLimits.getMap();
      if (limitsMap.containsKey('DailyAsyncApexExecutions')) {
        System.OrgLimit dailyLimitObj = limitsMap.get(
          'DailyAsyncApexExecutions'
        );
        Integer limitValue = dailyLimitObj.getValue();
        Integer maxLimit = dailyLimitObj.getLimit();

        if (limitsMap.containsKey('DailyAsyncApexElasticExecutions')) {
          System.OrgLimit elasticLimitObj = limitsMap.get(
            'DailyAsyncApexElasticExecutions'
          );
          maxLimit = elasticLimitObj.getLimit();
        }

        if (maxLimit > 0) {
          asyncFraction = (Double) limitValue / maxLimit;
        }
      }
    }
    if (asyncFraction != null && asyncFraction > 0.80) {
      return true;
    }
    return false;
  }
}
