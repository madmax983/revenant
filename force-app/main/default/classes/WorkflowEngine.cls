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

  @TestVisible
  private static Set<Id> enqueuedInstanceIds = new Set<Id>();
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
   * The set of statuses for which an inbound signal can still wake an instance:
   * a forward signal resumes Suspended/Running, and a compensation step may
   * await a signal while Compensating/Cancelling. Terminal statuses are not
   * signalable.
   * @param status the instance status to test
   * @return true when a signal can still wake an instance in this status
   */
  private static Boolean isWakeableStatus(String status) {
    return status == 'Suspended' ||
      status == 'Running' ||
      status == 'Compensating' ||
      status == 'Cancelling';
  }

  /**
   * Refreshes the cached SObject's status from a freshly-queried copy. The bulk
   * signal() path holds the same instance under several map keys (18-/15-char
   * Id and correlation key), but they all reference one SObject, so a single
   * field assignment updates every view of it.
   * @param instById map of instances keyed by Id (and other aliases)
   * @param refreshed the freshly-queried instance whose status is copied over
   */
  private static void refreshCachedStatus(
    Map<String, Workflow_Instance__c> instById,
    Workflow_Instance__c refreshed
  ) {
    Workflow_Instance__c cached = instById.get(refreshed.Id);
    if (cached != null) {
      cached.Status__c = refreshed.Status__c;
    }
  }

  /**
   * Extracts the normalized set of expected child correlation keys from a
   * resolved pending-step output payload. Returns null when the payload cannot
   * be parsed or does not carry a childCorrelationKeys list, signalling that the
   * parent should be treated as ready (not gated).
   * @param resolvedOutput the resolved step output JSON
   * @return normalized expected child keys, or null when absent/unparseable
   */
  private static Set<String> extractExpectedChildKeys(String resolvedOutput) {
    try {
      Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(
        resolvedOutput
      );
      if (!data.containsKey('childCorrelationKeys')) {
        return null;
      }
      List<Object> keysObj = (List<Object>) data.get('childCorrelationKeys');
      if (keysObj == null) {
        return null;
      }
      Set<String> expectedKeys = new Set<String>();
      for (Object o : keysObj) {
        if (o != null) {
          expectedKeys.add(normalizeKey(String.valueOf(o)));
        }
      }
      return expectedKeys;
    } catch (Exception ignored) {
      // If JSON parse fails or does not contain childCorrelationKeys, treat as ready
      return null;
    }
  }

  /**
   * Collects the normalized correlation keys of children that have reached a
   * non-active (finished) status and are among the expected keys.
   * @param children the child instances of a gated parent (may be null)
   * @param expectedKeys the expected child correlation keys to match against
   * @return the subset of expected keys whose child has finished
   */
  private static Set<String> collectFinishedChildKeys(
    List<Workflow_Instance__c> children,
    Set<String> expectedKeys
  ) {
    Set<String> finishedKeys = new Set<String>();
    if (children == null) {
      return finishedKeys;
    }
    for (Workflow_Instance__c child : children) {
      if (String.isNotBlank(child.Correlation_Key__c)) {
        String normChildKey = normalizeKey(child.Correlation_Key__c);
        if (
          expectedKeys.contains(normChildKey) &&
          child.Status__c != null &&
          !ACTIVE_STATUSES.contains(child.Status__c)
        ) {
          finishedKeys.add(normChildKey);
        }
      }
    }
    return finishedKeys;
  }

  /**
   * Determines whether every signal awaiting a non-ready parent is a
   * child-completion/failure signal, meaning the parent is genuinely gated on
   * outstanding children rather than an unrelated inbound signal.
   * @param sigNames the signal names pending for the parent (may be null)
   * @return true when all pending signals are child completion/failure signals
   */
  private static Boolean isAllChildSignals(Set<String> sigNames) {
    if (sigNames == null) {
      return true;
    }
    for (String name : sigNames) {
      if (String.isNotBlank(name)) {
        String lower = name.toLowerCase();
        if (
          !lower.startsWith('childcompleted:') &&
          !lower.startsWith('childfailed:')
        ) {
          return false;
        }
      }
    }
    return true;
  }

  /**
   * Holder for the queried/resolved data needed to evaluate whether suspended
   * parents are gated on outstanding children: the pending step execution per
   * parent, the resolved pending-step output per parent, and the child
   * instances grouped by parent.
   */
  private class GatedParentScan {
    Map<Id, Workflow_Step_Execution__c> pendingStepExecs = new Map<Id, Workflow_Step_Execution__c>();
    Map<Id, String> resolvedOutputsByParentId = new Map<Id, String>();
    Map<Id, List<Workflow_Instance__c>> childrenByParentId = new Map<Id, List<Workflow_Instance__c>>();
  }

  /**
   * Collects the ids of the suspended instances that must be checked for child
   * gating.
   * @param instances the candidate parent instances
   * @return the ids of instances currently in the Suspended status
   */
  private static Set<Id> collectSuspendedParentIds(
    List<Workflow_Instance__c> instances
  ) {
    Set<Id> parentIdsToCheck = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      if (inst != null && inst.Status__c == 'Suspended') {
        parentIdsToCheck.add(inst.Id);
      }
    }
    return parentIdsToCheck;
  }

  /**
   * Queries and resolves the data needed to evaluate child gating for the given
   * suspended parents: their pending step executions (with resolved outputs) and
   * their child instances grouped by parent.
   * @param parentIdsToCheck the suspended parent ids to scan
   * @return the populated scan holder
   */
  private static GatedParentScan queryGatedParentScan(
    Set<Id> parentIdsToCheck
  ) {
    GatedParentScan scan = new GatedParentScan();
    for (Workflow_Step_Execution__c se : [
      SELECT Id, Workflow_Instance__c, Step_Name__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :parentIdsToCheck AND Status__c = 'Pending'
      WITH SYSTEM_MODE
    ]) {
      scan.pendingStepExecs.put(se.Workflow_Instance__c, se);
    }

    if (!scan.pendingStepExecs.isEmpty()) {
      List<Id> parentIds = new List<Id>();
      List<String> rawOutputs = new List<String>();
      for (Workflow_Step_Execution__c se : scan.pendingStepExecs.values()) {
        parentIds.add(se.Workflow_Instance__c);
        rawOutputs.add(se.Output__c);
      }
      List<String> resolved = WorkflowPayloadOffload.resolvePayloads(
        rawOutputs
      );
      for (Integer i = 0; i < parentIds.size(); i++) {
        scan.resolvedOutputsByParentId.put(parentIds[i], resolved[i]);
      }
    }

    for (Workflow_Instance__c child : [
      SELECT Id, Parent_Instance__c, Correlation_Key__c, Status__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c IN :parentIdsToCheck
      WITH SYSTEM_MODE
    ]) {
      if (!scan.childrenByParentId.containsKey(child.Parent_Instance__c)) {
        scan.childrenByParentId.put(
          child.Parent_Instance__c,
          new List<Workflow_Instance__c>()
        );
      }
      scan.childrenByParentId.get(child.Parent_Instance__c).add(child);
    }

    return scan;
  }

  /**
   * Determines which suspended parents still have outstanding (non-finished)
   * expected children, i.e. are not yet ready to wake.
   * @param parentIdsToCheck the suspended parent ids to evaluate
   * @param scan the queried/resolved gating data
   * @return the ids of parents still gated on outstanding children
   */
  private static Set<Id> collectNonReadyParents(
    Set<Id> parentIdsToCheck,
    GatedParentScan scan
  ) {
    Set<Id> nonReadyParents = new Set<Id>();
    for (Id parentId : parentIdsToCheck) {
      Workflow_Step_Execution__c se = scan.pendingStepExecs.get(parentId);
      if (se == null) {
        continue;
      }
      String resolvedOutput = scan.resolvedOutputsByParentId.get(parentId);
      if (String.isBlank(resolvedOutput)) {
        continue;
      }
      Set<String> expectedKeys = extractExpectedChildKeys(resolvedOutput);
      if (expectedKeys == null) {
        continue;
      }
      Set<String> finishedKeys = collectFinishedChildKeys(
        scan.childrenByParentId.get(parentId),
        expectedKeys
      );
      if (!finishedKeys.containsAll(expectedKeys)) {
        nonReadyParents.add(parentId);
      }
    }
    return nonReadyParents;
  }

  private static Set<Id> getGatedNonReadyParents(
    List<Workflow_Instance__c> instances,
    Map<Id, Set<String>> signalsByInstanceId
  ) {
    Set<Id> gatedNonReadyParents = new Set<Id>();
    if (instances == null || instances.isEmpty()) {
      return gatedNonReadyParents;
    }

    Set<Id> parentIdsToCheck = collectSuspendedParentIds(instances);
    if (parentIdsToCheck.isEmpty()) {
      return gatedNonReadyParents;
    }

    GatedParentScan scan = queryGatedParentScan(parentIdsToCheck);
    Set<Id> nonReadyParents = collectNonReadyParents(parentIdsToCheck, scan);

    for (Id parentId : nonReadyParents) {
      if (isAllChildSignals(signalsByInstanceId.get(parentId))) {
        gatedNonReadyParents.add(parentId);
      }
    }

    return gatedNonReadyParents;
  }

  /**
   * Removes the given instances (and their parallel branch keys) from the static
   * enqueue guards. Called after a wake-up failure is rolled back so a caller
   * that catches the exception and retries in the same transaction can re-enqueue
   * the resume — otherwise the guard would suppress the retry's wake and leave
   * the workflow unwoken despite the re-inserted signal.
   * @param instanceIds instances whose enqueue guards (and branch keys) are cleared
   */
  private static void clearEnqueueGuards(Set<Id> instanceIds) {
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
   * Derives a per-instance-scoped dedup key for a routed signal with a
   * caller-supplied idempotency key. Hashing scopes uniqueness to the
   * instance so the same logical key on different instances never collides
   * on the global Workflow_Signal__c.Signal_Key__c unique index. The 'I:'
   * namespace prefix keeps routed (instance-scoped) keys distinct from the
   * 'C:' correlation-scoped keys used for pre-arrival/unrouted captures.
   * @param instanceId Id of the target instance the key is scoped to
   * @param idempotencyKey caller-supplied idempotency key
   * @return a hex SHA-256 dedup key for the routed signal
   */
  private static String deriveSignalDedupKey(
    Id instanceId,
    String idempotencyKey
  ) {
    return hashDedupBasis('I:' + instanceId + '::' + idempotencyKey);
  }

  /**
   * Derives a correlation-key-scoped dedup key for a pre-arrival (unrouted)
   * signal whose target instance does not exist yet. Scoping by correlation
   * key collapses duplicate keyed captures of the same logical event into one
   * Unrouted row while keeping distinct correlation keys (different targets)
   * separate. The 'C:' prefix avoids collision with routed 'I:' keys.
   *
   * The correlation key is lower-cased before hashing because Salesforce SOQL
   * matches Correlation_Key__c case-insensitively, so 'Order-1' and 'order-1'
   * resolve to the same instance and must therefore dedup to the same key.
   *
   * Components are length-prefixed before hashing so the variable-length
   * correlation and idempotency keys can never form an ambiguous basis: without
   * it, correlation 'a::b' + key 'c' and correlation 'a' + key 'b::c' would hash
   * identically and silently swallow the second capture as a duplicate.
   * @param correlationKey correlation key of the not-yet-existing target instance
   * @param idempotencyKey caller-supplied idempotency key
   * @return a hex SHA-256 dedup key for the unrouted capture
   */
  private static String deriveUnroutedDedupKey(
    String correlationKey,
    String idempotencyKey
  ) {
    String normalizedKey = correlationKey == null
      ? ''
      : correlationKey.toLowerCase();
    String key = idempotencyKey == null ? '' : idempotencyKey;
    return hashDedupBasis(
      'C:' +
        normalizedKey.length() +
        ':' +
        normalizedKey +
        ':' +
        key.length() +
        ':' +
        key
    );
  }

  private static String hashDedupBasis(String basis) {
    Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(basis));
    return EncodingUtil.convertToHex(digest);
  }

  /**
   * Claims a keyed Cancel/CancelWorkflow delivery by persisting a dedup
   * tombstone (Status='Consumed', so it is never surfaced as a pending signal)
   * keyed by the per-instance hash. Returns true for the first delivery (caller
   * should proceed to cancel()); false if a duplicate with the same key was
   * already delivered (idempotent no-op). Mirrors the forward-signal dedup so
   * an at-least-once redelivered cancel runs cancellation at most once.
   * @param instanceId Id of the instance being cancelled
   * @param signalName name of the cancel signal
   * @param idempotencyKey caller-supplied idempotency key for the delivery
   * @return true for the first delivery; false when a duplicate was already claimed
   */
  private static Boolean claimKeyedCancel(
    Id instanceId,
    String signalName,
    String idempotencyKey
  ) {
    Workflow_Signal__c marker = new Workflow_Signal__c(
      Workflow_Instance__c = instanceId,
      Signal_Name__c = signalName,
      Status__c = 'Consumed',
      Signal_Key__c = deriveSignalDedupKey(instanceId, idempotencyKey)
    );
    try {
      Database.insert(marker, true, AccessLevel.SYSTEM_MODE);
      return true;
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        return false;
      }
      throw ex;
    }
  }

  /**
   * Parses the optional {"runCompensations": <bool>} flag from a cancel signal
   * payload, defaulting to true when absent or unparseable.
   * @param payload the raw cancel signal payload JSON
   * @return the runCompensations flag, or true when absent/unparseable
   */
  private static Boolean parseRunCompensations(String payload) {
    if (String.isBlank(payload)) {
      return true;
    }
    try {
      Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(
        payload
      );
      if (params.containsKey('runCompensations')) {
        return (Boolean) params.get('runCompensations');
      }
    } catch (Exception ignored) {
      // Malformed cancel payload; fall through to the default runCompensations.
    }
    return true;
  }

  /**
   * Wakes an instance after a routed signal lands. A Suspended instance flips to
   * Running; a Running/Compensating/Cancelling instance is re-driven in place (a
   * compensation step can depend on inbound signals, so it is woken rather than
   * rejected). A Paused instance keeps its status — the held signal is observed
   * when resume re-drives the wait step.
   * @param instance the routed target instance to wake in place
   */
  private static void wakeInstanceForSignal(Workflow_Instance__c instance) {
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
    List<StartResult> results = signalOrStart(
      new List<SignalOrStartRequest>{ req }
    );
    return results[0];
  }

  // Mutable accumulator threaded through the signalOrStart phase helpers so each
  // helper stays within the parameter and complexity budgets.
  private class SignalOrStartRun {
    List<SignalOrStartRequest> requests;
    System.Savepoint sp;
    List<StartResult> startResults;
    Map<Id, Workflow_Instance__c> existingInstances = new Map<Id, Workflow_Instance__c>();
    Set<Id> cancelledInstanceIds = new Set<Id>();
    Set<Id> activeInstIdsToWake = new Set<Id>();
    List<Workflow_Signal__c> signalsToInsert = new List<Workflow_Signal__c>();
    List<Id> signalsInstIds = new List<Id>();
    Set<Id> instancesWithFreshSignal = new Set<Id>();
    Set<Id> gatedNonReadyParents = new Set<Id>();
    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    List<Workflow_Instance__c> instancesToWake = new List<Workflow_Instance__c>();
  }

  // Keyed cancel claims and the instances whose cancellation was attempted.
  private class CancelClaimBatch {
    List<Workflow_Signal__c> claims = new List<Workflow_Signal__c>();
    List<Id> instIds = new List<Id>();
    List<Boolean> runComp = new List<Boolean>();
    Set<Id> attemptedIds = new Set<Id>();
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
    if (requests == null || requests.isEmpty()) {
      return new List<StartResult>();
    }

    System.Savepoint sp = Database.setSavepoint();
    SignalOrStartRun run = new SignalOrStartRun();
    run.requests = requests;
    run.sp = sp;

    try {
      // 1. Gather all start requests and call startOrGet bulk
      run.startResults = startOrGet(buildSignalOrStartRequests(requests));

      // 2. Query details of existing instances to determine active vs terminal
      run.existingInstances = querySignalOrStartExisting(run);

      // 3. Prepare keyed cancel claims and run cancellations
      processSignalOrStartCancels(run);

      // 4. Prepare ordinary signal records to insert and identify active instances to wake
      prepareSignalOrStartRecords(run);

      // 5. Insert signals
      insertSignalOrStartSignals(run);

      // 6. Wake active instances that received a fresh signal
      wakeSignalOrStartInstances(run);

      return run.startResults;
    } catch (Exception e) {
      Database.rollback(sp);
      clearEnqueueGuards(run.activeInstIdsToWake);
      throw e;
    }
  }

  // True when a signal name is a cancellation (Cancel / CancelWorkflow).
  private static Boolean isCancelSignalName(String signalName) {
    return String.isNotBlank(signalName) &&
      (signalName.equalsIgnoreCase('Cancel') ||
      signalName.equalsIgnoreCase('CancelWorkflow'));
  }

  // True when an existing (non-new) instance is terminal or continued-as-new.
  private static Boolean isSignalTargetTerminal(
    Workflow_Instance__c existingInst,
    Boolean isNew
  ) {
    if (isNew || existingInst == null) {
      return false;
    }
    return WorkflowStatusRead.TERMINAL_GETSTATUS_STATUSES.contains(
        existingInst.Status__c
      ) || existingInst.Status__c == 'ContinuedAsNew';
  }

  // True when a signal to an existing instance must be swallowed: the instance
  // is terminal/continued-as-new or in a stalled CompensationFailed rollback.
  private static Boolean isSignalTargetTerminalOrStalled(
    Workflow_Instance__c existingInst,
    Boolean isNew
  ) {
    if (isNew || existingInst == null) {
      return false;
    }
    return isSignalTargetTerminal(existingInst, isNew) ||
      existingInst.Status__c == 'CompensationFailed';
  }

  // True when an instance's status is signal-wakeable.
  private static Boolean isWakeableSignalStatus(String status) {
    return status == 'Suspended' ||
      status == 'Running' ||
      status == 'Compensating' ||
      status == 'Cancelling';
  }

  // True when an instance is concurrency-parked without holding a slot.
  private static Boolean isConcurrencyParkedUnadmitted(
    Workflow_Instance__c inst
  ) {
    return inst.Concurrency_Parked__c == true &&
      inst.Concurrency_Slot_Held__c != true;
  }

  // §1: map each signal-or-start request to its embedded StartRequest (null
  // preserved for a null request), rejecting a null embedded start.
  private static List<StartRequest> buildSignalOrStartRequests(
    List<SignalOrStartRequest> requests
  ) {
    List<StartRequest> startReqs = new List<StartRequest>();
    for (SignalOrStartRequest req : requests) {
      if (req == null) {
        startReqs.add(null);
        continue;
      }
      if (req.start == null) {
        throw new WorkflowException(
          'StartRequest cannot be null in SignalOrStartRequest'
        );
      }
      startReqs.add(req.start);
    }
    return startReqs;
  }

  // §2: FOR UPDATE-lock the existing (deduped, non-new) instances so their live
  // status can be inspected for cancel/wake decisions.
  private static Map<Id, Workflow_Instance__c> querySignalOrStartExisting(
    SignalOrStartRun run
  ) {
    List<SignalOrStartRequest> requests = run.requests;
    List<StartResult> startResults = run.startResults;
    Set<Id> existingIds = new Set<Id>();
    for (Integer i = 0; i < requests.size(); i++) {
      SignalOrStartRequest req = requests[i];
      if (req == null) {
        continue;
      }
      StartResult res = startResults[i];
      if (res != null && !res.isNew) {
        existingIds.add(res.instanceId);
      }
    }

    Map<Id, Workflow_Instance__c> existingInstances = new Map<Id, Workflow_Instance__c>();
    if (!existingIds.isEmpty()) {
      existingInstances = new Map<Id, Workflow_Instance__c>(
        [
          SELECT
            Id,
            Status__c,
            Current_Step__c,
            Concurrency_Parked__c,
            Concurrency_Slot_Held__c,
            Sleep_Until__c
          FROM Workflow_Instance__c
          WHERE Id IN :existingIds
          WITH SYSTEM_MODE
          FOR UPDATE
        ]
      );
    }
    return existingInstances;
  }

  // §3: build keyed cancel claims, run cancellations, and refresh post-cancel
  // statuses so cancelled instances are excluded from the forward signal pass.
  private static void processSignalOrStartCancels(SignalOrStartRun run) {
    CancelClaimBatch batch = buildSignalOrStartCancelClaims(run);
    insertSignalOrStartCancelClaims(run, batch);
    refreshCancelledInstances(run, batch);
  }

  // Build keyed cancel claims (deduped in-batch) and immediately run unkeyed
  // cancels; skips non-cancel and already-terminal targets.
  private static CancelClaimBatch buildSignalOrStartCancelClaims(
    SignalOrStartRun run
  ) {
    CancelClaimBatch batch = new CancelClaimBatch();
    Set<String> seenCancelKeys = new Set<String>();
    List<SignalOrStartRequest> requests = run.requests;
    List<StartResult> startResults = run.startResults;

    for (Integer i = 0; i < requests.size(); i++) {
      SignalOrStartRequest req = requests[i];
      StartResult res = startResults[i];
      if (res == null) {
        continue;
      }

      Id instanceId = res.instanceId;
      Boolean isNew = res.isNew;

      if (!isCancelSignalName(req.signalName)) {
        continue;
      }
      if (
        isSignalTargetTerminal(run.existingInstances.get(instanceId), isNew)
      ) {
        continue; // Terminal or continued-as-new instance: cancel is an idempotent no-op
      }

      Boolean runCompensations = parseRunCompensations(req.payload);

      if (String.isNotBlank(req.idempotencyKey)) {
        String claimKey = deriveSignalDedupKey(instanceId, req.idempotencyKey);
        if (seenCancelKeys.contains(claimKey)) {
          continue; // in-batch duplicate keyed cancel
        }
        seenCancelKeys.add(claimKey);
        batch.claims.add(
          new Workflow_Signal__c(
            Workflow_Instance__c = instanceId,
            Signal_Name__c = req.signalName,
            Status__c = 'Consumed',
            Signal_Key__c = claimKey
          )
        );
        batch.instIds.add(instanceId);
        batch.runComp.add(runCompensations);
      } else {
        // Unkeyed cancel: execute immediately
        cancelInstance(instanceId, runCompensations);
        batch.attemptedIds.add(instanceId);
      }
    }
    return batch;
  }

  // Insert the keyed cancel claims (allOrNone=false); each winner runs its
  // cancel, a genuine (non-duplicate) claim failure rolls back and throws.
  private static void insertSignalOrStartCancelClaims(
    SignalOrStartRun run,
    CancelClaimBatch batch
  ) {
    if (batch.claims.isEmpty()) {
      return;
    }
    Database.SaveResult[] claimResults = Database.insert(
      batch.claims,
      false,
      AccessLevel.SYSTEM_MODE
    );
    String claimError = null;
    for (Integer i = 0; i < claimResults.size(); i++) {
      Database.SaveResult sr = claimResults[i];
      if (sr.isSuccess()) {
        cancelInstance(batch.instIds[i], batch.runComp[i]);
        batch.attemptedIds.add(batch.instIds[i]);
      } else if (
        !WorkflowStartService.isDuplicateSaveError(sr) && claimError == null
      ) {
        claimError = sr.getErrors()[0].getMessage();
      }
    }
    if (claimError != null) {
      Database.rollback(run.sp);
      throw new WorkflowException('Failed to claim cancel: ' + claimError);
    }
  }

  // Refresh post-cancel statuses in one query; non-wakeable results are recorded
  // so the forward signal pass skips them.
  private static void refreshCancelledInstances(
    SignalOrStartRun run,
    CancelClaimBatch batch
  ) {
    if (batch.attemptedIds.isEmpty()) {
      return;
    }
    Set<Id> attemptedCancelIds = batch.attemptedIds;
    for (Workflow_Instance__c refreshed : [
      SELECT Id, Status__c
      FROM Workflow_Instance__c
      WHERE Id IN :attemptedCancelIds
      WITH SYSTEM_MODE
    ]) {
      Workflow_Instance__c cached = run.existingInstances.get(refreshed.Id);
      if (cached != null) {
        cached.Status__c = refreshed.Status__c;
      }
      if (!isWakeableStatus(refreshed.Status__c)) {
        run.cancelledInstanceIds.add(refreshed.Id);
      }
    }
  }

  // §4: build the ordinary signal records to insert (in-batch keyed dedup) and
  // collect the active existing instances that may need waking.
  private static void prepareSignalOrStartRecords(SignalOrStartRun run) {
    Set<String> seenCompositeKeys = new Set<String>();
    for (Integer i = 0; i < run.requests.size(); i++) {
      prepareSignalOrStartRecord(run, i, seenCompositeKeys);
    }
  }

  // Build/track the signal record for one request, skipping cancels, already
  // cancelled/terminal/stalled targets, and in-batch keyed duplicates.
  private static void prepareSignalOrStartRecord(
    SignalOrStartRun run,
    Integer i,
    Set<String> seenCompositeKeys
  ) {
    StartResult res = run.startResults[i];
    if (res == null) {
      return;
    }
    SignalOrStartRequest req = run.requests[i];
    Id instanceId = res.instanceId;
    Boolean isNew = res.isNew;

    // Skip cancellation signals (already handled above) or instances that were cancelled in this batch
    if (
      isCancelSignalName(req.signalName) ||
      run.cancelledInstanceIds.contains(instanceId)
    ) {
      return;
    }

    Workflow_Instance__c existingInst = isNew
      ? null
      : run.existingInstances.get(instanceId);
    if (isSignalTargetTerminalOrStalled(existingInst, isNew)) {
      // Discard/swallow signal for terminal, stalled rollback, or continued-as-new instances (idempotent no-op)
      return;
    }

    Workflow_Signal__c sig = buildSignalOrStartSignalRecord(
      req,
      instanceId,
      seenCompositeKeys
    );
    if (sig == null) {
      // In-batch duplicate: skip insertion of this signal
      return;
    }

    run.signalsToInsert.add(sig);
    run.signalsInstIds.add(instanceId);

    // If it's an existing active instance, we may need to wake it. Brand-new
    // instances are already enqueued to run by startOrGet, so we don't wake them.
    if (shouldTrackSignalWake(existingInst, isNew)) {
      run.activeInstIdsToWake.add(instanceId);
    }
  }

  // True when an existing, non-new instance is signal-wakeable and so should be
  // tracked for a possible wake after its fresh signal lands.
  private static Boolean shouldTrackSignalWake(
    Workflow_Instance__c existingInst,
    Boolean isNew
  ) {
    return !isNew &&
      existingInst != null &&
      isWakeableSignalStatus(existingInst.Status__c);
  }

  // Build a Received signal record; keyed signals dedup in-batch (null return
  // means an in-batch duplicate that must be skipped).
  private static Workflow_Signal__c buildSignalOrStartSignalRecord(
    SignalOrStartRequest req,
    Id instanceId,
    Set<String> seenCompositeKeys
  ) {
    Workflow_Signal__c sig = new Workflow_Signal__c(
      Workflow_Instance__c = instanceId,
      Signal_Name__c = req.signalName,
      Payload__c = req.payload,
      Status__c = 'Received'
    );

    if (String.isNotBlank(req.idempotencyKey)) {
      String compositeKey = deriveSignalDedupKey(
        instanceId,
        req.idempotencyKey
      );
      if (seenCompositeKeys.contains(compositeKey)) {
        return null;
      }
      seenCompositeKeys.add(compositeKey);
      sig.Signal_Key__c = compositeKey;
    }
    return sig;
  }

  // §5: insert the signal records (allOrNone=false); a genuine (non-duplicate)
  // failure rolls back and throws, otherwise fresh-signal instances are tracked.
  private static void insertSignalOrStartSignals(SignalOrStartRun run) {
    if (run.signalsToInsert.isEmpty()) {
      return;
    }
    // Insert signals using allOrNone=false so concurrent duplicates are swallowed as no-ops,
    // but genuine errors are rolled back and thrown.
    Database.SaveResult[] srs = Database.insert(
      run.signalsToInsert,
      false,
      AccessLevel.SYSTEM_MODE
    );

    String genuineError = null;
    for (Integer i = 0; i < srs.size(); i++) {
      Database.SaveResult sr = srs[i];
      if (sr.isSuccess()) {
        run.instancesWithFreshSignal.add(run.signalsInstIds[i]);
      } else if (
        !WorkflowStartService.isDuplicateSaveError(sr) && genuineError == null
      ) {
        genuineError = sr.getErrors()[0].getMessage();
      }
    }

    if (genuineError != null) {
      Database.rollback(run.sp);
      throw new WorkflowException('Failed to insert signal: ' + genuineError);
    }
  }

  // §6: compute the join-readiness gate, flip eligible suspended instances to
  // Running, and enqueue the woken instances.
  private static void wakeSignalOrStartInstances(SignalOrStartRun run) {
    Map<Id, Set<String>> signalsByInstanceId = buildSignalsByInstanceId(run);

    List<Workflow_Instance__c> activeInstancesList = new List<Workflow_Instance__c>();
    for (Id instId : run.activeInstIdsToWake) {
      Workflow_Instance__c inst = run.existingInstances.get(instId);
      if (inst != null) {
        activeInstancesList.add(inst);
      }
    }
    run.gatedNonReadyParents = getGatedNonReadyParents(
      activeInstancesList,
      signalsByInstanceId
    );

    collectSignalOrStartWakes(run);
    enqueueSignalOrStartWakes(run);
  }

  // Map each request's instance to the set of signal names it received.
  private static Map<Id, Set<String>> buildSignalsByInstanceId(
    SignalOrStartRun run
  ) {
    Map<Id, Set<String>> signalsByInstanceId = new Map<Id, Set<String>>();
    List<SignalOrStartRequest> requests = run.requests;
    List<StartResult> startResults = run.startResults;
    for (Integer i = 0; i < requests.size(); i++) {
      SignalOrStartRequest req = requests[i];
      StartResult res = startResults[i];
      if (res == null) {
        continue;
      }
      Id instanceId = res.instanceId;
      if (!signalsByInstanceId.containsKey(instanceId)) {
        signalsByInstanceId.put(instanceId, new Set<String>());
      }
      if (String.isNotBlank(req.signalName)) {
        signalsByInstanceId.get(instanceId).add(req.signalName);
      }
    }
    return signalsByInstanceId;
  }

  // Determine which woken instances flip to Running (persisting that update) and
  // which are eligible to enqueue, honoring the join-readiness gate.
  private static void collectSignalOrStartWakes(SignalOrStartRun run) {
    for (Id instId : run.activeInstIdsToWake) {
      collectSignalOrStartWakeForInstance(run, instId);
    }
    if (!run.instancesToUpdate.isEmpty()) {
      Database.update(run.instancesToUpdate, true, AccessLevel.SYSTEM_MODE);
    }
  }

  // Wake decision for a single active instance: only a fresh signal wakes it; a
  // suspended, admitted, non-gated instance flips to Running.
  private static void collectSignalOrStartWakeForInstance(
    SignalOrStartRun run,
    Id instId
  ) {
    // Only wake if a fresh signal actually landed (i.e. not a duplicate signal)
    if (!run.instancesWithFreshSignal.contains(instId)) {
      return;
    }
    Workflow_Instance__c inst = run.existingInstances.get(instId);
    if (inst == null) {
      return;
    }

    // If the instance is suspended, change status to Running and clear Sleep_Until__c
    if (inst.Status__c == 'Suspended') {
      // Skip if concurrency-parked and doesn't hold slot
      if (isConcurrencyParkedUnadmitted(inst)) {
        return;
      }
      if (run.gatedNonReadyParents.contains(instId)) {
        return;
      }
      inst.Status__c = 'Running';
      inst.Sleep_Until__c = null;
      run.instancesToUpdate.add(inst);
    }
    if (!run.gatedNonReadyParents.contains(instId)) {
      run.instancesToWake.add(inst);
    }
  }

  // Enqueue the woken instances exactly once (parallel instances via bulk resume).
  private static void enqueueSignalOrStartWakes(SignalOrStartRun run) {
    List<Id> instanceIdsToEnqueue = new List<Id>();
    List<Workflow_Instance__c> parallelInstances = new List<Workflow_Instance__c>();

    for (Workflow_Instance__c inst : run.instancesToWake) {
      Boolean isCompensatingInst =
        inst.Status__c == 'Compensating' ||
        inst.Status__c == 'Cancelling';

      if (
        !isCompensatingInst &&
        String.isNotBlank(inst.Current_Step__c) &&
        inst.Current_Step__c.contains(',')
      ) {
        parallelInstances.add(inst);
      } else if (!enqueuedInstanceIds.contains(inst.Id)) {
        enqueuedInstanceIds.add(inst.Id);
        instanceIdsToEnqueue.add(inst.Id);
      }
    }

    if (!instanceIdsToEnqueue.isEmpty()) {
      WorkflowOrchestratorEnqueue.enqueueOrchestrators(instanceIdsToEnqueue);
    }
    if (!parallelInstances.isEmpty()) {
      enqueueResumeBulk(parallelInstances);
    }
  }

  /**
   * Executes the active step for a workflow instance. Designed to run in a Queueable context.
   * @param instanceId Id of the instance whose active step is executed
   */
  public static void runStep(Id instanceId) {
    runStep(instanceId, null);
  }

  private class RunStepContext {
    Id instanceId;
    String stepName;
    Workflow_Instance__c instance;
    Workflow_Step_Execution__c stepExec;
    Integer stepVisit = 0;
    String activeStepName;
  }

  /**
   * @description Executes a single step of a workflow instance and durably
   * persists its outcome: hydrates the step's `StepContext`, runs the step (or a
   * routed timeout fallback), then hands the `StepResult` to handleStepResult to
   * advance, suspend, retry, split, complete, fail or compensate the instance.
   * The engine's core step-execution entry point, run inside a Queueable.
   * @param instanceId Id of the instance to advance
   * @param stepName name of the step to run, or null to run the instance's
   * current step
   */
  public static void runStep(Id instanceId, String stepName) {
    RunStepContext ctx = new RunStepContext();
    ctx.instanceId = instanceId;
    ctx.stepName = stepName;
    ctx.instance = loadInstanceForRun(instanceId);
    if (isFinishedStatus(ctx.instance.Status__c)) {
      return; // Already finished
    }
    if (routeIfCompensating(ctx.instance)) {
      return;
    }
    if (parkIfPaused(ctx.instance)) {
      return;
    }
    if (admitOrParkForConcurrency(ctx.instance)) {
      return;
    }
    initializeStepInMemory(ctx.instance);
    if (isStaleParallelOrchestratorRun(ctx.instance, stepName)) {
      return;
    }
    ctx.activeStepName = String.isNotBlank(stepName)
      ? stepName
      : ctx.instance.Current_Step__c;
    if (acquireStepExecutionLog(ctx)) {
      return;
    }
    validateExplicitStepName(ctx.instance, stepName);
    String prevOutput = resolvePreviousStepOutput(
      ctx.instance,
      ctx.activeStepName,
      stepName
    );
    invokeStepAndHandleOutcome(ctx, prevOutput);
  }

  // §1. Fetch instance state (NO FOR UPDATE lock to allow parallel execution and
  // direct callouts).
  private static Workflow_Instance__c loadInstanceForRun(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Status__c,
        Current_Step__c,
        Input__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Parent_Instance__c,
        Compensation_Stack__c,
        Definition_Version__c,
        Error_Message__c,
        Previous_Run_At__c,
        Concurrency_Slot_Held__c,
        Concurrency_Parked__c,
        CreatedDate,
        Failure_Category__c,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instanceId);
    }
    return instances[0];
  }

  // A forward-terminal status: nothing left to drive.
  private static Boolean isFinishedStatus(String status) {
    return status == 'Completed' ||
      status == 'Failed' ||
      status == 'Compensated' ||
      status == 'CompensationFailed' ||
      status == 'Cancelled' ||
      status == 'ContinuedAsNew';
  }

  // Detect a live compensation drive and route it to runCompensationStep.
  // Returns true when the instance was routed (caller must stop).
  private static Boolean routeIfCompensating(Workflow_Instance__c instance) {
    if (!isLiveCompensation(instance)) {
      return false;
    }
    String reassertedStatus = reassertCompensatingStatus(instance);
    runCompensationStep(instance, reassertedStatus);
    return true;
  }

  // A compensation step that SUSPENDed (e.g. waiting on a signal) leaves the
  // instance Suspended; signal() then flips it to Running before re-enqueueing.
  // In either state a latest step ending in '_Compensate' whose base name is on
  // the compensation stack means the instance is still compensating and must
  // route to runCompensationStep, not the forward path.
  private static Boolean isLiveCompensation(Workflow_Instance__c instance) {
    if (
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling'
    ) {
      return true;
    }
    if (instance.Status__c != 'Suspended' && instance.Status__c != 'Running') {
      return false;
    }
    // Only treat a trailing-'_Compensate' latest step as a live compensation
    // when the instance's compensation stack actually holds the matching base
    // step. A normal forward step that happens to be named '<x>_Compensate' and
    // is resumed by signal() (with no -- or unrelated -- stack) must NOT be
    // misrouted. The forward execution of compensatable steps grows the stack
    // too, so a non-empty stack alone is not enough; require the base name on it.
    List<String> compStack = String.isNotBlank(instance.Compensation_Stack__c)
      ? (List<String>) JSON.deserialize(
          instance.Compensation_Stack__c,
          List<String>.class
        )
      : new List<String>();
    if (compStack.isEmpty()) {
      return false;
    }
    return latestStepIsOnCompensationStack(instance.Id, compStack);
  }

  // True when the instance's most recent step execution is a '_Compensate' step
  // whose base name is on the compensation stack.
  private static Boolean latestStepIsOnCompensationStack(
    Id instanceId,
    List<String> compStack
  ) {
    List<Workflow_Step_Execution__c> latestSteps = [
      SELECT Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    return !latestSteps.isEmpty() &&
      latestSteps[0].Step_Name__c != null &&
      latestSteps[0].Step_Name__c.endsWith('_Compensate') &&
      compStack.contains(latestSteps[0].Step_Name__c.removeEnd('_Compensate'));
  }

  // Re-assert the compensating status before running the step: runCompensationStep
  // early-exits unless the instance is Compensating/Cancelling, so a Suspended
  // (initial detection) or Running (signal-resumed) instance must be restored to
  // the right compensation status first. The DML is DEFERRED to runCompensationStep
  // so a signal-resumed CalloutStep compensate() is not blocked by uncommitted DML.
  private static String reassertCompensatingStatus(
    Workflow_Instance__c instance
  ) {
    if (instance.Status__c != 'Suspended' && instance.Status__c != 'Running') {
      return null;
    }
    String reassertedStatus = (instance.Error_Message__c != null &&
      instance.Error_Message__c.contains('Cancelled by user'))
      ? 'Cancelling'
      : 'Compensating';
    instance.Status__c = reassertedStatus;
    instance.Async_Job_Id__c = null;
    return reassertedStatus;
  }

  // §2a. Operator pause gate — park at the chain handoff instead of proceeding.
  // Returns true when the instance is parked/paused (caller must stop).
  private static Boolean parkIfPaused(Workflow_Instance__c instance) {
    Boolean definitionPaused =
      WorkflowPauseGate.anyPaused() &&
      WorkflowPauseGate.isDefinitionPaused(instance.Workflow_Name__c);

    if (!(definitionPaused || instance.Status__c == 'Paused')) {
      return false;
    }
    // Park a not-yet-parked instance whose definition is paused; an
    // already-Paused row is just a no-op until the drain flips it to Running.
    if (definitionPaused && instance.Status__c != 'Paused') {
      instance.Status__c = 'Paused';
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    }

    return true;
  }

  // §2b. Concurrency admission gate. Returns true when the delivery was handled
  // here (no-op, parked, or re-driven after acquiring a slot).
  private static Boolean admitOrParkForConcurrency(
    Workflow_Instance__c instance
  ) {
    if (instance.Concurrency_Slot_Held__c) {
      return false;
    }
    if (ConcurrencyGate.isConfigured(instance.Workflow_Name__c)) {
      return admitConfiguredInstance(instance);
    }
    // Otherwise unbounded (no ceiling): fall through and run exactly as today. If
    // this instance was parked under a ceiling that an admin has since removed or
    // disabled, clear the stale admission-retry markers before running.
    if (instance.Concurrency_Parked__c) {
      instance.Concurrency_Parked__c = false;
      instance.Sleep_Until__c = null;
      instance.Async_Job_Id__c = null;
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
      // Re-arm the pending step's watchdog deadline that parkForConcurrency cleared,
      // mirroring the successful-admission path above. Without this a re-drive that
      // is delayed or lost (and a CalloutStep, whose pre-exec bookkeeping relies on
      // the watchdog already being armed) would run with no pre-start timeout net.
      // reArmTimeoutsForResume re-arms here because the workflow is now unbounded
      // (isConfigured is false), so it is not treated as a deferred admission.
      WorkflowTimeoutReArm.reArmTimeoutsForResume(
        new List<Workflow_Instance__c>{ instance }
      );
      // Re-drive in a fresh transaction instead of executing the step now: the
      // marker-clear DML above is uncommitted, and a CalloutStep cannot run while
      // uncommitted DML is pending (Salesforce forbids it) — the same reason the
      // admission-acquire path above re-hops. A fresh RUN_STEP re-reads this row
      // (now unparked) and runs the step cleanly.
      if (!(Test.isRunningTest() && disableQueueableInTest)) {
        enqueueResume(instance.Id);
      }

      return true;
    }
    return false;
  }

  // Configured (bounded) admission: re-read under a lock, then acquire a slot and
  // re-drive, or park for a later re-attempt. Always handles the delivery.
  private static Boolean admitConfiguredInstance(
    Workflow_Instance__c instance
  ) {
    Workflow_Instance__c locked = [
      SELECT Concurrency_Slot_Held__c, Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (locked.Concurrency_Slot_Held__c) {
      // A concurrent delivery already admitted this instance; its re-hop drives
      // the step. This delivery is a safe no-op.
      return true;
    }
    // A concurrent cancel/terminal transition may have landed between the
    // unlocked instance query above and this locked re-read. Acquiring a slot
    // and writing Status__c = 'Running' off the stale forward state would
    // resurrect a finished/cancelled instance, so bail unless it is still
    // forward-runnable. (Compensating/Cancelling/Paused are driven by their own
    // paths, never the admission gate.)
    if (
      locked.Status__c != 'Pending' &&
      locked.Status__c != 'Running' &&
      locked.Status__c != 'Suspended'
    ) {
      return true;
    }

    String resolvedStep = resolveStepForAdmission(instance);

    ConcurrencyGate.AdmissionResult admission = ConcurrencyGate.tryAcquire(
      instance.Workflow_Name__c
    );
    if (admission.admitted) {
      commitSlotAcquisitionAndRedrive(instance, resolvedStep);
      return true;
    }
    // Ceiling full: park and re-attempt admission automatically through the
    // existing sleep/watchdog resume plumbing.
    parkForConcurrency(instance, resolvedStep);
    return true;
  }

  // Resolve the initial step for a fresh start BEFORE consuming a slot, so an
  // unresolvable workflow class fails cleanly here instead of holding a slot that
  // reconciliation would count forever.
  private static String resolveStepForAdmission(Workflow_Instance__c instance) {
    String resolvedStep = instance.Current_Step__c;
    if (String.isNotBlank(resolvedStep)) {
      return resolvedStep;
    }
    Type wfType = WorkflowTypeResolver.resolve(
      instance.Workflow_Name__c,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    if (wfType == null) {
      throw new WorkflowException(
        'Could not resolve workflow definition class: ' +
        instance.Workflow_Name__c
      );
    }
    return ((WorkflowDefinition) wfType.newInstance()).getInitialStep();
  }

  // Slot acquired: commit the acquire + flag, clear admission-retry markers,
  // re-arm the step's watchdog deadline, and re-drive in a fresh transaction.
  private static void commitSlotAcquisitionAndRedrive(
    Workflow_Instance__c instance,
    String resolvedStep
  ) {
    instance.Concurrency_Slot_Held__c = true;
    instance.Concurrency_Parked__c = false;
    instance.Current_Step__c = resolvedStep;
    instance.Status__c = 'Running';
    instance.Sleep_Until__c = null;
    instance.Async_Job_Id__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    WorkflowTimeoutReArm.reArmTimeoutsForResume(
      new List<Workflow_Instance__c>{ instance }
    );
    if (!(Test.isRunningTest() && disableQueueableInTest)) {
      enqueueResume(instance.Id);
    }
  }

  // §2. Initialize the initial step in memory if this is the start (DML deferred
  // to the outcome handler).
  private static void initializeStepInMemory(Workflow_Instance__c instance) {
    if (String.isBlank(instance.Current_Step__c)) {
      Type wflowType = WorkflowTypeResolver.resolve(
        instance.Workflow_Name__c,
        WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
      );
      if (wflowType == null) {
        throw new WorkflowException(
          'Could not resolve workflow definition class: ' +
          instance.Workflow_Name__c
        );
      }
      WorkflowDefinition def = (WorkflowDefinition) wflowType.newInstance();
      instance.Current_Step__c = def.getInitialStep();
      instance.Status__c = 'Running';
    } else if (
      instance.Status__c == 'Suspended' ||
      instance.Status__c == 'Pending'
    ) {
      instance.Status__c = 'Running';
      instance.Async_Job_Id__c = null;
    }
  }

  // A blank-stepName delivery for a parallel (comma-list) current step is a
  // stale/duplicate orchestrator run.
  private static Boolean isStaleParallelOrchestratorRun(
    Workflow_Instance__c instance,
    String stepName
  ) {
    return String.isBlank(stepName) &&
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',');
  }

  // §3. Retrieve or create the step execution log with a FOR UPDATE lock, and
  // re-query the instance under the lock. Returns true on an early exit (already
  // finished, or the step was completed/terminated by a concurrent thread).
  private static Boolean acquireStepExecutionLog(RunStepContext ctx) {
    Id instanceId = ctx.instanceId;
    String activeStepName = ctx.activeStepName;
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Step_Name__c, Status__c, Input__c, Output__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = :activeStepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    ctx.stepVisit = computeCompletedVisitCount(stepExecs);
    stepExecs = lockLatestStepExecIfPresent(stepExecs);

    // Re-query the instance after acquiring the lock on the step execution to get
    // the most up-to-date committed state.
    Workflow_Instance__c instance = reloadInstanceLocked(instanceId);
    ctx.instance = instance;

    // Check early exit conditions for instance status
    if (isFinishedStatus(instance.Status__c)) {
      return true; // Already finished
    }

    Workflow_Step_Execution__c stepExec = buildOrReuseStepExec(ctx, stepExecs);
    if (stepExec == null) {
      return true; // Already completed or terminated by concurrent thread
    }
    ctx.stepExec = stepExec;
    return false;
  }

  // Count the already-completed (or operator-skipped) runs of this step.
  private static Integer computeCompletedVisitCount(
    List<Workflow_Step_Execution__c> stepExecs
  ) {
    Integer stepVisit = 0;
    for (Workflow_Step_Execution__c exec : stepExecs) {
      if (
        exec.Status__c == 'Completed' ||
        exec.Status__c == 'OperatorSkipped'
      ) {
        stepVisit++;
      }
    }
    return stepVisit;
  }

  // Re-read the latest step execution FOR UPDATE (with the columns the drive
  // needs) when one exists; otherwise return the empty list unchanged.
  private static List<Workflow_Step_Execution__c> lockLatestStepExecIfPresent(
    List<Workflow_Step_Execution__c> stepExecs
  ) {
    if (stepExecs.isEmpty()) {
      return stepExecs;
    }
    return [
      SELECT
        Id,
        Step_Name__c,
        Status__c,
        Input__c,
        Output__c,
        Retry_Count__c,
        Transient_Retry_Count__c,
        Captured_Values__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepExecs[0].Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
  }

  // Re-query the instance under the step lock; throw if it vanished.
  private static Workflow_Instance__c reloadInstanceLocked(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Status__c,
        Current_Step__c,
        Input__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Parent_Instance__c,
        Compensation_Stack__c,
        Definition_Version__c,
        Error_Message__c,
        Previous_Run_At__c,
        Concurrency_Slot_Held__c,
        Concurrency_Parked__c,
        CreatedDate,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instanceId);
    }
    return instances[0];
  }

  // Build a fresh step execution (seeded with the previous step's output) or
  // reuse the locked one; returns null when the reused step is already terminal.
  private static Workflow_Step_Execution__c buildOrReuseStepExec(
    RunStepContext ctx,
    List<Workflow_Step_Execution__c> stepExecs
  ) {
    if (stepExecs.isEmpty()) {
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = ctx.instanceId;
      stepExec.Step_Name__c = ctx.activeStepName;
      stepExec.Status__c = 'Running';
      stepExec.Retry_Count__c = 0;
      stepExec.Transient_Retry_Count__c = 0;

      // Get previous step's output to feed as input
      List<Workflow_Step_Execution__c> completedSteps = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :ctx.instanceId
          AND Status__c IN ('Completed', 'OperatorSkipped')
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      stepExec.Input__c = !completedSteps.isEmpty()
        ? completedSteps[0].Output__c
        : ctx.instance.Input__c;
      return stepExec;
    }

    Workflow_Step_Execution__c stepExec = stepExecs[0];
    if (isStepExecTerminal(stepExec.Status__c)) {
      return null;
    }
    stepExec.Status__c = 'Running';
    return stepExec;
  }

  // A step execution status that is already terminal for this drive.
  private static Boolean isStepExecTerminal(String status) {
    return status == 'Completed' ||
      status == 'OperatorSkipped' ||
      status == 'Failed' ||
      status == 'Cancelled' ||
      status == 'Compensated';
  }

  // Validate an explicit stepName against the active (possibly parallel) step.
  private static void validateExplicitStepName(
    Workflow_Instance__c instance,
    String stepName
  ) {
    if (String.isBlank(stepName) || instance.Current_Step__c == stepName) {
      return;
    }
    if (!isStepInParallelList(instance.Current_Step__c, stepName)) {
      throw new WorkflowException(
        'Step ' +
          stepName +
          ' is not the active/expected step for this instance: ' +
          instance.Current_Step__c
      );
    }
  }

  // True when stepName is one of the comma-separated active parallel steps.
  private static Boolean isStepInParallelList(
    String currentStep,
    String stepName
  ) {
    if (String.isBlank(currentStep) || !currentStep.contains(',')) {
      return false;
    }
    for (String pStep : currentStep.split(',')) {
      if (pStep.trim() == stepName) {
        return true;
      }
    }
    return false;
  }

  // §4. Resolve the previous step's output for a yielded/resumed execution.
  private static String resolvePreviousStepOutput(
    Workflow_Instance__c instance,
    String activeStepName,
    String stepName
  ) {
    Id instanceId = instance.Id;
    String prevOutput = null;
    List<Workflow_Step_Execution__c> lastCompleted;
    if (
      String.isNotBlank(stepName) &&
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',')
    ) {
      List<String> activeParallelSteps = instance.Current_Step__c.split(',');
      lastCompleted = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c IN ('Completed', 'OperatorSkipped')
          AND Step_Name__c NOT IN :activeParallelSteps
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
    } else {
      lastCompleted = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c IN ('Completed', 'OperatorSkipped')
          AND Step_Name__c != :activeStepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
    }
    if (!lastCompleted.isEmpty()) {
      prevOutput = lastCompleted[0].Output__c;
    }

    return prevOutput;
  }

  // §5/§6. Invoke the step (with fault injection and timeout bookkeeping) and
  // route its outcome through handleStepResult.
  private static void invokeStepAndHandleOutcome(
    RunStepContext ctx,
    String prevOutput
  ) {
    WorkflowStep stepInstance = resolveStepInstance(
      ctx.instance,
      ctx.activeStepName
    );
    StepContext context = buildStepContext(ctx, stepInstance, prevOutput);
    StepResult result = executeStepWithTimeout(ctx, stepInstance, context);

    // 6. Handle Step Outcome
    StepOutcomeContext outcome = new StepOutcomeContext();
    outcome.instance = ctx.instance;
    outcome.stepExec = ctx.stepExec;
    outcome.result = result;
    outcome.context = context;
    WorkflowStepOutcome.handleStepResult(outcome);
  }

  // Resolve and instantiate the WorkflowStep for the active step.
  private static WorkflowStep resolveStepInstance(
    Workflow_Instance__c instance,
    String activeStepName
  ) {
    Type stepType = WorkflowTypeResolver.resolve(
      activeStepName,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    if (stepType == null) {
      throw new WorkflowException(
        'Could not resolve class for step: ' + activeStepName
      );
    }
    return (WorkflowStep) stepType.newInstance();
  }

  // Choose the signal source: a parallel branch claims signals at read time
  // (Received -> Processing) so siblings cannot double-process them. That claim is
  // uncommitted DML, which would make a payload-driven callout illegal, so a
  // CalloutStep opts out of claiming and reads at-least-once instead.
  private static StepContext.SignalSource resolveSignalSource(
    RunStepContext ctx,
    WorkflowStep stepInstance
  ) {
    Boolean isParallelBranchStep =
      String.isNotBlank(ctx.stepName) &&
      String.isNotBlank(ctx.instance.Current_Step__c) &&
      ctx.instance.Current_Step__c.contains(',');
    Boolean claimSignals =
      isParallelBranchStep && !(stepInstance instanceof CalloutStep);
    return claimSignals
      ? (StepContext.SignalSource) new ParallelBranchSignalSource(
          ctx.instanceId
        )
      : (StepContext.SignalSource) new PendingSignalSource(ctx.instanceId);
  }

  // Hydrate the StepContext for this execution, stripping engine-internal markers
  // and resolving captures/retry state.
  private static StepContext buildStepContext(
    RunStepContext ctx,
    WorkflowStep stepInstance,
    String prevOutput
  ) {
    Workflow_Instance__c instance = ctx.instance;
    Workflow_Step_Execution__c stepExec = ctx.stepExec;

    StepContext.SignalSource signalSrc = resolveSignalSource(ctx, stepInstance);

    // Detect and strip the $timeoutResume marker (issue #35): the watchdog sets it
    // in Input__c of the fallback exec to durably signal the timeout-triggered
    // path. Strip it before passing inputJson to the context so the author step
    // never sees the engine-internal key.
    String resolvedInput = WorkflowPayloadOffload.resolvePayload(
      stepExec.Input__c
    );
    Boolean isTimeoutResume =
      String.isNotBlank(resolvedInput) &&
      resolvedInput.contains('$timeoutResume') &&
      'true'
        .equalsIgnoreCase(
          WorkflowPayloadOffload.readJsonMapKey(resolvedInput, '$timeoutResume')
        );
    if (isTimeoutResume) {
      resolvedInput = stripJsonMapKey(resolvedInput, '$timeoutResume');
      // Persist the cleaned input back to the locked record so the engine marker
      // does not linger in the durable audit row (saved with the exec below).
      stepExec.Input__c = resolvedInput;
    }

    Integer attempt = stepExec.Retry_Count__c != null
      ? (Integer) stepExec.Retry_Count__c + 1
      : 1;
    CaptureContext cc = resolveCaptureContext(stepInstance, stepExec);

    StepContext.Builder contextBuilder = new StepContext.Builder()
      .instanceId(ctx.instanceId)
      .workflowName(instance.Workflow_Name__c)
      .stepName(ctx.activeStepName)
      .inputJson(resolvedInput)
      .previousStepOutput(WorkflowPayloadOffload.resolvePayload(prevOutput))
      .stepStateJson(resolveStepStateJson(stepExec))
      .workflowInputJson(
        WorkflowPayloadOffload.resolvePayload(instance.Input__c)
      )
      .workflowVersion(resolveWorkflowVersion(instance))
      .stepVisit(ctx.stepVisit)
      .signalSource(signalSrc)
      .previousRunAt(instance.Previous_Run_At__c)
      .capturedValuesMap(cc.capturesMap)
      .attempt(attempt)
      .maxAttempts(cc.maxAttempts);
    if (isTimeoutResume) {
      contextBuilder.markTimeoutResume();
    }
    return contextBuilder.build();
  }

  // Strip the engine-internal $timeoutStep marker from the state JSON a timed wait
  // persisted in Output__c, so a signal-win resume that re-runs the wait step does
  // not surface the reserved key to the author via stepStateJson.
  private static String resolveStepStateJson(
    Workflow_Step_Execution__c stepExec
  ) {
    String resolvedState = WorkflowPayloadOffload.resolvePayload(
      stepExec.Output__c
    );
    if (
      String.isNotBlank(resolvedState) && resolvedState.contains('$timeoutStep')
    ) {
      resolvedState = stripJsonMapKey(resolvedState, '$timeoutStep');
    }
    return resolvedState;
  }

  // The instance's definition version, defaulting to 1.
  private static Integer resolveWorkflowVersion(Workflow_Instance__c instance) {
    return instance.Definition_Version__c != null
      ? (Integer) instance.Definition_Version__c
      : 1;
  }

  private class CaptureContext {
    Map<String, Object> capturesMap = new Map<String, Object>();
    Integer maxAttempts = 1;
  }

  // Resolve the captured-values map and the effective max attempts (from a
  // RetryConfigurable policy, or a persisted __maxAttempts, defaulting to 1).
  private static CaptureContext resolveCaptureContext(
    WorkflowStep stepInstance,
    Workflow_Step_Execution__c stepExec
  ) {
    CaptureContext cc = new CaptureContext();
    if (stepInstance instanceof RetryConfigurable) {
      RetryPolicy policy = sanitizePolicy(
        ((RetryConfigurable) stepInstance).getRetryPolicy()
      );
      cc.maxAttempts = policy.maximumAttempts;
    }
    applyCapturedValues(cc, stepInstance, stepExec);
    return cc;
  }

  /**
   * Merges the step's persisted captured-values map into the capture context and,
   * for a non-RetryConfigurable step, adopts a persisted __maxAttempts override.
   * @param cc the capture context to populate
   * @param stepInstance the step being executed
   * @param stepExec the step execution row carrying Captured_Values__c
   */
  private static void applyCapturedValues(
    CaptureContext cc,
    WorkflowStep stepInstance,
    Workflow_Step_Execution__c stepExec
  ) {
    if (String.isBlank(stepExec.Captured_Values__c)) {
      return;
    }
    String resolvedCaptures = WorkflowPayloadOffload.resolvePayload(
      stepExec.Captured_Values__c
    );
    if (String.isBlank(resolvedCaptures)) {
      return;
    }
    try {
      cc.capturesMap = (Map<String, Object>) JSON.deserializeUntyped(
        resolvedCaptures
      );
      if (
        !(stepInstance instanceof RetryConfigurable) &&
        cc.capturesMap.containsKey('__maxAttempts')
      ) {
        cc.maxAttempts = Integer.valueOf(cc.capturesMap.get('__maxAttempts'));
      }
    } catch (Exception ignored) {
      // Malformed captured values; retain the default maxAttempts.
    }
  }

  // Set the pre-exec Running status and Timeout_At__c (deferring the DML write for
  // a CalloutStep), returning the resolved timeout seconds for the finally block.
  private static Integer applyPreExecTimeout(
    Workflow_Step_Execution__c stepExec,
    WorkflowStep stepInstance
  ) {
    // A CalloutStep performs a synchronous, payload-driven HTTP callout inside
    // execute(), and Salesforce forbids a callout once the transaction holds
    // pending DML, so defer this timeout-bookkeeping write past execute() for one.
    // The step's Timeout_At__c and scheduled timeout job were already committed
    // when it was queued, so the watchdog stays armed across the callout; the
    // finally block reconciles the timeout once execute() returns.
    Boolean deferPreExecDml = stepInstance instanceof CalloutStep;
    stepExec.Status__c = 'Running';
    Integer timeoutSeconds = null;
    if (stepInstance instanceof TimeoutConfigurable) {
      timeoutSeconds = ((TimeoutConfigurable) stepInstance).getTimeoutSeconds();
    }
    if (timeoutSeconds != null && timeoutSeconds > 0) {
      stepExec.Timeout_At__c = DateTime.now().addSeconds(timeoutSeconds);
      if (!deferPreExecDml) {
        saveStepExec(stepExec);
      }
    } else {
      stepExec.Timeout_At__c = null;
      if (stepExec.Id == null && !deferPreExecDml) {
        saveStepExec(stepExec);
      }
    }
    return timeoutSeconds;
  }

  // Execute the step (honoring test fault injection) and reconcile its timeout in
  // a finally block.
  private static StepResult executeStepWithTimeout(
    RunStepContext ctx,
    WorkflowStep stepInstance,
    StepContext context
  ) {
    Workflow_Step_Execution__c stepExec = ctx.stepExec;
    Integer timeoutSeconds = applyPreExecTimeout(stepExec, stepInstance);

    StepResult result;
    try {
      if (Test.isRunningTest() && WorkflowFaultInjection.hasArmedFaults()) {
        result = WorkflowFaultInjection.checkAndInjectFault(
          ctx.instanceId,
          ctx.activeStepName,
          stepInstance
        );
      }
      if (result == null) {
        result = stepInstance.execute(context);
      }
    } finally {
      if (timeoutSeconds != null && timeoutSeconds > 0) {
        stepExec.Timeout_At__c = null;
        saveStepExec(stepExec);
        WorkflowTimeoutScheduler.cancelTimeoutJob(
          ctx.instanceId,
          ctx.activeStepName
        );
      }
    }
    return result;
  }

  /**
   * Lazily supplies the pending (unconsumed) signals targeting an instance so a
   * step that never reads signals pays no query/heap cost for unrelated
   * unconsumed signals on the instance. Tracks a cumulative row budget across
   * accessor calls so the step can never observe (and mark consumed) more rows
   * than the COMPLETE consume pass can handle.
   */
  @TestVisible
  private class PendingSignalSource implements StepContext.SignalSource {
    private final Id instanceId;
    private Integer rowBudget = serialSignalRowCap;
    private Boolean capped = false;

    @TestVisible
    private PendingSignalSource(Id instanceId) {
      this.instanceId = instanceId;
    }

    /**
     * @description Returns the pending (Received) signals of the given name for
     * this instance, drawing from a per-execution row budget. Once the budget is
     * spent it returns a single still-Received row so a suspend-if-empty step is
     * never stranded while a matching signal is pending.
     * @param signalName name of the signals to read
     * @return the pending signals of that name within the remaining row budget
     */
    public List<StepContext.Signal> getPendingSignals(String signalName) {
      if (rowBudget <= 0) {
        capped = true;
        // Don't report a false absence once the budget is spent: return one
        // still-Received row so a step that suspends-if-empty is not stranded
        // while a matching signal is pending (its wake event already fired on
        // insert). Bounded to a single row; the budget still bounds full
        // enumeration, and the remainder stays Received for a later read.
        return loadPendingSignals(this.instanceId, signalName, 1);
      }
      List<StepContext.Signal> loaded = loadPendingSignals(
        this.instanceId,
        signalName,
        rowBudget
      );
      // A full page means more rows of this name may exist beyond what was
      // returned, so the step did not necessarily see every pending row.
      if (loaded.size() >= rowBudget) {
        capped = true;
      }
      rowBudget -= loaded.size();
      return loaded;
    }

    /**
     * @description Returns the most-recent signal of the given name for this
     * instance. This single-row lookup always reflects database truth, even after
     * the row budget is spent, so a step never suspends on a false absence.
     * @param signalName name of the signal to look up
     * @return the latest matching signal, or null when none exists
     */
    public StepContext.Signal getLatestSignal(String signalName) {
      // A single-row "latest"/"has" lookup must reflect database truth even
      // after the row budget is spent. Reporting a false absence here is unsafe:
      // a step that then suspends as if the signal never arrived would never be
      // re-woken (the signal's wake event already fired on insert), stranding
      // the instance. One extra observed row stays within the COMPLETE consume
      // pass's headroom (the budget caps list reads, not single lookups), so the
      // lookup always queries the true most-recent row rather than gating on the
      // budget. Only a genuine full page is still flagged capped.
      //
      // Consume-safety of ungated lookups: each distinct name is queried once
      // (StepContext caches per name via latestByName), so the number of extra
      // observed rows past budget exhaustion is bounded by the SOQL-query
      // governor limit (~200 async) -- far under the 1 000-row headroom between
      // serialSignalRowCap (8 000) and the 9 000-row consume cap. A step
      // would exhaust SOQL long before it could match more ids than
      // markSignalsConsumed() can update, so no consume-overflow redelivery
      // arises (Codex L1108 documented as not reachable, not gated).
      StepContext.Signal latest = loadLatestSignal(this.instanceId, signalName);
      if (latest != null && rowBudget > 0) {
        rowBudget -= 1;
      }
      return latest;
    }

    /**
     * @description Reports whether a read hit the row-budget cap, so the engine
     * knows the step may not have observed every pending row.
     * @return true when a read was truncated by the row budget
     */
    public Boolean readWasCapped() {
      return capped;
    }
  }

  /**
   * Signal source for parallel branch steps. Atomically claims each signal at
   * read time (Received → Processing) so two concurrent branches cannot both
   * process the same payload. The claim is held for the lifetime of the current
   * execution attempt: COMPLETE promotes Processing → Consumed; any other
   * outcome (YIELD, SUSPEND, SLEEP, RETRY, …) rolls the claim back to Received
   * so the branch can re-observe the signal on its next run. Each call claims at
   * most PARALLEL_CLAIM_ROW_CAP rows so the read can never exceed the DML-row
   * limit before the step returns.
   *
   * Two-step pattern: an ORDER BY query finds candidate IDs, then a FOR UPDATE
   * lock on those IDs atomically claims them. The claim writes uncommitted DML,
   * which makes a later callout in the same transaction illegal; a step that
   * reads a signal and then calls out on its payload must implement CalloutStep
   * to opt into a non-claiming (at-least-once) read instead.
   */
  private inherited sharing class ParallelBranchSignalSource implements StepContext.SignalSource {
    private final Id instanceId;
    // Cumulative claim ROW budget across all accessor calls in this execution,
    // so claim DML (now) + the matching consume DML (at COMPLETE, same
    // transaction) together stay under the 10 000 DML-row limit no matter how
    // many names the step reads.
    private Integer claimBudget = PARALLEL_CLAIM_ROW_CAP;
    // Cumulative claim DML-STATEMENT budget; bounds how many update statements
    // the accessors issue so a many-name fan-in cannot exceed the 150 statement
    // limit. When spent, reads fall back to non-claiming (at-least-once).
    private Integer claimStatementBudget = PARALLEL_CLAIM_STATEMENT_BUDGET;
    // Set whenever a read was truncated, or fell back to non-claiming, so the
    // step may not have seen (or exclusively claimed) every matching row. The
    // engine then skips same-name duplicate cleanup at consume time.
    private Boolean capped = false;

    private ParallelBranchSignalSource(Id instanceId) {
      this.instanceId = instanceId;
    }

    /**
     * @description Reports whether a read was truncated or fell back to a
     * non-claiming (at-least-once) read, so the engine skips same-name duplicate
     * cleanup at consume time.
     * @return true when a read did not exclusively claim every matching row
     */
    public Boolean readWasCapped() {
      return capped;
    }

    // True when SOQL usage is close to the governor limit. Each claim issues a
    // FOR UPDATE lock query, so a many-name fan-in could exhaust SOQL before the
    // DML-statement budget; once near the limit the accessors stop locking and
    // read non-claiming instead (at-least-once) to make progress.
    private Boolean nearSoqlLimit() {
      return Limits.getLimitQueries() > 0 &&
        Limits.getQueries() >= (Integer) (0.8 * Limits.getLimitQueries());
    }

    // Reads still-Received rows in arrival order, optionally excluding ids and
    // scoped to a name. Read-only (no claim) -- the callers decide whether to
    // claim what comes back.
    private List<Workflow_Signal__c> queryReceived(
      String signalName,
      Set<Id> excludeIds,
      Integer limitN
    ) {
      Set<Id> skip = (excludeIds != null) ? excludeIds : new Set<Id>();
      if (String.isBlank(signalName)) {
        return [
          SELECT Id, Signal_Name__c, Payload__c, CreatedDate
          FROM Workflow_Signal__c
          WHERE
            Workflow_Instance__c = :instanceId
            AND Status__c = 'Received'
            AND Id NOT IN :skip
          WITH SYSTEM_MODE
          ORDER BY CreatedDate ASC, Id ASC
          LIMIT :limitN
        ];
      }
      return [
        SELECT Id, Signal_Name__c, Payload__c, CreatedDate
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
          AND Signal_Name__c = :signalName
          AND Id NOT IN :skip
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC, Id ASC
        LIMIT :limitN
      ];
    }

    private List<StepContext.Signal> toSignals(List<Workflow_Signal__c> rows) {
      List<String> rawPayloads = new List<String>();
      for (Workflow_Signal__c c : rows) {
        rawPayloads.add(c.Payload__c);
      }
      // Resolve offloaded payloads in one bulk query rather than one per row.
      List<String> resolvedPayloads = WorkflowPayloadOffload.resolvePayloads(
        rawPayloads
      );

      List<StepContext.Signal> out = new List<StepContext.Signal>();
      for (Integer i = 0; i < rows.size(); i++) {
        out.add(
          new StepContext.Signal(
              rows[i].Id,
              rows[i].Signal_Name__c,
              resolvedPayloads[i]
            )
            .withCreatedDate(rows[i].CreatedDate)
        );
      }
      return out;
    }

    /**
     * @description Atomically claims (Received to Processing) and returns the
     * pending signals of the given name for this branch, bounded by the claim row
     * and statement budgets. When a budget is spent it falls back to a single
     * non-claiming read so a suspend-if-empty branch is not stranded.
     * @param signalName name of the signals to read
     * @return the claimed (or, past budget, at-least-once) signals of that name
     */
    public List<StepContext.Signal> getPendingSignals(String signalName) {
      if (claimBudget <= 0) {
        capped = true;
        // Don't report a false absence once the claim budget is spent: return
        // one still-Received row read-only (at-least-once) so a branch that
        // suspends-if-empty is not stranded while a matching signal is pending.
        // Bounded to a single row; no claim is issued.
        return toSignals(queryReceived(signalName, null, 1));
      }
      // Statement or SOQL budget spent: read without claiming so a many-name
      // fan-in cannot exceed the DML-statement or SOQL limit. These rows are
      // returned read-only (claimed = false) and at-least-once; mark capped.
      // Debit the row budget just like the claim path so total observed rows
      // stay bounded by PARALLEL_CLAIM_ROW_CAP -- otherwise repeated fallback
      // pages could mark more observed-only ids than the COMPLETE consume pass
      // (capped at 9 000) can handle, leaving the remainder Received.
      if (claimStatementBudget <= 0 || nearSoqlLimit()) {
        capped = true;
        List<Workflow_Signal__c> rows = queryReceived(
          signalName,
          null,
          claimBudget
        );
        claimBudget -= rows.size();
        return toSignals(rows);
      }

      // Try to claim a page; if a sibling claimed the entire page between query
      // and lock, re-page past it (bounded) so we do not return empty while
      // later Received rows remain unclaimed and unwoken.
      return claimReceivedSignalPages(signalName);
    }

    /**
     * Pages through Received rows of the given name, locking and claiming a full
     * page at a time and re-paging past pages fully lost to siblings. Keeps the
     * FOR UPDATE query and claim update inside the paging loop by design.
     * @param signalName the signal name to claim
     * @return the claimed signals from the first successfully-locked page, or an
     *   empty list when no matching Received rows survive claiming
     */
    private List<StepContext.Signal> claimReceivedSignalPages(
      String signalName
    ) {
      Set<Id> tried = new Set<Id>();
      Integer attempts = 0;
      while (
        claimBudget > 0 &&
        claimStatementBudget > 0 &&
        attempts < PARALLEL_CLAIM_PAGE_RETRIES
      ) {
        attempts++;
        List<Workflow_Signal__c> candidates = queryReceived(
          signalName,
          tried,
          claimBudget
        );
        if (candidates.isEmpty()) {
          break; // no more matching Received rows anywhere
        }
        // A full page means more matching rows may remain beyond the budget,
        // so flag capped: the COMPLETE consume then preserves (does not clean up)
        // same-name rows this read did not return, leaving them Received for a
        // later read rather than losing them.
        //
        // Short-page note: if a sibling claims only PART of this page between the
        // query and the FOR UPDATE lock, we return just the surviving subset
        // (the sibling exclusively owns the rest -- correct for exactly-once).
        // When the page was NOT full, the query already returned every matching
        // Received row, so that subset is the complete backlog. A short page that
        // still leaves matching rows unreturned can only arise from a FULL page,
        // which requires >PARALLEL_CLAIM_ROW_CAP pending rows of one name (or a
        // budget already drawn down by claiming that many) -- the same
        // pathological >cap regime as the documented at-least-once degradation;
        // capped is set above so the remainder is preserved for a later read.
        if (candidates.size() >= claimBudget) {
          capped = true;
        }
        Set<Id> candidateIds = new Map<Id, Workflow_Signal__c>(candidates)
          .keySet();
        tried.addAll(candidateIds);

        List<StepContext.Signal> claimed = lockAndClaimSignalPage(
          candidateIds,
          candidates
        );
        if (claimed == null) {
          continue; // whole page lost to siblings; try the next page
        }
        return claimed;
      }
      return new List<StepContext.Signal>();
    }

    /**
     * @description Locks the candidate ids with `FOR UPDATE` and, if any
     * survive, atomically marks them Processing and updates them in a single
     * DML statement. The FOR UPDATE query and the follow-on update run inside
     * this one helper call so they stay in the same transaction context and
     * remain atomic per page. Debits the caller's claim row and statement
     * budgets on success.
     *
     * The per-invocation SOQL FOR UPDATE + DML update is intentional and
     * bounded: the caller loops at most `PARALLEL_CLAIM_PAGE_RETRIES` times and
     * returns immediately on the first successful claim, so this helper is
     * called at most that many times per accessor call (typically once).
     * @param candidateIds ids returned by the read-only Received query
     * @param candidates the corresponding candidate rows (payload source)
     * @return the claimed signals for this page on success, or null when the
     *   whole page was lost to siblings so the caller should re-page
     */
    private List<StepContext.Signal> lockAndClaimSignalPage(
      Set<Id> candidateIds,
      List<Workflow_Signal__c> candidates
    ) {
      List<Workflow_Signal__c> locked = [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE Id IN :candidateIds AND Status__c = 'Received'
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
      if (locked.isEmpty()) {
        return null;
      }
      Set<Id> claimedIds = markSignalsProcessing(locked);
      Database.update(locked, true, AccessLevel.SYSTEM_MODE); // one statement for the whole page
      claimBudget -= claimedIds.size();
      claimStatementBudget -= 1;
      return buildClaimedSignals(candidates, claimedIds);
    }

    /**
     * Flips each locked row to Processing (in memory) and returns the claimed ids.
     * @param locked the FOR UPDATE-locked Received rows
     * @return the set of ids marked Processing
     */
    private Set<Id> markSignalsProcessing(List<Workflow_Signal__c> locked) {
      Set<Id> claimedIds = new Set<Id>();
      for (Workflow_Signal__c sig : locked) {
        sig.Status__c = 'Processing';
        claimedIds.add(sig.Id);
      }
      return claimedIds;
    }

    /**
     * Builds claimed StepContext.Signals for the subset of candidates this branch
     * won, bulk-resolving any offloaded payloads in a single query.
     * @param candidates the candidate rows queried this page
     * @param claimedIds the ids this branch exclusively claimed
     * @return the claimed signals, marked claimed with their created dates
     */
    private List<StepContext.Signal> buildClaimedSignals(
      List<Workflow_Signal__c> candidates,
      Set<Id> claimedIds
    ) {
      List<Workflow_Signal__c> claimedRows = new List<Workflow_Signal__c>();
      List<String> rawPayloads = new List<String>();
      for (Workflow_Signal__c c : candidates) {
        if (claimedIds.contains(c.Id)) {
          claimedRows.add(c);
          rawPayloads.add(c.Payload__c);
        }
      }
      // Resolve any offloaded payloads with a single bulk query (not one per
      // row), matching the read-only list path: a claimed page of offloaded
      // child-completion signals would otherwise run one ContentVersion query
      // each and could exhaust SOQL.
      List<String> resolvedPayloads = WorkflowPayloadOffload.resolvePayloads(
        rawPayloads
      );
      List<StepContext.Signal> result = new List<StepContext.Signal>();
      for (Integer i = 0; i < claimedRows.size(); i++) {
        // claimed = true: this branch now exclusively owns the row.
        result.add(
          new StepContext.Signal(
              claimedRows[i].Id,
              claimedRows[i].Signal_Name__c,
              resolvedPayloads[i]
            )
            .withCreatedDate(claimedRows[i].CreatedDate)
            .asClaimed()
        );
      }
      return result;
    }

    /**
     * @description Atomically claims and returns the most-recent signal of the
     * given name for this branch, re-paging past candidate pages fully claimed by
     * siblings so a loser does not observe a false absence.
     * @param signalName name of the signal to look up
     * @return the latest claimed signal, or null when none is available
     */
    public StepContext.Signal getLatestSignal(String signalName) {
      if (String.isBlank(signalName)) {
        return null;
      }
      // A sibling can claim the newest candidates between our query and lock. If
      // an entire page of 10 is lost that way, a still-Received row just beyond
      // the page must not be reported absent (which could strand it), so re-page
      // (claimed rows are now Processing and drop out of the Received view) up to
      // a bounded number of times.
      for (
        Integer attempt = 0; attempt <= PARALLEL_CLAIM_PAGE_RETRIES; attempt++
      ) {
        List<Workflow_Signal__c> candidates = queryLatestSignalCandidates(
          instanceId,
          signalName
        );
        if (candidates.isEmpty()) {
          return null; // no matching Received rows remain
        }
        // Row, statement or SOQL budget spent: a single-row lookup must still
        // reflect database truth, so return the newest read-only (at-least-once)
        // rather than reporting a false absence -- a branch that then suspends as
        // if the signal never arrived would never be re-woken (its wake event
        // already fired on insert) and would strand. No claim is issued (no
        // budget), so mark capped to skip same-name cleanup at consume.
        if (claimBudget <= 0 || claimStatementBudget <= 0 || nearSoqlLimit()) {
          capped = true;
          Workflow_Signal__c c = candidates[0];
          return new StepContext.Signal(
              c.Id,
              c.Signal_Name__c,
              WorkflowPayloadOffload.resolvePayload(c.Payload__c)
            )
            .withCreatedDate(c.CreatedDate);
        }
        // Try to claim each candidate newest-first; if a sibling wins the race on
        // the newest row, fall back to the next-newest still-Received row instead
        // of reporting absence while a matching signal is still available.
        for (Workflow_Signal__c cand : candidates) {
          StepContext.Signal claimed = tryClaimOneLatestSignal(cand);
          if (claimed != null) {
            return claimed;
          }
        }
        // Every candidate in this page was claimed by a sibling between query and
        // lock; those rows are now Processing and drop out of the next query, so
        // re-page to consider rows beyond the first 10.
      }
      // Could not claim a matching row within the retry budget (siblings own the
      // visible matches). Mark capped so consume skips same-name cleanup.
      capped = true;
      return null;
    }

    /**
     * @description Attempts to atomically claim a single candidate signal
     * (Received to Processing) by FOR UPDATE-locking its id and, if it
     * survives, marking it Processing and issuing a single-row DML update.
     * The FOR UPDATE query and the follow-on update run inside this one
     * helper call so they stay in the same transaction context and remain
     * atomic. Debits the caller's claim row and statement budgets by one on
     * success.
     *
     * The per-candidate SOQL FOR UPDATE + DML update is intentional and
     * bounded: the caller iterates a page of at most 10 candidates and
     * returns immediately on the first successful claim, so this helper is
     * called at most 10 times per retry attempt.
     * @param cand the candidate row this branch attempts to claim
     * @return the claimed `StepContext.Signal` on success, or null when a
     *   sibling won the race so the caller should fall back to the next
     *   candidate
     */
    private StepContext.Signal tryClaimOneLatestSignal(
      Workflow_Signal__c cand
    ) {
      Id targetId = cand.Id;
      List<Workflow_Signal__c> locked = [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE Id = :targetId AND Status__c = 'Received'
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
      if (locked.isEmpty()) {
        return null; // lost the race on this row; try the next-newest
      }
      locked[0].Status__c = 'Processing';
      Database.update(locked[0], true, AccessLevel.SYSTEM_MODE);
      claimBudget -= 1;
      claimStatementBudget -= 1;
      // claimed = true: this branch now exclusively owns the row.
      return new StepContext.Signal(
          cand.Id,
          cand.Signal_Name__c,
          WorkflowPayloadOffload.resolvePayload(cand.Payload__c)
        )
        .withCreatedDate(cand.CreatedDate)
        .asClaimed();
    }
  }

  /**
   * @description Fetches the newest-first candidate page of Received signals
   * of the given name for the given instance, limited to 10 rows. Kept as a
   * top-level static helper so the per-attempt SOQL is not lexically inside
   * `ParallelBranchSignalSource.getLatestSignal`'s retry loop. The
   * per-attempt query is intentional and bounded: the caller retries at most
   * `PARALLEL_CLAIM_PAGE_RETRIES + 1` times and returns immediately on the
   * first successful claim.
   * @param instanceId workflow instance whose signals are being paged
   * @param signalName the signal name to page (assumed non-blank; caller
   *   short-circuits on blank)
   * @return up to 10 candidate rows in newest-first order
   */
  private static List<Workflow_Signal__c> queryLatestSignalCandidates(
    Id instanceId,
    String signalName
  ) {
    return [
      SELECT Id, Signal_Name__c, Payload__c, CreatedDate
      FROM Workflow_Signal__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Status__c = 'Received'
        AND Signal_Name__c = :signalName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 10
    ];
  }

  /**
   * Loads only the single most-recent pending signal matching a name, so a step
   * reading one decision via getSignal/hasSignal does not pull every duplicate
   * payload (consumption still re-queries by name, without payloads). Returns
   * null when no matching Received signal exists.
   * @param instanceId Id of the instance whose signals are read
   * @param signalName name of the signal to load
   * @return the most-recent matching Received signal, or null when none exists
   */
  private static StepContext.Signal loadLatestSignal(
    Id instanceId,
    String signalName
  ) {
    if (String.isBlank(signalName)) {
      return null;
    }
    List<Workflow_Signal__c> records = [
      SELECT Id, Signal_Name__c, Payload__c, CreatedDate
      FROM Workflow_Signal__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Status__c = 'Received'
        AND Signal_Name__c = :signalName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (records.isEmpty()) {
      return null;
    }
    return new StepContext.Signal(
        records[0].Id,
        records[0].Signal_Name__c,
        WorkflowPayloadOffload.resolvePayload(records[0].Payload__c)
      )
      .withCreatedDate(records[0].CreatedDate);
  }

  /**
   * Loads the pending (unconsumed) signals targeting an instance as read-only
   * StepContext.Signal views, in deterministic arrival order. A non-blank
   * signalName scopes the query (and its payload heap cost) to that one name so
   * a single named accessor never pulls every pending payload on the instance;
   * a blank name loads them all. Bounded by rowLimit so a serial step never
   * observes (and marks consumed) more rows than the COMPLETE consume pass can
   * handle. Cancel control signals are handled inline by signal() and never
   * persist a Workflow_Signal__c record, so they are structurally excluded here.
   * @param instanceId Id of the instance whose signals are read
   * @param signalName name to scope the read to, or blank to load all names
   * @param rowLimit maximum rows to read (falls back to serialSignalRowCap)
   * @return the pending signals in arrival order, up to the effective limit
   */
  private static List<StepContext.Signal> loadPendingSignals(
    Id instanceId,
    String signalName,
    Integer rowLimit
  ) {
    Integer effectiveLimit = (rowLimit != null &&
      rowLimit > 0)
      ? rowLimit
      : serialSignalRowCap;
    List<Workflow_Signal__c> records;
    if (String.isBlank(signalName)) {
      records = [
        SELECT Id, Signal_Name__c, Payload__c, CreatedDate
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Received'
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC, Id ASC
        LIMIT :effectiveLimit
      ];
    } else {
      records = [
        SELECT Id, Signal_Name__c, Payload__c, CreatedDate
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
          AND Signal_Name__c = :signalName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC, Id ASC
        LIMIT :effectiveLimit
      ];
    }

    List<String> rawPayloads = new List<String>();
    for (Workflow_Signal__c sig : records) {
      rawPayloads.add(sig.Payload__c);
    }
    // Resolve any offloaded payloads with a single bulk query (not one per row).
    List<String> resolvedPayloads = WorkflowPayloadOffload.resolvePayloads(
      rawPayloads
    );

    List<StepContext.Signal> signals = new List<StepContext.Signal>();
    for (Integer i = 0; i < records.size(); i++) {
      signals.add(
        new StepContext.Signal(
            records[i].Id,
            records[i].Signal_Name__c,
            resolvedPayloads[i]
          )
          .withCreatedDate(records[i].CreatedDate)
      );
    }
    return signals;
  }

  /**
   * Rolls back the Processing claims a parallel branch step made but did not
   * durably COMPLETE (e.g. YIELD, SUSPEND, SLEEP, WAIT_FOR_APPROVAL,
   * START_CHILD, RETRY), restoring them to Received so the branch (next run) or
   * a sibling can re-observe them. Scoped to ids this branch actually CLAIMED --
   * never rows it merely observed (a CalloutStep branch reads without claiming),
   * so it can never flip a sibling's concurrent claim back to Received.
   * @param context the step context whose claimed signal ids are rolled back
   */
  public static void rollbackClaimedSignals(StepContext context) {
    if (context == null) {
      return;
    }
    Set<Id> claimedIds = context.signals().getClaimedSignalIds();
    if (claimedIds == null || claimedIds.isEmpty()) {
      return;
    }
    List<Workflow_Signal__c> toRollback = [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE Id IN :claimedIds AND Status__c = 'Processing'
      WITH SYSTEM_MODE
    ];
    if (toRollback.isEmpty()) {
      return;
    }
    for (Workflow_Signal__c sig : toRollback) {
      sig.Status__c = 'Received';
    }
    Database.update(toRollback, true, AccessLevel.SYSTEM_MODE);
  }

  /**
   * Coalesces a possibly-null id set to a usable set.
   * @param ids the id set, possibly null
   * @return the given id set, or a new empty set when it is null
   */
  private static Set<Id> orEmptyIds(Set<Id> ids) {
    return ids == null ? new Set<Id>() : ids;
  }

  /**
   * Coalesces a possibly-null string set to a usable set.
   * @param vals the string set, possibly null
   * @return the given string set, or a new empty set when it is null
   */
  private static Set<String> orEmptyStrings(Set<String> vals) {
    return vals == null ? new Set<String>() : vals;
  }

  /**
   * 1a. Claimed ids: buckets rows to consume while Received OR Processing (this
   * branch's own exclusive claim).
   * @param claimedIds ids exclusively claimed by this branch
   * @param toConsume the accumulating rows-to-consume map
   */
  private static void addClaimedConsumable(
    Set<Id> claimedIds,
    Map<Id, Workflow_Signal__c> toConsume
  ) {
    if (claimedIds.isEmpty()) {
      return;
    }
    for (Workflow_Signal__c sig : [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE Id IN :claimedIds AND Status__c IN ('Received', 'Processing')
      WITH SYSTEM_MODE
      LIMIT 9000
    ]) {
      toConsume.put(sig.Id, sig);
    }
  }

  /**
   * 1b. Observed-but-not-claimed ids: buckets rows only while STILL Received, so
   * a row a sibling has since claimed (Processing) is left for the sibling.
   * @param observedOnly matched-but-unclaimed ids
   * @param toConsume the accumulating rows-to-consume map
   */
  private static void addObservedConsumable(
    Set<Id> observedOnly,
    Map<Id, Workflow_Signal__c> toConsume
  ) {
    if (observedOnly.isEmpty() || toConsume.size() >= 9000) {
      return;
    }
    for (Workflow_Signal__c sig : [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE Id IN :observedOnly AND Status__c = 'Received'
      WITH SYSTEM_MODE
      LIMIT 9000
    ]) {
      toConsume.put(sig.Id, sig);
    }
  }

  /**
   * 2. Serial same-name at-least-once duplicate cleanup (caller gates on serial +
   * uncapped read): buckets still-Received same-name rows the step did not match.
   * Restricted to still-Received rows so it never steals a sibling's claim.
   * @param instanceId the instance whose duplicates are cleaned up
   * @param context step context carrying matched names/ids
   * @param toConsume the accumulating rows-to-consume map
   */
  private static void addDuplicateConsumable(
    Id instanceId,
    StepContext context,
    Map<Id, Workflow_Signal__c> toConsume
  ) {
    Set<String> matchedNames = orEmptyStrings(
      context.signals().getConsumedSignalNames()
    );
    Set<Id> matchedIds = orEmptyIds(context.signals().getConsumedSignalIds());
    Integer remaining = 9000 - toConsume.size();
    if (matchedNames.isEmpty() || remaining <= 0) {
      return;
    }
    for (Workflow_Signal__c sig : [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Status__c = 'Received'
        AND Signal_Name__c IN :matchedNames
        AND Id NOT IN :matchedIds
      WITH SYSTEM_MODE
      LIMIT :remaining
    ]) {
      toConsume.put(sig.Id, sig);
    }
  }

  /**
   * Flips the bucketed rows to Consumed and persists them in a single update.
   * @param toConsume the rows to consume (may be empty)
   */
  private static void consumeSignals(Map<Id, Workflow_Signal__c> toConsume) {
    if (toConsume.isEmpty()) {
      return;
    }
    for (Workflow_Signal__c sig : toConsume.values()) {
      sig.Status__c = 'Consumed';
    }
    Database.update(toConsume.values(), true, AccessLevel.SYSTEM_MODE);
  }

  /**
   * Marks the signals a step matched consumed at its successful transition.
   * The exact rows the step observed/claimed (context.signals().getConsumedSignalIds())
   * are consumed FIRST so they can never be starved by the row cap when a name
   * has a large backlog of duplicates; only then is any remaining budget spent
   * cleaning up same-name at-least-once duplicates (including one delivered
   * mid-execution after the snapshot was taken). A name only probed absent never
   * consumes a signal that arrives afterwards (it contributes no matched id and
   * no matched name).
   *
   * Ownership-scoped consumption (per signal id, not per transition kind):
   *  - CLAIMED ids (this branch holds them as exclusive Processing) are consumed
   *    while Received OR Processing -- promoting this branch's own claim.
   *  - OBSERVED-ONLY ids (matched but not claimed: serial reads, SPLIT spawn,
   *    compensation, CalloutStep branches, and claim-budget overflow rows) are
   *    consumed only while STILL Received. If a sibling has since claimed one
   *    (Processing), it now belongs to that sibling and is left alone, so this
   *    branch can never consume a row out from under a sibling's rollback.
   *  - Same-name duplicate cleanup (serial only, and only when no read was
   *    capped) catches an at-least-once redelivery that arrived after the
   *    snapshot, restricted to still-Received rows. It is skipped when a read
   *    was capped, because backlog rows the step never saw would otherwise be
   *    consumed and lost.
   *
   * Matched ids are consumed first so the exact row the step read is never left
   * behind in favor of unrelated duplicates. The combined update is capped at
   * 9 000 rows to stay below the 10 000 DML-row governor limit; any excess rows
   * are consumed on the next COMPLETE that observes them.
   * @param instanceId Id of the instance whose signals are consumed
   * @param context step context carrying the matched/claimed signal ids and names
   * @param parallelBranch true when consuming for a parallel-branch step (enables
   * ownership-scoped claim promotion; disables serial same-name cleanup)
   */
  private static void markSignalsConsumed(
    Id instanceId,
    StepContext context,
    Boolean parallelBranch
  ) {
    if (context == null) {
      return;
    }
    Set<Id> matchedIds = orEmptyIds(context.signals().getConsumedSignalIds());
    Set<Id> claimedIds = orEmptyIds(context.signals().getClaimedSignalIds());
    Set<String> matchedNames = orEmptyStrings(
      context.signals().getConsumedSignalNames()
    );
    // A step that matched nothing triggers no query, keeping non-signal steps cheap.
    if (matchedIds.isEmpty() && matchedNames.isEmpty()) {
      return;
    }

    Map<Id, Workflow_Signal__c> toConsume = new Map<Id, Workflow_Signal__c>();
    addClaimedConsumable(claimedIds, toConsume);

    Set<Id> observedOnly = new Set<Id>(matchedIds);
    observedOnly.removeAll(claimedIds);
    addObservedConsumable(observedOnly, toConsume);

    // Serial steps only, and only when no read was capped (see addDuplicateConsumable).
    // Skipped on a capped read so backlog rows the step never observed are not
    // consumed (lost). Known limitation: signalReadWasCapped() is a single flag for
    // the whole execution, so if ANY name's read was capped, duplicate cleanup is
    // suppressed for EVERY matched name -- those names degrade to at-least-once. The
    // cap only triggers at pathological scale, where at-least-once is the contract.
    if (!parallelBranch && !context.signals().signalReadWasCapped()) {
      addDuplicateConsumable(instanceId, context, toConsume);
    }

    consumeSignals(toConsume);
  }

  /**
   * @description Consumes the signals a completing step observed, scoping claim
   * promotion by the outcome's computed parallel-branch flag. A
   * no-boolean-parameter seam so the extracted outcome handlers can drive the
   * ownership-scoped consume without exposing a public Boolean parameter.
   * @param instanceId Id of the instance whose signals are consumed
   * @param outcome the step outcome bundle carrying the step context and the
   * computed parallel-branch flag
   */
  public static void markSignalsConsumedForOutcome(
    Id instanceId,
    StepOutcomeContext outcome
  ) {
    markSignalsConsumed(instanceId, outcome.context, outcome.isParallel);
  }

  /**
   * @description Consumes the signals a serial (non-branch) transition observed.
   * A no-boolean-parameter seam so the extracted SPLIT handler can drive the
   * consume for its serially-run spawning step without exposing a public Boolean
   * parameter.
   * @param instanceId Id of the instance whose signals are consumed
   * @param context the step context carrying the observed signal ids and names
   */
  public static void markSignalsConsumedSerial(
    Id instanceId,
    StepContext context
  ) {
    markSignalsConsumed(instanceId, context, false);
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
    private List<String> stack;
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
    signal(new SignalRequest(keyOrId, signalName, payload));
  }

  /**
   * Tests whether the given key-or-id string is a Workflow_Instance__c record id
   * (15/18-char id-shaped and carrying the object's key prefix).
   * @param keyOrId the correlation key or instance id supplied by the caller
   * @return true when the value is a workflow instance id
   */
  private static Boolean isInstanceId(String keyOrId) {
    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');
    return String.isNotBlank(keyOrId) &&
      idPattern.matcher(keyOrId).matches() &&
      keyOrId.startsWith(wflowPrefix);
  }

  /**
   * Resolves the instance statuses eligible to receive a signal. A Cancel signal
   * must also reach a stalled rollback (CompensationFailed) so cancellation can
   * resume or force it terminal; other signals keep the active-only lookup.
   * 'Paused' is included in both so a signal reaches a parked instance.
   * @param isCancelSignal true when the signal is a cancellation
   * @return the statuses eligible for the signal lookup
   */
  private static List<String> signalLookupStatuses(Boolean isCancelSignal) {
    return isCancelSignal
      ? new List<String>{
          'Pending',
          'Running',
          'Suspended',
          'CompensationFailed',
          'Paused'
        }
      : new List<String>{
          'Pending',
          'Running',
          'Suspended',
          'Compensating',
          'Cancelling',
          'Paused'
        };
  }

  /**
   * Locks (FOR UPDATE) the single signal target instance, preferring an id match
   * (queried first so a correlation key equal to an id string cannot shadow it)
   * and falling back to a correlation-key match.
   * @param keyOrId the correlation key or instance id
   * @param isId true when keyOrId is a workflow instance id
   * @param lookupStatuses the statuses eligible for the lookup
   * @return the matched instance in a (possibly empty) single-element list
   */
  private static List<Workflow_Instance__c> findSignalTargetInstances(
    String keyOrId,
    Boolean isId,
    List<String> lookupStatuses
  ) {
    List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
    if (isId) {
      // Query by ID first to prevent matching a correlation key that equals this ID string
      Id targetId = (Id) keyOrId;
      instances = [
        SELECT
          Id,
          Status__c,
          Concurrency_Parked__c,
          Concurrency_Slot_Held__c,
          Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :targetId AND Status__c IN :lookupStatuses
        WITH SYSTEM_MODE
        LIMIT 1
        FOR UPDATE
      ];
    }

    if (instances.isEmpty()) {
      instances = [
        SELECT
          Id,
          Status__c,
          Concurrency_Parked__c,
          Concurrency_Slot_Held__c,
          Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c = :keyOrId AND Status__c IN :lookupStatuses
        WITH SYSTEM_MODE
        LIMIT 1
        FOR UPDATE
      ];
    }
    return instances;
  }

  /**
   * Handles a signal that matched no active instance. A keyed cancel with no
   * match is an idempotent no-op; an unkeyed cancel throws; a non-cancel signal
   * is captured as Unrouted so it is never silently lost.
   * @param req the original signal request
   * @param isCancelSignal true when the signal is a cancellation
   */
  private static void handleUnmatchedSignal(
    SignalRequest req,
    Boolean isCancelSignal
  ) {
    if (isCancelSignal) {
      // A keyed cancel with no active match is an idempotent no-op: either the
      // first delivery already drove the instance terminal (and a duplicate is
      // now arriving) or there is nothing to cancel. Swallow rather than throw
      // so an at-least-once redelivered keyed cancel never faults the publisher.
      if (String.isNotBlank(req.idempotencyKey)) {
        return;
      }
      throw new WorkflowException(
        'No active workflow found with key or ID: ' + req.keyOrId
      );
    }
    // Non-cancel signal with no active match: capture as Unrouted so it is
    // never silently lost and can be re-delivered by an operator.
    captureUnroutedSignals(
      new List<SignalRequest>{
        new SignalRequest(req.keyOrId, req.signalName, req.payload)
          .withDedupKey(req.dedupKey)
          .withIdempotencyKey(req.idempotencyKey)
      }
    );
  }

  /**
   * Delivers a cancellation signal to a matched instance. A keyed cancel is
   * deduped via a Consumed tombstone sharing one savepoint with the cancel, so
   * an at-least-once redelivery runs cancellation at most once; a duplicate is a
   * silent no-op.
   * @param instance the matched target instance
   * @param req the cancellation signal request
   */
  private static void handleCancelSignal(
    Workflow_Instance__c instance,
    SignalRequest req
  ) {
    Boolean runCompensations = parseRunCompensations(req.payload);
    if (String.isNotBlank(req.idempotencyKey)) {
      Savepoint sp = Database.setSavepoint();
      if (!claimKeyedCancel(instance.Id, req.signalName, req.idempotencyKey)) {
        return;
      }
      try {
        cancelInstance(instance.Id, runCompensations);
      } catch (Exception e) {
        Database.rollback(sp);
        throw e;
      }
      return;
    }
    cancelInstance(instance.Id, runCompensations);
  }

  /**
   * Inserts the Received signal record and wakes the instance. When a caller
   * idempotency key is present, the row insert and wake-up share one savepoint
   * (unique Signal_Key__c makes a duplicate insert a silent no-op; a failed
   * wake-up rolls the row back so a retry re-inserts and re-wakes).
   * @param instance the matched target instance
   * @param req the signal request being delivered
   */
  private static void deliverSignal(
    Workflow_Instance__c instance,
    SignalRequest req
  ) {
    Workflow_Signal__c sig = new Workflow_Signal__c();
    sig.Workflow_Instance__c = instance.Id;
    sig.Signal_Name__c = req.signalName;
    sig.Payload__c = req.payload;
    sig.Status__c = 'Received';

    if (String.isNotBlank(req.idempotencyKey)) {
      sig.Signal_Key__c = deriveSignalDedupKey(instance.Id, req.idempotencyKey);
      Savepoint sp = Database.setSavepoint();
      try {
        Database.insert(sig, true, AccessLevel.SYSTEM_MODE);
      } catch (DmlException ex) {
        if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
          return; // idempotent no-op: duplicate key already delivered
        }
        throw ex;
      }
      try {
        wakeInstanceForSignal(instance);
      } catch (Exception e) {
        Database.rollback(sp);
        clearEnqueueGuards(new Set<Id>{ instance.Id });
        throw e;
      }
      return;
    }

    Database.insert(sig, true, AccessLevel.SYSTEM_MODE);
    wakeInstanceForSignal(instance);
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
    String keyOrId = req.keyOrId;
    String signalName = req.signalName;
    Boolean isId = isInstanceId(keyOrId);

    // A Cancel signal must also be able to reach a stalled rollback (CompensationFailed)
    // so cancellation can resume it to completion or force it terminal. Other signals keep
    // the active-only lookup — a stalled rollback is not a forward-signal target.
    // 'Paused' is included in both branches so a signal reaches a parked instance:
    // a forward signal is held (Received) and re-observed on resume, and a Cancel
    // signal can still cancel a paused instance (matching the bulk signal path).
    Boolean isCancelSignal = isCancelSignalName(signalName);
    List<String> lookupStatuses = signalLookupStatuses(isCancelSignal);

    List<Workflow_Instance__c> instances = findSignalTargetInstances(
      keyOrId,
      isId,
      lookupStatuses
    );

    if (instances.isEmpty()) {
      handleUnmatchedSignal(req, isCancelSignal);
      return;
    }

    Workflow_Instance__c instance = instances[0];

    if (
      signalName.equalsIgnoreCase('Cancel') ||
      signalName.equalsIgnoreCase('CancelWorkflow')
    ) {
      handleCancelSignal(instance, req);
      return;
    }

    // Insert the signal record. When a caller-supplied idempotency key is present,
    // store a per-instance-scoped hash on Signal_Key__c and catch DUPLICATE_VALUE
    // to treat a repeat delivery as an idempotent no-op (no row, no wake-up).
    deliverSignal(instance, req);
  }

  /**
   * Wakes a (possibly parallel) instance to resume execution. When
   * Current_Step__c is a parallel branch list, each still-incomplete branch is
   * enqueued by its own step name: runStep returns early for a comma-separated
   * Current_Step__c with a blank stepName, so a single blank enqueue would never
   * resume a branch suspended on a signal. A serial instance is enqueued once
   * with a null stepName.
   * @param instanceId Id of the instance to wake and enqueue for resume
   */
  private static void enqueueResume(Id instanceId) {
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
   * Refreshes the cached status of an instance immediately after an in-batch
   * unkeyed {@code cancelInstance()} in {@link signal}, and records it in
   * {@code cancelledInstanceIds} when the cancel drove it to a terminal
   * (non-wakeable) state so later sibling signals in the same batch skip it.
   * <p><b>Intentional per-iteration SOQL — order-dependent, MUST stay in the
   * loop.</b> This runs one targeted SOQL query per unkeyed cancel because its
   * result is read by <i>later iterations of the same request loop</i> (via
   * {@code cancelledInstanceIds} and the refreshed cache): hoisting it out of
   * the loop would break the in-batch cancel&rarr;sibling ordering and could
   * resurrect a Cancelled workflow (waking a stale Suspended SObject back to
   * Running). It therefore cannot be bulkified without changing behavior.
   * <p><b>Bound / governor profile.</b> The governor exposure of this method
   * is <i>batch-size-scaled, not a fixed numeric cap</i>: it issues exactly one
   * targeted single-row SOQL query per unkeyed cancel, so its query count grows
   * linearly (O(n)) with the number of unkeyed cancels in the caller's batch —
   * there is no constant ceiling below which it stops scaling. Crucially, this
   * adds <i>no new scaling dimension</i>: it stays in the <b>same cost class as
   * the pre-existing per-instance {@code cancelInstance()} path</b>, which
   * already spends per-instance SOQL/DML for every unkeyed cancel. The per-hop
   * refresh is thus the same order (n) as the unavoidable {@code cancelInstance()}
   * calls it pairs with — it does not multiply that cost, it matches it.
   * <p>The <b>mitigation for large batches</b> is the bulk <i>keyed</i>-cancel
   * pre-pass above: callers that need to cancel many instances at once use the
   * keyed cancel path, which is bulk-claimed and refreshed in a single query
   * for the whole batch instead of one query per instance. This per-iteration
   * unkeyed path is retained only for the legacy at-least-once unkeyed cancel
   * semantics, whose ordering constraint (documented above) forbids bulkifying.
   * @param inst the just-cancelled instance whose cached status to refresh
   * @param instById the by-id/by-15-char instance cache to update in place
   * @param cancelledInstanceIds accumulates ids driven terminal by this batch
   */
  private static void refreshAfterUnkeyedCancel(
    Workflow_Instance__c inst,
    Map<String, Workflow_Instance__c> instById,
    Set<Id> cancelledInstanceIds
  ) {
    for (Workflow_Instance__c refreshed : [
      SELECT Id, Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
      WITH SYSTEM_MODE
    ]) {
      refreshCachedStatus(instById, refreshed);
      if (!isWakeableStatus(refreshed.Status__c)) {
        cancelledInstanceIds.add(inst.Id);
      }
    }
  }

  // ---- signal(List<SignalRequest>) decomposition holders ----

  /** Partitions the batch's request key/id strings into instance ids and keys. */
  private class SignalTargets {
    Set<Id> ids = new Set<Id>();
    Set<String> keys = new Set<String>();
  }

  /** The by-id (and 15-char) and by-normalized-key caches of the FOR UPDATE-locked instances. */
  private class SignalInstanceMaps {
    Map<String, Workflow_Instance__c> instById = new Map<String, Workflow_Instance__c>();
    Map<String, Workflow_Instance__c> instByKey = new Map<String, Workflow_Instance__c>();
  }

  /** Parallel lists describing the keyed-cancel claims to insert then act on. */
  private class KeyedCancelClaimBatch {
    List<Workflow_Signal__c> claims = new List<Workflow_Signal__c>();
    List<Id> instIds = new List<Id>();
    List<Boolean> runComp = new List<Boolean>();

    Boolean isEmpty() {
      return claims.isEmpty();
    }
  }

  /** Accumulated state of the forward-signal partition pass. */
  private class ForwardSignalPartition {
    List<Workflow_Signal__c> unkeyedSignals = new List<Workflow_Signal__c>();
    Set<String> seenCompositeKeys = new Set<String>();
    List<Workflow_Signal__c> keyedSignals = new List<Workflow_Signal__c>();
    List<Id> keyedSignalInstIds = new List<Id>();
    Map<Id, Workflow_Instance__c> activeInstById = new Map<Id, Workflow_Instance__c>();
    Set<Id> instancesWithUnkeyedSignal = new Set<Id>();
    Map<Id, Set<String>> signalsByInstanceId = new Map<Id, Set<String>>();
    Set<Id> instancesWithFreshKeyedSignal = new Set<Id>();
    // Instances driven terminal by an in-batch cancel; siblings are skipped.
    Set<Id> cancelledInstanceIds = new Set<Id>();
  }

  /** The instances to flip to Running and the set to wake/enqueue this call. */
  private class WakeSelection {
    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    List<Workflow_Instance__c> activeInstances = new List<Workflow_Instance__c>();
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
    if (requests == null || requests.isEmpty()) {
      return;
    }
    SignalTargets targets = classifyRequestTargets(requests);
    SignalInstanceMaps maps = loadSignalableInstances(
      targets.ids,
      targets.keys
    );
    captureUnmatchedRequests(requests, maps);
    Set<Id> cancelledInstanceIds = processKeyedCancels(requests, maps);
    ForwardSignalPartition partition = partitionForwardSignals(
      requests,
      maps,
      cancelledInstanceIds
    );
    System.Savepoint sp = insertSignalRows(partition);
    wakeAndEnqueueInstances(partition, sp);
  }

  /**
   * Partitions the batch's request identifiers into workflow-instance ids
   * (18/15-char key-prefixed) and correlation keys for the load query.
   * @param requests the signal requests to classify
   * @return the collected ids and keys
   */
  private static SignalTargets classifyRequestTargets(
    List<SignalRequest> requests
  ) {
    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');
    SignalTargets targets = new SignalTargets();
    for (SignalRequest req : requests) {
      if (req == null || String.isBlank(req.keyOrId)) {
        continue;
      }
      if (
        idPattern.matcher(req.keyOrId).matches() &&
        req.keyOrId.startsWith(wflowPrefix)
      ) {
        targets.ids.add((Id) req.keyOrId);
      } else {
        targets.keys.add(req.keyOrId);
      }
    }
    return targets;
  }

  /**
   * Loads and FOR UPDATE-locks every signalable instance addressed by the batch
   * and builds the by-id/by-key caches. Includes CompensationFailed so a Cancel
   * signal can reach a stalled rollback; the per-request guards downstream still
   * reject non-cancel signals to a stalled instance, preserving active-only
   * semantics for everything except cancellation.
   * @param ids the workflow-instance ids to lock
   * @param keys the correlation keys to lock
   * @return the by-id (and 15-char) and by-normalized-key instance caches
   */
  private static SignalInstanceMaps loadSignalableInstances(
    Set<Id> ids,
    Set<String> keys
  ) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Status__c,
        Correlation_Key__c,
        Current_Step__c,
        Compensation_Stack__c,
        Concurrency_Parked__c,
        Concurrency_Slot_Held__c,
        Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE
        (Id IN :ids
        OR Correlation_Key__c IN :keys)
        AND Status__c IN (
          'Pending',
          'Running',
          'Suspended',
          'Compensating',
          'Cancelling',
          'CompensationFailed',
          'Paused'
        )
      WITH SYSTEM_MODE
      FOR UPDATE
    ];

    SignalInstanceMaps maps = new SignalInstanceMaps();
    for (Workflow_Instance__c inst : instances) {
      maps.instById.put(inst.Id, inst);
      String idStr = String.valueOf(inst.Id);
      if (idStr.length() == 18) {
        maps.instById.put(idStr.substring(0, 15), inst);
      }
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        // Key by the normalized (lower-cased) correlation key: SOQL matched the
        // instance case-insensitively, so a request addressed as 'order-1' must
        // resolve the instance stored as 'Order-1' rather than miss the map and
        // be treated as unmatched (which would skip a keyed cancel entirely).
        maps.instByKey.put(normalizeKey(inst.Correlation_Key__c), inst);
      }
    }
    return maps;
  }

  /**
   * Resolves the locked instance a request addresses, by id first then by
   * normalized correlation key.
   * @param req the request whose target to resolve
   * @param maps the by-id/by-key instance caches
   * @return the matched instance, or null when none was loaded/locked
   */
  private static Workflow_Instance__c resolveInstance(
    SignalRequest req,
    SignalInstanceMaps maps
  ) {
    Workflow_Instance__c inst = maps.instById.get(req.keyOrId);
    if (inst == null) {
      inst = maps.instByKey.get(normalizeKey(req.keyOrId));
    }
    return inst;
  }

  /**
   * Separates requests with no active match: non-cancel misses are captured as
   * Unrouted for replay; an unkeyed cancel miss throws (capturing a cancel for
   * an unknown future instance is unsafe); a keyed cancel miss is an idempotent
   * no-op. Throws before any keyed-cancel work, exactly as the original loop.
   * @param requests the signal requests to screen
   * @param maps the by-id/by-key instance caches
   */
  private static void captureUnmatchedRequests(
    List<SignalRequest> requests,
    SignalInstanceMaps maps
  ) {
    List<SignalRequest> unmatchedToCapture = new List<SignalRequest>();
    for (SignalRequest req : requests) {
      if (req == null) {
        continue;
      }
      collectUnmatchedRequest(req, maps, unmatchedToCapture);
    }
    captureUnroutedSignals(unmatchedToCapture);
  }

  /**
   * Classifies a single request against the loaded instances and either records
   * it for Unrouted capture, no-ops it (keyed cancel miss), or throws (unkeyed
   * cancel miss). Guard-clause flattened; behavior matches the original nested
   * branches exactly.
   * @param req the request to classify
   * @param maps the by-id/by-key instance caches
   * @param unmatchedToCapture accumulator for non-cancel misses (mutated)
   */
  private static void collectUnmatchedRequest(
    SignalRequest req,
    SignalInstanceMaps maps,
    List<SignalRequest> unmatchedToCapture
  ) {
    Workflow_Instance__c inst = resolveInstance(req, maps);
    Boolean isCancel = isCancelSignalName(req.signalName);
    Boolean unmatched =
      inst == null || (inst.Status__c == 'CompensationFailed' && !isCancel);
    if (!unmatched) {
      return;
    }
    if (!isCancel) {
      unmatchedToCapture.add(req);
      return;
    }
    if (String.isNotBlank(req.idempotencyKey)) {
      return; // keyed cancel, no active match: idempotent no-op
    }
    throw new WorkflowException(
      'No active workflow found with key or ID: ' + req.keyOrId
    );
  }

  /**
   * Keyed-cancel pre-pass: claims the keyed cancels in bulk (one savepoint plus
   * one bulk marker insert guards the whole sub-batch, rather than ~2 DML
   * statements per row which would abort large batches against the 150-statement
   * limit), cancels the freshly-claimed instances, then refreshes their cached
   * statuses. A failed cancel rolls the batch's claims back so the keys retry.
   * @param requests the signal requests to scan for keyed cancels
   * @param maps the by-id/by-key instance caches (statuses refreshed in place)
   * @return the ids driven to a terminal (non-wakeable) state by this pre-pass
   */
  private static Set<Id> processKeyedCancels(
    List<SignalRequest> requests,
    SignalInstanceMaps maps
  ) {
    Set<Id> cancelledInstanceIds = new Set<Id>();
    KeyedCancelClaimBatch batch = collectCancelClaims(requests, maps);
    if (batch.isEmpty()) {
      return cancelledInstanceIds;
    }
    Savepoint cancelSp = Database.setSavepoint();
    Database.SaveResult[] claimResults = Database.insert(
      batch.claims,
      false,
      AccessLevel.SYSTEM_MODE
    );
    List<Integer> freshClaims = collectFreshClaimIndices(
      claimResults,
      cancelSp
    );
    Set<Id> attemptedCancelIds = runKeyedCancels(batch, freshClaims, cancelSp);
    refreshAfterKeyedCancels(attemptedCancelIds, maps, cancelledInstanceIds);
    return cancelledInstanceIds;
  }

  /**
   * Builds the keyed-cancel claim rows from the batch. In-batch duplicates
   * collapse via a seen-key set; cross-transaction duplicates lose the
   * unique-constraint race later and are skipped.
   * @param requests the signal requests to scan
   * @param maps the by-id/by-key instance caches
   * @return the parallel claim/instance/run-compensations lists to act on
   */
  private static KeyedCancelClaimBatch collectCancelClaims(
    List<SignalRequest> requests,
    SignalInstanceMaps maps
  ) {
    KeyedCancelClaimBatch batch = new KeyedCancelClaimBatch();
    Set<String> seenCancelKeys = new Set<String>();
    for (SignalRequest req : requests) {
      if (req == null) {
        continue;
      }
      if (
        String.isBlank(req.idempotencyKey) ||
        !isCancelSignalName(req.signalName)
      ) {
        continue;
      }
      Workflow_Instance__c inst = resolveInstance(req, maps);
      if (inst == null) {
        continue; // unmatched keyed cancel already no-op'd above
      }
      String claimKey = deriveSignalDedupKey(inst.Id, req.idempotencyKey);
      if (seenCancelKeys.contains(claimKey)) {
        continue; // in-batch duplicate keyed cancel
      }
      seenCancelKeys.add(claimKey);
      batch.claims.add(
        new Workflow_Signal__c(
          Workflow_Instance__c = inst.Id,
          Signal_Name__c = req.signalName,
          Status__c = 'Consumed',
          Signal_Key__c = claimKey
        )
      );
      batch.instIds.add(inst.Id);
      batch.runComp.add(parseRunCompensations(req.payload));
    }
    return batch;
  }

  /**
   * Collects the indices of the freshly-claimed (won-the-race) cancel rows.
   * Concurrent-duplicate losers are skipped; on any genuine (non-duplicate)
   * insert error the batch is rolled back and a WorkflowException is thrown.
   * @param claimResults the save results of the bulk claim insert
   * @param cancelSp the savepoint to roll back on a genuine failure
   * @return the indices (into the KeyedCancelClaimBatch) of the fresh claims
   */
  private static List<Integer> collectFreshClaimIndices(
    Database.SaveResult[] claimResults,
    Savepoint cancelSp
  ) {
    List<Integer> freshClaims = new List<Integer>();
    String claimError = null;
    for (Integer i = 0; i < claimResults.size(); i++) {
      Database.SaveResult sr = claimResults[i];
      if (sr.isSuccess()) {
        freshClaims.add(i);
        continue;
      }
      if (isDuplicateError(sr)) {
        continue;
      }
      if (claimError == null) {
        claimError = sr.getErrors()[0].getMessage();
      }
    }
    if (claimError != null) {
      Database.rollback(cancelSp);
      throw new WorkflowException('Failed to claim cancel: ' + claimError);
    }
    return freshClaims;
  }

  /**
   * Cancels each freshly-claimed instance in claim order. On any failure the
   * whole sub-batch's claims are rolled back and the error rethrown so the keys
   * can be retried.
   * @param batch the claim batch supplying instance ids and run-compensation flags
   * @param freshClaims the indices of the claims that won the race
   * @param cancelSp the savepoint to roll back on failure
   * @return the ids of the instances a cancel was attempted on
   */
  private static Set<Id> runKeyedCancels(
    KeyedCancelClaimBatch batch,
    List<Integer> freshClaims,
    Savepoint cancelSp
  ) {
    Set<Id> attemptedCancelIds = new Set<Id>();
    try {
      for (Integer i : freshClaims) {
        cancelInstance(batch.instIds[i], batch.runComp[i]);
        attemptedCancelIds.add(batch.instIds[i]);
      }
    } catch (Exception e) {
      Database.rollback(cancelSp);
      throw e;
    }
    return attemptedCancelIds;
  }

  /**
   * Refreshes the post-cancel statuses of the keyed-cancel sub-batch in one
   * query. A no-compensation cancel is terminal (Cancelled) and its sibling
   * signals must be skipped; a compensating cancel leaves the instance
   * Cancelling (still signalable), so the cached SObject is refreshed so the
   * forward loop wakes it rather than resurrecting it.
   * @param attemptedCancelIds the ids a cancel was attempted on
   * @param maps the by-id/by-key instance caches (statuses refreshed in place)
   * @param cancelledInstanceIds accumulates ids driven terminal (mutated)
   */
  private static void refreshAfterKeyedCancels(
    Set<Id> attemptedCancelIds,
    SignalInstanceMaps maps,
    Set<Id> cancelledInstanceIds
  ) {
    if (attemptedCancelIds.isEmpty()) {
      return;
    }
    for (Workflow_Instance__c refreshed : [
      SELECT Id, Status__c
      FROM Workflow_Instance__c
      WHERE Id IN :attemptedCancelIds
      WITH SYSTEM_MODE
    ]) {
      refreshCachedStatus(maps.instById, refreshed);
      if (!isWakeableStatus(refreshed.Status__c)) {
        cancelledInstanceIds.add(refreshed.Id);
      }
    }
  }

  /**
   * Partitions the forward (non-keyed-cancel) signals into the unkeyed and
   * keyed rows to insert, records which instances are wakeable, and runs any
   * in-batch unkeyed cancels in request order so their result is visible to
   * later siblings in the same batch.
   * @param requests the signal requests to partition
   * @param maps the by-id/by-key instance caches
   * @param cancelledInstanceIds ids already driven terminal by the keyed pre-pass
   * @return the accumulated forward-signal partition
   */
  private static ForwardSignalPartition partitionForwardSignals(
    List<SignalRequest> requests,
    SignalInstanceMaps maps,
    Set<Id> cancelledInstanceIds
  ) {
    ForwardSignalPartition part = new ForwardSignalPartition();
    part.cancelledInstanceIds = cancelledInstanceIds;
    for (SignalRequest req : requests) {
      if (req == null) {
        continue;
      }
      partitionOneForwardSignal(req, maps, part);
    }
    return part;
  }

  /**
   * Handles one forward request: records the signal name for join-readiness,
   * skips siblings of an instance a prior in-batch cancel drove terminal, runs
   * an in-batch unkeyed cancel (refreshing status for later siblings), or stages
   * the signal row. Guard-clause flattened; matches the original nesting exactly.
   * @param req the request to handle
   * @param maps the by-id/by-key instance caches
   * @param part the partition accumulator (mutated)
   */
  private static void partitionOneForwardSignal(
    SignalRequest req,
    SignalInstanceMaps maps,
    ForwardSignalPartition part
  ) {
    Workflow_Instance__c inst = resolveInstance(req, maps);
    if (inst != null) {
      if (!part.signalsByInstanceId.containsKey(inst.Id)) {
        part.signalsByInstanceId.put(inst.Id, new Set<String>());
      }
      part.signalsByInstanceId.get(inst.Id).add(req.signalName);
    }
    if (inst == null) {
      return;
    }
    // A cancel earlier in this batch already drove this instance terminal; the
    // cached SObject is stale, so skip every sibling signal for it rather than
    // acting on the pre-cancel status and resurrecting a Cancelled workflow.
    if (part.cancelledInstanceIds.contains(inst.Id)) {
      return;
    }
    Boolean isCancel =
      req.signalName.equalsIgnoreCase('Cancel') ||
      req.signalName.equalsIgnoreCase('CancelWorkflow');
    if (inst.Status__c == 'CompensationFailed' && !isCancel) {
      return;
    }
    if (isCancel) {
      if (String.isNotBlank(req.idempotencyKey)) {
        return; // keyed cancel handled in the bulk-claim pre-pass above
      }
      cancelInstance(inst.Id, parseRunCompensations(req.payload));
      refreshAfterUnkeyedCancel(inst, maps.instById, part.cancelledInstanceIds);
      return;
    }
    addForwardSignalRow(req, inst, part);
  }

  /**
   * Stages a forward signal row (Received). Unkeyed signals keep at-least-once
   * behavior; keyed signals dedup in-batch on the per-instance composite key
   * (the unique constraint handles concurrent transactions). Wakeable instances
   * are recorded for the wake phase.
   * @param req the request supplying the signal name/payload/idempotency key
   * @param inst the resolved target instance
   * @param part the partition accumulator (mutated)
   */
  private static void addForwardSignalRow(
    SignalRequest req,
    Workflow_Instance__c inst,
    ForwardSignalPartition part
  ) {
    Workflow_Signal__c sig = new Workflow_Signal__c(
      Workflow_Instance__c = inst.Id,
      Signal_Name__c = req.signalName,
      Payload__c = req.payload,
      Status__c = 'Received'
    );

    Boolean isWakeable =
      inst.Status__c == 'Suspended' ||
      inst.Status__c == 'Running' ||
      inst.Status__c == 'Compensating' ||
      inst.Status__c == 'Cancelling';

    if (String.isBlank(req.idempotencyKey)) {
      // Unkeyed signal: at-least-once behavior unchanged.
      part.unkeyedSignals.add(sig);
      if (isWakeable) {
        part.activeInstById.put(inst.Id, inst);
        part.instancesWithUnkeyedSignal.add(inst.Id);
      }
      return;
    }

    // Keyed signal: compute per-instance hash for unique-constraint dedup.
    // In-batch dedup skips later duplicates with the same composite key.
    String compositeKey = deriveSignalDedupKey(inst.Id, req.idempotencyKey);
    if (part.seenCompositeKeys.contains(compositeKey)) {
      return; // in-batch duplicate — skip entirely (no row, no wake-up)
    }
    part.seenCompositeKeys.add(compositeKey);
    sig.Signal_Key__c = compositeKey;
    part.keyedSignals.add(sig);
    part.keyedSignalInstIds.add(inst.Id);
    if (isWakeable) {
      part.activeInstById.put(inst.Id, inst);
    }
  }

  /**
   * Inserts the staged signal rows under one savepoint so the bulk call is
   * all-or-none: unkeyed rows use a plain insert; keyed rows use allOrNone=false
   * so a concurrent-duplicate loser is a no-op while a genuine error rolls back
   * and surfaces. The savepoint is shared with the wake phase, so it is returned
   * for that phase's rollback.
   * @param part the partition holding the rows to insert (fresh-keyed set mutated)
   * @return the savepoint, or null when there were no rows to insert
   */
  private static System.Savepoint insertSignalRows(
    ForwardSignalPartition part
  ) {
    if (part.unkeyedSignals.isEmpty() && part.keyedSignals.isEmpty()) {
      return null;
    }
    System.Savepoint sp = Database.setSavepoint();

    // Insert unkeyed signals (plain insert, unchanged at-least-once behavior).
    if (!part.unkeyedSignals.isEmpty()) {
      Database.insert(part.unkeyedSignals, true, AccessLevel.SYSTEM_MODE);
    }

    if (!part.keyedSignals.isEmpty()) {
      insertKeyedSignals(part, sp);
    }
    return sp;
  }

  /**
   * Inserts the keyed signal rows with allOrNone=false, recording the instances
   * whose insert won the race; swallows per-row DUPLICATE_VALUE (another
   * transaction won) but rolls back and rethrows on a genuine non-duplicate
   * error. Guard-clause flattened.
   * @param part the partition holding the keyed rows (fresh-keyed set mutated)
   * @param sp the savepoint to roll back on a genuine failure
   */
  private static void insertKeyedSignals(
    ForwardSignalPartition part,
    System.Savepoint sp
  ) {
    Database.SaveResult[] srs = Database.insert(
      part.keyedSignals,
      false,
      AccessLevel.SYSTEM_MODE
    );
    String genuineError = null;
    for (Integer i = 0; i < srs.size(); i++) {
      Database.SaveResult sr = srs[i];
      if (sr.isSuccess()) {
        part.instancesWithFreshKeyedSignal.add(part.keyedSignalInstIds[i]);
        continue;
      }
      if (isDuplicateError(sr)) {
        continue;
      }
      if (genuineError == null) {
        genuineError = sr.getErrors()[0].getMessage();
      }
    }
    if (genuineError != null) {
      Database.rollback(sp);
      throw new WorkflowException('Failed to insert signal: ' + genuineError);
    }
  }

  /**
   * Wakes and enqueues the instances that received a fresh signal, sharing the
   * insert savepoint so the whole bulk call is all-or-none: the status flip,
   * enqueueOrchestrators, and enqueueResumeBulk can still throw after the rows
   * are committed, so on any failure the inserted rows are rolled back and the
   * enqueue guards cleared before rethrowing.
   * @param part the forward-signal partition
   * @param sp the shared insert savepoint (null when nothing was inserted)
   */
  private static void wakeAndEnqueueInstances(
    ForwardSignalPartition part,
    System.Savepoint sp
  ) {
    try {
      // JOIN-READINESS BARRIER PRE-COMPUTATION
      Set<Id> gatedNonReadyParents = getGatedNonReadyParents(
        part.activeInstById.values(),
        part.signalsByInstanceId
      );
      WakeSelection sel = selectInstancesToWake(part, gatedNonReadyParents);
      if (!sel.instancesToUpdate.isEmpty()) {
        Database.update(sel.instancesToUpdate, true, AccessLevel.SYSTEM_MODE);
      }
      dispatchWakeEnqueues(sel.activeInstances);
    } catch (Exception e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      clearEnqueueGuards(part.activeInstById.keySet());
      throw e;
    }
  }

  /**
   * Selects, once per instance, those that received at least one fresh signal
   * this call (unkeyed always qualifies; keyed only if the insert won the race)
   * and applies the per-instance wake decision.
   * @param part the forward-signal partition
   * @param gatedNonReadyParents parents still gated behind a non-ready join
   * @return the instances to flip to Running plus the instances to enqueue
   */
  private static WakeSelection selectInstancesToWake(
    ForwardSignalPartition part,
    Set<Id> gatedNonReadyParents
  ) {
    WakeSelection sel = new WakeSelection();
    // Deduplicate: only process each active instance once.
    Set<Id> processedActiveIds = new Set<Id>();
    for (Workflow_Instance__c inst : part.activeInstById.values()) {
      if (processedActiveIds.contains(inst.Id)) {
        continue;
      }
      Boolean freshSignalLanded =
        part.instancesWithUnkeyedSignal.contains(inst.Id) ||
        part.instancesWithFreshKeyedSignal.contains(inst.Id);
      if (!freshSignalLanded) {
        continue;
      }
      processedActiveIds.add(inst.Id);
      applyWakeDecision(inst, gatedNonReadyParents, sel);
    }
    return sel;
  }

  /**
   * Applies the wake decision for one fresh-signalled instance. A Suspended
   * instance resumes to Running (its wait deadline disarmed) unless it is
   * concurrency-parked without a slot or gated behind a non-ready join, in which
   * case it is left alone and not enqueued. Compensating/Cancelling and Running
   * instances are enqueued (unless gated) without a status flip; a Paused
   * instance keeps its status and observes the held signal on resume.
   * @param inst the instance to decide on (status/Sleep_Until mutated on wake)
   * @param gatedNonReadyParents parents still gated behind a non-ready join
   * @param sel the wake selection to append to (mutated)
   */
  private static void applyWakeDecision(
    Workflow_Instance__c inst,
    Set<Id> gatedNonReadyParents,
    WakeSelection sel
  ) {
    if (inst.Status__c == 'Suspended') {
      // A concurrency-parked row has not won a slot. Waking it to Running would
      // leave a Running instance holding no slot (violating the no-running-without-
      // slot invariant) and hide it from the parked count. Like Paused, leave it
      // alone: the signal is already captured (Received) and is observed once
      // admission drives the step. Skip the wake and the enqueue entirely.
      if (
        inst.Concurrency_Parked__c == true &&
        inst.Concurrency_Slot_Held__c != true
      ) {
        return;
      }
      if (gatedNonReadyParents.contains(inst.Id)) {
        return;
      }
      inst.Status__c = 'Running';
      // Disarm the wait deadline (issue #35): a signal-wake ends the current
      // wait, so any armed Sleep_Until__c (timed-wait timeout, or a plain
      // sleeper's deadline) must be cleared or the watchdog would later
      // re-select this instance and mis-route/double-wake it. The resumed
      // step re-arms its own deadline if it suspends or sleeps again.
      inst.Sleep_Until__c = null;
      sel.instancesToUpdate.add(inst);
    }
    if (!gatedNonReadyParents.contains(inst.Id)) {
      sel.activeInstances.add(inst);
    }
  }

  /**
   * Enqueues the woken instances: a Compensating/Cancelling instance rolls back
   * serially and gets exactly one compensation wake (never per-branch fan-out
   * off a stale parallel step list); a forward parallel instance is collected
   * for a single bulk resume (one step-execution query for all, not one per
   * instance); everything else is enqueued once via the orchestrator.
   * @param activeInstances the instances to enqueue this call
   */
  private static void dispatchWakeEnqueues(
    List<Workflow_Instance__c> activeInstances
  ) {
    List<Id> instanceIdsToEnqueue = new List<Id>();
    List<Workflow_Instance__c> parallelInstances = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c inst : activeInstances) {
      Boolean isCompensatingInst =
        inst.Status__c == 'Compensating' ||
        inst.Status__c == 'Cancelling';
      if (
        !isCompensatingInst &&
        String.isNotBlank(inst.Current_Step__c) &&
        inst.Current_Step__c.contains(',')
      ) {
        parallelInstances.add(inst);
        continue;
      }
      if (!enqueuedInstanceIds.contains(inst.Id)) {
        enqueuedInstanceIds.add(inst.Id);
        instanceIdsToEnqueue.add(inst.Id);
      }
    }
    WorkflowOrchestratorEnqueue.enqueueOrchestrators(instanceIdsToEnqueue);
    enqueueResumeBulk(parallelInstances);
  }

  /**
   * Bulk variant of enqueueResume for the bulk signal() path: wakes the
   * incomplete branches of many parallel instances using the already-loaded
   * Current_Step__c values and ONE step-execution query across all of them,
   * instead of two queries per instance.
   * @param parallelInstances the parallel instances whose branches are re-enqueued
   */
  private static void enqueueResumeBulk(
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

  // Deserialize the compensation stack (empty when blank). Unlike the reclaim
  // path this intentionally lets malformed JSON surface, matching the original
  // retry semantics.
  private static List<String> parseCompensationStack(
    Workflow_Instance__c instance
  ) {
    if (String.isBlank(instance.Compensation_Stack__c)) {
      return new List<String>();
    }
    return (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
  }

  /**
   * Builds the Error_Message for a stalled ("rollback incomplete") saga, preserving
   * the cancel-driven phase marker when applicable. The resume paths (resumeCompensation,
   * the watchdog sleep-resume, and runStep) infer whether to resume as 'Cancelling'
   * vs 'Compensating' from the presence of 'Cancelled' in this text, so a cancel-driven
   * rollback must retain that marker across the stall — otherwise a cancelled saga would
   * resume as a plain compensation and wrongly terminate as 'Compensated' instead of
   * 'Cancelled'.
   * @param wasCancelling true when the stalled rollback was cancel-driven
   * @param detail the base stall detail message
   * @return the error message with the cancel-phase marker prepended when applicable
   */
  private static String buildRollbackIncompleteMessage(
    Boolean wasCancelling,
    String detail
  ) {
    return (wasCancelling ? 'Cancelled by user. ' : '') + detail;
  }

  /**
   * Resumes a saga whose rollback stalled (status CompensationFailed) from exactly
   * the failed compensation point. The remaining LIFO stack — preserved intact when
   * the compensation failed — is replayed in strict order through the existing
   * compensation/orchestrator path; no forward step is re-executed and no
   * already-successful compensation is re-run.
   *
   * Idempotent by construction: the status guard + FOR UPDATE lock means a second
   * (e.g. double-clicked) resume sees the instance already out of CompensationFailed
   * and is a no-op, so two concurrent orchestrator chains can never roll back the
   * same instance and no compensation is double-run.
   * @param instanceId Id of the CompensationFailed instance to resume rolling back
   */
  public static void resumeCompensation(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Status__c,
        Compensation_Stack__c,
        Error_Message__c,
        Failure_Category__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId AND Status__c = 'CompensationFailed'
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      // Not stalled (already resumed, fully compensated, or never stalled). The
      // operator action is idempotent, so treat this as a safe no-op.
      return;
    }
    Workflow_Instance__c instance = instances[0];

    List<String> stack = new List<String>();
    if (String.isNotBlank(instance.Compensation_Stack__c)) {
      stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
    }

    if (stack.isEmpty()) {
      // Defensive: a stalled state with no remaining work means the rollback is in
      // fact complete. Promote it to the fully-compensated terminal state.
      instance.Status__c = 'Compensated';
      instance.Current_Step__c = null;
      instance.Error_Message__c = null;
      instance.Failure_Category__c = null;
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
      return;
    }

    // Resume into the same phase the rollback was running in. A cancel-driven rollback
    // continues as 'Cancelling'; a failure-driven one as 'Compensating'. The phase is
    // identified by the engine-owned 'Cancelled by user' marker (set by cancel() and the
    // stalled-message builder) rather than an arbitrary 'Cancelled' substring, so a
    // failure-driven rollback whose compensation error text merely contains the word
    // "Cancelled" is not mistaken for a cancellation.
    Boolean isCancelling =
      instance.Error_Message__c != null &&
      instance.Error_Message__c.contains('Cancelled by user');
    instance.Status__c = isCancelling ? 'Cancelling' : 'Compensating';
    // Clear the stalled "rollback incomplete" banner, but for a cancel-driven rollback
    // keep the 'Cancelled by user' marker: runStep and the watchdog sleep-resume path read
    // it to restore the phase as 'Cancelling' if a remaining compensation suspends (RETRY/
    // SLEEP) before the stack drains. Without it the rollback would finish 'Compensated'
    // instead of 'Cancelled'. Also clear any stale sleep deadline so a later SUSPEND/
    // approval gate is not prematurely woken by the watchdog.
    instance.Error_Message__c = isCancelling
      ? 'Cancelled by user. Compensating.'
      : null;
    instance.Sleep_Until__c = null;
    instance.Async_Job_Id__c = null;
    instance.Failure_Category__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    // Append-only: create a FRESH pending compensation attempt for the stalled
    // top-of-stack step, leaving the failed attempt's record intact for the audit
    // trail. This is what makes runCompensationStep re-run the stalled compensation
    // rather than treating the prior Failed record as a terminal "already done".
    appendCompensationRetryStep(instance, stack);

    WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instance.Id));
      }
    } else {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(instance.Id, null);
    }
  }

  /**
   * Inserts a new Pending compensation step-execution log for the current top of the
   * rollback stack, unless a non-terminal (Pending/Running/Retrying) attempt already
   * exists. Unlike preCreateFirstCompensationStep, it does NOT short-circuit on a
   * prior terminal (Failed) attempt — that record is preserved and a fresh attempt is
   * appended, keeping the audit trail append-only while letting the rollback resume.
   * @param instance the instance whose compensation is being retried
   * @param stack the compensation stack whose top step is re-logged
   */
  public static void appendCompensationRetryStep(
    Workflow_Instance__c instance,
    List<String> stack
  ) {
    if (stack == null || stack.isEmpty()) {
      return;
    }
    String activeStepName = stack[stack.size() - 1];
    String compensationStepLogName = activeStepName + '_Compensate';

    // Only the latest attempt is read (existing[0]) for idempotency and to seed
    // the next retry, so LIMIT 1 avoids loading every historical attempt's inline
    // Captured_Values__c payload into heap on a repeatedly operator-resumed
    // compensation.
    List<Workflow_Step_Execution__c> existing = [
      SELECT Id, Status__c, Input__c, Output__c, Captured_Values__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :compensationStepLogName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];

    // If an attempt is already in flight, do not stack a duplicate (idempotency).
    if (isCompensationAttemptInFlight(existing)) {
      return;
    }

    insertCompensationRetryStep(instance, activeStepName, existing);
  }

  /**
   * Determines whether the latest compensation-step attempt is still in flight.
   * @param existing the latest compensation-step attempt (LIMIT 1, may be empty)
   * @return true when the latest attempt is Pending/Running/Retrying (in flight)
   */
  private static Boolean isCompensationAttemptInFlight(
    List<Workflow_Step_Execution__c> existing
  ) {
    if (existing.isEmpty()) {
      return false;
    }
    String latestStatus = existing[0].Status__c;
    return latestStatus == 'Pending' ||
      latestStatus == 'Running' ||
      latestStatus == 'Retrying';
  }

  /**
   * Seeds and inserts the appended compensation retry step. Prefers any checkpoint
   * the failed compensation already saved (a YIELD stores progress in its own
   * Output__c) so a resumed compensation continues from where it left off, falling
   * back to the original forward execution's input/output (the initial undo
   * context) when the failed attempt has no saved state. Carries the failed
   * attempt's capture-once values forward (append-only) so a resumed compensation
   * replays the same once() values instead of re-invoking their producers.
   * @param instance the compensating instance
   * @param activeStepName the forward step name being compensated
   * @param existing the latest compensation-step attempt (LIMIT 1, may be empty)
   */
  private static void insertCompensationRetryStep(
    Workflow_Instance__c instance,
    String activeStepName,
    List<Workflow_Step_Execution__c> existing
  ) {
    String compensationStepLogName = activeStepName + '_Compensate';
    List<Workflow_Step_Execution__c> originalExecs = [
      SELECT Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :activeStepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    String forwardInput = !originalExecs.isEmpty()
      ? originalExecs[0].Input__c
      : null;
    String forwardOutput = !originalExecs.isEmpty()
      ? originalExecs[0].Output__c
      : null;

    String priorInput = (!existing.isEmpty() &&
      String.isNotBlank(existing[0].Input__c))
      ? existing[0].Input__c
      : forwardInput;
    String checkpointOutput = (!existing.isEmpty() &&
      String.isNotBlank(existing[0].Output__c))
      ? existing[0].Output__c
      : forwardOutput;
    String priorCaptures = (!existing.isEmpty() &&
      String.isNotBlank(existing[0].Captured_Values__c))
      ? existing[0].Captured_Values__c
      : null;

    Workflow_Step_Execution__c compStepExec = new Workflow_Step_Execution__c();
    compStepExec.Workflow_Instance__c = instance.Id;
    compStepExec.Step_Name__c = compensationStepLogName;
    compStepExec.Status__c = 'Pending';
    compStepExec.Input__c = priorInput;
    compStepExec.Output__c = checkpointOutput;
    compStepExec.Captured_Values__c = priorCaptures;
    compStepExec.Retry_Count__c = 0;
    Database.insert(compStepExec, true, AccessLevel.SYSTEM_MODE);
  }

  // Mutable accumulator threaded through the compensation-step phase helpers so
  // each helper stays within the parameter and complexity budgets.
  private class CompensationRun {
    Workflow_Instance__c instance;
    String reassertedStatus;
    Id forwardSourceInstanceId;
    List<String> stack;
    String activeStepName;
    String compensationStepLogName;
    List<Workflow_Step_Execution__c> stepExecs;
    Workflow_Step_Execution__c stepExec;
    Integer compensateVisit = 0;
    Integer attempt;
    Integer maxAttempts;
    Map<String, Object> capturesMap;
    Boolean deferPreExecDml;
    Integer timeoutSeconds;
    StepResult result;
  }

  private static void runCompensationStep(
    Workflow_Instance__c instance,
    String reassertedStatus
  ) {
    CompensationRun run = new CompensationRun();
    run.instance = instance;
    run.reassertedStatus = reassertedStatus;
    // Determine the source of the forward executions (original completed run or this run)
    run.forwardSourceInstanceId = resolveForwardSourceInstanceId(instance);

    // 1. Read the compensation stack
    if (finalizeIfCompensationStackEmpty(run)) {
      return;
    }

    // 2. Get the top step to compensate (do not pop yet, only pop on success)
    run.activeStepName = run.stack[run.stack.size() - 1];
    run.compensationStepLogName = run.activeStepName + '_Compensate';

    // 3. Create or retrieve the compensation step execution log with FOR UPDATE lock.
    if (!prepareCompensationStepExec(run)) {
      return;
    }

    // 4. Instantiate the step and execute compensate
    executeCompensation(run);
  }

  // Resolve the instance whose completed forward executions supply compensation
  // inputs -- the predecessor run when it committed Completed, else this run.
  private static Id resolveForwardSourceInstanceId(
    Workflow_Instance__c instance
  ) {
    Id forwardSourceInstanceId = instance.Id;
    Id prevInstId = null;
    try {
      prevInstId = instance.Previous_Instance__c;
    } catch (SObjectException ex) {
      List<Workflow_Instance__c> temp = [
        SELECT Previous_Instance__c
        FROM Workflow_Instance__c
        WHERE Id = :instance.Id
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (!temp.isEmpty()) {
        prevInstId = temp[0].Previous_Instance__c;
      }
    }
    if (prevInstId != null) {
      List<Workflow_Instance__c> preds = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :prevInstId
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (!preds.isEmpty() && preds[0].Status__c == 'Completed') {
        forwardSourceInstanceId = prevInstId;
      }
    }
    return forwardSourceInstanceId;
  }

  // Read/parse the compensation stack; when empty, drive the instance to its
  // terminal state and return true to signal the caller to stop.
  private static Boolean finalizeIfCompensationStackEmpty(CompensationRun run) {
    Workflow_Instance__c instance = run.instance;
    if (String.isBlank(instance.Compensation_Stack__c)) {
      finalizeEmptyCompensationStack(instance);
      return true;
    }
    run.stack = (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
    if (run.stack.isEmpty()) {
      finalizeEmptyCompensationStack(instance);
      return true;
    }
    return false;
  }

  // Terminal transition for an instance whose compensation stack is exhausted.
  private static void finalizeEmptyCompensationStack(
    Workflow_Instance__c instance
  ) {
    instance.Status__c = (instance.Status__c == 'Cancelling')
      ? 'Cancelled'
      : 'Compensated';
    instance.Current_Step__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    WorkflowParentNotifier.notifyParentCompletion(instance);
    // Fire-and-forget outbound lifecycle event on terminal transition.
    WorkflowLifecyclePublisher.publish(instance);
  }

  // Load/lock the compensation step execution, re-query the instance under the
  // lock, and build (or short-circuit) the step exec. Returns false when an
  // early-exit branch handled the run and the caller should stop.
  private static Boolean prepareCompensationStepExec(CompensationRun run) {
    Workflow_Instance__c instance = run.instance;
    String compensationStepLogName = run.compensationStepLogName;
    // Load all executions so compensateVisit can be derived in Apex without an
    // extra COUNT() SOQL query.
    // Captured_Values__c is selected only on the single-row FOR UPDATE requery
    // below, not on this all-rows visit-count read, to avoid loading every
    // historical capture payload into heap (see the forward runStep path).
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Status__c, Input__c, Output__c, Retry_Count__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :compensationStepLogName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    run.compensateVisit = countCompensateVisits(stepExecs);

    if (!stepExecs.isEmpty()) {
      stepExecs = [
        SELECT
          Id,
          Status__c,
          Input__c,
          Output__c,
          Retry_Count__c,
          Step_Name__c,
          Captured_Values__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExecs[0].Id
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
    }
    run.stepExecs = stepExecs;

    // Re-query the instance after acquiring the lock on the step execution to get the most up-to-date committed state
    List<Workflow_Instance__c> freshInstances = [
      SELECT
        Id,
        Status__c,
        Compensation_Stack__c,
        Definition_Version__c,
        Workflow_Name__c,
        Input__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Error_Message__c,
        Previous_Run_At__c
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (freshInstances.isEmpty()) {
      throw new WorkflowException(
        'Workflow instance not found: ' + instance.Id
      );
    }
    instance = freshInstances[0];
    run.instance = instance;

    // A signal-resumed compensation: runStep detected the rollback but DEFERRED
    // the Suspended/Running -> Compensating status DML (so a CalloutStep callout
    // stays legal), so the re-queried status is still Suspended/Running. Restore
    // the in-memory compensating phase runStep computed so the guard below and the
    // terminal-status decisions use the correct phase; the DML is committed later
    // (before compensate() for an ordinary step, after it for a CalloutStep). Only
    // restore from Suspended/Running -- a status another transaction drove to a
    // terminal/failed value is left intact so the guard can early-exit on it.
    if (
      run.reassertedStatus != null &&
      (instance.Status__c == 'Suspended' ||
      instance.Status__c == 'Running')
    ) {
      instance.Status__c = run.reassertedStatus;
      instance.Async_Job_Id__c = null;
    }

    // Check early exit conditions for instance status
    if (
      instance.Status__c != 'Compensating' &&
      instance.Status__c != 'Cancelling'
    ) {
      return false; // Already completed compensation or aborted
    }

    return buildCompensationStepExec(run);
  }

  // Count prior compensate visits (Compensated/Completed executions) in Apex.
  private static Integer countCompensateVisits(
    List<Workflow_Step_Execution__c> stepExecs
  ) {
    Integer compensateVisit = 0;
    for (Workflow_Step_Execution__c exec : stepExecs) {
      if (exec.Status__c == 'Compensated' || exec.Status__c == 'Completed') {
        compensateVisit++;
      }
    }
    return compensateVisit;
  }

  // Build a fresh compensation step exec, or reuse the locked one. Returns false
  // when the locked exec is already terminal and the run was advanced/enqueued.
  private static Boolean buildCompensationStepExec(CompensationRun run) {
    Workflow_Instance__c instance = run.instance;
    List<Workflow_Step_Execution__c> stepExecs = run.stepExecs;
    Workflow_Step_Execution__c stepExec;
    if (stepExecs.isEmpty()) {
      stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = run.compensationStepLogName;
      stepExec.Status__c = 'Running';
      stepExec.Retry_Count__c = 0;

      // Retrieve the original step execution to get inputs/outputs
      List<Workflow_Step_Execution__c> originalExecs = [
        SELECT Input__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :run.forwardSourceInstanceId
          AND Step_Name__c = :run.activeStepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];

      stepExec.Input__c = !originalExecs.isEmpty()
        ? originalExecs[0].Input__c
        : null;
      stepExec.Output__c = !originalExecs.isEmpty()
        ? originalExecs[0].Output__c
        : null;
    } else {
      stepExec = stepExecs[0];
      if (
        stepExec.Status__c == 'Completed' ||
        stepExec.Status__c == 'Compensated' ||
        stepExec.Status__c == 'Failed' ||
        stepExec.Status__c == 'Cancelled'
      ) {
        finalizeAlreadyCompensatedStep(run);
        return false;
      }
      stepExec.Status__c = 'Running';
    }
    run.stepExec = stepExec;
    return true;
  }

  // Pop the already-terminal top step, advance the stack, and re-enqueue.
  private static void finalizeAlreadyCompensatedStep(CompensationRun run) {
    Workflow_Instance__c instance = run.instance;
    List<String> stack = run.stack;
    stack.remove(stack.size() - 1);
    instance.Compensation_Stack__c = JSON.serialize(stack);
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    if (!stack.isEmpty()) {
      preCreateFirstCompensationStep(instance);
      WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
    }

    enqueueCompensationOrchestrator(instance.Id);
  }

  // Enqueue the next orchestrator pass for a compensating instance.
  private static void enqueueCompensationOrchestrator(Id instanceId) {
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instanceId));
      }
    } else {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(instanceId, null);
    }
  }

  // Instantiate the compensatable step, build its context, execute compensate,
  // and dispatch the outcome. Non-compensatable steps are auto-compensated.
  private static void executeCompensation(CompensationRun run) {
    CompensatableStep compensatableStepInstance = resolveCompensatableStep(run);
    if (compensatableStepInstance == null) {
      return;
    }

    StepContext context = buildCompensationContext(
      run,
      compensatableStepInstance
    );
    commitPreCompensationState(run, compensatableStepInstance);

    if (!invokeCompensation(run, compensatableStepInstance, context)) {
      return;
    }

    StepOutcomeContext outcome = new StepOutcomeContext();
    outcome.instance = run.instance;
    outcome.stepExec = run.stepExec;
    outcome.result = run.result;
    outcome.stack = run.stack;
    outcome.context = context;
    handleCompensationStepResult(outcome);
  }

  // Resolve the compensatable step instance. Returns null (after auto-marking
  // the step Compensated and advancing the stack) for non-compensatable steps.
  private static CompensatableStep resolveCompensatableStep(
    CompensationRun run
  ) {
    Workflow_Instance__c instance = run.instance;
    Type stepType = WorkflowTypeResolver.resolve(
      run.activeStepName,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    if (stepType == null) {
      throw new WorkflowException(
        'Could not resolve class for step compensation: ' + run.activeStepName
      );
    }

    Object stepInstanceObj = stepType.newInstance();
    if (!(stepInstanceObj instanceof CompensatableStep)) {
      Workflow_Step_Execution__c stepExec = run.stepExec;
      stepExec.Status__c = 'Compensated';
      saveStepExec(stepExec);

      List<String> stack = run.stack;
      stack.remove(stack.size() - 1);
      instance.Compensation_Stack__c = JSON.serialize(stack);
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);

      if (!stack.isEmpty()) {
        WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
      }

      enqueueCompensationOrchestrator(instance.Id);
      return null;
    }

    return (CompensatableStep) stepInstanceObj;
  }

  // Build the StepContext for the compensate() invocation.
  private static StepContext buildCompensationContext(
    CompensationRun run,
    CompensatableStep compensatableStepInstance
  ) {
    Workflow_Instance__c instance = run.instance;
    Workflow_Step_Execution__c stepExec = run.stepExec;

    String prevOutput = null;
    List<Workflow_Step_Execution__c> completedBefore = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :run.forwardSourceInstanceId
        AND Status__c IN ('Completed', 'OperatorSkipped')
        AND Step_Name__c != :run.activeStepName
        AND Step_Name__c != :run.compensationStepLogName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (!completedBefore.isEmpty()) {
      prevOutput = completedBefore[0].Output__c;
    }

    resolveCompensationRetryState(run, compensatableStepInstance);

    return new StepContext.Builder()
      .instanceId(instance.Id)
      .workflowName(instance.Workflow_Name__c)
      .stepName(run.compensationStepLogName)
      .inputJson(WorkflowPayloadOffload.resolvePayload(stepExec.Input__c))
      .previousStepOutput(WorkflowPayloadOffload.resolvePayload(prevOutput))
      .stepStateJson(WorkflowPayloadOffload.resolvePayload(stepExec.Output__c))
      .workflowInputJson(
        WorkflowPayloadOffload.resolvePayload(instance.Input__c)
      )
      .workflowVersion(
        instance.Definition_Version__c != null
          ? (Integer) instance.Definition_Version__c
          : 1
      )
      .stepVisit(run.compensateVisit)
      .signalSource(new PendingSignalSource(instance.Id))
      .previousRunAt(instance.Previous_Run_At__c)
      .capturedValuesMap(run.capturesMap)
      .attempt(run.attempt)
      .maxAttempts(run.maxAttempts)
      .build();
  }

  // Derive attempt/maxAttempts and captured-values map for the compensation.
  private static void resolveCompensationRetryState(
    CompensationRun run,
    CompensatableStep compensatableStepInstance
  ) {
    Workflow_Step_Execution__c stepExec = run.stepExec;
    run.attempt = stepExec.Retry_Count__c != null
      ? (Integer) stepExec.Retry_Count__c + 1
      : 1;
    Integer maxAttempts = 1;
    Map<String, Object> capturesMap = new Map<String, Object>();
    if (compensatableStepInstance instanceof RetryConfigurable) {
      RetryPolicy policy = sanitizePolicy(
        ((RetryConfigurable) compensatableStepInstance).getRetryPolicy()
      );
      maxAttempts = policy.maximumAttempts;
    }
    if (String.isNotBlank(stepExec.Captured_Values__c)) {
      String resolvedCaptures = WorkflowPayloadOffload.resolvePayload(
        stepExec.Captured_Values__c
      );
      if (String.isNotBlank(resolvedCaptures)) {
        try {
          capturesMap = (Map<String, Object>) JSON.deserializeUntyped(
            resolvedCaptures
          );
          maxAttempts = resolveCapturedMaxAttempts(
            compensatableStepInstance,
            capturesMap,
            maxAttempts
          );
        } catch (Exception ignored) {
          // Malformed captured values; retain the default maxAttempts.
        }
      }
    }
    run.maxAttempts = maxAttempts;
    run.capturesMap = capturesMap;
  }

  // For a non-RetryConfigurable compensation step, honor a persisted
  // '__maxAttempts' captured value; otherwise keep the supplied default.
  private static Integer resolveCapturedMaxAttempts(
    CompensatableStep compensatableStepInstance,
    Map<String, Object> capturesMap,
    Integer defaultMaxAttempts
  ) {
    if (compensatableStepInstance instanceof RetryConfigurable) {
      return defaultMaxAttempts;
    }
    if (!capturesMap.containsKey('__maxAttempts')) {
      return defaultMaxAttempts;
    }
    return Integer.valueOf(capturesMap.get('__maxAttempts'));
  }

  // Commit the pre-execution step status/timeout so the watchdog can detect
  // timeouts. Deferred for a CalloutStep so its payload-driven callout is legal.
  private static void commitPreCompensationState(
    CompensationRun run,
    CompensatableStep compensatableStepInstance
  ) {
    Workflow_Instance__c instance = run.instance;
    Workflow_Step_Execution__c stepExec = run.stepExec;
    // Save/Commit step execution status and set Timeout_At__c before executing compensation so watchdog can detect timeouts.
    // As in the forward execute() path, a CalloutStep performs a synchronous,
    // payload-driven callout inside compensate() and Salesforce forbids a
    // callout once the transaction holds pending DML, so defer this timeout
    // write past compensate() for a CalloutStep. The step's Timeout_At__c and
    // scheduled job were already committed when it was queued, so the watchdog
    // stays armed; the finally block reconciles the timeout afterward.
    Boolean deferPreExecDml = compensatableStepInstance instanceof CalloutStep;
    run.deferPreExecDml = deferPreExecDml;
    // Persist the compensating status that runStep re-asserted in memory. For an
    // ordinary step commit it now (matching the prior commit-before-compensate()
    // behavior); for a CalloutStep leave it uncommitted so the payload-driven
    // callout in compensate() below stays legal -- handleCompensationStepResult
    // writes the instance after compensate() returns. The earlier early-return
    // branches (already-terminal exec, non-CompensatableStep) commit the status
    // via their own update, so a pending re-assert is never dropped.
    if (run.reassertedStatus != null && !deferPreExecDml) {
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    }
    stepExec.Status__c = 'Running';
    Integer timeoutSeconds = null;
    if (compensatableStepInstance instanceof TimeoutConfigurable) {
      timeoutSeconds = ((TimeoutConfigurable) compensatableStepInstance)
        .getTimeoutSeconds();
    }
    if (timeoutSeconds != null && timeoutSeconds > 0) {
      stepExec.Timeout_At__c = DateTime.now().addSeconds(timeoutSeconds);
      if (!deferPreExecDml) {
        saveStepExec(stepExec);
      }
    } else {
      stepExec.Timeout_At__c = null;
      if (stepExec.Id == null && !deferPreExecDml) {
        saveStepExec(stepExec);
      }
    }
    run.timeoutSeconds = timeoutSeconds;
  }

  // Execute compensate() (honoring test fault injection), reconciling the
  // timeout in the finally block. Returns false when the step failed and the
  // failure was already handled; otherwise stores the result on the run.
  private static Boolean invokeCompensation(
    CompensationRun run,
    CompensatableStep compensatableStepInstance,
    StepContext context
  ) {
    Workflow_Instance__c instance = run.instance;
    Workflow_Step_Execution__c stepExec = run.stepExec;
    String compensationStepLogName = run.compensationStepLogName;
    Integer timeoutSeconds = run.timeoutSeconds;
    StepResult result;
    try {
      result = resolveInjectedCompensationFault(run, compensatableStepInstance);
      if (result == null) {
        result = compensatableStepInstance.compensate(context);
      }
    } catch (Exception ex) {
      StepOutcomeContext crashOutcome = new StepOutcomeContext();
      crashOutcome.instance = instance;
      crashOutcome.stepExec = stepExec;
      crashOutcome.context = context;
      WorkflowBreadcrumbs.persistStepBreadcrumbs(crashOutcome);
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c =
        ex.getMessage() +
        '\n' +
        ex.getStackTraceString();
      saveStepExec(stepExec);
      failWorkflowInstance(
        instance.Id,
        compensationStepLogName,
        ex.getMessage()
      );
      return false;
    } finally {
      if (timeoutSeconds != null && timeoutSeconds > 0) {
        stepExec.Timeout_At__c = null;
        saveStepExec(stepExec);
        WorkflowTimeoutScheduler.cancelTimeoutJob(
          instance.Id,
          compensationStepLogName
        );
      }
    }
    run.result = result;
    return true;
  }

  // Return an injected fault result for the compensation when test fault
  // injection is armed for this step; otherwise null (run compensate normally).
  private static StepResult resolveInjectedCompensationFault(
    CompensationRun run,
    CompensatableStep compensatableStepInstance
  ) {
    if (!(Test.isRunningTest() && WorkflowFaultInjection.hasArmedFaults())) {
      return null;
    }
    Workflow_Instance__c instance = run.instance;
    String compensationStepLogName = run.compensationStepLogName;
    Id rootId = WorkflowFaultInjection.getRootInstanceId(instance.Id);
    String compKey =
      (rootId != null ? String.valueOf(rootId) : '') +
      ':' +
      compensationStepLogName.toLowerCase();
    if (WorkflowFaultInjection.hasFaultForKey(compKey)) {
      return WorkflowFaultInjection.checkAndInjectFault(
        instance.Id,
        compensationStepLogName,
        compensatableStepInstance
      );
    }
    return WorkflowFaultInjection.checkAndInjectFault(
      instance.Id,
      run.activeStepName,
      compensatableStepInstance
    );
  }

  private static void handleCompensationStepResult(StepOutcomeContext outcome) {
    WorkflowBreadcrumbs.persistStepBreadcrumbs(outcome);
    Workflow_Instance__c instance = loadFreshCompensationInstance(
      outcome.instance
    );
    persistCompensationProgressAndCaptures(outcome, instance);

    StepResult.ActionType action = outcome.result.directive().action;
    if (action == StepResult.ActionType.COMPLETE) {
      handleCompensationComplete(outcome, instance);
    } else if (action == StepResult.ActionType.YIELD) {
      handleCompensationYield(outcome, instance);
    } else if (action == StepResult.ActionType.SUSPEND) {
      handleCompensationSuspend(outcome, instance);
    } else if (action == StepResult.ActionType.SLEEP) {
      handleCompensationSleep(outcome, instance);
    } else if (action == StepResult.ActionType.WAIT_FOR_APPROVAL) {
      handleCompensationWaitForApproval(outcome, instance);
    } else if (action == StepResult.ActionType.RETRY) {
      handleCompensationRetry(outcome, instance);
    } else if (action == StepResult.ActionType.FAIL) {
      handleCompensationFail(outcome, instance);
    } else {
      handleCompensationUnsupported(outcome, instance);
    }
  }

  // Re-load the instance under FOR UPDATE and reject if a concurrent path
  // already terminated or cancelled it.
  private static Workflow_Instance__c loadFreshCompensationInstance(
    Workflow_Instance__c instance
  ) {
    Workflow_Instance__c freshInstance = [
      SELECT
        Id,
        Status__c,
        Progress__c,
        Current_Step__c,
        Compensation_Stack__c,
        Sleep_Until__c,
        Async_Job_Id__c,
        Failure_Category__c,
        Error_Message__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Input__c,
        Definition_Version__c,
        Previous_Run_At__c,
        CreatedDate
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (
      freshInstance.Status__c == 'Failed' ||
      freshInstance.Status__c == 'CompensationFailed' ||
      freshInstance.Status__c == 'Cancelled'
    ) {
      throw new WorkflowException(
        'Workflow execution was terminated or cancelled.'
      );
    }
    return freshInstance;
  }

  private static void persistCompensationProgressAndCaptures(
    StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepContext context = outcome.context;
    if (context != null && context.progress().isProgressReported()) {
      String progJson = context.progress().getProgressJson();
      instance.Progress__c = WorkflowPayloadOffload.savePayloadIfNeeded(
        instance.Id,
        progJson,
        'Progress_' +
        (stepExec != null && String.isNotBlank(stepExec.Step_Name__c)
          ? stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
          : 'Default')
      );
    }

    // Persist capture-once values produced during this compensation execution.
    if (context.captures().hasNewCaptures()) {
      String capturedJson = context.captures().getCapturedValuesJson();
      stepExec.Captured_Values__c = WorkflowPayloadOffload.savePayloadIfNeeded(
        instance.Id,
        capturedJson,
        'Captures_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
    }
  }

  // Shared recoverable rollback-failure transition used by the RETRY-exhausted,
  // explicit-FAIL, and unsupported-action branches. Captures wasCancelling from
  // the pre-mutation status, then parks the saga in CompensationFailed.
  private static void failCompensationRecoverable(
    Workflow_Instance__c instance,
    String detail
  ) {
    Boolean wasCancelling = (instance.Status__c == 'Cancelling');
    instance.Status__c = 'CompensationFailed';
    instance.Failure_Category__c = CAT_COMPENSATION_FAILED;
    instance.Error_Message__c = buildRollbackIncompleteMessage(
        wasCancelling,
        detail
      )
      .left(255);
    // Clear any stale sleep/retry deadline so a resumed gate is not immediately
    // re-woken by the watchdog (Sleep_Until__c <= now).
    instance.Sleep_Until__c = null;
    instance.Async_Job_Id__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    WorkflowParentNotifier.notifyParentCompletion(instance);
    WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
    WorkflowLifecyclePublisher.publish(instance);
  }

  private static void handleCompensationComplete(
    StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    List<String> stack = outcome.stack;
    StepContext context = outcome.context;
    stepExec.Status__c = 'Compensated';
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      result.directive().outputJson,
      'Output_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    saveStepExec(stepExec);

    // A compensating step that read signals durably completed; consume them on
    // the same contract as a forward step so a later compensation attempt or
    // step does not re-observe them. Compensation runs serially (LIFO) and
    // does not claim, so it consumes still-Received rows plus same-name cleanup.
    markSignalsConsumed(instance.Id, context, false);

    // Effectively-once outbound emit from compensation (issue #64): a
    // CompensatableStep.compensate() that calls ctx.events().emit() or the
    // complete(..., events) overload publishes here, coupled to the durable
    // Compensated transition — the same commit-coupling as the forward path,
    // so the public emit API does not silently drop events in rollback flows.
    WorkflowStepOutcome.publishOutboundEvents(result, context);

    stack.remove(stack.size() - 1);
    instance.Compensation_Stack__c = JSON.serialize(stack);

    if (stack.isEmpty()) {
      instance.Status__c = (instance.Status__c == 'Cancelling')
        ? 'Cancelled'
        : 'Compensated';
      instance.Current_Step__c = null;
    }
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    if (stack.isEmpty()) {
      WorkflowParentNotifier.notifyParentCompletion(instance);
    } else {
      WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
    }

    enqueueOrchestratorForInstance(instance.Id);

    // Fire-and-forget outbound lifecycle event; only fires once the stack is
    // drained and the instance has reached Compensated/Cancelled. Runs LAST so
    // the load-bearing orchestrator enqueue above keeps first claim on DML budget.
    WorkflowLifecyclePublisher.publish(instance);
  }

  private static void handleCompensationYield(
    StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    stepExec.Status__c = 'Running';
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      result.directive().stepStateJson,
      'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    saveStepExec(stepExec);

    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
    WorkflowOrchestratorEnqueue.enqueueOrchestrator(instance.Id, null);
  }

  private static void handleCompensationSuspend(
    StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    // Note: timed-wait timeout is not supported in compensation steps and is not armed here.
    stepExec.Status__c = 'Pending';
    stepExec.Output__c = String.isNotBlank(result.directive().stepStateJson)
      ? WorkflowPayloadOffload.savePayloadIfNeeded(
          instance.Id,
          result.directive().stepStateJson,
          'State_Suspend_' +
          stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
        )
      : null;
    saveStepExec(stepExec);
    instance.Status__c = 'Suspended';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
  }

  private static void handleCompensationSleep(
    StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    stepExec.Status__c = 'Pending';
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      result.directive().stepStateJson,
      'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    saveStepExec(stepExec);
    instance.Status__c = 'Suspended';
    if (result.directive().sleepDurationSeconds != null) {
      instance.Sleep_Until__c = DateTime.now()
        .addSeconds(result.directive().sleepDurationSeconds);
      instance.Async_Job_Id__c = WorkflowRetrySleepScheduler.scheduleSleepResume(
        instance.Id,
        stepExec.Step_Name__c,
        result.directive().sleepDurationSeconds
      );
    }
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
  }

  private static void handleCompensationWaitForApproval(
    StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    // Note: timed-wait timeout is not supported in compensation steps and is not armed here.
    stepExec.Status__c = 'Pending';
    Map<String, Object> state = new Map<String, Object>{
      'waitingForApproval' => true,
      'approvalKey' => result.directive().approvalKey,
      'approvalRole' => result.directive().approvalRole
    };
    stepExec.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      JSON.serialize(state),
      'State_Approval_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    saveStepExec(stepExec);
    instance.Status__c = 'Suspended';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
  }

  private static void handleCompensationRetry(
    StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    stepExec.Retry_Count__c += 1;
    // Get and sanitize retry policy
    RetryPolicy policy = sanitizePolicy(result.directive().retry.policy);

    persistRetryMaxAttempts(instance, stepExec, policy);

    if (stepExec.Retry_Count__c >= policy.maximumAttempts) {
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c =
        'Compensation max retries (' +
        policy.maximumAttempts +
        ') exceeded.';
      saveStepExec(stepExec);

      // The author's RetryPolicy budget for the automatic phase is exhausted, but
      // the remaining stack is intact. Surface a recoverable "rollback incomplete"
      // state (resumable by an operator) instead of abandoning the deeper steps.
      failCompensationRecoverable(
        instance,
        'Rollback incomplete: compensation step ' +
          stepExec.Step_Name__c +
          ' failed after max retries.'
      );
    } else {
      scheduleExponentialRetry(instance, stepExec, policy);
    }
  }

  private static void handleCompensationFail(
    StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    // A compensation step returned an explicit fail() — treat it as a deliberate
    // compensation crash: park the saga in the recoverable CompensationFailed state
    // with the author's reason, preserving the remaining LIFO stack for operator
    // resume. Same format as the RETRY-exhausted and thrown-exception paths.
    stepExec.Status__c = 'Failed';
    stepExec.Error_Details__c = (result.directive().failureDataJson != null)
      ? result.directive().failureReason +
        '\nfailureData: ' +
        result.directive().failureDataJson
      : result.directive().failureReason;
    saveStepExec(stepExec);

    failCompensationRecoverable(
      instance,
      'Rollback incomplete: compensation step ' +
        stepExec.Step_Name__c +
        ' failed: ' +
        result.directive().failureReason
    );
  }

  private static void handleCompensationUnsupported(
    StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    stepExec.Status__c = 'Failed';
    stepExec.Error_Details__c =
      'Unsupported compensation action: ' +
      (result != null ? result.directive().action : null);
    saveStepExec(stepExec);

    // Remaining stack is intact; leave the saga recoverable rather than abandoning it.
    failCompensationRecoverable(
      instance,
      'Rollback incomplete: compensation step ' +
        stepExec.Step_Name__c +
        ' failed: Unsupported action.'
    );
  }

  /**
   * @description Pre-creates the first pending compensation step for an instance
   * entering compensation, so the orchestrator has a concrete step to drive. Public
   * so the extracted `WorkflowFailureService` can open compensation through the same
   * resident helper. No-op when the compensation stack is empty.
   * @param instance the instance beginning compensation
   */
  public static void preCreateFirstCompensationStep(
    Workflow_Instance__c instance
  ) {
    if (String.isBlank(instance.Compensation_Stack__c)) {
      return;
    }
    List<String> stack = (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
    if (stack.isEmpty()) {
      return;
    }
    String activeStepName = stack[stack.size() - 1];
    String compensationStepLogName = activeStepName + '_Compensate';

    // Check if it already exists to avoid duplicates
    List<Workflow_Step_Execution__c> existing = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :compensationStepLogName
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!existing.isEmpty()) {
      return;
    }

    // Determine the source of the forward executions (original completed run or this run)
    Id forwardSourceInstanceId = resolveForwardSourceInstanceId(instance);

    List<Workflow_Step_Execution__c> originalExecs = [
      SELECT Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :forwardSourceInstanceId
        AND Step_Name__c = :activeStepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];

    Workflow_Step_Execution__c compStepExec = new Workflow_Step_Execution__c();
    compStepExec.Workflow_Instance__c = instance.Id;
    compStepExec.Step_Name__c = compensationStepLogName;
    compStepExec.Status__c = 'Pending';
    compStepExec.Input__c = !originalExecs.isEmpty()
      ? originalExecs[0].Input__c
      : null;
    compStepExec.Output__c = !originalExecs.isEmpty()
      ? originalExecs[0].Output__c
      : null;
    compStepExec.Retry_Count__c = 0;
    Database.insert(compStepExec, true, AccessLevel.SYSTEM_MODE);
  }

  /**
   * Manually triggers compensation for a completed workflow instance.
   * Validates status, copies the compensation stack, spawns a new compensating instance,
   * links it to the original instance, and runs the rollback.
   * @param instanceId Id of the completed instance to compensate
   * @return Id of the new compensating instance
   */
  public static Id compensate(Id instanceId) {
    if (instanceId == null) {
      throw new WorkflowException('Instance ID cannot be null.');
    }

    Workflow_Instance__c target = loadCompensationTarget(instanceId);

    // Spawn successor compensating instance. Carry the root correlation key forward.
    Workflow_Instance__c compensatingInstance = buildCompensatingInstance(
      target
    );
    Database.insert(compensatingInstance, true, AccessLevel.SYSTEM_MODE);

    // Link original instance to new compensating instance
    target.Compensated_By__c = compensatingInstance.Id;
    Database.update(target, true, AccessLevel.SYSTEM_MODE);

    // Pre-create the first compensation step execution log
    preCreateFirstCompensationStep(compensatingInstance);

    // Schedule watchdog and enqueue orchestrator
    enqueueCompensatingOrchestrator(compensatingInstance.Id);

    return compensatingInstance.Id;
  }

  /**
   * Loads and validates the target instance for compensation, locking it FOR
   * UPDATE. Throws when it is missing, not Completed, or has no compensation stack.
   * @param instanceId the instance to compensate
   * @return the locked, validated target instance
   */
  private static Workflow_Instance__c loadCompensationTarget(Id instanceId) {
    List<Workflow_Instance__c> targetInstances = [
      SELECT
        Id,
        Status__c,
        Compensation_Stack__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Definition_Version__c,
        Previous_Run_At__c,
        Input__c,
        Parent_Instance__c,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      FOR UPDATE
    ];

    if (targetInstances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instanceId);
    }

    Workflow_Instance__c target = targetInstances[0];

    if (target.Status__c != 'Completed') {
      throw new WorkflowException(
        'Only Completed workflow instances can be compensated. Current status: ' +
        target.Status__c
      );
    }

    if (String.isBlank(target.Compensation_Stack__c)) {
      throw new WorkflowException(
        'No compensation stack found on instance: ' + instanceId
      );
    }

    List<String> stack = (List<String>) JSON.deserialize(
      target.Compensation_Stack__c,
      List<String>.class
    );
    if (stack.isEmpty()) {
      throw new WorkflowException(
        'Compensation stack is empty for instance: ' + instanceId
      );
    }
    return target;
  }

  /**
   * Builds the successor compensating instance, carrying the root correlation key
   * and causation lineage forward from the completed target.
   * @param target the completed instance being compensated
   * @return the unsaved compensating instance
   */
  private static Workflow_Instance__c buildCompensatingInstance(
    Workflow_Instance__c target
  ) {
    return new Workflow_Instance__c(
      Workflow_Name__c = target.Workflow_Name__c,
      Correlation_Key__c = target.Correlation_Key__c,
      Root_Correlation_Key__c = String.isNotBlank(
          target.Root_Correlation_Key__c
        )
        ? target.Root_Correlation_Key__c
        : target.Correlation_Key__c,
      Previous_Instance__c = target.Id,
      Definition_Version__c = target.Definition_Version__c,
      Status__c = 'Compensating',
      Compensation_Stack__c = target.Compensation_Stack__c,
      Input__c = target.Input__c,
      Causation_Id__c = String.isNotBlank(target.Causation_Id__c)
        ? target.Causation_Id__c
        : target.Parent_Instance__c
    );
  }

  /**
   * Schedules the watchdog and enqueues the orchestrator for a compensating
   * instance, dispatching directly under test and via event otherwise.
   * @param compensatingInstanceId the compensating instance to drive
   */
  private static void enqueueCompensatingOrchestrator(
    Id compensatingInstanceId
  ) {
    WorkflowTimeoutArming.scheduleTimeoutJobForInstance(compensatingInstanceId);
    if (!Test.isRunningTest()) {
      WorkflowOrchestratorEnqueue.enqueueOrchestrator(
        compensatingInstanceId,
        null
      );
      return;
    }
    if (!disableQueueableInTest) {
      System.enqueueJob(new WorkflowOrchestrator(compensatingInstanceId));
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

  // Removes a reserved $-key from a JSON-object string, returning the cleaned
  // JSON (null when the map is empty after removal). Returns the original string
  // for blank/missing-key input, non-object JSON, and parse failures.
  private static String stripJsonMapKey(String jsonText, String key) {
    if (String.isBlank(jsonText) || !jsonText.contains(key)) {
      return jsonText;
    }
    try {
      Object parsed = JSON.deserializeUntyped(jsonText);
      if (!(parsed instanceof Map<String, Object>)) {
        return jsonText;
      }
      Map<String, Object> m = (Map<String, Object>) parsed;
      m.remove(key);
      return m.isEmpty() ? null : JSON.serialize(m);
    } catch (Exception e) {
      return jsonText;
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
   * Parks an instance that could not acquire a concurrency slot. It suspends with a
   * short admission-retry wake time and re-enters admission through the SAME sleep/
   * watchdog resume path used by SLEEP — no busy spin, no dropped Queueable chain. The
   * current Pending step's watchdog deadline is cleared so a parked (not-yet-executed)
   * step is never failed by the timeout sweep; admission re-arms it.
   * @param instance the instance that failed to acquire a concurrency slot
   * @param resolvedStep name of the current Pending step being parked
   */
  private static void parkForConcurrency(
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
   * Persists unmatched (unrouted) signal requests as Workflow_Signal__c rows
   * with Status='Unrouted'. Keyed rows are inserted first-wins (allOrNone=false,
   * swallowing per-row DUPLICATE_VALUE) so a duplicate capture is a no-op against
   * the already-captured row rather than overwriting it; keyless rows are
   * plain-inserted. Never touches Workflow_Step_Execution__c.
   *
   * Dedup key selection for a pre-arrival/unrouted signal (no instance yet):
   *  - a caller-supplied idempotency key wins, scoped to the correlation key
   *    (deriveUnroutedDedupKey) so N publishes of the same logical event while
   *    no instance is active collapse to a single Unrouted row and redeliver
   *    once; distinct correlation keys stay separate. The raw key is retained on
   *    Idempotency_Key__c so redeliverCapturedSignal can rewrite the dedup key to
   *    the instance-scoped routed hash once an instance becomes active.
   *  - otherwise the platform-event EventUuid (req.dedupKey) is used, which
   *    only collapses replays of the *same* publish.
   * @param unmatched the signal requests whose target instance does not exist yet
   */
  @TestVisible
  private static void captureUnroutedSignals(List<SignalRequest> unmatched) {
    if (unmatched == null || unmatched.isEmpty()) {
      return;
    }

    Map<String, Workflow_Signal__c> keyedRows = new Map<String, Workflow_Signal__c>();
    List<Workflow_Signal__c> unkeyedRows = new List<Workflow_Signal__c>();
    buildUnroutedSignalRows(unmatched, keyedRows, unkeyedRows);

    // A savepoint restores all-or-none semantics: the keyed insert uses
    // allOrNone=false so a concurrent-duplicate loser is swallowed as a no-op,
    // but a genuine (non-duplicate) row error — or a failure of the unkeyed
    // insert below — must roll back the already-captured rows before the method
    // throws. Otherwise a caller that catches the exception and retries the same
    // batch would treat the committed captures as duplicates while the rest of
    // the request never ran.
    if (keyedRows.isEmpty() && unkeyedRows.isEmpty()) {
      return;
    }
    Savepoint sp = Database.setSavepoint();

    if (!keyedRows.isEmpty()) {
      insertKeyedUnroutedSignals(keyedRows.values(), sp);
    }
    if (!unkeyedRows.isEmpty()) {
      try {
        Database.insert(unkeyedRows, true, AccessLevel.SYSTEM_MODE);
      } catch (Exception e) {
        Database.rollback(sp);
        throw e;
      }
    }
  }

  // Build the Unrouted signal rows, splitting them into dedup-keyed rows (kept
  // first-wins in a map) and unkeyed rows (a plain list). Mutates the two
  // supplied collections in place.
  private static void buildUnroutedSignalRows(
    List<SignalRequest> unmatched,
    Map<String, Workflow_Signal__c> keyedRows,
    List<Workflow_Signal__c> unkeyedRows
  ) {
    for (SignalRequest req : unmatched) {
      Workflow_Signal__c sig = new Workflow_Signal__c(
        Correlation_Key__c = req.keyOrId,
        Signal_Name__c = req.signalName,
        Payload__c = req.payload,
        Status__c = 'Unrouted'
      );
      String dedupVal;
      if (String.isNotBlank(req.idempotencyKey)) {
        // Retain the raw caller key so redeliverCapturedSignal can rewrite the
        // correlation-scoped capture key to the instance-scoped routed key once
        // a matching instance becomes active (closes the pre-arrival boundary).
        //
        // Known limitation (issue #48, "Out of Scope: retroactive dedup of
        // already-persisted signals"): if a keyed signal was already routed to an
        // instance that has since gone terminal, an at-least-once redelivery finds
        // no active match and is captured here under a correlation-scoped C: key.
        // That cannot collide with the original I:<instanceId> routed row, so the
        // duplicate persists as Unrouted and could be redelivered to a later
        // successor instance sharing the correlation key. Retiring such
        // post-terminal duplicates would require a dedup-window lookup of the
        // terminal instance plus a routed-row existence check on every keyed
        // capture; that retroactive dedup is intentionally deferred.
        sig.Idempotency_Key__c = req.idempotencyKey;
        dedupVal = deriveUnroutedDedupKey(req.keyOrId, req.idempotencyKey);
      } else {
        dedupVal = req.dedupKey;
      }
      if (String.isNotBlank(dedupVal)) {
        sig.Signal_Key__c = dedupVal;
        if (!keyedRows.containsKey(dedupVal)) {
          keyedRows.put(dedupVal, sig);
        }
      } else {
        unkeyedRows.add(sig);
      }
    }
  }

  // First-wins: insert (allOrNone=false) and swallow per-row DUPLICATE_VALUE so
  // a duplicate capture (same key, possibly different payload/name) is a no-op
  // against the already-captured row — matching the routed keyed path — rather
  // than overwriting it the way an upsert would. A genuine error rolls back to
  // the savepoint and surfaces.
  private static void insertKeyedUnroutedSignals(
    List<Workflow_Signal__c> keyedRows,
    Savepoint sp
  ) {
    Database.SaveResult[] srs = Database.insert(
      keyedRows,
      false,
      AccessLevel.SYSTEM_MODE
    );
    String genuineError = findGenuineSaveError(srs);
    if (genuineError != null) {
      Database.rollback(sp);
      throw new WorkflowException(
        'Failed to capture unrouted signal: ' + genuineError
      );
    }
  }

  // Return the first non-DUPLICATE_VALUE row-error message across the save
  // results, or null when every failure was a swallowed duplicate.
  private static String findGenuineSaveError(Database.SaveResult[] srs) {
    for (Database.SaveResult sr : srs) {
      if (sr.isSuccess()) {
        continue;
      }
      Boolean isDup = false;
      for (Database.Error err : sr.getErrors()) {
        if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
          isDup = true;
          break;
        }
      }
      if (!isDup) {
        return sr.getErrors()[0].getMessage();
      }
    }
    return null;
  }

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
      sig.Signal_Key__c = deriveSignalDedupKey(
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
          sig.Signal_Key__c = deriveSignalDedupKey(
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
