/**
 * @description Core durable-execution engine for Revenant. Admits, advances and
 * finalizes `Workflow_Instance__c` runs by executing their `WorkflowStep` units
 * against a durable `StepContext`, preserving step state transitions and event
 * emissions effectively-once. Owns start/get-or-start deduplication, signal
 * routing, saga compensation, child-workflow orchestration, timeout/retry/sleep
 * scheduling and the watchdog heartbeat that reclaims stalled work. All DML and
 * SOQL run in system mode so the engine can drive workflows regardless of the
 * invoking user's object permissions.
 */
public inherited sharing class WorkflowEngine {
  public static Set<Id> resumedInstanceIds = new Set<Id>();
  public static Boolean disableQueueableInTest = false;
  public static Integer watchdogDelayMinutes = 10;
  public static Boolean useDynamicScheduling = true;
  // Operator toggle (Revenant_Config__mdt.Publish_Lifecycle_Events__c): when true
  // the engine publishes a Workflow_Lifecycle__e event on terminal transitions.
  public static Boolean publishLifecycleEvents = true;

  // Failure Category picklist API values
  public static final String CAT_STEP_EXCEPTION = 'STEP_EXCEPTION';
  public static final String CAT_RETRIES_EXHAUSTED = 'RETRIES_EXHAUSTED';
  public static final String CAT_TIMEOUT = 'TIMEOUT';
  public static final String CAT_COMPENSATION_FAILED = 'COMPENSATION_FAILED';
  public static final String CAT_EXPLICIT_FAIL = 'EXPLICIT_FAIL';
  public static final String CAT_UNKNOWN = 'UNKNOWN';

  // Get-or-start dedup window in minutes. Redelivered starts whose correlation
  // key matches a terminal instance that became terminal within this many
  // minutes resolve to that instance instead of spawning a duplicate. Set to 0
  // to preserve active-only dedup behavior.
  public static Integer dedupWindowMinutes = 1440;

  // Minutes of inactivity after which a Suspended instance with no active resume
  // mechanism is classified as stalled on the dashboard. Configurable via
  // Revenant_Config__mdt.Stale_Threshold_Minutes__c; default 60 minutes.
  public static Integer staleThresholdMinutes = 60;
  public static Integer reclaimThresholdMinutes = null;
  @TestVisible
  public static Datetime mockNow = null;

  // Instances in these statuses are considered in-flight; a start that collides
  // with one of them always dedups to the existing instance.
  public static final Set<String> ACTIVE_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended',
    'Compensating',
    'Cancelling',
    // A stalled rollback is non-terminal: it still has un-reversed side effects and
    // can be resumed, so it must keep reserving its correlation key to prevent a
    // duplicate active workflow from starting with the same key while half-undone.
    'CompensationFailed',
    // A parked (operator-paused) run is in-flight and resumes later, so it keeps
    // reserving its correlation key — mirroring the trigger's reservation — so dedup
    // returns the live paused instance rather than a stale terminal row in the window.
    'Paused'
  };

  // Upper bound on rows read by a single dedup lookup, so a hot correlation key
  // with many historical terminal runs cannot exhaust the SOQL row governor.
  // Single-key lookups (the common start path) read only the top row.
  // Public (non-final) so tests can shrink it to exercise the cap cheaply and so
  // the extracted status-read winner resolver can honor the same governor cap.
  public static Integer dedupLookupRowCap = 10000;

  // Search Attributes configuration limits
  public static final Integer MAX_ATTRIBUTES_PER_INSTANCE = 10;
  public static final Integer MAX_ATTRIBUTE_KEY_LENGTH = 100;
  public static final Integer MAX_ATTRIBUTE_VALUE_LENGTH = 150;

  // Caps how many signals a serial step may observe in one execution. Serial
  // steps never claim (no read-side DML), so the only DML is the COMPLETE
  // consume; 8 000 keeps the consume update (matched ids + same-name duplicate
  // cleanup) safely under the 10 000 DML-row limit while never exposing more
  // rows than completion can consume. Excess rows stay Received for a later read.
  // @TestVisible (non-final) so a test can shrink the cap to exercise budget
  // exhaustion without inserting thousands of rows.
  @TestVisible
  private static Integer serialSignalRowCap = 8000;

  // Caps how many signals a single parallel-branch accessor call claims at read
  // time. A claim writes Processing now and the matching COMPLETE writes
  // Consumed later in the SAME transaction, so claim + consume both draw on the
  // 10 000 DML-row governor limit; 4 000 leaves headroom for the consume pass
  // and the engine's other DML. Bounding the claim keeps a branch facing a huge
  // redelivery backlog from blowing the limit on every attempt and stalling
  // forever; any rows beyond the cap stay Received for a later read.
  private static final Integer PARALLEL_CLAIM_ROW_CAP = 4000;
  // Caps how many claim DML *statements* a parallel branch issues in one
  // execution. Each named getSignal/hasSignal (and each getSignals page) is one
  // update statement, so a fan-in step probing many distinct names could exceed
  // the 150 DML-statement governor limit; once this budget is spent the branch
  // reads remaining signals WITHOUT claiming (at-least-once). 100 leaves room
  // for the consume statement and the engine's other DML.
  private static final Integer PARALLEL_CLAIM_STATEMENT_BUDGET = 100;
  // How many times a parallel getSignals() re-pages past a fully-lost candidate
  // page (every row claimed by a sibling between query and lock) before giving
  // up, so a loser does not return empty while later Received rows remain.
  private static final Integer PARALLEL_CLAIM_PAGE_RETRIES = 3;

  static {
    try {
      List<Revenant_Config__mdt> configs = [
        SELECT
          Watchdog_Delay_Minutes__c,
          Use_Dynamic_Scheduling__c,
          Publish_Lifecycle_Events__c,
          Dedup_Window_Minutes__c,
          Stale_Threshold_Minutes__c,
          Reclaim_Threshold_Minutes__c
        FROM Revenant_Config__mdt
        WHERE DeveloperName = 'Default'
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (!configs.isEmpty()) {
        if (configs[0].Watchdog_Delay_Minutes__c != null) {
          watchdogDelayMinutes = configs[0]
            .Watchdog_Delay_Minutes__c.intValue();
        }
        if (configs[0].Use_Dynamic_Scheduling__c != null) {
          useDynamicScheduling = configs[0].Use_Dynamic_Scheduling__c;
        }
        if (configs[0].Publish_Lifecycle_Events__c != null) {
          publishLifecycleEvents = configs[0].Publish_Lifecycle_Events__c;
        }
        if (configs[0].Dedup_Window_Minutes__c != null) {
          dedupWindowMinutes = configs[0].Dedup_Window_Minutes__c.intValue();
        }
        if (configs[0].Stale_Threshold_Minutes__c != null) {
          staleThresholdMinutes = configs[0]
            .Stale_Threshold_Minutes__c.intValue();
        }
        if (configs[0].Reclaim_Threshold_Minutes__c != null) {
          reclaimThresholdMinutes = configs[0]
            .Reclaim_Threshold_Minutes__c.intValue();
        }
      }
    } catch (Exception ignored) {
      // Configuration metadata is optional; fall back to defaults on any read failure.
    }
  }

  /**
   * @description Exception type raised by the engine for workflow-level faults,
   * including step failures surfaced by injected test faults and invalid engine
   * operations. Distinguishes engine-originated errors from arbitrary step
   * exceptions.
   */
  public class WorkflowException extends Exception {
  }

  /**
   * Outcome of a get-or-start admission decision. Distinguishes a brand-new
   * instance from an existing instance returned for a deduplicated redelivery.
   */
  public class StartResult {
    public Id instanceId;
    // true when a new instance was inserted; false when an existing instance
    // was returned (deduped active or recently-terminal redelivery).
    public Boolean isNew;

    /**
     * @description Builds an admission result for an existing (deduplicated)
     * instance. Call markNew() to flag a newly-inserted instance.
     * @param instanceId Id of the resolved workflow instance
     */
    public StartResult(Id instanceId) {
      this.instanceId = instanceId;
      this.isNew = false;
    }

    /**
     * @description Flags this result as a newly-inserted instance and returns it
     * for fluent construction.
     * @return this StartResult with isNew set to true
     */
    public StartResult markNew() {
      this.isNew = true;
      return this;
    }
  }

  // ─── Read API ──────────────────────────────────────────────────────────────

  /**
   * Stable read-only DTO returned by the workflow read API. All fields are
   * read-only to callers (private setters); the engine's read layer populates
   * them once via the all-arguments constructor.
   */
  public class WorkflowStatus {
    /** @description Salesforce Id of the workflow instance. */
    public Id instanceId { get; private set; }
    /** @description Developer name of the workflow definition. */
    public String definitionName { get; private set; }
    /** @description Correlation key the instance was started with. */
    public String correlationKey { get; private set; }
    /** @description Current lifecycle status of the instance. */
    public String status { get; private set; }
    /** @description True when the status is a terminal outcome. */
    public Boolean isTerminal { get; private set; }
    /** @description Failure message for a failed instance; null otherwise. */
    public String errorMessage { get; private set; }
    /**
     * @description Fully rehydrated output for terminal instances; null for
     * in-flight instances.
     */
    public String output { get; private set; }
    /** @description Causation Id linking this run to the event that caused it. */
    public String causationId { get; private set; }

    /**
     * @description Builds a fully-populated status DTO from a queried instance
     * and its pre-resolved (rehydrated) terminal output. Used by the extracted
     * read layer ({@link WorkflowStatusRead}); fields remain read-only to callers
     * after construction. Terminality and the cleaned causation Id are derived
     * here so the read layer never touches the private setters.
     * @param inst the queried workflow instance row to project
     * @param output the rehydrated terminal output, or null when in-flight
     */
    public WorkflowStatus(Workflow_Instance__c inst, String output) {
      this.instanceId = inst.Id;
      this.definitionName = inst.Workflow_Name__c;
      this.correlationKey = inst.Correlation_Key__c;
      this.status = inst.Status__c;
      this.isTerminal = WorkflowStatusRead.TERMINAL_GETSTATUS_STATUSES.contains(
        inst.Status__c
      );
      this.errorMessage = inst.Error_Message__c;
      this.output = output;
      this.causationId = WorkflowCausationParser.cleanCausationId(
        inst.Causation_Id__c
      );
    }
  }

  /**
   * Stable read-only DTO for a single step execution in an instance's timeline.
   * A forever-public API contract: v1 is metadata-only (no per-step input/output
   * payload bodies). All fields are read-only to callers (private setters); the
   * read layer populates them once via the constructor.
   */
  public class StepHistoryEntry {
    /** @description Salesforce Id of the step-execution row (stable identifier). */
    public Id executionId { get; private set; }
    /**
     * @description Logical step name. Compensation executions carry the
     * `<step>_Compensate` name; use {@link #isCompensation} to distinguish them.
     */
    public String stepName { get; private set; }
    /**
     * @description Raw `Status__c` of the step execution. One of the engine's
     * eleven step statuses: terminal — `Completed`, `Failed`, `Compensated`,
     * `Cancelled`, `OperatorSkipped`, `ContinuedAsNew`; in flight — `Pending`,
     * `Running`, `Retrying`, `Compensating`, `Cancelling`. A terminal status
     * settles `endedAt`/`totalDurationMs`; an in-flight status leaves them null.
     */
    public String status { get; private set; }
    /** @description Retry attempt count for this step (0 on the first attempt). */
    public Integer attempt { get; private set; }
    /** @description When this step execution was first appended to the trail. */
    public Datetime startedAt { get; private set; }
    /**
     * @description Last modification time of the terminal step-execution row (the
     * engine reuses one row across retries, so this is the last modification, not
     * per-attempt); null while the step is still in flight.
     */
    public Datetime endedAt { get; private set; }
    /**
     * @description Total wall-clock from `startedAt` to `endedAt` in milliseconds,
     * across ALL attempts including retry backoff — not a single attempt's
     * duration, because the engine reuses one step-execution row for every retry.
     * Use `attempt` to disambiguate a retried row. Null while in flight.
     */
    public Long totalDurationMs { get; private set; }
    /**
     * @description Whether this step-execution row currently has error detail
     * recorded (`Error_Details__c` is populated). The timeline is payload-free: the
     * error text itself is NOT loaded here (it can be a 131k long-text field);
     * fetch it per-step via {@link WorkflowHistoryRead#getStepError}. Because the
     * engine reuses one row across retries, `hasError` reflects the row's CURRENT
     * (last-attempt) error state — a step that errored and then retried to success
     * can still be `hasError = true` with a terminal-success `status`, so this is
     * NOT equivalent to `status`.
     */
    public Boolean hasError { get; private set; }
    /**
     * @description True when this row is a compensation (rollback) execution,
     * false for a forward execution. Convention-derived: it is inferred from the
     * step name ending in the engine's `_Compensate` suffix, so a step an author
     * manually names ending in `_Compensate` would be a false positive.
     */
    public Boolean isCompensation { get; private set; }

    /**
     * @description Builds a fully-populated history entry from a queried
     * step-execution row. Terminality (and therefore `endedAt`/`totalDurationMs`),
     * the compensation flag, and the normalized attempt count are derived here so
     * the read layer never touches the private setters. `hasError` is set from the
     * pre-resolved set of execution Ids that have error detail — the read layer
     * resolves that with a bounded Id-only probe, so no long-text is loaded here.
     * Used by the extracted read layer ({@link WorkflowHistoryRead}).
     * @param row the queried `Workflow_Step_Execution__c` row to project
     * @param errorExecutionIds Ids of rows with non-null `Error_Details__c`
     */
    public StepHistoryEntry(
      Workflow_Step_Execution__c row,
      Set<Id> errorExecutionIds
    ) {
      this.executionId = row.Id;
      this.stepName = row.Step_Name__c;
      this.status = row.Status__c;
      this.attempt = row.Retry_Count__c == null
        ? 0
        : row.Retry_Count__c.intValue();
      this.startedAt = row.CreatedDate;
      Boolean isTerminal = WorkflowHistoryRead.TERMINAL_STEP_STATUSES.contains(
        row.Status__c
      );
      this.endedAt = isTerminal ? row.LastModifiedDate : null;
      this.totalDurationMs = (isTerminal &&
        this.startedAt != null &&
        this.endedAt != null)
        ? this.endedAt.getTime() - this.startedAt.getTime()
        : null;
      this.hasError =
        errorExecutionIds != null && errorExecutionIds.contains(row.Id);
      this.isCompensation =
        row.Step_Name__c != null && row.Step_Name__c.endsWith('_Compensate');
    }
  }

  /**
   * Stable read-only wrapper returned by the history read API for one instance:
   * the ordered `StepHistoryEntry` list plus an explicit truncation flag so a
   * capped history is never silently cut. Forever-public contract; fields are
   * read-only to callers (private setters).
   */
  public class StepHistory {
    /**
     * @description The step-execution entries in append (execution) order,
     * capped at {@link WorkflowHistoryRead#MAX_HISTORY_ROWS}. Empty for a known
     * instance that has not yet logged a step.
     */
    public List<StepHistoryEntry> entries { get; private set; }
    /**
     * @description True when the instance's real step total exceeds the retained
     * `entries` — either the history was cut at the row cap, or (in a bulk read) the
     * instance was starved of scan budget by a larger sibling in the same batch.
     * Either way `totalCount` still reports the real total, so a step-bearing
     * instance is never returned as an empty (`isTruncated = false`) history.
     */
    public Boolean isTruncated { get; private set; }
    /**
     * @description The real total number of step executions for the instance,
     * supplied authoritatively by the read layer. Equals `entries.size()` exactly
     * when nothing was dropped; when `isTruncated` is true it is the real total
     * (from a `COUNT()` query) even though `entries` is capped or partial, so
     * callers always know the full size. `0` for a known instance with no steps.
     */
    public Integer totalCount { get; private set; }

    /**
     * @description Projects a set of queried, append-ordered step-execution rows
     * for one instance into the capped `entries` list, and derives `isTruncated`
     * from the authoritative `totalCount` versus the retained entry count (so a
     * scan-starved bulk instance is flagged truncated, never false-empty). Mirrors
     * the projecting constructor of {@link WorkflowStatus}; used by the extracted
     * read layer ({@link WorkflowHistoryRead}), which supplies `totalCount` so this
     * DTO stays SOQL-free.
     * @param rows the instance's retained step-execution rows in append order
     * @param totalCount the real total step-execution count for the instance
     * @param errorExecutionIds Ids of rows with non-null `Error_Details__c`, used
     * to set each entry's `hasError` without loading the error text
     */
    public StepHistory(
      List<Workflow_Step_Execution__c> rows,
      Integer totalCount,
      Set<Id> errorExecutionIds
    ) {
      this.entries = new List<StepHistoryEntry>();
      Integer rowCap = WorkflowHistoryRead.MAX_HISTORY_ROWS;
      Integer rowCount = rows == null ? 0 : rows.size();
      Integer take = rowCount > rowCap ? rowCap : rowCount;
      for (Integer i = 0; i < take; i++) {
        this.entries.add(new StepHistoryEntry(rows[i], errorExecutionIds));
      }
      this.totalCount = totalCount;
      this.isTruncated = totalCount > this.entries.size();
    }
  }

  // ─── End Read API ──────────────────────────────────────────────────────────

  /**
   * Starts a new durable workflow instance (get-or-start). Delegates to
   * {@link WorkflowStartService}; if an instance with the same correlation key
   * already exists within the dedup scope, returns that instance's Id instead of
   * inserting a duplicate.
   * @param workflowName developer name of the workflow definition to start
   * @param correlationKey dedup/correlation key for the instance
   * @param input start input payload passed to the first step
   * @return Id of the new or deduplicated existing instance
   */
  public static Id start(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    return WorkflowStartService.startOne(workflowName, correlationKey, input);
  }

  /**
   * @description Get-or-start from a fully-built request. Delegates to
   * {@link WorkflowStartService}.
   * @param request the start request describing the instance to get-or-start
   * @return Id of the new or deduplicated existing instance
   */
  public static Id start(StartRequest request) {
    return WorkflowStartService.startOne(request);
  }

  /**
   * Get-or-start variant that exposes whether a new instance was created or an
   * existing one was returned. Delegates to {@link WorkflowStartService}.
   * @param workflowName developer name of the workflow definition to start
   * @param correlationKey dedup/correlation key for the instance
   * @param input start input payload passed to the first step
   * @return a StartResult carrying the instance Id and whether it was newly created
   */
  public static StartResult startOrGet(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    return WorkflowStartService.startOrGetOne(
      workflowName,
      correlationKey,
      input
    );
  }

  /**
   * @description startOrGet from a fully-built request. Delegates to
   * {@link WorkflowStartService}.
   * @param request the start request describing the instance to get-or-start
   * @return a StartResult carrying the instance Id and whether it was newly created
   */
  public static StartResult startOrGet(StartRequest request) {
    return WorkflowStartService.startOrGetOne(request);
  }

  /**
   * @description Input DTO for a single get-or-start request in the bulk start
   * and signalOrStart APIs. Carries the definition name, correlation key, start
   * input (as an Object or pre-serialized JSON), and optional parent reference,
   * searchable attributes and causation id.
   */
  public class StartRequest {
    public String workflowName;
    public String correlationKey;
    public Object input;
    public String inputJson;
    public Id parentInstanceId;
    public Map<String, String> attributes;
    public String causationId;

    /**
     * @description Builds a minimal start request.
     * @param workflowName developer name of the workflow definition
     * @param correlationKey dedup/correlation key
     * @param input start input payload
     */
    public StartRequest(
      String workflowName,
      String correlationKey,
      Object input
    ) {
      this.workflowName = workflowName;
      this.correlationKey = correlationKey;
      this.input = input;
    }

    /**
     * @description Fluent setter stamping searchable attributes on the request.
     * @param attributesArg searchable key/value attributes
     * @return this request, for call chaining
     */
    public StartRequest withAttributes(Map<String, String> attributesArg) {
      this.attributes = attributesArg;
      return this;
    }

    /**
     * @description Fluent setter linking the request to a parent instance.
     * @param parentInstanceIdArg Id of the parent workflow instance
     * @return this request, for call chaining
     */
    public StartRequest withParent(Id parentInstanceIdArg) {
      this.parentInstanceId = parentInstanceIdArg;
      return this;
    }
  }

  /**
   * @description Input DTO for the bulk resume API. Targets an instance either by
   * correlation key or by Id, along with the resume payload.
   */
  public class ResumeRequest {
    public String correlationKey;
    public Id instanceId;
    public String payload;

    /**
     * @description Builds a resume request targeting by correlation key.
     * @param correlationKey correlation key of the instance to resume
     * @param payload resume payload delivered to the waiting step
     */
    public ResumeRequest(String correlationKey, String payload) {
      this.correlationKey = correlationKey;
      this.payload = payload;
    }

    /**
     * @description Builds a resume request targeting by instance Id.
     * @param instanceId Id of the instance to resume
     * @param payload resume payload delivered to the waiting step
     */
    public ResumeRequest(Id instanceId, String payload) {
      this.instanceId = instanceId;
      this.payload = payload;
    }
  }

  /**
   * @description Input DTO for the bulk signal API. Targets an instance by
   * correlation key or Id and carries the signal name, payload and optional
   * dedup/idempotency keys for effectively-once delivery.
   */
  public class SignalRequest {
    public String keyOrId;
    public String signalName;
    public String payload;
    public String dedupKey;
    public String idempotencyKey;

    /**
     * @description Builds a signal request without dedup keys.
     * @param keyOrId correlation key or instance Id of the target
     * @param signalName name of the signal
     * @param payload signal payload
     */
    public SignalRequest(String keyOrId, String signalName, String payload) {
      this.keyOrId = keyOrId;
      this.signalName = signalName;
      this.payload = payload;
    }

    /**
     * @description Fluent setter stamping a routing-level dedup key.
     * @param dedupKeyArg routing-level dedup key
     * @return this request, for call chaining
     */
    public SignalRequest withDedupKey(String dedupKeyArg) {
      this.dedupKey = dedupKeyArg;
      return this;
    }

    /**
     * @description Fluent setter stamping a per-delivery idempotency key.
     * @param idempotencyKeyArg per-delivery idempotency key
     * @return this request, for call chaining
     */
    public SignalRequest withIdempotencyKey(String idempotencyKeyArg) {
      this.idempotencyKey = idempotencyKeyArg;
      return this;
    }
  }

  /**
   * @description Input DTO for the signal-or-start API: signals an existing
   * instance matching the embedded start request's correlation key, or starts a
   * new one when none exists.
   */
  public class SignalOrStartRequest {
    public StartRequest start;
    public String signalName;
    public String payload;
    public String idempotencyKey;

    /**
     * @description Builds a signal-or-start request.
     * @param start start request used to resolve or create the target instance
     * @param signalName name of the signal to deliver
     * @param payload signal payload
     */
    public SignalOrStartRequest(
      StartRequest start,
      String signalName,
      String payload
    ) {
      this.start = start;
      this.signalName = signalName;
      this.payload = payload;
    }

    /**
     * @description Fluent setter stamping a per-delivery idempotency key.
     * @param idempotencyKeyArg per-delivery idempotency key
     * @return this request, for call chaining
     */
    public SignalOrStartRequest withIdempotencyKey(String idempotencyKeyArg) {
      this.idempotencyKey = idempotencyKeyArg;
      return this;
    }
  }

  /**
   * Starts multiple durable workflow instances in a bulk-friendly transaction
   * (get-or-start). Delegates to {@link WorkflowStartService}. A duplicate
   * correlation key resolves to the existing instance and never faults sibling
   * requests in the same invocation.
   * @param requests the start requests to process
   * @return instance Ids index-aligned with requests (null per null request)
   */
  public static List<Id> start(List<StartRequest> requests) {
    return WorkflowStartService.startBulk(requests);
  }

  /**
   * Bulk get-or-start. Delegates to {@link WorkflowStartService}. Returns a
   * result per request (index-aligned) reporting the resolved instance Id and
   * whether it was newly created or deduped.
   * @param requests the start requests to process
   * @return StartResults index-aligned with requests (null per null request)
   */
  public static List<StartResult> startOrGet(List<StartRequest> requests) {
    return WorkflowStartService.startOrGetBulk(requests);
  }

  /**
   * @description Single-request convenience for signalOrStart: delivers a signal
   * to the instance resolved from the request's embedded start correlation key,
   * starting a new instance first when none exists.
   * @param req the signal-or-start request (embedded start request, signal name,
   * payload and optional idempotency key)
   * @return the StartResult for the resolved or created instance
   */
  public static StartResult signalOrStart(SignalOrStartRequest req) {
    return WorkflowSignalOrStartService.signalOrStartBulk(
      new List<SignalOrStartRequest>{ req }
    )[0];
  }

  /**
   * @description Bulk signal-or-start. For each request, resolves the target
   * instance by the embedded start request's correlation key and delivers the
   * signal, starting a new instance when none exists. Runs under a savepoint so a
   * mid-batch failure rolls back cleanly.
   * @param requests the signal-or-start requests to process
   * @return StartResults index-aligned with requests
   */
  public static List<StartResult> signalOrStart(
    List<SignalOrStartRequest> requests
  ) {
    return WorkflowSignalOrStartService.signalOrStartBulk(requests);
  }

  /**
   * @description Executes the active step for a workflow instance. Designed to
   * run in a Queueable context. Delegates to `WorkflowStepRunner`, which owns the
   * admission and lock ordering and the step invocation.
   * @param instanceId Id of the instance whose active step is executed
   */
  public static void runStep(Id instanceId) {
    WorkflowStepRunner.runStepById(instanceId);
  }

  /**
   * @description Executes a single step of a workflow instance and durably
   * persists its outcome. Delegates to `WorkflowStepRunner.runStepNamed`, the
   * engine's core step-execution entry point, run inside a Queueable.
   * @param instanceId Id of the instance to advance
   * @param stepName name of the step to run, or null to run the instance's
   * current step
   */
  public static void runStep(Id instanceId, String stepName) {
    WorkflowStepRunner.runStepNamed(instanceId, stepName);
  }

  /**
   * @description Internal wrapper bundling the values threaded through the
   * step-outcome handlers (handleStepResult, handleCompensationStepResult,
   * persistStepBreadcrumbs) so each takes a single parameter instead of a long
   * positional list. Populated field-by-field to avoid a wide constructor.
   */
  public class StepOutcomeContext {
    public Workflow_Instance__c instance;
    public Workflow_Step_Execution__c stepExec;
    public StepResult result;
    public List<String> stack;
    public StepContext context;
    public Boolean isParallel;
  }

  /**
   * Rescues a workflow when the host transaction fails or hits governor limits.
   * Invoked from a System.Finalizer.
   * @param instanceId Id of the instance whose transaction crashed
   * @param ex the exception that caused the crash
   */
  public static void handleCrash(Id instanceId, Exception ex) {
    WorkflowCrashHandler.processCrash(instanceId, null, ex);
  }

  /**
   * @description Rescues a crashed or governor-limited step in its own DML
   * transaction so the outcome is durable even when the parent transaction rolled
   * back. Re-drives the step on a transient row-lock error (within the retry
   * budget); otherwise fails the workflow with the crash details.
   * @param instanceId Id of the instance to rescue
   * @param stepName name of the step that crashed, or null when unknown
   * @param ex the exception that caused the crash
   */
  public static void handleCrash(Id instanceId, String stepName, Exception ex) {
    WorkflowCrashHandler.processCrash(instanceId, stepName, ex);
  }

  /**
   * @description Request DTO for failing a workflow instance. Carries the target
   * (by Id, or by pre-queried record on the resolved path), the failing step, the
   * error message, the failure category, and — on the resolved path — the attempt
   * count. Populated field-by-field to avoid a wide constructor.
   */
  public class FailInstanceRequest {
    public Id instanceId;
    public Workflow_Instance__c instance;
    public String stepName;
    public String errorMessage;
    public String failureCategory;
    public Integer attemptCount;
  }

  /**
   * Transitions a workflow instance to Failed or Compensating state.
   * @param instanceId Id of the instance to fail
   * @param stepName name of the step that failed
   * @param errorMessage failure message to record
   */
  public static void failWorkflowInstance(
    Id instanceId,
    String stepName,
    String errorMessage
  ) {
    FailInstanceRequest req = new FailInstanceRequest();
    req.instanceId = instanceId;
    req.stepName = stepName;
    req.errorMessage = errorMessage;
    req.failureCategory = CAT_UNKNOWN;
    WorkflowFailureService.failInstance(req);
  }

  /**
   * @description Fails an instance with an explicit failure category, resolving
   * the current attempt count from the step's latest execution before delegating
   * to the record-level path.
   * @param req the fail request (instanceId, stepName, errorMessage, failureCategory)
   */
  public static void failWorkflowInstance(FailInstanceRequest req) {
    WorkflowFailureService.failInstance(req);
  }

  /**
   * Sends an external signal to a workflow instance by correlation key or instance ID.
   * @param keyOrId correlation key or instance Id of the target
   * @param signalName name of the signal to deliver
   * @param payload signal payload
   */
  public static void signal(String keyOrId, String signalName, String payload) {
    WorkflowSignalRouter.routeSignalRequest(
      new SignalRequest(keyOrId, signalName, payload)
    );
  }

  /**
   * Sends an external signal with an optional caller-supplied idempotency key.
   * When idempotencyKey is non-blank, at-most-once delivery is enforced per
   * (instance, key) pair: a duplicate with the same key is swallowed as a
   * successful no-op — no error is returned and no second wake-up fires. Dedup
   * is constraint-based (unique Signal_Key__c per instance hash) so it holds
   * across concurrent transactions without adding SOQL to the hot path.
   * Passing null preserves the existing at-least-once behavior.
   * @param req the signal request (keyOrId, signalName, payload and optional
   * idempotencyKey); when idempotencyKey is null, at-least-once behavior applies
   */
  public static void signal(SignalRequest req) {
    WorkflowSignalRouter.routeSignalRequest(req);
  }

  /**
   * Sends external signals to multiple workflow instances in bulk. Orchestrates
   * the six phases (in order, preserving the original all-or-none and in-batch
   * cancel-before-sibling semantics): classify targets, lock/load instances,
   * capture unmatched requests, run the keyed-cancel pre-pass, partition the
   * forward signals, insert the rows, then wake and enqueue.
   * @param requests the signal requests to deliver
   */
  public static void signal(List<SignalRequest> requests) {
    WorkflowSignalBatch.routeSignalBatch(requests);
  }

  /**
   * Cancels a workflow instance (and its active descendants) and aborts scheduled
   * jobs WITHOUT running saga compensations.
   * @param instanceId Id of the target instance to cancel (with its active descendants)
   */
  public static void cancel(Id instanceId) {
    cancelInstance(instanceId, false);
  }

  /**
   * @description Cancels a workflow instance, aborts scheduled jobs, and
   * optionally runs saga compensations across the instance and its active
   * descendant tree. Thin dispatcher preserved for the engine's internal cancel
   * call sites; the cancellation logic lives on {@link WorkflowCancellation}.
   * @param instanceId Id of the target instance to cancel (with its active
   * descendants)
   * @param runCompensations true to roll back completed steps via saga compensation
   */
  private static void cancelInstance(Id instanceId, Boolean runCompensations) {
    if (runCompensations) {
      WorkflowCancellation.cancelWithCompensationsInstance(instanceId);
    } else {
      WorkflowCancellation.cancelInstance(instanceId);
    }
  }

  /**
   * @description Request DTO pairing an instance Id with the step name to drive,
   * used to enqueue orchestrator RUN_STEP work in bulk.
   */
  public class OrchestratorRequest {
    public Id instanceId;
    public String stepName;
    /**
     * @description Builds an orchestrator request.
     * @param instanceId Id of the instance to orchestrate
     * @param stepName name of the step to run, or null for the current step
     */
    public OrchestratorRequest(Id instanceId, String stepName) {
      this.instanceId = instanceId;
      this.stepName = stepName;
    }
  }

  /**
   * Evaluates and resumes suspended workflows that have exceeded their sleep time,
   * and terminates active steps that have exceeded their timeout limits.
   */
  public static void processWatchdogHeartbeat() {
    WorkflowHeartbeatService.runWatchdogHeartbeat();
  }
}
