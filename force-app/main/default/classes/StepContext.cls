public inherited sharing class StepContext {
  public static final Integer MAX_LOG_ENTRIES = 100;
  public static final Integer MAX_MESSAGE_LENGTH = 4000;
  public static final String LOG_TYPE_BREADCRUMB = 'StepBreadcrumb';

  private List<Breadcrumb> breadcrumbs = new List<Breadcrumb>();

  // 0-based sequence of this visit to `stepName` within this instance: the count
  // of already-completed executions of the step when this context was built. It
  // stays constant across retries/re-drives/resumes of the current (not yet
  // completed) visit, and increments only when the engine loops back to the same
  // step for a fresh visit. Populated by the engine; defaults to 0.
  private Integer stepVisit = 0;
  private static Double cachedAsyncFraction = null;

  // True when this execution is the engine-routed timeout fallback (issue #35).
  // Set by the engine via withCapturedValues; false by default for all normal runs.
  private Boolean timeoutResume = false;

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

  // Named change marker (patch) state (issue #130)
  private Map<String, Boolean> patchDecisionsCache = new Map<String, Boolean>();
  private Set<String> completedStepsCache = new Set<String>();
  private Boolean hasLoadedExecutions = false;
  private DateTime instanceCreatedDate = null;
  private DateTime classLastModified = null;

  @TestVisible
  private static DateTime mockInstanceCreatedDate = null;
  @TestVisible
  private static DateTime mockClassLastModified = null;

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

  /**
   * Logging severity levels for step breadcrumbs.
   */
  public enum Level {
    INFO,
    WARN,
    ERROR
  }

  /**
   * Represents an individual step log entry.
   */
  public class Breadcrumb {
    /** The timestamp when this breadcrumb was created. */
    public Datetime timestamp { get; private set; }
    /** The severity level of this breadcrumb. */
    public Level level { get; private set; }
    /** The formatted log message (with serialized context, if any, and truncation applied). */
    public String message { get; private set; }

    public Breadcrumb(Level level, String message) {
      this.timestamp = Datetime.now();
      this.level = (level != null) ? level : StepContext.Level.INFO;
      this.message = message;
    }
  }

  /**
   * Logs a message at the specified level without any context.
   *
   * @param level The severity level (INFO, WARN, or ERROR).
   * @param message The log message.
   */
  public void log(Level level, String message) {
    this.log(level, message, null);
  }

  /**
   * Logs a message at the specified level with a context map, which will be serialized as JSON.
   * Enforces log volume caps (up to 100 entries, with a truncation warning on the 101st log)
   * and character length limits (entries are truncated to exactly 4000 characters).
   *
   * @param level The severity level (INFO, WARN, or ERROR).
   * @param message The log message.
   * @param logContext Context data as key-value pairs to be appended to the log.
   */
  public void log(Level level, String message, Map<String, Object> logContext) {
    if (this.breadcrumbs.size() > MAX_LOG_ENTRIES) {
      return;
    }
    if (this.breadcrumbs.size() == MAX_LOG_ENTRIES) {
      this.breadcrumbs.add(buildTruncationBreadcrumb());
      return;
    }

    String formattedMessage = appendContext(message, logContext);
    formattedMessage = capMessageLength(formattedMessage);
    this.breadcrumbs.add(new Breadcrumb(level, formattedMessage));
  }

  private static Breadcrumb buildTruncationBreadcrumb() {
    return new Breadcrumb(
      StepContext.Level.WARN,
      '[TRUNCATED] Log limit of ' +
        MAX_LOG_ENTRIES +
        ' entries reached. Subsequent step logs are discarded.'
    );
  }

  // Appends the serialized context (if any) to the message, applying the size,
  // heap-pressure, oversized-value and serialization-failure guards in order.
  private static String appendContext(
    String message,
    Map<String, Object> logContext
  ) {
    if (logContext == null || logContext.isEmpty()) {
      return message;
    }
    String base = (message != null) ? message : 'null';
    if (logContext.size() > 50) {
      return base +
        ' | Context: [TRUNCATED] Map size limit of 50 entries exceeded.';
    }
    if (Limits.getHeapSize() > Limits.getLimitHeapSize() * 0.85) {
      return base +
        ' | Context: [TRUNCATED] JSON serialization bypassed due to heap pressure.';
    }
    if (hasOversizedStringValue(logContext)) {
      return base +
        ' | Context: [TRUNCATED] JSON serialization bypassed due to oversized string value.';
    }
    return base + ' | Context: ' + serializeContext(logContext);
  }

  private static Boolean hasOversizedStringValue(
    Map<String, Object> logContext
  ) {
    for (Object val : logContext.values()) {
      if (
        val instanceof String && ((String) val).length() > MAX_MESSAGE_LENGTH
      ) {
        return true;
      }
    }
    return false;
  }

  private static String serializeContext(Map<String, Object> logContext) {
    try {
      String serializedContext = JSON.serialize(logContext);
      if (serializedContext.length() > MAX_MESSAGE_LENGTH) {
        serializedContext =
          serializedContext.substring(0, MAX_MESSAGE_LENGTH) +
          '... [TRUNCATED]';
      }
      return serializedContext;
    } catch (Exception ex) {
      return '[TRUNCATED] JSON serialization failed: ' + ex.getMessage();
    }
  }

  private static String capMessageLength(String formattedMessage) {
    if (
      formattedMessage != null &&
      formattedMessage.length() > MAX_MESSAGE_LENGTH
    ) {
      return formattedMessage.substring(0, MAX_MESSAGE_LENGTH - 15) +
        '... [TRUNCATED]';
    }
    return formattedMessage;
  }

  /**
   * Retrieves the buffered log entries (breadcrumbs) for this step execution.
   *
   * @return The list of Breadcrumb logs.
   */
  public List<Breadcrumb> getBreadcrumbs() {
    return this.breadcrumbs;
  }

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
  public String failedStepName { get; private set; }
  public String errorMessage { get; private set; }
  public Integer attemptCount { get; private set; }

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

  public Boolean isTimeoutResume() {
    return timeoutResume == true;
  }

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
      this.signalId = signalId;
      this.name = name;
      this.payload = payload;
      this.createdDate = null;
      this.claimed = false;
      this.present = true;
    }

    private Signal() {
      this.present = false;
      this.claimed = false;
    }

    /**
     * Sets the arrival timestamp and returns this signal, so a caller can build
     * a signal fluently without a long constructor parameter list.
     */
    public Signal withCreatedDate(Datetime createdDate) {
      this.createdDate = createdDate;
      return this;
    }

    /**
     * Marks this signal as CLAIMED (exclusive Processing hold for this branch)
     * and returns it. Intent-named alternative to a boolean constructor flag.
     */
    public Signal asClaimed() {
      this.claimed = true;
      return this;
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

  // Base constructor used by the Builder. Sets only the defaults that must hold
  // when their fluent setter is never called; the Builder writes the remaining
  // fields directly and finishBuild() applies the derived/hydration state.
  private StepContext() {
    this.workflowVersion = 1;
    this.attempt = 1;
    this.maxAttempts = 1;
  }

  // Applies the derived (stepVisit normalization, pending signals) and hydration
  // (attempt/maxAttempts/timeoutResume/captured values) state, reproducing the
  // exact behavior of the former positional constructors and withCapturedValues*
  // factories. Defaults leave the plain-constructor behavior unchanged.
  private StepContext finishBuild(Builder b) {
    this.stepVisit = (b.stepVisitVal != null &&
      b.stepVisitVal > 0)
      ? b.stepVisitVal
      : 0;
    this.attempt = 1;
    this.maxAttempts = 1;
    applyPendingSignals(b);
    this.timeoutResume = (b.timeoutResumeVal == true);
    if (b.attemptVal != null && b.attemptVal > 0) {
      this.attempt = b.attemptVal;
    }
    if (b.maxAttemptsVal != null && b.maxAttemptsVal > 0) {
      this.maxAttempts = b.maxAttemptsVal;
    }
    applyCapturedValues(b);
    return this;
  }

  private void applyPendingSignals(Builder b) {
    if (!b.pendingSignalsProvided) {
      return;
    }
    // Explicit pending-signal list (used by tests): already resolved, so no
    // lazy source load is needed.
    this.allSignals = (b.pendingSignalsVal != null)
      ? b.pendingSignalsVal
      : new List<Signal>();
    this.allLoaded = true;
  }

  // Assigns the pre-parsed (or JSON-parsed) captured values and extracts the
  // reserved retry/error bookkeeping keys, mirroring the former
  // withCapturedValuesMap factory. No-op for the plain-constructor path.
  private void applyCapturedValues(Builder b) {
    Map<String, Object> cv = b.capturedValuesMapVal;
    if (cv == null && b.capturesJsonProvided) {
      cv = parseCaptures(b.capturedValuesJsonVal);
    }
    if (cv == null) {
      return;
    }
    this.capturedValues = cv;
    extractReservedCaptures();
  }

  private void extractReservedCaptures() {
    if (this.capturedValues.containsKey('__maxAttempts')) {
      try {
        this.maxAttempts = Integer.valueOf(
          this.capturedValues.get('__maxAttempts')
        );
      } catch (Exception ignored) {
      }
      this.capturedValues.remove('__maxAttempts');
    }
    if (this.capturedValues.containsKey('__failedStepName')) {
      this.failedStepName = String.valueOf(
        this.capturedValues.get('__failedStepName')
      );
      this.capturedValues.remove('__failedStepName');
    }
    if (this.capturedValues.containsKey('__errorMessage')) {
      this.errorMessage = String.valueOf(
        this.capturedValues.get('__errorMessage')
      );
      this.capturedValues.remove('__errorMessage');
    }
    if (this.capturedValues.containsKey('__attemptCount')) {
      try {
        this.attemptCount = Integer.valueOf(
          this.capturedValues.get('__attemptCount')
        );
      } catch (Exception ignored) {
      }
      this.capturedValues.remove('__attemptCount');
    }
  }

  /**
   * Fluent construction path for StepContext. Every construction parameter is
   * supplied through a single-value setter so no method carries a long
   * parameter list. Unset values keep the historical defaults (workflowVersion
   * = 1, stepVisit = 0, attempt/maxAttempts = 1, timeoutResume = false).
   *
   * Public so the engine and step-author tests can build contexts directly; the
   * former positional StepContext(...) constructors and withCapturedValues*
   * factories routed through this same path.
   */
  public class Builder {
    // The context under construction. Simple, non-derived fields are written
    // straight onto it; only the values that need normalization or deferred
    // hydration are held on the Builder itself, keeping its field count small.
    private StepContext ctx = new StepContext();
    private Integer stepVisitVal = 0;
    private List<Signal> pendingSignalsVal;
    private Boolean pendingSignalsProvided = false;
    private Map<String, Object> capturedValuesMapVal;
    private String capturedValuesJsonVal;
    private Boolean capturesJsonProvided = false;
    private Boolean timeoutResumeVal = false;
    private Integer attemptVal = 1;
    private Integer maxAttemptsVal = 1;

    public Builder instanceId(Id val) {
      ctx.workflowInstanceId = val;
      return this;
    }

    public Builder workflowName(String val) {
      ctx.workflowName = val;
      return this;
    }

    public Builder stepName(String val) {
      ctx.stepName = val;
      return this;
    }

    public Builder inputJson(String val) {
      ctx.inputJson = val;
      return this;
    }

    public Builder previousStepOutput(String val) {
      ctx.previousStepOutput = val;
      return this;
    }

    public Builder stepStateJson(String val) {
      ctx.stepStateJson = val;
      return this;
    }

    public Builder workflowInputJson(String val) {
      ctx.workflowInputJson = val;
      return this;
    }

    public Builder workflowVersion(Integer val) {
      ctx.workflowVersion = val;
      return this;
    }

    public Builder stepVisit(Integer val) {
      this.stepVisitVal = val;
      return this;
    }

    public Builder signalSource(SignalSource val) {
      // Defer loading until a signal accessor is actually called.
      ctx.signalSource = val;
      return this;
    }

    public Builder pendingSignals(List<Signal> val) {
      this.pendingSignalsVal = val;
      this.pendingSignalsProvided = true;
      return this;
    }

    public Builder previousRunAt(Datetime val) {
      ctx.previousRunAt = val;
      return this;
    }

    public Builder capturedValuesMap(Map<String, Object> val) {
      this.capturedValuesMapVal = val;
      return this;
    }

    public Builder capturedValuesJson(String val) {
      this.capturedValuesJsonVal = val;
      this.capturesJsonProvided = true;
      return this;
    }

    public Builder attempt(Integer val) {
      this.attemptVal = val;
      return this;
    }

    public Builder maxAttempts(Integer val) {
      this.maxAttemptsVal = val;
      return this;
    }

    /** Marks this context as the engine-routed timeout fallback (issue #35). */
    public Builder markTimeoutResume() {
      this.timeoutResumeVal = true;
      return this;
    }

    public StepContext build() {
      return ctx.finishBuild(this);
    }
  }

  // Resolves the full pending set lazily so a step that never touches signals
  // pays no query/heap cost for unrelated unconsumed signals on the instance.
  private List<Signal> loadAll() {
    if (allLoaded) {
      return this.allSignals;
    }
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
    Set<Id> present = collectPresentIds(all);
    mergeCachedClaimsInto(all, present);
    // Re-sort into arrival order: merged-in claims (out of the source's
    // Received view) must not simply trail the still-Received rows, which
    // would violate the accessor's arrival-order contract.
    all.sort();
    this.allSignals = all;
    this.allLoaded = true;
    return this.allSignals;
  }

  private static Set<Id> collectPresentIds(List<Signal> signals) {
    Set<Id> present = new Set<Id>();
    for (Signal s : signals) {
      if (s.signalId != null) {
        present.add(s.signalId);
      }
    }
    return present;
  }

  // Merges rows this branch already claimed (latest-per-name and named-list
  // caches) back into `all`, skipping ids already present. Mutates both args.
  private void mergeCachedClaimsInto(List<Signal> all, Set<Id> present) {
    for (Signal cached : latestByName.values()) {
      if (cached != null && cached.isPresent()) {
        addUnseen(all, present, cached);
      }
    }
    for (List<Signal> cachedList : byNameCache.values()) {
      for (Signal cached : cachedList) {
        addUnseen(all, present, cached);
      }
    }
  }

  private static void addUnseen(
    List<Signal> all,
    Set<Id> present,
    Signal cached
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
      return filterByName(allSignals, signalName);
    }
    String key = signalName.toLowerCase();
    if (!byNameCache.containsKey(key)) {
      byNameCache.put(key, loadNamedMatches(key, signalName));
    }
    return byNameCache.get(key);
  }

  // Case-insensitive filter matching the source SOQL (Text field equality) and
  // the lower-cased per-name caches; a case-only difference must not make an
  // already-delivered signal look absent.
  private static List<Signal> filterByName(
    List<Signal> signals,
    String signalName
  ) {
    List<Signal> matches = new List<Signal>();
    for (Signal s : signals) {
      if (s.name != null && s.name.equalsIgnoreCase(signalName)) {
        matches.add(s);
      }
    }
    return matches;
  }

  // Loads the per-name matches from the source and merges back rows this branch
  // already claimed, so neither a guard-then-read pattern nor a capped full read
  // drops a matched payload from the named list.
  private List<Signal> loadNamedMatches(String key, String signalName) {
    List<Signal> loaded = (signalSource != null)
      ? signalSource.getPendingSignals(signalName)
      : null;
    // If the source truncated this read, the cached list is a partial (oldest)
    // page, so latestFor() must not treat its last row as the true latest.
    if (signalSource != null && signalSource.readWasCapped()) {
      partialNameKeys.add(key);
    }
    List<Signal> matches = (loaded != null) ? loaded : new List<Signal>();
    // Reclaim candidates: the per-name latest claimed by an earlier
    // getSignal/hasSignal, and matching rows from a capped full-set read
    // (reached here only when allReadCapped, since a complete full set returns
    // above).
    if (mergeReclaims(matches, reclaimCandidates(key, signalName))) {
      // Keep arrival order after merging the claimed rows back in.
      matches.sort();
    }
    return matches;
  }

  // Appends candidates not already present (by id) to `matches`. Returns true
  // when at least one row was merged.
  private static Boolean mergeReclaims(
    List<Signal> matches,
    List<Signal> candidates
  ) {
    Set<Id> present = collectPresentIds(matches);
    Boolean merged = false;
    for (Signal s : candidates) {
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

  private List<Signal> reclaimCandidates(String key, String signalName) {
    List<Signal> reclaim = new List<Signal>();
    Signal cachedLatest = latestByName.get(key);
    if (cachedLatest != null && cachedLatest.isPresent()) {
      reclaim.add(cachedLatest);
    }
    if (allLoaded) {
      reclaim.addAll(filterByName(allSignals, signalName));
    }
    return reclaim;
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
      return newestInList(allSignals, signalName);
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
    return reconcileLatest(latestByName.get(key), key, signalName);
  }

  // Case-insensitive scan returning the last (newest, arrival-ordered) match.
  private static Signal newestInList(List<Signal> signals, String signalName) {
    Signal latest = null;
    for (Signal s : signals) {
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
  private Signal reconcileLatest(
    Signal sourceLatest,
    String key,
    String signalName
  ) {
    Signal cachedLatest = newestCachedMatch(key, signalName);
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
   * Checks if the current transaction is approaching governor limits.
   * Returns true if any monitored limit (CPU, SOQL, DML statements, DML rows, or Heap size) is > 80% consumed.
   */
  public Boolean shouldYield() {
    if (exceedsThreshold(Limits.getCpuTime(), Limits.getLimitCpuTime())) {
      return true;
    }
    if (exceedsThreshold(Limits.getQueries(), Limits.getLimitQueries())) {
      return true;
    }
    Double queryRowsFraction = mockQueryRowsFraction != null
      ? mockQueryRowsFraction
      : fractionOf(Limits.getQueryRows(), Limits.getLimitQueryRows());
    if (queryRowsFraction > 0.80) {
      return true;
    }
    if (
      exceedsThreshold(
        Limits.getDmlStatements(),
        Limits.getLimitDmlStatements()
      )
    ) {
      return true;
    }
    if (exceedsThreshold(Limits.getDmlRows(), Limits.getLimitDmlRows())) {
      return true;
    }
    if (exceedsThreshold(Limits.getHeapSize(), Limits.getLimitHeapSize())) {
      return true;
    }
    Double asyncFraction = asyncExecutionsFraction();
    return asyncFraction != null && asyncFraction > 0.80;
  }

  // 0.0 when the limit is non-positive, else current/limit as a fraction.
  private static Double fractionOf(Integer current, Integer max) {
    return max > 0 ? ((Double) current / max) : 0.0;
  }

  // True when current consumes more than 80% of a positive limit.
  private static Boolean exceedsThreshold(Integer current, Integer max) {
    return max > 0 && ((Double) current / max) > 0.80;
  }

  // Daily Async Apex Executions fraction (accounts for Beta Elastic Limits if
  // enabled). Uses the test mock when set, else the cached org-limit reading.
  private static Double asyncExecutionsFraction() {
    if (mockAsyncExecutionsFraction != null) {
      return mockAsyncExecutionsFraction;
    }
    if (cachedAsyncFraction != null) {
      return cachedAsyncFraction;
    }
    Map<String, System.OrgLimit> limitsMap = System.OrgLimits.getMap();
    if (!limitsMap.containsKey('DailyAsyncApexExecutions')) {
      return null;
    }
    System.OrgLimit dailyLimitObj = limitsMap.get('DailyAsyncApexExecutions');
    Integer limitValue = dailyLimitObj.getValue();
    Integer maxLimit = dailyLimitObj.getLimit();
    if (limitsMap.containsKey('DailyAsyncApexElasticExecutions')) {
      maxLimit = limitsMap.get('DailyAsyncApexElasticExecutions').getLimit();
    }
    if (maxLimit > 0) {
      cachedAsyncFraction = (Double) limitValue / maxLimit;
    }
    return cachedAsyncFraction;
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
   * Evaluates if a specific named change marker (patch) is active for this instance.
   *
   * The first time a given (instance, changeId) decision is reached, the result
   * reflects the currently-deployed code's intent (new behavior = true); that
   * decision is recorded once and returns the identical value on every subsequent
   * re-execution of that step (retry, yield/resume, at-least-once event resume,
   * operator re-drive) — same capture-once durability contract as once().
   *
   * An instance that already executed past the point where a marker is later
   * introduced is never retroactively flipped: its recorded patch decisions are
   * immutable, so resuming it cannot change a branch it already took.
   *
   * @param changeId The unique developer-supplied name for the patch/change.
   * @return True if the patch is active/enabled for this instance, else false.
   */
  public Boolean patched(String changeId) {
    return patched(changeId, null);
  }

  /**
   * Evaluates if a specific named change marker (patch) is active for this instance,
   * using an optional introduction date to safely handle future redeployments of the class.
   *
   * @param changeId The unique developer-supplied name for the patch/change.
   * @param introducedAt Optional DateTime representing when the patch was introduced.
   *                     If provided, any instance created before this date defaults to false,
   *                     while instances created after default to true. This avoids regression
   *                     risks when the class is redeployed for unrelated edits later.
   * @return True if the patch is active/enabled for this instance, else false.
   */
  public Boolean patched(String changeId, DateTime introducedAt) {
    if (String.isBlank(changeId)) {
      return false;
    }
    String key = '__patch:' + changeId;
    if (capturedValues.containsKey(key)) {
      return (Boolean) capturedValues.get(key);
    }

    // Check if any other step in this instance has already recorded a decision for this changeId.
    loadExecutions(getCallingClassName());
    Boolean decision = patchDecisionsCache.containsKey(changeId)
      ? patchDecisionsCache.get(changeId)
      : firstPatchDecision(introducedAt);
    capturedValues.put(key, decision);
    newCaptureKeys.add(key);
    return decision;
  }

  // Computes the patch decision the first time it is reached in this instance
  // (no prior recorded decision). An already-completed visit is a re-execution
  // (false); otherwise a brand-new instance defaults to true unless it predates
  // the patch introduction / class deployment, or dates were unresolvable while
  // earlier steps already completed.
  private Boolean firstPatchDecision(DateTime introducedAt) {
    if (completedStepsCache.contains(this.stepName + ':' + this.stepVisit)) {
      return false;
    }
    DateTime comparisonDate = introducedAt != null
      ? introducedAt
      : classLastModified;
    if (
      instanceCreatedDate != null &&
      comparisonDate != null &&
      instanceCreatedDate < comparisonDate
    ) {
      return false;
    }
    if (
      !completedStepsCache.isEmpty() &&
      (instanceCreatedDate == null ||
      comparisonDate == null)
    ) {
      return false;
    }
    return true;
  }

  /**
   * Asserts that a named change marker (patch) has been retired/deprecated.
   *
   * If this instance is still expecting the old branch (i.e. patched(changeId) == false),
   * reaching this marker throws a distinguishable WorkflowException to prevent silently
   * running the wrong path.
   *
   * @param changeId The unique developer-supplied name for the patch/change.
   */
  public void deprecated(String changeId) {
    deprecated(changeId, null);
  }

  /**
   * Asserts that a named change marker (patch) has been retired/deprecated,
   * using an optional introduction date to safely handle future redeployments of the class.
   *
   * @param changeId The unique developer-supplied name for the patch/change.
   * @param introducedAt Optional DateTime representing when the patch was introduced.
   */
  public void deprecated(String changeId, DateTime introducedAt) {
    if (!patched(changeId, introducedAt)) {
      throw new WorkflowEngine.WorkflowException(
        'Workflow execution reached retired code path for patch: ' + changeId
      );
    }
  }

  private void loadExecutions(String targetClassName) {
    if (hasLoadedExecutions || this.workflowInstanceId == null) {
      return;
    }
    Set<Id> targetIds = collectTargetExecutionIds();
    List<Workflow_Step_Execution__c> executions = queryExecutions(targetIds);
    resolveInstanceCreatedDate(executions);
    resolveClassLastModified(targetClassName);
    indexExecutions(executions, resolveCapturePayloads(executions));
    hasLoadedExecutions = true;
  }

  // Steps 1 & 2: the first+last execution id per other step name, plus the
  // current step name's executions bounded by stepVisit + 2 (queried separately
  // to ensure correct visit counts).
  private Set<Id> collectTargetExecutionIds() {
    Set<Id> targetIds = new Set<Id>();
    for (AggregateResult ar : [
      SELECT Step_Name__c, MIN(Id) minId, MAX(Id) maxId
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :this.workflowInstanceId
      WITH SYSTEM_MODE
      GROUP BY Step_Name__c
    ]) {
      if ((String) ar.get('Step_Name__c') == this.stepName) {
        continue;
      }
      Id minId = (Id) ar.get('minId');
      Id maxId = (Id) ar.get('maxId');
      if (minId != null) {
        targetIds.add(minId);
      }
      if (maxId != null) {
        targetIds.add(maxId);
      }
    }
    Integer currentStepLimit = this.stepVisit + 2;
    for (Workflow_Step_Execution__c e : [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :this.workflowInstanceId
        AND Step_Name__c = :this.stepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT :currentStepLimit
    ]) {
      targetIds.add(e.Id);
    }
    return targetIds;
  }

  // Step 3: the final sorted list of step executions by id.
  private List<Workflow_Step_Execution__c> queryExecutions(Set<Id> targetIds) {
    if (targetIds.isEmpty()) {
      return new List<Workflow_Step_Execution__c>();
    }
    return [
      SELECT
        Step_Name__c,
        Status__c,
        Captured_Values__c,
        Workflow_Instance__r.CreatedDate
      FROM Workflow_Step_Execution__c
      WHERE Id IN :targetIds
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
    ];
  }

  private void resolveInstanceCreatedDate(
    List<Workflow_Step_Execution__c> executions
  ) {
    if (Test.isRunningTest() && mockInstanceCreatedDate != null) {
      this.instanceCreatedDate = mockInstanceCreatedDate;
      return;
    }
    if (!executions.isEmpty()) {
      this.instanceCreatedDate = executions[0].Workflow_Instance__r.CreatedDate;
      return;
    }
    List<Workflow_Instance__c> instances = [
      SELECT CreatedDate
      FROM Workflow_Instance__c
      WHERE Id = :this.workflowInstanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!instances.isEmpty()) {
      this.instanceCreatedDate = instances[0].CreatedDate;
    }
  }

  private void resolveClassLastModified(String targetClassName) {
    if (Test.isRunningTest() && mockClassLastModified != null) {
      this.classLastModified = mockClassLastModified;
      return;
    }
    List<ApexClass> classes = [
      SELECT LastModifiedDate
      FROM ApexClass
      WHERE Name = :targetClassName
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!classes.isEmpty()) {
      this.classLastModified = classes[0].LastModifiedDate;
    }
  }

  // Resolve offloaded payloads in small batches to stay under Apex Heap Limits
  // (synchronous cap is 6 MB).
  private List<String> resolveCapturePayloads(
    List<Workflow_Step_Execution__c> executions
  ) {
    List<String> rawCaptures = new List<String>();
    for (Workflow_Step_Execution__c exec : executions) {
      rawCaptures.add(exec.Captured_Values__c);
    }
    Integer batchSize = 40;
    List<String> resolvedCaptures = new List<String>();
    for (Integer i = 0; i < rawCaptures.size(); i += batchSize) {
      List<String> batchRaw = new List<String>();
      for (Integer j = i; j < i + batchSize && j < rawCaptures.size(); j++) {
        batchRaw.add(rawCaptures[j]);
      }
      resolvedCaptures.addAll(WorkflowEngine.resolvePayloads(batchRaw));
    }
    return resolvedCaptures;
  }

  // Populates completedStepsCache (per-visit completion markers) and
  // patchDecisionsCache (prior __patch: decisions) from the resolved captures.
  private void indexExecutions(
    List<Workflow_Step_Execution__c> executions,
    List<String> resolvedCaptures
  ) {
    Map<String, Integer> completedCounts = new Map<String, Integer>();
    for (Integer i = 0; i < executions.size(); i++) {
      Workflow_Step_Execution__c exec = executions[i];
      recordCompletedVisit(exec, completedCounts);
      mergePatchDecisions(resolvedCaptures[i]);
    }
  }

  private void recordCompletedVisit(
    Workflow_Step_Execution__c exec,
    Map<String, Integer> completedCounts
  ) {
    if (exec.Status__c != 'Completed' && exec.Status__c != 'OperatorSkipped') {
      return;
    }
    Integer visit = completedCounts.containsKey(exec.Step_Name__c)
      ? completedCounts.get(exec.Step_Name__c)
      : 0;
    completedStepsCache.add(exec.Step_Name__c + ':' + visit);
    completedCounts.put(exec.Step_Name__c, visit + 1);
  }

  private void mergePatchDecisions(String capturesJson) {
    if (String.isBlank(capturesJson) || !capturesJson.contains('__patch:')) {
      return;
    }
    try {
      Map<String, Object> captures = (Map<String, Object>) JSON.deserializeUntyped(
        capturesJson
      );
      for (String k : captures.keySet()) {
        if (k.startsWith('__patch:')) {
          patchDecisionsCache.put(k.substring(8), (Boolean) captures.get(k));
        }
      }
    } catch (Exception ignored) {
      // Ignore malformed JSON
    }
  }

  private String getCallingClassName() {
    String trace = new DmlException().getStackTraceString();
    List<String> lines = trace.split('\n');
    for (String line : lines) {
      String trimmed = line.trim();
      if (
        trimmed.startsWith('Class.') && !trimmed.contains('Class.StepContext.')
      ) {
        String classAndMethod = trimmed.substring(6);
        return classAndMethod.substringBefore('.');
      }
    }
    // Fallback: use outer class of stepName or workflowName
    return this.stepName != null
      ? this.stepName.substringBefore('.')
      : this.workflowName.substringBefore('.');
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
    if (hasNothingToSerialize()) {
      return null;
    }
    Map<String, Object> toSerialize = new Map<String, Object>(capturedValues);
    if (this.maxAttempts != null && this.maxAttempts > 1) {
      toSerialize.put('__maxAttempts', this.maxAttempts);
    }
    if (String.isNotBlank(this.failedStepName)) {
      toSerialize.put('__failedStepName', this.failedStepName);
    }
    if (String.isNotBlank(this.errorMessage)) {
      toSerialize.put('__errorMessage', this.errorMessage);
    }
    if (this.attemptCount != null) {
      toSerialize.put('__attemptCount', this.attemptCount);
    }
    return JSON.serialize(toSerialize);
  }

  // True when there are no captures and no reserved metadata (retry/error
  // bookkeeping) to persist, so getCapturedValuesJson() returns null.
  private Boolean hasNothingToSerialize() {
    return capturedValues.isEmpty() &&
      (this.maxAttempts == null ||
      this.maxAttempts <= 1) &&
      String.isBlank(this.failedStepName) &&
      String.isBlank(this.errorMessage) &&
      this.attemptCount == null;
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
    } catch (Exception ignored) {
    }
    return new Map<String, Object>();
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
    List<ChildOutcome> outcomes = this.getChildOutcomes(
      new List<String>{ childKey }
    );
    if (outcomes.isEmpty()) {
      return new ChildOutcome();
    }
    return outcomes[0];
  }

  public List<ChildOutcome> getChildOutcomes(List<String> childKeys) {
    this.loadAll(); // Pre-load all pending signals to bulkify and avoid N+1 queries
    List<ChildOutcome> outcomes = new List<ChildOutcome>();
    if (childKeys == null || childKeys.isEmpty()) {
      return outcomes;
    }
    ChildResolution res = new ChildResolution();
    // Step 1: probe each key's signals and collect raw payloads to resolve.
    for (Integer i = 0; i < childKeys.size(); i++) {
      collectChildPayloads(i, childKeys[i], res);
    }
    // Step 2: bulk-resolve the collected payloads and index them by key.
    resolveChildPayloads(res);
    // Step 3: construct the ChildOutcome list.
    for (Integer i = 0; i < childKeys.size(); i++) {
      outcomes.add(buildChildOutcome(i, childKeys[i], res));
    }
    return outcomes;
  }

  // Mutable accumulator for the three phases of getChildOutcomes so no phase
  // helper needs a long parameter list.
  private class ChildResolution {
    List<String> rawPayloads = new List<String>();
    List<Integer> targetKeyIndex = new List<Integer>();
    List<String> targetType = new List<String>(); // 'completed' or 'failedOutput'
    // Pre-deserialized maps for failed signals so we don't deserialize twice.
    Map<Integer, Map<String, Object>> failedDataMap = new Map<Integer, Map<String, Object>>();
    Map<Integer, String> resolvedCompleted = new Map<Integer, String>();
    Map<Integer, String> resolvedFailedOutput = new Map<Integer, String>();

    void addRawPayload(String payload, Integer keyIndex, String type) {
      this.rawPayloads.add(payload);
      this.targetKeyIndex.add(keyIndex);
      this.targetType.add(type);
    }
  }

  private void collectChildPayloads(
    Integer i,
    String childKey,
    ChildResolution res
  ) {
    if (String.isBlank(childKey)) {
      return;
    }
    String completedName = 'ChildCompleted:' + childKey;
    String failedName = 'ChildFailed:' + childKey;
    Signal completedSig = this.getSignal(completedName);
    Signal failedSig = this.getSignal(failedName);

    if (completedSig.isPresent() || failedSig.isPresent()) {
      this.markMatched(new Signal(null, completedName, null));
      this.markMatched(new Signal(null, failedName, null));
    }

    if (completedSig.isPresent()) {
      if (String.isNotBlank(completedSig.payload)) {
        res.addRawPayload(completedSig.payload, i, 'completed');
      }
    } else if (failedSig.isPresent() && String.isNotBlank(failedSig.payload)) {
      collectFailedPayload(i, failedSig, res);
    }
  }

  private void collectFailedPayload(
    Integer i,
    Signal failedSig,
    ChildResolution res
  ) {
    try {
      Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(
        failedSig.payload
      );
      res.failedDataMap.put(i, data);
      Object outputObj = data.get('output');
      if (outputObj instanceof String) {
        res.addRawPayload((String) outputObj, i, 'failedOutput');
      }
    } catch (Exception ignored) {
      // Deserialization failure will be handled during outcome construction
    }
  }

  private void resolveChildPayloads(ChildResolution res) {
    if (res.rawPayloads.isEmpty()) {
      return;
    }
    List<String> resolvedPayloads = WorkflowEngine.resolvePayloads(
      res.rawPayloads
    );
    for (Integer j = 0; j < resolvedPayloads.size(); j++) {
      Integer keyIdx = res.targetKeyIndex[j];
      String type = res.targetType[j];
      if (type == 'completed') {
        res.resolvedCompleted.put(keyIdx, resolvedPayloads[j]);
      } else if (type == 'failedOutput') {
        res.resolvedFailedOutput.put(keyIdx, resolvedPayloads[j]);
      }
    }
  }

  private ChildOutcome buildChildOutcome(
    Integer i,
    String childKey,
    ChildResolution res
  ) {
    if (String.isBlank(childKey)) {
      return new ChildOutcome();
    }
    Signal completedSig = this.getSignal('ChildCompleted:' + childKey);
    Signal failedSig = this.getSignal('ChildFailed:' + childKey);

    if (completedSig.isPresent()) {
      String resolvedVal = res.resolvedCompleted.containsKey(i)
        ? res.resolvedCompleted.get(i)
        : completedSig.payload;
      return new ChildOutcome('Completed', null, resolvedVal);
    }
    if (!failedSig.isPresent()) {
      return new ChildOutcome();
    }
    if (String.isBlank(failedSig.payload)) {
      return new ChildOutcome('Failed', null, null);
    }
    if (!res.failedDataMap.containsKey(i)) {
      return new ChildOutcome('Failed', failedSig.payload, null);
    }
    return buildFailedOutcome(i, res);
  }

  private ChildOutcome buildFailedOutcome(Integer i, ChildResolution res) {
    Map<String, Object> data = res.failedDataMap.get(i);
    String status = data.get('status') != null
      ? String.valueOf(data.get('status'))
      : null;
    String errorMessage = data.get('errorMessage') != null
      ? String.valueOf(data.get('errorMessage'))
      : null;
    Object outputObj = data.get('output');
    String outputVal = null;
    if (outputObj instanceof String) {
      outputVal = res.resolvedFailedOutput.containsKey(i)
        ? res.resolvedFailedOutput.get(i)
        : (String) outputObj;
    } else if (outputObj != null) {
      outputVal = JSON.serialize(outputObj);
    }
    return new ChildOutcome(status, errorMessage, outputVal);
  }
}
