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

  // Base + jitter (seconds) before a concurrency-parked instance re-attempts
  // admission. Precise scheduling drives it promptly when slots free; under a large
  // burst the scheduling degrades to the watchdog batch-resume (the scalable path).
  @TestVisible
  private static Integer concurrencyAdmissionRetrySeconds = 30;
  private static final Integer CONCURRENCY_ADMISSION_RETRY_JITTER_SECONDS = 15;

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

  // Public so the extracted signal-routing and signal-or-start services can
  // apply the same instance-level enqueue dedup as the resident resume path.
  @TestVisible
  public static Set<Id> enqueuedInstanceIds = new Set<Id>();
  // Per-(instance, branch) enqueue dedup so resuming a parallel instance can
  // wake each branch by name without the instance-level dedup blocking siblings.
  @TestVisible
  private static Set<String> enqueuedBranchKeys = new Set<String>();

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
   * Canonical form of a correlation key for in-memory dedup maps/sets.
   * Correlation_Key__c is case-insensitive (and the unique
   * Active_Correlation_Key__c index is too), but Apex Map/Set keys are
   * case-sensitive, so keys are lower-cased to match the database semantics.
   * @param key the raw correlation key
   * @return the lower-cased key, or null when the input is null
   */
  public static String normalizeKey(String key) {
    return key == null ? null : key.toLowerCase();
  }

  /**
   * Removes the given instances (and their parallel branch keys) from the static
   * enqueue guards. Called after a wake-up failure is rolled back so a caller
   * that catches the exception and retries in the same transaction can re-enqueue
   * the resume — otherwise the guard would suppress the retry's wake and leave
   * the workflow unwoken despite the re-inserted signal.
   * @param instanceIds instances whose enqueue guards (and branch keys) are cleared
   */
  public static void clearEnqueueGuards(Set<Id> instanceIds) {
    if (instanceIds == null || instanceIds.isEmpty()) {
      return;
    }
    enqueuedInstanceIds.removeAll(instanceIds);
    if (!enqueuedBranchKeys.isEmpty()) {
      Set<String> toRemove = new Set<String>();
      for (String branchKey : enqueuedBranchKeys) {
        for (Id instanceId : instanceIds) {
          if (branchKey.startsWith(instanceId + '::')) {
            toRemove.add(branchKey);
            break;
          }
        }
      }
      enqueuedBranchKeys.removeAll(toRemove);
    }
  }

  /**
   * Wakes an instance after a routed signal lands. A Suspended instance flips to
   * Running; a Running/Compensating/Cancelling instance is re-driven in place (a
   * compensation step can depend on inbound signals, so it is woken rather than
   * rejected). A Paused instance keeps its status — the held signal is observed
   * when resume re-drives the wait step.
   * @param instance the routed target instance to wake in place
   */
  public static void wakeInstanceForSignal(Workflow_Instance__c instance) {
    // A concurrency-parked row is stored as an ordinary Suspended instance but has
    // not yet won an admission slot. Waking it to Running would leave a Running
    // instance holding no slot (violating the no-running-without-slot invariant) and
    // hide it from the parked count. The signal is already captured (Received) and is
    // observed once admission drives the step, so skip the wake and the enqueue
    // entirely — mirroring the guard in the bulk signal(List<SignalRequest>) path.
    if (
      instance.Status__c == 'Suspended' &&
      instance.Concurrency_Parked__c == true &&
      instance.Concurrency_Slot_Held__c != true
    ) {
      return;
    }
    if (
      instance.Status__c == 'Suspended' ||
      instance.Status__c == 'Running' ||
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling'
    ) {
      if (instance.Status__c == 'Suspended') {
        instance.Status__c = 'Running';
        // Disarm the wait deadline (issue #35): a signal-wake ends the current
        // wait, so any armed Sleep_Until__c (timed-wait timeout, or a plain
        // sleeper's deadline) must be cleared or the watchdog would later
        // re-select this instance and mis-route/double-wake it. The resumed step
        // re-arms its own deadline if it suspends or sleeps again.
        instance.Sleep_Until__c = null;
        Database.update(instance, true, AccessLevel.SYSTEM_MODE);
      }
      enqueueResume(instance.Id);
    }
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

  private static void populateTelemetry(
    Workflow_Step_Execution__c stepExec,
    Boolean isCrash
  ) {
    if (stepExec != null) {
      if (isCrash) {
        stepExec.CPU_Time_Ms__c = null;
        stepExec.SOQL_Query_Count__c = null;
        stepExec.Heap_Size_Bytes__c = null;
      } else {
        stepExec.CPU_Time_Ms__c = Limits.getCpuTime();
        stepExec.SOQL_Query_Count__c = Limits.getQueries();
        stepExec.Heap_Size_Bytes__c = Limits.getHeapSize();
      }
    }
  }

  /**
   * @description Persists a step execution (insert when transient, otherwise
   * update) in system mode after populating its telemetry, for the non-crash
   * case. Public so the extracted breadcrumb persistence can flush a transient
   * step execution before correlating its logs.
   * @param stepExec the step execution to persist
   */
  public static void saveStepExec(Workflow_Step_Execution__c stepExec) {
    saveStepExec(stepExec, false);
  }

  /**
   * @description Persists a step execution recorded by the crash handler, marking
   * its telemetry as a crash outcome. Public entry so the extracted
   * `WorkflowCrashHandler` can flush a crashed step execution without exposing the
   * internal Boolean crash flag.
   * @param stepExec the crashed step execution to persist
   */
  public static void saveStepExecAsCrash(Workflow_Step_Execution__c stepExec) {
    saveStepExec(stepExec, true);
  }

  private static void saveStepExec(
    Workflow_Step_Execution__c stepExec,
    Boolean isCrash
  ) {
    populateTelemetry(stepExec, isCrash);
    if (stepExec.Id == null) {
      Database.insert(stepExec, true, AccessLevel.SYSTEM_MODE);
    } else {
      Database.update(stepExec, true, AccessLevel.SYSTEM_MODE);
    }
  }

  /**
   * Counts terminal (completed) executions of a step name within an instance.
   * Used to derive the per-visit idempotency sequence for StepContext: the
   * current (not-yet-completed) visit is excluded, so this is 0 for the first
   * visit and increments each time the engine loops back to the same step.
   * @param instanceId Id of the instance to count within
   * @param stepName name of the step whose completed executions are counted
   * @param completedStatuses the statuses that count as terminal/completed
   * @return the number of already-completed executions of the step
   */
  private static Integer countCompletedStepExecutions(
    Id instanceId,
    String stepName,
    Set<String> completedStatuses
  ) {
    return [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = :stepName
        AND Status__c IN :completedStatuses
      WITH SYSTEM_MODE
    ];
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
   * @description Shared retry persistence: merges the sanitized policy's
   * maximumAttempts into the step's captured values and re-offloads them.
   * Extracted from the forward and compensation retry paths, which persisted
   * identical captures state before diverging on the retries-exhausted branch.
   * Behavior is byte-identical to the inlined blocks. Public so the extracted
   * outcome retry handler can invoke it, called qualified.
   * @param instance the workflow instance owning the step
   * @param stepExec the step execution whose captured values are updated
   * @param policy the sanitized retry policy whose maximumAttempts is persisted
   */
  public static void persistRetryMaxAttempts(
    Workflow_Instance__c instance,
    Workflow_Step_Execution__c stepExec,
    RetryPolicy policy
  ) {
    Map<String, Object> captures = new Map<String, Object>();
    if (String.isNotBlank(stepExec.Captured_Values__c)) {
      String resolvedCaptures = WorkflowPayloadOffload.resolvePayload(
        stepExec.Captured_Values__c
      );
      if (String.isNotBlank(resolvedCaptures)) {
        try {
          captures = (Map<String, Object>) JSON.deserializeUntyped(
            resolvedCaptures
          );
        } catch (Exception ignored) {
          // Malformed captures; proceed with an empty captures map.
        }
      }
    }
    captures.put('__maxAttempts', policy.maximumAttempts);
    stepExec.Captured_Values__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      JSON.serialize(captures),
      'Captures_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
  }

  /**
   * @description Shared exponential-backoff reschedule: marks the step Retrying,
   * computes the capped backoff delay, suspends the instance and arms the retry
   * job. Extracted from the not-yet-exhausted branch of the forward and
   * compensation retry paths, which scheduled the next attempt identically.
   * Behavior is byte-identical to the inlined else-branches. Public so the
   * extracted outcome retry handler can invoke it, called qualified.
   * @param instance the workflow instance to suspend until the next attempt
   * @param stepExec the step execution being rescheduled
   * @param policy the sanitized retry policy driving the backoff computation
   */
  public static void scheduleExponentialRetry(
    Workflow_Instance__c instance,
    Workflow_Step_Execution__c stepExec,
    RetryPolicy policy
  ) {
    stepExec.Status__c = 'Retrying';
    stepExec.Output__c = null;
    saveStepExec(stepExec);

    // Calculate exponential backoff
    Double backoff = Math.pow(
      (Double) policy.backoffCoefficient,
      (Double) (stepExec.Retry_Count__c - 1)
    );
    Integer delay = (Integer) (policy.initialIntervalSeconds * backoff);
    delay = Math.min(delay, 86400);

    instance.Status__c = 'Suspended';
    instance.Sleep_Until__c = DateTime.now().addSeconds(delay);
    instance.Async_Job_Id__c = WorkflowRetrySleepScheduler.scheduleRetry(
      instance.Id,
      stepExec.Step_Name__c,
      delay
    );
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
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
   * @description Shared enqueue path used by the fail/error-routing branches: in
   * tests, enqueue only when queueables are enabled; otherwise delegate to the
   * standard orchestrator enqueue. Public so the extracted `WorkflowFailureService`
   * can drive the orchestrator through the same test-aware path.
   * @param instanceId Id of the instance whose orchestrator is enqueued
   */
  public static void enqueueOrchestratorForInstance(Id instanceId) {
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instanceId));
      }
    } else {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(instanceId, null);
    }
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
   * @description Wakes a (possibly parallel) instance to resume execution. When
   * Current_Step__c is a parallel branch list, each still-incomplete branch is
   * enqueued by its own step name: runStep returns early for a comma-separated
   * Current_Step__c with a blank stepName, so a single blank enqueue would never
   * resume a branch suspended on a signal. A serial instance is enqueued once
   * with a null stepName. Public so the extracted `WorkflowStepRunner` admission
   * gate can re-drive an instance after clearing concurrency-park markers.
   * @param instanceId Id of the instance to wake and enqueue for resume
   */
  public static void enqueueResume(Id instanceId) {
    List<Workflow_Instance__c> rows = [
      SELECT Id, Current_Step__c, Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    String currentStep = rows.isEmpty() ? null : rows[0].Current_Step__c;
    // A Compensating/Cancelling instance rolls back serially off the LIFO stack,
    // so it needs a single compensation wake, never per-branch fan-out -- even if
    // Current_Step__c still holds a stale comma-separated parallel branch list from
    // the forward phase. Only forward parallel instances fan out per branch.
    Boolean isCompensatingInst =
      !rows.isEmpty() &&
      (rows[0].Status__c == 'Compensating' ||
      rows[0].Status__c == 'Cancelling');

    if (
      !isCompensatingInst &&
      String.isNotBlank(currentStep) &&
      currentStep.contains(',')
    ) {
      // Delegate to the batched bulk path (single-element list) so a parallel
      // instance with many unfinished branches publishes one EventBus call
      // rather than one publish per branch (which could exceed the 150
      // publish/DML-statement limit).
      enqueueResumeBulk(rows);
      return;
    }

    // Serial resume.
    enqueueSerialResume(instanceId);
  }

  /**
   * Serial resume enqueue: dedups per instance, then enqueues the orchestrator
   * directly under test, or via queueable (falling back to the platform-event
   * path when the queueable budget is exhausted or the enqueue throws).
   * @param instanceId the instance to resume
   */
  private static void enqueueSerialResume(Id instanceId) {
    if (enqueuedInstanceIds.contains(instanceId)) {
      return;
    }
    enqueuedInstanceIds.add(instanceId);
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instanceId));
      }
      return;
    }
    try {
      if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
        System.enqueueJob(new WorkflowOrchestrator(instanceId));
      } else {
        WorkflowOrchestratorEnqueue.enqueueOrchestrator(instanceId, null);
      }
    } catch (Exception ignored) {
      // Queueable enqueue failed; fall back to the Platform Event path.
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(instanceId, null);
    }
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
   * Bulk variant of enqueueResume for the bulk signal() path: wakes the
   * incomplete branches of many parallel instances using the already-loaded
   * Current_Step__c values and ONE step-execution query across all of them,
   * instead of two queries per instance.
   * @param parallelInstances the parallel instances whose branches are re-enqueued
   */
  public static void enqueueResumeBulk(
    List<Workflow_Instance__c> parallelInstances
  ) {
    if (parallelInstances == null || parallelInstances.isEmpty()) {
      return;
    }
    Set<String> allBranchNames = new Set<String>();
    Map<Id, List<String>> branchesByInstance = mapBranchesByInstance(
      parallelInstances,
      allBranchNames
    );
    Map<String, String> latestStatusByKey = loadLatestBranchStatuses(
      branchesByInstance.keySet(),
      allBranchNames
    );
    List<Workflow_Event__e> branchEvents = buildBranchRunEvents(
      branchesByInstance,
      latestStatusByKey
    );
    publishBranchEvents(branchEvents);
  }

  /**
   * Maps each parallel instance to its trimmed branch step names and collects
   * every branch name across the batch for a single step-execution lookup.
   * @param parallelInstances the parallel instances whose Current_Step__c
   *        comma lists to split into branch names
   * @param allBranchNames output accumulator populated with every branch name
   *        seen across the batch (mutated in place)
   * @return a map of instance id to its ordered list of branch step names
   */
  private static Map<Id, List<String>> mapBranchesByInstance(
    List<Workflow_Instance__c> parallelInstances,
    Set<String> allBranchNames
  ) {
    Map<Id, List<String>> branchesByInstance = new Map<Id, List<String>>();
    for (Workflow_Instance__c inst : parallelInstances) {
      List<String> branches = new List<String>();
      for (String b : inst.Current_Step__c.split(',')) {
        branches.add(b.trim());
        allBranchNames.add(b.trim());
      }
      branchesByInstance.put(inst.Id, branches);
    }
    return branchesByInstance;
  }

  /**
   * Loads the latest step-execution status per (instance, branch step name)
   * across the whole batch in a single query. Newest-first ordering means the
   * first row seen for a key is the latest, so earlier map entries win.
   * @param instanceIds the parallel instance ids to load branch statuses for
   * @param allBranchNames the branch step names to restrict the query to
   * @return a map of "instanceId::stepName" to the latest execution status
   */
  private static Map<String, String> loadLatestBranchStatuses(
    Set<Id> instanceIds,
    Set<String> allBranchNames
  ) {
    Map<String, String> latestStatusByKey = new Map<String, String>();
    for (Workflow_Step_Execution__c se : [
      SELECT Workflow_Instance__c, Step_Name__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instanceIds
        AND Step_Name__c IN :allBranchNames
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      String key = se.Workflow_Instance__c + '::' + se.Step_Name__c;
      if (!latestStatusByKey.containsKey(key)) {
        latestStatusByKey.put(key, se.Status__c);
      }
    }
    return latestStatusByKey;
  }

  /**
   * Builds the RUN_STEP events for every incomplete, not-yet-enqueued branch,
   * so they can be published in ONE EventBus call (one publish per branch would
   * risk the publish/DML statement limit when many parallel instances wake at
   * once). Skips branches already Completed/OperatorSkipped and branches
   * already enqueued this transaction; under test it directly enqueues the
   * branch job via {@link enqueueTestBranchJob} instead of emitting an event.
   * @param branchesByInstance instance id to its branch step names
   * @param latestStatusByKey "instanceId::stepName" to latest branch status
   * @return the RUN_STEP events to publish (empty under test)
   */
  private static List<Workflow_Event__e> buildBranchRunEvents(
    Map<Id, List<String>> branchesByInstance,
    Map<String, String> latestStatusByKey
  ) {
    List<Workflow_Event__e> branchEvents = new List<Workflow_Event__e>();
    for (Id instId : branchesByInstance.keySet()) {
      for (String b : branchesByInstance.get(instId)) {
        String key = instId + '::' + b;
        String status = latestStatusByKey.get(key);
        if (status == 'Completed' || status == 'OperatorSkipped') {
          continue; // branch already finished
        }
        if (enqueuedBranchKeys.contains(key)) {
          continue;
        }
        enqueuedBranchKeys.add(key);
        if (Test.isRunningTest()) {
          enqueueTestBranchJob(instId, b);
        } else {
          branchEvents.add(
            new Workflow_Event__e(
              Workflow_Instance_Id__c = instId,
              Event_Type__c = 'RUN_STEP',
              Payload__c = b
            )
          );
        }
      }
    }
    return branchEvents;
  }

  /**
   * Publishes the collected branch RUN_STEP events in one EventBus call and
   * bootstraps the watchdog. Throws WorkflowException on any per-event publish
   * failure. No-op when there are no events (e.g. under test).
   * @param branchEvents the RUN_STEP events to publish
   */
  private static void publishBranchEvents(
    List<Workflow_Event__e> branchEvents
  ) {
    if (branchEvents.isEmpty()) {
      return;
    }
    WorkflowWatchdog.bootstrap();
    List<Database.SaveResult> srs = EventBus.publish(branchEvents);
    for (Database.SaveResult sr : srs) {
      if (!sr.isSuccess()) {
        List<String> errMsgs = new List<String>();
        for (Database.Error err : sr.getErrors()) {
          errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
        }
        throw new WorkflowException(
          'Failed to publish resumed branch event: ' +
          String.join(errMsgs, ', ')
        );
      }
    }
  }

  /**
   * @description Direct-enqueues one branch orchestrator job for the test-only
   * branch of `enqueueResumeBulk`. Kept as a helper so the per-branch
   * `System.enqueueJob` is not lexically inside `enqueueResumeBulk`'s nested
   * loop. Production still batches every branch into a single
   * `EventBus.publish`; this helper is only invoked when `Test.isRunningTest()`
   * is true. Honors `disableQueueableInTest` so tests that suppress queueable
   * dispatch remain suppressed.
   * @param instId the parent workflow instance whose branch is being driven
   * @param branchName the branch step name to enqueue
   */
  private static void enqueueTestBranchJob(Id instId, String branchName) {
    if (!disableQueueableInTest) {
      System.enqueueJob(new WorkflowOrchestrator(instId, branchName));
    }
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
   * Cancels a workflow instance (and its active descendants), aborts scheduled jobs,
   * and rolls back completed steps via saga compensation.
   * @param instanceId Id of the target instance to cancel (with its active descendants)
   */
  public static void cancelWithCompensations(Id instanceId) {
    cancelInstance(instanceId, true);
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

  /**
   * @description Parks an instance that could not acquire a concurrency slot. It
   * suspends with a short admission-retry wake time and re-enters admission
   * through the SAME sleep/watchdog resume path used by SLEEP — no busy spin, no
   * dropped Queueable chain. The current Pending step's watchdog deadline is
   * cleared so a parked (not-yet-executed) step is never failed by the timeout
   * sweep; admission re-arms it. Public so the extracted `WorkflowStepRunner`
   * admission gate can park a denied delivery.
   * @param instance the instance that failed to acquire a concurrency slot
   * @param resolvedStep name of the current Pending step being parked
   */
  public static void parkForConcurrency(
    Workflow_Instance__c instance,
    String resolvedStep
  ) {
    // Reset the current step's pre-execution state so a re-park is always clean: an
    // external resume() can have flipped the not-yet-executed step to Running and
    // stamped a deadline before this delivery reached the gate. Put it back to
    // Pending and clear Timeout_At__c (the watchdog/timeout job already skips a
    // Suspended parent, but this keeps the step row consistent and re-armable).
    List<Workflow_Step_Execution__c> pending = [
      SELECT Id, Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Status__c IN ('Pending', 'Running')
        AND Timeout_At__c != NULL
      WITH SYSTEM_MODE
    ];
    if (!pending.isEmpty()) {
      for (Workflow_Step_Execution__c step : pending) {
        step.Status__c = 'Pending';
        step.Timeout_At__c = null;
      }
      Database.update(pending, true, AccessLevel.SYSTEM_MODE);
    }

    Integer retrySeconds =
      concurrencyAdmissionRetrySeconds +
      (Integer) Math.floor(
        Math.random() * CONCURRENCY_ADMISSION_RETRY_JITTER_SECONDS
      );
    instance.Status__c = 'Suspended';
    instance.Concurrency_Parked__c = true;
    instance.Concurrency_Slot_Held__c = false;
    instance.Sleep_Until__c = DateTime.now().addSeconds(retrySeconds);
    instance.Async_Job_Id__c = WorkflowRetrySleepScheduler.scheduleSleepResume(
      instance.Id,
      resolvedStep,
      retrySeconds
    );
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
  }

  // ── Unrouted-signal capture & re-delivery ──────────────────────────────────

  /**
   * Re-parents the captured signal to the resolved instance and wakes it, sharing
   * one savepoint so the redelivery is all-or-none. On a unique-key collision with
   * a routed delivery that already claimed this instance+key, retires this row as a
   * keyless Consumed tombstone rather than delivering a second copy.
   * @param sig the captured Unrouted signal (locked)
   * @param instance the resolved active instance (locked)
   * @return true once the signal has been delivered or tombstoned
   */
  public static Boolean deliverRedeliveredSignal(
    Workflow_Signal__c sig,
    Workflow_Instance__c instance
  ) {
    sig.Workflow_Instance__c = instance.Id;
    sig.Status__c = 'Received';
    if (String.isNotBlank(sig.Idempotency_Key__c)) {
      // Rewrite the correlation-scoped capture key to the instance-scoped routed
      // key so a later routed delivery of the same idempotency key dedups against
      // this row instead of inserting a second Received signal.
      sig.Signal_Key__c = WorkflowSignalDedup.deriveSignalDedupKey(
        instance.Id,
        sig.Idempotency_Key__c
      );
    }
    // The re-parent update and the wake-up share one savepoint so the
    // redelivery is all-or-none. The update flips the row to Received and
    // rewrites Signal_Key__c to the instance-scoped routed hash; if the wake
    // then fails, the row is rolled back to its Unrouted/capture-key state so
    // redelivery can be retried. Otherwise a stranded Received row with the
    // rewritten unique key would cause a later routed duplicate of the same
    // idempotency key to no-op, leaving the workflow unwoken.
    Savepoint sp = Database.setSavepoint();
    try {
      Database.update(sig, true, AccessLevel.SYSTEM_MODE);
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) != 'DUPLICATE_VALUE') {
        throw ex;
      }
      // A routed delivery already claimed this instance+key, so the canonical
      // Received row exists and was (or will be) woken. This captured row is a
      // duplicate: retire it as a keyless Consumed tombstone (releasing the
      // key it could not take) rather than delivering a second copy.
      sig.Workflow_Instance__c = null;
      sig.Signal_Key__c = null;
      sig.Status__c = 'Consumed';
      Database.update(sig, true, AccessLevel.SYSTEM_MODE);
      return true;
    }

    try {
      wakeInstanceForSignal(instance);
    } catch (Exception e) {
      Database.rollback(sp);
      clearEnqueueGuards(new Set<Id>{ instance.Id });
      throw e;
    }

    return true;
  }

  /**
   * @description Re-homes any Unrouted signals matching an instance (by id or
   * correlation key) back onto it as Received, so a step that just suspended
   * awaiting a signal immediately re-observes one that arrived during its run.
   * Public so the extracted suspension handlers can invoke it, called qualified.
   * @param instanceId Id of the instance to redeliver matching signals to
   * @param correlationKey the instance's correlation key to match signals on
   */
  public static void redeliverMatchingSignalsForInstance(
    Id instanceId,
    String correlationKey
  ) {
    if (instanceId == null) {
      return;
    }
    List<Workflow_Instance__c> matchInsts = [
      SELECT Id, Status__c, Concurrency_Parked__c, Concurrency_Slot_Held__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];

    if (matchInsts.isEmpty()) {
      return;
    }

    List<String> matchKeys = new List<String>{ String.valueOf(instanceId) };
    if (String.isNotBlank(correlationKey)) {
      matchKeys.add(correlationKey);
    }

    List<Workflow_Signal__c> allSignals = [
      SELECT
        Id,
        Correlation_Key__c,
        Status__c,
        Idempotency_Key__c,
        Signal_Key__c,
        CreatedDate
      FROM Workflow_Signal__c
      WHERE Status__c = 'Unrouted' AND Correlation_Key__c IN :matchKeys
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT 10000
    ];

    if (!allSignals.isEmpty()) {
      Map<Id, List<Workflow_Signal__c>> instIdToSignals = new Map<Id, List<Workflow_Signal__c>>{
        instanceId => allSignals
      };
      redeliverCapturedSignalsBulk(matchInsts, instIdToSignals);
    }
  }

  /**
   * Re-homes each captured signal onto its matched instance (Received, with a
   * per-instance dedup key when idempotency-keyed) and returns the flat list of
   * signals to update.
   * @param matchInsts the matched instances to redeliver to
   * @param instIdToSignals the captured signals grouped by instance id
   * @return the signals prepared for the redelivery update
   */
  private static List<Workflow_Signal__c> collectSignalsToRedeliver(
    List<Workflow_Instance__c> matchInsts,
    Map<Id, List<Workflow_Signal__c>> instIdToSignals
  ) {
    List<Workflow_Signal__c> signalsToUpdate = new List<Workflow_Signal__c>();
    for (Workflow_Instance__c inst : matchInsts) {
      List<Workflow_Signal__c> sigs = instIdToSignals.get(inst.Id);
      if (sigs == null) {
        continue;
      }
      for (Workflow_Signal__c sig : sigs) {
        sig.Workflow_Instance__c = inst.Id;
        sig.Status__c = 'Received';
        if (String.isNotBlank(sig.Idempotency_Key__c)) {
          sig.Signal_Key__c = WorkflowSignalDedup.deriveSignalDedupKey(
            inst.Id,
            sig.Idempotency_Key__c
          );
        }
        signalsToUpdate.add(sig);
      }
    }
    return signalsToUpdate;
  }

  /**
   * Tests whether a partial-success save result failed with a duplicate-value
   * error.
   * @param sr the save result to inspect
   * @return true when any of the result's errors is DUPLICATE_VALUE
   */
  private static Boolean isDuplicateError(Database.SaveResult sr) {
    for (Database.Error err : sr.getErrors()) {
      if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
        return true;
      }
    }
    return false;
  }

  /**
   * Partitions the redelivery save results: successful signals are appended to
   * successfulSignals, duplicate failures are reset to a Consumed tombstone and
   * returned, and any other failure is rethrown as a DmlException.
   * @param srs the partial-success save results (positionally aligned)
   * @param signalsToUpdate the signals that were updated (positionally aligned)
   * @param successfulSignals out: signals that updated successfully
   * @return the duplicate signals reset to Consumed tombstones
   */
  private static List<Workflow_Signal__c> partitionSaveResults(
    Database.SaveResult[] srs,
    List<Workflow_Signal__c> signalsToUpdate,
    List<Workflow_Signal__c> successfulSignals
  ) {
    List<Workflow_Signal__c> duplicateSignals = new List<Workflow_Signal__c>();
    for (Integer i = 0; i < srs.size(); i++) {
      Database.SaveResult sr = srs[i];
      Workflow_Signal__c sig = signalsToUpdate[i];
      if (sr.isSuccess()) {
        successfulSignals.add(sig);
      } else if (isDuplicateError(sr)) {
        sig.Workflow_Instance__c = null;
        sig.Signal_Key__c = null;
        sig.Status__c = 'Consumed';
        duplicateSignals.add(sig);
      } else {
        throw new DmlException(sr.getErrors()[0].getMessage());
      }
    }
    return duplicateSignals;
  }

  /**
   * Wakes each distinct instance that had a signal successfully redelivered.
   * @param successfulSignals the signals that updated successfully
   * @param instMap the matched instances by id
   */
  private static void wakeSuccessfulInstances(
    List<Workflow_Signal__c> successfulSignals,
    Map<Id, Workflow_Instance__c> instMap
  ) {
    Set<Id> wokenInstanceIds = new Set<Id>();
    for (Workflow_Signal__c sig : successfulSignals) {
      if (wokenInstanceIds.add(sig.Workflow_Instance__c)) {
        Workflow_Instance__c inst = instMap.get(sig.Workflow_Instance__c);
        if (inst != null) {
          wakeInstanceForSignal(inst);
        }
      }
    }
  }

  /**
   * @description Redelivers the captured Unrouted signals grouped per matched
   * instance: updates them to Captured (partitioning true duplicates), then wakes
   * the successfully-captured instances. Public so the extracted watchdog
   * sleep/orphan sweep can invoke it, called qualified.
   * @param matchInsts the suspended instances the signals were matched to
   * @param instIdToSignals the still-Unrouted signals grouped by instance id
   */
  public static void redeliverCapturedSignalsBulk(
    List<Workflow_Instance__c> matchInsts,
    Map<Id, List<Workflow_Signal__c>> instIdToSignals
  ) {
    List<Workflow_Signal__c> signalsToUpdate = collectSignalsToRedeliver(
      matchInsts,
      instIdToSignals
    );
    Map<Id, Workflow_Instance__c> instMap = new Map<Id, Workflow_Instance__c>(
      matchInsts
    );

    if (signalsToUpdate.isEmpty()) {
      return;
    }

    Savepoint sp = Database.setSavepoint();
    try {
      Database.SaveResult[] srs = Database.update(
        signalsToUpdate,
        false,
        AccessLevel.SYSTEM_MODE
      );

      List<Workflow_Signal__c> successfulSignals = new List<Workflow_Signal__c>();
      List<Workflow_Signal__c> duplicateSignals = partitionSaveResults(
        srs,
        signalsToUpdate,
        successfulSignals
      );

      if (!duplicateSignals.isEmpty()) {
        Database.update(duplicateSignals, true, AccessLevel.SYSTEM_MODE);
      }

      wakeSuccessfulInstances(successfulSignals, instMap);
    } catch (Exception e) {
      Database.rollback(sp);
      Set<Id> instIdsToClear = new Set<Id>();
      for (Workflow_Instance__c inst : matchInsts) {
        instIdsToClear.add(inst.Id);
      }
      clearEnqueueGuards(instIdsToClear);
      throw e;
    }
  }

  /**
   * @description Returns a retry policy with only the valid, positive fields of
   * the supplied policy applied over the defaults, so an author-supplied policy
   * can never weaken the engine below its safe retry floor. Public so the
   * extracted outcome retry handler can invoke it, called qualified.
   * @param policy the author-supplied retry policy to sanitize (may be null)
   * @return a sanitized retry policy safe for backoff scheduling
   */
  public static RetryPolicy sanitizePolicy(RetryPolicy policy) {
    RetryPolicy clean = new RetryPolicy();
    if (policy != null) {
      if (policy.maximumAttempts != null && policy.maximumAttempts > 0) {
        clean.maximumAttempts = policy.maximumAttempts;
      }
      if (
        policy.initialIntervalSeconds != null &&
        policy.initialIntervalSeconds > 0
      ) {
        clean.initialIntervalSeconds = policy.initialIntervalSeconds;
      }
      if (
        policy.backoffCoefficient != null &&
        policy.backoffCoefficient >= 1.0
      ) {
        clean.backoffCoefficient = policy.backoffCoefficient;
      }
    }
    return clean;
  }
}
