/**
 * @description Durable per-step execution context handed to every workflow step.
 * Carries the step's identity, inputs, prior outputs and retry/attempt metadata,
 * and exposes the effectively-once primitives step authors rely on. To keep this
 * type focused, those primitives now live on cohesive accessor sub-objects,
 * reached via pure getters:
 *
 * - logger()   -> StepLog        breadcrumb logging
 * - progress() -> StepProgress   progress snapshots
 * - events()   -> StepEmitter    outbound event emission
 * - signals()  -> StepSignals    inbound signal reads + child outcomes
 * - captures() -> StepCaptures   capture-once values + named change markers
 * - retry()    -> StepRetryInfo  attempt/retry/error metadata
 *
 * The hottest author reads (identity/input fields, `attempt`, `isFinalAttempt()`,
 * `idempotencyKey`, `shouldYield()`) stay directly on the context.
 */
public inherited sharing class StepContext {
  /** Log_Type__c value stamped on persisted step breadcrumbs. */
  public static final String LOG_TYPE_BREADCRUMB = 'StepBreadcrumb';

  // 0-based sequence of this visit to `stepName` within this instance: the count
  // of already-completed executions of the step when this context was built. It
  // stays constant across retries/re-drives/resumes of the current (not yet
  // completed) visit, and increments only when the engine loops back to the same
  // step for a fresh visit. Populated by the engine; defaults to 0.
  private Integer stepVisit = 0;

  // Accessor sub-objects that own this context's state and logic. Each is
  // constructed by finishBuild() and returned by a pure getter (no delegation),
  // so this class stays small and the getters do not trip the class-metric
  // recursion heuristic.
  /** Breadcrumb logging accessor (StepContext.logger()). */
  private StepLog stepLog;
  /** Progress-snapshot accessor (StepContext.progress()). */
  private StepProgress stepProgress;
  /** Outbound event accessor (StepContext.events()). */
  private StepEmitter stepEmitter;
  /** Attempt/retry/error metadata accessor (StepContext.retry()). */
  private StepRetryInfo stepRetry;
  /** Inbound signal + child-outcome accessor (StepContext.signals()). */
  private StepSignals stepSignals;
  /** Capture-once + patch accessor (StepContext.captures()). */
  private StepCaptures stepCaptures;

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

    /**
     * @description Constructs a breadcrumb, stamping the current time and
     * defaulting a null level to INFO.
     * @param level The severity level; INFO is used when null.
     * @param message The formatted log message.
     */
    public Breadcrumb(Level level, String message) {
      this.timestamp = Datetime.now();
      this.level = (level != null) ? level : StepContext.Level.INFO;
      this.message = message;
    }
  }

  /** The Id of the Workflow_Instance__c this step is executing for. */
  public Id workflowInstanceId { get; private set; }
  /** The developer name of the workflow definition being executed. */
  public String workflowName { get; private set; }
  /** The name of the step currently executing. */
  public String stepName { get; private set; }
  /** JSON input passed to this step by the transition that scheduled it. */
  public String inputJson { get; private set; }
  /** JSON output produced by the immediately preceding step, if any. */
  public String previousStepOutput { get; private set; }
  /** JSON durable state persisted for this step across re-executions. */
  public String stepStateJson { get; private set; }
  /** JSON input the workflow instance was originally started with. */
  public String workflowInputJson { get; private set; }
  /** The version of the workflow definition this instance is pinned to. */
  public Integer workflowVersion { get; private set; }
  /** The 1-based attempt number of the current step execution. */
  public Integer attempt { get; private set; }

  /**
   * @description True when the current attempt is the last one permitted, so a
   * step can branch to a terminal fallback instead of requesting another retry.
   * @return True if this attempt has reached the retry maxAttempts.
   */
  public Boolean isFinalAttempt() {
    return this.attempt >= this.stepRetry.maxAttempts;
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

  /**
   * @description Breadcrumb logging accessor for this step execution.
   * @return The StepLog owning this context's buffered breadcrumbs.
   */
  public StepLog logger() {
    return this.stepLog;
  }

  /**
   * @description Progress-snapshot accessor for this step execution.
   * @return The StepProgress owning this context's buffered progress snapshot.
   */
  public StepProgress progress() {
    return this.stepProgress;
  }

  /**
   * @description Outbound event accessor for this step execution.
   * @return The StepEmitter owning this context's buffered outbound events.
   */
  public StepEmitter events() {
    return this.stepEmitter;
  }

  /**
   * @description Inbound signal and child-outcome accessor for this step
   * execution.
   * @return The StepSignals owning this context's signal reads and claim state.
   */
  public StepSignals signals() {
    return this.stepSignals;
  }

  /**
   * @description Capture-once and named-change-marker (patch) accessor for this
   * step execution.
   * @return The StepCaptures owning this context's captured values and patches.
   */
  public StepCaptures captures() {
    return this.stepCaptures;
  }

  /**
   * @description Attempt/retry/error metadata accessor for this step execution.
   * @return The StepRetryInfo owning this context's retry and error fields.
   */
  public StepRetryInfo retry() {
    return this.stepRetry;
  }

  /**
   * Read-only view of an inbound signal that targets this workflow instance.
   * Carries the author-interpreted name and payload string; the internal record
   * id is exposed so the engine can tie consumption to the step's transition.
   */
  public class Signal implements Comparable {
    /** The Id of the underlying Workflow_Signal__c record. */
    public Id signalId { get; private set; }
    /** The author-interpreted signal name this row was delivered under. */
    public String name { get; private set; }
    /** The signal's payload string, or null for the empty sentinel. */
    public String payload { get; private set; }
    // Arrival timestamp (Workflow_Signal__c.CreatedDate). Used to keep merged
    // signal lists in deterministic arrival order even when a row was already
    // claimed out of a later re-query. Null for the empty sentinel and for
    // signals built from an explicit in-memory list (tests).
    /** Arrival timestamp used to keep merged signal lists in arrival order. */
    public Datetime createdDate { get; private set; }
    // True when the source atomically CLAIMED this row (flipped it to an
    // exclusive Processing state for this branch), as opposed to merely reading
    // it while still Received. The engine uses this to roll back / consume only
    // rows this branch actually owns, never a sibling's claim.
    private Boolean claimed;
    private Boolean present;

    /**
     * @description Constructs a present signal from its record id, name and
     * payload; createdDate is left null and claimed defaults to false.
     * @param signalId The Workflow_Signal__c record id.
     * @param name The signal name.
     * @param payload The signal payload string.
     */
    public Signal(Id signalId, String name, String payload) {
      this.signalId = signalId;
      this.name = name;
      this.payload = payload;
      this.createdDate = null;
      this.claimed = false;
      this.present = true;
    }

    /**
     * @description Constructs the empty (not-present) result sentinel returned
     * when no matching signal is pending.
     */
    public Signal() {
      this.present = false;
      this.claimed = false;
    }

    /**
     * @description Sets the arrival timestamp and returns this signal, so a
     * caller can build a signal fluently without a long constructor parameter
     * list.
     * @param createdDate The arrival timestamp to record.
     * @return This signal, for chaining.
     */
    public Signal withCreatedDate(Datetime createdDate) {
      this.createdDate = createdDate;
      return this;
    }

    /**
     * @description Marks this signal as CLAIMED (exclusive Processing hold for
     * this branch) and returns it. Intent-named alternative to a boolean
     * constructor flag.
     * @return This signal, for chaining.
     */
    public Signal asClaimed() {
      this.claimed = true;
      return this;
    }

    /**
     * @description True when this represents a real pending signal (not the
     * empty result sentinel).
     * @return True if a matching signal is present.
     */
    public Boolean isPresent() {
      return present;
    }

    /**
     * @description True when the engine holds an exclusive claim on this row for
     * this branch.
     * @return True if this row is claimed by this branch.
     */
    public Boolean isClaimed() {
      return claimed;
    }

    /**
     * @description Orders by arrival (CreatedDate, then Id) so a merged list
     * preserves the engine's deterministic signal ordering. Nulls (in-memory
     * signals) sort first, then by id as a stable fallback when no timestamp is
     * known.
     * @param other The other Signal to compare against.
     * @return A negative, zero, or positive Integer per the Comparable contract.
     */
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
    /**
     * @description Returns pending signals for the given name, or every pending
     * signal when the name is blank/null.
     * @param signalName The name to filter by, or blank for all.
     * @return The matching pending signals.
     */
    List<Signal> getPendingSignals(String signalName);
    /**
     * @description Returns only the single most-recent pending signal matching
     * the name, avoiding loading every duplicate payload.
     * @param signalName The name to match.
     * @return The latest matching signal, or null if none.
     */
    Signal getLatestSignal(String signalName);
    /**
     * @description True when the last read was truncated by a governor-safety
     * row cap, so callers must not treat the returned page as exhaustive.
     * @return True if the most recent read was capped.
     */
    Boolean readWasCapped();
  }

  // Base constructor used by the Builder. Sets only the defaults that must hold
  // when their fluent setter is never called; the Builder writes the remaining
  // fields directly and finishBuild() applies the derived/hydration state.
  private StepContext() {
    this.workflowVersion = 1;
    this.attempt = 1;
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
    this.stepLog = new StepLog();
    this.stepProgress = new StepProgress();
    this.stepEmitter = new StepEmitter();
    this.stepRetry = new StepRetryInfo();
    this.stepRetry.setMaxAttempts(1);
    this.stepSignals = new StepSignals(b.signalSourceVal);
    applyPendingSignals(b);
    if (b.timeoutResumeVal == true) {
      this.stepRetry.markTimeoutResume();
    }
    if (b.attemptVal != null && b.attemptVal > 0) {
      this.attempt = b.attemptVal;
    }
    if (b.maxAttemptsVal != null && b.maxAttemptsVal > 0) {
      this.stepRetry.setMaxAttempts(b.maxAttemptsVal);
    }
    this.stepCaptures = new StepCaptures(this, this.stepVisit, this.stepRetry);
    applyCapturedValues(b);
    return this;
  }

  private void applyPendingSignals(Builder b) {
    if (!b.pendingSignalsProvided) {
      return;
    }
    // Explicit pending-signal list (used by tests): already resolved, so no
    // lazy source load is needed.
    this.stepSignals.seedPendingSignals(
      (b.pendingSignalsVal != null) ? b.pendingSignalsVal : new List<Signal>()
    );
  }

  // Assigns the pre-parsed (or JSON-parsed) captured values onto StepCaptures,
  // which extracts the reserved retry/error bookkeeping keys, mirroring the
  // former withCapturedValuesMap factory. No-op for the plain-constructor path.
  private void applyCapturedValues(Builder b) {
    Map<String, Object> cv = b.capturedValuesMapVal;
    if (cv == null && b.capturesJsonProvided) {
      cv = StepCaptureSerde.parseCaptures(b.capturedValuesJsonVal);
    }
    if (cv == null) {
      return;
    }
    this.stepCaptures.applyCapturedValues(cv);
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
    private SignalSource signalSourceVal;
    private List<Signal> pendingSignalsVal;
    private Boolean pendingSignalsProvided = false;
    private Map<String, Object> capturedValuesMapVal;
    private String capturedValuesJsonVal;
    private Boolean capturesJsonProvided = false;
    private Boolean timeoutResumeVal = false;
    private Integer attemptVal = 1;
    private Integer maxAttemptsVal = 1;

    /**
     * @description Sets the workflow instance id for the context.
     * @param val The Workflow_Instance__c id.
     * @return This builder, for chaining.
     */
    public Builder instanceId(Id val) {
      ctx.workflowInstanceId = val;
      return this;
    }

    /**
     * @description Sets the workflow definition name for the context.
     * @param val The workflow developer name.
     * @return This builder, for chaining.
     */
    public Builder workflowName(String val) {
      ctx.workflowName = val;
      return this;
    }

    /**
     * @description Sets the name of the step this context represents.
     * @param val The step name.
     * @return This builder, for chaining.
     */
    public Builder stepName(String val) {
      ctx.stepName = val;
      return this;
    }

    /**
     * @description Sets the JSON input passed to this step.
     * @param val The step input JSON.
     * @return This builder, for chaining.
     */
    public Builder inputJson(String val) {
      ctx.inputJson = val;
      return this;
    }

    /**
     * @description Sets the JSON output produced by the preceding step.
     * @param val The previous step's output JSON.
     * @return This builder, for chaining.
     */
    public Builder previousStepOutput(String val) {
      ctx.previousStepOutput = val;
      return this;
    }

    /**
     * @description Sets the durable per-step state JSON for this step.
     * @param val The step state JSON.
     * @return This builder, for chaining.
     */
    public Builder stepStateJson(String val) {
      ctx.stepStateJson = val;
      return this;
    }

    /**
     * @description Sets the JSON input the workflow instance was started with.
     * @param val The workflow input JSON.
     * @return This builder, for chaining.
     */
    public Builder workflowInputJson(String val) {
      ctx.workflowInputJson = val;
      return this;
    }

    /**
     * @description Sets the workflow definition version this instance is pinned
     * to.
     * @param val The workflow version.
     * @return This builder, for chaining.
     */
    public Builder workflowVersion(Integer val) {
      ctx.workflowVersion = val;
      return this;
    }

    /**
     * @description Sets the 0-based visit sequence of this step within the
     * instance, used to scope the idempotency key and capture-once state.
     * @param val The step visit sequence.
     * @return This builder, for chaining.
     */
    public Builder stepVisit(Integer val) {
      this.stepVisitVal = val;
      return this;
    }

    /**
     * @description Sets the lazy signal source; signals are not loaded until an
     * accessor is actually called.
     * @param val The SignalSource implementation.
     * @return This builder, for chaining.
     */
    public Builder signalSource(SignalSource val) {
      // Defer loading until a signal accessor is actually called.
      this.signalSourceVal = val;
      return this;
    }

    /**
     * @description Supplies an explicit, already-resolved pending-signal list
     * (used by tests) instead of a lazy source.
     * @param val The pending signals to expose.
     * @return This builder, for chaining.
     */
    public Builder pendingSignals(List<Signal> val) {
      this.pendingSignalsVal = val;
      this.pendingSignalsProvided = true;
      return this;
    }

    /**
     * @description Sets the predecessor instance start time used as an
     * incremental-query polling cursor.
     * @param val The previous run's start timestamp.
     * @return This builder, for chaining.
     */
    public Builder previousRunAt(Datetime val) {
      ctx.previousRunAt = val;
      return this;
    }

    /**
     * @description Seeds the capture-once values from an already-parsed map so
     * once() replays prior values without invoking producers.
     * @param val The captured values map.
     * @return This builder, for chaining.
     */
    public Builder capturedValuesMap(Map<String, Object> val) {
      this.capturedValuesMapVal = val;
      return this;
    }

    /**
     * @description Seeds the capture-once values from a stored JSON payload,
     * parsed during build.
     * @param val The captured values JSON.
     * @return This builder, for chaining.
     */
    public Builder capturedValuesJson(String val) {
      this.capturedValuesJsonVal = val;
      this.capturesJsonProvided = true;
      return this;
    }

    /**
     * @description Sets the 1-based attempt number for this step execution.
     * @param val The attempt number.
     * @return This builder, for chaining.
     */
    public Builder attempt(Integer val) {
      this.attemptVal = val;
      return this;
    }

    /**
     * @description Sets the maximum number of attempts permitted for this step.
     * @param val The maximum attempts.
     * @return This builder, for chaining.
     */
    public Builder maxAttempts(Integer val) {
      this.maxAttemptsVal = val;
      return this;
    }

    /**
     * @description Marks this context as the engine-routed timeout fallback
     * (issue #35).
     * @return This builder, for chaining.
     */
    public Builder markTimeoutResume() {
      this.timeoutResumeVal = true;
      return this;
    }

    /**
     * @description Finalizes construction, applying the derived and hydration
     * state, and returns the built StepContext.
     * @return The fully constructed StepContext.
     */
    public StepContext build() {
      return ctx.finishBuild(this);
    }
  }

  /**
   * Checks if the current transaction is approaching governor limits.
   * Returns true if any monitored limit (CPU, SOQL, DML statements, DML rows, or Heap size) is > 80% consumed.
   *
   * @return True if the transaction is nearing a governor limit and the step
   * should yield.
   */
  public Boolean shouldYield() {
    return StepGovernor.isNearingLimit();
  }

  /**
   * Derives the idempotency key from logical (instance, step, visit) identity
   * only. SHA-256 keeps it opaque, uniform-length, and safe to forward verbatim
   * as an external idempotency token.
   *
   * @param instanceId The workflow instance id.
   * @param stepName The step name.
   * @param stepVisit The step's visit sequence within the instance.
   * @return The hex-encoded SHA-256 idempotency key.
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

  /**
   * @description Read-only result of a child (sub-workflow) execution, resolved
   * from the ChildCompleted/ChildFailed signals a parent step observes.
   */
  public class ChildOutcome {
    /** The child's terminal status, e.g. 'Completed' or 'Failed'. */
    public String status { get; private set; }
    /** The child's error message when it failed, else null. */
    public String errorMessage { get; private set; }
    /** The child's output payload, resolved from its completion signal. */
    public String output { get; private set; }
    private Boolean present = false;

    /**
     * @description Constructs an empty (not-present) outcome, used when no child
     * result signal is pending for the key.
     */
    public ChildOutcome() {
      this.present = false;
    }

    /**
     * @description Constructs a present outcome from a resolved child result.
     * @param status The child's terminal status.
     * @param errorMessage The child's error message, or null.
     * @param output The child's output payload, or null.
     */
    public ChildOutcome(String status, String errorMessage, String output) {
      this.status = status;
      this.errorMessage = errorMessage;
      this.output = output;
      this.present = true;
    }

    /**
     * @description True when a child result was found for this key (not the
     * empty sentinel).
     * @return True if this outcome represents a real child result.
     */
    public Boolean isPresent() {
      return this.present;
    }

    /**
     * @description True when the child completed successfully.
     * @return True if the child's status is 'Completed'.
     */
    public Boolean isSuccess() {
      return this.status == 'Completed';
    }
  }
}
