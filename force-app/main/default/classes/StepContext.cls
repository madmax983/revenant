public inherited sharing class StepContext {
  public Id workflowInstanceId { get; private set; }
  public String workflowName { get; private set; }
  public String stepName { get; private set; }
  public String inputJson { get; private set; }
  public String previousStepOutput { get; private set; }
  public String stepStateJson { get; private set; }
  public String workflowInputJson { get; private set; }
  public Integer workflowVersion { get; private set; }
  public Integer attempt { get; private set; }
  public Integer maxAttempts { get; private set; }

  public Boolean isFinalAttempt() {
    return this.attempt >= this.maxAttempts;
  }

  /**
   * Start time of the predecessor instance (its CreatedDate). Null for the
   * first instance in a chain or non-continuation contexts.
   *
   * Use as the polling cursor for incremental queries — query records modified
   * since the predecessor STARTED, not since it finished. This prevents a gap:
   * records modified during the predecessor's execution window are covered by
   * the successor's query. Near-boundary records may be processed by both runs
   * (bounded overlap), but nothing is ever skipped.
   *
   *   Datetime since = ctx.previousRunAt != null
   *       ? ctx.previousRunAt
   *       : Datetime.now().addHours(-24); // cold-start fallback
   *   [SELECT ... WHERE LastModifiedDate >= :since]
   *
   * Skip-free only when each run drains its ENTIRE window: capping the query
   * with a LIMIT lets this wall-clock cursor advance past the unprocessed tail
   * and starve it. If you must bound batch size, carry a data-derived
   * high-water mark (max processed timestamp) via ContinueAsNew instead.
   *
   * NOT a compensation primitive. It is populated in compensate() contexts only
   * for parity with execute(); a compensation must undo exactly what the forward
   * step did using that step's recorded input/output, never a re-scan since
   * previousRunAt (which can drift to records the forward run never touched).
   */
  public Datetime previousRunAt { get; private set; }

  // 0-based sequence of this visit to `stepName` within this instance: the count
  // of already-completed executions of the step when this context was built. It
  // stays constant across retries/re-drives/resumes of the current (not yet
  // completed) visit, and increments only when the engine loops back to the same
  // step for a fresh visit. Populated by the engine; defaults to 0.
  private Integer stepVisit = 0;
  private static Double cachedAsyncFraction = null;

  /**
   * A stable, read-only idempotency key for this logical step execution.
   *
   * The engine guarantees only at-least-once execution: execute() (and
   * compensate()) may run more than once for the same logical step on transient
   * RetryPolicy/WorkflowRetryJob retries, on operator re-drive, and on
   * at-least-once Workflow_Event__e resumes. Forward this key to a non-idempotent
   * external system (e.g. as a Stripe `Idempotency-Key` header) to get
   * effective-once side effects despite that contract.
   *
   * Guarantees:
   * - Stable across every re-execution of the same step VISIT: retries,
   *   re-drives, and resumes of the current (not-yet-completed) visit all observe
   *   the identical key. It is derived from `workflowInstanceId` + `stepName` +
   *   the visit sequence, never from the per-attempt, append-only
   *   Workflow_Step_Execution__c record Id.
   * - Distinct per (instance, step): different steps in one instance, the same
   *   step in two different instances, and the same step name across two parallel
   *   fan-out branch instances (different Parent_Instance__c, hence different
   *   `workflowInstanceId`) each observe a different key.
   * - Distinct per visit: when a workflow loops back to the same step in the same
   *   instance (the engine inserts a fresh execution for each transition), each
   *   completed visit observes a different key, so distinct side effects in
   *   loop/polling workflows are not wrongly deduped as retries.
   * - For compensate(), the engine builds the context with stepName
   *   "<step>_Compensate", so the compensation key is automatically stable for a
   *   given forward step yet distinct from that step's own forward key.
   */
  public String idempotencyKey {
    get {
      return deriveIdempotencyKey(
        this.workflowInstanceId,
        this.stepName,
        this.stepVisit
      );
    }
  }

  // True when this execution is the engine-routed timeout fallback (issue #35).
  // Set by the engine via withCapturedValues; false by default for all normal runs.
  private Boolean timeoutResume = false;

  public Boolean isTimeoutResume() {
    return timeoutResume == true;
  }

  @TestVisible
  private static Double mockQueryRowsFraction = null;
  @TestVisible
  private static Double mockAsyncExecutionsFraction = null;

  // Capture-once state. capturedValues is loaded from Captured_Values__c on
  // hydration and extended in-memory as once() is called. newCaptureKeys tracks
  // which keys were added THIS execution so the engine can persist only when
  // there is something new to write (avoids a no-op DML on every re-execution).
  private Map<String, Object> capturedValues = new Map<String, Object>();
  private Set<String> newCaptureKeys = new Set<String>();

  // Outbound domain events buffered via emit() during this execution (issue
  // #64). The engine publishes them effectively-once, coupled to the step's
  // COMPLETE/SPLIT transition commit; they are discarded (never published) on a
  // yield/retry/suspend/rollback because the buffer lives only on this in-memory
  // context, which is rebuilt fresh on every re-execution.
  private List<SObject> pendingEmits = new List<SObject>();

  // Progress snapshot state (issue #52). Set from within execute() or compensate()
  // via reportProgress(). Buffered in-memory and read by the engine/orchestrator
  // to persist onto Workflow_Instance__c.Progress__c at the transition checkpoint.
  private String progressJson = null;
  private Boolean progressReported = false;

  public void reportProgress(Decimal percentComplete, String message) {
    Map<String, Object> progressMap = new Map<String, Object>{
      'percentComplete' => percentComplete,
      'message' => message
    };
    reportProgress(progressMap);
  }

  public void reportProgress(Object progressData) {
    if (progressData == null) {
      this.progressJson = null;
    } else {
      this.progressJson = JSON.serialize(progressData);
    }
    this.progressReported = true;
  }

  public String getProgressJson() {
    return this.progressJson;
  }

  public Boolean isProgressReported() {
    return this.progressReported;
  }

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
      0
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
    Integer stepVisit
  ) {
    this.workflowInstanceId = workflowInstanceId;
    this.workflowName = workflowName;
    this.stepName = stepName;
    this.inputJson = inputJson;
    this.previousStepOutput = previousStepOutput;
    this.stepStateJson = stepStateJson;
    this.workflowInputJson = workflowInputJson;
    this.workflowVersion = workflowVersion;
    this.stepVisit = (stepVisit != null && stepVisit > 0) ? stepVisit : 0;
    this.attempt = 1;
    this.maxAttempts = 1;
  }

  /**
   * Explicit pending-signal list (used by tests): already resolved, so no lazy
   * source load is needed. stepVisit defaults to 0.
   */
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
    this(
      workflowInstanceId,
      workflowName,
      stepName,
      inputJson,
      previousStepOutput,
      stepStateJson,
      workflowInputJson,
      workflowVersion,
      0
    );
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
    this.attempt = 1;
    this.maxAttempts = 1;
  }

  /**
   * Full engine context: carries both the idempotency stepVisit and a lazy
   * SignalSource. Used by the engine when building execute()/compensate()
   * contexts so a step gets a stable idempotency key AND can read signals.
   */
  public StepContext(
    Id workflowInstanceId,
    String workflowName,
    String stepName,
    String inputJson,
    String previousStepOutput,
    String stepStateJson,
    String workflowInputJson,
    Integer workflowVersion,
    Integer stepVisit,
    SignalSource signalSource
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
      signalSource
    );
    this.stepVisit = (stepVisit != null && stepVisit > 0) ? stepVisit : 0;
  }

  /**
   * Full engine context with continuation metadata. Carries the stepVisit
   * sequence, a lazy SignalSource, and the previousRunAt timestamp for
   * ContinueAsNew chains (null for the first instance in a chain).
   */
  public StepContext(
    Id workflowInstanceId,
    String workflowName,
    String stepName,
    String inputJson,
    String previousStepOutput,
    String stepStateJson,
    String workflowInputJson,
    Integer workflowVersion,
    Integer stepVisit,
    SignalSource signalSource,
    Datetime previousRunAt
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
      stepVisit,
      signalSource
    );
    this.previousRunAt = previousRunAt;
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
      this.allReadCapped =
        (signalSource != null) && signalSource.readWasCapped();
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
      Set<Id> present = new Set<Id>();
      for (Signal s : matches) {
        if (s.signalId != null) {
          present.add(s.signalId);
        }
      }
      // Merge back rows this branch already claimed out of the source's Received
      // view but still owns and has marked for consumption, so neither a
      // guard-then-read pattern nor a capped full read drops a matched payload
      // from the named list (otherwise the step could complete -- consuming the
      // ids -- without the named accessor ever returning them):
      //  - the per-name latest claimed by an earlier getSignal/hasSignal, and
      //  - matching rows from a capped full-set read (allSignals; reached here
      //    only when allReadCapped, since a complete full set returns above).
      List<Signal> reclaim = new List<Signal>();
      Signal cachedLatest = latestByName.get(key);
      if (cachedLatest != null && cachedLatest.isPresent()) {
        reclaim.add(cachedLatest);
      }
      if (allLoaded) {
        for (Signal s : allSignals) {
          if (s.name != null && s.name.equalsIgnoreCase(signalName)) {
            reclaim.add(s);
          }
        }
      }
      Boolean merged = false;
      for (Signal s : reclaim) {
        if (s.signalId != null && present.contains(s.signalId)) {
          continue;
        }
        matches.add(s);
        if (s.signalId != null) {
          present.add(s.signalId);
        }
        merged = true;
      }
      if (merged) {
        // Keep arrival order after merging the claimed rows back in.
        matches.sort();
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
    Signal sourceLatest = latestByName.get(key);

    // We only reach here when a read was capped (the full set is partial, or
    // this name's page was truncated). In a parallel branch a capped read has
    // already CLAIMED its rows (Received -> Processing), so the source's
    // getLatestSignal -- which sees only still-Received rows -- can miss them and
    // report a false absence, stranding a suspend-on-absent branch whose signal
    // is sitting in its own claimed page. Recover this branch's newest matching
    // cached row and return the later-arriving of it and the source result.
    Signal cachedLatest = newestCachedMatch(key, signalName);
    if (cachedLatest != null) {
      if (sourceLatest == null || !sourceLatest.isPresent()) {
        return cachedLatest;
      }
      // Compare on the full (CreatedDate, Id) order the source uses for "latest"
      // (ORDER BY CreatedDate DESC, Id DESC) via Signal.compareTo, not the
      // timestamp alone: bulk inserts routinely share a CreatedDate, and a
      // timestamp-only test would wrongly favor the cached row and return an
      // older payload than sourceLatest.
      Boolean cachedNewer = cachedLatest.compareTo(sourceLatest) > 0;
      return cachedNewer ? cachedLatest : sourceLatest;
    }
    return sourceLatest;
  }

  // Newest matching signal already in this execution's in-memory caches: the
  // (capped) full set if loaded, else the (capped) per-name page. Returns null
  // when neither holds the name. Used so a latest lookup never reports absence
  // for a name whose rows this branch already claimed out of the Received view.
  private Signal newestCachedMatch(String key, String signalName) {
    Signal newest = null;
    if (allLoaded) {
      // allSignals is in arrival order and includes rows this branch claimed
      // (loadAll merges them back), so the last match is the newest.
      for (Signal s : allSignals) {
        if (s.name != null && s.name.equalsIgnoreCase(signalName)) {
          newest = s;
        }
      }
    } else if (byNameCache.containsKey(key)) {
      List<Signal> cached = byNameCache.get(key);
      if (!cached.isEmpty()) {
        newest = cached[cached.size() - 1];
      }
    }
    return newest;
  }

  /**
   * Returns the pending (unconsumed) signals targeting this instance, in
   * deterministic arrival order. Never null. Reading the full list marks every
   * pending signal observed, so the engine consumes them when the step completes.
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
   *
   * Inside a parallel branch this claims the matching signal for exactly-once
   * delivery, costing one claim DML statement (and a FOR UPDATE lock query). To
   * inspect MANY distinct names in one branch, prefer a single getSignals() and
   * filter in memory rather than a getSignal() per name (see issue #38): beyond
   * the engine's per-branch claim budget, overflow per-name reads degrade to
   * at-least-once.
   */
  public Signal getSignal(String signalName) {
    Signal latest = latestFor(signalName);
    if (latest == null) {
      return new Signal();
    }
    markMatched(latest);
    return latest;
  }

  /**
   * True when at least one pending signal matches the given name. Marks observed.
   * Inside a parallel branch this claims the matching signal (one claim DML
   * statement); to probe MANY distinct names prefer a single getSignals() and
   * filter in memory rather than a hasSignal() per name (see issue #38).
   */
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
    Double asyncFraction = mockAsyncExecutionsFraction != null
      ? mockAsyncExecutionsFraction
      : cachedAsyncFraction;
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
          cachedAsyncFraction = asyncFraction;
        }
      }
    }
    if (asyncFraction != null && asyncFraction > 0.80) {
      return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Capture-once API (issue #44)
  // ---------------------------------------------------------------------------

  /**
   * Records a value the first time it is produced and returns that same value
   * on every subsequent re-execution of this logical step, without calling the
   * producer again.
   *
   * Use this to stabilize any locally generated non-deterministic value — a
   * generated reference number, a Crypto-random token, a random branch decision,
   * or a timestamp — so that retries, yield/resume cycles, at-least-once event
   * resumes, and operator re-drives all observe the identical value.
   *
   * Scoping mirrors idempotencyKey: distinct keys within one step are
   * independent; the same key in a different step, a different instance, or a
   * different parallel branch is a distinct capture.
   *
   * Return type — captures are JSON round-tripped for durability, so the value
   * returned is always the JSON-normalized form (the same whether freshly
   * produced or rehydrated from a prior run). Producers should therefore return
   * JSON-native values: String, Integer/Long/Decimal/Double, Boolean, or
   * Map/List of those. A native Date/Datetime/Blob comes back as its JSON String
   * form, NOT as the original type — capture a serialized representation instead
   * (e.g. `Datetime.now().getTime()` for an epoch-millis Long, or
   * `Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')` for an ISO string)
   * and rebuild the Datetime from it after the cast.
   *
   * Durability boundary — a capture becomes durable when the step next reaches a
   * checkpoint that commits its execution row (complete, yield, sleep, suspend,
   * or a graceful StepResult.retry). If execute() throws BEFORE returning a
   * StepResult, the transaction rolls back and any captures made in that attempt
   * are discarded, so the crash-driven re-run will re-produce them. This matches
   * the checkpoint-based model (cf. Temporal SideEffect, whose result is durable
   * only once the next command is recorded). To stabilize a value across a
   * throwing path, capture it and reach a checkpoint before the code that can
   * throw.
   *
   * @param key      Caller-supplied name, unique within this step execution.
   * @param producer Invoked at most once: only on the first call for this key.
   * @return The originally produced value in its JSON-normalized form.
   */
  public Object once(String key, CaptureProducer producer) {
    if (capturedValues.containsKey(key)) {
      return defensiveCopy(capturedValues.get(key));
    }
    Object raw = producer.produce();
    // JSON round-trip ensures the in-memory value is byte-identical to what
    // would be returned after serialize → store → deserialize on a later run.
    Object normalized = JSON.deserializeUntyped(JSON.serialize(raw));
    capturedValues.put(key, normalized);
    newCaptureKeys.add(key);
    return defensiveCopy(normalized);
  }

  /**
   * Returns a defensive copy of a captured value so caller-local mutations of a
   * returned Map/List cannot reach the canonical instance held in
   * capturedValues (which getCapturedValuesJson() serializes). Primitives are
   * immutable, so they are returned as-is to avoid needless allocation.
   */
  private Object defensiveCopy(Object value) {
    if (value instanceof Map<String, Object> || value instanceof List<Object>) {
      return JSON.deserializeUntyped(JSON.serialize(value));
    }
    return value;
  }

  /**
   * Returns a JSON serialization of all captured values accumulated during this
   * execution, or null if nothing was captured. Used by the engine to persist
   * captures to Workflow_Step_Execution__c.Captured_Values__c.
   */
  public String getCapturedValuesJson() {
    if (
      capturedValues.isEmpty() &&
      (this.maxAttempts == null ||
      this.maxAttempts <= 1)
    ) {
      return null;
    }
    Map<String, Object> toSerialize = new Map<String, Object>(capturedValues);
    if (this.maxAttempts != null && this.maxAttempts > 1) {
      toSerialize.put('__maxAttempts', this.maxAttempts);
    }
    return JSON.serialize(toSerialize);
  }

  /**
   * True when at least one new capture was added during this execution (i.e.
   * the engine needs to persist Captured_Values__c). False when the step only
   * read back prior captures without adding any new ones.
   */
  public Boolean hasNewCaptures() {
    return !newCaptureKeys.isEmpty();
  }

  // ---------------------------------------------------------------------------
  // Outbound emit API (issue #64)
  // ---------------------------------------------------------------------------

  /**
   * re-emits. Call it as many times as needed; events publish in arrival order
   * once the step completes.
   *
   * The author chooses the __e type and its fields; the engine imposes no
   * envelope. The emitted __e should use publishBehavior=PublishAfterCommit so a
   * rolled-back transition fires nothing. Delivery to subscribers stays
   * at-least-once — the guarantee is effectively-once publication at the
   * producer, so subscribers must remain idempotent. A null event is ignored.
   */
  public void emit(SObject event) {
    if (event != null) {
      this.pendingEmits.add(event);
    }
  }

  /**
   * The outbound events buffered via emit() during this execution, in arrival
   * order. Never null. The engine reads this at the step's COMPLETE/SPLIT
   * transition and publishes the union of these and any events passed to
   * StepResult.complete(next, output, events).
   */
  public List<SObject> getPendingEmits() {
    return this.pendingEmits.clone();
  }

  /**
   * Factory used by the engine to build a context pre-seeded with the durably
   * stored captures from a prior execution of this step. Authors never call this
   * directly; the engine passes the resolved Captured_Values__c payload here so
   * once() can replay prior values without invoking producers.
   *
   * Also exposed as @TestVisible for unit tests that need to simulate a
   * re-execution context with prior captures in place.
   */
  /**
   * Helper to parse captured values JSON string safely into a Map.
   * Catches parsing exceptions and handles malformed payloads defensively.
   */
  private static Map<String, Object> parseCaptures(String jsonStr) {
    if (String.isBlank(jsonStr)) {
      return new Map<String, Object>();
    }
    try {
      Object deserialized = JSON.deserializeUntyped(jsonStr);
      if (deserialized instanceof Map<String, Object>) {
        return (Map<String, Object>) deserialized;
      }
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'Failed to parse captured values JSON: ' + e.getMessage()
      );
    }
    return new Map<String, Object>();
  }

  @TestVisible
  public static StepContext withCapturedValues(
    Id workflowInstanceId,
    String workflowName,
    String stepName,
    String inputJson,
    String previousStepOutput,
    String stepStateJson,
    String workflowInputJson,
    Integer workflowVersion,
    Integer stepVisit,
    SignalSource signalSource,
    Datetime previousRunAt,
    String capturedValuesJson
  ) {
    Map<String, Object> capturedValuesMap = parseCaptures(capturedValuesJson);
    return withCapturedValuesMap(
      workflowInstanceId,
      workflowName,
      stepName,
      inputJson,
      previousStepOutput,
      stepStateJson,
      workflowInputJson,
      workflowVersion,
      stepVisit,
      signalSource,
      previousRunAt,
      capturedValuesMap,
      false,
      1,
      1
    );
  }

  @TestVisible
  public static StepContext withCapturedValues(
    Id workflowInstanceId,
    String workflowName,
    String stepName,
    String inputJson,
    String previousStepOutput,
    String stepStateJson,
    String workflowInputJson,
    Integer workflowVersion,
    Integer stepVisit,
    SignalSource signalSource,
    Datetime previousRunAt,
    String capturedValuesJson,
    Integer attempt,
    Integer maxAttempts
  ) {
    Map<String, Object> capturedValuesMap = parseCaptures(capturedValuesJson);
    return withCapturedValuesMap(
      workflowInstanceId,
      workflowName,
      stepName,
      inputJson,
      previousStepOutput,
      stepStateJson,
      workflowInputJson,
      workflowVersion,
      stepVisit,
      signalSource,
      previousRunAt,
      capturedValuesMap,
      false,
      attempt,
      maxAttempts
    );
  }

  @TestVisible
  public static StepContext withCapturedValues(
    Id workflowInstanceId,
    String workflowName,
    String stepName,
    String inputJson,
    String previousStepOutput,
    String stepStateJson,
    String workflowInputJson,
    Integer workflowVersion,
    Integer stepVisit,
    SignalSource signalSource,
    Datetime previousRunAt,
    String capturedValuesJson,
    Boolean timeoutResume
  ) {
    Map<String, Object> capturedValuesMap = parseCaptures(capturedValuesJson);
    return withCapturedValuesMap(
      workflowInstanceId,
      workflowName,
      stepName,
      inputJson,
      previousStepOutput,
      stepStateJson,
      workflowInputJson,
      workflowVersion,
      stepVisit,
      signalSource,
      previousRunAt,
      capturedValuesMap,
      timeoutResume,
      1,
      1
    );
  }

  @TestVisible
  public static StepContext withCapturedValues(
    Id workflowInstanceId,
    String workflowName,
    String stepName,
    String inputJson,
    String previousStepOutput,
    String stepStateJson,
    String workflowInputJson,
    Integer workflowVersion,
    Integer stepVisit,
    SignalSource signalSource,
    Datetime previousRunAt,
    String capturedValuesJson,
    Boolean timeoutResume,
    Integer attempt,
    Integer maxAttempts
  ) {
    Map<String, Object> capturedValuesMap = parseCaptures(capturedValuesJson);
    return withCapturedValuesMap(
      workflowInstanceId,
      workflowName,
      stepName,
      inputJson,
      previousStepOutput,
      stepStateJson,
      workflowInputJson,
      workflowVersion,
      stepVisit,
      signalSource,
      previousRunAt,
      capturedValuesMap,
      timeoutResume,
      attempt,
      maxAttempts
    );
  }

  /**
   * Optimized factory that accepts a pre-parsed map of captured values to avoid double deserialization.
   */
  @TestVisible
  public static StepContext withCapturedValuesMap(
    Id workflowInstanceId,
    String workflowName,
    String stepName,
    String inputJson,
    String previousStepOutput,
    String stepStateJson,
    String workflowInputJson,
    Integer workflowVersion,
    Integer stepVisit,
    SignalSource signalSource,
    Datetime previousRunAt,
    Map<String, Object> capturedValuesMap,
    Boolean timeoutResume,
    Integer attempt,
    Integer maxAttempts
  ) {
    StepContext ctx = new StepContext(
      workflowInstanceId,
      workflowName,
      stepName,
      inputJson,
      previousStepOutput,
      stepStateJson,
      workflowInputJson,
      workflowVersion,
      stepVisit,
      signalSource,
      previousRunAt
    );
    ctx.timeoutResume = (timeoutResume == true);
    if (attempt != null && attempt > 0) {
      ctx.attempt = attempt;
    }
    if (maxAttempts != null && maxAttempts > 0) {
      ctx.maxAttempts = maxAttempts;
    }
    if (capturedValuesMap != null) {
      ctx.capturedValues = capturedValuesMap;
      if (ctx.capturedValues.containsKey('__maxAttempts')) {
        try {
          ctx.maxAttempts = Integer.valueOf(
            ctx.capturedValues.get('__maxAttempts')
          );
        } catch (Exception e) {
          System.debug(
            LoggingLevel.WARN,
            'Failed to parse __maxAttempts: ' + e.getMessage()
          );
        }
        ctx.capturedValues.remove('__maxAttempts');
      }
    }
    return ctx;
  }

  /**
   * Optimized factory overload for the compensation path that accepts a pre-parsed map.
   */
  @TestVisible
  public static StepContext withCapturedValuesMap(
    Id workflowInstanceId,
    String workflowName,
    String stepName,
    String inputJson,
    String previousStepOutput,
    String stepStateJson,
    String workflowInputJson,
    Integer workflowVersion,
    Integer stepVisit,
    SignalSource signalSource,
    Datetime previousRunAt,
    Map<String, Object> capturedValuesMap,
    Integer attempt,
    Integer maxAttempts
  ) {
    return withCapturedValuesMap(
      workflowInstanceId,
      workflowName,
      stepName,
      inputJson,
      previousStepOutput,
      stepStateJson,
      workflowInputJson,
      workflowVersion,
      stepVisit,
      signalSource,
      previousRunAt,
      capturedValuesMap,
      false,
      attempt,
      maxAttempts
    );
  }

  /**
   * Derives the idempotency key from logical (instance, step, visit) identity
   * only. SHA-256 keeps it opaque, uniform-length, and safe to forward verbatim
   * as an external idempotency token.
   */
  private static String deriveIdempotencyKey(
    Id instanceId,
    String stepName,
    Integer stepVisit
  ) {
    String basis =
      (instanceId == null ? '' : String.valueOf(instanceId)) +
      '::' +
      (stepName == null ? '' : stepName) +
      '::' +
      String.valueOf(stepVisit == null ? 0 : stepVisit);
    Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(basis));
    return EncodingUtil.convertToHex(digest);
  }

  public class ChildOutcome {
    public String status { get; private set; }
    public String errorMessage { get; private set; }
    public String output { get; private set; }
    private Boolean present = false;

    public ChildOutcome() {
      this.present = false;
    }

    public ChildOutcome(String status, String errorMessage, String output) {
      this.status = status;
      this.errorMessage = errorMessage;
      this.output = output;
      this.present = true;
    }

    public Boolean isPresent() {
      return this.present;
    }

    public Boolean isSuccess() {
      return this.status == 'Completed';
    }
  }

  public ChildOutcome getChildOutcome(String childKey) {
    if (String.isBlank(childKey)) {
      return new ChildOutcome();
    }
    String completedName = 'ChildCompleted:' + childKey;
    String failedName = 'ChildFailed:' + childKey;

    Signal completedSig = this.getSignal(completedName);
    Signal failedSig = this.getSignal(failedName);

    if (completedSig.isPresent() || failedSig.isPresent()) {
      // Force both names to be registered in matchedNames so that any duplicate/delayed
      // sibling signals of either type are consumed/cleaned up by the engine.
      this.markMatched(new Signal(null, completedName, null));
      this.markMatched(new Signal(null, failedName, null));
    }

    if (completedSig.isPresent()) {
      return new ChildOutcome(
        'Completed',
        null,
        WorkflowEngine.resolvePayload(completedSig.payload)
      );
    }

    if (failedSig.isPresent()) {
      if (String.isNotBlank(failedSig.payload)) {
        try {
          Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(
            failedSig.payload
          );
          String status = data.get('status') != null
            ? String.valueOf(data.get('status'))
            : null;
          String errorMessage = data.get('errorMessage') != null
            ? String.valueOf(data.get('errorMessage'))
            : null;
          Object outputObj = data.get('output');
          String outputVal = null;
          if (outputObj != null) {
            if (outputObj instanceof String) {
              outputVal = WorkflowEngine.resolvePayload((String) outputObj);
            } else {
              outputVal = JSON.serialize(outputObj);
            }
          }
          return new ChildOutcome(status, errorMessage, outputVal);
        } catch (Exception ex) {
          return new ChildOutcome('Failed', failedSig.payload, null);
        }
      } else {
        return new ChildOutcome('Failed', null, null);
      }
    }

    return new ChildOutcome();
  }

  public List<ChildOutcome> getChildOutcomes(List<String> childKeys) {
    this.loadAll(); // Pre-load all pending signals to bulkify and avoid N+1 queries
    List<ChildOutcome> outcomes = new List<ChildOutcome>();
    if (childKeys != null) {
      for (String key : childKeys) {
        outcomes.add(this.getChildOutcome(key));
      }
    }
    return outcomes;
  }
}
