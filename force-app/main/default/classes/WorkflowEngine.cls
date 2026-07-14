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
  private static Map<String, Boolean> validatedWorkflows = new Map<String, Boolean>();

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
  @TestVisible
  private static Integer predecessorQueriesRemaining = 15;

  // Base + jitter (seconds) before a concurrency-parked instance re-attempts
  // admission. Precise scheduling drives it promptly when slots free; under a large
  // burst the scheduling degrades to the watchdog batch-resume (the scalable path).
  @TestVisible
  private static Integer concurrencyAdmissionRetrySeconds = 30;
  private static final Integer CONCURRENCY_ADMISSION_RETRY_JITTER_SECONDS = 15;

  // Bounds for re-driving a step after a TRANSIENT row-lock error (UNABLE_TO_LOCK_ROW)
  // — e.g. a fan-in where many child-completion signals lock the shared parent row at
  // once. These are CONSECUTIVE retries (reset on the next successful drive), so the
  // cap need only outlast a contention burst, not the whole fan-in.
  @TestVisible
  private static Integer maxTransientLockRetries = 12;
  private static final Integer TRANSIENT_LOCK_BASE_DELAY_SECONDS = 5;
  private static final Integer TRANSIENT_LOCK_MAX_DELAY_SECONDS = 60;
  private static final Integer TRANSIENT_LOCK_JITTER_SECONDS = 5;

  // Instances in these statuses are considered in-flight; a start that collides
  // with one of them always dedups to the existing instance.
  private static final Set<String> ACTIVE_STATUSES = new Set<String>{
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

  // Upper bound (~100 years) applied to the dedup window before it is subtracted
  // from "now", so a large/misconfigured Dedup_Window_Minutes__c cannot push the
  // computed lower bound outside Salesforce's valid DateTime range and fault
  // every start.
  private static final Integer MAX_DEDUP_WINDOW_MINUTES = 52560000;

  // Upper bound on rows read by a single dedup lookup, so a hot correlation key
  // with many historical terminal runs cannot exhaust the SOQL row governor.
  // Single-key lookups (the common start path) read only the top row.
  // @TestVisible (non-final) so tests can shrink it to exercise the cap cheaply.
  @TestVisible
  private static Integer dedupLookupRowCap = 10000;

  // Search Attributes configuration limits
  public static final Integer MAX_ATTRIBUTES_PER_INSTANCE = 10;
  public static final Integer MAX_ATTRIBUTE_KEY_LENGTH = 100;
  public static final Integer MAX_ATTRIBUTE_VALUE_LENGTH = 150;

  // Max number of timed-out steps a single watchdog heartbeat will fail. Each failure
  // triggers failWorkflowInstance() (its own SOQL/DML + optional alert queries), so this
  // bounds the heartbeat's governor usage. Remaining timeouts drain on the next heartbeat.
  @TestVisible
  private static Integer watchdogTimeoutBatchSize = 50;
  // Max number of sleeping instances a single heartbeat resumes, for the same reason.
  @TestVisible
  private static Integer watchdogResumeBatchSize = 200;
  // Max number of expired instances a single heartbeat fails/compensates, for the same reason.
  @TestVisible
  private static Integer watchdogDeadlineBatchSize = 100;

  @TestVisible
  private static Set<Id> enqueuedInstanceIds = new Set<Id>();
  // Per-(instance, branch) enqueue dedup so resuming a parallel instance can
  // wake each branch by name without the instance-level dedup blocking siblings.
  @TestVisible
  private static Set<String> enqueuedBranchKeys = new Set<String>();

  @TestVisible
  private static Map<String, FaultConfig> injectedFaults = new Map<String, FaultConfig>();

  @TestVisible
  private static Map<Id, Id> childToParentMap = new Map<Id, Id>();

  // Terminal statuses for the read API. ContinuedAsNew is deliberately excluded
  // (it is a hand-off, not an outcome) and CompensationFailed is excluded
  // (it is non-terminal — the rollback can still be resumed/retried).
  private static final Set<String> TERMINAL_GETSTATUS_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled'
  };

  // Caps how many signals a serial step may observe in one execution. Serial
  // steps never claim (no read-side DML), so the only DML is the COMPLETE
  // consume; 8 000 keeps the consume update (matched ids + same-name duplicate
  // cleanup) safely under the 10 000 DML-row limit while never exposing more
  // rows than completion can consume. Excess rows stay Received for a later read.
  // @TestVisible (non-final) so a test can shrink the cap to exercise budget
  // exhaustion without inserting thousands of rows.
  @TestVisible
  private static Integer serialSignalRowCap = 8000;

  @TestVisible
  private static Integer breadcrumbDmlStatementReserve = 10;
  @TestVisible
  private static Integer breadcrumbDmlRowReserve = 20;
  @TestVisible
  private static Integer breadcrumbSoqlReserve = 5;

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

  @TestVisible
  private static Integer adoptionQueryLimit = 45000;
  @TestVisible
  private static List<Workflow_Instance__c> mockInstancesForAdoption;

  private static Map<String, Integer> stepTimeoutCache = new Map<String, Integer>();

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

  @TestVisible
  private class FaultConfig {
    public String message;
    public Integer remainingFailures;
    /**
     * @description Builds a fault-injection entry for a keyed step.
     * @param message failure message thrown when the fault fires
     * @param remainingFailures number of times the fault should still fire, or
     * null to fail on every execution
     */
    public FaultConfig(String message, Integer remainingFailures) {
      this.message = message;
      this.remainingFailures = remainingFailures;
    }
  }

  private static void registerChildParent(Id childId, Id parentId) {
    if (childId != null && parentId != null) {
      childToParentMap.put(childId, parentId);
    }
  }

  private static Id getRootInstanceId(Id instanceId) {
    if (instanceId == null) {
      return null;
    }
    Id currentId = instanceId;
    for (Integer i = 0; i < 10; i++) {
      if (childToParentMap.containsKey(currentId)) {
        currentId = childToParentMap.get(currentId);
      } else {
        // Fallback: Query parent from DB to resolve root across hops/transactions
        List<Workflow_Instance__c> insts = [
          SELECT Parent_Instance__c
          FROM Workflow_Instance__c
          WHERE Id = :currentId
          WITH SYSTEM_MODE
          LIMIT 1
        ];
        if (!insts.isEmpty() && insts[0].Parent_Instance__c != null) {
          Id parentId = insts[0].Parent_Instance__c;
          childToParentMap.put(currentId, parentId);
          currentId = parentId;
        } else {
          break;
        }
      }
    }
    return currentId;
  }

  /**
   * Consumes one injected-fault occurrence for the key and reports whether this
   * invocation should fail. A null remainingFailures fails every time; a
   * positive count is decremented (and the fault removed when it reaches zero);
   * a zero/negative count does not fail.
   * @param config the fault configuration (mutated when it has a finite count)
   * @param key the injected-fault map key, removed when the count is exhausted
   * @return true when this invocation should inject the fault
   */
  private static Boolean consumeFaultShouldFail(
    FaultConfig config,
    String key
  ) {
    if (config.remainingFailures == null) {
      return true;
    }
    if (config.remainingFailures > 0) {
      config.remainingFailures--;
      if (config.remainingFailures == 0) {
        injectedFaults.remove(key);
      }
      return true;
    }
    return false;
  }

  /**
   * Builds the injected-fault outcome: a retry when the step is RetryConfigurable
   * with a policy, otherwise a thrown WorkflowException carrying the fault
   * message.
   * @param stepInstance the step being executed
   * @param config the fault configuration supplying the failure message
   * @return a retry StepResult when a retry policy applies
   */
  private static StepResult faultResult(
    WorkflowStep stepInstance,
    FaultConfig config
  ) {
    if (stepInstance instanceof RetryConfigurable) {
      RetryPolicy policy = ((RetryConfigurable) stepInstance).getRetryPolicy();
      if (policy != null) {
        return StepResult.retry(policy);
      }
    }
    throw new WorkflowException(config.message);
  }

  private static StepResult checkAndInjectFault(
    Id instanceId,
    String stepName,
    WorkflowStep stepInstance
  ) {
    if (
      !(Test.isRunningTest() &&
      injectedFaults != null &&
      !injectedFaults.isEmpty() &&
      String.isNotBlank(stepName))
    ) {
      return null;
    }
    Id rootId = getRootInstanceId(instanceId);
    String key =
      (rootId != null ? String.valueOf(rootId) : '') +
      ':' +
      stepName.toLowerCase();
    FaultConfig config = injectedFaults.get(key);
    if (config == null) {
      return null;
    }
    if (!consumeFaultShouldFail(config, key)) {
      return null;
    }
    return faultResult(stepInstance, config);
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
   * Stable read-only DTO returned by WorkflowEngine.getStatus. All fields are
   * read-only to callers; the engine populates them via the private constructor.
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

    private WorkflowStatus() {
      this.isTerminal = false;
    }
  }

  /**
   * Returns the current status and rehydrated output for a workflow instance by Id,
   * or null if no instance with that Id exists.
   * Costs at most 2 SOQL queries and zero DML.
   * @param instanceId Id of the workflow instance to read
   * @return the instance status DTO, or null when no such instance exists
   */
  public static WorkflowStatus getStatus(Id instanceId) {
    List<WorkflowStatus> results = getStatus(new List<Id>{ instanceId });
    return results[0];
  }

  /**
   * Returns the current status and rehydrated output for a workflow instance by
   * correlation key (prefers a live/active run, and follows a continue-as-new chain
   * via its shared root key), or null if no matching instance exists. Blank/null key
   * returns null. Costs a small constant number of SOQL queries and zero DML.
   * @param correlationKey correlation key to resolve
   * @return the status DTO for the resolved instance, or null when none matches
   */
  public static WorkflowStatus getStatus(String correlationKey) {
    List<WorkflowStatus> results = getStatus(
      new List<String>{ correlationKey }
    );
    return results[0];
  }

  /**
   * Bulk variant — accepts a list of instance Ids and returns a correspondingly
   * ordered list of WorkflowStatus DTOs (null where an Id was not found).
   * Costs at most 2 SOQL queries total regardless of list size, and zero DML.
   * @param instanceIds instance Ids to read
   * @return status DTOs positionally aligned with instanceIds (null per missing Id)
   */
  public static List<WorkflowStatus> getStatus(List<Id> instanceIds) {
    List<WorkflowStatus> out = new List<WorkflowStatus>();
    if (instanceIds == null || instanceIds.isEmpty()) {
      return out;
    }

    Set<Id> lookupIds = new Set<Id>(instanceIds);
    Map<Id, Workflow_Instance__c> instById = new Map<Id, Workflow_Instance__c>();
    for (Workflow_Instance__c inst : [
      SELECT
        Id,
        Workflow_Name__c,
        Correlation_Key__c,
        Status__c,
        Error_Message__c,
        Output__c,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id IN :lookupIds
      WITH SYSTEM_MODE
    ]) {
      instById.put(inst.Id, inst);
    }

    // Bulk-resolve all offloaded outputs in a single ContentVersion query.
    Map<Id, String> resolvedOutputByDocId = bulkResolveOffloadedOutputs(
      instById.values()
    );

    for (Id reqId : instanceIds) {
      Workflow_Instance__c inst = instById.get(reqId);
      out.add(inst == null ? null : buildStatus(inst, resolvedOutputByDocId));
    }
    return out;
  }

  /**
   * Normalizes the non-blank correlation keys for consistent in-memory bucketing.
   * Correlation key fields are case-insensitive in SOQL but Apex Set/Map lookups
   * are case-sensitive, so all bucketing is done on the normalized (lower-cased)
   * key to keep in-memory matching consistent with what the query returns.
   * @param correlationKeys the requested correlation keys
   * @return the set of normalized non-blank keys
   */
  private static Set<String> normalizeStatusKeys(List<String> correlationKeys) {
    Set<String> normalizedKeys = new Set<String>();
    for (String k : correlationKeys) {
      if (String.isNotBlank(k)) {
        normalizedKeys.add(normalizeKey(k));
      }
    }
    return normalizedKeys;
  }

  /**
   * Fetches the winner instances' DTO fields (including Output__c) by id.
   * @param winnerIds the resolved winning instance ids
   * @return a map of instance id to its loaded record (empty when no winners)
   */
  private static Map<Id, Workflow_Instance__c> queryWinnerInstances(
    Set<Id> winnerIds
  ) {
    Map<Id, Workflow_Instance__c> instById = new Map<Id, Workflow_Instance__c>();
    if (winnerIds.isEmpty()) {
      return instById;
    }
    for (Workflow_Instance__c inst : [
      SELECT
        Id,
        Workflow_Name__c,
        Correlation_Key__c,
        Status__c,
        Error_Message__c,
        Output__c,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id IN :winnerIds
      WITH SYSTEM_MODE
    ]) {
      instById.put(inst.Id, inst);
    }
    return instById;
  }

  /**
   * Bulk variant — accepts a list of correlation keys and returns a correspondingly
   * ordered list of WorkflowStatus DTOs (null where no instance was found or the
   * key entry is blank). A live/active run is preferred over a terminal one when a
   * key maps to several rows; a ContinuedAsNew hand-off always loses to a real
   * generation of its chain. Lookup follows a continue-as-new chain via the shared
   * Root_Correlation_Key__c, so polling the original key — or any intermediate
   * successor key — resolves to the live/final generation.
   *
   * Winners are resolved from metadata only (Output__c is fetched solely for the
   * winners), per key (no single hot key can crowd out others or exhaust the heap).
   * Costs a small constant number of SOQL queries regardless of list size, and zero
   * DML. (The Id-based overloads remain bounded at <= 2 SOQL.)
   * @param correlationKeys correlation keys to resolve
   * @return status DTOs positionally aligned with correlationKeys (null per blank
   * or unmatched key)
   */
  public static List<WorkflowStatus> getStatus(List<String> correlationKeys) {
    List<WorkflowStatus> out = new List<WorkflowStatus>();
    if (correlationKeys == null || correlationKeys.isEmpty()) {
      return out;
    }

    Set<String> normalizedKeys = normalizeStatusKeys(correlationKeys);

    // Resolve the winning instance Id per requested key using metadata only (no
    // Output__c), so a hot key's many candidate rows can never load enough inline
    // payloads to exhaust the heap. Resolution is per-key bounded (no single key can
    // crowd out others) and follows ContinuedAsNew chains via the shared root key.
    Map<String, Id> winnerIdByKey = resolveWinnerIdByKey(normalizedKeys);

    // Fetch Output__c (and the remaining DTO fields) only for the winners, then
    // rehydrate any offloaded outputs in one ContentVersion query — the same bounded
    // tail used by the Id-based overload.
    Map<Id, Workflow_Instance__c> instById = queryWinnerInstances(
      new Set<Id>(winnerIdByKey.values())
    );

    Map<Id, String> resolvedOutputByDocId = bulkResolveOffloadedOutputs(
      instById.values()
    );

    for (String k : correlationKeys) {
      if (String.isBlank(k)) {
        out.add(null);
        continue;
      }
      Id winnerId = winnerIdByKey.get(normalizeKey(k));
      Workflow_Instance__c inst = winnerId == null
        ? null
        : instById.get(winnerId);
      out.add(inst == null ? null : buildStatus(inst, resolvedOutputByDocId));
    }
    return out;
  }

  // Returns true if candidate should replace existing for the same correlation key.
  // A ContinuedAsNew row is a superseded hand-off, so any non-hand-off generation of
  // the chain wins over it (independent of timestamps); otherwise an active run beats
  // a terminal one, and among equals the more recently created wins.
  private static Boolean isPreferredForGetStatus(
    Workflow_Instance__c candidate,
    Workflow_Instance__c existing
  ) {
    Boolean candidateHandoff = candidate.Status__c == 'ContinuedAsNew';
    Boolean existingHandoff = existing.Status__c == 'ContinuedAsNew';
    if (candidateHandoff != existingHandoff) {
      return !candidateHandoff;
    }
    Boolean candidateActive = ACTIVE_STATUSES.contains(candidate.Status__c);
    Boolean existingActive = ACTIVE_STATUSES.contains(existing.Status__c);
    if (candidateActive != existingActive) {
      return candidateActive;
    }
    return candidate.CreatedDate > existing.CreatedDate;
  }

  /**
   * Resolves the single winning Workflow_Instance__c Id for each requested
   * (normalized) correlation key, keyed by that normalized key. Loads only metadata
   * (never Output__c). Follows ContinuedAsNew chains via the shared
   * Root_Correlation_Key__c — which a before-insert trigger defaults to the
   * instance's own correlation key, so every row carries its chain root — letting a
   * lookup by the original key, or any intermediate successor key, resolve to the
   * live/final generation. Bounded per key so no single hot key (a correlation key
   * reused across many terminal runs) can crowd out other requested keys or exceed
   * the SOQL row governor.
   * @param normalizedKeys normalized (lower-cased) correlation keys to resolve
   * @return map of normalized key to the winning instance Id (keys with no match
   * are absent)
   */
  private static Map<String, Id> resolveWinnerIdByKey(
    Set<String> normalizedKeys
  ) {
    if (normalizedKeys == null || normalizedKeys.isEmpty()) {
      return new Map<String, Id>();
    }
    return normalizedKeys.size() == 1
      ? resolveSingleKeyWinner(new List<String>(normalizedKeys)[0])
      : resolveBulkKeyWinners(normalizedKeys);
  }

  /**
   * Fast path for a single requested key. One metadata query picks the winner; a
   * second runs only when that winner is a ContinuedAsNew hand-off reached via a
   * non-root key (i.e. the requested key is an intermediate generation), in which
   * case the live/final successor lives under the shared root key.
   * @param key the single normalized correlation key to resolve
   * @return a one-entry map of the key to its winning instance Id, or empty when
   * no instance matches
   */
  private static Map<String, Id> resolveSingleKeyWinner(String key) {
    Map<String, Id> winnerByKey = new Map<String, Id>();
    Set<String> single = new Set<String>{ key };
    Workflow_Instance__c winner = pickWinner(
      [
        SELECT
          Id,
          Status__c,
          CreatedDate,
          Active_Correlation_Key__c,
          Correlation_Key__c,
          Root_Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE
          Active_Correlation_Key__c IN :single
          OR Correlation_Key__c IN :single
          OR Root_Correlation_Key__c IN :single
        WITH SYSTEM_MODE
        ORDER BY
          Active_Correlation_Key__c NULLS LAST,
          Terminal_At__c DESC NULLS FIRST,
          CreatedDate DESC
        LIMIT :dedupLookupRowCap
      ]
    );
    if (winner == null) {
      return winnerByKey;
    }

    // Follow the chain forward via its shared root. (Same root-reuse limitation as
    // resolveWinnersByRoot: if the root key was reused for an independent live run,
    // this can resolve to that run — see README.)
    String rootKey = String.isNotBlank(winner.Root_Correlation_Key__c)
      ? normalizeKey(winner.Root_Correlation_Key__c)
      : null;
    if (
      winner.Status__c == 'ContinuedAsNew' &&
      rootKey != null &&
      rootKey != key
    ) {
      Set<String> roots = new Set<String>{ rootKey };
      Workflow_Instance__c chainWinner = pickWinner(
        [
          SELECT
            Id,
            Status__c,
            CreatedDate,
            Active_Correlation_Key__c,
            Correlation_Key__c,
            Root_Correlation_Key__c
          FROM Workflow_Instance__c
          WHERE Root_Correlation_Key__c IN :roots
          WITH SYSTEM_MODE
          ORDER BY
            Active_Correlation_Key__c NULLS LAST,
            Terminal_At__c DESC NULLS FIRST,
            CreatedDate DESC
          LIMIT :dedupLookupRowCap
        ]
      );
      if (chainWinner != null && isPreferredForGetStatus(chainWinner, winner)) {
        winner = chainWinner;
      }
    }

    winnerByKey.put(key, winner.Id);
    return winnerByKey;
  }

  /**
   * Bulk path. Each requested key is resolved by its OWN correlation/active key
   * (never by root), mirroring the start-path findExistingByKey machinery: an active
   * run if any, else the most-recent row by correlation key (an aggregate, so a hot
   * key reused across many terminal runs collapses to one group and cannot crowd out
   * other keys). Matching on the key itself — not on Root_Correlation_Key__c — means
   * a rootless legacy row is still found, and independent runs that merely share a
   * chain root are never conflated. The chain is then followed via the shared root
   * only for keys whose direct winner is a ContinuedAsNew hand-off, exactly as the
   * single-key fast path does, so bulk and single resolution stay consistent.
   * @param keys normalized correlation keys to resolve
   * @return map of each resolved key to its winning instance Id
   */
  private static Map<String, Id> resolveBulkKeyWinners(Set<String> keys) {
    Map<String, Workflow_Instance__c> bestByKey = new Map<String, Workflow_Instance__c>();

    // 1a) Active runs — the unique active-key index bounds this to ~one per key.
    for (Workflow_Instance__c inst : [
      SELECT
        Id,
        Status__c,
        CreatedDate,
        Active_Correlation_Key__c,
        Correlation_Key__c,
        Root_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        (Active_Correlation_Key__c IN :keys
        OR Correlation_Key__c IN :keys)
        AND Status__c IN :ACTIVE_STATUSES
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
    ]) {
      bucketByOwnKey(inst, keys, bestByKey);
    }

    // 1b) Keys with no active run → most-recent row by correlation key.
    resolveRemainingKeyWinners(keys, bestByKey);

    // 2) For keys whose direct winner is a ContinuedAsNew hand-off, follow the
    //    chain to its live/final successor via the shared root key.
    expandContinuedAsNewWinners(bestByKey);

    Map<String, Id> winnerByKey = new Map<String, Id>();
    for (String reqKey : bestByKey.keySet()) {
      winnerByKey.put(reqKey, bestByKey.get(reqKey).Id);
    }
    return winnerByKey;
  }

  /**
   * Resolves winners for keys with no active run (phase 1b): the most-recent row
   * by correlation key of any status (so a ContinuedAsNew hand-off is detected
   * for the chain expansion). An aggregate yields one MAX(CreatedDate) per key
   * (a hot key collapses to one group), then a bounded fetch resolves the Id(s)
   * at those timestamps. Mutates bestByKey in place.
   * @param keys the full requested key set (for own-key bucketing)
   * @param bestByKey the accumulating best-instance-per-key map to extend
   */
  private static void resolveRemainingKeyWinners(
    Set<String> keys,
    Map<String, Workflow_Instance__c> bestByKey
  ) {
    Set<String> remaining = unresolved(keys, bestByKey);
    if (remaining.isEmpty()) {
      return;
    }
    Map<String, Datetime> maxByKey = new Map<String, Datetime>();
    Set<Datetime> maxTimes = new Set<Datetime>();
    for (AggregateResult ar : [
      SELECT Correlation_Key__c ck, MAX(CreatedDate) mc
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :remaining
      WITH SYSTEM_MODE
      GROUP BY Correlation_Key__c
    ]) {
      Datetime mc = (Datetime) ar.get('mc');
      if (mc == null) {
        continue;
      }
      // Guard the put: a case-insensitive GROUP BY can yield separate groups for
      // case variants that normalize to the same key, so keep the latest.
      String nk = normalizeKey((String) ar.get('ck'));
      Datetime existing = maxByKey.get(nk);
      if (existing == null || mc > existing) {
        maxByKey.put(nk, mc);
      }
      maxTimes.add(mc);
    }
    if (maxTimes.isEmpty()) {
      return;
    }
    for (Workflow_Instance__c inst : [
      SELECT
        Id,
        Status__c,
        CreatedDate,
        Active_Correlation_Key__c,
        Correlation_Key__c,
        Root_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :remaining AND CreatedDate IN :maxTimes
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
      LIMIT :dedupLookupRowCap
    ]) {
      if (
        inst.CreatedDate == maxByKey.get(normalizeKey(inst.Correlation_Key__c))
      ) {
        bucketByOwnKey(inst, keys, bestByKey);
      }
    }
  }

  /**
   * Follows ContinuedAsNew hand-offs to their live/final successor (phase 2).
   * For each key whose direct winner is a ContinuedAsNew row, the chain root is
   * resolved (falling back to the predecessor's own key when its root is blank)
   * and, when a preferred successor is found, it replaces the winner. Mutates
   * bestByKey in place.
   * @param bestByKey the best-instance-per-key map to expand
   */
  private static void expandContinuedAsNewWinners(
    Map<String, Workflow_Instance__c> bestByKey
  ) {
    Map<String, String> rootByKey = new Map<String, String>();
    Set<String> expandRoots = new Set<String>();
    for (String reqKey : bestByKey.keySet()) {
      Workflow_Instance__c w = bestByKey.get(reqKey);
      if (w.Status__c == 'ContinuedAsNew') {
        // A continueAsNew successor inherits the predecessor's root, falling back to
        // the predecessor's own correlation key when the predecessor predates the
        // root default (blank root). Mirror that fallback so a rootless legacy
        // hand-off still expands to its successor (here reqKey == predecessor key).
        String root = String.isNotBlank(w.Root_Correlation_Key__c)
          ? normalizeKey(w.Root_Correlation_Key__c)
          : reqKey;
        rootByKey.put(reqKey, root);
        expandRoots.add(root);
      }
    }
    if (expandRoots.isEmpty()) {
      return;
    }
    Map<String, Workflow_Instance__c> winnerByRoot = resolveWinnersByRoot(
      expandRoots
    );
    for (String reqKey : rootByKey.keySet()) {
      Workflow_Instance__c cand = winnerByRoot.get(rootByKey.get(reqKey));
      if (
        cand != null && isPreferredForGetStatus(cand, bestByKey.get(reqKey))
      ) {
        bestByKey.put(reqKey, cand);
      }
    }
  }

  /**
   * Resolves the winning instance per chain root: an active run if any, else the
   * most-recent non-hand-off terminal generation, else the most-recent row of any
   * status. Used to follow a ContinuedAsNew chain forward from a hand-off winner.
   * Per-root bounded so a reused root cannot exhaust the SOQL row governor.
   *
   * Known limitation (by design — see README): the root key is shared by every
   * generation of a chain AND by any independent run that reuses the same
   * correlation key, so following a hand-off by root cannot distinguish the chain's
   * own successor from an unrelated run reusing that key. If a correlation key is
   * reused for a separate run while a continue-as-new chain on that key is still
   * live, polling an intermediate hand-off key may resolve to the reused run.
   * Precisely disambiguating would require walking Previous_Instance__c, which is
   * deliberately out of scope to keep this path's bounded, constant-SOQL guarantee.
   * @param roots normalized chain-root correlation keys to resolve
   * @return map of each root key to its winning instance record
   */
  /**
   * Phase 1: buckets the active run per chain (bounded to ~one per chain by the
   * unique active-key index) into the winner map.
   * @param roots the chain-root keys to resolve
   * @param winnerByRoot the accumulating winner map
   */
  private static void addActiveWinners(
    Set<String> roots,
    Map<String, Workflow_Instance__c> winnerByRoot
  ) {
    for (Workflow_Instance__c inst : [
      SELECT
        Id,
        Status__c,
        CreatedDate,
        Active_Correlation_Key__c,
        Correlation_Key__c,
        Root_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Root_Correlation_Key__c IN :roots AND Status__c IN :ACTIVE_STATUSES
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
    ]) {
      putBestByRoot(
        winnerByRoot,
        normalizeKey(inst.Root_Correlation_Key__c),
        inst
      );
    }
  }

  /**
   * Phase 2: for roots with no active run, buckets the most-recent non-hand-off
   * terminal generation into the winner map.
   * @param remainingRoots roots left unresolved after the active phase
   * @param winnerByRoot the accumulating winner map
   */
  private static void addTerminalGenerationWinners(
    Set<String> remainingRoots,
    Map<String, Workflow_Instance__c> winnerByRoot
  ) {
    if (remainingRoots.isEmpty()) {
      return;
    }
    Map<String, Datetime> maxByRoot = new Map<String, Datetime>();
    Set<Datetime> maxTimes = new Set<Datetime>();
    for (AggregateResult ar : [
      SELECT Root_Correlation_Key__c root, MAX(CreatedDate) mc
      FROM Workflow_Instance__c
      WHERE
        Root_Correlation_Key__c IN :remainingRoots
        AND Status__c IN :TERMINAL_GETSTATUS_STATUSES
      WITH SYSTEM_MODE
      GROUP BY Root_Correlation_Key__c
    ]) {
      Datetime mc = (Datetime) ar.get('mc');
      if (mc == null) {
        continue;
      }
      String nr = normalizeKey((String) ar.get('root'));
      Datetime existing = maxByRoot.get(nr);
      if (existing == null || mc > existing) {
        maxByRoot.put(nr, mc);
      }
      maxTimes.add(mc);
    }
    if (maxTimes.isEmpty()) {
      return;
    }
    for (Workflow_Instance__c inst : [
      SELECT
        Id,
        Status__c,
        CreatedDate,
        Active_Correlation_Key__c,
        Correlation_Key__c,
        Root_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        Root_Correlation_Key__c IN :remainingRoots
        AND Status__c IN :TERMINAL_GETSTATUS_STATUSES
        AND CreatedDate IN :maxTimes
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
      LIMIT :dedupLookupRowCap
    ]) {
      String r = normalizeKey(inst.Root_Correlation_Key__c);
      if (inst.CreatedDate == maxByRoot.get(r)) {
        putBestByRoot(winnerByRoot, r, inst);
      }
    }
  }

  /**
   * Phase 3: fallback for an all-hand-off chain — keeps the most-recent matched
   * row so the caller still sees the latest generation rather than null.
   * @param stuckRoots roots still unresolved after the terminal phase
   * @param winnerByRoot the accumulating winner map
   */
  private static void addHandoffFallbackWinners(
    Set<String> stuckRoots,
    Map<String, Workflow_Instance__c> winnerByRoot
  ) {
    if (stuckRoots.isEmpty()) {
      return;
    }
    for (Workflow_Instance__c inst : [
      SELECT
        Id,
        Status__c,
        CreatedDate,
        Active_Correlation_Key__c,
        Correlation_Key__c,
        Root_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Root_Correlation_Key__c IN :stuckRoots
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
      LIMIT :dedupLookupRowCap
    ]) {
      putBestByRoot(
        winnerByRoot,
        normalizeKey(inst.Root_Correlation_Key__c),
        inst
      );
    }
  }

  private static Map<String, Workflow_Instance__c> resolveWinnersByRoot(
    Set<String> roots
  ) {
    Map<String, Workflow_Instance__c> winnerByRoot = new Map<String, Workflow_Instance__c>();
    addActiveWinners(roots, winnerByRoot);
    addTerminalGenerationWinners(unresolved(roots, winnerByRoot), winnerByRoot);
    addHandoffFallbackWinners(unresolved(roots, winnerByRoot), winnerByRoot);
    return winnerByRoot;
  }

  // Buckets a candidate under each requested key it carries via its own correlation
  // or active key (not its root), keeping the best per key via the getStatus
  // preference. Matching on the instance's own key avoids conflating independent
  // runs that share a chain root and still resolves rootless legacy rows.
  private static void bucketByOwnKey(
    Workflow_Instance__c inst,
    Set<String> keys,
    Map<String, Workflow_Instance__c> bestByKey
  ) {
    Set<String> own = new Set<String>();
    if (String.isNotBlank(inst.Correlation_Key__c)) {
      own.add(normalizeKey(inst.Correlation_Key__c));
    }
    if (String.isNotBlank(inst.Active_Correlation_Key__c)) {
      own.add(normalizeKey(inst.Active_Correlation_Key__c));
    }
    for (String k : own) {
      if (!keys.contains(k)) {
        continue;
      }
      Workflow_Instance__c existing = bestByKey.get(k);
      if (existing == null || isPreferredForGetStatus(inst, existing)) {
        bestByKey.put(k, inst);
      }
    }
  }

  // Picks the single best instance from a candidate list via the getStatus
  // preference (non-hand-off > active > most-recently created).
  private static Workflow_Instance__c pickWinner(
    List<Workflow_Instance__c> candidates
  ) {
    Workflow_Instance__c winner = null;
    for (Workflow_Instance__c inst : candidates) {
      if (winner == null || isPreferredForGetStatus(inst, winner)) {
        winner = inst;
      }
    }
    return winner;
  }

  // Keeps the best candidate per chain root using the getStatus preference.
  private static void putBestByRoot(
    Map<String, Workflow_Instance__c> winnerByRoot,
    String root,
    Workflow_Instance__c inst
  ) {
    if (root == null) {
      return;
    }
    Workflow_Instance__c existing = winnerByRoot.get(root);
    if (existing == null || isPreferredForGetStatus(inst, existing)) {
      winnerByRoot.put(root, inst);
    }
  }

  // Members of allKeys not yet resolved to a winner in the given map.
  private static Set<String> unresolved(
    Set<String> allKeys,
    Map<String, Workflow_Instance__c> resolved
  ) {
    Set<String> remaining = new Set<String>();
    for (String k : allKeys) {
      if (!resolved.containsKey(k)) {
        remaining.add(k);
      }
    }
    return remaining;
  }

  // Builds a WorkflowStatus DTO from a queried instance, using the pre-fetched
  // offloaded-output map so no additional SOQL is issued per row.
  private static WorkflowStatus buildStatus(
    Workflow_Instance__c inst,
    Map<Id, String> resolvedOutputByDocId
  ) {
    Boolean terminal = TERMINAL_GETSTATUS_STATUSES.contains(inst.Status__c);
    String output = null;
    if (terminal) {
      output = rehydrateFromMap(inst.Output__c, resolvedOutputByDocId);
      // A terminal instance has definitively produced its output, so surface an
      // empty result as '' rather than null. (Salesforce coerces an empty text
      // field to null on insert.) This keeps output == null meaning exactly "not
      // terminal yet", so callers can distinguish "completed with no output" from
      // "still running" by output alone, per the documented contract.
      if (output == null) {
        output = '';
      }
    }
    WorkflowStatus statusDto = new WorkflowStatus();
    statusDto.instanceId = inst.Id;
    statusDto.definitionName = inst.Workflow_Name__c;
    statusDto.correlationKey = inst.Correlation_Key__c;
    statusDto.status = inst.Status__c;
    statusDto.isTerminal = terminal;
    statusDto.errorMessage = inst.Error_Message__c;
    statusDto.output = output;
    statusDto.causationId = cleanCausationId(inst.Causation_Id__c);
    return statusDto;
  }

  // Resolves all offload markers found in a collection of instances in one
  // ContentVersion SOQL query. Returns a map from ContentDocumentId → resolved text.
  private static Map<Id, String> bulkResolveOffloadedOutputs(
    List<Workflow_Instance__c> instances
  ) {
    Set<Id> docIds = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      Id docId = getOffloadDocId(inst.Output__c);
      if (docId != null) {
        docIds.add(docId);
      }
    }
    Map<Id, String> resolved = new Map<Id, String>();
    if (!docIds.isEmpty()) {
      for (ContentVersion cv : [
        SELECT ContentDocumentId, VersionData
        FROM ContentVersion
        WHERE ContentDocumentId IN :docIds AND IsLatest = TRUE
        WITH SYSTEM_MODE
      ]) {
        if (cv.VersionData != null) {
          resolved.put(cv.ContentDocumentId, cv.VersionData.toString());
        }
      }
    }
    return resolved;
  }

  // Extracts the ContentDocumentId from an offload marker, or null if not a marker.
  private static Id getOffloadDocId(String textValue) {
    if (
      String.isNotBlank(textValue) && textValue.startsWith('{"$attachmentId":')
    ) {
      try {
        Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(
          textValue
        );
        return (Id) marker.get('$attachmentId');
      } catch (Exception ignored) {
        // Not a valid offload marker; treat as a non-offloaded value.
      }
    }
    return null;
  }

  // Rehydrates a single output string using the pre-fetched resolved map.
  private static String rehydrateFromMap(
    String textValue,
    Map<Id, String> resolvedOutputByDocId
  ) {
    Id docId = getOffloadDocId(textValue);
    if (docId != null && resolvedOutputByDocId.containsKey(docId)) {
      return resolvedOutputByDocId.get(docId);
    }
    return textValue;
  }

  // ─── End Read API ──────────────────────────────────────────────────────────

  /**
   * Returns the historical causation lineage (parent/ancestor chain) of a workflow
   * instance ID up to the root cause. Bounded to a maximum depth of 12 hops to safeguard
   * against cyclic/governor limits. Performs zero DML.
   * @param instanceId Id of the instance whose causation chain is walked
   * @return status DTOs ordered from the given instance up to its root cause;
   * empty when instanceId is null
   */
  public static List<WorkflowStatus> getCausationLineage(Id instanceId) {
    List<WorkflowStatus> lineage = new List<WorkflowStatus>();
    if (instanceId == null) {
      return lineage;
    }

    predecessorQueriesRemaining = 15;
    Id currentId = instanceId;
    Set<Id> visitedIds = new Set<Id>();
    Integer maxHops = 12;
    List<Workflow_Instance__c> ancestors = new List<Workflow_Instance__c>();

    for (Integer hop = 0; hop < maxHops; hop++) {
      if (currentId == null || visitedIds.contains(currentId)) {
        break;
      }
      visitedIds.add(currentId);

      List<Workflow_Instance__c> records = [
        SELECT
          Id,
          Workflow_Name__c,
          Correlation_Key__c,
          Status__c,
          Error_Message__c,
          Causation_Id__c,
          Previous_Instance__c,
          Parent_Instance__c,
          Output__c,
          CreatedDate
        FROM Workflow_Instance__c
        WHERE Id = :currentId
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (records.isEmpty()) {
        break;
      }
      Workflow_Instance__c inst = records[0];
      ancestors.add(inst);

      String cause = inst.Causation_Id__c;
      if (String.isBlank(cause)) {
        if (inst.Parent_Instance__c != null) {
          currentId = inst.Parent_Instance__c;
          continue;
        }
        break;
      }

      Id resolvedId = null;
      if (isValidId(cause)) {
        List<Workflow_Instance__c> directRecords = [
          SELECT Id
          FROM Workflow_Instance__c
          WHERE Id = :cause
          WITH SYSTEM_MODE
          LIMIT 1
        ];
        if (!directRecords.isEmpty()) {
          resolvedId = directRecords[0].Id;
        }
      }

      if (resolvedId != null) {
        currentId = resolvedId;
      } else if (cause.startsWith('key:')) {
        String correlationKey = cause.substring(4);
        DateTime earliestCreatedDate = null;
        if (cause.startsWith('key:{"')) {
          try {
            String jsonStr = cause.substring(4);
            Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(
              jsonStr
            );
            correlationKey = (String) data.get('k');
            Long ms = (Long) data.get('t');
            earliestCreatedDate = DateTime.newInstance(ms);
          } catch (Exception ignored) {
            // fallback: leave earliestCreatedDate unresolved and continue
          }
        } else {
          Integer tsIndex = correlationKey.lastIndexOf('::ts::');
          if (tsIndex != -1) {
            String tsStr = correlationKey.substring(tsIndex + 6);
            if (tsStr.length() >= 12 && tsStr.length() <= 15) {
              try {
                Long ms = Long.valueOf(tsStr);
                earliestCreatedDate = DateTime.newInstance(ms);
                correlationKey = correlationKey.substring(0, tsIndex);
              } catch (Exception ignored) {
                // fallback: leave earliestCreatedDate unresolved and continue
              }
            }
          }
        }
        if (earliestCreatedDate == null) {
          // Backwards compatibility fallback for older '#' format
          Integer hashIndex = correlationKey.lastIndexOf('#');
          if (hashIndex != -1) {
            String tsStr = correlationKey.substring(hashIndex + 1);
            if (tsStr.length() >= 12 && tsStr.length() <= 15) {
              try {
                Long ms = Long.valueOf(tsStr);
                earliestCreatedDate = DateTime.newInstance(ms);
                correlationKey = correlationKey.substring(0, hashIndex);
              } catch (Exception ignored) {
                // fallback: leave earliestCreatedDate unresolved and continue
              }
            }
          }
        }
        if (earliestCreatedDate == null) {
          earliestCreatedDate = getEarliestPredecessorCreatedDate(inst);
        }

        List<Workflow_Instance__c> parents = [
          SELECT Id
          FROM Workflow_Instance__c
          WHERE
            (Correlation_Key__c = :correlationKey
            OR Active_Correlation_Key__c = :correlationKey
            OR Root_Correlation_Key__c = :correlationKey)
            AND CreatedDate <= :earliestCreatedDate
            AND Id NOT IN :visitedIds
          WITH SYSTEM_MODE
          ORDER BY CreatedDate DESC
          LIMIT 1
        ];

        if (!parents.isEmpty()) {
          currentId = parents[0].Id;
        } else {
          currentId = null;
        }
      } else {
        currentId = null;
      }
    }

    Map<Id, String> resolvedOutputByDocId = bulkResolveOffloadedOutputs(
      ancestors
    );
    for (Workflow_Instance__c inst : ancestors) {
      lineage.add(buildStatus(inst, resolvedOutputByDocId));
    }
    return lineage;
  }

  private static Boolean isValidId(String val) {
    if (String.isBlank(val)) {
      return false;
    }
    try {
      Id parsed = (Id) val;
      return parsed.getSObjectType() == Workflow_Instance__c.SObjectType;
    } catch (Exception ex) {
      return false;
    }
  }

  /**
   * Recovers the bare key from the current JSON causation form (`key:{...}`).
   * @param val a `key:`-scoped causation id
   * @return the `key:<k>` display value, or null when val is not JSON-shaped or
   *   cannot be parsed (so callers fall through to legacy trimming)
   */
  private static String parseKeyScopedJson(String val) {
    if (!val.startsWith('key:{"')) {
      return null;
    }
    try {
      String jsonStr = val.substring(4);
      Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(
        jsonStr
      );
      return 'key:' + (String) data.get('k');
    } catch (Exception ignored) {
      return null;
    }
  }

  /**
   * Trims a legacy numeric uniqueness suffix delimited by the given separator.
   * @param val the raw value
   * @param separator the delimiter preceding the numeric suffix
   * @return the value with the suffix removed, or null when there is no valid
   *   12-15 digit numeric suffix to strip
   */
  private static String stripNumericSuffix(String val, String separator) {
    Integer idx = val.lastIndexOf(separator);
    if (idx == -1) {
      return null;
    }
    String suffix = val.substring(idx + separator.length());
    if (suffix.length() < 12 || suffix.length() > 15) {
      return null;
    }
    try {
      Long.valueOf(suffix);
      return val.substring(0, idx);
    } catch (Exception ignored) {
      return null;
    }
  }

  /**
   * @description Normalizes a stored causation id for display by stripping the
   * uniqueness suffix from a `key:`-scoped value. Parses the current JSON form
   * (`key:{...}`) to recover the bare key, and falls back to trimming legacy
   * `::ts::<millis>` or `#<millis>` suffixes. Non-key values are returned unchanged.
   * @param val the raw causation id to clean
   * @return the display causation id, or the original value when nothing to strip
   */
  public static String cleanCausationId(String val) {
    if (String.isBlank(val) || !val.startsWith('key:')) {
      return val;
    }
    String fromJson = parseKeyScopedJson(val);
    if (fromJson != null) {
      return fromJson;
    }
    // Backwards compatibility fallback for older formats
    String tsTrimmed = stripNumericSuffix(val, '::ts::');
    if (tsTrimmed != null) {
      return tsTrimmed;
    }
    String hashTrimmed = stripNumericSuffix(val, '#');
    if (hashTrimmed != null) {
      return hashTrimmed;
    }
    return val;
  }

  private static Boolean hasUnambiguousTimestampSuffix(String val) {
    if (String.isBlank(val)) {
      return false;
    }
    Integer tsIndex = val.lastIndexOf('::ts::');
    if (tsIndex == -1 || tsIndex == val.length() - 6) {
      return false;
    }
    String suffix = val.substring(tsIndex + 6);
    if (suffix.length() < 12 || suffix.length() > 15) {
      return false;
    }
    try {
      Long.valueOf(suffix);
      return true;
    } catch (Exception ex) {
      return false;
    }
  }

  private static DateTime getEarliestPredecessorCreatedDate(
    Workflow_Instance__c inst
  ) {
    return getEarliestPredecessorCreatedDate(inst, 100);
  }

  /**
   * Mutable state for a predecessor-chain walk: the earliest CreatedDate seen so
   * far, the next predecessor id to visit, the set of already-visited ids, the
   * hop count and the hop ceiling.
   */
  private class PredecessorWalk {
    DateTime earliest;
    Id prevId;
    Set<Id> visited;
    Integer hopsCount;
    Integer maxPredecessors;
  }

  /**
   * Whether the walk may take another hop to a present predecessor node: the
   * next id is set, unvisited, the node is present, and the hop ceiling is not
   * yet reached.
   * @param walk the walk state
   * @param nodePresent whether the next predecessor node is populated
   * @return true when the walk may advance to the node
   */
  private static Boolean canLookAhead(
    PredecessorWalk walk,
    Boolean nodePresent
  ) {
    return walk.prevId != null &&
      !walk.visited.contains(walk.prevId) &&
      nodePresent &&
      walk.hopsCount < walk.maxPredecessors;
  }

  /**
   * Walks up to four further predecessor levels in-memory from the queried row
   * `p` (whose Previous_Instance__r chain was pre-fetched five deep), advancing
   * the walk's earliest/prevId/hopsCount/visited state. Stops at the first level
   * whose predecessor is absent, already visited, or beyond the hop ceiling.
   * @param walk the walk state to advance
   * @param p the queried row with its pre-fetched predecessor chain
   */
  private static void advanceInMemoryLookAhead(
    PredecessorWalk walk,
    Workflow_Instance__c p
  ) {
    if (!canLookAhead(walk, p.Previous_Instance__r != null)) {
      return;
    }
    walk.visited.add(walk.prevId);
    walk.earliest = p.Previous_Instance__r.CreatedDate;
    walk.prevId = p.Previous_Instance__r.Previous_Instance__c;
    walk.hopsCount++;

    if (
      !canLookAhead(walk, p.Previous_Instance__r.Previous_Instance__r != null)
    ) {
      return;
    }
    walk.visited.add(walk.prevId);
    walk.earliest = p.Previous_Instance__r.Previous_Instance__r.CreatedDate;
    walk.prevId = p.Previous_Instance__r.Previous_Instance__r.Previous_Instance__c;
    walk.hopsCount++;

    if (
      !canLookAhead(
        walk,
        p.Previous_Instance__r.Previous_Instance__r.Previous_Instance__c != null
      )
    ) {
      return;
    }
    walk.visited.add(walk.prevId);
    walk.earliest = p.Previous_Instance__r.Previous_Instance__r.Previous_Instance__r
      .CreatedDate;
    walk.prevId = p.Previous_Instance__r.Previous_Instance__r.Previous_Instance__r
      .Previous_Instance__c;
    walk.hopsCount++;

    if (
      !canLookAhead(
        walk,
        p.Previous_Instance__r.Previous_Instance__r.Previous_Instance__r
          .Previous_Instance__c != null
      )
    ) {
      return;
    }
    walk.visited.add(walk.prevId);
    walk.earliest = p.Previous_Instance__r.Previous_Instance__r.Previous_Instance__r
      .Previous_Instance__r.CreatedDate;
    walk.prevId = p.Previous_Instance__r.Previous_Instance__r.Previous_Instance__r
      .Previous_Instance__r.Previous_Instance__c;
    walk.hopsCount++;
  }

  private static DateTime getEarliestPredecessorCreatedDate(
    Workflow_Instance__c inst,
    Integer maxPredecessors
  ) {
    PredecessorWalk walk = new PredecessorWalk();
    walk.earliest = inst.CreatedDate;
    walk.prevId = inst.Previous_Instance__c;
    walk.visited = new Set<Id>{ inst.Id };
    walk.hopsCount = 0;
    walk.maxPredecessors = maxPredecessors;
    while (
      walk.prevId != null &&
      !walk.visited.contains(walk.prevId) &&
      walk.hopsCount < maxPredecessors &&
      predecessorQueriesRemaining > 0
    ) {
      walk.visited.add(walk.prevId);
      predecessorQueriesRemaining--;
      Id prevId = walk.prevId;
      List<Workflow_Instance__c> prevs = [
        SELECT
          Id,
          CreatedDate,
          Previous_Instance__c,
          Previous_Instance__r.CreatedDate,
          Previous_Instance__r.Previous_Instance__c,
          Previous_Instance__r.Previous_Instance__r.CreatedDate,
          Previous_Instance__r.Previous_Instance__r.Previous_Instance__c,
          Previous_Instance__r.Previous_Instance__r.Previous_Instance__r.CreatedDate,
          Previous_Instance__r.Previous_Instance__r.Previous_Instance__r.Previous_Instance__c,
          Previous_Instance__r.Previous_Instance__r.Previous_Instance__r.Previous_Instance__r.CreatedDate,
          Previous_Instance__r.Previous_Instance__r.Previous_Instance__r.Previous_Instance__r.Previous_Instance__c
        FROM Workflow_Instance__c
        WHERE Id = :prevId
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (prevs.isEmpty()) {
        break;
      }

      Workflow_Instance__c p = prevs[0];
      walk.earliest = p.CreatedDate;
      walk.prevId = p.Previous_Instance__c;
      walk.hopsCount++;

      // Look ahead up to 4 more levels from p in-memory
      advanceInMemoryLookAhead(walk, p);
    }
    return walk.earliest;
  }

  /**
   * Starts a new durable workflow instance (get-or-start). If an instance with
   * the same correlation key already exists within the dedup scope, returns
   * that instance's Id instead of inserting a duplicate.
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
    return doStart(new StartRequest(workflowName, correlationKey, input), true)
      .instanceId;
  }

  /**
   * @description Get-or-start from a fully-built request (attributes and/or
   * parent reference set fluently on the request). Replaces the former positional
   * start overloads that took attributes and/or a parent instance id.
   * @param request the start request describing the instance to get-or-start
   * @return Id of the new or deduplicated existing instance
   */
  public static Id start(StartRequest request) {
    return doStart(request, true).instanceId;
  }

  /**
   * Arms a durable trailing-edge debounce timer for starting a workflow. Build
   * the request with workflowName, correlationKey, inputJson and debounceSeconds
   * (and optionally maxWaitSeconds, attributesJson and causationId). Replaces the
   * former positional startDebounced overloads.
   * @param request the debounce request describing the coalesced start
   */
  public static void startDebounced(WorkflowDebouncer.DebounceRequest request) {
    WorkflowDebouncer.startDebounced(
      new List<WorkflowDebouncer.DebounceRequest>{ request }
    );
  }

  /**
   * Get-or-start variant that exposes whether a new instance was created or an
   * existing one was returned.
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
    return doStart(new StartRequest(workflowName, correlationKey, input), true);
  }

  /**
   * @description startOrGet from a fully-built request (attributes and/or parent
   * reference set fluently on the request). Replaces the former positional
   * startOrGet overloads that took attributes and/or a parent instance id.
   * @param request the start request describing the instance to get-or-start
   * @return a StartResult carrying the instance Id and whether it was newly created
   */
  public static StartResult startOrGet(StartRequest request) {
    return doStart(request, true);
  }

  /**
   * Active-only get-or-start for engine-internal singleton workflows (e.g. the
   * watchdog). Never dedups against terminal instances, so a failed or
   * continued-as-new singleton is always restarted rather than resolving to a
   * dead terminal run within the dedup window.
   * @param workflowName developer name of the singleton workflow definition
   * @param correlationKey dedup/correlation key for the singleton
   * @param input start input payload passed to the first step
   * @return Id of the active instance (existing if one is live, otherwise newly created)
   */
  public static Id startSingleton(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    return doStart(new StartRequest(workflowName, correlationKey, input), false)
      .instanceId;
  }

  private static void validateAttributes(Map<String, String> attributes) {
    if (attributes == null || attributes.isEmpty()) {
      return;
    }
    if (attributes.size() > MAX_ATTRIBUTES_PER_INSTANCE) {
      throw new WorkflowException(
        'Attribute count exceeds maximum limit of ' +
        MAX_ATTRIBUTES_PER_INSTANCE
      );
    }
    for (String key : attributes.keySet()) {
      validateAttributeEntry(key, attributes.get(key));
    }
  }

  /**
   * Validates a single search-attribute key/value pair against the key-blankness,
   * key-length, and value-length limits.
   * @param key the attribute key
   * @param val the attribute value (may be null)
   */
  private static void validateAttributeEntry(String key, String val) {
    if (String.isBlank(key)) {
      throw new WorkflowException('Attribute key cannot be blank');
    }
    if (key.length() > MAX_ATTRIBUTE_KEY_LENGTH) {
      throw new WorkflowException(
        'Attribute key length exceeds maximum limit of ' +
          MAX_ATTRIBUTE_KEY_LENGTH +
          ' characters: ' +
          key
      );
    }
    if (val != null && val.length() > MAX_ATTRIBUTE_VALUE_LENGTH) {
      throw new WorkflowException(
        'Attribute value length exceeds maximum limit of ' +
          MAX_ATTRIBUTE_VALUE_LENGTH +
          ' characters: ' +
          val
      );
    }
  }

  private static List<Workflow_Search_Attribute__c> buildAttributes(
    Id instanceId,
    Map<String, String> attributes
  ) {
    List<Workflow_Search_Attribute__c> records = new List<Workflow_Search_Attribute__c>();
    if (attributes == null || attributes.isEmpty()) {
      return records;
    }
    for (String key : attributes.keySet()) {
      String val = attributes.get(key);
      records.add(
        new Workflow_Search_Attribute__c(
          Workflow_Instance__c = instanceId,
          Key__c = key,
          Value__c = val,
          Key_Value__c = key + '=' + (val == null ? '' : val)
        )
      );
    }
    return records;
  }

  /**
   * Resolves an existing get-or-start winner within the dedup scope.
   * @param correlationKey the correlation key to look up
   * @param includeTerminal whether recently-terminal matches count
   * @return the existing instance, or null when none is in scope
   */
  private static Workflow_Instance__c resolveExistingStart(
    String correlationKey,
    Boolean includeTerminal
  ) {
    return findExistingByKey(new Set<String>{ correlationKey }, includeTerminal)
      .get(normalizeKey(correlationKey));
  }

  /**
   * Inserts the instance and its search attributes, resolving the unique-index
   * concurrency backstop on DUPLICATE_VALUE.
   * @param instance the unsaved instance to insert
   * @param attributes the search attributes to insert alongside it
   * @param correlationKey the correlation key (used to resolve a race winner)
   * @return a StartResult when a sibling won the race (caller returns it), else
   *   null on a normal successful insert
   */
  private static StartResult insertStartInstance(
    Workflow_Instance__c instance,
    Map<String, String> attributes,
    String correlationKey
  ) {
    try {
      Database.insert(instance, true, AccessLevel.SYSTEM_MODE);
      List<Workflow_Search_Attribute__c> attrsToInsert = buildAttributes(
        instance.Id,
        attributes
      );
      if (!attrsToInsert.isEmpty()) {
        Database.insert(attrsToInsert, true, AccessLevel.SYSTEM_MODE);
      }
      return null;
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) != 'DUPLICATE_VALUE') {
        throw ex;
      }
      // Concurrency backstop: a sibling start won the race on the unique
      // Active_Correlation_Key__c index. A sibling provably exists, so resolve
      // the winner regardless of the dedup window (it may have completed
      // mid-race) and return its Id so the loser is a safe no-op.
      Workflow_Instance__c winner = findAnyByKey(
          new Set<String>{ correlationKey }
        )
        .get(normalizeKey(correlationKey));
      if (winner != null) {
        return new StartResult(winner.Id);
      }
      throw new WorkflowException(
        'An active workflow already exists with correlation key: ' +
        correlationKey
      );
    }
  }

  /**
   * Inserts the initial Pending step execution for a freshly-started instance,
   * arming the timeout clock unless the start is parked or concurrency-deferred.
   * @param instance the inserted instance
   * @param parkAtStart whether the start is parked by the operator pause gate
   * @param deferTimeoutForConcurrency whether admission will arm the timeout
   */
  private static void insertInitialStepExecution(
    Workflow_Instance__c instance,
    Boolean parkAtStart,
    Boolean deferTimeoutForConcurrency
  ) {
    if (String.isBlank(instance.Current_Step__c)) {
      return;
    }
    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
    stepExec.Workflow_Instance__c = instance.Id;
    stepExec.Step_Name__c = instance.Current_Step__c;
    stepExec.Status__c = 'Pending';
    stepExec.Input__c = instance.Input__c;
    stepExec.Retry_Count__c = 0;
    // Do not start the timeout clock while parked — a paused/throttled step's
    // Timeout_At__c would otherwise pollute the watchdog timeout batch (selected,
    // then skipped because the parent is not runnable) or, for a still-Pending
    // bounded start, fail it before admission. Resume/admission re-establishes it.
    if (!parkAtStart && !deferTimeoutForConcurrency) {
      Integer timeout = getStepTimeoutSeconds(
        instance.Current_Step__c,
        WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
      );
      if (timeout != null && timeout > 0) {
        stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
      }
    }
    Database.insert(stepExec, true, AccessLevel.SYSTEM_MODE);
  }

  private static StartResult doStart(
    StartRequest req,
    Boolean includeTerminal
  ) {
    String correlationKey = req.correlationKey;
    Object input = req.input;
    Map<String, String> attributes = req.attributes;
    validateCorrelationKey(correlationKey);
    validateAttributes(attributes);

    // Get-or-start: return an existing instance within the dedup scope (active,
    // and optionally recently terminal within the configured window) instead of
    // throwing or inserting a duplicate. No step-execution write, no enqueue.
    //
    // Concurrency note (known limitation): the unique Active_Correlation_Key__c
    // index is the hard backstop for the active<->active race. Terminal-window
    // dedup is best-effort under concurrent redelivery: if a sibling start
    // inserts AND transitions to terminal in the narrow window between this
    // pre-query and our insert, the trigger has already cleared its active key,
    // so our insert succeeds and a duplicate of a just-finished, in-window run
    // can be created. Closing this fully would require a recheck-after-insert
    // (an extra SOQL on every successful start) or a lock surviving the terminal
    // transition; both are intentionally avoided here to keep the start path to
    // a single indexed SOQL. The common cases (active redelivery, sequential
    // post-completion redelivery) are fully covered.
    if (String.isNotBlank(correlationKey)) {
      Workflow_Instance__c match = resolveExistingStart(
        correlationKey,
        includeTerminal
      );
      if (match != null) {
        return new StartResult(match.Id);
      }
    }

    Workflow_Instance__c instance = buildInstance(req);

    StartResult raceWinner = insertStartInstance(
      instance,
      attributes,
      correlationKey
    );
    if (raceWinner != null) {
      return raceWinner;
    }

    instance.Input__c = savePayloadIfNeeded(
      instance.Id,
      (req.inputJson != null)
        ? req.inputJson
        : ((input != null) ? JSON.serialize(input) : null),
      'Input_' + instance.Id
    );

    // Operator pause gate — decide up front whether to park this start, so the
    // initial step's timeout clock is never started while parked.
    Boolean parkAtStart =
      WorkflowPauseGate.anyPaused() &&
      WorkflowPauseGate.isDefinitionPaused(instance.Workflow_Name__c);

    // A concurrency-bounded workflow may park on its first RUN_STEP before executing
    // a step. Defer arming the initial step's timeout until admission succeeds (the
    // admission path re-arms it via reArmTimeoutsForResume). Otherwise a still-Pending
    // step sitting in the event/queue backlog during a burst could be failed by the
    // timeout sweep before it ever reaches the gate to park.
    Boolean deferTimeoutForConcurrency = ConcurrencyGate.isConfigured(
      instance.Workflow_Name__c
    );
    // Stamp the durable awaiting-admission marker at deferral time. The pre-start
    // watchdog (WorkflowTimeoutJob) keys its null-deadline skip off this marker, not
    // the live CMDT, so a ceiling added later cannot retroactively silence a genuine
    // unbounded pre-start watchdog. Cleared on admission (the acquire path) / when the
    // ceiling is later removed (the unbounded fall-through).
    if (deferTimeoutForConcurrency) {
      instance.Concurrency_Parked__c = true;
    }
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    insertInitialStepExecution(
      instance,
      parkAtStart,
      deferTimeoutForConcurrency
    );

    // Park at start if the definition is currently paused. The initial Pending
    // Workflow_Step_Execution__c (inserted above, with no timeout clock) gives the
    // resume path a concrete step to drive. Skip timeout scheduling and the first
    // enqueue; the watchdog re-drives held work on resume.
    if (parkAtStart) {
      return parkStartInstance(instance);
    }

    return finalizeStart(instance, deferTimeoutForConcurrency);
  }

  /**
   * Parks a freshly-started instance under the operator pause gate.
   * @param instance the inserted instance to park
   * @return a new-marked StartResult for the parked instance
   */
  private static StartResult parkStartInstance(Workflow_Instance__c instance) {
    instance.Status__c = 'Paused';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    return new StartResult(instance.Id).markNew();
  }

  /**
   * Schedules the initial-step watchdog (unless concurrency-deferred) and enqueues
   * the first step execution for a non-parked start.
   * @param instance the inserted instance to drive
   * @param deferTimeoutForConcurrency whether admission will arm the timeout
   * @return a new-marked StartResult for the started instance
   */
  private static StartResult finalizeStart(
    Workflow_Instance__c instance,
    Boolean deferTimeoutForConcurrency
  ) {
    // Schedule watchdog for the initial step before executing it — unless this is a
    // bounded workflow, where the admission gate arms the timeout once a slot is won.
    if (!deferTimeoutForConcurrency) {
      scheduleTimeoutJobForInstance(instance.Id);
    }

    // Enqueue the first step execution
    enqueueOrchestrators(new List<Id>{ instance.Id });
    return new StartResult(instance.Id).markNew();
  }

  /**
   * Builds an unsaved Workflow_Instance__c for a start request, resolving the
   * definition version and initial step.
   * @param req the start request describing the workflow to instantiate
   * @return an unsaved Workflow_Instance__c populated from the request and definition
   */
  // Candidate (localName, namespace) pairs used to authorize a workflow name
  // against ApexTypeImplementor with and without its resolved namespace prefix.
  private class WorkflowNameCandidates {
    String localName1;
    String ns1;
    String localName2;
    String ns2;
  }

  private static Workflow_Instance__c buildInstance(StartRequest req) {
    Workflow_Instance__c instance = new Workflow_Instance__c();
    Type startWflowType = WorkflowTypeResolver.resolve(
      req.workflowName,
      WorkflowTypeResolver.extractNamespace(req.workflowName)
    );
    instance.Workflow_Name__c = startWflowType != null
      ? String.valueOf(startWflowType)
      : req.workflowName;
    instance.Status__c = 'Pending';
    instance.Correlation_Key__c = req.correlationKey;
    instance.Parent_Instance__c = req.parentInstanceId;
    instance.Causation_Id__c = resolveCausationId(req);

    validateWorkflowAuthorization(req);
    applyDefinitionMetadata(instance, req);
    return instance;
  }

  private static String resolveCausationId(StartRequest req) {
    if (String.isBlank(req.causationId)) {
      return req.parentInstanceId;
    }
    String finalCausationId = req.causationId;
    if (finalCausationId.startsWith('key:')) {
      Map<String, Object> payload = new Map<String, Object>{
        'k' => finalCausationId.substring(4),
        't' => System.now().getTime() + 1000
      };
      finalCausationId = 'key:' + JSON.serialize(payload);
    }
    return finalCausationId;
  }

  // Authorize the workflow name against ApexTypeImplementor once per name
  // (memoized in validatedWorkflows); throws when no authorized implementor
  // matches either candidate (local or fully-qualified) form.
  private static void validateWorkflowAuthorization(StartRequest req) {
    if (String.isBlank(req.workflowName)) {
      return;
    }
    String wflowKey = req.workflowName.toLowerCase();
    if (validatedWorkflows.containsKey(wflowKey)) {
      return;
    }
    WorkflowNameCandidates c = resolveNameCandidates(req.workflowName);
    List<ApexTypeImplementor> queryResults = [
      SELECT ClassName, ClassNamespacePrefix
      FROM ApexTypeImplementor
      WHERE
        ClassName IN (:c.localName1, :c.localName2)
        AND ClassNamespacePrefix IN (:c.ns1, :c.ns2)
        AND InterfaceName IN (
          'WorkflowDefinition',
          'VersionedWorkflow',
          'ErrorRoutingWorkflow'
        )
      WITH SYSTEM_MODE
    ];
    if (!matchesAuthorizedImpl(queryResults, c)) {
      throw new WorkflowException(
        'Unauthorized or invalid workflow definition: ' + req.workflowName
      );
    }
    validatedWorkflows.put(wflowKey, true);
  }

  private static WorkflowNameCandidates resolveNameCandidates(
    String workflowName
  ) {
    WorkflowNameCandidates c = new WorkflowNameCandidates();
    c.localName1 = workflowName;
    c.ns1 = '';
    c.localName2 = workflowName;
    c.ns2 = '';
    Type resolvedWflowType = WorkflowTypeResolver.resolve(
      workflowName,
      WorkflowTypeResolver.extractNamespace(workflowName)
    );
    if (resolvedWflowType != null) {
      String fqName = String.valueOf(resolvedWflowType);
      if (fqName.contains('.')) {
        c.ns1 = fqName.substringBefore('.');
        c.localName1 = fqName.substringAfter('.');
        c.ns2 = '';
        c.localName2 = fqName;
      } else {
        c.localName1 = fqName;
        c.localName2 = fqName;
      }
    }
    return c;
  }

  private static Boolean matchesAuthorizedImpl(
    List<ApexTypeImplementor> queryResults,
    WorkflowNameCandidates c
  ) {
    for (ApexTypeImplementor impl : queryResults) {
      String implNs = String.isBlank(impl.ClassNamespacePrefix)
        ? ''
        : impl.ClassNamespacePrefix;
      if (
        (impl.ClassName.equalsIgnoreCase(c.localName1) &&
        implNs.equalsIgnoreCase(c.ns1)) ||
        (impl.ClassName.equalsIgnoreCase(c.localName2) &&
        implNs.equalsIgnoreCase(c.ns2))
      ) {
        return true;
      }
    }
    return false;
  }

  private static void applyDefinitionMetadata(
    Workflow_Instance__c instance,
    StartRequest req
  ) {
    Type wflowType = WorkflowTypeResolver.resolve(
      req.workflowName,
      WorkflowTypeResolver.extractNamespace(req.workflowName)
    );
    if (wflowType == null) {
      instance.Definition_Version__c = 1;
      return;
    }
    Object defObj = wflowType.newInstance();
    if (defObj instanceof VersionedWorkflow) {
      instance.Definition_Version__c = ((VersionedWorkflow) defObj)
        .getLatestVersion();
    } else {
      instance.Definition_Version__c = 1;
    }
    if (defObj instanceof WorkflowDefinition) {
      instance.Current_Step__c = ((WorkflowDefinition) defObj).getInitialStep();
    }
    if (defObj instanceof ExecutionTimeoutConfigurable) {
      Integer timeoutSecs = ((ExecutionTimeoutConfigurable) defObj)
        .getExecutionTimeoutSeconds();
      if (timeoutSecs != null) {
        instance.Deadline_At__c = DateTime.now().addSeconds(timeoutSecs);
      }
    }
  }

  /**
   * Canonical form of a correlation key for in-memory dedup maps/sets.
   * Correlation_Key__c is case-insensitive (and the unique
   * Active_Correlation_Key__c index is too), but Apex Map/Set keys are
   * case-sensitive, so keys are lower-cased to match the database semantics.
   * @param key the raw correlation key
   * @return the lower-cased key, or null when the input is null
   */
  private static String normalizeKey(String key) {
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
      List<String> resolved = resolvePayloads(rawOutputs);
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
   * Fast path for a single requested key: one indexed LIMIT 1 query returns the
   * single most-relevant row (an active instance preferred via NULLS FIRST, else
   * the newest in-window terminal), bounding the row governor regardless of how
   * many historical terminal runs the key has.
   * @param keys the single-element requested key set
   * @param terminalEnabled when true, allow an in-window terminal instance to win
   * @return the (at most one) resolved key-to-instance mapping
   */
  private static Map<String, Workflow_Instance__c> findSingleKeyWinner(
    Set<String> keys,
    Boolean terminalEnabled
  ) {
    Map<String, Workflow_Instance__c> result = new Map<String, Workflow_Instance__c>();
    DateTime windowStart = terminalEnabled
      ? dedupWindowStart()
      : DateTime.now().addYears(1000);
    for (Workflow_Instance__c inst : [
      SELECT Id, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        Correlation_Key__c IN :keys
        AND (Status__c IN :ACTIVE_STATUSES
        OR Terminal_At__c >= :windowStart)
      WITH SYSTEM_MODE
      ORDER BY Terminal_At__c DESC NULLS FIRST, CreatedDate DESC
      LIMIT 1
    ]) {
      result.put(normalizeKey(inst.Correlation_Key__c), inst);
    }
    return result;
  }

  /**
   * Computes the maximum in-window Terminal_At__c per remaining key via an
   * aggregate (each grouped result counts as a single SOQL row, so a hot key
   * cannot exhaust the row limit), filling maxTimeByKey and returning the set of
   * distinct max timestamps for the follow-up bounded fetch.
   * @param remaining the keys still unresolved after the active-instance pass
   * @param windowStart the dedup-window lower bound
   * @param maxTimeByKey out: normalized key to its max Terminal_At__c
   * @return the distinct max timestamps across the remaining keys
   */
  private static Set<Datetime> computeMaxTerminalTimes(
    Set<String> remaining,
    DateTime windowStart,
    Map<String, Datetime> maxTimeByKey
  ) {
    Set<Datetime> maxTimes = new Set<Datetime>();
    for (AggregateResult ar : [
      SELECT Correlation_Key__c ck, MAX(Terminal_At__c) mt
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :remaining AND Terminal_At__c >= :windowStart
      WITH SYSTEM_MODE
      GROUP BY Correlation_Key__c
    ]) {
      Datetime mt = (Datetime) ar.get('mt');
      if (mt == null) {
        continue;
      }
      String n = normalizeKey((String) ar.get('ck'));
      Datetime existing = maxTimeByKey.get(n);
      if (existing == null || mt > existing) {
        maxTimeByKey.put(n, mt);
      }
      maxTimes.add(mt);
    }
    return maxTimes;
  }

  /**
   * Bulk terminal pass (phase 2): resolves the most-recent in-window terminal
   * instance for each key not already resolved to an active instance. Mutates
   * result in place.
   * @param keys the full requested key set
   * @param result the accumulating key-to-instance map to extend
   */
  private static void resolveTerminalWinners(
    Set<String> keys,
    Map<String, Workflow_Instance__c> result
  ) {
    Set<String> remaining = new Set<String>();
    for (String k : keys) {
      if (!result.containsKey(normalizeKey(k))) {
        remaining.add(k);
      }
    }
    if (remaining.isEmpty()) {
      return;
    }

    DateTime windowStart = dedupWindowStart();
    Map<String, Datetime> maxTimeByKey = new Map<String, Datetime>();
    Set<Datetime> maxTimes = computeMaxTerminalTimes(
      remaining,
      windowStart,
      maxTimeByKey
    );
    if (maxTimes.isEmpty()) {
      return;
    }

    for (Workflow_Instance__c inst : [
      SELECT Id, Correlation_Key__c, Terminal_At__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :remaining AND Terminal_At__c IN :maxTimes
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
    ]) {
      String n = normalizeKey(inst.Correlation_Key__c);
      if (
        !result.containsKey(n) && inst.Terminal_At__c == maxTimeByKey.get(n)
      ) {
        result.put(n, inst);
      }
    }
  }

  /**
   * Resolves the dedup-winner instance for each correlation key: an active
   * instance if one exists, otherwise (when includeTerminal is true) the most
   * recent terminal instance that became terminal within the configured dedup
   * window. The returned map is keyed by the normalized correlation key.
   * @param keys normalized correlation keys to resolve
   * @param includeTerminal when true, allow a recently-terminal instance to win
   * @return map of normalized key to its dedup-winning instance
   */
  private static Map<String, Workflow_Instance__c> findExistingByKey(
    Set<String> keys,
    Boolean includeTerminal
  ) {
    Map<String, Workflow_Instance__c> result = new Map<String, Workflow_Instance__c>();
    if (keys == null || keys.isEmpty()) {
      return result;
    }
    Boolean terminalEnabled =
      includeTerminal &&
      dedupWindowMinutes != null &&
      dedupWindowMinutes > 0;

    // Fast path: a single key needs only the single most-relevant row. SOQL
    // equality is case-insensitive, so a stored "Foo" matches a requested "foo".
    if (keys.size() == 1) {
      return findSingleKeyWinner(keys, terminalEnabled);
    }

    // Bulk path: resolve each key independently so no single hot key can crowd
    // out another, and without reading every historical terminal row.
    // 1) Active instances — bounded to at most one per key by the unique
    //    Active_Correlation_Key__c index.
    for (Workflow_Instance__c inst : [
      SELECT Id, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :keys AND Status__c IN :ACTIVE_STATUSES
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
    ]) {
      String n = normalizeKey(inst.Correlation_Key__c);
      if (!result.containsKey(n)) {
        result.put(n, inst);
      }
    }
    if (!terminalEnabled) {
      return result;
    }

    // 2) Most-recent terminal per key not already resolved to an active instance.
    resolveTerminalWinners(keys, result);
    return result;
  }

  /**
   * Resolves the existing instance per key regardless of the dedup window,
   * preferring an active instance then the most recent terminal one. Used as the
   * post-DUPLICATE_VALUE concurrency backstop, where a sibling is known to exist
   * and the loser must always resolve to the winner per the get-or-start
   * contract (even if the winner completed mid-race, and even when the window is
   * disabled). Row-bounded for the same governor-safety reason as
   * findExistingByKey.
   * @param keys normalized correlation keys to resolve
   * @return map of normalized key to the preferred (active, else latest terminal)
   * instance
   */
  private static Map<String, Workflow_Instance__c> findAnyByKey(
    Set<String> keys
  ) {
    Map<String, Workflow_Instance__c> result = new Map<String, Workflow_Instance__c>();
    if (keys == null || keys.isEmpty()) {
      return result;
    }
    Integer rowLimit = keys.size() == 1 ? 1 : dedupLookupRowCap;
    for (Workflow_Instance__c inst : [
      SELECT Id, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :keys
      WITH SYSTEM_MODE
      ORDER BY Terminal_At__c DESC NULLS FIRST, CreatedDate DESC
      LIMIT :rowLimit
    ]) {
      String normalized = normalizeKey(inst.Correlation_Key__c);
      if (!result.containsKey(normalized)) {
        result.put(normalized, inst);
      }
    }
    return result;
  }

  /**
   * Lower bound for the terminal dedup window. When the window is at its
   * minimum (<= 0) a far-future sentinel is returned so no terminal instance
   * matches, preserving active-only dedup behavior. The window is clamped to a
   * safe maximum so a misconfigured value cannot underflow the valid DateTime
   * range.
   * @return the lower-bound timestamp for terminal dedup, or a far-future sentinel
   * when the window is disabled
   */
  private static DateTime dedupWindowStart() {
    if (dedupWindowMinutes != null && dedupWindowMinutes > 0) {
      Integer minutes = Math.min(dedupWindowMinutes, MAX_DEDUP_WINDOW_MINUTES);
      return DateTime.now().addMinutes(-minutes);
    }
    return DateTime.now().addYears(1000);
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
   * (get-or-start). A duplicate correlation key resolves to the existing
   * instance and never faults sibling requests in the same invocation.
   * @param requests the start requests to process
   * @return instance Ids index-aligned with requests (null per null request)
   */
  public static List<Id> start(List<StartRequest> requests) {
    List<Id> ids = new List<Id>();
    for (StartResult r : startOrGet(requests)) {
      ids.add(r == null ? null : r.instanceId);
    }
    return ids;
  }

  // Mutable accumulator threaded through the startOrGet phase helpers so each
  // helper stays within the parameter and complexity budgets.
  private class StartOrGetRun {
    List<StartRequest> requests;
    List<StartResult> results;
    List<Workflow_Instance__c> toInsert;
    List<Integer> insertReqIndexes;
    List<Workflow_Instance__c> insertedInstances = new List<Workflow_Instance__c>();
    List<Integer> insertedReqIndexes = new List<Integer>();
    Set<String> concurrentLoserKeys = new Set<String>();
    Set<Id> parkedIds = new Set<Id>();
    Set<Id> deferTimeoutIds = new Set<Id>();
    List<Workflow_Instance__c> instancesToPark = new List<Workflow_Instance__c>();
  }

  // Candidate class-name / namespace sets to query for workflow-name validation,
  // plus the raw-spelling back-references keyed by resolved class name.
  private class WorkflowNameQuery {
    Set<String> localNames = new Set<String>();
    Set<String> namespaces = new Set<String>();
    Map<String, List<String>> rawNamesByResolved = new Map<String, List<String>>();
  }

  /**
   * Bulk get-or-start. Returns a result per request (index-aligned) reporting
   * the resolved instance Id and whether it was newly created or deduped.
   * @param requests the start requests to process
   * @return StartResults index-aligned with requests (null per null request)
   */
  public static List<StartResult> startOrGet(List<StartRequest> requests) {
    List<StartResult> results = new List<StartResult>();
    if (requests == null || requests.isEmpty()) {
      return results;
    }
    StartOrGetRun run = new StartOrGetRun();
    run.requests = requests;
    run.results = results;

    // 1. Validate and gather correlation keys, and pre-validate workflow names in bulk
    Set<String> correlationKeys = validateAndPrevalidateStarts(requests);

    // 2. Pre-resolve existing instances within the dedup scope (keyed by the
    //    normalized correlation key to honor case-insensitive matching).
    Map<String, Workflow_Instance__c> existingByKey = findExistingByKey(
      correlationKeys,
      true
    );

    // 3. Decide per request (preserving order): dedup to an existing instance,
    //    dedup to an intra-batch sibling, or build a fresh instance to insert.
    decideStartRequests(run, existingByKey);

    // 4. Insert fresh instances, tolerating per-row DUPLICATE_VALUE from a
    //    concurrent winner (the unique Active_Correlation_Key__c backstop).
    insertFreshInstances(run);
    insertStartSearchAttributes(run);

    // 5. Build a key -> resolved Id map for newly inserted instances and for
    //    any concurrent winners, then fill remaining results and assert resolution.
    fillRemainingStartResults(run);
    assertAllStartsResolved(run);

    // 6. Resolve input payloads for newly inserted instances
    resolveStartInputPayloads(run);

    // Operator pause gate and concurrency-bounded deferral (mirror doStart).
    applyStartPauseGate(run);
    applyStartConcurrencyGate(run);

    // 7. Construct initial Step Execution logs for inserted instances only
    buildInitialStepExecs(run);

    // Persist the parked status transition; parked instances are neither scheduled
    // nor enqueued — the resume path drives them when the definition is resumed.
    if (!run.instancesToPark.isEmpty()) {
      Database.update(run.instancesToPark, true, AccessLevel.SYSTEM_MODE);
    }

    // 8. Schedule timeout jobs and enqueue orchestrators for eligible instances.
    scheduleAndEnqueueStarts(run);

    return results;
  }

  // §1: validate each request and gather correlation keys; pre-validate any
  // not-yet-cached workflow names in bulk via ApexTypeImplementor.
  private static Set<String> validateAndPrevalidateStarts(
    List<StartRequest> requests
  ) {
    Set<String> correlationKeys = new Set<String>();
    Set<String> workflowNamesToQuery = new Set<String>();
    for (StartRequest req : requests) {
      if (req == null) {
        continue;
      }
      validateCorrelationKey(req.correlationKey);
      validateAttributes(req.attributes);
      if (String.isNotBlank(req.correlationKey)) {
        correlationKeys.add(req.correlationKey);
      }
      if (String.isNotBlank(req.workflowName)) {
        String wflowKey = req.workflowName.toLowerCase();
        if (!validatedWorkflows.containsKey(wflowKey)) {
          workflowNamesToQuery.add(req.workflowName);
        }
      }
    }

    if (!workflowNamesToQuery.isEmpty()) {
      prevalidateWorkflowNames(workflowNamesToQuery);
    }
    return correlationKeys;
  }

  // Query ApexTypeImplementor for the candidate class/namespace pairs and mark
  // the matching workflow names validated (both resolved and raw spellings).
  private static void prevalidateWorkflowNames(
    Set<String> workflowNamesToQuery
  ) {
    WorkflowNameQuery q = buildWorkflowNameQuery(workflowNamesToQuery);
    Set<String> localNamesToQuery = q.localNames;
    Set<String> namespacesToQuery = q.namespaces;

    for (ApexTypeImplementor impl : [
      SELECT ClassName, ClassNamespacePrefix
      FROM ApexTypeImplementor
      WHERE
        ClassName IN :localNamesToQuery
        AND ClassNamespacePrefix IN :namespacesToQuery
        AND InterfaceName IN (
          'WorkflowDefinition',
          'VersionedWorkflow',
          'ErrorRoutingWorkflow'
        )
      WITH SYSTEM_MODE
    ]) {
      String matchName = String.isBlank(impl.ClassNamespacePrefix)
        ? impl.ClassName
        : (impl.ClassNamespacePrefix + '.' + impl.ClassName);
      String matchLower = matchName.toLowerCase();
      validatedWorkflows.put(matchLower, true);

      if (q.rawNamesByResolved.containsKey(matchLower)) {
        for (String rawName : q.rawNamesByResolved.get(matchLower)) {
          validatedWorkflows.put(rawName.toLowerCase(), true);
        }
      }
    }
  }

  // Resolve each raw workflow name into the local-name/namespace candidates to
  // query, tracking which raw spellings map to each resolved class.
  private static WorkflowNameQuery buildWorkflowNameQuery(
    Set<String> workflowNamesToQuery
  ) {
    WorkflowNameQuery q = new WorkflowNameQuery();
    for (String rawName : workflowNamesToQuery) {
      Type resolved = WorkflowTypeResolver.resolve(
        rawName,
        WorkflowTypeResolver.extractNamespace(rawName)
      );
      String localName1 = rawName;
      String ns1 = '';
      String localName2 = rawName;
      String ns2 = '';
      if (resolved != null) {
        String fqName = String.valueOf(resolved);
        String resName = fqName.toLowerCase();
        if (!q.rawNamesByResolved.containsKey(resName)) {
          q.rawNamesByResolved.put(resName, new List<String>());
        }
        q.rawNamesByResolved.get(resName).add(rawName);

        if (fqName.contains('.')) {
          ns1 = fqName.substringBefore('.');
          localName1 = fqName.substringAfter('.');
          ns2 = '';
          localName2 = fqName;
        } else {
          localName1 = fqName;
          localName2 = fqName;
        }
      }
      q.localNames.add(localName1);
      q.localNames.add(localName2);
      q.namespaces.add(ns1);
      q.namespaces.add(ns2);
    }
    return q;
  }

  // §3: per request, dedup to an existing/intra-batch instance or queue a fresh
  // instance for insertion, populating run.toInsert / run.insertReqIndexes.
  private static void decideStartRequests(
    StartOrGetRun run,
    Map<String, Workflow_Instance__c> existingByKey
  ) {
    List<StartRequest> requests = run.requests;
    List<StartResult> results = run.results;
    for (Integer i = 0; i < requests.size(); i++) {
      results.add(null);
    }
    List<Workflow_Instance__c> toInsert = new List<Workflow_Instance__c>();
    List<Integer> insertReqIndexes = new List<Integer>();
    Set<String> newKeysInBatch = new Set<String>();

    for (Integer i = 0; i < requests.size(); i++) {
      StartRequest req = requests[i];
      if (req == null) {
        continue;
      }
      String key = req.correlationKey;
      String normKey = normalizeKey(key);

      if (String.isNotBlank(key) && existingByKey.containsKey(normKey)) {
        results[i] = new StartResult(existingByKey.get(normKey).Id);
        continue;
      }
      if (String.isNotBlank(key) && newKeysInBatch.contains(normKey)) {
        // Intra-batch duplicate; resolved to the sibling's Id after insert.
        continue;
      }

      toInsert.add(buildInstance(req));
      insertReqIndexes.add(i);
      if (String.isNotBlank(key)) {
        newKeysInBatch.add(normKey);
      }
    }
    run.toInsert = toInsert;
    run.insertReqIndexes = insertReqIndexes;
  }

  // §4a: insert the fresh instances, resolving new results and tolerating
  // per-row DUPLICATE_VALUE losers; a genuine failure deletes siblings + throws.
  private static void insertFreshInstances(StartOrGetRun run) {
    List<Workflow_Instance__c> toInsert = run.toInsert;
    if (toInsert.isEmpty()) {
      return;
    }
    Database.SaveResult[] saveResults = Database.insert(
      toInsert,
      false,
      AccessLevel.SYSTEM_MODE
    );
    String genuineError = null;
    for (Integer j = 0; j < saveResults.size(); j++) {
      String rowError = processStartInsertRow(run, saveResults[j], j);
      if (rowError != null && genuineError == null) {
        genuineError = rowError;
      }
    }
    // A genuine (non-duplicate) row failure restores all-or-none semantics:
    // delete every sibling row that succeeded in this partial insert (no
    // savepoint is spent on the all-success path) and surface the error so no
    // orphan Pending instances are left behind.
    if (genuineError != null) {
      if (!run.insertedInstances.isEmpty()) {
        Database.delete(run.insertedInstances, true, AccessLevel.SYSTEM_MODE);
      }
      throw new WorkflowException('Failed to start workflow: ' + genuineError);
    }
  }

  // Handle one insert save-result row: record a success/new result or a
  // concurrent DUPLICATE_VALUE loser key. Returns a genuine error message
  // (a non-duplicate failure, or a duplicate on a blank key) or null.
  private static String processStartInsertRow(
    StartOrGetRun run,
    Database.SaveResult sr,
    Integer j
  ) {
    Integer reqIdx = run.insertReqIndexes[j];
    if (sr.isSuccess()) {
      Workflow_Instance__c inst = run.toInsert[j];
      run.insertedInstances.add(inst);
      run.insertedReqIndexes.add(reqIdx);
      run.results[reqIdx] = new StartResult(inst.Id).markNew();
      return null;
    }
    Boolean isDup = isDuplicateSaveError(sr);
    String key = run.requests[reqIdx].correlationKey;
    if (isDup && String.isNotBlank(key)) {
      run.concurrentLoserKeys.add(key);
      return null;
    }
    return sr.getErrors()[0].getMessage();
  }

  // True when every error on the save result is a DUPLICATE_VALUE.
  private static Boolean isDuplicateSaveError(Database.SaveResult sr) {
    for (Database.Error err : sr.getErrors()) {
      if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
        return true;
      }
    }
    return false;
  }

  // §4b: insert search-attribute rows for the freshly inserted instances.
  private static void insertStartSearchAttributes(StartOrGetRun run) {
    if (run.insertedInstances.isEmpty()) {
      return;
    }
    List<Workflow_Search_Attribute__c> attrsToInsert = new List<Workflow_Search_Attribute__c>();
    for (Integer j = 0; j < run.insertedInstances.size(); j++) {
      StartRequest req = run.requests[run.insertedReqIndexes[j]];
      Workflow_Instance__c instance = run.insertedInstances[j];
      if (req.attributes != null && !req.attributes.isEmpty()) {
        for (String key : req.attributes.keySet()) {
          String val = req.attributes.get(key);
          attrsToInsert.add(
            new Workflow_Search_Attribute__c(
              Workflow_Instance__c = instance.Id,
              Key__c = key,
              Value__c = val,
              Key_Value__c = key + '=' + (val == null ? '' : val)
            )
          );
        }
      }
    }
    if (!attrsToInsert.isEmpty()) {
      Database.insert(attrsToInsert, true, AccessLevel.SYSTEM_MODE);
    }
  }

  // §5a: resolve remaining (intra-batch / concurrent-loser) results by key.
  private static void fillRemainingStartResults(StartOrGetRun run) {
    Map<String, Id> resolvedIdByKey = buildResolvedIdByKey(run);
    List<StartRequest> requests = run.requests;
    List<StartResult> results = run.results;
    for (Integer i = 0; i < requests.size(); i++) {
      if (requests[i] == null || results[i] != null) {
        continue;
      }
      String normKey = normalizeKey(requests[i].correlationKey);
      if (
        String.isNotBlank(requests[i].correlationKey) &&
        resolvedIdByKey.containsKey(normKey)
      ) {
        results[i] = new StartResult(resolvedIdByKey.get(normKey));
      }
    }
  }

  // Build the normalized-key -> Id map from inserted instances and any
  // concurrent winners located for DUPLICATE_VALUE loser keys.
  private static Map<String, Id> buildResolvedIdByKey(StartOrGetRun run) {
    Map<String, Id> resolvedIdByKey = new Map<String, Id>();
    for (Integer j = 0; j < run.insertedInstances.size(); j++) {
      String key = run.requests[run.insertedReqIndexes[j]].correlationKey;
      if (String.isNotBlank(key)) {
        resolvedIdByKey.put(normalizeKey(key), run.insertedInstances[j].Id);
      }
    }
    if (!run.concurrentLoserKeys.isEmpty()) {
      Map<String, Workflow_Instance__c> winners = findAnyByKey(
        run.concurrentLoserKeys
      );
      for (String normalized : winners.keySet()) {
        if (!resolvedIdByKey.containsKey(normalized)) {
          resolvedIdByKey.put(normalized, winners.get(normalized).Id);
        }
      }
    }
    return resolvedIdByKey;
  }

  // §5b safety net: a lingering unresolved (non-null) request would mean a
  // duplicate loser whose winner could not be found; roll back and surface it.
  private static void assertAllStartsResolved(StartOrGetRun run) {
    List<StartRequest> requests = run.requests;
    List<StartResult> results = run.results;
    List<String> unresolvedKeys = new List<String>();
    for (Integer i = 0; i < requests.size(); i++) {
      if (requests[i] == null) {
        continue;
      }
      if (results[i] == null) {
        unresolvedKeys.add(requests[i].correlationKey);
      }
    }

    if (unresolvedKeys.isEmpty()) {
      return;
    }
    if (!run.insertedInstances.isEmpty()) {
      Database.delete(run.insertedInstances, true, AccessLevel.SYSTEM_MODE);
    }
    throw new WorkflowException(
      'Failed to resolve workflow start for correlation key(s): ' +
      String.join(unresolvedKeys, ', ')
    );
  }

  // §6: resolve/persist input payloads for the freshly inserted instances.
  private static void resolveStartInputPayloads(StartOrGetRun run) {
    for (Integer j = 0; j < run.insertedInstances.size(); j++) {
      StartRequest req = run.requests[run.insertedReqIndexes[j]];
      Workflow_Instance__c instance = run.insertedInstances[j];
      String inputJson = (req.inputJson != null)
        ? req.inputJson
        : ((req.input != null) ? JSON.serialize(req.input) : null);
      instance.Input__c = savePayloadIfNeeded(
        instance.Id,
        inputJson,
        'Input_' + instance.Id
      );
    }
    if (!run.insertedInstances.isEmpty()) {
      Database.update(run.insertedInstances, true, AccessLevel.SYSTEM_MODE);
    }
  }

  // Operator pause gate (bulk path — used by scheduled jobs and the Flow
  // invocable): instances whose definition is paused are parked at start. They
  // get a Pending initial step with NO timeout clock and are excluded from
  // timeout scheduling and the initial enqueue, mirroring the scalar doStart.
  private static void applyStartPauseGate(StartOrGetRun run) {
    if (!WorkflowPauseGate.anyPaused()) {
      return;
    }
    for (Workflow_Instance__c instance : run.insertedInstances) {
      if (WorkflowPauseGate.isDefinitionPaused(instance.Workflow_Name__c)) {
        instance.Status__c = 'Paused';
        run.parkedIds.add(instance.Id);
        run.instancesToPark.add(instance);
      }
    }
  }

  // Concurrency-bounded workflows defer the initial timeout clock until the
  // admission gate wins a slot (mirrors doStart). A bounded first step is enqueued
  // so its RUN_STEP reaches the gate, but a still-Pending overflow item sitting in
  // the event/queue backlog during a burst would be failed by the timeout sweep
  // before it ever reaches the gate to park. Admission re-arms the timeout via
  // reArmTimeoutsForResume. isConfigured is memoized per name, so this is bulk-safe.
  private static void applyStartConcurrencyGate(StartOrGetRun run) {
    List<Workflow_Instance__c> deferredToMark = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c instance : run.insertedInstances) {
      if (ConcurrencyGate.isConfigured(instance.Workflow_Name__c)) {
        run.deferTimeoutIds.add(instance.Id);
        // Durable awaiting-admission marker (see doStart): the pre-start watchdog
        // keys its null-deadline skip off this, not the live CMDT, so a ceiling added
        // later cannot silence a genuine unbounded pre-start watchdog. Cleared on
        // admission. Parked-at-start instances are handled by instancesToPark below.
        if (!run.parkedIds.contains(instance.Id)) {
          deferredToMark.add(
            new Workflow_Instance__c(
              Id = instance.Id,
              Concurrency_Parked__c = true
            )
          );
        }
      }
    }
    if (!deferredToMark.isEmpty()) {
      Database.update(deferredToMark, true, AccessLevel.SYSTEM_MODE);
    }
  }

  // §7: construct initial Step Execution logs for the inserted instances.
  private static void buildInitialStepExecs(StartOrGetRun run) {
    List<Workflow_Step_Execution__c> stepExecs = new List<Workflow_Step_Execution__c>();
    for (Workflow_Instance__c instance : run.insertedInstances) {
      if (String.isBlank(instance.Current_Step__c)) {
        continue;
      }
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = instance.Current_Step__c;
      stepExec.Status__c = 'Pending';
      stepExec.Input__c = instance.Input__c;
      stepExec.Retry_Count__c = 0;
      // No timeout clock for a parked step (see doStart) or a bounded start awaiting
      // admission — either would otherwise pollute the watchdog timeout batch or fail
      // a still-Pending bounded start before admission. Resume/admission re-establishes it.
      if (
        !run.parkedIds.contains(instance.Id) &&
        !run.deferTimeoutIds.contains(instance.Id)
      ) {
        Integer timeout = getStepTimeoutSeconds(
          instance.Current_Step__c,
          WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
        );
        if (timeout != null && timeout > 0) {
          stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
        }
      }
      stepExecs.add(stepExec);
    }
    if (!stepExecs.isEmpty()) {
      Database.insert(stepExecs, true, AccessLevel.SYSTEM_MODE);
    }
  }

  // §8: schedule timeout jobs for non-parked, non-deferred instances and enqueue
  // orchestrators for all non-parked instances.
  private static void scheduleAndEnqueueStarts(StartOrGetRun run) {
    List<Workflow_Instance__c> instancesToSchedule = new List<Workflow_Instance__c>();
    List<Id> instanceIds = new List<Id>();
    for (Workflow_Instance__c instance : run.insertedInstances) {
      if (run.parkedIds.contains(instance.Id)) {
        continue;
      }
      instanceIds.add(instance.Id);
      if (!run.deferTimeoutIds.contains(instance.Id)) {
        instancesToSchedule.add(instance);
      }
    }
    if (!instancesToSchedule.isEmpty()) {
      scheduleTimeoutJobsForInstances(instancesToSchedule);
    }
    if (!instanceIds.isEmpty()) {
      enqueueOrchestrators(instanceIds);
    }
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
    return TERMINAL_GETSTATUS_STATUSES.contains(existingInst.Status__c) ||
      existingInst.Status__c == 'ContinuedAsNew';
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
      } else if (!isDuplicateSaveError(sr) && claimError == null) {
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
      } else if (!isDuplicateSaveError(sr) && genuineError == null) {
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
      enqueueOrchestrators(instanceIdsToEnqueue);
    }
    if (!parallelInstances.isEmpty()) {
      enqueueResumeBulk(parallelInstances);
    }
  }

  /**
   * Stores the resume payload on the instance's current active step (if any),
   * flipping it to Running and re-arming or clearing its watchdog deadline.
   * @param instance the resumed instance (Running)
   * @param payload the resume payload to persist on the active step
   */
  private static void applyResumePayloadToActiveStep(
    Workflow_Instance__c instance,
    String payload
  ) {
    if (String.isBlank(instance.Current_Step__c)) {
      return;
    }
    List<Workflow_Step_Execution__c> activeSteps = [
      SELECT Id, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :instance.Current_Step__c
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (activeSteps.isEmpty()) {
      return;
    }
    Workflow_Step_Execution__c stepExec = activeSteps[0];
    stepExec.Status__c = 'Running';
    stepExec.Output__c = savePayloadIfNeeded(
      instance.Id,
      payload,
      'Resume_' + stepExec.Id
    );
    Integer timeout = getStepTimeoutSeconds(
      instance.Current_Step__c,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    stepExec.Timeout_At__c = (timeout != null &&
      timeout > 0)
      ? DateTime.now().addSeconds(timeout)
      : null;
    Database.update(stepExec, true, AccessLevel.SYSTEM_MODE);
  }

  /**
   * Resumes a suspended workflow matching the correlation key.
   * @param correlationKey correlation key of the suspended instance
   * @param payload resume payload delivered to the waiting step
   */
  public static void resume(String correlationKey, String payload) {
    List<Workflow_Instance__c> instances = [
      SELECT Id, Workflow_Name__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :correlationKey AND Status__c = 'Suspended'
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];

    if (instances.isEmpty()) {
      throw new WorkflowException(
        'No suspended workflow found with correlation key: ' + correlationKey
      );
    }

    Workflow_Instance__c instance = instances[0];
    instance.Status__c = 'Running';
    // Disarm any armed timed-wait timeout so the watchdog does not mis-route to
    // the fallback step after a manual resume wins the race (issue #35).
    instance.Sleep_Until__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    // If there is an active step, we can store the resume payload in its step execution record
    applyResumePayloadToActiveStep(instance, payload);

    scheduleTimeoutJobForInstance(instance.Id);

    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(instance.Id));
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  /**
   * Resumes a suspended workflow instance directly by its database ID.
   * @param instanceId Id of the suspended instance
   * @param payload resume payload delivered to the waiting step
   */
  public static void resumeInstance(Id instanceId, String payload) {
    List<Workflow_Instance__c> instances = [
      SELECT Id, Workflow_Name__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId AND Status__c = 'Suspended'
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];

    if (instances.isEmpty()) {
      throw new WorkflowException(
        'No suspended workflow found with ID: ' + instanceId
      );
    }

    Workflow_Instance__c instance = instances[0];
    instance.Status__c = 'Running';
    // Disarm any armed timed-wait timeout so the watchdog does not mis-route to
    // the fallback step after a manual resume wins the race (issue #35).
    instance.Sleep_Until__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    // If there is an active step, we can store the resume payload in its step execution record
    applyResumePayloadToActiveStep(instance, payload);

    scheduleTimeoutJobForInstance(instance.Id);

    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(instance.Id));
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  /**
   * Resumes a suspended workflow instance by ID and step name.
   * @param instanceId Id of the suspended instance
   * @param stepName name of the waiting step to resume (advisory)
   * @param payload resume payload delivered to the waiting step
   */
  public static void resume(Id instanceId, String stepName, String payload) {
    resumeInstance(instanceId, payload);
  }

  /**
   * Lookup index of the suspended instances found for a batch of resume
   * requests, keyed by both Id and correlation key.
   */
  private class ResumeInstanceIndex {
    Map<Id, Workflow_Instance__c> instById = new Map<Id, Workflow_Instance__c>();
    Map<String, Workflow_Instance__c> instByKey = new Map<String, Workflow_Instance__c>();
  }

  /**
   * Accumulated instance and step-execution records to persist for a batch of
   * resume requests.
   */
  private class ResumeUpdates {
    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    List<Workflow_Step_Execution__c> stepsToUpdate = new List<Workflow_Step_Execution__c>();
  }

  /**
   * Collects the explicit instance ids referenced by the resume requests.
   * @param requests the resume requests
   * @return the set of non-null request instance ids
   */
  private static Set<Id> collectResumeIds(List<ResumeRequest> requests) {
    Set<Id> ids = new Set<Id>();
    for (ResumeRequest req : requests) {
      if (req.instanceId != null) {
        ids.add(req.instanceId);
      }
    }
    return ids;
  }

  /**
   * Collects the correlation keys referenced by the resume requests that do not
   * carry an explicit instance id.
   * @param requests the resume requests
   * @return the set of correlation keys used for lookup
   */
  private static Set<String> collectResumeKeys(List<ResumeRequest> requests) {
    Set<String> keys = new Set<String>();
    for (ResumeRequest req : requests) {
      if (req.instanceId == null && String.isNotBlank(req.correlationKey)) {
        keys.add(req.correlationKey);
      }
    }
    return keys;
  }

  /**
   * Builds the by-Id and by-correlation-key lookup index over the queried
   * suspended instances.
   * @param instances the suspended instances found for the batch
   * @return the populated lookup index
   */
  private static ResumeInstanceIndex buildResumeInstanceIndex(
    List<Workflow_Instance__c> instances
  ) {
    ResumeInstanceIndex index = new ResumeInstanceIndex();
    for (Workflow_Instance__c inst : instances) {
      index.instById.put(inst.Id, inst);
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        index.instByKey.put(inst.Correlation_Key__c, inst);
      }
    }
    return index;
  }

  /**
   * Resolves the suspended instance targeted by a resume request, preferring an
   * explicit instance id and falling back to the correlation key.
   * @param req the resume request
   * @param index the instance lookup index
   * @return the matching instance, or null when none was found
   */
  private static Workflow_Instance__c resolveResumeInstance(
    ResumeRequest req,
    ResumeInstanceIndex index
  ) {
    if (req.instanceId != null) {
      return index.instById.get(req.instanceId);
    }
    if (String.isNotBlank(req.correlationKey)) {
      return index.instByKey.get(req.correlationKey);
    }
    return null;
  }

  /**
   * Verifies that a suspended instance was found for every resume request,
   * throwing if any request cannot be satisfied.
   * @param requests the resume requests
   * @param index the instance lookup index
   */
  private static void verifyAllResumeTargetsFound(
    List<ResumeRequest> requests,
    ResumeInstanceIndex index
  ) {
    for (ResumeRequest req : requests) {
      Workflow_Instance__c inst = resolveResumeInstance(req, index);
      if (inst == null) {
        throw new WorkflowException(
          'No suspended workflow found with key or ID: ' +
          (req.instanceId != null
            ? (String) req.instanceId
            : req.correlationKey)
        );
      }
    }
  }

  /**
   * Tests whether a step name is (one of) the instance's current active step(s),
   * supporting comma-separated parallel branch step names.
   * @param inst the instance whose Current_Step__c is inspected
   * @param stepName the step execution's step name to test
   * @return true when the step name matches the instance's current step
   */
  private static Boolean stepMatchesCurrentStep(
    Workflow_Instance__c inst,
    String stepName
  ) {
    if (inst == null || String.isBlank(inst.Current_Step__c)) {
      return false;
    }
    if (inst.Current_Step__c.contains(',')) {
      for (String pStep : inst.Current_Step__c.split(',')) {
        if (pStep.trim() == stepName) {
          return true;
        }
      }
      return false;
    }
    return inst.Current_Step__c == stepName;
  }

  /**
   * Picks the latest active step execution per instance that matches the
   * instance's current step, from a list ordered newest-first.
   * @param allActiveSteps the instances' step executions, newest first
   * @param instById the instance lookup by id
   * @return the matching latest step execution per instance id
   */
  private static Map<Id, Workflow_Step_Execution__c> buildLatestStepByInstanceId(
    List<Workflow_Step_Execution__c> allActiveSteps,
    Map<Id, Workflow_Instance__c> instById
  ) {
    Map<Id, Workflow_Step_Execution__c> latestStepByInstanceId = new Map<Id, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c step : allActiveSteps) {
      if (!latestStepByInstanceId.containsKey(step.Workflow_Instance__c)) {
        Workflow_Instance__c inst = instById.get(step.Workflow_Instance__c);
        if (stepMatchesCurrentStep(inst, step.Step_Name__c)) {
          latestStepByInstanceId.put(step.Workflow_Instance__c, step);
        }
      }
    }
    return latestStepByInstanceId;
  }

  /**
   * Applies the resume mutation to a matched step execution: marks it Running,
   * persists the resume payload as its output, and (re)arms its step timeout.
   * @param stepExec the step execution to mutate
   * @param inst the owning instance (for id, current step and namespace)
   * @param payload the resume payload to persist
   */
  private static void applyResumeToStep(
    Workflow_Step_Execution__c stepExec,
    Workflow_Instance__c inst,
    String payload
  ) {
    stepExec.Status__c = 'Running';
    stepExec.Output__c = savePayloadIfNeeded(
      inst.Id,
      payload,
      'Resume_' + stepExec.Id
    );
    Integer timeout = getStepTimeoutSeconds(
      inst.Current_Step__c,
      WorkflowTypeResolver.extractNamespace(inst.Workflow_Name__c)
    );
    if (timeout != null && timeout > 0) {
      stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
    } else {
      stepExec.Timeout_At__c = null;
    }
  }

  /**
   * Builds the pending instance/step-execution mutations for a batch of resume
   * requests: each matched instance is flipped to Running with its timed-wait
   * disarmed, and its matched step execution (if any) is resumed.
   * @param requests the resume requests
   * @param index the instance lookup index
   * @param latestStepByInstanceId the matched latest step execution per instance
   * @return the accumulated records to update
   */
  private static ResumeUpdates buildResumeUpdates(
    List<ResumeRequest> requests,
    ResumeInstanceIndex index,
    Map<Id, Workflow_Step_Execution__c> latestStepByInstanceId
  ) {
    ResumeUpdates updates = new ResumeUpdates();
    for (ResumeRequest req : requests) {
      Workflow_Instance__c inst = resolveResumeInstance(req, index);
      if (inst == null) {
        continue;
      }
      inst.Status__c = 'Running';
      // Disarm any armed timed-wait timeout so the watchdog does not mis-route
      // to the fallback step after a manual resume wins the race (issue #35).
      inst.Sleep_Until__c = null;
      updates.instancesToUpdate.add(inst);

      Workflow_Step_Execution__c stepExec = latestStepByInstanceId.get(inst.Id);
      if (stepExec != null) {
        applyResumeToStep(stepExec, inst, req.payload);
        updates.stepsToUpdate.add(stepExec);
      }
    }
    return updates;
  }

  /**
   * Resumes multiple suspended workflows in a bulk-friendly transaction.
   * @param requests the resume requests to process
   */
  public static void resume(List<ResumeRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    Set<Id> ids = collectResumeIds(requests);
    Set<String> keys = collectResumeKeys(requests);

    List<Workflow_Instance__c> instances = [
      SELECT Id, Workflow_Name__c, Current_Step__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        (Id IN :ids
        OR Correlation_Key__c IN :keys)
        AND Status__c = 'Suspended'
      WITH SYSTEM_MODE
      FOR UPDATE
    ];

    ResumeInstanceIndex index = buildResumeInstanceIndex(instances);

    // Verify that we found a suspended instance for every request
    verifyAllResumeTargetsFound(requests, index);

    // Gathers active step execution logs for the instances in bulk
    Set<Id> activeInstIds = index.instById.keySet();
    List<Workflow_Step_Execution__c> allActiveSteps = [
      SELECT Id, Workflow_Instance__c, Step_Name__c, Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :activeInstIds
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    Map<Id, Workflow_Step_Execution__c> latestStepByInstanceId = buildLatestStepByInstanceId(
      allActiveSteps,
      index.instById
    );

    ResumeUpdates updates = buildResumeUpdates(
      requests,
      index,
      latestStepByInstanceId
    );

    Database.update(updates.instancesToUpdate, true, AccessLevel.SYSTEM_MODE);
    if (!updates.stepsToUpdate.isEmpty()) {
      Database.update(updates.stepsToUpdate, true, AccessLevel.SYSTEM_MODE);
    }

    scheduleTimeoutJobsForInstances(updates.instancesToUpdate);

    List<Id> instanceIds = new List<Id>();
    for (Workflow_Instance__c inst : updates.instancesToUpdate) {
      instanceIds.add(inst.Id);
    }
    enqueueOrchestrators(instanceIds);
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
      reArmTimeoutsForResume(new List<Workflow_Instance__c>{ instance });
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
    reArmTimeoutsForResume(new List<Workflow_Instance__c>{ instance });
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
    handleStepResult(outcome);
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
    String resolvedInput = resolvePayload(stepExec.Input__c);
    Boolean isTimeoutResume =
      String.isNotBlank(resolvedInput) &&
      resolvedInput.contains('$timeoutResume') &&
      'true'.equalsIgnoreCase(readJsonMapKey(resolvedInput, '$timeoutResume'));
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
      .previousStepOutput(resolvePayload(prevOutput))
      .stepStateJson(resolveStepStateJson(stepExec))
      .workflowInputJson(resolvePayload(instance.Input__c))
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
    String resolvedState = resolvePayload(stepExec.Output__c);
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
    String resolvedCaptures = resolvePayload(stepExec.Captured_Values__c);
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
      if (
        Test.isRunningTest() &&
        injectedFaults != null &&
        !injectedFaults.isEmpty()
      ) {
        result = checkAndInjectFault(
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
        cancelTimeoutJob(ctx.instanceId, ctx.activeStepName);
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
      List<String> resolvedPayloads = resolvePayloads(rawPayloads);

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
      List<String> resolvedPayloads = resolvePayloads(rawPayloads);
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
              resolvePayload(c.Payload__c)
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
          resolvePayload(cand.Payload__c)
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
        resolvePayload(records[0].Payload__c)
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
    List<String> resolvedPayloads = resolvePayloads(rawPayloads);

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
  private static void rollbackClaimedSignals(StepContext context) {
    if (context == null) {
      return;
    }
    Set<Id> claimedIds = context.getClaimedSignalIds();
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
    Set<String> matchedNames = orEmptyStrings(context.getConsumedSignalNames());
    Set<Id> matchedIds = orEmptyIds(context.getConsumedSignalIds());
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
   * The exact rows the step observed/claimed (context.getConsumedSignalIds())
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
    Set<Id> matchedIds = orEmptyIds(context.getConsumedSignalIds());
    Set<Id> claimedIds = orEmptyIds(context.getClaimedSignalIds());
    Set<String> matchedNames = orEmptyStrings(context.getConsumedSignalNames());
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
    if (!parallelBranch && !context.signalReadWasCapped()) {
      addDuplicateConsumable(instanceId, context, toConsume);
    }

    consumeSignals(toConsume);
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

  private static void saveStepExec(Workflow_Step_Execution__c stepExec) {
    saveStepExec(stepExec, false);
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
   * Publishes the union of the events a step buffered via ctx.emit() and those
   * handed to StepResult.complete(next, output, events), coupled to the step's
   * COMPLETE/SPLIT transition commit (issue #64). Called only from the COMPLETE
   * and SPLIT paths, in the same transaction as the Completed record write, so
   * a non-completing transition (retry/yield/suspend/rollback) publishes
   * nothing. Delegates the actual publish (with DML-budget guard and
   * fire-and-forget failure isolation) to WorkflowOutboundEventPublisher.
   * @param result step result whose complete(...) events are published
   * @param context step context whose buffered emit() events are published
   */
  private static void publishOutboundEvents(
    StepResult result,
    StepContext context
  ) {
    List<SObject> events = new List<SObject>();
    // Filter null entries from both sources: a null SObject in the EventBus
    // publish list throws before any per-row SaveResult, which the publisher then
    // swallows (fire-and-forget) — silently dropping every valid event in the
    // same batch. ctx.emit(null) is already ignored at the buffer; do the same
    // for the complete(..., events) overload, where an author may have built the
    // list conditionally.
    if (context != null) {
      addNonNullEvents(context.getPendingEmits(), events);
    }
    if (result != null) {
      addNonNullEvents(result.outboundEvents, events);
    }
    if (events.isEmpty()) {
      return;
    }
    WorkflowOutboundEventPublisher.publish(events);
  }

  /**
   * Appends the non-null entries of a source event list onto the publish list.
   * @param source the candidate events (may be null)
   * @param events the accumulating publish list
   */
  private static void addNonNullEvents(
    List<SObject> source,
    List<SObject> events
  ) {
    if (source == null) {
      return;
    }
    for (SObject e : source) {
      if (e != null) {
        events.add(e);
      }
    }
  }

  /**
   * @description Internal wrapper bundling the values threaded through the
   * step-outcome handlers (handleStepResult, handleCompensationStepResult,
   * persistStepBreadcrumbs) so each takes a single parameter instead of a long
   * positional list. Populated field-by-field to avoid a wide constructor.
   */
  private class StepOutcomeContext {
    private Workflow_Instance__c instance;
    private Workflow_Step_Execution__c stepExec;
    private StepResult result;
    private List<String> stack;
    private StepContext context;
    private Boolean isParallel;
  }

  private static void handleStepResult(StepOutcomeContext outcome) {
    persistStepBreadcrumbs(outcome);
    // Re-query to avoid overwriting a timeout or finalizer crash status and race conditions
    Workflow_Instance__c freshInstance = [
      SELECT
        Id,
        Status__c,
        Current_Step__c,
        Compensation_Stack__c,
        Output__c,
        Parent_Instance__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Input__c,
        Definition_Version__c,
        Previous_Run_At__c,
        Concurrency_Parked__c,
        Concurrency_Slot_Held__c,
        CreatedDate,
        Progress__c,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :outcome.instance.Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (!prepareStepOutcome(outcome, freshInstance)) {
      return;
    }
    dispatchStepOutcome(outcome);
  }

  // Prepare the freshly-locked instance for the outcome dispatch. Returns false
  // when this is a stale completion that must be ignored (already handled).
  private static Boolean prepareStepOutcome(
    StepOutcomeContext outcome,
    Workflow_Instance__c freshInstance
  ) {
    if (isStaleCompletion(outcome, freshInstance)) {
      return false;
    }
    applyProgressUpdate(outcome, freshInstance);
    restoreBlankCurrentStep(outcome, freshInstance);
    assertInstanceRunnable(freshInstance);
    outcome.instance = freshInstance;
    resetTransientRetryCounter(outcome.stepExec);
    outcome.isParallel =
      String.isNotBlank(freshInstance.Current_Step__c) &&
      freshInstance.Current_Step__c.contains(',');
    persistNewCaptures(outcome);
    return true;
  }

  // Verify the completing step is still active in the current step list. If not,
  // roll back its claimed signals, cancel a still-Running exec, and report stale.
  private static Boolean isStaleCompletion(
    StepOutcomeContext outcome,
    Workflow_Instance__c freshInstance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    Boolean stepIsActive = false;
    if (String.isNotBlank(freshInstance.Current_Step__c) && stepExec != null) {
      for (String activeStep : freshInstance.Current_Step__c.split(',')) {
        if (activeStep.trim() == stepExec.Step_Name__c) {
          stepIsActive = true;
          break;
        }
      }
    }
    if (stepIsActive) {
      return false;
    }
    rollbackClaimedSignals(outcome.context);
    if (
      stepExec != null &&
      stepExec.Id != null &&
      stepExec.Status__c == 'Running'
    ) {
      stepExec.Status__c = 'Cancelled';
      Database.update(stepExec, true, AccessLevel.SYSTEM_MODE);
    }
    return true;
  }

  // Persist reported progress onto the fresh instance before dispatch.
  private static void applyProgressUpdate(
    StepOutcomeContext outcome,
    Workflow_Instance__c freshInstance
  ) {
    StepContext context = outcome.context;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    if (context != null && context.isProgressReported()) {
      String progJson = context.getProgressJson();
      freshInstance.Progress__c = savePayloadIfNeeded(
        freshInstance.Id,
        progJson,
        'Progress_' +
        (stepExec != null && String.isNotBlank(stepExec.Step_Name__c)
          ? stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
          : 'Default')
      );
    }
  }

  // Restore a blanked current step from the pre-drive instance snapshot.
  private static void restoreBlankCurrentStep(
    StepOutcomeContext outcome,
    Workflow_Instance__c freshInstance
  ) {
    Workflow_Instance__c instance = outcome.instance;
    if (
      String.isBlank(freshInstance.Current_Step__c) &&
      String.isNotBlank(instance.Current_Step__c)
    ) {
      freshInstance.Current_Step__c = instance.Current_Step__c;
    }
  }

  // Guard against a terminal/compensating instance and flip Pending/Suspended to
  // Running so the outcome dispatch always sees a runnable instance.
  private static void assertInstanceRunnable(
    Workflow_Instance__c freshInstance
  ) {
    if (isTerminalOrTransitioningStatus(freshInstance.Status__c)) {
      throw new WorkflowException(
        'Workflow execution was terminated, cancelled, is compensating, or was continued as new.'
      );
    }
    if (
      freshInstance.Status__c == 'Pending' ||
      freshInstance.Status__c == 'Suspended'
    ) {
      freshInstance.Status__c = 'Running';
    }
  }

  // True when a status is terminal, compensating, cancelling, or continued-as-new.
  private static Boolean isTerminalOrTransitioningStatus(String status) {
    return status == 'Failed' ||
      status == 'Compensating' ||
      status == 'Compensated' ||
      status == 'CompensationFailed' ||
      status == 'Cancelled' ||
      status == 'Cancelling' ||
      status == 'ContinuedAsNew';
  }

  // Reaching handleStepResult means the instance lock cleared, so reset the
  // consecutive transient-retry counter on the step.
  private static void resetTransientRetryCounter(
    Workflow_Step_Execution__c stepExec
  ) {
    if (
      stepExec != null &&
      stepExec.Id != null &&
      stepExec.Transient_Retry_Count__c != null &&
      stepExec.Transient_Retry_Count__c > 0
    ) {
      // Targeted single-field update so this early reset never persists any other
      // in-memory staging the outcome branches below have yet to commit.
      Database.update(
        new Workflow_Step_Execution__c(
          Id = stepExec.Id,
          Transient_Retry_Count__c = 0
        ),
        true,
        AccessLevel.SYSTEM_MODE
      );
      stepExec.Transient_Retry_Count__c = 0;
    }
  }

  // Persist capture-once values produced during this execution (once, before the
  // action dispatch, so every outcome durably records new captures).
  private static void persistNewCaptures(StepOutcomeContext outcome) {
    StepContext context = outcome.context;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    Workflow_Instance__c instance = outcome.instance;
    if (context.hasNewCaptures()) {
      String capturedJson = context.getCapturedValuesJson();
      stepExec.Captured_Values__c = savePayloadIfNeeded(
        instance.Id,
        capturedJson,
        'Captures_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
    }
  }

  // Dispatch the step outcome to the matching action handler.
  private static void dispatchStepOutcome(StepOutcomeContext outcome) {
    if (dispatchTerminalOrAdvanceOutcome(outcome)) {
      return;
    }
    dispatchSuspendingOutcome(outcome);
  }

  // Handlers that advance, split, retry, continue-as-new, or terminally fail the
  // instance. Returns true when the action was handled here.
  private static Boolean dispatchTerminalOrAdvanceOutcome(
    StepOutcomeContext outcome
  ) {
    StepResult.ActionType action = outcome.result.action;
    if (action == StepResult.ActionType.COMPLETE) {
      handleCompleteOutcome(outcome);
      return true;
    }
    if (action == StepResult.ActionType.SPLIT) {
      handleSplitOutcome(outcome);
      return true;
    }
    if (action == StepResult.ActionType.RETRY) {
      handleRetryOutcome(outcome);
      return true;
    }
    if (action == StepResult.ActionType.CONTINUE_AS_NEW) {
      handleContinueAsNewOutcome(outcome);
      return true;
    }
    if (action == StepResult.ActionType.FAIL) {
      handleFailOutcome(outcome);
      return true;
    }
    return false;
  }

  // Handlers that suspend the instance awaiting an external event.
  private static void dispatchSuspendingOutcome(StepOutcomeContext outcome) {
    StepResult.ActionType action = outcome.result.action;
    if (action == StepResult.ActionType.YIELD) {
      handleYieldOutcome(outcome);
    } else if (action == StepResult.ActionType.SUSPEND) {
      handleSuspendOutcome(outcome);
    } else if (action == StepResult.ActionType.SLEEP) {
      handleSleepOutcome(outcome);
    } else if (action == StepResult.ActionType.START_CHILD) {
      handleStartChildOutcome(outcome);
    } else if (action == StepResult.ActionType.START_CHILDREN) {
      handleStartChildrenOutcome(outcome);
    } else if (action == StepResult.ActionType.WAIT_FOR_APPROVAL) {
      handleWaitForApprovalOutcome(outcome);
    }
  }

  // COMPLETE: durably complete the step and advance (serial) or join (parallel).
  private static void handleCompleteOutcome(StepOutcomeContext outcome) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    // Step is complete. Store output.
    stepExec.Status__c = 'Completed';
    stepExec.Output__c = savePayloadIfNeeded(
      instance.Id,
      result.outputJson,
      'Output_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    saveStepExec(stepExec);

    // Tie signal consumption to the step's durable COMPLETE transition: only
    // now (not on yield/retry/suspend) are the signals this step observed
    // marked consumed, so an at-least-once redelivered duplicate cannot be
    // reprocessed by a later step. A parallel branch consumes only its own
    // claimed ids so it cannot strip a sibling branch's signal.
    markSignalsConsumed(instance.Id, context, isParallel);

    // Effectively-once outbound emit (issue #64): the step's buffered domain
    // events publish here, in the same transaction that just wrote the
    // Completed record and before the next step's RUN_STEP event is enqueued.
    // Anything buffered on a yield/retry/suspend re-execution was discarded
    // with that context, so a re-run before this commit publishes nothing.
    publishOutboundEvents(result, context);

    updateCompensationStackIfNeeded(instance, stepExec);

    if (!isParallel) {
      advanceSerialStep(outcome);
      return;
    }

    completeParallelBranch(outcome);
  }

  // Push the just-completed step onto the compensation stack when it is a
  // CompensatableStep, persisting the updated stack immediately.
  private static void updateCompensationStackIfNeeded(
    Workflow_Instance__c instance,
    Workflow_Step_Execution__c stepExec
  ) {
    Type stepType = WorkflowTypeResolver.resolve(
      stepExec.Step_Name__c,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    if (stepType == null) {
      return;
    }
    Object stepInstanceObj = stepType.newInstance();
    if (!(stepInstanceObj instanceof CompensatableStep)) {
      return;
    }
    List<String> stack = new List<String>();
    if (String.isNotBlank(instance.Compensation_Stack__c)) {
      stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
    }
    stack.add(stepExec.Step_Name__c);
    instance.Compensation_Stack__c = JSON.serialize(stack);
    // If not parallel or if parallel and not all done, update here so stack is saved.
    // (Parallel allDone paths will update instance later, but doing a single update here is safe).
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
  }

  // Serial COMPLETE: resolve the next step and either finish the workflow or
  // advance to the next step.
  private static void advanceSerialStep(StepOutcomeContext outcome) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;

    String nextStepName = resolveNextStepName(
      instance,
      instance.Current_Step__c,
      result
    );

    if (String.isBlank(nextStepName)) {
      // Workflow is finished
      completeWorkflowInstance(instance, result.outputJson, 'Output_Final');
      return;
    }

    // Advance to next step
    instance.Current_Step__c = nextStepName;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    Workflow_Step_Execution__c nextStepExec = new Workflow_Step_Execution__c();
    nextStepExec.Workflow_Instance__c = instance.Id;
    nextStepExec.Step_Name__c = nextStepName;
    nextStepExec.Status__c = 'Pending';
    nextStepExec.Input__c = stepExec.Output__c;
    nextStepExec.Retry_Count__c = 0;
    Database.insert(nextStepExec, true, AccessLevel.SYSTEM_MODE);

    // Pass the in-memory instance (Current_Step__c just advanced to nextStepName,
    // committed above) so the per-advance watchdog scheduling does not re-query the
    // instance on every step — that re-read is what exhausts the SOQL limit on a
    // long synchronous drive.
    scheduleTimeoutJobForInstance(instance);
    enqueueOrchestrator(instance.Id, null);
  }

  // Resolve the workflow definition class for an instance, throwing when it
  // cannot be resolved.
  private static WorkflowDefinition resolveWorkflowDefinition(
    Workflow_Instance__c instance
  ) {
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
    return (WorkflowDefinition) wflowType.newInstance();
  }

  // Resolve the next step name, honoring VersionedWorkflow when applicable.
  private static String resolveNextStepName(
    Workflow_Instance__c instance,
    String currentStepArg,
    StepResult result
  ) {
    WorkflowDefinition def = resolveWorkflowDefinition(instance);
    if (def instanceof VersionedWorkflow) {
      return ((VersionedWorkflow) def)
        .getNextStep(
          currentStepArg,
          result,
          instance.Definition_Version__c != null
            ? (Integer) instance.Definition_Version__c
            : 1
        );
    }
    return def.getNextStep(currentStepArg, result);
  }

  // Terminal completion of a workflow instance: store final output, clear the
  // current step, notify the parent, and publish the lifecycle event.
  private static void completeWorkflowInstance(
    Workflow_Instance__c instance,
    String outputJson,
    String payloadLabel
  ) {
    instance.Status__c = 'Completed';
    instance.Output__c = savePayloadIfNeeded(
      instance.Id,
      outputJson,
      payloadLabel
    );
    instance.Current_Step__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    // Parent notification publishes the load-bearing Workflow_Event__e, so it
    // runs BEFORE the best-effort lifecycle publish (first claim on DML budget).
    notifyParentCompletion(instance);

    // Fire-and-forget outbound lifecycle event on terminal transition.
    WorkflowLifecyclePublisher.publish(instance);
  }

  // Parallel COMPLETE: when a branch finishes, either mark the instance
  // suspended/failed (not all done) or proceed to the join step.
  private static void completeParallelBranch(StepOutcomeContext outcome) {
    Workflow_Instance__c instance = outcome.instance;
    List<String> activeParallelSteps = instance.Current_Step__c.split(',');
    Map<String, Workflow_Step_Execution__c> latestExecByStep = loadLatestParallelExecs(
      instance.Id,
      activeParallelSteps
    );

    if (!isAllParallelDone(activeParallelSteps, latestExecByStep)) {
      applyIncompleteParallelStatus(
        instance,
        activeParallelSteps,
        latestExecByStep
      );
      return;
    }

    proceedToJoin(outcome, activeParallelSteps, latestExecByStep);
  }

  // Load the latest step execution per active parallel step.
  private static Map<String, Workflow_Step_Execution__c> loadLatestParallelExecs(
    Id instanceId,
    List<String> activeParallelSteps
  ) {
    List<Workflow_Step_Execution__c> parallelExecs = [
      SELECT Step_Name__c, Status__c, Output__c, CPU_Time_Ms__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c IN :activeParallelSteps
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    Map<String, Workflow_Step_Execution__c> latestExecByStep = new Map<String, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c pe : parallelExecs) {
      if (!latestExecByStep.containsKey(pe.Step_Name__c)) {
        latestExecByStep.put(pe.Step_Name__c, pe);
      }
    }
    return latestExecByStep;
  }

  // True when every active parallel branch is Completed or OperatorSkipped.
  private static Boolean isAllParallelDone(
    List<String> activeParallelSteps,
    Map<String, Workflow_Step_Execution__c> latestExecByStep
  ) {
    for (String ps : activeParallelSteps) {
      Workflow_Step_Execution__c pe = latestExecByStep.get(ps);
      if (
        pe == null ||
        (pe.Status__c != 'Completed' &&
        pe.Status__c != 'OperatorSkipped')
      ) {
        return false;
      }
    }
    return true;
  }

  // Not-all-done parallel branches: suspend when only pending work remains, or
  // fail when the only non-done branches failed.
  private static void applyIncompleteParallelStatus(
    Workflow_Instance__c instance,
    List<String> activeParallelSteps,
    Map<String, Workflow_Step_Execution__c> latestExecByStep
  ) {
    String verdict = classifyIncompleteParallel(
      activeParallelSteps,
      latestExecByStep
    );
    if (verdict == 'SUSPEND') {
      instance.Status__c = 'Suspended';
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    } else if (verdict == 'FAIL') {
      instance.Status__c = 'Failed';
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    }
  }

  // Classify the not-all-done branch set as SUSPEND, FAIL, or NONE.
  private static String classifyIncompleteParallel(
    List<String> activeParallelSteps,
    Map<String, Workflow_Step_Execution__c> latestExecByStep
  ) {
    Boolean hasPending = false;
    Boolean hasRunning = false;
    Boolean hasFailed = false;
    for (String ps : activeParallelSteps) {
      String cat = parallelBranchCategory(latestExecByStep.get(ps));
      if (cat == 'RUNNING') {
        hasRunning = true;
      } else if (cat == 'FAILED') {
        hasFailed = true;
      } else if (cat == 'PENDING') {
        hasPending = true;
      }
    }
    return parallelVerdict(hasPending, hasRunning, hasFailed);
  }

  // Category of a single parallel branch's latest execution.
  private static String parallelBranchCategory(Workflow_Step_Execution__c pe) {
    if (pe == null) {
      return 'RUNNING';
    }
    if (pe.Status__c == 'Running') {
      return 'RUNNING';
    }
    if (pe.Status__c == 'Failed') {
      return 'FAILED';
    }
    if (pe.Status__c == 'Retrying') {
      return 'PENDING';
    }
    if (pe.Status__c == 'Pending') {
      return pe.CPU_Time_Ms__c != null ? 'PENDING' : 'RUNNING';
    }
    return 'NONE';
  }

  // Overall verdict for a not-all-done parallel branch set.
  private static String parallelVerdict(
    Boolean hasPending,
    Boolean hasRunning,
    Boolean hasFailed
  ) {
    if (hasPending && !hasRunning) {
      return 'SUSPEND';
    }
    if (!hasPending && !hasRunning && hasFailed) {
      return 'FAIL';
    }
    return 'NONE';
  }

  // All parallel branches done: resolve the join step and either finish the
  // workflow or create the join step execution.
  private static void proceedToJoin(
    StepOutcomeContext outcome,
    List<String> activeParallelSteps,
    Map<String, Workflow_Step_Execution__c> latestExecByStep
  ) {
    Workflow_Instance__c instance = outcome.instance;

    // All parallel steps completed. Proceed to Join step.
    List<Workflow_Step_Execution__c> spawningSteps = [
      SELECT Step_Name__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Status__c IN ('Completed', 'OperatorSkipped')
        AND Step_Name__c NOT IN :activeParallelSteps
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];

    String spawningStepName = !spawningSteps.isEmpty()
      ? spawningSteps[0].Step_Name__c
      : '';
    StepResult mockResult = StepResult.complete(
      null,
      !spawningSteps.isEmpty() ? spawningSteps[0].Output__c : null
    );

    String nextStepName = resolveNextStepName(
      instance,
      spawningStepName,
      mockResult
    );

    String joinInputJson = JSON.serialize(
      buildJoinInput(activeParallelSteps, latestExecByStep)
    );

    if (String.isBlank(nextStepName)) {
      completeWorkflowInstance(instance, joinInputJson, 'Output_Join');
      return;
    }

    createJoinStep(instance, nextStepName, joinInputJson);
  }

  // Assemble the join step's input map from each branch's resolved output.
  private static Map<String, Object> buildJoinInput(
    List<String> activeParallelSteps,
    Map<String, Workflow_Step_Execution__c> latestExecByStep
  ) {
    Map<String, Object> joinInput = new Map<String, Object>();
    for (String ps : activeParallelSteps) {
      Workflow_Step_Execution__c pe = latestExecByStep.get(ps);
      if (pe == null) {
        continue;
      }
      Object outputVal = null;
      String resolvedOutput = resolvePayload(pe.Output__c);
      if (String.isNotBlank(resolvedOutput)) {
        try {
          outputVal = JSON.deserializeUntyped(resolvedOutput);
        } catch (Exception ignored) {
          // Output was not JSON; fall back to the raw string value.
          outputVal = resolvedOutput;
        }
      }
      joinInput.put(ps, outputVal);
    }
    return joinInput;
  }

  // Create the join step execution and advance the instance to it.
  private static void createJoinStep(
    Workflow_Instance__c instance,
    String nextStepName,
    String joinInputJson
  ) {
    Workflow_Step_Execution__c joinStepExec = new Workflow_Step_Execution__c();
    joinStepExec.Workflow_Instance__c = instance.Id;
    joinStepExec.Step_Name__c = nextStepName;
    joinStepExec.Status__c = 'Pending';
    joinStepExec.Input__c = savePayloadIfNeeded(
      instance.Id,
      joinInputJson,
      'Input_' + nextStepName.replaceAll('[^a-zA-Z0-9]', '_')
    );
    joinStepExec.Retry_Count__c = 0;
    Database.insert(joinStepExec, true, AccessLevel.SYSTEM_MODE);

    instance.Current_Step__c = nextStepName;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    scheduleTimeoutJobForInstance(instance.Id);
    enqueueOrchestrator(instance.Id, null);
  }

  // YIELD: save state to Output and re-run in a new transaction.
  private static void handleYieldOutcome(StepOutcomeContext outcome) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    // Step yielded (e.g. Apex Cursor chunk). Save state to Output and run again in a new transaction.
    if (isParallel) {
      rollbackClaimedSignals(context);
    }
    stepExec.Status__c = 'Running';
    stepExec.Output__c = savePayloadIfNeeded(
      instance.Id,
      result.stepStateJson,
      'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    saveStepExec(stepExec);

    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    scheduleTimeoutJobForInstance(instance.Id);
    enqueueOrchestrator(instance.Id, null);
  }

  // SUSPEND: save state and suspend awaiting an external signal.
  private static void handleSuspendOutcome(StepOutcomeContext outcome) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    // Step suspended (waiting for external signal). Save state and mark instance.
    if (isParallel) {
      rollbackClaimedSignals(context);
    }
    stepExec.Status__c = 'Pending';
    String suspendStateJson;
    if (String.isNotBlank(result.timeoutStep)) {
      // Timed suspend (issue #35): persist the fallback step in a reserved key
      // so the watchdog can route to it when the deadline elapses.
      suspendStateJson = JSON.serialize(
        new Map<String, Object>{ '$timeoutStep' => result.timeoutStep }
      );
      instance.Sleep_Until__c = DateTime.now()
        .addSeconds(result.timeoutSeconds);
    } else {
      // Explicit stepStateJson is preserved; no-arg suspend() nulls Output__c so
      // stale yield checkpoints from a prior YIELD in the same execution don't
      // survive into a retry and cause duplicate-spawn collisions.
      suspendStateJson = result.stepStateJson;
      // A plain (deadline-less) suspend must not inherit a stale timer left by
      // an earlier timed wait or a manual resume, or the watchdog would wake it
      // early. Reset the deadline defensively (issue #35).
      instance.Sleep_Until__c = null;
    }
    stepExec.Output__c = String.isNotBlank(suspendStateJson)
      ? savePayloadIfNeeded(
          instance.Id,
          suspendStateJson,
          'State_Suspend_' +
          stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
        )
      : null;
    saveStepExec(stepExec);

    instance.Status__c = 'Suspended';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    redeliverMatchingSignalsForInstance(
      instance.Id,
      instance.Correlation_Key__c
    );
  }

  // SLEEP: suspend until the requested sleep deadline.
  private static void handleSleepOutcome(StepOutcomeContext outcome) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    // Step requested sleep
    if (isParallel) {
      rollbackClaimedSignals(context);
    }
    stepExec.Status__c = 'Pending';
    stepExec.Output__c = savePayloadIfNeeded(
      instance.Id,
      result.stepStateJson,
      'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    saveStepExec(stepExec);

    instance.Status__c = 'Suspended';
    instance.Sleep_Until__c = DateTime.now()
      .addSeconds(result.sleepDurationSeconds);
    instance.Async_Job_Id__c = scheduleSleepResume(
      instance.Id,
      stepExec.Step_Name__c,
      result.sleepDurationSeconds
    );
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
  }

  // START_CHILD: suspend and start a single child workflow.
  private static void handleStartChildOutcome(StepOutcomeContext outcome) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    // Step requested child workflow.
    //
    // Observed signals are intentionally NOT consumed here. START_CHILD
    // suspends and re-runs the SAME step when the child completes (like
    // SUSPEND/WAIT_FOR_APPROVAL), rather than transitioning forward like
    // COMPLETE/SPLIT. Consuming on this path would break a step that re-reads
    // its kickoff signal on resume to confirm it is still in the active flow.
    // A START_CHILD step should therefore check the child-completion signal
    // before re-acting on a kickoff signal (or stash needed data in step state).
    if (isParallel) {
      rollbackClaimedSignals(context);
    }
    stepExec.Status__c = 'Pending';
    Map<String, Object> childInfo = new Map<String, Object>{
      'childWorkflowName' => result.childWorkflowName,
      'childCorrelationKey' => result.childCorrelationKey
    };
    stepExec.Output__c = savePayloadIfNeeded(
      instance.Id,
      JSON.serialize(childInfo),
      'State_ChildInfo_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    saveStepExec(stepExec);

    instance.Status__c = 'Suspended';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    redeliverMatchingSignalsForInstance(
      instance.Id,
      instance.Correlation_Key__c
    );

    ChildWorkflowStartRequest childReq = new ChildWorkflowStartRequest();
    childReq.parentId = instance.Id;
    childReq.workflowName = result.childWorkflowName;
    childReq.correlationKey = result.childCorrelationKey;
    childReq.inputJson = result.childInputJson;
    startChildWorkflow(childReq);
  }

  // START_CHILDREN: suspend and start multiple child workflows.
  private static void handleStartChildrenOutcome(StepOutcomeContext outcome) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    if (result.childRequests == null || result.childRequests.isEmpty()) {
      throw new WorkflowException(
        'START_CHILDREN action requires at least one child request.'
      );
    }
    if (isParallel) {
      rollbackClaimedSignals(context);
    }
    stepExec.Status__c = 'Pending';
    List<String> childKeys = new List<String>();
    for (StepResult.ChildRequest req : result.childRequests) {
      childKeys.add(req.correlationKey);
    }
    Map<String, Object> state = new Map<String, Object>{
      'childCorrelationKeys' => childKeys
    };
    stepExec.Output__c = savePayloadIfNeeded(
      instance.Id,
      JSON.serialize(state),
      'State_ChildKeys_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    saveStepExec(stepExec);

    instance.Status__c = 'Suspended';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    redeliverMatchingSignalsForInstance(
      instance.Id,
      instance.Correlation_Key__c
    );

    startChildWorkflows(instance.Id, result.childRequests);
  }

  // WAIT_FOR_APPROVAL: suspend awaiting an approval signal.
  private static void handleWaitForApprovalOutcome(StepOutcomeContext outcome) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    if (isParallel) {
      rollbackClaimedSignals(context);
    }
    stepExec.Status__c = 'Pending';
    Map<String, Object> state = new Map<String, Object>{
      'waitingForApproval' => true,
      'approvalKey' => result.approvalKey,
      'approvalRole' => result.approvalRole
    };
    if (String.isNotBlank(result.timeoutStep)) {
      // Timed approval (issue #35): add fallback step so watchdog can route.
      state.put('$timeoutStep', result.timeoutStep);
      instance.Sleep_Until__c = DateTime.now()
        .addSeconds(result.timeoutSeconds);
    } else {
      // A deadline-less approval wait must not inherit a stale timer left by an
      // earlier timed wait or a manual resume (issue #35).
      instance.Sleep_Until__c = null;
    }
    stepExec.Output__c = savePayloadIfNeeded(
      instance.Id,
      JSON.serialize(state),
      'State_Approval_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    saveStepExec(stepExec);

    instance.Status__c = 'Suspended';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    redeliverMatchingSignalsForInstance(
      instance.Id,
      instance.Correlation_Key__c
    );
  }

  // SPLIT: complete the spawning step and fan out parallel branches.
  private static void handleSplitOutcome(StepOutcomeContext outcome) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    stepExec.Status__c = 'Completed';
    stepExec.Output__c = savePayloadIfNeeded(
      instance.Id,
      result.parallelInputJson != null
        ? result.parallelInputJson
        : result.outputJson,
      'Output_Split_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    saveStepExec(stepExec);

    // The spawning step durably completed; consume the signals it observed so
    // they are not re-loaded into the parallel branches it fans out to. The
    // spawning step runs serially (it is the fan-out point, not a branch) and
    // does not claim, so it consumes still-Received rows plus same-name
    // duplicate cleanup.
    markSignalsConsumed(instance.Id, context, false);

    String parallelStepsStr = String.join(result.parallelStepNames, ',');
    instance.Current_Step__c = parallelStepsStr;
    instance.Status__c = 'Running';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    List<Workflow_Step_Execution__c> parallelExecs = new List<Workflow_Step_Execution__c>();
    for (String ps : result.parallelStepNames) {
      Workflow_Step_Execution__c pe = new Workflow_Step_Execution__c();
      pe.Workflow_Instance__c = instance.Id;
      pe.Step_Name__c = ps;
      pe.Status__c = 'Pending';
      pe.Input__c = savePayloadIfNeeded(
        instance.Id,
        result.parallelInputJson != null
          ? result.parallelInputJson
          : stepExec.Output__c,
        'Input_Parallel_' + ps.replaceAll('[^a-zA-Z0-9]', '_')
      );
      pe.Retry_Count__c = 0;
      Integer timeout = getStepTimeoutSeconds(
        ps,
        WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
      );
      if (timeout != null && timeout > 0) {
        pe.Timeout_At__c = DateTime.now().addSeconds(timeout);
      }
      parallelExecs.add(pe);
    }
    Database.insert(parallelExecs, true, AccessLevel.SYSTEM_MODE);

    scheduleTimeoutJobForInstance(instance.Id);
    for (String ps : result.parallelStepNames) {
      enqueueOrchestrator(instance.Id, ps);
    }

    // Effectively-once outbound emit (issue #64): publish AFTER the SPLIT's
    // required durable DML — the instance update, the branch-execution inserts,
    // and the per-branch enqueueOrchestrator hand-offs (which scale with the
    // fan-out). Publishing here means the best-effort emit can never consume the
    // DML budget those writes need and roll back the SPLIT commit. The events
    // still ride this same transaction, so a rollback anywhere above publishes
    // nothing, and they remain part of the SPLIT commit that gates the branches.
    publishOutboundEvents(result, context);
  }

  // RETRY: apply backoff, or fail the instance when retries are exhausted.
  private static void handleRetryOutcome(StepOutcomeContext outcome) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    // Step requested retry
    if (isParallel) {
      rollbackClaimedSignals(context);
    }
    stepExec.Retry_Count__c += 1;

    // Get and sanitize retry policy
    RetryPolicy policy = sanitizePolicy(result.retryPolicy);

    Map<String, Object> captures = new Map<String, Object>();
    if (String.isNotBlank(stepExec.Captured_Values__c)) {
      String resolvedCaptures = resolvePayload(stepExec.Captured_Values__c);
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
    stepExec.Captured_Values__c = savePayloadIfNeeded(
      instance.Id,
      JSON.serialize(captures),
      'Captures_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );

    if (stepExec.Retry_Count__c >= policy.maximumAttempts) {
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c =
        'Max retries (' +
        policy.maximumAttempts +
        ') exceeded.';
      saveStepExec(stepExec);

      FailInstanceRequest maxRetriesReq = new FailInstanceRequest();
      maxRetriesReq.instanceId = instance.Id;
      maxRetriesReq.stepName = instance.Current_Step__c;
      maxRetriesReq.errorMessage = 'Max retries exceeded.';
      maxRetriesReq.failureCategory = CAT_RETRIES_EXHAUSTED;
      failWorkflowInstance(maxRetriesReq);
    } else {
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
      instance.Async_Job_Id__c = scheduleRetry(
        instance.Id,
        stepExec.Step_Name__c,
        delay
      );
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    }
  }

  // CONTINUE_AS_NEW: finish this instance and spawn a successor.
  private static void handleContinueAsNewOutcome(StepOutcomeContext outcome) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    if (isParallel) {
      rollbackClaimedSignals(context);
    }
    stepExec.Status__c = 'ContinuedAsNew';
    stepExec.Output__c = savePayloadIfNeeded(
      instance.Id,
      result.nextInputJson,
      'ContinueInput_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    saveStepExec(stepExec);

    // Resolve the new correlation key
    String newKey = resolveContinueAsNewKey(
      instance.Correlation_Key__c,
      result.newCorrelationKey
    );

    // Mark current instance as ContinuedAsNew
    instance.Status__c = 'ContinuedAsNew';
    instance.Current_Step__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    spawnContinueAsNewSuccessor(instance, result, newKey);
  }

  /**
   * Resolves the successor's execution deadline from an execution-timeout-
   * configurable workflow definition.
   * @param defObj the instantiated workflow definition object
   * @return the deadline DateTime, or null when no positive execution timeout is
   *   configured
   */
  private static Datetime resolveExecutionDeadline(Object defObj) {
    if (!(defObj instanceof ExecutionTimeoutConfigurable)) {
      return null;
    }
    Integer timeoutSecs = ((ExecutionTimeoutConfigurable) defObj)
      .getExecutionTimeoutSeconds();
    return timeoutSecs != null ? DateTime.now().addSeconds(timeoutSecs) : null;
  }

  // Create and enqueue the successor instance for a CONTINUE_AS_NEW transition.
  private static void spawnContinueAsNewSuccessor(
    Workflow_Instance__c instance,
    StepResult result,
    String newKey
  ) {
    // Resolve initial step for successor instance
    String initialStep = null;
    Datetime nextDeadline = null;
    Type wflowType = WorkflowTypeResolver.resolve(
      instance.Workflow_Name__c,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    if (wflowType != null) {
      Object defObj = wflowType.newInstance();
      if (defObj instanceof WorkflowDefinition) {
        initialStep = ((WorkflowDefinition) defObj).getInitialStep();
      }
      nextDeadline = resolveExecutionDeadline(defObj);
    }

    // Spawn successor instance. Carry the chain's root correlation key forward
    // unchanged so the whole continue-as-new chain shares one stable key that
    // external callers can correlate the terminal lifecycle event against.
    // Fall back to the predecessor's own key if the root was never populated
    // (pre-existing data created before the Root_Correlation_Key__c field).
    String rootKey = String.isNotBlank(instance.Root_Correlation_Key__c)
      ? instance.Root_Correlation_Key__c
      : instance.Correlation_Key__c;
    Workflow_Instance__c nextInstance = new Workflow_Instance__c(
      Workflow_Name__c = instance.Workflow_Name__c,
      Correlation_Key__c = newKey,
      Root_Correlation_Key__c = rootKey,
      Previous_Instance__c = instance.Id,
      Definition_Version__c = instance.Definition_Version__c,
      Current_Step__c = initialStep,
      Deadline_At__c = nextDeadline,
      Progress__c = instance.Progress__c,
      Causation_Id__c = String.isNotBlank(instance.Causation_Id__c)
        ? instance.Causation_Id__c
        : instance.Parent_Instance__c,
      // Use the predecessor's CreatedDate (when it started) rather than
      // System.now() (when it finished). This prevents a gap: records
      // modified during the predecessor's execution window are covered by
      // the successor's query (>= predecessor start). The tradeoff is
      // bounded overlap near the boundary, which is correct at-least-once
      // behavior — the same contract Temporal/DBOS use for polling cursors.
      Previous_Run_At__c = instance.CreatedDate
    );
    insertSuccessorRecord(nextInstance, newKey);
    copyPredecessorSearchAttributes(instance.Id, nextInstance.Id);
    finalizeSuccessorInstance(nextInstance, result, initialStep);
  }

  // Insert the successor instance, translating a duplicate-key collision into a
  // WorkflowException.
  private static void insertSuccessorRecord(
    Workflow_Instance__c nextInstance,
    String newKey
  ) {
    try {
      Database.insert(nextInstance, true, AccessLevel.SYSTEM_MODE);
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' + newKey
        );
      }
      throw ex;
    }
  }

  // Copy the predecessor's search attributes onto the successor instance.
  private static void copyPredecessorSearchAttributes(
    Id predecessorId,
    Id successorId
  ) {
    List<Workflow_Search_Attribute__c> predecessorAttrs = [
      SELECT Key__c, Value__c
      FROM Workflow_Search_Attribute__c
      WHERE Workflow_Instance__c = :predecessorId
      WITH SYSTEM_MODE
    ];
    if (predecessorAttrs.isEmpty()) {
      return;
    }
    List<Workflow_Search_Attribute__c> successorAttrs = new List<Workflow_Search_Attribute__c>();
    for (Workflow_Search_Attribute__c attr : predecessorAttrs) {
      successorAttrs.add(
        new Workflow_Search_Attribute__c(
          Workflow_Instance__c = successorId,
          Key__c = attr.Key__c,
          Value__c = attr.Value__c,
          Key_Value__c = attr.Key__c +
            '=' +
            (attr.Value__c == null ? '' : attr.Value__c)
        )
      );
    }
    Database.insert(successorAttrs, true, AccessLevel.SYSTEM_MODE);
  }

  // Set the successor's input, pre-create its first step, and enqueue its run.
  private static void finalizeSuccessorInstance(
    Workflow_Instance__c nextInstance,
    StepResult result,
    String initialStep
  ) {
    // Set input and save payload
    nextInstance.Input__c = savePayloadIfNeeded(
      nextInstance.Id,
      result.nextInputJson,
      'Input_' + nextInstance.Id
    );

    // A concurrency-bounded successor must pass the admission gate on its first
    // RUN_STEP before it owns a slot, so defer the initial step's timeout until
    // admission re-arms it (mirrors doStart). Otherwise the still-Pending successor
    // could be failed by the timeout sweep while waiting in the backlog for a slot.
    Boolean deferTimeoutForConcurrency = ConcurrencyGate.isConfigured(
      nextInstance.Workflow_Name__c
    );
    // Durable awaiting-admission marker (see doStart): keeps the pre-start watchdog
    // keyed off persisted state rather than the live CMDT. Cleared on admission.
    if (deferTimeoutForConcurrency) {
      nextInstance.Concurrency_Parked__c = true;
    }
    Database.update(nextInstance, true, AccessLevel.SYSTEM_MODE);

    // Pre-create the successor's first step execution log
    if (String.isNotBlank(initialStep)) {
      Workflow_Step_Execution__c nextStepExec = new Workflow_Step_Execution__c();
      nextStepExec.Workflow_Instance__c = nextInstance.Id;
      nextStepExec.Step_Name__c = initialStep;
      nextStepExec.Status__c = 'Pending';
      nextStepExec.Input__c = nextInstance.Input__c;
      nextStepExec.Retry_Count__c = 0;
      Integer timeout = getStepTimeoutSeconds(
        initialStep,
        WorkflowTypeResolver.extractNamespace(nextInstance.Workflow_Name__c)
      );
      if (timeout != null && timeout > 0 && !deferTimeoutForConcurrency) {
        nextStepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
      }
      Database.insert(nextStepExec, true, AccessLevel.SYSTEM_MODE);
    }

    // Enqueue the successor run
    if (!deferTimeoutForConcurrency) {
      scheduleTimeoutJobForInstance(nextInstance.Id);
    }
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(nextInstance.Id));
      }
    } else {
      enqueueOrchestrator(nextInstance.Id, null);
    }
  }

  // FAIL: deliberate terminal failure routed through failWorkflowInstance.
  private static void handleFailOutcome(StepOutcomeContext outcome) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Boolean isParallel = outcome.isParallel;
    // Explicit terminal failure (issue #37): the author returned a deliberate
    // business failure — not a crash, not a retry. Record the step terminal
    // exactly once (append-only) with the operator-readable reason (and any
    // structured failureData) in Error_Details__c, then route through the
    // existing failWorkflowInstance path. That performs ZERO retry hops and
    // transitions to Compensating (LIFO rollback) when a Compensation_Stack__c
    // exists, or to Failed otherwise; Terminal_At__c is stamped by
    // WorkflowInstanceTrigger on the terminal transition, exactly as a thrown
    // failure does today.
    //
    // Signal consumption mirrors the COMPLETE path: the step ran to its terminal
    // conclusion so any signals it observed are marked consumed (not rolled back),
    // preventing re-delivery to later compensation steps.
    markSignalsConsumed(instance.Id, context, isParallel);
    stepExec.Status__c = 'Failed';
    // Plain-text schema matches RETRY/crash paths. When failureData is present
    // the raw JSON is appended on a second line for downstream inspection without
    // needing to detect a JSON envelope.
    stepExec.Error_Details__c = (result.failureDataJson != null)
      ? result.failureReason + '\nfailureData: ' + result.failureDataJson
      : result.failureReason;
    saveStepExec(stepExec);

    // Publish any domain events the step buffered via StepContext.emit() before
    // returning fail() — same commit-coupling contract as COMPLETE/SPLIT so
    // callers never silently lose events on deliberate terminal failures.
    publishOutboundEvents(result, context);

    FailInstanceRequest explicitFailReq = new FailInstanceRequest();
    explicitFailReq.instanceId = instance.Id;
    explicitFailReq.stepName = stepExec.Step_Name__c;
    explicitFailReq.errorMessage = result.failureReason;
    explicitFailReq.failureCategory = CAT_EXPLICIT_FAIL;
    failWorkflowInstance(explicitFailReq);
  }

  /**
   * Rescues a workflow when the host transaction fails or hits governor limits.
   * Invoked from a System.Finalizer.
   * @param instanceId Id of the instance whose transaction crashed
   * @param ex the exception that caused the crash
   */
  public static void handleCrash(Id instanceId, Exception ex) {
    handleCrash(instanceId, null, ex);
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
    // Run as separate DML transaction to ensure it's written even if parent rolled back
    List<Workflow_Instance__c> instances = [
      SELECT Id, Status__c, Current_Step__c, Compensation_Stack__c, Input__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];

    if (instances.isEmpty()) {
      return;
    }

    Workflow_Instance__c instance = instances[0];

    Boolean midRollback = isMidRollback(instance);
    String targetStepName = resolveCrashStepName(
      instance,
      stepName,
      midRollback
    );

    // Transient row-lock contention (UNABLE_TO_LOCK_ROW) is retryable, not a crash:
    // it arises when many transactions touch the same row at once — e.g. a fan-in
    // where every child-completion signal locks the shared parent row — and clears on
    // its own once the competing transactions commit. Re-drive the step after a short
    // backoff instead of failing/compensating the whole workflow. Bounded by the
    // step's consecutive Transient_Retry_Count__c so a genuinely stuck row still fails.
    if (
      isTransientLockError(ex) &&
      String.isNotBlank(targetStepName) &&
      scheduleTransientLockRetry(instance, targetStepName)
    ) {
      return;
    }

    recordCrashedStep(instance, targetStepName, ex);

    // Use fail helper
    String errorMsg =
      'Transaction crashed: ' +
      (ex != null ? ex.getMessage() : 'Unknown governor limit');
    FailInstanceRequest stepExceptionReq = new FailInstanceRequest();
    stepExceptionReq.instanceId = instanceId;
    stepExceptionReq.stepName = targetStepName;
    stepExceptionReq.errorMessage = errorMsg;
    stepExceptionReq.failureCategory = CAT_STEP_EXCEPTION;
    failWorkflowInstance(stepExceptionReq);
  }

  // The instance is mid-rollback when its status is Compensating/Cancelling, OR
  // when it is Suspended and its most recent step execution is a '_Compensate'
  // attempt (a sleeping/approval-gated compensation whose in-transaction status
  // flip was rolled back by the crash). Detected the same way runStep() does so
  // the crash is recorded against the '_Compensate' step, not the stale forward
  // step.
  private static Boolean isMidRollback(Workflow_Instance__c instance) {
    Boolean midRollback =
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling';
    if (!midRollback && instance.Status__c == 'Suspended') {
      List<Workflow_Step_Execution__c> latestSteps = [
        SELECT Step_Name__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instance.Id
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      midRollback =
        !latestSteps.isEmpty() &&
        latestSteps[0].Step_Name__c != null &&
        latestSteps[0].Step_Name__c.endsWith('_Compensate');
    }
    return midRollback;
  }

  // Resolve the step the crash is recorded against. An explicit stepName always
  // wins; otherwise a mid-rollback crash targets the top-of-stack '_Compensate'
  // step, and a forward crash targets the stale Current_Step__c.
  private static String resolveCrashStepName(
    Workflow_Instance__c instance,
    String stepName,
    Boolean midRollback
  ) {
    if (String.isNotBlank(stepName)) {
      return stepName;
    }
    if (midRollback && String.isNotBlank(instance.Compensation_Stack__c)) {
      List<String> stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
      return stack.isEmpty()
        ? instance.Current_Step__c
        : stack[stack.size() - 1] + '_Compensate';
    }
    return instance.Current_Step__c;
  }

  private static String crashErrorDetails(Exception ex) {
    return ex != null
      ? ex.getMessage() + '\n' + ex.getStackTraceString()
      : 'Unknown governor limit / crash';
  }

  // Mark the crashing step's execution log Failed (updating the latest log if it
  // exists, otherwise inserting a fresh Failed log seeded with the right undo
  // context).
  private static void recordCrashedStep(
    Workflow_Instance__c instance,
    String targetStepName,
    Exception ex
  ) {
    if (String.isBlank(targetStepName)) {
      return;
    }
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :targetStepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (!stepExecs.isEmpty()) {
      Workflow_Step_Execution__c stepExec = stepExecs[0];
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c = crashErrorDetails(ex);
      saveStepExec(stepExec, true);
      return;
    }
    // Construct and insert the step execution log with failed status
    Workflow_Step_Execution__c stepExec = buildCrashedStepExec(
      instance,
      targetStepName,
      ex
    );
    saveStepExec(stepExec, true);
  }

  private static Workflow_Step_Execution__c buildCrashedStepExec(
    Workflow_Instance__c instance,
    String targetStepName,
    Exception ex
  ) {
    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
    stepExec.Workflow_Instance__c = instance.Id;
    stepExec.Step_Name__c = targetStepName;
    stepExec.Status__c = 'Failed';
    stepExec.Error_Details__c = crashErrorDetails(ex);

    if (targetStepName.endsWith('_Compensate')) {
      seedCompensationCrashInput(stepExec, instance.Id, targetStepName);
    } else {
      seedForwardCrashInput(stepExec, instance);
    }
    return stepExec;
  }

  // Crash row for a compensation step: seed from THIS step's own forward
  // execution (input/output), matching how compensation logs are seeded
  // everywhere else. Using the latest completed step overall would be wrong once
  // earlier compensations have popped — that row belongs to an already-reversed
  // step, giving the wrong undo context on resume.
  private static void seedCompensationCrashInput(
    Workflow_Step_Execution__c stepExec,
    Id instanceId,
    String targetStepName
  ) {
    String forwardStepName = targetStepName.removeEnd('_Compensate');
    List<Workflow_Step_Execution__c> forwardExecs = [
      SELECT Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = :forwardStepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (!forwardExecs.isEmpty()) {
      stepExec.Input__c = forwardExecs[0].Input__c;
      stepExec.Output__c = forwardExecs[0].Output__c;
    }
  }

  // Forward step crash: feed the previous step's output as input.
  private static void seedForwardCrashInput(
    Workflow_Step_Execution__c stepExec,
    Workflow_Instance__c instance
  ) {
    List<Workflow_Step_Execution__c> completedSteps = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Status__c IN ('Completed', 'OperatorSkipped')
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    stepExec.Input__c = !completedSteps.isEmpty()
      ? completedSteps[0].Output__c
      : instance.Input__c;
  }

  /**
   * True when the exception is a transient row-lock contention error
   * (UNABLE_TO_LOCK_ROW / "record currently unavailable") rather than a genuine
   * crash. These resolve on their own once the competing transaction commits, so
   * the crash handler re-drives the step instead of failing the workflow.
   * @param ex the exception to classify
   * @return true when the exception is a transient row-lock contention error
   */
  @TestVisible
  private static Boolean isTransientLockError(Exception ex) {
    if (ex == null) {
      return false;
    }
    if (ex instanceof DmlException) {
      try {
        DmlException de = (DmlException) ex;
        for (Integer i = 0; i < de.getNumDml(); i++) {
          if (de.getDmlType(i) == StatusCode.UNABLE_TO_LOCK_ROW) {
            return true;
          }
        }
      } catch (Exception ignored) {
        // Safeguard against programmatically constructed DmlExceptions in tests
      }
    }
    String msg = ex.getMessage();
    if (String.isBlank(msg)) {
      return false;
    }
    String lower = msg.toLowerCase();
    return lower.contains('unable_to_lock_row') ||
      lower.contains('unable to lock row') ||
      lower.contains('unable to obtain exclusive access') ||
      lower.contains('record currently unavailable') ||
      lower.contains('currently being modified by another');
  }

  /**
   * Re-drives a step after a transient row-lock error, bounded by the step's
   * CONSECUTIVE Transient_Retry_Count__c (reset to 0 on the next successful drive in
   * handleStepResult). Returns true when a retry was scheduled — the caller then
   * skips the fail path; returns false when the budget is spent or there is no step
   * row to retry against, so the caller fails the workflow as usual. Mirrors the
   * RETRY action's suspend + scheduleRetry handoff so the watchdog/sleep plumbing
   * re-drives even when dynamic scheduling is off.
   * @param instance the instance whose step is re-driven
   * @param stepName name of the step to retry against
   * @return true when a retry was scheduled; false when the budget is spent or
   * there is no step row to retry
   */
  /**
   * Determines whether an instance is already terminal for transient-retry gating.
   * @param instance the instance whose status is checked
   * @return true when the instance is in a terminal state that must not be
   *   resurrected by a transient-lock retry (excludes CompensationFailed, which is
   *   recoverable via operator resume)
   */
  private static Boolean isInstanceTerminalForRetry(
    Workflow_Instance__c instance
  ) {
    return instance.Status__c == 'Completed' ||
      instance.Status__c == 'Failed' ||
      instance.Status__c == 'Compensated' ||
      instance.Status__c == 'Cancelled' ||
      instance.Status__c == 'ContinuedAsNew';
  }

  private static Boolean scheduleTransientLockRetry(
    Workflow_Instance__c instance,
    String stepName
  ) {
    // Never resurrect an already-terminal instance: a stray late crash must fall
    // through to the (idempotent) fail path, not flip a finished run back to Suspended.
    if (isInstanceTerminalForRetry(instance)) {
      return false;
    }

    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Status__c, Transient_Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instance.Id AND Step_Name__c = :stepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (stepExecs.isEmpty()) {
      return false;
    }
    Workflow_Step_Execution__c stepExec = stepExecs[0];
    Integer attempts = (stepExec.Transient_Retry_Count__c == null)
      ? 0
      : (Integer) stepExec.Transient_Retry_Count__c;
    if (attempts >= maxTransientLockRetries) {
      return false; // budget spent -> caller fails the workflow
    }

    // The crash rolled back any in-flight status change, so keep the step
    // re-runnable and record the consecutive transient attempt without touching the
    // business Retry_Count__c budget.
    stepExec.Transient_Retry_Count__c = attempts + 1;
    if (stepExec.Status__c == 'Failed') {
      stepExec.Status__c = 'Pending';
    }
    // Clear the step's watchdog deadline for the duration of the backoff. The crash
    // left the row Running/Pending carrying its pre-crash Timeout_At__c; once the
    // sleep flips the parent back to Running, a now-stale (already-past) deadline
    // would let the watchdog timeout batch fail the step before the retry worker
    // re-drives it. runStep re-stamps a fresh deadline before execute() on the
    // re-drive, mirroring how the RETRY action parks its step out of the timeout batch.
    stepExec.Timeout_At__c = null;
    Database.update(stepExec, true, AccessLevel.SYSTEM_MODE);

    // Exponential backoff (capped) with jitter so the contention wave drains before
    // the re-drive and a fan-in of re-drives does not re-synchronize into a new storm.
    Double exponent = Math.min(attempts, 4); // widen Integer -> Double for Math.pow
    Integer delay =
      TRANSIENT_LOCK_BASE_DELAY_SECONDS * (Integer) Math.pow(2, exponent);
    delay = Math.min(delay, TRANSIENT_LOCK_MAX_DELAY_SECONDS);
    delay += (Integer) Math.floor(
      Math.random() * TRANSIENT_LOCK_JITTER_SECONDS
    );

    String jobId = scheduleRetry(instance.Id, stepName, delay);
    instance.Status__c = 'Suspended';
    instance.Sleep_Until__c = DateTime.now().addSeconds(delay);
    instance.Async_Job_Id__c = jobId;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    if (jobId == null) {
      // No delayed job was created (dynamic scheduling off, or async limit), so this
      // retry relies entirely on the watchdog heartbeat to re-drive after the backoff.
      // Ensure the watchdog singleton is alive — the removed immediate re-drive used to
      // restart a dead watchdog via enqueueOrchestrator's bootstrap() call.
      WorkflowWatchdog.bootstrap();
    }

    // No immediate re-drive when jobId is null. The branch target is durably persisted
    // as its Pending step row carrying Transient_Retry_Count__c > 0 (set above), and
    // the watchdog sleep-resume re-drives exactly those branches BY NAME once
    // Sleep_Until__c is due (see processWatchdogHeartbeat). Enqueuing the branch
    // immediately here would bypass the backoff just written and, under a sustained
    // UNABLE_TO_LOCK_ROW fan-in, burn through maxTransientLockRetries before the
    // contending transactions clear — failing the very workflow the backoff exists to
    // wait out. A single-step instance is still resolved by the watchdog's blank-name
    // resume; only the parallel branch needed a name-carrying path, now the watchdog's.
    return true;
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
    failWorkflowInstance(req);
  }

  /**
   * @description Fails an instance with an explicit failure category, resolving
   * the current attempt count from the step's latest execution before delegating
   * to the record-level path.
   * @param req the fail request (instanceId, stepName, errorMessage, failureCategory)
   */
  public static void failWorkflowInstance(FailInstanceRequest req) {
    Id instanceId = req.instanceId;
    String stepName = req.stepName;
    String failureCategory = req.failureCategory;
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Name,
        Status__c,
        Current_Step__c,
        Error_Message__c,
        Compensation_Stack__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Failure_Category__c,
        Concurrency_Parked__c,
        Concurrency_Slot_Held__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      return;
    }
    Workflow_Instance__c instance = instances[0];

    // Determine attempt count
    Integer attemptCount = 1;
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Step_Name__c = :stepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (!stepExecs.isEmpty() && stepExecs[0].Retry_Count__c != null) {
      attemptCount = (Integer) stepExecs[0].Retry_Count__c;
      if (failureCategory != CAT_RETRIES_EXHAUSTED) {
        attemptCount += 1;
      }
    }

    req.instance = instance;
    req.attemptCount = attemptCount;
    failResolvedInstance(req);
  }

  /**
   * @description Record-level fail transition: routes the instance to Failed, or
   * to Compensating when a compensable saga has completed steps to unwind, records
   * the error/category/attempt count, and publishes lifecycle/alert side effects.
   * @param req the fail request with a pre-queried instance record and attempt count
   */
  private static void failResolvedInstance(FailInstanceRequest req) {
    Workflow_Instance__c instance = req.instance;
    Boolean isCompFailure = isCompensationContext(instance, req.stepName);

    if (tryErrorRouting(req, isCompFailure)) {
      return;
    }

    // Check if there are compensations to run
    if (!hasPendingCompensations(instance)) {
      failInstanceTerminally(req);
      return;
    }

    if (isCompensationContext(instance, req.stepName)) {
      failCompensationTerminally(req);
      return;
    }

    beginCompensation(req);
  }

  private static Boolean isCompensationContext(
    Workflow_Instance__c instance,
    String stepName
  ) {
    return instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling' ||
      (String.isNotBlank(stepName) && stepName.endsWith('_Compensate'));
  }

  private static Boolean hasPendingCompensations(
    Workflow_Instance__c instance
  ) {
    if (String.isBlank(instance.Compensation_Stack__c)) {
      return false;
    }
    List<String> stack = (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
    return !stack.isEmpty();
  }

  // Best-effort error routing: if the workflow defines an error step, cancel
  // siblings, insert the error step, and re-run. Returns true when routing
  // consumed the failure (caller returns), false to fall through to the
  // compensation/terminal-fail path. Never lets a routing failure mask the
  // original error.
  private static Boolean tryErrorRouting(
    FailInstanceRequest req,
    Boolean isCompFailure
  ) {
    if (isCompFailure) {
      return false;
    }
    Workflow_Instance__c instance = req.instance;
    try {
      Type wfType = WorkflowTypeResolver.resolve(
        instance.Workflow_Name__c,
        WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
      );
      if (wfType == null) {
        return false;
      }
      WorkflowDefinition def = (WorkflowDefinition) wfType.newInstance();
      if (!(def instanceof ErrorRoutingWorkflow)) {
        return false;
      }
      String truncatedError = req.errorMessage != null
        ? req.errorMessage.left(20000)
        : null;
      StepError err = new StepError(
        req.stepName,
        truncatedError,
        req.attemptCount
      );
      String errorStepName = ((ErrorRoutingWorkflow) def)
        .getErrorStep(req.stepName, err);
      if (String.isBlank(errorStepName)) {
        return false;
      }
      routeToErrorStep(req, errorStepName, truncatedError);
      return true;
    } catch (Exception ignored) {
      // Error-routing is best-effort; a routing failure must not mask the original error.
      return false;
    }
  }

  private static void routeToErrorStep(
    FailInstanceRequest req,
    String errorStepName,
    String truncatedError
  ) {
    Workflow_Instance__c instance = req.instance;
    cancelSiblingStepsForErrorRouting(instance, req.stepName);

    abortScheduledJobs(instance.Id);

    Workflow_Step_Execution__c nextStepExec = new Workflow_Step_Execution__c();
    nextStepExec.Workflow_Instance__c = instance.Id;
    nextStepExec.Step_Name__c = errorStepName;
    nextStepExec.Status__c = 'Pending';
    nextStepExec.Retry_Count__c = 0;

    Map<String, Object> errorCaptures = new Map<String, Object>{
      '__failedStepName' => req.stepName,
      '__errorMessage' => truncatedError,
      '__attemptCount' => req.attemptCount
    };
    nextStepExec.Captured_Values__c = savePayloadIfNeeded(
      instance.Id,
      JSON.serialize(errorCaptures),
      'Captures_' + errorStepName.replaceAll('[^a-zA-Z0-9]', '_')
    );
    Database.insert(nextStepExec, true, AccessLevel.SYSTEM_MODE);

    instance.Current_Step__c = errorStepName;
    instance.Status__c = 'Running';
    instance.Sleep_Until__c = null;
    instance.Async_Job_Id__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    scheduleTimeoutJobForInstance(instance);
    enqueueOrchestratorForInstance(instance.Id);
  }

  private static void cancelSiblingStepsForErrorRouting(
    Workflow_Instance__c instance,
    String stepName
  ) {
    if (
      String.isBlank(instance.Current_Step__c) ||
      !instance.Current_Step__c.contains(',')
    ) {
      return;
    }
    List<String> activeSteps = instance.Current_Step__c.split(',');
    List<Workflow_Step_Execution__c> siblingExecs = [
      SELECT Id, Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c IN :activeSteps
        AND Step_Name__c != :stepName
        AND Status__c IN ('Pending', 'Retrying')
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    for (Workflow_Step_Execution__c sibling : siblingExecs) {
      sibling.Status__c = 'Cancelled';
    }
    if (!siblingExecs.isEmpty()) {
      Database.update(siblingExecs, true, AccessLevel.SYSTEM_MODE);
    }
  }

  private static void failInstanceTerminally(FailInstanceRequest req) {
    Workflow_Instance__c instance = req.instance;
    instance.Status__c = 'Failed';
    instance.Failure_Category__c = req.failureCategory;
    instance.Error_Message__c = ('Failed at step ' +
      req.stepName +
      ': ' +
      req.errorMessage)
      .left(255);
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    notifyParentCompletion(instance);
    WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
    WorkflowLifecyclePublisher.publish(instance);
  }

  private static void failCompensationTerminally(FailInstanceRequest req) {
    Workflow_Instance__c instance = req.instance;
    Boolean wasCancelling =
      instance.Status__c == 'Cancelling' ||
      (instance.Error_Message__c != null &&
      instance.Error_Message__c.contains('Cancelled by user'));
    instance.Status__c = 'CompensationFailed';
    instance.Failure_Category__c = CAT_COMPENSATION_FAILED;
    instance.Error_Message__c = buildRollbackIncompleteMessage(
        wasCancelling,
        'Rollback incomplete at compensation step ' +
          req.stepName +
          ': ' +
          req.errorMessage
      )
      .left(255);
    instance.Sleep_Until__c = null;
    instance.Async_Job_Id__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    notifyParentCompletion(instance);
    WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
    WorkflowLifecyclePublisher.publish(instance);
  }

  private static void beginCompensation(FailInstanceRequest req) {
    Workflow_Instance__c instance = req.instance;
    instance.Status__c = 'Compensating';
    instance.Error_Message__c = ('Failed at step ' +
      req.stepName +
      ': ' +
      req.errorMessage)
      .left(255);
    preCreateFirstCompensationStep(instance);
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    enqueueOrchestratorForInstance(instance.Id);
  }

  // Shared enqueue path used by the fail/error-routing branches: in tests,
  // enqueue only when queueables are enabled; otherwise delegate to the
  // standard orchestrator enqueue.
  private static void enqueueOrchestratorForInstance(Id instanceId) {
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instanceId));
      }
    } else {
      enqueueOrchestrator(instanceId, null);
    }
  }

  /**
   * @description Request DTO for starting a single child workflow. Populated
   * field-by-field to avoid a wide constructor.
   */
  @TestVisible
  private class ChildWorkflowStartRequest {
    public Id parentId;
    public String workflowName;
    public String correlationKey;
    public String inputJson;
  }

  /**
   * Resolves the correlation-key preconditions for starting a child workflow.
   * Returns true when an idempotent re-suspend applies (an active instance under
   * the same parent, or a terminal sibling under the same parent already exists),
   * and throws when the key collides with an active instance under a different
   * parent.
   * @param correlationKey the child's correlation key (assumed not blank)
   * @param parentId the requesting parent instance id
   * @return true when the start should resolve idempotently without creating one
   */
  private static Boolean isChildStartIdempotent(
    String correlationKey,
    Id parentId
  ) {
    // 1. Check for active globally unique key
    List<Workflow_Instance__c> existingActive = [
      SELECT Id, Parent_Instance__c, Status__c
      FROM Workflow_Instance__c
      WHERE Active_Correlation_Key__c = :correlationKey
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!existingActive.isEmpty()) {
      if (existingActive[0].Parent_Instance__c == parentId) {
        return true; // Idempotent re-suspend
      }
      throw new WorkflowException(
        'An active workflow already exists with correlation key: ' +
        correlationKey
      );
    }

    // 2. Check for sibling terminal key under same parent
    List<Workflow_Instance__c> existingSibling = [
      SELECT Id, Parent_Instance__c, Status__c
      FROM Workflow_Instance__c
      WHERE
        Correlation_Key__c = :correlationKey
        AND Parent_Instance__c = :parentId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return !existingSibling.isEmpty(); // non-empty => idempotent re-suspend
  }

  /**
   * Builds (in memory) the child Workflow_Instance__c from the start request and
   * its resolved definition, populating status, correlation/parent linkage,
   * definition version and initial step. Throws when the workflow name cannot be
   * resolved or the class does not implement WorkflowDefinition.
   * @param req the child start request
   * @param parentNamespace the parent's namespace used to resolve the type
   * @return the unsaved child instance
   */
  private static Workflow_Instance__c buildChildInstance(
    ChildWorkflowStartRequest req,
    String parentNamespace
  ) {
    Type wflowType = WorkflowTypeResolver.resolve(
      req.workflowName,
      parentNamespace
    );
    if (wflowType == null) {
      throw new WorkflowException(
        'Workflow definition not found for name: ' + req.workflowName
      );
    }
    Workflow_Instance__c instance = new Workflow_Instance__c();
    instance.Workflow_Name__c = String.valueOf(wflowType);
    instance.Status__c = 'Pending';
    instance.Correlation_Key__c = req.correlationKey;
    instance.Parent_Instance__c = req.parentId;
    instance.Causation_Id__c = req.parentId;
    Object defObj = wflowType.newInstance();
    if (!(defObj instanceof WorkflowDefinition)) {
      throw new WorkflowException(
        'Class ' + req.workflowName + ' must implement WorkflowDefinition'
      );
    }

    if (defObj instanceof VersionedWorkflow) {
      instance.Definition_Version__c = ((VersionedWorkflow) defObj)
        .getLatestVersion();
    } else {
      instance.Definition_Version__c = 1;
    }
    instance.Current_Step__c = ((WorkflowDefinition) defObj).getInitialStep();
    return instance;
  }

  /**
   * Inserts the child instance, handling the DUPLICATE_VALUE concurrency
   * backstop: when a sibling wins the insert race under the same parent the
   * start resolves idempotently, otherwise a collision throws.
   * @param instance the unsaved child instance
   * @return true when a concurrent sibling won the race and the start should
   * resolve idempotently without proceeding
   */
  private static Boolean insertChildInstance(Workflow_Instance__c instance) {
    Id parentId = instance.Parent_Instance__c;
    String correlationKey = instance.Correlation_Key__c;
    try {
      Database.insert(instance, true, AccessLevel.SYSTEM_MODE);
      if (Test.isRunningTest() && parentId != null) {
        registerChildParent(instance.Id, parentId);
      }
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        // Concurrency backstop: check if the sibling that won the insert race belongs to the same parent.
        List<Workflow_Instance__c> sibling = [
          SELECT Id, Parent_Instance__c
          FROM Workflow_Instance__c
          WHERE Active_Correlation_Key__c = :correlationKey
          WITH SYSTEM_MODE
          LIMIT 1
        ];
        if (!sibling.isEmpty() && sibling[0].Parent_Instance__c == parentId) {
          return true; // Sibling won the insert race, and it belongs to this parent; resolve idempotently.
        }
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' +
          correlationKey
        );
      }
      throw ex;
    }
    return false;
  }

  /**
   * Inserts the child's initial Pending step execution, mirroring the instance's
   * initial step and input.
   * @param instance the persisted child instance
   */
  private static void insertInitialChildStep(Workflow_Instance__c instance) {
    if (String.isNotBlank(instance.Current_Step__c)) {
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = instance.Current_Step__c;
      stepExec.Status__c = 'Pending';
      stepExec.Input__c = instance.Input__c;
      stepExec.Retry_Count__c = 0;
      Database.insert(stepExec, true, AccessLevel.SYSTEM_MODE);
    }
  }

  @TestVisible
  private static void startChildWorkflow(ChildWorkflowStartRequest req) {
    Id parentId = req.parentId;
    String correlationKey = req.correlationKey;
    String inputJson = req.inputJson;
    validateCorrelationKey(correlationKey);
    if (
      String.isNotBlank(correlationKey) &&
      isChildStartIdempotent(correlationKey, parentId)
    ) {
      return;
    }

    if (String.isBlank(req.workflowName)) {
      throw new WorkflowException('Workflow name is required.');
    }
    String parentNamespace = resolveParentNamespace(parentId);
    Workflow_Instance__c instance = buildChildInstance(req, parentNamespace);

    if (insertChildInstance(instance)) {
      return;
    }

    instance.Input__c = savePayloadIfNeeded(
      instance.Id,
      inputJson,
      'Input_Child_' + instance.Id
    );
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    insertInitialChildStep(instance);

    finalizeChildStart(instance);
  }

  /**
   * Finalizes a freshly-persisted child instance: applies the operator pause
   * gate, schedules (or defers) the initial-step watchdog, and enqueues the
   * orchestrator when not running under test.
   * @param instance the persisted child instance to finalize
   */
  private static void finalizeChildStart(Workflow_Instance__c instance) {
    // Operator pause gate — park the child at start if its definition is paused, so a
    // running parent cannot bypass the pause by spawning children. The initial Pending
    // step (above) gives resume a concrete step to drive; skip timeout scheduling and
    // the enqueue. The child's correlation reservation still holds (the trigger keeps
    // Active_Correlation_Key__c set for Paused).
    if (
      WorkflowPauseGate.anyPaused() &&
      WorkflowPauseGate.isDefinitionPaused(instance.Workflow_Name__c)
    ) {
      instance.Status__c = 'Paused';
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
      return;
    }

    // Schedule the watchdog for the child's initial step before executing it, matching
    // the start() overloads. Without this a TimeoutConfigurable first step of a child
    // workflow would never get a scheduled timeout job. A concurrency-bounded child
    // defers this until its first RUN_STEP wins an admission slot (mirrors doStart):
    // a parked sibling could take the freed slot before this child reaches the gate,
    // so an armed timeout could fail it while it is only waiting for capacity.
    if (!ConcurrencyGate.isConfigured(instance.Workflow_Name__c)) {
      scheduleTimeoutJobForInstance(instance.Id);
    } else {
      // Durable awaiting-admission marker (see doStart): the pre-start watchdog keys
      // its null-deadline skip off this, not the live CMDT, so a ceiling added later
      // cannot silence a genuine unbounded pre-start watchdog. Cleared on admission.
      instance.Concurrency_Parked__c = true;
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    }

    if (!Test.isRunningTest()) {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  /**
   * Parallel arrays pairing each freshly built child instance with the
   * originating ChildRequest, so payload resolution can re-associate them
   * positionally after the bulk insert assigns Ids.
   */
  private class ChildStartPlan {
    List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
    List<StepResult.ChildRequest> requests = new List<StepResult.ChildRequest>();
  }

  private static void startChildWorkflows(
    Id parentId,
    List<StepResult.ChildRequest> requests
  ) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    String parentNamespace = resolveParentNamespace(parentId);
    Set<String> correlationKeys = validateChildRequests(
      requests,
      parentNamespace
    );
    Map<String, Workflow_Instance__c> existingByCorrKey = findExistingChildren(
      parentId,
      correlationKeys
    );

    ChildStartPlan plan = new ChildStartPlan();
    for (StepResult.ChildRequest req : requests) {
      if (
        String.isNotBlank(req.correlationKey) &&
        existingByCorrKey.containsKey(normalizeKey(req.correlationKey))
      ) {
        continue;
      }
      plan.instances.add(buildChildInstance(req, parentId, parentNamespace));
      plan.requests.add(req);
    }

    if (plan.instances.isEmpty()) {
      return;
    }

    if (!insertChildInstances(plan.instances, parentId)) {
      return;
    }

    List<Workflow_Instance__c> instancesToUpdate = applyChildInputPayloads(
      plan
    );
    insertChildInitialSteps(instancesToUpdate);
    scheduleOrPauseChildren(instancesToUpdate);
    enqueueChildOrchestrators(instancesToUpdate);
  }

  private static String resolveParentNamespace(Id parentId) {
    if (parentId == null) {
      return '';
    }
    List<Workflow_Instance__c> parentInsts = [
      SELECT Workflow_Name__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (parentInsts.isEmpty()) {
      return '';
    }
    return WorkflowTypeResolver.extractNamespace(
      parentInsts[0].Workflow_Name__c
    );
  }

  private static Set<String> validateChildRequests(
    List<StepResult.ChildRequest> requests,
    String parentNamespace
  ) {
    Set<String> correlationKeys = new Set<String>();
    for (StepResult.ChildRequest req : requests) {
      validateCorrelationKey(req.correlationKey);
      correlationKeys.add(req.correlationKey);

      if (String.isBlank(req.workflowName)) {
        throw new WorkflowException('Workflow name is required.');
      }
      Type wflowType = WorkflowTypeResolver.resolve(
        req.workflowName,
        parentNamespace
      );
      if (wflowType == null) {
        throw new WorkflowException(
          'Workflow definition not found for name: ' + req.workflowName
        );
      }
      Object defObj = wflowType.newInstance();
      if (!(defObj instanceof WorkflowDefinition)) {
        throw new WorkflowException(
          'Class ' + req.workflowName + ' must implement WorkflowDefinition'
        );
      }
    }
    return correlationKeys;
  }

  private static Map<String, Workflow_Instance__c> findExistingChildren(
    Id parentId,
    Set<String> correlationKeys
  ) {
    Map<String, Workflow_Instance__c> existingByCorrKey = new Map<String, Workflow_Instance__c>();
    if (correlationKeys.isEmpty()) {
      return existingByCorrKey;
    }

    List<Workflow_Instance__c> existingActive = [
      SELECT Id, Parent_Instance__c, Status__c, Active_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Active_Correlation_Key__c IN :correlationKeys
      WITH SYSTEM_MODE
    ];
    for (Workflow_Instance__c existing : existingActive) {
      if (existing.Parent_Instance__c == parentId) {
        existingByCorrKey.put(
          normalizeKey(existing.Active_Correlation_Key__c),
          existing
        );
      } else {
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' +
          existing.Active_Correlation_Key__c
        );
      }
    }

    List<Workflow_Instance__c> existingSiblings = [
      SELECT Id, Parent_Instance__c, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        Correlation_Key__c IN :correlationKeys
        AND Parent_Instance__c = :parentId
      WITH SYSTEM_MODE
    ];
    for (Workflow_Instance__c existing : existingSiblings) {
      existingByCorrKey.put(
        normalizeKey(existing.Correlation_Key__c),
        existing
      );
    }
    return existingByCorrKey;
  }

  private static Workflow_Instance__c buildChildInstance(
    StepResult.ChildRequest req,
    Id parentId,
    String parentNamespace
  ) {
    Type wflowType = WorkflowTypeResolver.resolve(
      req.workflowName,
      parentNamespace
    );
    Workflow_Instance__c instance = new Workflow_Instance__c();
    // wflowType is guaranteed non-null by the validation loop above
    instance.Workflow_Name__c = String.valueOf(wflowType);
    instance.Status__c = 'Pending';
    instance.Correlation_Key__c = req.correlationKey;
    instance.Parent_Instance__c = parentId;
    instance.Causation_Id__c = parentId;
    Object defObj = wflowType.newInstance();
    if (defObj instanceof VersionedWorkflow) {
      instance.Definition_Version__c = ((VersionedWorkflow) defObj)
        .getLatestVersion();
    } else {
      instance.Definition_Version__c = 1;
    }
    instance.Current_Step__c = ((WorkflowDefinition) defObj).getInitialStep();
    return instance;
  }

  // Inserts the child instances, returning true when processing should
  // continue and false when a DUPLICATE_VALUE race was reconciled against
  // existing siblings (the original early return).
  private static Boolean insertChildInstances(
    List<Workflow_Instance__c> instancesToInsert,
    Id parentId
  ) {
    try {
      Database.insert(instancesToInsert, true, AccessLevel.SYSTEM_MODE);
      if (Test.isRunningTest()) {
        for (Workflow_Instance__c inst : instancesToInsert) {
          registerChildParent(inst.Id, parentId);
        }
      }
      return true;
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        reconcileDuplicateChildren(instancesToInsert, parentId);
        return false;
      }
      throw ex;
    }
  }

  private static Set<String> collectChildCorrelationKeys(
    List<Workflow_Instance__c> instances
  ) {
    Set<String> corrKeys = new Set<String>();
    for (Workflow_Instance__c inst : instances) {
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        corrKeys.add(normalizeKey(inst.Correlation_Key__c));
      }
    }
    return corrKeys;
  }

  // Re-verifies that each duplicate-keyed child already exists as a sibling of
  // this parent; throws only for a correlation-key collision with a foreign
  // instance. Mirrors the original in-catch reconciliation exactly.
  private static void reconcileDuplicateChildren(
    List<Workflow_Instance__c> instancesToInsert,
    Id parentId
  ) {
    Set<String> corrKeys = collectChildCorrelationKeys(instancesToInsert);
    Map<String, Workflow_Instance__c> siblingsMap = new Map<String, Workflow_Instance__c>();
    if (!corrKeys.isEmpty()) {
      for (Workflow_Instance__c sibling : [
        SELECT Id, Parent_Instance__c, Active_Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE Active_Correlation_Key__c IN :corrKeys
        WITH SYSTEM_MODE
      ]) {
        siblingsMap.put(
          normalizeKey(sibling.Active_Correlation_Key__c),
          sibling
        );
      }
    }
    for (Workflow_Instance__c inst : instancesToInsert) {
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        Workflow_Instance__c sibling = siblingsMap.get(
          normalizeKey(inst.Correlation_Key__c)
        );
        if (sibling == null || sibling.Parent_Instance__c != parentId) {
          throw new WorkflowException(
            'An active workflow already exists with correlation key: ' +
            inst.Correlation_Key__c
          );
        }
      }
    }
  }

  private static List<Workflow_Instance__c> applyChildInputPayloads(
    ChildStartPlan plan
  ) {
    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < plan.instances.size(); i++) {
      Workflow_Instance__c inst = plan.instances[i];
      StepResult.ChildRequest req = plan.requests[i];
      inst.Input__c = savePayloadIfNeeded(
        inst.Id,
        req.inputJson,
        'Input_Child_' + inst.Id
      );
      instancesToUpdate.add(inst);
    }
    Database.update(instancesToUpdate, true, AccessLevel.SYSTEM_MODE);
    return instancesToUpdate;
  }

  private static void insertChildInitialSteps(
    List<Workflow_Instance__c> instancesToUpdate
  ) {
    List<Workflow_Step_Execution__c> stepExecsToInsert = new List<Workflow_Step_Execution__c>();
    for (Workflow_Instance__c inst : instancesToUpdate) {
      if (String.isNotBlank(inst.Current_Step__c)) {
        Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
        stepExec.Workflow_Instance__c = inst.Id;
        stepExec.Step_Name__c = inst.Current_Step__c;
        stepExec.Status__c = 'Pending';
        stepExec.Input__c = inst.Input__c;
        stepExec.Retry_Count__c = 0;
        stepExecsToInsert.add(stepExec);
      }
    }
    if (!stepExecsToInsert.isEmpty()) {
      Database.insert(stepExecsToInsert, true, AccessLevel.SYSTEM_MODE);
    }
  }

  private static void scheduleOrPauseChildren(
    List<Workflow_Instance__c> instancesToUpdate
  ) {
    List<Workflow_Instance__c> instancesToSchedule = new List<Workflow_Instance__c>();
    List<Workflow_Instance__c> instancesToPause = new List<Workflow_Instance__c>();
    Boolean checkPause = WorkflowPauseGate.anyPaused();

    for (Workflow_Instance__c inst : instancesToUpdate) {
      if (
        checkPause &&
        WorkflowPauseGate.isDefinitionPaused(inst.Workflow_Name__c)
      ) {
        inst.Status__c = 'Paused';
        instancesToPause.add(inst);
      } else {
        if (!ConcurrencyGate.isConfigured(inst.Workflow_Name__c)) {
          instancesToSchedule.add(inst);
        } else {
          inst.Concurrency_Parked__c = true;
          instancesToPause.add(inst);
        }
      }
    }

    if (!instancesToPause.isEmpty()) {
      Database.update(instancesToPause, true, AccessLevel.SYSTEM_MODE);
    }

    if (!instancesToSchedule.isEmpty()) {
      scheduleTimeoutJobsForInstances(instancesToSchedule);
    }
  }

  private static void enqueueChildOrchestrators(
    List<Workflow_Instance__c> instancesToUpdate
  ) {
    if (Test.isRunningTest()) {
      return;
    }
    List<Id> instanceIdsToEnqueue = new List<Id>();
    for (Workflow_Instance__c inst : instancesToUpdate) {
      if (inst.Status__c != 'Paused') {
        instanceIdsToEnqueue.add(inst.Id);
      }
    }
    if (!instanceIdsToEnqueue.isEmpty()) {
      enqueueOrchestrators(instanceIdsToEnqueue);
    }
  }

  @TestVisible
  private static void notifyParentCompletion(
    Workflow_Instance__c childInstance
  ) {
    notifyParentCompletion(new List<Workflow_Instance__c>{ childInstance });
  }

  /**
   * Determines whether a parent instance is in a terminal or inactive state and
   * should therefore not receive a child-completion signal.
   * @param parent the parent workflow instance
   * @return true when the parent status is terminal/inactive
   */
  private static Boolean isParentInTerminalState(Workflow_Instance__c parent) {
    return parent.Status__c == 'Completed' ||
      parent.Status__c == 'Failed' ||
      parent.Status__c == 'Compensated' ||
      parent.Status__c == 'Cancelled' ||
      parent.Status__c == 'ContinuedAsNew' ||
      parent.Status__c == 'CompensationFailed';
  }

  /**
   * Builds the child-completion platform event delivered to a parent instance.
   * @param child the completed/failed child instance
   * @param parent the parent instance to notify
   * @return the Workflow_Event__e carrying the child outcome signal
   */
  private static Workflow_Event__e buildChildCompletionEvent(
    Workflow_Instance__c child,
    Workflow_Instance__c parent
  ) {
    String targetKey = String.isNotBlank(parent.Correlation_Key__c)
      ? parent.Correlation_Key__c
      : parent.Id;

    String signalName;
    String payload;
    if (child.Status__c == 'Completed') {
      signalName = 'ChildCompleted';
      payload = child.Output__c;
    } else {
      signalName = 'ChildFailed';
      Map<String, Object> outcomeData = new Map<String, Object>{
        'status' => child.Status__c,
        'errorMessage' => child.Error_Message__c != null
          ? child.Error_Message__c.left(10000)
          : null,
        'output' => child.Output__c
      };
      payload = savePayloadIfNeeded(
        parent.Id,
        JSON.serialize(outcomeData),
        'ChildFailedOutcome_' + child.Id
      );
    }

    signalName += String.isNotBlank(child.Correlation_Key__c)
      ? ':' + child.Correlation_Key__c
      : ':' + child.Id;

    return new Workflow_Event__e(
      Workflow_Instance_Id__c = targetKey,
      Event_Type__c = 'SIGNAL:' + signalName,
      Payload__c = payload
    );
  }

  /**
   * Publishes child-completion events and raises on any publish failure.
   * @param events platform events to publish (may be empty)
   */
  private static void publishChildCompletionEvents(
    List<Workflow_Event__e> events
  ) {
    if (events.isEmpty()) {
      return;
    }
    List<Database.SaveResult> srs = EventBus.publish(events);
    for (Database.SaveResult sr : srs) {
      if (sr.isSuccess()) {
        continue;
      }
      List<String> errMsgs = new List<String>();
      for (Database.Error err : sr.getErrors()) {
        errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
      }
      throw new WorkflowException(
        'Failed to publish child completion event: ' +
        String.join(errMsgs, ', ')
      );
    }
  }

  @TestVisible
  private static void notifyParentCompletion(
    List<Workflow_Instance__c> childInstances
  ) {
    if (childInstances == null || childInstances.isEmpty()) {
      return;
    }

    // Query child instances to ensure all fields are loaded (avoids SObjectException)
    List<Workflow_Instance__c> freshChildren = [
      SELECT
        Parent_Instance__c,
        Correlation_Key__c,
        Status__c,
        Error_Message__c,
        Output__c
      FROM Workflow_Instance__c
      WHERE Id IN :childInstances
      WITH SYSTEM_MODE
    ];

    List<Workflow_Instance__c> childrenWithParents = new List<Workflow_Instance__c>();
    Set<Id> parentIds = new Set<Id>();
    for (Workflow_Instance__c child : freshChildren) {
      if (child.Parent_Instance__c != null) {
        childrenWithParents.add(child);
        parentIds.add(child.Parent_Instance__c);
      }
    }

    if (childrenWithParents.isEmpty()) {
      return;
    }

    Map<Id, Workflow_Instance__c> parents = new Map<Id, Workflow_Instance__c>(
      [
        SELECT Correlation_Key__c, Status__c
        FROM Workflow_Instance__c
        WHERE Id IN :parentIds
        WITH SYSTEM_MODE
      ]
    );

    List<Workflow_Event__e> events = new List<Workflow_Event__e>();
    for (Workflow_Instance__c child : childrenWithParents) {
      Workflow_Instance__c parent = parents.get(child.Parent_Instance__c);
      if (parent == null) {
        continue;
      }

      // Skip if the parent is already terminal or inactive (avoids inserting stale Unrouted signals)
      if (isParentInTerminalState(parent)) {
        continue;
      }

      events.add(buildChildCompletionEvent(child, parent));
    }

    publishChildCompletionEvents(events);
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
        enqueueOrchestrator(instanceId, null);
      }
    } catch (Exception ignored) {
      // Queueable enqueue failed; fall back to the Platform Event path.
      enqueueOrchestrator(instanceId, null);
    }
  }

  /**
   * Sends external signals to multiple workflow instances in bulk.
   * @param requests the signal requests to deliver
   */
  public static void signal(List<SignalRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');
    Set<Id> ids = new Set<Id>();
    Set<String> keys = new Set<String>();

    for (SignalRequest req : requests) {
      if (req == null) {
        continue;
      }
      if (String.isNotBlank(req.keyOrId)) {
        if (
          idPattern.matcher(req.keyOrId).matches() &&
          req.keyOrId.startsWith(wflowPrefix)
        ) {
          ids.add((Id) req.keyOrId);
        } else {
          keys.add(req.keyOrId);
        }
      }
    }

    // Include CompensationFailed so a Cancel signal can reach a stalled rollback; the
    // per-request guard below still rejects non-cancel signals to a stalled instance,
    // preserving the active-only semantics for everything except cancellation.
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

    Map<String, Workflow_Instance__c> instById = new Map<String, Workflow_Instance__c>();
    Map<String, Workflow_Instance__c> instByKey = new Map<String, Workflow_Instance__c>();
    for (Workflow_Instance__c inst : instances) {
      instById.put(inst.Id, inst);
      String idStr = String.valueOf(inst.Id);
      if (idStr.length() == 18) {
        instById.put(idStr.substring(0, 15), inst);
      }
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        // Key by the normalized (lower-cased) correlation key: SOQL matched the
        // instance case-insensitively, so a request addressed as 'order-1' must
        // resolve the instance stored as 'Order-1' rather than miss the map and
        // be treated as unmatched (which would skip a keyed cancel entirely).
        instByKey.put(normalizeKey(inst.Correlation_Key__c), inst);
      }
    }

    // Separate requests into: matched (active instance found), unmatched
    // non-cancel (capture as Unrouted), and unmatched cancel. An unkeyed cancel
    // throws (capturing a cancel for future replay against an unknown future
    // instance is unsafe); a *keyed* cancel is an idempotent no-op (the first
    // delivery already drove the instance terminal, or there is nothing to
    // cancel), so it is swallowed rather than faulting the publisher.
    List<SignalRequest> unmatchedToCapture = new List<SignalRequest>();
    for (SignalRequest req : requests) {
      if (req == null) {
        continue;
      }
      Workflow_Instance__c inst = instById.get(req.keyOrId);
      if (inst == null) {
        inst = instByKey.get(normalizeKey(req.keyOrId));
      }
      Boolean isCancel =
        String.isNotBlank(req.signalName) &&
        (req.signalName.equalsIgnoreCase('Cancel') ||
        req.signalName.equalsIgnoreCase('CancelWorkflow'));
      Boolean unmatched =
        inst == null || (inst.Status__c == 'CompensationFailed' && !isCancel);
      if (unmatched) {
        if (isCancel) {
          if (String.isNotBlank(req.idempotencyKey)) {
            continue; // keyed cancel, no active match: idempotent no-op
          }
          throw new WorkflowException(
            'No active workflow found with key or ID: ' + req.keyOrId
          );
        }
        unmatchedToCapture.add(req);
      }
    }
    captureUnroutedSignals(unmatchedToCapture);

    // Keyed cancels: claim in bulk, then cancel. One savepoint plus one bulk
    // marker insert guards the whole keyed-cancel sub-batch — rather than a
    // savepoint and a marker insert per row, which would burn ~2 DML statements
    // each and abort large batches against the 150-statement limit. In-batch
    // duplicates collapse via seenCancelKeys; cross-transaction duplicates lose
    // the unique-constraint race (DUPLICATE_VALUE) and are skipped. A failed
    // cancel() rolls the batch's claims back so the same keys can be retried.
    List<Workflow_Signal__c> cancelClaims = new List<Workflow_Signal__c>();
    List<Id> cancelClaimInstIds = new List<Id>();
    List<Boolean> cancelClaimRunComp = new List<Boolean>();
    Set<String> seenCancelKeys = new Set<String>();
    // Instances driven to a terminal (no-compensation) Cancelled state by a
    // cancel in this batch. The forward-signal loop below must skip any sibling
    // signal for these — otherwise it would act on the stale pre-cancel status
    // and, for a Suspended instance, write that SObject back as Running,
    // resurrecting a workflow the cancel just drove to Cancelled. A cancel that
    // starts compensations leaves the instance Cancelling (still signalable), so
    // it is NOT added here; its cached status is refreshed instead.
    Set<Id> cancelledInstanceIds = new Set<Id>();
    for (SignalRequest req : requests) {
      if (req == null) {
        continue;
      }
      if (
        String.isBlank(req.idempotencyKey) ||
        String.isBlank(req.signalName) ||
        !(req.signalName.equalsIgnoreCase('Cancel') ||
        req.signalName.equalsIgnoreCase('CancelWorkflow'))
      ) {
        continue;
      }
      Workflow_Instance__c inst = instById.get(req.keyOrId);
      if (inst == null) {
        inst = instByKey.get(normalizeKey(req.keyOrId));
      }
      if (inst == null) {
        continue; // unmatched keyed cancel already no-op'd above
      }
      String claimKey = deriveSignalDedupKey(inst.Id, req.idempotencyKey);
      if (seenCancelKeys.contains(claimKey)) {
        continue; // in-batch duplicate keyed cancel
      }
      seenCancelKeys.add(claimKey);
      cancelClaims.add(
        new Workflow_Signal__c(
          Workflow_Instance__c = inst.Id,
          Signal_Name__c = req.signalName,
          Status__c = 'Consumed',
          Signal_Key__c = claimKey
        )
      );
      cancelClaimInstIds.add(inst.Id);
      cancelClaimRunComp.add(parseRunCompensations(req.payload));
    }
    if (!cancelClaims.isEmpty()) {
      Savepoint cancelSp = Database.setSavepoint();
      Database.SaveResult[] claimResults = Database.insert(
        cancelClaims,
        false,
        AccessLevel.SYSTEM_MODE
      );
      List<Integer> freshClaims = new List<Integer>();
      String claimError = null;
      for (Integer i = 0; i < claimResults.size(); i++) {
        Database.SaveResult sr = claimResults[i];
        if (sr.isSuccess()) {
          freshClaims.add(i);
        } else {
          Boolean isDup = false;
          for (Database.Error err : sr.getErrors()) {
            if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
              isDup = true;
              break;
            }
          }
          if (!isDup && claimError == null) {
            claimError = sr.getErrors()[0].getMessage();
          }
        }
      }
      if (claimError != null) {
        Database.rollback(cancelSp);
        throw new WorkflowException('Failed to claim cancel: ' + claimError);
      }
      Set<Id> attemptedCancelIds = new Set<Id>();
      try {
        for (Integer i : freshClaims) {
          cancelInstance(cancelClaimInstIds[i], cancelClaimRunComp[i]);
          attemptedCancelIds.add(cancelClaimInstIds[i]);
        }
      } catch (Exception e) {
        Database.rollback(cancelSp);
        throw e;
      }
      // Refresh post-cancel statuses in one query for the whole sub-batch. A
      // no-compensation cancel is terminal (Cancelled) and its sibling signals
      // must be skipped; a compensating cancel leaves the instance Cancelling
      // (still signalable), so refresh the cached SObject so the forward loop
      // wakes it as a compensating instance rather than resurrecting it.
      if (!attemptedCancelIds.isEmpty()) {
        for (Workflow_Instance__c refreshed : [
          SELECT Id, Status__c
          FROM Workflow_Instance__c
          WHERE Id IN :attemptedCancelIds
          WITH SYSTEM_MODE
        ]) {
          refreshCachedStatus(instById, refreshed);
          if (!isWakeableStatus(refreshed.Status__c)) {
            cancelledInstanceIds.add(refreshed.Id);
          }
        }
      }
    }

    // Separate into unkeyed (at-least-once, unchanged) and keyed (dedup by unique constraint).
    // For keyed signals, in-batch dedup prevents multiple rows for the same (instance, key)
    // within a single bulk call; the unique constraint handles concurrent transactions.
    List<Workflow_Signal__c> unkeyedSignals = new List<Workflow_Signal__c>();
    Set<String> seenCompositeKeys = new Set<String>();
    List<Workflow_Signal__c> keyedSignals = new List<Workflow_Signal__c>();
    List<Id> keyedSignalInstIds = new List<Id>(); // parallel: instance for each keyed signal
    Map<Id, Workflow_Instance__c> activeInstById = new Map<Id, Workflow_Instance__c>();
    Set<Id> instancesWithUnkeyedSignal = new Set<Id>();
    Map<Id, Set<String>> signalsByInstanceId = new Map<Id, Set<String>>();

    for (SignalRequest req : requests) {
      if (req == null) {
        continue;
      }
      Workflow_Instance__c inst = instById.get(req.keyOrId);
      if (inst == null) {
        inst = instByKey.get(normalizeKey(req.keyOrId));
      }
      if (inst != null) {
        if (!signalsByInstanceId.containsKey(inst.Id)) {
          signalsByInstanceId.put(inst.Id, new Set<String>());
        }
        signalsByInstanceId.get(inst.Id).add(req.signalName);
      }

      // A cancel earlier in this batch already drove this instance terminal; the
      // cached SObject is stale, so skip every sibling signal for it rather than
      // acting on the pre-cancel status and resurrecting a Cancelled workflow.
      if (inst != null && cancelledInstanceIds.contains(inst.Id)) {
        continue;
      }

      if (
        inst != null &&
        !(inst.Status__c == 'CompensationFailed' &&
        !(req.signalName.equalsIgnoreCase('Cancel') ||
        req.signalName.equalsIgnoreCase('CancelWorkflow')))
      ) {
        if (
          req.signalName.equalsIgnoreCase('Cancel') ||
          req.signalName.equalsIgnoreCase('CancelWorkflow')
        ) {
          if (String.isNotBlank(req.idempotencyKey)) {
            continue; // keyed cancel handled in the bulk-claim pre-pass above
          }
          cancelInstance(inst.Id, parseRunCompensations(req.payload));
          // Refresh the cached status so later sibling signals see the post-cancel
          // state: a terminal (no-compensation) cancel must skip them (otherwise
          // the stale SObject is woken back to Running), while a compensating
          // cancel stays signalable and is left for the wake logic. cancel()
          // already spends per-instance SOQL, so this targeted refresh keeps the
          // unkeyed path's cost in the same class.
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
          continue;
        }

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

        if (String.isNotBlank(req.idempotencyKey)) {
          // Keyed signal: compute per-instance hash for unique-constraint dedup.
          // In-batch dedup skips later duplicates with the same composite key.
          String compositeKey = deriveSignalDedupKey(
            inst.Id,
            req.idempotencyKey
          );
          if (!seenCompositeKeys.contains(compositeKey)) {
            seenCompositeKeys.add(compositeKey);
            sig.Signal_Key__c = compositeKey;
            keyedSignals.add(sig);
            keyedSignalInstIds.add(inst.Id);
            if (isWakeable) {
              activeInstById.put(inst.Id, inst);
            }
          }
          // else: in-batch duplicate — skip entirely (no row, no wake-up)
        } else {
          // Unkeyed signal: at-least-once behavior unchanged.
          unkeyedSignals.add(sig);
          if (isWakeable) {
            activeInstById.put(inst.Id, inst);
            instancesWithUnkeyedSignal.add(inst.Id);
          }
        }
      }
    }

    // Insert signals. A savepoint restores all-or-none semantics on a genuine
    // (non-duplicate) row failure: keyed inserts use allOrNone=false so a
    // concurrent-duplicate loser is swallowed as a no-op, but a real error
    // (e.g. an overlong Signal_Name__c from a direct Apex/Flow caller) must not
    // leave the already-inserted unkeyed rows and sibling keyed rows committed
    // when the method throws — a caller that catches the exception would
    // otherwise be left with a stranded Received signal and a consumed
    // idempotency key, so retrying the same batch would silently no-op.
    Set<Id> instancesWithFreshKeyedSignal = new Set<Id>();
    System.Savepoint sp = null;
    if (!unkeyedSignals.isEmpty() || !keyedSignals.isEmpty()) {
      sp = Database.setSavepoint();

      // Insert unkeyed signals (plain insert, unchanged at-least-once behavior).
      if (!unkeyedSignals.isEmpty()) {
        Database.insert(unkeyedSignals, true, AccessLevel.SYSTEM_MODE);
      }

      // Insert keyed signals with allOrNone=false; swallow per-row
      // DUPLICATE_VALUE (another transaction won the race) — that delivery is
      // still a success no-op. Genuine non-duplicate errors roll back and surface.
      if (!keyedSignals.isEmpty()) {
        Database.SaveResult[] srs = Database.insert(
          keyedSignals,
          false,
          AccessLevel.SYSTEM_MODE
        );
        String genuineError = null;
        for (Integer i = 0; i < srs.size(); i++) {
          Database.SaveResult sr = srs[i];
          if (sr.isSuccess()) {
            instancesWithFreshKeyedSignal.add(keyedSignalInstIds[i]);
          } else {
            Boolean isDup = false;
            for (Database.Error err : sr.getErrors()) {
              if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                isDup = true;
                break;
              }
            }
            if (!isDup && genuineError == null) {
              genuineError = sr.getErrors()[0].getMessage();
            }
          }
        }
        if (genuineError != null) {
          Database.rollback(sp);
          throw new WorkflowException(
            'Failed to insert signal: ' + genuineError
          );
        }
      }
    }

    // The signal inserts and the wake-up share the savepoint above so the bulk
    // call is all-or-none: the status flip (update), enqueueOrchestrators, and
    // enqueueResumeBulk can still throw after the rows are committed (e.g. a
    // validation rule on a Suspended instance or an EventBus publish failure),
    // so on any such failure we roll the inserted rows back before rethrowing.
    // Otherwise a caller that catches the exception would be left with stranded
    // Received rows and consumed idempotency keys, so retrying the same batch
    // would silently no-op and never wake the still-Suspended instances.
    try {
      // JOIN-READINESS BARRIER PRE-COMPUTATION
      Set<Id> gatedNonReadyParents = getGatedNonReadyParents(
        activeInstById.values(),
        signalsByInstanceId
      );

      // Only wake an instance if it received at least one fresh signal this call:
      // unkeyed signals always qualify; keyed signals only if the insert won the race.
      List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
      List<Workflow_Instance__c> activeInstances = new List<Workflow_Instance__c>();
      // Deduplicate: only process each active instance once.
      Set<Id> processedActiveIds = new Set<Id>();
      for (Workflow_Instance__c inst : activeInstById.values()) {
        if (processedActiveIds.contains(inst.Id)) {
          continue;
        }
        Boolean freshSignalLanded =
          instancesWithUnkeyedSignal.contains(inst.Id) ||
          instancesWithFreshKeyedSignal.contains(inst.Id);
        if (!freshSignalLanded) {
          continue;
        }
        processedActiveIds.add(inst.Id);
        // If the workflow is suspended or running, resume/orchestrate it. A
        // Compensating/Cancelling instance is mid-rollback: a compensation step
        // may depend on this signal, so wake it too rather than rejecting it. The
        // compensation status is left untouched (only Suspended flips to Running);
        // runStep re-detects the rollback from the trailing '_Compensate' step.
        // A Paused instance keeps its status — the held signal (Received) is
        // observed when resume re-drives the wait step; do not wake it here.
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
            continue;
          }
          if (gatedNonReadyParents.contains(inst.Id)) {
            continue;
          }
          inst.Status__c = 'Running';
          // Disarm the wait deadline (issue #35): a signal-wake ends the current
          // wait, so any armed Sleep_Until__c (timed-wait timeout, or a plain
          // sleeper's deadline) must be cleared or the watchdog would later
          // re-select this instance and mis-route/double-wake it. The resumed
          // step re-arms its own deadline if it suspends or sleeps again.
          inst.Sleep_Until__c = null;
          instancesToUpdate.add(inst);
        }
        if (!gatedNonReadyParents.contains(inst.Id)) {
          activeInstances.add(inst);
        }
      }

      if (!instancesToUpdate.isEmpty()) {
        Database.update(instancesToUpdate, true, AccessLevel.SYSTEM_MODE);
      }

      List<Id> instanceIdsToEnqueue = new List<Id>();
      List<Workflow_Instance__c> parallelInstances = new List<Workflow_Instance__c>();
      for (Workflow_Instance__c inst : activeInstances) {
        // A Compensating/Cancelling instance rolls back serially off the LIFO stack,
        // so it needs exactly one compensation wake -- never per-branch fan-out, even
        // if Current_Step__c still holds a stale comma-separated parallel branch list
        // from the forward phase. Otherwise one compensation signal would publish a
        // RUN_STEP per stale branch and pile up duplicate rollback workers.
        Boolean isCompensatingInst =
          inst.Status__c == 'Compensating' ||
          inst.Status__c == 'Cancelling';
        // Parallel (forward) instances must wake each branch by name; collect them
        // for a single bulk resume rather than a per-instance query each (which would
        // exhaust the SOQL limit when many parallel workflows are signaled at once).
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
      enqueueOrchestrators(instanceIdsToEnqueue);
      enqueueResumeBulk(parallelInstances);
    } catch (Exception e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      clearEnqueueGuards(activeInstById.keySet());
      throw e;
    }
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
    // Map each instance to its branch step names, and collect all branch names
    // for a single step-execution lookup.
    Map<Id, List<String>> branchesByInstance = new Map<Id, List<String>>();
    Set<String> allBranchNames = new Set<String>();
    for (Workflow_Instance__c inst : parallelInstances) {
      List<String> branches = new List<String>();
      for (String b : inst.Current_Step__c.split(',')) {
        branches.add(b.trim());
        allBranchNames.add(b.trim());
      }
      branchesByInstance.put(inst.Id, branches);
    }

    // One query: latest execution per (instance, branch step name).
    Map<String, String> latestStatusByKey = new Map<String, String>();
    for (Workflow_Step_Execution__c se : [
      SELECT Workflow_Instance__c, Step_Name__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :branchesByInstance.keySet()
        AND Step_Name__c IN :allBranchNames
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      String key = se.Workflow_Instance__c + '::' + se.Step_Name__c;
      if (!latestStatusByKey.containsKey(key)) {
        latestStatusByKey.put(key, se.Status__c);
      }
    }

    // Collect all branch RUN_STEP events and publish them in ONE EventBus call,
    // so signaling many parallel instances cannot exceed the publish/DML
    // statement limit (one publish per branch).
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

    if (!branchEvents.isEmpty()) {
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
   * Resumes a failed workflow instance from the step where it failed, resetting its state and retry counter.
   * @param instanceId Id of the failed instance to retry
   */
  public static void retryWorkflow(Id instanceId) {
    Workflow_Instance__c instance = loadInstanceForRetry(instanceId);

    List<String> stack = parseCompensationStack(instance);
    Boolean hasCompensations = !stack.isEmpty();

    List<String> targetStepNames = resolveRetryTargetSteps(
      instance,
      stack,
      hasCompensations
    );

    // Reset the failed step's execution status to let it execute again. Bulk-load the
    // latest execution per target step in ONE query (was one SOQL per step in a loop),
    // build a name->latest map, then update the resettable ones together.
    Map<String, Workflow_Step_Execution__c> latestStepByName = resetRetryTargetSteps(
      instanceId,
      targetStepNames
    );

    if (hasCompensations) {
      instance.Status__c = 'Compensating';
    } else {
      instance.Status__c = 'Running';
    }
    instance.Error_Message__c = null;
    instance.Failure_Category__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    // Enqueue the orchestrator to resume execution
    if (
      hasCompensations ||
      String.isBlank(instance.Current_Step__c) ||
      !instance.Current_Step__c.contains(',')
    ) {
      enqueueOrchestratorForInstance(instanceId);
      return;
    }

    enqueueParallelBranchRetries(instanceId, targetStepNames, latestStepByName);
  }

  private static Workflow_Instance__c loadInstanceForRetry(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Status__c,
        Current_Step__c,
        Error_Message__c,
        Compensation_Stack__c,
        Workflow_Name__c,
        Failure_Category__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instanceId);
    }
    Workflow_Instance__c instance = instances[0];
    if (instance.Status__c != 'Failed') {
      throw new WorkflowException(
        'Workflow instance is not in Failed status. Current status: ' +
        instance.Status__c
      );
    }
    return instance;
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

  private static List<String> resolveRetryTargetSteps(
    Workflow_Instance__c instance,
    List<String> stack,
    Boolean hasCompensations
  ) {
    List<String> targetStepNames = new List<String>();
    if (hasCompensations) {
      targetStepNames.add(stack[stack.size() - 1] + '_Compensate');
    } else if (String.isNotBlank(instance.Current_Step__c)) {
      if (instance.Current_Step__c.contains(',')) {
        for (String pStep : instance.Current_Step__c.split(',')) {
          targetStepNames.add(pStep.trim());
        }
      } else {
        targetStepNames.add(instance.Current_Step__c);
      }
    }
    applyRetryInitialStepFallback(instance, targetStepNames, hasCompensations);
    return targetStepNames;
  }

  // When a Failed instance has no current step and no compensations, resolve
  // the workflow's initial step so retry has a concrete step to drive. Mutates
  // instance.Current_Step__c and appends to targetStepNames in place.
  private static void applyRetryInitialStepFallback(
    Workflow_Instance__c instance,
    List<String> targetStepNames,
    Boolean hasCompensations
  ) {
    if (!(String.isBlank(instance.Current_Step__c) && !hasCompensations)) {
      return;
    }
    Type wflowType = WorkflowTypeResolver.resolve(
      instance.Workflow_Name__c,
      WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
    );
    if (wflowType == null) {
      return;
    }
    Object defObj = wflowType.newInstance();
    if (defObj instanceof WorkflowDefinition) {
      instance.Current_Step__c = ((WorkflowDefinition) defObj).getInitialStep();
      targetStepNames.add(instance.Current_Step__c);
    }
  }

  private static Map<String, Workflow_Step_Execution__c> resetRetryTargetSteps(
    Id instanceId,
    List<String> targetStepNames
  ) {
    Map<String, Workflow_Step_Execution__c> latestStepByName = new Map<String, Workflow_Step_Execution__c>();
    if (!targetStepNames.isEmpty()) {
      for (Workflow_Step_Execution__c se : [
        SELECT Id, Step_Name__c, Status__c, Retry_Count__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c IN :targetStepNames
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
      ]) {
        if (!latestStepByName.containsKey(se.Step_Name__c)) {
          latestStepByName.put(se.Step_Name__c, se);
        }
      }
    }

    List<Workflow_Step_Execution__c> stepsToReset = new List<Workflow_Step_Execution__c>();
    for (String targetStepName : targetStepNames) {
      Workflow_Step_Execution__c stepExec = latestStepByName.get(
        targetStepName
      );
      if (
        stepExec != null &&
        stepExec.Status__c != 'Completed' &&
        stepExec.Status__c != 'OperatorSkipped'
      ) {
        stepExec.Status__c = 'Pending';
        stepExec.Retry_Count__c = 0; // reset retry counter
        stepExec.Error_Details__c = null;
        stepsToReset.add(stepExec);
      }
    }
    if (!stepsToReset.isEmpty()) {
      Database.update(stepsToReset, true, AccessLevel.SYSTEM_MODE);
    }
    return latestStepByName;
  }

  // Parallel forward execution retry: enqueue only incomplete branches. Reuse the
  // already-loaded step map (reset steps are now 'Pending' in memory) instead of
  // re-querying once per branch. The per-branch enqueue is delegated to
  // enqueueParallelBranchRetryOne so it is not lexically inside this loop.
  private static void enqueueParallelBranchRetries(
    Id instanceId,
    List<String> targetStepNames,
    Map<String, Workflow_Step_Execution__c> latestStepByName
  ) {
    for (String targetStepName : targetStepNames) {
      Workflow_Step_Execution__c stepExec = latestStepByName.get(
        targetStepName
      );
      Boolean incomplete =
        stepExec == null ||
        (stepExec.Status__c != 'Completed' &&
        stepExec.Status__c != 'OperatorSkipped');
      if (!incomplete) {
        continue;
      }
      enqueueParallelBranchRetryOne(instanceId, targetStepName);
    }
  }

  /**
   * @description Enqueues a single parallel-branch retry, direct-enqueue under
   * test and via the standard `enqueueOrchestrator` path otherwise. Kept as a
   * helper so the test-only per-branch `System.enqueueJob` is not lexically
   * inside `enqueueParallelBranchRetries`'s loop. Test-only enqueue continues
   * to honor `disableQueueableInTest`.
   * @param instanceId the parent workflow instance to resume
   * @param targetStepName the target branch step name to drive
   */
  private static void enqueueParallelBranchRetryOne(
    Id instanceId,
    String targetStepName
  ) {
    if (!Test.isRunningTest()) {
      enqueueOrchestrator(instanceId, targetStepName);
      return;
    }
    if (!disableQueueableInTest) {
      System.enqueueJob(new WorkflowOrchestrator(instanceId, targetStepName));
    }
  }

  /**
   * Returns the count of non-terminal workflow instances that have recorded
   * a decision of 'false' for the given changeId.
   *
   * @param changeId The unique name of the patch.
   * @return The number of active instances pinning the old branch.
   */
  public static Integer getPatchAdoptionCount(String changeId) {
    return getPatchAdoptionCount(null, changeId, null);
  }

  /**
   * Returns the count of non-terminal workflow instances that have recorded
   * a decision of 'false' for the given changeId, using an optional introduction date
   * to count legacy instances that have not yet reached the patch check.
   *
   * @param changeId The unique name of the patch.
   * @param introducedAt Optional DateTime representing when the patch was introduced.
   * @return The number of active instances pinning the old branch.
   */
  public static Integer getPatchAdoptionCount(
    String changeId,
    DateTime introducedAt
  ) {
    return getPatchAdoptionCount(null, changeId, introducedAt);
  }

  // Mutable accumulator threaded through the patch-adoption scan helpers so each
  // helper stays within the parameter and complexity budgets.
  private class AdoptionScan {
    String key;
    Set<String> targetWorkflows = new Set<String>();
    Set<Id> instancesWithExplicitFalse = new Set<Id>();
  }

  /**
   * Returns the count of non-terminal workflow instances that have recorded
   * a decision of 'false' for the given changeId, scoped to a specific workflow name
   * and using an optional introduction date.
   *
   * @param workflowName Optional name of the workflow to scope active scans to.
   * @param changeId The unique name of the patch.
   * @param introducedAt Optional DateTime representing when the patch was introduced.
   * @return The number of active instances pinning the old branch.
   */
  public static Integer getPatchAdoptionCount(
    String workflowName,
    String changeId,
    DateTime introducedAt
  ) {
    if (String.isBlank(changeId)) {
      return 0;
    }
    Integer queryLimit = adoptionQueryLimit;

    // 1. Query all active (non-terminal) workflow instances directly
    List<Workflow_Instance__c> instances = queryAdoptionInstances(
      workflowName,
      queryLimit
    );

    if (instances.size() >= queryLimit) {
      throw new WorkflowException(
        'Active instances exceed query limit (' +
          queryLimit +
          ' rows). Adoption count cannot be computed reliably.'
      );
    }

    AdoptionScan scan = new AdoptionScan();
    scan.key = '__patch:' + changeId;
    if (String.isNotBlank(workflowName)) {
      scan.targetWorkflows.add(workflowName);
    }

    // 2. Query step executions in batches of 1,000 instances to stay under 50k SOQL row limits
    scanInstancesForExplicitFalse(instances, scan);

    // 3. Count instances pinning the legacy branch
    return countPinnedInstances(instances, introducedAt, scan);
  }

  private static List<Workflow_Instance__c> queryAdoptionInstances(
    String workflowName,
    Integer queryLimit
  ) {
    if (Test.isRunningTest() && mockInstancesForAdoption != null) {
      return mockInstancesForAdoption;
    }
    if (String.isNotBlank(workflowName)) {
      return [
        SELECT Id, Workflow_Name__c, CreatedDate
        FROM Workflow_Instance__c
        WHERE Status__c IN :ACTIVE_STATUSES AND Workflow_Name__c = :workflowName
        WITH SYSTEM_MODE
        LIMIT :queryLimit
      ];
    }
    return [
      SELECT Id, Workflow_Name__c, CreatedDate
      FROM Workflow_Instance__c
      WHERE Status__c IN :ACTIVE_STATUSES
      WITH SYSTEM_MODE
      LIMIT :queryLimit
    ];
  }

  // Batch step-execution query stays in-loop (OperationWithLimitsInLoop deferred
  // to PR #3): one SOQL per 1,000-instance batch to stay under the 50k row cap.
  private static void scanInstancesForExplicitFalse(
    List<Workflow_Instance__c> instances,
    AdoptionScan scan
  ) {
    Integer instanceBatchSize = 1000;
    for (Integer i = 0; i < instances.size(); i += instanceBatchSize) {
      List<Workflow_Instance__c> batchInstances = sliceInstances(
        instances,
        i,
        instanceBatchSize
      );

      List<Workflow_Step_Execution__c> execs = [
        SELECT
          Workflow_Instance__c,
          Captured_Values__c,
          Workflow_Instance__r.Workflow_Name__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c IN :batchInstances
        WITH SYSTEM_MODE
      ];

      List<String> resolvedCaptures = resolveCapturesInBatches(execs);
      applyExecCaptures(execs, resolvedCaptures, scan);
    }
  }

  private static List<Workflow_Instance__c> sliceInstances(
    List<Workflow_Instance__c> instances,
    Integer start,
    Integer batchSize
  ) {
    List<Workflow_Instance__c> batch = new List<Workflow_Instance__c>();
    for (
      Integer j = start; j < start + batchSize && j < instances.size(); j++
    ) {
      batch.add(instances[j]);
    }
    return batch;
  }

  // Process offloaded payloads in small batches of 40 to stay under Apex Heap
  // Limits (synchronous cap is 6 MB).
  private static List<String> resolveCapturesInBatches(
    List<Workflow_Step_Execution__c> execs
  ) {
    Integer offloadBatchSize = 40;
    List<String> resolvedCaptures = new List<String>();
    for (Integer k = 0; k < execs.size(); k += offloadBatchSize) {
      List<String> batchRaw = new List<String>();
      for (Integer m = k; m < k + offloadBatchSize && m < execs.size(); m++) {
        batchRaw.add(execs[m].Captured_Values__c);
      }
      resolvedCaptures.addAll(resolvePayloads(batchRaw));
    }
    return resolvedCaptures;
  }

  private static void applyExecCaptures(
    List<Workflow_Step_Execution__c> execs,
    List<String> resolvedCaptures,
    AdoptionScan scan
  ) {
    for (Integer k = 0; k < execs.size(); k++) {
      applyExecCapture(execs[k], resolvedCaptures[k], scan);
    }
  }

  private static void applyExecCapture(
    Workflow_Step_Execution__c exec,
    String capturesJson,
    AdoptionScan scan
  ) {
    if (String.isBlank(capturesJson)) {
      return;
    }
    if (!capturesJson.contains(scan.key)) {
      return;
    }
    try {
      Map<String, Object> captures = (Map<String, Object>) JSON.deserializeUntyped(
        capturesJson
      );
      if (captures.containsKey(scan.key)) {
        scan.targetWorkflows.add(exec.Workflow_Instance__r.Workflow_Name__c);
        if (captures.get(scan.key) == false) {
          scan.instancesWithExplicitFalse.add(exec.Workflow_Instance__c);
        }
      }
    } catch (Exception ignored) {
      // Ignore malformed JSON
    }
  }

  private static Integer countPinnedInstances(
    List<Workflow_Instance__c> instances,
    DateTime introducedAt,
    AdoptionScan scan
  ) {
    Set<Id> instancesWithFalse = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      String wflow = inst.Workflow_Name__c;
      if (!scan.targetWorkflows.contains(wflow)) {
        continue;
      }

      if (introducedAt != null && inst.CreatedDate < introducedAt) {
        // Active instance of a target workflow created before patch introduction
        instancesWithFalse.add(inst.Id);
        continue;
      }

      if (scan.instancesWithExplicitFalse.contains(inst.Id)) {
        instancesWithFalse.add(inst.Id);
      }
    }

    return instancesWithFalse.size();
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

  // Mutable accumulator threaded through the resume-past-step phase helpers so
  // each helper stays within the parameter and complexity budgets.
  private class ResumeSkipRun {
    Workflow_Instance__c instance;
    Id instanceId;
    String stepName;
    String suppliedOutputJson;
    Workflow_Step_Execution__c latestExec;
    Workflow_Step_Execution__c skipExec;
    WorkflowDefinition def;
    List<String> activeParallelSteps;
    Map<String, Workflow_Step_Execution__c> latestParallelMap;
  }

  /**
   * Operator action to resume a failed instance past a failed step by supplying
   * that step's resolved output and resuming forward execution.
   * @param instanceId Id of the failed instance to resume
   * @param stepName name of the failed step being resolved
   * @param suppliedOutputJson operator-supplied resolved output for that step
   */
  public static void resumePastStep(
    Id instanceId,
    String stepName,
    String suppliedOutputJson
  ) {
    if (instanceId == null) {
      throw new WorkflowException('Instance ID is required.');
    }
    if (String.isBlank(stepName)) {
      throw new WorkflowException('Step name is required.');
    }

    // 1. Fetch and lock instance state + 2. Validate status
    Workflow_Instance__c instance = lockFailedInstanceForSkip(instanceId);

    // 3. Validate step is currently active and normalize casing to match definition exactly
    stepName = validateAndNormalizeSkipStep(instance, stepName);

    // 4. Retrieve latest step execution with row lock (FOR UPDATE)
    Workflow_Step_Execution__c latestExec = lockLatestFailedStepExec(
      instanceId,
      stepName
    );

    // 5. Parse and validate supplied output JSON
    validateSuppliedSkipOutput(suppliedOutputJson);

    ResumeSkipRun run = new ResumeSkipRun();
    run.instance = instance;
    run.instanceId = instanceId;
    run.stepName = stepName;
    run.suppliedOutputJson = suppliedOutputJson;
    run.latestExec = latestExec;

    Savepoint sp = Database.setSavepoint();
    try {
      // 6. Record skip as a new Step Execution row
      recordOperatorSkip(run);
      // 7. Log operator intervention
      logOperatorSkipIntervention(run);
      // 8. Determine next step and advance
      advanceAfterSkip(run);
    } catch (Exception ex) {
      Database.rollback(sp);
      throw ex;
    }
  }

  // Fetch/lock the instance and require Failed status for a resume-past-step.
  private static Workflow_Instance__c lockFailedInstanceForSkip(Id instanceId) {
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
        Previous_Run_At__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      FOR UPDATE
    ];

    if (instances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instanceId);
    }
    Workflow_Instance__c instance = instances[0];

    if (instance.Status__c != 'Failed') {
      throw new WorkflowException(
        'Resume past step is only allowed for instances in Failed state. Current status: ' +
        instance.Status__c
      );
    }
    return instance;
  }

  // Confirm the requested step is the active/expected step, returning the
  // definition-normalized casing. Throws when the step is not resumable.
  private static String validateAndNormalizeSkipStep(
    Workflow_Instance__c instance,
    String stepName
  ) {
    String normalized = matchStepNameCandidate(
      instance.Current_Step__c,
      stepName
    );
    if (normalized == null) {
      throw new WorkflowException(
        'Step ' +
          stepName +
          ' is not the active/expected step for this instance: ' +
          instance.Current_Step__c
      );
    }
    return normalized;
  }

  // Resolve the definition-normalized casing for stepName within currentStep
  // (which may be a comma-separated parallel-branch list). Returns null when the
  // step is not among the active steps.
  private static String matchStepNameCandidate(
    String currentStep,
    String stepName
  ) {
    if (String.isBlank(currentStep)) {
      return null;
    }
    if (!currentStep.contains(',')) {
      return currentStep.equalsIgnoreCase(stepName) ? currentStep : null;
    }
    for (String s : currentStep.split(',')) {
      if (s.trim().equalsIgnoreCase(stepName)) {
        return s.trim();
      }
    }
    return null;
  }

  // Retrieve and FOR UPDATE-lock the latest execution for the step, requiring
  // it to be in Failed status before it can be operator-skipped.
  private static Workflow_Step_Execution__c lockLatestFailedStepExec(
    Id instanceId,
    String stepName
  ) {
    List<Workflow_Step_Execution__c> stepExecsWithoutLock = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Step_Name__c = :stepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (stepExecsWithoutLock.isEmpty()) {
      throw new WorkflowException(
        'No execution record found for step: ' + stepName
      );
    }
    Id latestStepExecId = stepExecsWithoutLock[0].Id;

    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Status__c, Input__c, Retry_Count__c, Transient_Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :latestStepExecId
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    Workflow_Step_Execution__c latestExec = stepExecs[0];
    if (latestExec.Status__c != 'Failed') {
      throw new WorkflowException(
        'Step ' +
          stepName +
          ' cannot be skipped because it is not in Failed status. Current status: ' +
          latestExec.Status__c
      );
    }
    return latestExec;
  }

  // Validate operator-supplied output JSON: size, reserved markers, parseability.
  private static void validateSuppliedSkipOutput(String suppliedOutputJson) {
    if (String.isBlank(suppliedOutputJson)) {
      return;
    }
    if (suppliedOutputJson.length() > 250000) {
      throw new WorkflowException(
        'Supplied output size exceeds maximum allowed limit of 250KB.'
      );
    }
    if (suppliedOutputJson.contains('"$attachmentId"')) {
      throw new WorkflowException(
        'Operator-supplied payload cannot contain reserved "$attachmentId" markers.'
      );
    }
    try {
      JSON.deserializeUntyped(suppliedOutputJson);
    } catch (Exception ex) {
      throw new WorkflowException(
        'Supplied output is not valid JSON: ' + ex.getMessage()
      );
    }
  }

  // Record the operator skip as a new OperatorSkipped step execution row.
  private static void recordOperatorSkip(ResumeSkipRun run) {
    Workflow_Step_Execution__c skipExec = new Workflow_Step_Execution__c();
    skipExec.Workflow_Instance__c = run.instanceId;
    skipExec.Step_Name__c = run.stepName;
    skipExec.Status__c = 'OperatorSkipped';
    skipExec.Retry_Count__c = 0;
    skipExec.Transient_Retry_Count__c = 0;
    skipExec.Input__c = run.latestExec.Input__c;
    skipExec.Output__c = savePayloadIfNeeded(
      run.instanceId,
      run.suppliedOutputJson,
      'Output_' + run.stepName.replaceAll('[^a-zA-Z0-9]', '_')
    );
    Database.insert(skipExec, true, AccessLevel.SYSTEM_MODE);
    run.skipExec = skipExec;
  }

  // Write the operator-intervention audit log for the skip.
  private static void logOperatorSkipIntervention(ResumeSkipRun run) {
    Workflow_Instance__c instance = run.instance;
    String suppliedOutputJson = run.suppliedOutputJson;
    String msg =
      'User ' +
      UserInfo.getUserName() +
      ' (' +
      UserInfo.getName() +
      ') skipped step ' +
      run.stepName +
      ' on instance ' +
      instance.Name +
      ' (Correlation Key: ' +
      instance.Correlation_Key__c +
      ') providing output: ' +
      (suppliedOutputJson != null &&
        suppliedOutputJson.length() > 500
        ? suppliedOutputJson.substring(0, 500) + '...'
        : suppliedOutputJson);

    Workflow_Log__c interventionLog = new Workflow_Log__c(
      Workflow_Instance__c = run.instanceId,
      Workflow_Name__c = instance.Workflow_Name__c,
      Correlation_Key__c = instance.Correlation_Key__c,
      Log_Type__c = 'OperatorIntervention',
      Message__c = msg.left(131072),
      Outcome__c = 'Success',
      Level__c = 'INFO',
      Fire_Time__c = DateTime.now()
    );
    Database.insert(interventionLog, true, AccessLevel.SYSTEM_MODE);
  }

  // Resolve the workflow definition and dispatch to the single-branch or
  // parallel-branch advancement path.
  private static void advanceAfterSkip(ResumeSkipRun run) {
    Workflow_Instance__c instance = run.instance;
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
    run.def = (WorkflowDefinition) wflowType.newInstance();

    Boolean isParallel =
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',');

    if (!isParallel) {
      advanceSingleBranchSkip(run);
    } else {
      advanceParallelSkip(run);
    }
  }

  // Advance a single (non-parallel) branch after an operator skip.
  private static void advanceSingleBranchSkip(ResumeSkipRun run) {
    Workflow_Instance__c instance = run.instance;
    String stepName = run.stepName;
    String suppliedOutputJson = run.suppliedOutputJson;

    StepResult mockResult = new StepResult();
    mockResult.action = StepResult.ActionType.COMPLETE;
    mockResult.nextStepName = 'SENTINEL_NEXT_STEP';
    mockResult.outputJson = suppliedOutputJson;
    String nextStepName;
    if (run.def instanceof VersionedWorkflow) {
      nextStepName = ((VersionedWorkflow) run.def)
        .getNextStep(
          stepName,
          mockResult,
          instance.Definition_Version__c != null
            ? (Integer) instance.Definition_Version__c
            : 1
        );
    } else {
      nextStepName = run.def.getNextStep(stepName, mockResult);
    }

    if (nextStepName == 'SENTINEL_NEXT_STEP') {
      throw new WorkflowException(
        'Skip is not supported for dynamic-next step definitions.'
      );
    }

    if (String.isBlank(nextStepName)) {
      // Workflow is completed
      markSkipInstanceCompleted(run, suppliedOutputJson, 'Output_Final');
      return;
    }

    // Advance to next step
    instance.Current_Step__c = nextStepName;
    instance.Status__c = 'Running';
    instance.Error_Message__c = null;
    instance.Failure_Category__c = null;
    Boolean deferTimeoutForConcurrency = ConcurrencyGate.isConfigured(
      instance.Workflow_Name__c
    );
    if (deferTimeoutForConcurrency) {
      instance.Concurrency_Parked__c = true;
    }
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    Workflow_Step_Execution__c nextStepExec = new Workflow_Step_Execution__c();
    nextStepExec.Workflow_Instance__c = instance.Id;
    nextStepExec.Step_Name__c = nextStepName;
    nextStepExec.Status__c = 'Pending';
    nextStepExec.Input__c = run.skipExec.Output__c;
    nextStepExec.Retry_Count__c = 0;
    Database.insert(nextStepExec, true, AccessLevel.SYSTEM_MODE);

    if (!deferTimeoutForConcurrency) {
      scheduleTimeoutJobForInstance(instance.Id);
    }
    enqueueSkipOrchestrator(instance.Id);
  }

  // Advance parallel branches after an operator skip: join when all done,
  // otherwise re-drive the incomplete siblings.
  private static void advanceParallelSkip(ResumeSkipRun run) {
    // Parallel branches: load all parallel step executions to see if we can join
    run.activeParallelSteps = run.instance.Current_Step__c.split(',');
    run.latestParallelMap = loadResumeParallelExecs(run);

    Boolean allDone = isAllParallelDone(
      run.activeParallelSteps,
      run.latestParallelMap
    );

    String nextStepName = resolveParallelSkipNextStep(run);

    if (allDone) {
      completeOrJoinParallel(run, nextStepName);
    } else {
      resumeIncompleteParallel(run);
    }
  }

  // Load the latest execution per active parallel step (including Timeout_At__c).
  private static Map<String, Workflow_Step_Execution__c> loadResumeParallelExecs(
    ResumeSkipRun run
  ) {
    Id instanceId = run.instanceId;
    List<String> activeParallelSteps = run.activeParallelSteps;
    Map<String, Workflow_Step_Execution__c> latestParallelMap = new Map<String, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c pe : [
      SELECT Step_Name__c, Status__c, Output__c, CPU_Time_Ms__c, Timeout_At__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c IN :activeParallelSteps
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      if (!latestParallelMap.containsKey(pe.Step_Name__c)) {
        latestParallelMap.put(pe.Step_Name__c, pe);
      }
    }
    return latestParallelMap;
  }

  // Resolve the join/next step for the parallel skip via the spawning step.
  private static String resolveParallelSkipNextStep(ResumeSkipRun run) {
    Workflow_Instance__c instance = run.instance;
    Id instanceId = run.instanceId;
    List<String> activeParallelSteps = run.activeParallelSteps;
    // Spawning step
    List<Workflow_Step_Execution__c> spawningSteps = [
      SELECT Step_Name__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Status__c IN ('Completed', 'OperatorSkipped')
        AND Step_Name__c NOT IN :activeParallelSteps
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    String spawningStepName = !spawningSteps.isEmpty()
      ? spawningSteps[0].Step_Name__c
      : '';
    StepResult mockSpawningResult = StepResult.complete(
      'SENTINEL_NEXT_STEP',
      !spawningSteps.isEmpty() ? spawningSteps[0].Output__c : null
    );

    String nextStepName;
    if (run.def instanceof VersionedWorkflow) {
      nextStepName = ((VersionedWorkflow) run.def)
        .getNextStep(
          spawningStepName,
          mockSpawningResult,
          instance.Definition_Version__c != null
            ? (Integer) instance.Definition_Version__c
            : 1
        );
    } else {
      nextStepName = run.def.getNextStep(spawningStepName, mockSpawningResult);
    }

    if (nextStepName == 'SENTINEL_NEXT_STEP') {
      throw new WorkflowException(
        'Skip is not supported for dynamic-next step definitions.'
      );
    }
    return nextStepName;
  }

  // All parallel branches are done: build the join input and either complete
  // the workflow or spawn the join step.
  private static void completeOrJoinParallel(
    ResumeSkipRun run,
    String nextStepName
  ) {
    Workflow_Instance__c instance = run.instance;
    String joinInputJson = buildParallelJoinInput(run);

    if (String.isBlank(nextStepName)) {
      markSkipInstanceCompleted(run, joinInputJson, 'Output_Join');
      return;
    }

    Workflow_Step_Execution__c joinStepExec = new Workflow_Step_Execution__c();
    joinStepExec.Workflow_Instance__c = instance.Id;
    joinStepExec.Step_Name__c = nextStepName;
    joinStepExec.Status__c = 'Pending';
    joinStepExec.Input__c = savePayloadIfNeeded(
      instance.Id,
      joinInputJson,
      'Input_' + nextStepName.replaceAll('[^a-zA-Z0-9]', '_')
    );
    joinStepExec.Retry_Count__c = 0;
    Database.insert(joinStepExec, true, AccessLevel.SYSTEM_MODE);

    instance.Current_Step__c = nextStepName;
    instance.Status__c = 'Running';
    instance.Error_Message__c = null;
    instance.Failure_Category__c = null;
    Boolean deferTimeoutForConcurrency = ConcurrencyGate.isConfigured(
      instance.Workflow_Name__c
    );
    if (deferTimeoutForConcurrency) {
      instance.Concurrency_Parked__c = true;
    }
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    if (!deferTimeoutForConcurrency) {
      scheduleTimeoutJobForInstance(instance.Id);
    }
    enqueueSkipOrchestrator(instance.Id);
  }

  // Assemble the merged join input JSON from every parallel branch's output.
  private static String buildParallelJoinInput(ResumeSkipRun run) {
    Map<String, Object> joinInput = new Map<String, Object>();
    for (String ps : run.latestParallelMap.keySet()) {
      Workflow_Step_Execution__c pe = run.latestParallelMap.get(ps);
      Object outputVal = null;
      String resolvedOutput = resolvePayload(pe.Output__c);
      if (String.isNotBlank(resolvedOutput)) {
        try {
          outputVal = JSON.deserializeUntyped(resolvedOutput);
        } catch (Exception ex) {
          outputVal = resolvedOutput;
        }
      }
      joinInput.put(pe.Step_Name__c, outputVal);
    }
    return JSON.serialize(joinInput);
  }

  // Drive an instance to Completed terminal state after an operator skip.
  private static void markSkipInstanceCompleted(
    ResumeSkipRun run,
    String outputJson,
    String payloadName
  ) {
    Workflow_Instance__c instance = run.instance;
    instance.Status__c = 'Completed';
    instance.Terminal_At__c = DateTime.now();
    instance.Output__c = savePayloadIfNeeded(
      run.instanceId,
      outputJson,
      payloadName
    );
    instance.Current_Step__c = null;
    instance.Error_Message__c = null;
    instance.Failure_Category__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    notifyParentCompletion(instance);
    WorkflowLifecyclePublisher.publish(instance);
  }

  // Enqueue the next orchestrator pass after a single/join skip advancement.
  private static void enqueueSkipOrchestrator(Id instanceId) {
    if (Test.isRunningTest() && disableQueueableInTest) {
      System.enqueueJob(new WorkflowOrchestrator(instanceId));
    } else {
      enqueueOrchestrator(instanceId, null);
    }
  }

  // Not all parallel branches are done: re-drive the incomplete siblings.
  private static void resumeIncompleteParallel(ResumeSkipRun run) {
    Workflow_Instance__c instance = run.instance;
    Boolean hasParkedSibling = hasParkedParallelSibling(run);

    instance.Status__c = hasParkedSibling ? 'Suspended' : 'Running';
    instance.Error_Message__c = null;
    instance.Failure_Category__c = null;
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    Set<String> stepsToEnqueue = new Set<String>();
    List<Workflow_Step_Execution__c> stepsToReset = new List<Workflow_Step_Execution__c>();
    collectParallelResumeSteps(run, stepsToEnqueue, stepsToReset);
    if (!stepsToReset.isEmpty()) {
      Database.update(stepsToReset, true, AccessLevel.SYSTEM_MODE);
    }

    for (String ps : stepsToEnqueue) {
      enqueueParallelResumeStep(run.instanceId, ps);
    }
  }

  /**
   * @description Enqueues a single parallel-resume step, direct-enqueue under
   * test and via the standard `enqueueOrchestrator` path otherwise. Kept as a
   * helper so the test-only per-step `System.enqueueJob` is not lexically
   * inside the caller's loop. Test-only enqueue continues to honor
   * `disableQueueableInTest`.
   * @param instanceId the parent workflow instance to resume
   * @param stepName the parallel-sibling step name to drive
   */
  private static void enqueueParallelResumeStep(Id instanceId, String stepName) {
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instanceId, stepName));
      }
    } else {
      enqueueOrchestrator(instanceId, stepName);
    }
  }

  // True when a non-skipped sibling branch is parked (Retrying, or Pending with
  // recorded CPU time), meaning the instance should stay Suspended.
  private static Boolean hasParkedParallelSibling(ResumeSkipRun run) {
    for (String ps : run.activeParallelSteps) {
      if (ps.equalsIgnoreCase(run.stepName)) {
        continue;
      }
      Workflow_Step_Execution__c pe = run.latestParallelMap.get(ps);
      if (
        pe != null &&
        (pe.Status__c == 'Retrying' ||
        (pe.Status__c == 'Pending' &&
        pe.CPU_Time_Ms__c != null))
      ) {
        return true;
      }
    }
    return false;
  }

  // Determine which sibling branches to reset/enqueue for parallel resume.
  private static void collectParallelResumeSteps(
    ResumeSkipRun run,
    Set<String> stepsToEnqueue,
    List<Workflow_Step_Execution__c> stepsToReset
  ) {
    for (String ps : run.activeParallelSteps) {
      if (ps.equalsIgnoreCase(run.stepName)) {
        continue;
      }
      Workflow_Step_Execution__c pe = run.latestParallelMap.get(ps);
      if (pe == null) {
        stepsToEnqueue.add(ps);
      } else if (pe.Status__c == 'Failed') {
        pe.Status__c = 'Pending';
        pe.Retry_Count__c = 0;
        pe.Error_Details__c = null;
        stepsToReset.add(pe);
        stepsToEnqueue.add(ps);
      } else if (pe.Status__c == 'Pending' && pe.CPU_Time_Ms__c == null) {
        // Initial/undriven pending branch: enqueue it directly after re-arming/clearing timeout
        Integer timeout = getStepTimeoutSeconds(
          ps,
          WorkflowTypeResolver.extractNamespace(run.instance.Workflow_Name__c)
        );
        if (timeout != null && timeout > 0) {
          pe.Timeout_At__c = DateTime.now().addSeconds(timeout);
        } else {
          pe.Timeout_At__c = null;
        }
        stepsToReset.add(pe);
        stepsToEnqueue.add(ps);
      }
    }
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

    scheduleTimeoutJobForInstance(instance.Id);
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instance.Id));
      }
    } else {
      enqueueOrchestrator(instance.Id, null);
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
  private static void appendCompensationRetryStep(
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
    notifyParentCompletion(instance);
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
      scheduleTimeoutJobForInstance(instance.Id);
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
      enqueueOrchestrator(instanceId, null);
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
        scheduleTimeoutJobForInstance(instance.Id);
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
      .inputJson(resolvePayload(stepExec.Input__c))
      .previousStepOutput(resolvePayload(prevOutput))
      .stepStateJson(resolvePayload(stepExec.Output__c))
      .workflowInputJson(resolvePayload(instance.Input__c))
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
      String resolvedCaptures = resolvePayload(stepExec.Captured_Values__c);
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
      persistStepBreadcrumbs(crashOutcome);
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
        cancelTimeoutJob(instance.Id, compensationStepLogName);
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
    if (
      !(Test.isRunningTest() &&
      injectedFaults != null &&
      !injectedFaults.isEmpty())
    ) {
      return null;
    }
    Workflow_Instance__c instance = run.instance;
    String compensationStepLogName = run.compensationStepLogName;
    Id rootId = getRootInstanceId(instance.Id);
    String compKey =
      (rootId != null ? String.valueOf(rootId) : '') +
      ':' +
      compensationStepLogName.toLowerCase();
    if (injectedFaults.containsKey(compKey)) {
      return checkAndInjectFault(
        instance.Id,
        compensationStepLogName,
        compensatableStepInstance
      );
    }
    return checkAndInjectFault(
      instance.Id,
      run.activeStepName,
      compensatableStepInstance
    );
  }

  private static void handleCompensationStepResult(StepOutcomeContext outcome) {
    persistStepBreadcrumbs(outcome);
    Workflow_Instance__c instance = loadFreshCompensationInstance(
      outcome.instance
    );
    persistCompensationProgressAndCaptures(outcome, instance);

    StepResult.ActionType action = outcome.result.action;
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
    if (context != null && context.isProgressReported()) {
      String progJson = context.getProgressJson();
      instance.Progress__c = savePayloadIfNeeded(
        instance.Id,
        progJson,
        'Progress_' +
        (stepExec != null && String.isNotBlank(stepExec.Step_Name__c)
          ? stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
          : 'Default')
      );
    }

    // Persist capture-once values produced during this compensation execution.
    if (context.hasNewCaptures()) {
      String capturedJson = context.getCapturedValuesJson();
      stepExec.Captured_Values__c = savePayloadIfNeeded(
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
    notifyParentCompletion(instance);
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
    stepExec.Output__c = savePayloadIfNeeded(
      instance.Id,
      result.outputJson,
      'Output_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    saveStepExec(stepExec);

    // A compensating step that read signals durably completed; consume them on
    // the same contract as a forward step so a later compensation attempt or
    // step does not re-observe them. Compensation runs serially (LIFO) and
    // does not claim, so it consumes still-Received rows plus same-name cleanup.
    markSignalsConsumed(instance.Id, context, false);

    // Effectively-once outbound emit from compensation (issue #64): a
    // CompensatableStep.compensate() that calls ctx.emit() or the
    // complete(..., events) overload publishes here, coupled to the durable
    // Compensated transition — the same commit-coupling as the forward path,
    // so the public emit API does not silently drop events in rollback flows.
    publishOutboundEvents(result, context);

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
      notifyParentCompletion(instance);
    } else {
      scheduleTimeoutJobForInstance(instance.Id);
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
    stepExec.Output__c = savePayloadIfNeeded(
      instance.Id,
      result.stepStateJson,
      'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    saveStepExec(stepExec);

    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    scheduleTimeoutJobForInstance(instance.Id);
    enqueueOrchestrator(instance.Id, null);
  }

  private static void handleCompensationSuspend(
    StepOutcomeContext outcome,
    Workflow_Instance__c instance
  ) {
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepResult result = outcome.result;
    // Note: timed-wait timeout is not supported in compensation steps and is not armed here.
    stepExec.Status__c = 'Pending';
    stepExec.Output__c = String.isNotBlank(result.stepStateJson)
      ? savePayloadIfNeeded(
          instance.Id,
          result.stepStateJson,
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
    stepExec.Output__c = savePayloadIfNeeded(
      instance.Id,
      result.stepStateJson,
      'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );
    saveStepExec(stepExec);
    instance.Status__c = 'Suspended';
    if (result.sleepDurationSeconds != null) {
      instance.Sleep_Until__c = DateTime.now()
        .addSeconds(result.sleepDurationSeconds);
      instance.Async_Job_Id__c = scheduleSleepResume(
        instance.Id,
        stepExec.Step_Name__c,
        result.sleepDurationSeconds
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
      'approvalKey' => result.approvalKey,
      'approvalRole' => result.approvalRole
    };
    stepExec.Output__c = savePayloadIfNeeded(
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
    RetryPolicy policy = sanitizePolicy(result.retryPolicy);

    Map<String, Object> captures = new Map<String, Object>();
    if (String.isNotBlank(stepExec.Captured_Values__c)) {
      String resolvedCaptures = resolvePayload(stepExec.Captured_Values__c);
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
    stepExec.Captured_Values__c = savePayloadIfNeeded(
      instance.Id,
      JSON.serialize(captures),
      'Captures_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
    );

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
      stepExec.Status__c = 'Retrying';
      stepExec.Output__c = null;
      saveStepExec(stepExec);

      Double backoff = Math.pow(
        (Double) policy.backoffCoefficient,
        (Double) (stepExec.Retry_Count__c - 1)
      );
      Integer delay = (Integer) (policy.initialIntervalSeconds * backoff);
      delay = Math.min(delay, 86400);
      instance.Status__c = 'Suspended';
      instance.Sleep_Until__c = DateTime.now().addSeconds(delay);
      instance.Async_Job_Id__c = scheduleRetry(
        instance.Id,
        stepExec.Step_Name__c,
        delay
      );
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);
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
    stepExec.Error_Details__c = (result.failureDataJson != null)
      ? result.failureReason + '\nfailureData: ' + result.failureDataJson
      : result.failureReason;
    saveStepExec(stepExec);

    failCompensationRecoverable(
      instance,
      'Rollback incomplete: compensation step ' +
        stepExec.Step_Name__c +
        ' failed: ' +
        result.failureReason
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
      (result != null ? result.action : null);
    saveStepExec(stepExec);

    // Remaining stack is intact; leave the saga recoverable rather than abandoning it.
    failCompensationRecoverable(
      instance,
      'Rollback incomplete: compensation step ' +
        stepExec.Step_Name__c +
        ' failed: Unsupported action.'
    );
  }

  private static void preCreateFirstCompensationStep(
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
   * The per-instance plan for pre-creating first compensation steps: the valid
   * instances (those with a parseable, non-empty compensation stack) and, per
   * instance id, the top-of-stack active step name and its derived compensation
   * step log name.
   */
  private class CompStepPlan {
    Set<Id> instanceIds = new Set<Id>();
    List<Workflow_Instance__c> validInstances = new List<Workflow_Instance__c>();
    Map<Id, String> activeStepNames = new Map<Id, String>();
    Map<Id, String> compStepNames = new Map<Id, String>();
  }

  /**
   * Builds the compensation-step plan from the candidate instances, skipping any
   * with a blank, unparseable, or empty compensation stack. For each valid
   * instance it records the top-of-stack active step and its '_Compensate' log
   * name.
   * @param instances the candidate instances entering compensation
   * @return the per-instance compensation-step plan
   */
  private static CompStepPlan planCompensationSteps(
    List<Workflow_Instance__c> instances
  ) {
    CompStepPlan plan = new CompStepPlan();
    for (Workflow_Instance__c instance : instances) {
      if (String.isBlank(instance.Compensation_Stack__c)) {
        continue;
      }
      List<String> stack;
      try {
        stack = (List<String>) JSON.deserialize(
          instance.Compensation_Stack__c,
          List<String>.class
        );
      } catch (Exception ex) {
        continue;
      }
      if (stack == null || stack.isEmpty()) {
        continue;
      }
      String activeStepName = stack[stack.size() - 1];
      String compensationStepLogName = activeStepName + '_Compensate';

      plan.instanceIds.add(instance.Id);
      plan.validInstances.add(instance);
      plan.activeStepNames.put(instance.Id, activeStepName);
      plan.compStepNames.put(instance.Id, compensationStepLogName);
    }
    return plan;
  }

  /**
   * Queries existing compensation step executions for the instances in bulk and
   * returns their '{instanceId}:{stepName}' keys, used to avoid creating
   * duplicate compensation steps.
   * @param instanceIds the instances whose existing compensation steps are read
   * @return the set of existing '{instanceId}:{stepName}' keys
   */
  private static Set<String> queryExistingCompKeys(Set<Id> instanceIds) {
    // Bind the LIKE pattern so the escaped underscore ('\_', matching a literal
    // '_') lives in an Apex string literal rather than inline SOQL.
    String compensateSuffixPattern = '%\\_Compensate';
    List<Workflow_Step_Execution__c> existingCompSteps = [
      SELECT Workflow_Instance__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instanceIds
        AND Step_Name__c LIKE :compensateSuffixPattern
      WITH SYSTEM_MODE
    ];
    Set<String> existingKeys = new Set<String>();
    for (Workflow_Step_Execution__c step : existingCompSteps) {
      existingKeys.add(step.Workflow_Instance__c + ':' + step.Step_Name__c);
    }
    return existingKeys;
  }

  /**
   * Queries the step executions for the instances in bulk and maps the latest
   * (newest-first) execution per '{instanceId}:{stepName}' key, used to carry
   * the original step's Input/Output onto its compensation step.
   * @param instanceIds the instances whose step executions are read
   * @return the latest execution per '{instanceId}:{stepName}' key
   */
  private static Map<String, Workflow_Step_Execution__c> buildLatestOrigExecs(
    Set<Id> instanceIds
  ) {
    List<Workflow_Step_Execution__c> originalExecs = [
      SELECT Workflow_Instance__c, Step_Name__c, Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :instanceIds
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    Map<String, Workflow_Step_Execution__c> latestOrigExecs = new Map<String, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c exec : originalExecs) {
      String key = exec.Workflow_Instance__c + ':' + exec.Step_Name__c;
      if (!latestOrigExecs.containsKey(key)) {
        latestOrigExecs.put(key, exec);
      }
    }
    return latestOrigExecs;
  }

  /**
   * Builds the Pending compensation step executions to insert, skipping any that
   * already exist, and carrying the original step's Input/Output where available.
   * @param plan the per-instance compensation-step plan
   * @param existingKeys the '{instanceId}:{stepName}' keys already present
   * @param latestOrigExecs the latest original execution per step key
   * @return the compensation step executions to insert
   */
  private static List<Workflow_Step_Execution__c> buildCompStepsToInsert(
    CompStepPlan plan,
    Set<String> existingKeys,
    Map<String, Workflow_Step_Execution__c> latestOrigExecs
  ) {
    List<Workflow_Step_Execution__c> stepsToInsert = new List<Workflow_Step_Execution__c>();
    for (Workflow_Instance__c instance : plan.validInstances) {
      String compName = plan.compStepNames.get(instance.Id);
      String key = instance.Id + ':' + compName;
      if (existingKeys.contains(key)) {
        continue;
      }

      String activeName = plan.activeStepNames.get(instance.Id);
      String origKey = instance.Id + ':' + activeName;
      Workflow_Step_Execution__c origExec = latestOrigExecs.get(origKey);

      Workflow_Step_Execution__c compStepExec = new Workflow_Step_Execution__c();
      compStepExec.Workflow_Instance__c = instance.Id;
      compStepExec.Step_Name__c = compName;
      compStepExec.Status__c = 'Pending';
      compStepExec.Input__c = (origExec != null) ? origExec.Input__c : null;
      compStepExec.Output__c = (origExec != null) ? origExec.Output__c : null;
      compStepExec.Retry_Count__c = 0;
      stepsToInsert.add(compStepExec);
    }
    return stepsToInsert;
  }

  private static void preCreateFirstCompensationSteps(
    List<Workflow_Instance__c> instances
  ) {
    if (instances == null || instances.isEmpty()) {
      return;
    }

    CompStepPlan plan = planCompensationSteps(instances);
    if (plan.instanceIds.isEmpty()) {
      return;
    }

    // Query existing compensation steps in bulk to avoid duplicates.
    Set<String> existingKeys = queryExistingCompKeys(plan.instanceIds);

    // Query original executions to map Input/Output in bulk.
    Map<String, Workflow_Step_Execution__c> latestOrigExecs = buildLatestOrigExecs(
      plan.instanceIds
    );

    List<Workflow_Step_Execution__c> stepsToInsert = buildCompStepsToInsert(
      plan,
      existingKeys,
      latestOrigExecs
    );

    if (!stepsToInsert.isEmpty()) {
      Database.insert(stepsToInsert, true, AccessLevel.SYSTEM_MODE);
    }
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
    scheduleTimeoutJobForInstance(compensatingInstanceId);
    if (!Test.isRunningTest()) {
      enqueueOrchestrator(compensatingInstanceId, null);
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
   * Cancels a workflow instance, aborts scheduled jobs, and optionally runs saga compensations.
   * @param instanceId Id of the target instance to cancel (with its active descendants)
   * @param runCompensations true to roll back completed steps via saga compensation
   */
  private static void cancelInstance(Id instanceId, Boolean runCompensations) {
    // Cancel the target instance and its entire active descendant tree. Descendants are
    // gathered iteratively (one set-based query per tree level) rather than via recursive
    // cancel() calls, so deep/wide trees cannot blow the SOQL or stack-depth governor
    // limits through uncontrolled recursion. Parent-before-child ordering is preserved.
    //
    // Note: each node still costs a handful of SOQL/DML in cancelSingleInstance(); a tree
    // with thousands of nodes would need async chunking. That is intentionally out of
    // scope here — the goal is to remove the recursion-driven multiplication.
    // The traversal always yields the target first, so it is cancelled with the original
    // not-found semantics (throwIfMissing = true); descendants are best-effort.
    //
    // Lifecycle events are collected and published in a single bulk batch AFTER every
    // node is cancelled, so the best-effort publish never spends a DML statement that a
    // later child cancellation still needs.
    List<Workflow_Instance__c> terminallyCancelled = new List<Workflow_Instance__c>();
    for (Id targetId : collectInstanceAndActiveDescendants(instanceId)) {
      Workflow_Instance__c cancelled = cancelSingleInstance(
        targetId,
        runCompensations,
        targetId == instanceId
      );
      if (cancelled != null) {
        terminallyCancelled.add(cancelled);
      }
    }
    notifyParentCompletion(terminallyCancelled);
    WorkflowLifecyclePublisher.publish(terminallyCancelled);
  }

  /**
   * Breadth-first collection of an instance plus all of its active descendants using one
   * set-based query per tree level. Returns IDs in parent-before-child order. A `seen`
   * guard makes the traversal safe against accidental parent-reference cycles.
   * @param rootId Id of the instance at the root of the traversal
   * @return the root plus all active descendant Ids in parent-before-child order
   */
  private static List<Id> collectInstanceAndActiveDescendants(Id rootId) {
    List<Id> ordered = new List<Id>{ rootId };
    Set<Id> seen = new Set<Id>{ rootId };
    List<Id> frontier = new List<Id>{ rootId };
    while (!frontier.isEmpty()) {
      List<Workflow_Instance__c> children = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE
          Parent_Instance__c IN :frontier
          AND Status__c IN (
            'Pending',
            'Running',
            'Suspended',
            'Cancelling',
            'CompensationFailed',
            'Paused'
          )
        WITH SYSTEM_MODE
      ];
      List<Id> nextFrontier = new List<Id>();
      for (Workflow_Instance__c child : children) {
        if (!seen.contains(child.Id)) {
          seen.add(child.Id);
          ordered.add(child.Id);
          nextFrontier.add(child.Id);
        }
      }
      frontier = nextFrontier;
    }
    return ordered;
  }

  /**
   * Tests whether a status is terminal for the purposes of cancellation, i.e.
   * cancellation should be skipped because the instance is already finished.
   * @param status the instance status to test
   * @return true when the status is a terminal (non-cancellable) state
   */
  private static Boolean isTerminalForCancel(String status) {
    return status == 'Completed' ||
      status == 'Failed' ||
      status == 'Compensated' ||
      status == 'Cancelled' ||
      status == 'ContinuedAsNew';
  }

  /**
   * Enqueues the orchestrator for an instance, honoring the in-test queueable
   * disable flag so tests can drive the loop deterministically.
   * @param instanceId the instance to enqueue an orchestrator for
   */
  private static void enqueueOrchestratorTestAware(Id instanceId) {
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instanceId));
      }
    } else {
      enqueueOrchestrator(instanceId, null);
    }
  }

  /**
   * Locks (FOR UPDATE) the active step executions for the instance's current
   * step(s), supporting comma-separated parallel branch step names. Returns an
   * empty list when the instance has no current step.
   * @param instance the instance whose active steps are locked
   * @return the locked active step executions
   */
  private static List<Workflow_Step_Execution__c> lockActiveStepExecs(
    Workflow_Instance__c instance
  ) {
    List<Workflow_Step_Execution__c> stepExecs = new List<Workflow_Step_Execution__c>();
    if (String.isNotBlank(instance.Current_Step__c)) {
      List<String> activeStepNames = new List<String>();
      if (instance.Current_Step__c.contains(',')) {
        activeStepNames = instance.Current_Step__c.split(',');
      } else {
        activeStepNames.add(instance.Current_Step__c);
      }

      Id instanceId = instance.Id;
      stepExecs = [
        SELECT Id, Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c IN :activeStepNames
          AND Status__c IN ('Running', 'Pending', 'Retrying')
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
    }
    return stepExecs;
  }

  /**
   * Cancels an instance stalled in CompensationFailed. With compensations
   * requested and remaining rollback work, it resumes the rollback under the
   * cancel phase (returns null, non-terminal); otherwise it forces the instance
   * terminal Cancelled (returns the instance for bulk lifecycle publish).
   * @param instance the CompensationFailed instance being cancelled
   * @param runCompensations true to drain remaining compensations before cancelling
   * @return the instance when driven terminal, otherwise null
   */
  private static Workflow_Instance__c cancelCompensationFailed(
    Workflow_Instance__c instance,
    Boolean runCompensations
  ) {
    List<String> remaining = parseCompensationStack(instance);
    if (runCompensations && !remaining.isEmpty()) {
      instance.Status__c = 'Cancelling';
      instance.Error_Message__c = 'Cancelled by user. Compensating.';
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);

      // Append a fresh attempt for the stalled top-of-stack step (the prior Failed
      // attempt is preserved) so the existing compensation loop re-runs it.
      appendCompensationRetryStep(instance, remaining);
      scheduleTimeoutJobForInstance(instance.Id);
      enqueueOrchestratorTestAware(instance.Id);
      // Not terminal yet — the orchestrator emits the lifecycle event when the
      // compensation stack drains to Cancelled.
      return null;
    }
    instance.Status__c = 'Cancelled';
    instance.Error_Message__c = 'Cancelled by user.';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    // Terminal immediately — hand back to cancel() for bulk lifecycle publish.
    return instance;
  }

  /**
   * Determines whether a cancel should first drain a live compensation stack,
   * i.e. compensations were requested and the instance has a non-empty stack.
   * @param runCompensations true when the cancel requested saga compensation
   * @param instance the instance being cancelled
   * @return true when the cancel must run compensations before terminating
   */
  private static Boolean hasCancelCompensations(
    Boolean runCompensations,
    Workflow_Instance__c instance
  ) {
    if (!runCompensations || String.isBlank(instance.Compensation_Stack__c)) {
      return false;
    }
    return !parseCompensationStack(instance).isEmpty();
  }

  /**
   * Cancels a single workflow instance (no descendant traversal). When throwIfMissing is
   * true the original not-found exception is preserved for the top-level target.
   *
   * Returns the instance when this call drove it to a terminal Cancelled state (the
   * no-compensation path), otherwise null. The caller (cancel()) collects these and
   * publishes one bulk lifecycle batch AFTER the whole tree is cancelled, so a
   * per-node publish can never spend the DML budget that a later child cancellation
   * still needs. (The compensation path reaches Cancelled asynchronously and emits
   * its own event from the orchestrator.)
   * @param instanceId Id of the single instance to cancel
   * @param runCompensations true to roll back completed steps via saga compensation
   * @param throwIfMissing true to raise the not-found exception for the top-level target
   * @return the instance when this call drove it to terminal Cancelled, otherwise null
   */
  private static Workflow_Instance__c cancelSingleInstance(
    Id instanceId,
    Boolean runCompensations,
    Boolean throwIfMissing
  ) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Status__c,
        Current_Step__c,
        Compensation_Stack__c,
        Error_Message__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      if (throwIfMissing) {
        throw new WorkflowException(
          'Workflow instance not found: ' + instanceId
        );
      }
      return null;
    }

    Workflow_Instance__c instance = instances[0];
    if (isTerminalForCancel(instance.Status__c)) {
      return null; // Already in terminal state
    }
    // Note: CompensationFailed is intentionally NOT treated as terminal here — a stalled
    // rollback is resumable and still holds un-reversed side effects, so cancellation must
    // reach it (handled explicitly below) rather than skip it.

    // Lock active step executions FOR UPDATE second
    List<Workflow_Step_Execution__c> stepExecs = lockActiveStepExecs(instance);

    // Abort all scheduled jobs for this instance (sleeps, retries, timeouts)
    abortScheduledJobs(instanceId);

    // Disarm any armed timed-wait timeout so the watchdog cannot mis-route a
    // cancelled (or compensating) instance to a fallback step (issue #35). Every
    // cancel branch below commits `instance`, so set it once here.
    instance.Sleep_Until__c = null;

    // Update step executions to Cancelled
    for (Workflow_Step_Execution__c stepExec : stepExecs) {
      stepExec.Status__c = 'Cancelled';
    }
    if (!stepExecs.isEmpty()) {
      Database.update(stepExecs, true, AccessLevel.SYSTEM_MODE);
    }

    // A stalled rollback (CompensationFailed) being cancelled is handled per cancel mode:
    // with compensations requested, resume the remaining rollback under the cancel phase so
    // it drains to 'Cancelled' (every remaining side effect reversed); without, force it
    // terminal 'Cancelled', abandoning the un-run compensations but releasing its key.
    if (instance.Status__c == 'CompensationFailed') {
      return cancelCompensationFailed(instance, runCompensations);
    }

    if (hasCancelCompensations(runCompensations, instance)) {
      instance.Status__c = 'Cancelling';
      instance.Error_Message__c = 'Cancelled by user. Compensating.';
      preCreateFirstCompensationStep(instance);
      Database.update(instance, true, AccessLevel.SYSTEM_MODE);

      // Kick off rollback loop
      enqueueOrchestratorTestAware(instance.Id);
      // Not terminal yet (Cancelling); the orchestrator emits the lifecycle event
      // when the compensation stack drains to Cancelled.
      return null;
    }

    instance.Status__c = 'Cancelled';
    instance.Error_Message__c = 'Cancelled by user.';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    // Terminal: hand the instance back to cancel() for a single bulk publish after
    // the whole descendant tree is cancelled (preserves DML headroom mid-loop).
    // Active child workflows are handled by the caller (cancel()) via iterative
    // descendant traversal, so no recursive child cancellation happens here.
    return instance;
  }

  /**
   * Aborts all Scheduled Apex cron jobs associated with the workflow instance.
   * @param instanceId Id of the instance whose scheduled jobs are aborted
   */
  public static void abortScheduledJobs(Id instanceId) {
    abortScheduledJobs(new Set<Id>{ instanceId });
  }

  /**
   * @description Bulk-aborts the sleep, retry and timeout cron jobs scheduled for
   * the given instances, matching them by their name prefixes. Abort failures are
   * logged and skipped so one stuck job never blocks the rest.
   * @param instanceIds Ids of the instances whose scheduled jobs are aborted
   */
  public static void abortScheduledJobs(Set<Id> instanceIds) {
    if (instanceIds == null || instanceIds.isEmpty()) {
      return;
    }
    List<String> nameLikeFilters = new List<String>();
    for (Id instanceId : instanceIds) {
      nameLikeFilters.add('WorkflowSleep_' + instanceId + '_%');
      nameLikeFilters.add('WorkflowRetry_' + instanceId + '_%');
      nameLikeFilters.add('Timeout_' + instanceId + '_%');
    }
    List<CronTrigger> triggers = [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name LIKE :nameLikeFilters
      WITH SYSTEM_MODE
    ];
    for (CronTrigger triggerJob : triggers) {
      try {
        System.abortJob(triggerJob.Id);
      } catch (Exception ignored) {
        // Job may already have completed or been aborted; nothing further to do.
      }
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
   * @description Enqueues orchestrator RUN_STEP work for a batch of requests. In a
   * test context it enqueues Queueables directly (deduped per instance, honoring
   * the queueable governor); otherwise it publishes one Workflow_Event__e per
   * request so the platform event trigger drives the steps asynchronously.
   * @param requests the orchestrator requests to enqueue
   */
  /**
   * Under test, enqueues one orchestrator job per distinct instance directly
   * (best-effort, honoring the queueable limit) rather than via platform events.
   * @param requests the orchestrator requests to dispatch
   */
  private static void enqueueOrchestratorsInTest(
    List<OrchestratorRequest> requests
  ) {
    if (disableQueueableInTest) {
      return;
    }
    Set<Id> instanceIds = new Set<Id>();
    for (OrchestratorRequest req : requests) {
      instanceIds.add(req.instanceId);
    }
    for (Id instId : instanceIds) {
      tryEnqueueTestOrchestratorForInstance(instId);
    }
  }

  /**
   * @description Best-effort direct enqueue of a single-instance orchestrator
   * job for test paths that fan out one job per distinct instance. Honors the
   * per-transaction queueable limit and swallows enqueue failures so the
   * caller's loop continues; the watchdog re-drives any instance left
   * un-enqueued. Kept as a helper so the caller's per-instance
   * `System.enqueueJob` is not lexically inside the loop.
   * @param instId the workflow instance to enqueue
   */
  private static void tryEnqueueTestOrchestratorForInstance(Id instId) {
    try {
      if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
        System.enqueueJob(new WorkflowOrchestrator(instId));
      }
    } catch (Exception ignored) {
      // Best-effort enqueue; the watchdog re-drives any instance left un-enqueued.
    }
  }

  /**
   * Builds the RUN_STEP platform events for a batch of orchestrator requests.
   * @param requests the orchestrator requests
   * @return the events to publish
   */
  private static List<Workflow_Event__e> buildOrchestratorEvents(
    List<OrchestratorRequest> requests
  ) {
    List<Workflow_Event__e> events = new List<Workflow_Event__e>();
    for (OrchestratorRequest req : requests) {
      events.add(
        new Workflow_Event__e(
          Workflow_Instance_Id__c = req.instanceId,
          Event_Type__c = 'RUN_STEP',
          Payload__c = req.stepName
        )
      );
    }
    return events;
  }

  /**
   * @description Enqueues orchestrator work for a batch of requests, dispatching
   * directly under test and via RUN_STEP platform events otherwise.
   * @param requests the orchestrator requests to enqueue
   */
  public static void enqueueOrchestrators(List<OrchestratorRequest> requests) {
    WorkflowWatchdog.bootstrap();
    if (Test.isRunningTest()) {
      enqueueOrchestratorsInTest(requests);
      return;
    }
    List<Workflow_Event__e> events = buildOrchestratorEvents(requests);
    if (!events.isEmpty()) {
      List<Database.SaveResult> srs = EventBus.publish(events);
      throwOnPublishErrors(srs, 'Failed to publish orchestrator event: ');
    }
  }

  /**
   * @description Convenience overload that enqueues orchestrator work for a list
   * of instance Ids, driving each instance's current step (null step name).
   * @param instanceIds Ids of the instances to orchestrate
   */
  public static void enqueueOrchestrators(List<Id> instanceIds) {
    List<OrchestratorRequest> requests = new List<OrchestratorRequest>();
    for (Id instId : instanceIds) {
      requests.add(new OrchestratorRequest(instId, null));
    }
    enqueueOrchestrators(requests);
  }

  /**
   * @description Convenience overload that enqueues orchestrator work for a single
   * instance and step.
   * @param instanceId Id of the instance to orchestrate
   * @param stepName name of the step to run, or null for the current step
   */
  public static void enqueueOrchestrator(Id instanceId, String stepName) {
    enqueueOrchestrators(
      new List<OrchestratorRequest>{
        new OrchestratorRequest(instanceId, stepName)
      }
    );
  }

  private static void validateCorrelationKey(String correlationKey) {
    if (String.isBlank(correlationKey)) {
      throw new WorkflowException('Correlation key is required.');
    }
    if (correlationKey.length() > 200) {
      throw new WorkflowException(
        'Correlation key length cannot exceed 200 characters.'
      );
    }
  }

  // Returns the String value of a reserved $-key from a JSON-object string, or
  // null for blank input, non-object JSON, a missing key, and parse failures.
  private static String readJsonMapKey(String jsonText, String key) {
    if (String.isBlank(jsonText)) {
      return null;
    }
    try {
      Object parsed = JSON.deserializeUntyped(jsonText);
      if (!(parsed instanceof Map<String, Object>)) {
        return null;
      }
      Object value = ((Map<String, Object>) parsed).get(key);
      if (value == null) {
        return null;
      }
      String strValue = String.valueOf(value);
      return String.isBlank(strValue) ? null : strValue;
    } catch (Exception e) {
      return null;
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

  // Extracts the $timeoutStep value from a step exec's Output__c if it is a
  // timed-wait state envelope (issue #35). Returns null for plain SLEEP state,
  // author-supplied JSON, null/blank, and any parse failure.
  private static String extractTimedWaitTarget(
    Workflow_Step_Execution__c stepExec
  ) {
    if (stepExec == null || String.isBlank(stepExec.Output__c)) {
      return null;
    }
    // Cheap gate: the timed-wait marker is always inline (the {"$timeoutStep":..}
    // envelope is tiny and never offloaded), so the raw field already contains
    // the key without needing resolvePayload. This avoids a ContentVersion SOQL
    // per plain-sleeper instance inside the watchdog resume loop.
    if (!stepExec.Output__c.contains('$timeoutStep')) {
      return null;
    }
    return readJsonMapKey(resolvePayload(stepExec.Output__c), '$timeoutStep');
  }

  /**
   * @description Resolves a possibly-offloaded payload string: when the value is a
   * `{"$attachmentId":...}` marker it fetches and returns the linked
   * ContentVersion body, otherwise the value is returned unchanged. Falls back to
   * the raw value if the offloaded document cannot be read.
   * @param textValue the raw (possibly marker) payload string
   * @return the resolved payload text, or the original value when not offloaded
   */
  public static String resolvePayload(String textValue) {
    if (
      String.isNotBlank(textValue) && textValue.startsWith('{"$attachmentId":')
    ) {
      try {
        Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(
          textValue
        );
        Id attachmentId = (Id) marker.get('$attachmentId');
        List<ContentVersion> cvs = [
          SELECT VersionData
          FROM ContentVersion
          WHERE ContentDocumentId = :attachmentId AND IsLatest = TRUE
          WITH SYSTEM_MODE
        ];
        if (!cvs.isEmpty()) {
          return cvs[0].VersionData.toString();
        }
      } catch (Exception ignored) {
        // Offload resolution is best-effort; fall back to the raw stored value.
      }
    }
    return textValue;
  }

  /**
   * Bulk variant of resolvePayload: resolves a list of payload strings, fetching
   * every offloaded ContentVersion in ONE query rather than one per row. A list
   * accessor (e.g. a parent reading a backlog of child-completion signals with
   * large offloaded outputs) would otherwise issue a ContentVersion query per
   * offloaded payload and hit the SOQL-query governor limit after ~100-200 rows,
   * defeating the accessor's design of loading thousands in one call. Inline
   * (non-marker) payloads and unresolved markers pass through unchanged, index
   * for index with the input.
   * @param rawValues the raw (possibly marker) payload strings to resolve
   * @return the resolved payloads, index-aligned with rawValues
   */
  public static List<String> resolvePayloads(List<String> rawValues) {
    Map<Integer, Id> markerDocByIndex = new Map<Integer, Id>();
    Set<Id> docIds = collectOffloadMarkers(rawValues, markerDocByIndex);
    Map<Id, String> resolvedByDoc = queryResolvedDocs(docIds);
    List<String> out = new List<String>();
    for (Integer i = 0; i < rawValues.size(); i++) {
      Id docId = markerDocByIndex.get(i);
      out.add(
        (docId != null && resolvedByDoc.containsKey(docId))
          ? resolvedByDoc.get(docId)
          : rawValues[i]
      );
    }
    return out;
  }

  /**
   * Scans raw values for `{"$attachmentId":...}` offload markers, recording each
   * marker's document id by index and collecting the distinct document ids.
   * @param rawValues the raw payload values (inline or offload markers)
   * @param markerDocByIndex out-param mapping each marker's index to its doc id
   * @return the distinct offloaded ContentDocument ids to resolve
   */
  private static Set<Id> collectOffloadMarkers(
    List<String> rawValues,
    Map<Integer, Id> markerDocByIndex
  ) {
    Set<Id> docIds = new Set<Id>();
    for (Integer i = 0; i < rawValues.size(); i++) {
      String v = rawValues[i];
      if (!(String.isNotBlank(v) && v.startsWith('{"$attachmentId":'))) {
        continue;
      }
      try {
        Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(
          v
        );
        Id docId = (Id) marker.get('$attachmentId');
        markerDocByIndex.put(i, docId);
        docIds.add(docId);
      } catch (Exception ignored) {
        // Not a valid offload marker; leave this entry to pass through as-is.
      }
    }
    return docIds;
  }

  /**
   * Bulk-resolves the latest ContentVersion text for the given document ids.
   * @param docIds the offloaded ContentDocument ids to resolve
   * @return a map of document id to its resolved payload text (empty when none)
   */
  private static Map<Id, String> queryResolvedDocs(Set<Id> docIds) {
    Map<Id, String> resolvedByDoc = new Map<Id, String>();
    if (docIds.isEmpty()) {
      return resolvedByDoc;
    }
    for (ContentVersion cv : [
      SELECT ContentDocumentId, VersionData
      FROM ContentVersion
      WHERE ContentDocumentId IN :docIds AND IsLatest = TRUE
      WITH SYSTEM_MODE
    ]) {
      resolvedByDoc.put(cv.ContentDocumentId, cv.VersionData.toString());
    }
    return resolvedByDoc;
  }

  /**
   * @description Offloads an oversized payload to a ContentVersion so it fits
   * within field limits: when the text exceeds the inline threshold it is stored
   * as a file and a `{"$attachmentId":...}` marker is returned; otherwise the
   * value is returned unchanged for inline storage.
   * @param instanceId Id of the owning instance (links the stored document)
   * @param textValue the payload text to store
   * @param title title/filename for the offloaded ContentVersion
   * @return an offload marker string when stored as a file, else the original text
   */
  public static String savePayloadIfNeeded(
    Id instanceId,
    String textValue,
    String title
  ) {
    if (String.isNotBlank(textValue) && textValue.length() > 100000) {
      ContentVersion cv = new ContentVersion();
      cv.Title = title;
      cv.PathOnClient = title + '.json';
      cv.VersionData = Blob.valueOf(textValue);
      Database.insert(cv, true, AccessLevel.SYSTEM_MODE);

      Id docId = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv.Id
        WITH SYSTEM_MODE
      ]
      .ContentDocumentId;

      ContentDocumentLink cdl = new ContentDocumentLink();
      cdl.ContentDocumentId = docId;
      cdl.LinkedEntityId = instanceId;
      cdl.ShareType = 'V';
      cdl.Visibility = 'InternalUsers';
      try {
        Database.insert(cdl, true, AccessLevel.SYSTEM_MODE);
      } catch (DmlException ignored) {
        // Default visibility rejected; retry the link with AllUsers visibility.
        cdl.Visibility = 'AllUsers';
        Database.insert(cdl, true, AccessLevel.SYSTEM_MODE);
      }

      return JSON.serialize(
        new Map<String, String>{ '$attachmentId' => docId }
      );
    }
    return textValue;
  }

  // Mutable accumulator for the timed-out-steps section (§1). Bundled so the
  // per-step helpers stay under the parameter-count limit while still sharing
  // the collections the section finalizes and flushes.
  private class TimedOutStepContext {
    Map<Id, Workflow_Instance__c> parents;
    Map<Id, Workflow_Step_Execution__c> lockedSteps;
    Map<String, Boolean> isRoutingWflow;
    Map<String, Integer> latestRetryCounts;
    List<Workflow_Step_Execution__c> stepsToUpdate = new List<Workflow_Step_Execution__c>();
    Map<Id, Workflow_Instance__c> instancesToUpdate = new Map<Id, Workflow_Instance__c>();
    List<Workflow_Step_Execution__c> compensationStepsToInsert = new List<Workflow_Step_Execution__c>();
    List<Id> orchestratorInstanceIds = new List<Id>();
    Set<Id> instancesNeedingCompensationInfo = new Set<Id>();
    Set<String> activeStepNamesForComp = new Set<String>();
  }

  // Mutable accumulator for the exceeded-deadline section (§1b).
  private class DeadlineBatch {
    List<Workflow_Step_Execution__c> deadlineStepsToInsert = new List<Workflow_Step_Execution__c>();
    List<Workflow_Instance__c> instancesToFail = new List<Workflow_Instance__c>();
    List<Id> deadlineOrchestratorIds = new List<Id>();
  }

  // Mutable accumulator for the sleep-resumption section (§2).
  private class SleepResumeBatch {
    Map<Id, Workflow_Step_Execution__c> latestStepByInstId = new Map<Id, Workflow_Step_Execution__c>();
    List<Id> instanceIds = new List<Id>();
    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    List<Id> parallelResumeIds = new List<Id>();
    List<Workflow_Step_Execution__c> timedWaitFallbackExecs = new List<Workflow_Step_Execution__c>();
  }

  /**
   * Evaluates and resumes suspended workflows that have exceeded their sleep time,
   * and terminates active steps that have exceeded their timeout limits.
   */
  public static void processWatchdogHeartbeat() {
    Datetime now = mockNow != null ? mockNow : System.now();

    // Terminal instances finalized by the timed-out-steps / deadline sections
    // below. Their lifecycle events are published once at the very END of the
    // heartbeat, after ALL required work (including the sleep-resume section) is
    // done, so the best-effort publish can never spend a DML statement the
    // resume section needs.
    List<Workflow_Instance__c> watchdogTerminalInstances = new List<Workflow_Instance__c>();

    // 1. Process timed-out steps.
    processTimedOutSteps(now, watchdogTerminalInstances);

    // 1b. Process exceeded execution deadlines (bounded per heartbeat).
    processExceededDeadlines(now, watchdogTerminalInstances);

    // 2. Process sleep resumptions (bounded per heartbeat).
    processSleepResumptions(now);

    // 2b. Sweep Suspended instances for matching Unrouted signals (safety net).
    sweepUnroutedSuspendedSignals();

    // 3. Process due recurring schedules (0-slot: runs inside the watchdog
    // heartbeat, so enabling N Workflow_Schedule__c records adds 0 scheduled-job
    // slots).
    try {
      WorkflowScheduleSweeper.sweep();
    } catch (Exception ignored) {
      // Best-effort sweep; a failure here must not abort the watchdog heartbeat.
    }

    // 3b. Process due debounced starts (0-slot: runs inside the watchdog heartbeat).
    try {
      WorkflowDebouncer.sweep();
    } catch (Exception ignored) {
      // Best-effort sweep; a failure here must not abort the watchdog heartbeat.
    }

    // 4. Reconcile concurrency slot counters. Recomputes each configured
    // workflow's in-flight count from the true number of non-terminal
    // slot-holding instances, reclaiming any slot leaked by an instance that
    // died without releasing (crash, killed transaction) so a parked instance is
    // never starved indefinitely.
    try {
      ConcurrencyGate.reconcileAll();
    } catch (Exception ignored) {
      // Best-effort reconcile; a failure here must not abort the watchdog heartbeat.
    }

    // 5. Rescue transient-lock retry branches orphaned when a parallel sibling
    // that completed during the backoff flipped the parent out of Suspended.
    rescueOrphanedTransientRetryBranches(now);

    // 6. Auto-reclaim orphaned instances.
    autoReclaimOrphanedInstances(now);

    // Run proactive stall detection and alerting hook
    try {
      WorkflowAlertManager.detectAndAlertStalls();
    } catch (Exception ignored) {
      // Best-effort stall detection; a failure here must not abort the watchdog heartbeat.
    }

    // All required heartbeat work (timed-out-step failures, sleep resumptions,
    // and schedule sweeps) is now done, so the best-effort lifecycle publish
    // runs last with no risk of starving a required update/enqueue of its DML budget.
    WorkflowLifecyclePublisher.publish(watchdogTerminalInstances);
  }

  // §1. Process Timed-out Steps. Exclude steps whose parent is Paused: a parked
  // parent is not runnable, so its step rows (e.g. parallel branch rows the SPLIT
  // path stamped with Timeout_At__c before their RUN_STEP reached the gate, or a
  // parked initial step) would otherwise be selected and skipped, wasting the
  // bounded batch and delaying real timeouts in other workflows. Resume re-arms
  // these deadlines (see reArmTimeoutsForResume).
  private static void processTimedOutSteps(
    Datetime now,
    List<Workflow_Instance__c> watchdogTerminalInstances
  ) {
    List<Workflow_Step_Execution__c> timedOutSteps = [
      SELECT Id, Workflow_Instance__c, Step_Name__c, Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE
        Status__c IN ('Running', 'Pending')
        AND Timeout_At__c <= :now
        AND Workflow_Instance__r.Status__c != 'Paused'
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT :watchdogTimeoutBatchSize
    ];

    if (timedOutSteps.isEmpty()) {
      return;
    }

    Set<Id> stepIds = new Set<Id>();
    Set<Id> instanceIds = new Set<Id>();
    for (Workflow_Step_Execution__c step : timedOutSteps) {
      stepIds.add(step.Id);
      instanceIds.add(step.Workflow_Instance__c);
    }

    // Lock parent instances
    Map<Id, Workflow_Instance__c> parents = new Map<Id, Workflow_Instance__c>(
      [
        SELECT
          Id,
          Name,
          Status__c,
          Current_Step__c,
          Compensation_Stack__c,
          Error_Message__c,
          Workflow_Name__c,
          Correlation_Key__c,
          Root_Correlation_Key__c,
          Failure_Category__c,
          Concurrency_Parked__c,
          Concurrency_Slot_Held__c
        FROM Workflow_Instance__c
        WHERE Id IN :instanceIds
        WITH SYSTEM_MODE
        FOR UPDATE
      ]
    );

    // Lock step executions
    Map<Id, Workflow_Step_Execution__c> lockedSteps = new Map<Id, Workflow_Step_Execution__c>(
      [
        SELECT
          Id,
          Status__c,
          Error_Details__c,
          Timeout_At__c,
          Step_Name__c,
          Workflow_Instance__c
        FROM Workflow_Step_Execution__c
        WHERE Id IN :stepIds
        WITH SYSTEM_MODE
        FOR UPDATE
      ]
    );

    TimedOutStepContext ctx = new TimedOutStepContext();
    ctx.parents = parents;
    ctx.lockedSteps = lockedSteps;
    ctx.isRoutingWflow = classifyRoutingWorkflows(parents);
    ctx.latestRetryCounts = loadLatestRetryCounts(parents, ctx.isRoutingWflow);

    for (Workflow_Step_Execution__c step : timedOutSteps) {
      finalizeTimedOutStep(step, ctx);
    }

    createCompensationStepsForTimedOut(ctx);
    flushTimedOutStepResults(ctx, watchdogTerminalInstances);
  }

  // Determine, per distinct workflow name, whether it is an ErrorRoutingWorkflow.
  private static Map<String, Boolean> classifyRoutingWorkflows(
    Map<Id, Workflow_Instance__c> parents
  ) {
    Map<String, Boolean> isRoutingWflow = new Map<String, Boolean>();
    for (Workflow_Instance__c parent : parents.values()) {
      if (String.isBlank(parent.Workflow_Name__c)) {
        continue;
      }
      String wfName = parent.Workflow_Name__c;
      if (isRoutingWflow.containsKey(wfName)) {
        continue;
      }
      Type wflowType = WorkflowTypeResolver.resolve(
        wfName,
        WorkflowTypeResolver.extractNamespace(wfName)
      );
      if (wflowType != null) {
        Object instObj = wflowType.newInstance();
        isRoutingWflow.put(wfName, instObj instanceof ErrorRoutingWorkflow);
      } else {
        isRoutingWflow.put(wfName, false);
      }
    }
    return isRoutingWflow;
  }

  // Fetch the latest retry count per (instance, step) for routing instances only.
  private static Map<String, Integer> loadLatestRetryCounts(
    Map<Id, Workflow_Instance__c> parents,
    Map<String, Boolean> isRoutingWflow
  ) {
    Set<Id> routingInstanceIds = new Set<Id>();
    for (Workflow_Instance__c parent : parents.values()) {
      if (
        String.isNotBlank(parent.Workflow_Name__c) &&
        isRoutingWflow.get(parent.Workflow_Name__c) == true
      ) {
        routingInstanceIds.add(parent.Id);
      }
    }

    Map<String, Integer> latestRetryCounts = new Map<String, Integer>();
    if (routingInstanceIds.isEmpty()) {
      return latestRetryCounts;
    }
    for (Workflow_Step_Execution__c exec : [
      SELECT Workflow_Instance__c, Step_Name__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :routingInstanceIds
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      String key = exec.Workflow_Instance__c + ':' + exec.Step_Name__c;
      if (!latestRetryCounts.containsKey(key)) {
        latestRetryCounts.put(
          key,
          exec.Retry_Count__c != null ? (Integer) exec.Retry_Count__c : 0
        );
      }
    }
    return latestRetryCounts;
  }

  // Process a single timed-out step: enforce the pause gate, route to an error
  // step if configured, otherwise mark the step Failed and transition the parent.
  // A parent is actionable for a timed-out step only in a self-driving status.
  private static Boolean isTimedOutParentActionable(
    Workflow_Instance__c parent
  ) {
    return parent.Status__c == 'Pending' ||
      parent.Status__c == 'Running' ||
      parent.Status__c == 'Compensating' ||
      parent.Status__c == 'Cancelling';
  }

  // A step is still enforceable while Running or Pending.
  private static Boolean isRunnableStepStatus(Workflow_Step_Execution__c s) {
    return s.Status__c == 'Running' || s.Status__c == 'Pending';
  }

  // Notify parent-completion for exactly the instances that reached a terminal
  // Failed state (shared by the timed-out-step and deadline flush paths).
  private static void notifyTerminalFailures(
    List<Workflow_Instance__c> updated
  ) {
    List<Workflow_Instance__c> terminalUpdated = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c inst : updated) {
      if (inst.Status__c == 'Failed') {
        terminalUpdated.add(inst);
      }
    }
    notifyParentCompletion(terminalUpdated);
  }

  // Enqueue orchestrators for the given instances unless nothing is pending or
  // the test opt-out is active.
  private static void enqueueOrchestratorsBounded(List<Id> ids) {
    if (ids.isEmpty()) {
      return;
    }
    if (Test.isRunningTest() && disableQueueableInTest) {
      return;
    }
    enqueueOrchestrators(ids);
  }

  private static void finalizeTimedOutStep(
    Workflow_Step_Execution__c step,
    TimedOutStepContext ctx
  ) {
    Workflow_Instance__c parent = ctx.parents.get(step.Workflow_Instance__c);
    if (parent == null) {
      return;
    }
    if (!isTimedOutParentActionable(parent)) {
      return;
    }

    Workflow_Step_Execution__c lockedStep = ctx.lockedSteps.get(step.Id);
    if (lockedStep == null) {
      return;
    }
    if (!isRunnableStepStatus(lockedStep)) {
      return;
    }

    if (holdPausedPendingStep(parent, lockedStep, ctx)) {
      return;
    }

    String errorMsg = (lockedStep.Status__c == 'Running')
      ? 'Step execution timed out.'
      : 'Step execution timed out before starting.';

    String errorStepName = resolveTimeoutErrorRouting(step, errorMsg, ctx);

    if (String.isNotBlank(errorStepName)) {
      routeTimedOutStepFailure(step, errorMsg, ctx);
      return;
    }

    lockedStep.Status__c = 'Failed';
    lockedStep.Error_Details__c = errorMsg;
    lockedStep.Timeout_At__c = null;
    ctx.stepsToUpdate.add(lockedStep);

    if (!ctx.instancesToUpdate.containsKey(parent.Id)) {
      applyTimedOutInstanceTransition(step, errorMsg, ctx);
    }
  }

  // Operator pause gate (mirrors WorkflowTimeoutJob): if the definition is
  // paused while the parent is still Pending/Running (handoff armed the deadline
  // before the delayed RUN_STEP reached the gate), only hold pre-start Pending
  // steps — clear their deadline so a post-resume heartbeat cannot fire
  // instantly; re-armed on park/re-run. Running (stuck) steps are NOT held: the
  // instance stays Running so reArmTimeoutsForResume will not re-arm them on
  // resume; clearing their deadline here would leave them permanently
  // unenforceable. Compensating/Cancelling bypass the pause gate normally.
  // Returns true when the step was held (and the caller must skip it).
  private static Boolean holdPausedPendingStep(
    Workflow_Instance__c parent,
    Workflow_Step_Execution__c lockedStep,
    TimedOutStepContext ctx
  ) {
    if (
      (parent.Status__c == 'Pending' ||
      parent.Status__c == 'Running') &&
      WorkflowPauseGate.anyPaused() &&
      WorkflowPauseGate.isDefinitionPaused(parent.Workflow_Name__c)
    ) {
      if (lockedStep.Status__c == 'Pending') {
        lockedStep.Timeout_At__c = null;
        ctx.stepsToUpdate.add(lockedStep);
        return true;
      }
      // Running step — fall through to enforce the timeout normally
    }
    return false;
  }

  // Check if error routing is defined for this timed-out step; returns the error
  // step name to route to, or null/blank when no routing applies.
  private static String resolveTimeoutErrorRouting(
    Workflow_Step_Execution__c step,
    String errorMsg,
    TimedOutStepContext ctx
  ) {
    Workflow_Instance__c parent = ctx.parents.get(step.Workflow_Instance__c);
    if (
      !(ctx.isRoutingWflow.containsKey(parent.Workflow_Name__c) &&
      ctx.isRoutingWflow.get(parent.Workflow_Name__c))
    ) {
      return null;
    }
    Type wflowType = WorkflowTypeResolver.resolve(
      parent.Workflow_Name__c,
      WorkflowTypeResolver.extractNamespace(parent.Workflow_Name__c)
    );
    if (wflowType == null) {
      return null;
    }
    WorkflowDefinition def = (WorkflowDefinition) wflowType.newInstance();
    String key = parent.Id + ':' + step.Step_Name__c;
    Integer attemptCount =
      (ctx.latestRetryCounts.containsKey(key)
        ? ctx.latestRetryCounts.get(key)
        : 0) + 1;
    StepError err = new StepError(step.Step_Name__c, errorMsg, attemptCount);
    return ((ErrorRoutingWorkflow) def).getErrorStep(step.Step_Name__c, err);
  }

  // A routed timed-out step: mark it Failed immediately and fail the instance
  // through the resolved-error path.
  private static void routeTimedOutStepFailure(
    Workflow_Step_Execution__c step,
    String errorMsg,
    TimedOutStepContext ctx
  ) {
    Workflow_Instance__c parent = ctx.parents.get(step.Workflow_Instance__c);
    Workflow_Step_Execution__c lockedStep = ctx.lockedSteps.get(step.Id);

    lockedStep.Status__c = 'Failed';
    lockedStep.Error_Details__c = errorMsg;
    lockedStep.Timeout_At__c = null;
    Database.update(lockedStep, true, AccessLevel.SYSTEM_MODE);

    String key = parent.Id + ':' + step.Step_Name__c;
    Integer attemptCount =
      (ctx.latestRetryCounts.containsKey(key)
        ? ctx.latestRetryCounts.get(key)
        : 0) + 1;

    FailInstanceRequest timeoutFailReq = new FailInstanceRequest();
    timeoutFailReq.instance = parent;
    timeoutFailReq.stepName = step.Step_Name__c;
    timeoutFailReq.errorMessage = errorMsg;
    timeoutFailReq.failureCategory = CAT_TIMEOUT;
    timeoutFailReq.attemptCount = attemptCount;
    failResolvedInstance(timeoutFailReq);
  }

  // Transition the (not-yet-transitioned) parent instance for a timed-out step:
  // recoverable rollback-incomplete, terminal Failed, or start compensation.
  private static void applyTimedOutInstanceTransition(
    Workflow_Step_Execution__c step,
    String errorMsg,
    TimedOutStepContext ctx
  ) {
    Workflow_Instance__c parent = ctx.parents.get(step.Workflow_Instance__c);

    // Check if there are compensations to run
    Boolean hasCompensations = false;
    List<String> stack = new List<String>();
    if (String.isNotBlank(parent.Compensation_Stack__c)) {
      stack = (List<String>) JSON.deserialize(
        parent.Compensation_Stack__c,
        List<String>.class
      );
      hasCompensations = !stack.isEmpty();
    }

    Boolean isCompensationFailure = (parent.Status__c == 'Compensating' ||
    parent.Status__c == 'Cancelling' ||
    (String.isNotBlank(step.Step_Name__c) &&
    step.Step_Name__c.endsWith('_Compensate')));

    if (isCompensationFailure && hasCompensations) {
      // A compensation step timed out mid-rollback. The remaining stack is
      // intact, so park the saga in the recoverable "rollback incomplete"
      // state rather than abandoning the deeper compensations.
      Boolean wasCancelling = (parent.Status__c == 'Cancelling');
      parent.Status__c = 'CompensationFailed';
      parent.Failure_Category__c = CAT_COMPENSATION_FAILED;
      parent.Error_Message__c = buildRollbackIncompleteMessage(
        wasCancelling,
        'Rollback incomplete at compensation step ' +
          step.Step_Name__c +
          ': ' +
          errorMsg
      );
      // Clear any stale sleep/retry deadline so a later resumed SUSPEND/approval
      // gate is not prematurely woken by the watchdog.
      parent.Sleep_Until__c = null;
      parent.Async_Job_Id__c = null;
      ctx.instancesToUpdate.put(parent.Id, parent);
    } else if (!hasCompensations) {
      parent.Status__c = 'Failed';
      parent.Failure_Category__c = CAT_TIMEOUT;
      parent.Error_Message__c =
        'Failed at step ' +
        step.Step_Name__c +
        ': ' +
        errorMsg;
      ctx.instancesToUpdate.put(parent.Id, parent);
    } else {
      parent.Status__c = 'Compensating';
      parent.Error_Message__c =
        'Failed at step ' +
        step.Step_Name__c +
        ': ' +
        errorMsg;
      ctx.instancesToUpdate.put(parent.Id, parent);

      ctx.instancesNeedingCompensationInfo.add(parent.Id);
      if (!stack.isEmpty()) {
        ctx.activeStepNamesForComp.add(stack[stack.size() - 1]);
      }
    }
  }

  // Map of "<instanceId>:<stepName>_Compensate" -> existing compensation step
  // for the instances entering compensation (avoids duplicating a comp step).
  private static Map<String, Workflow_Step_Execution__c> buildExistingCompSteps(
    Set<Id> instancesNeedingCompensationInfo
  ) {
    Map<String, Workflow_Step_Execution__c> existingCompSteps = new Map<String, Workflow_Step_Execution__c>();
    if (instancesNeedingCompensationInfo.isEmpty()) {
      return existingCompSteps;
    }
    // Bind the LIKE pattern so the escaped underscore ('\_', matching a
    // literal '_') lives in an Apex string literal rather than inline SOQL.
    String compensateSuffixPattern = '%\\_Compensate';
    for (Workflow_Step_Execution__c e : [
      SELECT Id, Workflow_Instance__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instancesNeedingCompensationInfo
        AND Step_Name__c LIKE :compensateSuffixPattern
      WITH SYSTEM_MODE
    ]) {
      existingCompSteps.put(e.Workflow_Instance__c + ':' + e.Step_Name__c, e);
    }
    return existingCompSteps;
  }

  // Map of "<instanceId>:<stepName>" -> most recent original step exec, used to
  // seed the compensation step's Input/Output.
  private static Map<String, Workflow_Step_Execution__c> buildOriginalStepExecs(
    Set<Id> instancesNeedingCompensationInfo,
    Set<String> activeStepNamesForComp
  ) {
    Map<String, Workflow_Step_Execution__c> originalStepsMap = new Map<String, Workflow_Step_Execution__c>();
    if (instancesNeedingCompensationInfo.isEmpty()) {
      return originalStepsMap;
    }
    for (Workflow_Step_Execution__c o : [
      SELECT Workflow_Instance__c, Step_Name__c, Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instancesNeedingCompensationInfo
        AND Step_Name__c IN :activeStepNamesForComp
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      String key = o.Workflow_Instance__c + ':' + o.Step_Name__c;
      if (!originalStepsMap.containsKey(key)) {
        originalStepsMap.put(key, o);
      }
    }
    return originalStepsMap;
  }

  // Pre-create the first compensation step-exec log for each instance entering
  // compensation from a timed-out step.
  private static void createCompensationStepsForTimedOut(
    TimedOutStepContext ctx
  ) {
    Map<String, Workflow_Step_Execution__c> existingCompSteps = buildExistingCompSteps(
      ctx.instancesNeedingCompensationInfo
    );
    Map<String, Workflow_Step_Execution__c> originalStepsMap = buildOriginalStepExecs(
      ctx.instancesNeedingCompensationInfo,
      ctx.activeStepNamesForComp
    );

    for (Id instId : ctx.instancesNeedingCompensationInfo) {
      Workflow_Instance__c parent = ctx.parents.get(instId);
      List<String> stack = (List<String>) JSON.deserialize(
        parent.Compensation_Stack__c,
        List<String>.class
      );
      String activeStepName = stack[stack.size() - 1];
      String compensationStepLogName = activeStepName + '_Compensate';

      if (
        existingCompSteps.containsKey(parent.Id + ':' + compensationStepLogName)
      ) {
        continue;
      }

      Workflow_Step_Execution__c orig = originalStepsMap.get(
        parent.Id + ':' + activeStepName
      );

      Workflow_Step_Execution__c compStepExec = new Workflow_Step_Execution__c();
      compStepExec.Workflow_Instance__c = parent.Id;
      compStepExec.Step_Name__c = compensationStepLogName;
      compStepExec.Status__c = 'Pending';
      compStepExec.Input__c = (orig != null) ? orig.Input__c : null;
      compStepExec.Output__c = (orig != null) ? orig.Output__c : null;
      compStepExec.Retry_Count__c = 0;
      ctx.compensationStepsToInsert.add(compStepExec);
      ctx.orchestratorInstanceIds.add(parent.Id);
    }
  }

  // Flush all accumulated DML for the timed-out-steps section, publish alerts,
  // enqueue orchestrators, and record terminal instances for the deferred
  // lifecycle publish.
  private static void flushTimedOutStepResults(
    TimedOutStepContext ctx,
    List<Workflow_Instance__c> watchdogTerminalInstances
  ) {
    if (!ctx.stepsToUpdate.isEmpty()) {
      Database.update(ctx.stepsToUpdate, true, AccessLevel.SYSTEM_MODE);
    }
    if (!ctx.compensationStepsToInsert.isEmpty()) {
      Database.insert(
        ctx.compensationStepsToInsert,
        true,
        AccessLevel.SYSTEM_MODE
      );
    }
    if (!ctx.instancesToUpdate.isEmpty()) {
      Database.update(
        ctx.instancesToUpdate.values(),
        true,
        AccessLevel.SYSTEM_MODE
      );
      notifyTerminalFailures(ctx.instancesToUpdate.values());
    }

    for (Workflow_Instance__c parent : ctx.instancesToUpdate.values()) {
      WorkflowAlertManager.sendAlert(parent, parent.Error_Message__c);
    }

    enqueueOrchestratorsBounded(ctx.orchestratorInstanceIds);

    // Defer lifecycle publishing to the end of the heartbeat. Only the parents
    // transitioned to a terminal state (Failed) emit — Compensating parents are
    // skipped by the publisher.
    watchdogTerminalInstances.addAll(ctx.instancesToUpdate.values());
  }

  // §1b. Process Exceeded Execution Deadlines (bounded per heartbeat).
  private static void processExceededDeadlines(
    Datetime now,
    List<Workflow_Instance__c> watchdogTerminalInstances
  ) {
    List<Workflow_Instance__c> expiredInstances = [
      SELECT
        Id,
        Name,
        Status__c,
        Deadline_At__c,
        Compensation_Stack__c,
        Error_Message__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Current_Step__c,
        Failure_Category__c
      FROM Workflow_Instance__c
      WHERE
        Status__c IN ('Pending', 'Running', 'Suspended')
        AND Deadline_At__c <= :now
      WITH SYSTEM_MODE
      LIMIT :watchdogDeadlineBatchSize
      FOR UPDATE
    ];

    if (expiredInstances.isEmpty()) {
      return;
    }

    DeadlineBatch batch = new DeadlineBatch();

    // Bulk abort all scheduled jobs for all expired instances
    Set<Id> expiredInstanceIds = new Set<Id>();
    for (Workflow_Instance__c inst : expiredInstances) {
      expiredInstanceIds.add(inst.Id);
    }
    abortScheduledJobs(expiredInstanceIds);

    for (Workflow_Instance__c inst : expiredInstances) {
      applyDeadlineExpiry(inst, batch, watchdogTerminalInstances);
    }

    if (!batch.deadlineStepsToInsert.isEmpty()) {
      Database.insert(
        batch.deadlineStepsToInsert,
        true,
        AccessLevel.SYSTEM_MODE
      );
    }

    preCreateFirstCompensationSteps(expiredInstances);

    if (!batch.instancesToFail.isEmpty()) {
      Database.update(batch.instancesToFail, true, AccessLevel.SYSTEM_MODE);
      notifyTerminalFailures(batch.instancesToFail);
    }

    alertDeadlineFailures(batch.instancesToFail);

    enqueueOrchestratorsBounded(batch.deadlineOrchestratorIds);
  }

  // Alert on exactly the deadline-expired instances that reached terminal Failed.
  private static void alertDeadlineFailures(
    List<Workflow_Instance__c> instancesToFail
  ) {
    for (Workflow_Instance__c inst : instancesToFail) {
      if (inst.Status__c == 'Failed') {
        WorkflowAlertManager.sendAlert(inst, inst.Error_Message__c);
      }
    }
  }

  // Apply the deadline-exceeded transition to a single instance: append the
  // audit step and route to compensation or terminal failure.
  private static void applyDeadlineExpiry(
    Workflow_Instance__c inst,
    DeadlineBatch batch,
    List<Workflow_Instance__c> watchdogTerminalInstances
  ) {
    inst.Sleep_Until__c = null;
    inst.Async_Job_Id__c = null;

    // Check if there are compensations to run
    Boolean hasCompensations = false;
    List<String> stack = new List<String>();
    if (String.isNotBlank(inst.Compensation_Stack__c)) {
      stack = (List<String>) JSON.deserialize(
        inst.Compensation_Stack__c,
        List<String>.class
      );
      hasCompensations = !stack.isEmpty();
    }

    // Append a new failed step execution record (audit trail)
    Workflow_Step_Execution__c deadlineStep = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'Workflow_Deadline',
      Status__c = 'Failed',
      Error_Details__c = 'Execution deadline exceeded',
      Retry_Count__c = 0
    );
    batch.deadlineStepsToInsert.add(deadlineStep);

    if (hasCompensations) {
      inst.Status__c = 'Compensating';
      inst.Error_Message__c = 'Execution deadline exceeded';
      batch.instancesToFail.add(inst);
      batch.deadlineOrchestratorIds.add(inst.Id);
    } else {
      inst.Status__c = 'Failed';
      inst.Failure_Category__c = CAT_TIMEOUT;
      inst.Error_Message__c = 'Execution deadline exceeded';
      batch.instancesToFail.add(inst);
      watchdogTerminalInstances.add(inst);
    }
  }

  // §2. Process Sleep Resumptions (bounded per heartbeat; backlog drains on
  // subsequent heartbeats so an unbounded suspended-instance backlog cannot blow
  // row/heap limits). Paused definitions are excluded at the SOQL level so paused
  // sleepers cannot fill the bounded batch and starve resumable rows from other
  // workflows (they would be re-selected and skipped every heartbeat). An
  // org-wide '*' pause means nothing is resumable, so the phase is skipped
  // entirely.
  private static void processSleepResumptions(Datetime now) {
    List<Workflow_Instance__c> readyToResume = new List<Workflow_Instance__c>();
    if (!WorkflowPauseGate.wildcardPaused()) {
      Set<String> pausedDefNames = WorkflowPauseGate.pausedNames();
      readyToResume = [
        SELECT
          Id,
          Status__c,
          Sleep_Until__c,
          Async_Job_Id__c,
          Error_Message__c,
          Workflow_Name__c,
          Current_Step__c,
          Concurrency_Parked__c,
          Concurrency_Slot_Held__c,
          (
            SELECT Workflow_Instance__c, Step_Name__c, Output__c, Id, Status__c
            FROM Workflow_Step_Executions__r
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
          )
        FROM Workflow_Instance__c
        WHERE
          Status__c = 'Suspended'
          AND Sleep_Until__c <= :now
          AND Workflow_Name__c NOT IN :pausedDefNames
        WITH SYSTEM_MODE
        LIMIT :watchdogResumeBatchSize
        FOR UPDATE
      ];
    }

    if (readyToResume.isEmpty()) {
      return;
    }

    SleepResumeBatch b = new SleepResumeBatch();
    for (Workflow_Instance__c inst : readyToResume) {
      if (
        inst.Workflow_Step_Executions__r != null &&
        !inst.Workflow_Step_Executions__r.isEmpty()
      ) {
        b.latestStepByInstId.put(inst.Id, inst.Workflow_Step_Executions__r[0]);
      }
    }

    for (Workflow_Instance__c inst : readyToResume) {
      resumeSuspendedInstance(inst, b);
    }

    flushSleepResumptions(b);
  }

  // Persist the resume batch: insert timed-wait fallbacks, flip instances to
  // their resumed status, enqueue orchestrators, and re-drive parallel branches.
  private static void flushSleepResumptions(SleepResumeBatch b) {
    if (!b.timedWaitFallbackExecs.isEmpty()) {
      Database.insert(b.timedWaitFallbackExecs, true, AccessLevel.SYSTEM_MODE);
    }
    if (!b.instancesToUpdate.isEmpty()) {
      for (Workflow_Instance__c inst : b.instancesToUpdate) {
        resumedInstanceIds.add(inst.Id);
      }
      Database.update(b.instancesToUpdate, true, AccessLevel.SYSTEM_MODE);
    }
    // Honor the test opt-out (mirrors the timed-out-step enqueue above) so a
    // suite asserting only the Suspended -> Running wake transition is not
    // carried to completion by a worker draining at Test.stopTest().
    if (!(Test.isRunningTest() && disableQueueableInTest)) {
      enqueueOrchestrators(b.instanceIds);
    }
    // For a resumed parallel instance the blank-stepName orchestrator above is a
    // no-op (runStep ignores it for a comma-separated Current_Step__c), so
    // re-drive each branch parked for a transient row-lock retry BY NAME. Scoped
    // to Pending/Running steps carrying Transient_Retry_Count__c > 0 — the
    // durable target the transient-lock backoff persists. handleCrash leaves the
    // row Pending after a rollback, or Running when the synchronous harness calls
    // it without one, so both statuses are matched; genuinely in-flight branches
    // (count 0) and ordinary fan-out steps are left untouched. The actual enqueue
    // honors the test opt-out internally (like the bulk signal path) so the
    // query/re-arm still run under it.
    if (!b.parallelResumeIds.isEmpty()) {
      reDriveTransientRetryBranches(
        [
          SELECT
            Id,
            Workflow_Instance__c,
            Step_Name__c,
            Workflow_Instance__r.Workflow_Name__c
          FROM Workflow_Step_Execution__c
          WHERE
            Workflow_Instance__c IN :b.parallelResumeIds
            AND Status__c IN ('Pending', 'Running')
            AND Transient_Retry_Count__c > 0
          WITH SYSTEM_MODE
        ]
      );
    }
  }

  // A suspended instance's resume is held when its definition is paused.
  private static Boolean isDefinitionResumeHeld(Workflow_Instance__c inst) {
    return WorkflowPauseGate.anyPaused() &&
      WorkflowPauseGate.isDefinitionPaused(inst.Workflow_Name__c);
  }

  // Resume a single suspended instance: honor the pause gate and concurrency
  // parking, then flip to the appropriate running/compensating status.
  private static void resumeSuspendedInstance(
    Workflow_Instance__c inst,
    SleepResumeBatch b
  ) {
    // Hold, not drop: if the definition is paused, leave the instance Suspended
    // with Sleep_Until__c intact so it re-fires on the next heartbeat after resume.
    if (isDefinitionResumeHeld(inst)) {
      return;
    }
    // A concurrency-parked sleeper has not yet won an admission slot. Do NOT flip
    // it to Running here: that would leave Running rows holding no slot (violating
    // the status/cap invariant) and hide them from the parked count. Drive it back
    // through the admission gate while leaving it Suspended/parked — the gate flips
    // it to Running on a successful acquire, or re-parks it (bumping Sleep_Until__c
    // into the future) on denial. Leave Sleep_Until__c/Async_Job_Id__c intact so
    // the gate owns the transition; the next heartbeat will not re-select it once
    // a re-park has pushed Sleep_Until__c forward, and a duplicate delivery before
    // then is idempotent at the gate's locked re-read.
    if (
      inst.Concurrency_Parked__c == true &&
      inst.Concurrency_Slot_Held__c != true
    ) {
      b.instanceIds.add(inst.Id);
      return;
    }
    Workflow_Step_Execution__c latestStep = b.latestStepByInstId.get(inst.Id);
    if (
      latestStep != null &&
      latestStep.Step_Name__c != null &&
      latestStep.Step_Name__c.endsWith('_Compensate')
    ) {
      if (
        inst.Error_Message__c != null &&
        inst.Error_Message__c.contains('Cancelled by user')
      ) {
        inst.Status__c = 'Cancelling';
      } else {
        inst.Status__c = 'Compensating';
      }
    } else {
      routeNonCompensatingResume(inst, latestStep, b);
    }
    inst.Sleep_Until__c = null;
    inst.Async_Job_Id__c = null;
    b.instanceIds.add(inst.Id);
    b.instancesToUpdate.add(inst);
  }

  // Non-compensating resume path: detect a fired timed-wait and route to the
  // fallback step, otherwise flip to Running and track parallel branches.
  private static void routeNonCompensatingResume(
    Workflow_Instance__c inst,
    Workflow_Step_Execution__c latestStep,
    SleepResumeBatch b
  ) {
    // Timed-wait detection (issue #35): if the latest step exec carries a
    // $timeoutStep key in its Output, the timer fired for a timed suspend/
    // approval wait. Route to the fallback step instead of re-running the
    // current step. Non-compensating, serial instances only.
    String timedWaitTarget = extractTimedWaitTarget(latestStep);
    Boolean isSerial =
      String.isBlank(inst.Current_Step__c) ||
      !inst.Current_Step__c.contains(',');
    if (String.isNotBlank(timedWaitTarget) && isSerial) {
      // Route to the fallback step: create a new Pending exec (append-only)
      // and advance Current_Step__c. The prior wait exec is never mutated.
      Workflow_Step_Execution__c fallbackExec = new Workflow_Step_Execution__c();
      fallbackExec.Workflow_Instance__c = inst.Id;
      fallbackExec.Step_Name__c = timedWaitTarget;
      fallbackExec.Status__c = 'Pending';
      fallbackExec.Input__c = '{"$timeoutResume":true}';
      fallbackExec.Retry_Count__c = 0;
      fallbackExec.Transient_Retry_Count__c = 0;
      b.timedWaitFallbackExecs.add(fallbackExec);
      inst.Current_Step__c = timedWaitTarget;
    }
    inst.Status__c = 'Running';
    if (
      String.isNotBlank(inst.Current_Step__c) &&
      inst.Current_Step__c.contains(',')
    ) {
      b.parallelResumeIds.add(inst.Id);
    }
  }

  // §2b. Sweep Suspended instances for matching Unrouted signals (safety net).
  private static void sweepUnroutedSuspendedSignals() {
    if (WorkflowPauseGate.wildcardPaused()) {
      return;
    }

    // 1. Query sparse Unrouted signals first (safety net capped backlog)
    List<Workflow_Signal__c> unrouted = [
      SELECT
        Id,
        Correlation_Key__c,
        Status__c,
        Idempotency_Key__c,
        Signal_Key__c
      FROM Workflow_Signal__c
      WHERE Status__c = 'Unrouted'
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT 1000
    ];

    if (unrouted.isEmpty()) {
      return;
    }

    Set<String> keys = new Set<String>();
    for (Workflow_Signal__c sig : unrouted) {
      if (String.isNotBlank(sig.Correlation_Key__c)) {
        keys.add(sig.Correlation_Key__c);
      }
    }

    if (keys.isEmpty()) {
      return;
    }

    List<Workflow_Instance__c> matchInsts = findSuspendedInstancesForKeys(keys);
    if (matchInsts.isEmpty()) {
      return;
    }

    redeliverUnroutedSignalsFor(matchInsts);
  }

  // Resolve the Suspended instances whose Id or Correlation_Key matches any of
  // the given Unrouted-signal keys (bounded, excluding paused definitions).
  private static List<Workflow_Instance__c> findSuspendedInstancesForKeys(
    Set<String> keys
  ) {
    Set<String> pausedDefNames = WorkflowPauseGate.pausedNames();

    // Limit batch size defensively for this non-bulkified redelivery loop
    Integer sweepLimit = 20;

    // Split correlation keys from Id binds to avoid System.QueryException: Invalid ID
    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');
    Set<Id> instIds = new Set<Id>();
    Set<String> corrKeys = new Set<String>();

    for (String key : keys) {
      if (idPattern.matcher(key).matches() && key.startsWith(wflowPrefix)) {
        instIds.add((Id) key);
      } else {
        corrKeys.add(key);
      }
    }

    return [
      SELECT
        Id,
        Correlation_Key__c,
        Status__c,
        Concurrency_Parked__c,
        Concurrency_Slot_Held__c
      FROM Workflow_Instance__c
      WHERE
        Status__c = 'Suspended'
        AND (Id IN :instIds
        OR Correlation_Key__c IN :corrKeys)
        AND Workflow_Name__c NOT IN :pausedDefNames
      WITH SYSTEM_MODE
      LIMIT :sweepLimit
      FOR UPDATE
    ];
  }

  // Group all still-Unrouted signals for the matched instances and redeliver them.
  private static void redeliverUnroutedSignalsFor(
    List<Workflow_Instance__c> matchInsts
  ) {
    Map<String, Workflow_Instance__c> keyToInst = new Map<String, Workflow_Instance__c>();
    Set<String> matchInstKeys = new Set<String>();
    for (Workflow_Instance__c inst : matchInsts) {
      String instIdStr = String.valueOf(inst.Id);
      keyToInst.put(normalizeKey(instIdStr), inst);
      matchInstKeys.add(instIdStr);
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        keyToInst.put(normalizeKey(inst.Correlation_Key__c), inst);
        matchInstKeys.add(inst.Correlation_Key__c);
      }
    }

    List<Workflow_Signal__c> allMatchSignals = [
      SELECT
        Id,
        Correlation_Key__c,
        Status__c,
        Idempotency_Key__c,
        Signal_Key__c,
        CreatedDate
      FROM Workflow_Signal__c
      WHERE Status__c = 'Unrouted' AND Correlation_Key__c IN :matchInstKeys
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT 10000
    ];

    if (allMatchSignals.isEmpty()) {
      return;
    }

    Map<Id, List<Workflow_Signal__c>> instIdToSignals = new Map<Id, List<Workflow_Signal__c>>();
    for (Workflow_Signal__c sig : allMatchSignals) {
      if (String.isBlank(sig.Correlation_Key__c)) {
        continue;
      }
      Workflow_Instance__c inst = keyToInst.get(
        normalizeKey(sig.Correlation_Key__c)
      );
      if (inst == null) {
        continue;
      }
      if (!instIdToSignals.containsKey(inst.Id)) {
        instIdToSignals.put(inst.Id, new List<Workflow_Signal__c>());
      }
      instIdToSignals.get(inst.Id).add(sig);
    }

    redeliverCapturedSignalsBulk(matchInsts, instIdToSignals);
  }

  // §5. Rescue transient-lock retry branches orphaned when a parallel sibling
  // that completed during the backoff flipped the parent out of Suspended (e.g. a
  // CompensatableStep persisting the parent as Running). The sleep-resume above
  // only selects Suspended parents, so such a retry branch would otherwise never
  // be re-driven and the workflow would hang. Sleep_Until__c survives on the
  // instance, so re-drive any due retry-marked branch under a non-terminal,
  // non-Suspended (Running) parallel parent. Best-effort like the sweeps above: a
  // publish hiccup retries on the next heartbeat (Sleep_Until__c is left intact)
  // instead of aborting the core wake/timeout work. Self-resolving — once
  // re-driven the branch either succeeds (counter resets to 0) or re-crashes back
  // to Suspended (handled above).
  private static void rescueOrphanedTransientRetryBranches(Datetime now) {
    try {
      if (WorkflowPauseGate.wildcardPaused()) {
        return;
      }
      Set<String> orphanPausedDefs = WorkflowPauseGate.pausedNames();
      reDriveTransientRetryBranches(
        [
          SELECT
            Id,
            Workflow_Instance__c,
            Step_Name__c,
            Workflow_Instance__r.Workflow_Name__c
          FROM Workflow_Step_Execution__c
          WHERE
            Transient_Retry_Count__c > 0
            AND Status__c IN ('Pending', 'Running')
            AND Workflow_Instance__r.Status__c = 'Running'
            AND Workflow_Instance__r.Sleep_Until__c != NULL
            AND Workflow_Instance__r.Sleep_Until__c <= :now
            AND Workflow_Instance__r.Current_Step__c LIKE '%,%'
            AND Workflow_Instance__r.Workflow_Name__c NOT IN :orphanPausedDefs
          WITH SYSTEM_MODE
          LIMIT :watchdogResumeBatchSize
        ]
      );
    } catch (Exception ignored) {
      // Best-effort re-drive; Sleep_Until__c is left intact so the next heartbeat retries.
    }
  }

  // §6. Auto-reclaim orphaned instances. Sweeps for instances stuck in a
  // self-driving status (Pending/Running/Compensating/Cancelling) whose
  // referenced async job is no longer alive, and re-enqueues them at their last
  // durable step.
  private static void autoReclaimOrphanedInstances(Datetime now) {
    try {
      if (
        reclaimThresholdMinutes == null ||
        reclaimThresholdMinutes <= 0 ||
        WorkflowPauseGate.wildcardPaused()
      ) {
        return;
      }
      Set<String> pausedDefNames = WorkflowPauseGate.pausedNames();
      List<Workflow_Instance__c> candidates = [
        SELECT
          Id,
          Name,
          Status__c,
          Current_Step__c,
          Compensation_Stack__c,
          Async_Job_Id__c,
          Workflow_Name__c,
          Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE
          Status__c IN ('Pending', 'Running', 'Compensating', 'Cancelling')
          AND LastModifiedDate <= :now.addMinutes(-reclaimThresholdMinutes)
          AND Workflow_Name__c NOT IN :pausedDefNames
        WITH SYSTEM_MODE
        ORDER BY LastModifiedDate ASC, Id ASC
        LIMIT 50
      ];

      if (candidates.isEmpty()) {
        return;
      }

      Set<Id> orphanIds = findOrphanCandidateIds(candidates);
      if (orphanIds.isEmpty()) {
        return;
      }

      List<Workflow_Instance__c> lockedOrphans = [
        SELECT
          Id,
          Name,
          Status__c,
          Current_Step__c,
          Compensation_Stack__c,
          Async_Job_Id__c,
          Workflow_Name__c,
          Correlation_Key__c,
          LastModifiedDate
        FROM Workflow_Instance__c
        WHERE
          Id IN :orphanIds
          AND Status__c IN ('Pending', 'Running', 'Compensating', 'Cancelling')
        WITH SYSTEM_MODE
        FOR UPDATE
      ];

      if (lockedOrphans.isEmpty()) {
        return;
      }

      // Re-check liveness of the locked candidates to make sure they didn't
      // progress in the race window.
      List<Workflow_Instance__c> confirmedOrphans = confirmLockedOrphans(
        lockedOrphans,
        now
      );

      if (!confirmedOrphans.isEmpty()) {
        reclaimOrphanedInstances(confirmedOrphans);
      }
    } catch (Exception ignored) {
      // Best-effort sweep; a failure here must not abort the watchdog heartbeat.
    }
  }

  // First-pass orphan detection: return the ids of candidate instances whose
  // referenced async job is no longer alive.
  private static Set<Id> findOrphanCandidateIds(
    List<Workflow_Instance__c> candidates
  ) {
    Set<Id> activeJobIds = resolveActiveJobIds(collectValidJobIds(candidates));
    Set<Id> orphanIds = new Set<Id>();
    for (Workflow_Instance__c inst : candidates) {
      if (isInstanceOrphaned(inst, activeJobIds)) {
        orphanIds.add(inst.Id);
      }
    }
    return orphanIds;
  }

  // Second-pass confirmation under the FOR UPDATE lock: drop any instance that
  // progressed recently and re-check liveness of the rest.
  private static List<Workflow_Instance__c> confirmLockedOrphans(
    List<Workflow_Instance__c> lockedOrphans,
    Datetime now
  ) {
    Set<Id> lockedActiveJobIds = resolveActiveJobIds(
      collectValidJobIds(lockedOrphans)
    );
    List<Workflow_Instance__c> confirmedOrphans = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c inst : lockedOrphans) {
      if (inst.LastModifiedDate > now.addMinutes(-reclaimThresholdMinutes)) {
        continue; // legitimately progressed/touched recently
      }
      if (isInstanceOrphaned(inst, lockedActiveJobIds)) {
        confirmedOrphans.add(inst);
      }
    }
    return confirmedOrphans;
  }

  // Collect the well-formed CronTrigger/AsyncApexJob ids referenced by the given
  // instances' Async_Job_Id__c.
  private static Set<Id> collectValidJobIds(List<Workflow_Instance__c> insts) {
    Set<Id> jobIds = new Set<Id>();
    for (Workflow_Instance__c inst : insts) {
      if (String.isBlank(inst.Async_Job_Id__c)) {
        continue;
      }
      String jobIdStr = inst.Async_Job_Id__c;
      if (
        !((jobIdStr.length() == 15 || jobIdStr.length() == 18) &&
        (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707')))
      ) {
        continue;
      }
      try {
        jobIds.add((Id) jobIdStr);
      } catch (Exception ignored) {
        // Malformed Async_Job_Id__c; skip the liveness check for this instance.
      }
    }
    return jobIds;
  }

  // Resolve which of the given job ids are still alive (WAITING/ACQUIRED/QUEUED/
  // EXECUTING crons or Queued/Holding/Preparing/Processing async jobs).
  private static Set<Id> resolveActiveJobIds(Set<Id> jobIds) {
    Set<Id> cronIds = new Set<Id>();
    Set<Id> asyncIds = new Set<Id>();
    for (Id jobId : jobIds) {
      if (jobId.getSobjectType() == CronTrigger.SObjectType) {
        cronIds.add(jobId);
      } else if (jobId.getSobjectType() == AsyncApexJob.SObjectType) {
        asyncIds.add(jobId);
      }
    }

    Set<Id> activeIds = new Set<Id>();
    if (!cronIds.isEmpty()) {
      for (CronTrigger ct : [
        SELECT Id
        FROM CronTrigger
        WHERE
          Id IN :cronIds
          AND State IN ('WAITING', 'ACQUIRED', 'QUEUED', 'EXECUTING')
        WITH SYSTEM_MODE
      ]) {
        activeIds.add(ct.Id);
      }
    }
    if (!asyncIds.isEmpty()) {
      for (AsyncApexJob aaj : [
        SELECT Id
        FROM AsyncApexJob
        WHERE
          Id IN :asyncIds
          AND Status IN ('Queued', 'Holding', 'Preparing', 'Processing')
        WITH SYSTEM_MODE
      ]) {
        activeIds.add(aaj.Id);
      }
    }
    return activeIds;
  }

  // An instance is orphaned when it has no async job id, a malformed one, or a
  // well-formed id that is not in the set of currently-alive jobs.
  private static Boolean isInstanceOrphaned(
    Workflow_Instance__c inst,
    Set<Id> activeJobIds
  ) {
    if (String.isBlank(inst.Async_Job_Id__c)) {
      return true;
    }
    String jobIdStr = inst.Async_Job_Id__c;
    if (
      !((jobIdStr.length() == 15 || jobIdStr.length() == 18) &&
      (jobIdStr.startsWith('08e') || jobIdStr.startsWith('707')))
    ) {
      return true;
    }
    try {
      Id jobId = (Id) jobIdStr;
      return !activeJobIds.contains(jobId);
    } catch (Exception ex) {
      return true;
    }
  }

  private static Integer getStepTimeoutSeconds(
    String stepName,
    String contextNamespace
  ) {
    if (String.isBlank(stepName)) {
      return null;
    }
    String cacheKey = (stepName +
      (String.isNotBlank(contextNamespace) ? ('|' + contextNamespace) : ''))
      .toLowerCase();
    if (stepTimeoutCache.containsKey(cacheKey)) {
      return stepTimeoutCache.get(cacheKey);
    }
    String className = stepName.endsWith('_Compensate')
      ? stepName.substring(0, stepName.lastIndexOf('_Compensate'))
      : stepName;
    Integer timeout = null;
    try {
      Type stepType = WorkflowTypeResolver.resolve(className, contextNamespace);
      if (stepType != null) {
        Object stepObj = stepType.newInstance();
        if (stepObj instanceof TimeoutConfigurable) {
          timeout = ((TimeoutConfigurable) stepObj).getTimeoutSeconds();
        }
      }
    } catch (Exception ignored) {
      // Step type may not be instantiable here; leave timeout unset.
    }
    stepTimeoutCache.put(cacheKey, timeout);
    return timeout;
  }

  private static String resolveContinueAsNewKey(
    String currentKey,
    String customKey
  ) {
    if (String.isNotBlank(customKey)) {
      return customKey;
    }
    if (String.isBlank(currentKey)) {
      return 'Run_' + System.currentTimeMillis();
    }

    Pattern p = Pattern.compile('^(.*)_run(\\d+)$');
    Matcher m = p.matcher(currentKey);
    if (m.matches()) {
      String base = m.group(1);
      Integer nextNum = Integer.valueOf(m.group(2)) + 1;
      return base + '_run' + nextNum;
    }
    return currentKey + '_run2';
  }

  /**
   * @description Schedules the dynamic timeout jobs for a batch of instances,
   * arming the deadline of each instance's active step (or, for a compensating
   * saga, its current compensation step) so the watchdog can enforce timeouts.
   * @param instances the instances whose active steps' timeout jobs are scheduled
   */
  public static void scheduleTimeoutJobsForInstances(
    List<Workflow_Instance__c> instances
  ) {
    for (Workflow_Instance__c instance : instances) {
      armTimeoutJobsForInstance(instance);
    }
  }

  /**
   * Arms the timeout job(s) for a single instance's active work — the current
   * compensation step for a compensating saga, otherwise the active step(s).
   * @param instance the instance whose timeout jobs are armed
   */
  private static void armTimeoutJobsForInstance(Workflow_Instance__c instance) {
    if (
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling'
    ) {
      armCompensationTimeoutJob(instance);
      return;
    }
    if (String.isBlank(instance.Current_Step__c)) {
      return;
    }
    armActiveStepTimeoutJobs(instance);
  }

  /**
   * Arms the timeout job for the top of a compensating saga's compensation stack.
   * @param instance the compensating/cancelling instance
   */
  private static void armCompensationTimeoutJob(Workflow_Instance__c instance) {
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
    scheduleTimeoutJobIfNeeded(
      instance.Id,
      stack[stack.size() - 1] + '_Compensate',
      instance.Workflow_Name__c
    );
  }

  /**
   * Arms timeout jobs for an instance's active step(s), fanning out over the
   * comma-separated parallel steps when present.
   * @param instance the running instance whose active step(s) are armed
   */
  private static void armActiveStepTimeoutJobs(Workflow_Instance__c instance) {
    if (!instance.Current_Step__c.contains(',')) {
      scheduleTimeoutJobIfNeeded(
        instance.Id,
        instance.Current_Step__c,
        instance.Workflow_Name__c
      );
      return;
    }
    for (String pStep : instance.Current_Step__c.split(',')) {
      scheduleTimeoutJobIfNeeded(
        instance.Id,
        pStep.trim(),
        instance.Workflow_Name__c
      );
    }
  }

  /**
   * Re-drives a set of parallel-branch steps that are parked for a transient row-lock
   * retry, BY NAME (the blank-stepName watchdog orchestrator is ignored for a
   * comma-separated Current_Step__c). Shared by the watchdog sleep-resume (Suspended
   * parents) and the orphaned-retry sweep (Running parents whose sibling flipped them
   * out of Suspended). Re-arms ONLY these retry-marked rows' watchdog deadlines (so a
   * sibling's overdue deadline is not masked) and bulk-publishes a single EventBus
   * call (so a heartbeat waking many sleepers cannot exhaust the DML-statement limit),
   * throwing on any failed publish so the wake-up rolls back and retries intact.
   * @param retryBranches the transient-retry-marked parallel branch step executions
   * to re-drive by name
   */
  /**
   * Raises a WorkflowException if any platform-event publish result failed.
   * @param srs the save results returned by EventBus.publish
   * @param errorPrefix message prefix identifying the failing publish site
   */
  private static void throwOnPublishErrors(
    List<Database.SaveResult> srs,
    String errorPrefix
  ) {
    for (Database.SaveResult sr : srs) {
      if (sr.isSuccess()) {
        continue;
      }
      List<String> errMsgs = new List<String>();
      for (Database.Error err : sr.getErrors()) {
        errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
      }
      throw new WorkflowException(errorPrefix + String.join(errMsgs, ', '));
    }
  }

  /**
   * Builds the fresh Timeout_At__c re-arm updates for transient-retry branches
   * that have a positive step timeout configured.
   * @param retryBranches the retry-marked step rows
   * @return the step updates to apply (may be empty)
   */
  private static List<Workflow_Step_Execution__c> buildTransientRetryReArm(
    List<Workflow_Step_Execution__c> retryBranches
  ) {
    List<Workflow_Step_Execution__c> toReArm = new List<Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c branch : retryBranches) {
      Integer timeout = getStepTimeoutSeconds(
        branch.Step_Name__c,
        WorkflowTypeResolver.extractNamespace(
          branch.Workflow_Instance__r.Workflow_Name__c
        )
      );
      if (timeout == null || timeout <= 0) {
        continue;
      }
      toReArm.add(
        new Workflow_Step_Execution__c(
          Id = branch.Id,
          Timeout_At__c = DateTime.now().addSeconds(timeout)
        )
      );
    }
    return toReArm;
  }

  /**
   * Dispatches each transient-retry branch: enqueues the orchestrator directly
   * under test, otherwise collects a RUN_STEP event for bulk publish.
   * @param retryBranches the retry-marked step rows
   * @return the RUN_STEP events to publish (empty under test)
   */
  private static List<Workflow_Event__e> dispatchTransientRetryBranches(
    List<Workflow_Step_Execution__c> retryBranches
  ) {
    List<Workflow_Event__e> branchEvents = new List<Workflow_Event__e>();
    for (Workflow_Step_Execution__c branch : retryBranches) {
      Workflow_Event__e evt = dispatchTransientRetryBranchOne(branch);
      if (evt != null) {
        branchEvents.add(evt);
      }
    }
    return branchEvents;
  }

  /**
   * @description Dispatches a single transient-retry branch, choosing between
   * the production platform-event path and the test direct-enqueue path. Under
   * test the per-branch `System.enqueueJob` runs inside this helper so it is
   * not lexically inside the caller's loop; production still collects a
   * RUN_STEP event for a single bulk `EventBus.publish`.
   * @param branch the retry-marked step row to dispatch
   * @return the RUN_STEP event to publish (production), or null under test
   */
  private static Workflow_Event__e dispatchTransientRetryBranchOne(
    Workflow_Step_Execution__c branch
  ) {
    if (!Test.isRunningTest()) {
      return new Workflow_Event__e(
        Workflow_Instance_Id__c = branch.Workflow_Instance__c,
        Event_Type__c = 'RUN_STEP',
        Payload__c = branch.Step_Name__c
      );
    }
    if (!disableQueueableInTest) {
      System.enqueueJob(
        new WorkflowOrchestrator(
          branch.Workflow_Instance__c,
          branch.Step_Name__c
        )
      );
    }
    return null;
  }

  private static void reDriveTransientRetryBranches(
    List<Workflow_Step_Execution__c> retryBranches
  ) {
    if (retryBranches == null || retryBranches.isEmpty()) {
      return;
    }
    // Re-arm only the retry-marked rows whose deadline scheduleTransientLockRetry
    // cleared for backoff (their instance is necessarily past admission, so no
    // concurrency-defer check is needed) — never every active step on the instance.
    List<Workflow_Step_Execution__c> toReArm = buildTransientRetryReArm(
      retryBranches
    );
    if (!toReArm.isEmpty()) {
      Database.update(toReArm, true, AccessLevel.SYSTEM_MODE);
    }

    List<Workflow_Event__e> branchEvents = dispatchTransientRetryBranches(
      retryBranches
    );
    if (!branchEvents.isEmpty()) {
      WorkflowWatchdog.bootstrap();
      List<Database.SaveResult> srs = EventBus.publish(branchEvents);
      throwOnPublishErrors(
        srs,
        'Failed to publish transient-retry branch event: '
      );
    }
  }

  /**
   * Re-establishes step timeouts for instances being resumed from a Paused park.
   * Parking clears/omits the watchdog deadline so parked rows do not pollute the
   * timeout batch; on resume we re-stamp a fresh Timeout_At__c on each instance's
   * current Pending/Running step(s) (the watchdog safety net) and schedule the
   * dynamic timeout jobs, mirroring how start() arms a fresh step. Must run before
   * the resumed workers are enqueued so a delayed worker still has an enforced
   * deadline.
   * @param instances the instances being resumed from a Paused park to re-arm
   */
  public static void reArmTimeoutsForResume(
    List<Workflow_Instance__c> instances
  ) {
    if (instances == null || instances.isEmpty()) {
      return;
    }
    Set<Id> instanceIds = new Set<Id>();
    for (Workflow_Instance__c inst : instances) {
      instanceIds.add(inst.Id);
    }

    Set<Id> deferIds = collectConcurrencyDeferIds(instanceIds);

    List<Workflow_Step_Execution__c> steps = [
      SELECT
        Id,
        Workflow_Instance__c,
        Step_Name__c,
        Workflow_Instance__r.Workflow_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instanceIds
        AND Status__c IN ('Pending', 'Running')
      WITH SYSTEM_MODE
    ];
    reArmStepDeadlines(steps, deferIds);
    scheduleActiveStepTimeoutJobs(steps, deferIds);
  }

  /**
   * Re-queries the authoritative slot flag and collects the ids of concurrency-
   * bounded instances that have not yet won an admission slot. Their initial step
   * deadline must NOT be re-armed here (the admission gate re-arms it once a slot
   * is won); an in-memory caller value cannot skew this decision.
   * @param instanceIds the candidate instance ids being resumed
   * @return the ids whose deadline re-arm must be deferred to the admission gate
   */
  private static Set<Id> collectConcurrencyDeferIds(Set<Id> instanceIds) {
    Set<Id> deferIds = new Set<Id>();
    for (Workflow_Instance__c inst : [
      SELECT Id, Workflow_Name__c, Concurrency_Slot_Held__c
      FROM Workflow_Instance__c
      WHERE Id IN :instanceIds
      WITH SYSTEM_MODE
    ]) {
      if (
        !inst.Concurrency_Slot_Held__c &&
        ConcurrencyGate.isConfigured(inst.Workflow_Name__c)
      ) {
        deferIds.add(inst.Id);
      }
    }
    return deferIds;
  }

  /**
   * Re-stamps a fresh watchdog deadline on each non-deferred active step that has
   * a positive configured timeout, then persists them in a single update.
   * @param steps the queried Pending/Running step rows
   * @param deferIds instance ids whose steps must not be re-armed
   */
  private static void reArmStepDeadlines(
    List<Workflow_Step_Execution__c> steps,
    Set<Id> deferIds
  ) {
    List<Workflow_Step_Execution__c> toUpdate = new List<Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c step : steps) {
      if (deferIds.contains(step.Workflow_Instance__c)) {
        continue;
      }
      Integer timeout = getStepTimeoutSeconds(
        step.Step_Name__c,
        WorkflowTypeResolver.extractNamespace(
          step.Workflow_Instance__r.Workflow_Name__c
        )
      );
      if (timeout == null || timeout <= 0) {
        continue;
      }
      step.Timeout_At__c = DateTime.now().addSeconds(timeout);
      toUpdate.add(step);
    }
    if (!toUpdate.isEmpty()) {
      Database.update(toUpdate, true, AccessLevel.SYSTEM_MODE);
    }
  }

  /**
   * Schedules the dynamic timeout jobs for the genuinely active (non-deferred)
   * step rows only. A parallel instance keeps every branch name in Current_Step__c
   * until the join, so a completed branch lingers there; driving off the queried
   * Pending/Running rows (instead of parsing Current_Step__c) avoids scheduling a
   * timeout for a completed branch that would later find no active step row and
   * wrongly fail the whole instance "before starting".
   * @param steps the queried Pending/Running step rows
   * @param deferIds instance ids whose steps must not be scheduled
   */
  private static void scheduleActiveStepTimeoutJobs(
    List<Workflow_Step_Execution__c> steps,
    Set<Id> deferIds
  ) {
    for (Workflow_Step_Execution__c step : steps) {
      if (deferIds.contains(step.Workflow_Instance__c)) {
        continue;
      }
      scheduleTimeoutJobIfNeeded(
        step.Workflow_Instance__c,
        step.Step_Name__c,
        step.Workflow_Instance__r.Workflow_Name__c
      );
    }
  }

  /**
   * @description Schedules the timeout job for a single instance by Id, querying
   * the fields needed to arm the deadline before delegating to the record overload.
   * @param instanceId Id of the instance whose timeout job is scheduled
   */
  public static void scheduleTimeoutJobForInstance(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Workflow_Name__c,
        Status__c,
        Current_Step__c,
        Compensation_Stack__c,
        Concurrency_Parked__c,
        Concurrency_Slot_Held__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      return;
    }
    scheduleTimeoutJobForInstance(instances[0]);
  }

  // Overload for callers that already hold the instance with the fields this needs
  // (Status__c, Current_Step__c, Compensation_Stack__c, and the two concurrency
  // flags). Skipping the re-query matters on the per-step drive: handleStepResult
  // schedules the next step's watchdog on every advance, so re-reading the instance
  // each time can exhaust the 100-SOQL limit on a long synchronous drive (e.g. the
  // test harness driving many steps in one transaction).
  /**
   * @description Schedules the timeout job for an already-loaded instance record,
   * avoiding a re-query on the hot per-step drive. Skips a concurrency-parked
   * instance that has not yet won a slot (its step has no deadline yet).
   * @param instance the instance record carrying the fields needed to arm the timeout
   */
  public static void scheduleTimeoutJobForInstance(
    Workflow_Instance__c instance
  ) {
    if (instance == null) {
      return;
    }
    // A concurrency-parked instance that has not won a slot has a null step deadline;
    // scheduling a timeout job now would only wake and return, while occupying one of
    // the org's scarce scheduled-job slots — a large parked backlog could crowd out
    // real sleep/admission/timeout jobs. Admission re-arms the timeout once a slot is
    // won (the generic WorkflowSleepJob admission-retry path routes through here).
    if (instance.Concurrency_Parked__c && !instance.Concurrency_Slot_Held__c) {
      return;
    }
    scheduleTimeoutJobsForInstances(new List<Workflow_Instance__c>{ instance });
  }

  /**
   * @description Schedules a dynamic timeout job for a step when one is configured,
   * resolving the workflow namespace from the instance.
   * @param instanceId Id of the instance owning the step
   * @param stepName name of the step to arm a timeout for
   */
  public static void scheduleTimeoutJobIfNeeded(
    Id instanceId,
    String stepName
  ) {
    scheduleTimeoutJobIfNeeded(instanceId, stepName, null);
  }

  /**
   * @description Schedules a dynamic timeout job for a step when a positive timeout
   * is configured and dynamic scheduling is enabled. The workflow name, when
   * supplied, avoids a namespace-resolving query.
   * @param instanceId Id of the instance owning the step
   * @param stepName name of the step to arm a timeout for
   * @param workflowName developer name of the workflow, or null to resolve it
   */
  public static void scheduleTimeoutJobIfNeeded(
    Id instanceId,
    String stepName,
    String workflowName
  ) {
    if (String.isBlank(stepName) || !useDynamicScheduling) {
      return;
    }
    try {
      String ns = resolveNamespaceForStep(instanceId, workflowName);
      Integer timeoutSeconds = getStepTimeoutSeconds(stepName, ns);
      if (timeoutSeconds == null || timeoutSeconds <= 0) {
        return;
      }
      if (tryEnqueueTimeoutJob(instanceId, stepName, timeoutSeconds)) {
        return;
      }
      scheduleTimeoutCronJob(instanceId, stepName, timeoutSeconds);
    } catch (AsyncException ignored) {
      // Scheduling limit reached; the watchdog heartbeat enforces the timeout instead.
    } catch (Exception ignored) {
      // Timeout scheduling is best-effort; the watchdog heartbeat is the backstop.
    }
  }

  /**
   * Resolves the namespace for timeout scheduling, using the supplied workflow
   * name when present to avoid a query, otherwise looking it up by instance.
   * @param instanceId the instance owning the step
   * @param workflowName the workflow developer name, or null to resolve it
   * @return the resolved namespace, or null when it cannot be determined
   */
  private static String resolveNamespaceForStep(
    Id instanceId,
    String workflowName
  ) {
    if (String.isNotBlank(workflowName)) {
      return WorkflowTypeResolver.extractNamespace(workflowName);
    }
    List<Workflow_Instance__c> insts = [
      SELECT Workflow_Name__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (insts.isEmpty()) {
      return null;
    }
    return WorkflowTypeResolver.extractNamespace(insts[0].Workflow_Name__c);
  }

  /**
   * Fast path: enqueues a minute-granular queueable timeout job when the timeout
   * qualifies (outside test, 60-600s, whole minutes) and queueable budget remains.
   * @param instanceId the instance owning the step
   * @param stepName the step to arm a timeout for
   * @param timeoutSeconds the configured positive timeout in seconds
   * @return true when a queueable job was enqueued (caller is done), else false
   */
  private static Boolean tryEnqueueTimeoutJob(
    Id instanceId,
    String stepName,
    Integer timeoutSeconds
  ) {
    if (
      Test.isRunningTest() ||
      timeoutSeconds < 60 ||
      timeoutSeconds > 600 ||
      Math.mod(timeoutSeconds, 60) != 0
    ) {
      return false;
    }
    if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
      return false;
    }
    System.enqueueJob(
      new WorkflowTimeoutJob.QueueableTimeoutJob(instanceId, stepName),
      timeoutSeconds / 60
    );
    return true;
  }

  /**
   * Schedules a cron-based timeout job, first clearing any stale deterministically
   * -named job so a re-schedule is registered rather than silently dropped.
   * @param instanceId the instance owning the step
   * @param stepName the step to arm a timeout for
   * @param timeoutSeconds the configured positive timeout in seconds
   */
  private static void scheduleTimeoutCronJob(
    Id instanceId,
    String stepName,
    Integer timeoutSeconds
  ) {
    WorkflowTimeoutJob job = new WorkflowTimeoutJob(instanceId, stepName);
    Datetime runTime = Datetime.now()
      .addSeconds(Test.isRunningTest() ? timeoutSeconds + 60 : timeoutSeconds);
    String cronStr =
      runTime.second() +
      ' ' +
      runTime.minute() +
      ' ' +
      runTime.hour() +
      ' ' +
      runTime.day() +
      ' ' +
      runTime.month() +
      ' ? ' +
      runTime.year();
    String cleanStepName = stepName.replaceAll('[^a-zA-Z0-9]', '_');
    String jobName = 'Timeout_' + instanceId + '_' + cleanStepName;
    // The job name is deterministic, so a re-schedule (e.g. retry, or a yielded step
    // that re-enters before its prior timeout job fires) collides with the existing
    // scheduled job and System.schedule() throws. Clear any stale job with this name
    // first so the new timeout is actually registered instead of silently dropped.
    cancelTimeoutJob(instanceId, stepName);
    System.schedule(jobName, cronStr, job);
  }

  /**
   * Determines whether a delay can be scheduled as a minute-granular queueable job.
   * @param delaySeconds the configured delay in seconds
   * @return true when the delay qualifies for a minute-granular queueable job
   *   (outside test, 60-600s, whole minutes) and queueable budget remains
   */
  private static Boolean qualifiesForMinuteQueueable(Integer delaySeconds) {
    return !Test.isRunningTest() &&
      delaySeconds >= 60 &&
      delaySeconds <= 600 &&
      Math.mod(delaySeconds, 60) == 0 &&
      Limits.getQueueableJobs() < Limits.getLimitQueueableJobs();
  }

  private static String scheduleRetry(
    Id instanceId,
    String stepName,
    Integer delaySeconds
  ) {
    if (!useDynamicScheduling) {
      return null;
    }
    try {
      if (qualifiesForMinuteQueueable(delaySeconds)) {
        return String.valueOf(
          System.enqueueJob(
            new WorkflowRetryJob.QueueableRetryJob(instanceId, stepName),
            delaySeconds / 60
          )
        );
      }
      WorkflowRetryJob job = new WorkflowRetryJob(instanceId, stepName);
      Datetime runTime = Datetime.now()
        .addSeconds(Test.isRunningTest() ? delaySeconds + 60 : delaySeconds);
      String cronStr =
        runTime.second() +
        ' ' +
        runTime.minute() +
        ' ' +
        runTime.hour() +
        ' ' +
        runTime.day() +
        ' ' +
        runTime.month() +
        ' ? ' +
        runTime.year();
      return String.valueOf(
        System.schedule(
          'WorkflowRetry_' + instanceId + '_' + runTime.getTime(),
          cronStr,
          job
        )
      );
    } catch (AsyncException ignored) {
      // Scheduling limit reached; the watchdog heartbeat re-drives the retry instead.
      return null;
    } catch (Exception ignored) {
      // Retry scheduling is best-effort; the watchdog heartbeat is the backstop.
      return null;
    }
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
    instance.Async_Job_Id__c = scheduleSleepResume(
      instance.Id,
      resolvedStep,
      retrySeconds
    );
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
  }

  private static String scheduleSleepResume(
    Id instanceId,
    String stepName,
    Integer delaySeconds
  ) {
    if (!useDynamicScheduling) {
      return null;
    }
    try {
      if (qualifiesForMinuteQueueable(delaySeconds)) {
        return String.valueOf(
          System.enqueueJob(
            new WorkflowSleepJob.QueueableSleepJob(instanceId, stepName),
            delaySeconds / 60
          )
        );
      }
      WorkflowSleepJob job = new WorkflowSleepJob(instanceId, stepName);
      Datetime runTime = Datetime.now()
        .addSeconds(Test.isRunningTest() ? delaySeconds + 60 : delaySeconds);
      String cronStr =
        runTime.second() +
        ' ' +
        runTime.minute() +
        ' ' +
        runTime.hour() +
        ' ' +
        runTime.day() +
        ' ' +
        runTime.month() +
        ' ? ' +
        runTime.year();
      String jobName =
        getSleepJobPrefix(instanceId, stepName) +
        '_' +
        runTime.getTime();
      return String.valueOf(System.schedule(jobName, cronStr, job));
    } catch (AsyncException ignored) {
      // Scheduling limit reached; the watchdog heartbeat resumes the sleep instead.
      return null;
    } catch (Exception ignored) {
      // Sleep scheduling is best-effort; the watchdog heartbeat is the backstop.
      return null;
    }
  }

  /**
   * @description Builds the deterministic cron job name prefix for an instance and
   * step's sleep job, so the job can be located or aborted without storing its Id.
   * @param instanceId Id of the instance the sleep job belongs to
   * @param stepName name of the sleeping step
   * @return the sleep job name prefix
   */
  public static String getSleepJobPrefix(Id instanceId, String stepName) {
    String cleanStepName = String.isNotBlank(stepName)
      ? stepName.replaceAll('[^a-zA-Z0-9]', '_')
      : '';
    if (cleanStepName.length() > 25) {
      cleanStepName =
        cleanStepName.substring(0, 15) +
        '_' +
        Math.abs(cleanStepName.hashCode());
    }
    return 'WorkflowSleep_' +
      instanceId +
      (String.isNotBlank(cleanStepName) ? '_' + cleanStepName : '');
  }

  private static void cancelTimeoutJob(Id instanceId, String stepName) {
    String cleanStepName = stepName.replaceAll('[^a-zA-Z0-9]', '_');
    String jobName = 'Timeout_' + instanceId + '_' + cleanStepName;
    List<CronTrigger> triggers = [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name = :jobName
      WITH SYSTEM_MODE
    ];
    for (CronTrigger triggerJob : triggers) {
      try {
        System.abortJob(triggerJob.Id);
      } catch (Exception ignored) {
        // Job may already have fired or been removed; nothing further to do.
      }
    }
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
   * Re-delivers a captured (Unrouted) signal by correlating it to a now-active
   * workflow instance. If a match is found the signal row is re-parented
   * (Workflow_Instance__c set, Status flipped to 'Received') and the instance
   * is woken via the normal resume handoff. Returns true if a match was found,
   * false if the signal is still unmatched (safe no-op).
   * @param signalId Id of the captured (Unrouted) signal to redeliver
   * @return true when the signal was matched and re-parented; false when still unmatched
   */
  public static Boolean redeliverCapturedSignal(Id signalId) {
    Workflow_Signal__c sig = loadUnroutedSignal(signalId);
    if (sig == null) {
      return false;
    }

    String keyOrId = sig.Correlation_Key__c;
    if (String.isBlank(keyOrId)) {
      return false;
    }

    Workflow_Instance__c instance = resolveRedeliveryTarget(keyOrId);
    if (instance == null) {
      return false;
    }

    return deliverRedeliveredSignal(sig, instance);
  }

  /**
   * Loads and locks the Unrouted captured signal to redeliver.
   * @param signalId the captured signal id
   * @return the locked Unrouted signal row, or null when none matches
   */
  private static Workflow_Signal__c loadUnroutedSignal(Id signalId) {
    List<Workflow_Signal__c> rows = [
      SELECT
        Id,
        Status__c,
        Correlation_Key__c,
        Signal_Name__c,
        Payload__c,
        Signal_Key__c,
        Idempotency_Key__c
      FROM Workflow_Signal__c
      WHERE Id = :signalId AND Status__c = 'Unrouted'
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    return rows.isEmpty() ? null : rows[0];
  }

  /**
   * Resolves and locks the active instance to redeliver the captured signal to,
   * preferring an id-shaped key match, then falling back to a correlation-key
   * match.
   * @param keyOrId the captured signal's correlation key (id or key)
   * @return the locked active instance, or null when none is active
   */
  private static Workflow_Instance__c resolveRedeliveryTarget(String keyOrId) {
    List<String> activeStatuses = new List<String>{
      'Pending',
      'Running',
      'Suspended',
      'Compensating',
      'Cancelling',
      'Paused'
    };

    List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
    if (isInstanceId(keyOrId)) {
      instances = [
        SELECT Id, Status__c, Concurrency_Parked__c, Concurrency_Slot_Held__c
        FROM Workflow_Instance__c
        WHERE Id = :keyOrId AND Status__c IN :activeStatuses
        WITH SYSTEM_MODE
        LIMIT 1
        FOR UPDATE
      ];
    }
    if (instances.isEmpty()) {
      instances = [
        SELECT Id, Status__c, Concurrency_Parked__c, Concurrency_Slot_Held__c
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c = :keyOrId AND Status__c IN :activeStatuses
        WITH SYSTEM_MODE
        LIMIT 1
        FOR UPDATE
      ];
    }
    return instances.isEmpty() ? null : instances[0];
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
  private static Boolean deliverRedeliveredSignal(
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

  @TestVisible
  private static void redeliverMatchingSignalsForInstance(
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

  private static void redeliverCapturedSignalsBulk(
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

  private static RetryPolicy sanitizePolicy(RetryPolicy policy) {
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

  private static void persistStepBreadcrumbs(StepOutcomeContext outcome) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    StepContext context = outcome.context;
    if (context == null || stepExec == null || instance == null) {
      return;
    }
    List<StepContext.Breadcrumb> crumbs = context.getBreadcrumbs();
    if (crumbs == null || crumbs.isEmpty()) {
      return;
    }

    // Keep breadcrumbs from exhausting checkpoint SOQL (best-effort observability log drop)
    if (
      Limits.getQueries() + breadcrumbSoqlReserve > Limits.getLimitQueries()
    ) {
      // SOQL budget exhausted; drop best-effort breadcrumbs rather than risk the checkpoint.
      return;
    }

    Integer dynamicRowReserve = computeBreadcrumbRowReserve(outcome);

    // Keep breadcrumbs from exhausting checkpoint DML (best-effort observability log drop)
    if (breadcrumbDmlBudgetExceeded(crumbs.size(), dynamicRowReserve)) {
      // DML budget exhausted; drop best-effort breadcrumbs rather than risk the checkpoint.
      return;
    }

    if (stepExec.Id == null) {
      saveStepExec(stepExec);
    }

    insertBreadcrumbLogs(outcome, crumbs);
  }

  private static Boolean breadcrumbDmlBudgetExceeded(
    Integer crumbCount,
    Integer dynamicRowReserve
  ) {
    return Limits.getDmlStatements() + 1 + breadcrumbDmlStatementReserve >
      Limits.getLimitDmlStatements() ||
      Limits.getDmlRows() + crumbCount + breadcrumbDmlRowReserve +
      dynamicRowReserve > Limits.getLimitDmlRows();
  }

  // Best-effort estimate of the extra DML rows the checkpoint may insert, used
  // to decide whether breadcrumb logs fit within the remaining DML budget.
  private static Integer computeBreadcrumbRowReserve(
    StepOutcomeContext outcome
  ) {
    StepResult result = outcome.result;
    if (result == null) {
      return 0;
    }
    Integer dynamicRowReserve = 0;
    dynamicRowReserve += reserveForChildRequests(result.childRequests);
    dynamicRowReserve += reserveForParallelSteps(result, outcome.stepExec);
    if (result.outboundEvents != null) {
      dynamicRowReserve += result.outboundEvents.size();
    }
    dynamicRowReserve += computeSignalCleanupRowReserve(outcome);
    return dynamicRowReserve;
  }

  private static Integer reserveForChildRequests(
    List<StepResult.ChildRequest> childRequests
  ) {
    Integer reserve = 0;
    if (childRequests == null) {
      return reserve;
    }
    for (StepResult.ChildRequest req : childRequests) {
      reserve += 3;
      if (String.isNotBlank(req.inputJson) && req.inputJson.length() > 100000) {
        reserve += 2; // ContentVersion + ContentDocumentLink
      }
    }
    return reserve;
  }

  private static Integer reserveForParallelSteps(
    StepResult result,
    Workflow_Step_Execution__c stepExec
  ) {
    Integer reserve = 0;
    if (result.parallelStepNames == null) {
      return reserve;
    }
    for (String ps : result.parallelStepNames) {
      reserve += 1;
      String inputPayload = result.parallelInputJson != null
        ? result.parallelInputJson
        : stepExec.Output__c;
      if (String.isNotBlank(inputPayload) && inputPayload.length() > 100000) {
        reserve += 2; // ContentVersion + ContentDocumentLink
      }
    }
    return reserve;
  }

  // Reserve for the signal-cleanup DML the checkpoint performs when the step
  // consumes signals (COMPLETE / SPLIT / FAIL). Only reached with a non-null
  // result (guarded by the caller).
  private static Integer computeSignalCleanupRowReserve(
    StepOutcomeContext outcome
  ) {
    StepResult result = outcome.result;
    StepContext context = outcome.context;
    Workflow_Instance__c instance = outcome.instance;
    Boolean willConsumeSignals = (result.action ==
    StepResult.ActionType.COMPLETE ||
    result.action == StepResult.ActionType.SPLIT ||
    result.action == StepResult.ActionType.FAIL);
    if (!willConsumeSignals) {
      return 0;
    }
    Set<String> matchedNames = context.getConsumedSignalNames();
    if (matchedNames == null || matchedNames.isEmpty()) {
      return 0;
    }
    Boolean isParallel =
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',');
    Boolean runDuplicateCleanup = !isParallel && !context.signalReadWasCapped();
    if (runDuplicateCleanup) {
      return reserveForDuplicateCleanup(instance, context, matchedNames);
    }
    return reserveForConsumedSignals(context);
  }

  private static Integer reserveForDuplicateCleanup(
    Workflow_Instance__c instance,
    StepContext context,
    Set<String> matchedNames
  ) {
    Integer reserve = [
      SELECT COUNT()
      FROM Workflow_Signal__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Status__c = 'Received'
        AND Signal_Name__c IN :matchedNames
      WITH SYSTEM_MODE
    ];
    Set<Id> claimedIds = context.getClaimedSignalIds();
    if (claimedIds != null && !claimedIds.isEmpty()) {
      reserve += [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE Id IN :claimedIds AND Status__c = 'Processing'
        WITH SYSTEM_MODE
      ];
    }
    return reserve;
  }

  private static Integer reserveForConsumedSignals(StepContext context) {
    Set<Id> consumedIds = context.getConsumedSignalIds();
    Set<Id> claimedIds = context.getClaimedSignalIds();
    Set<Id> allIds = new Set<Id>();
    if (consumedIds != null) {
      allIds.addAll(consumedIds);
    }
    if (claimedIds != null) {
      allIds.addAll(claimedIds);
    }
    if (allIds.isEmpty()) {
      return 0;
    }
    return [
      SELECT COUNT()
      FROM Workflow_Signal__c
      WHERE Id IN :allIds AND Status__c IN ('Received', 'Processing')
      WITH SYSTEM_MODE
    ];
  }

  private static void insertBreadcrumbLogs(
    StepOutcomeContext outcome,
    List<StepContext.Breadcrumb> crumbs
  ) {
    Workflow_Instance__c instance = outcome.instance;
    Workflow_Step_Execution__c stepExec = outcome.stepExec;
    List<Workflow_Log__c> logsToInsert = new List<Workflow_Log__c>();
    for (StepContext.Breadcrumb b : crumbs) {
      logsToInsert.add(
        new Workflow_Log__c(
          Workflow_Instance__c = instance.Id,
          Workflow_Name__c = instance.Workflow_Name__c,
          Correlation_Key__c = stepExec.Id,
          Log_Type__c = StepContext.LOG_TYPE_BREADCRUMB,
          Level__c = (b.level != null) ? b.level.name() : 'INFO',
          Message__c = b.message,
          Fire_Time__c = b.timestamp
        )
      );
    }
    Database.insert(logsToInsert, true, AccessLevel.SYSTEM_MODE);
  }

  // Mutable accumulator threaded through the reclaim phase helpers so each
  // helper stays within the parameter and complexity budgets.
  private class ReclaimState {
    Set<Id> instanceIds = new Set<Id>();
    Set<String> allTargetStepNames = new Set<String>();
    Map<Id, List<String>> targetStepsByInstanceId = new Map<Id, List<String>>();
    Map<Id, Boolean> hasCompensationsByInstanceId = new Map<Id, Boolean>();
    Map<String, Workflow_Step_Execution__c> latestStepByName = new Map<String, Workflow_Step_Execution__c>();
    Set<Id> failedInstanceIds = new Set<Id>();
    Set<Id> succeededInstanceIds = new Set<Id>();
  }

  private static void reclaimOrphanedInstances(
    List<Workflow_Instance__c> orphanedInstances
  ) {
    ReclaimState state = new ReclaimState();
    buildReclaimPlan(orphanedInstances, state);
    lockLatestReclaimSteps(state);
    Map<Id, Workflow_Step_Execution__c> stepsToResetMap = collectReclaimStepsToReset(
      orphanedInstances,
      state
    );
    resetReclaimSteps(stepsToResetMap, state);
    clearReclaimAsyncJobIds(orphanedInstances, state);
    writeReclaimAuditLogs(orphanedInstances, state);
    enqueueReclaimOrchestrators(orphanedInstances, state);
  }

  // Derive, per orphaned instance, the target step names to reset and whether
  // the instance carries pending compensations, populating the shared state.
  private static void buildReclaimPlan(
    List<Workflow_Instance__c> orphanedInstances,
    ReclaimState state
  ) {
    Map<String, String> initialStepByWorkflowName = new Map<String, String>();
    for (Workflow_Instance__c inst : orphanedInstances) {
      planReclaimForInstance(inst, state, initialStepByWorkflowName);
    }
  }

  // Compute the target steps / compensation flag for a single orphaned instance.
  private static void planReclaimForInstance(
    Workflow_Instance__c inst,
    ReclaimState state,
    Map<String, String> initialStepByWorkflowName
  ) {
    state.instanceIds.add(inst.Id);
    Boolean isCompensatingOrCancelling = (inst.Status__c == 'Compensating' ||
    inst.Status__c == 'Cancelling');
    List<String> stack = new List<String>();
    if (
      isCompensatingOrCancelling &&
      String.isNotBlank(inst.Compensation_Stack__c)
    ) {
      stack = parseReclaimCompensationStack(inst);
    }
    Boolean hasCompensations = (stack != null && !stack.isEmpty());
    state.hasCompensationsByInstanceId.put(inst.Id, hasCompensations);

    List<String> targetStepNames = computeReclaimTargetSteps(
      inst,
      stack,
      hasCompensations
    );

    if (String.isBlank(inst.Current_Step__c) && !hasCompensations) {
      String initialStep = resolveReclaimInitialStep(
        inst.Workflow_Name__c,
        initialStepByWorkflowName
      );
      if (initialStep != null) {
        inst.Current_Step__c = initialStep;
        targetStepNames.add(initialStep);
      }
    }

    state.targetStepsByInstanceId.put(inst.Id, targetStepNames);
    state.allTargetStepNames.addAll(targetStepNames);
  }

  // Derive the target step names for reclaim from the instance status, its
  // compensation stack, and any comma-separated parallel current steps.
  private static List<String> computeReclaimTargetSteps(
    Workflow_Instance__c inst,
    List<String> stack,
    Boolean hasCompensations
  ) {
    Boolean isCompensatingOrCancelling = (inst.Status__c == 'Compensating' ||
    inst.Status__c == 'Cancelling');
    List<String> targetStepNames = new List<String>();
    if (isCompensatingOrCancelling && hasCompensations) {
      targetStepNames.add(stack[stack.size() - 1] + '_Compensate');
    } else if (String.isNotBlank(inst.Current_Step__c)) {
      if (inst.Current_Step__c.contains(',')) {
        for (String pStep : inst.Current_Step__c.split(',')) {
          targetStepNames.add(pStep.trim());
        }
      } else {
        targetStepNames.add(inst.Current_Step__c);
      }
    }
    return targetStepNames;
  }

  // Deserialize the compensation stack; malformed JSON yields an empty stack.
  private static List<String> parseReclaimCompensationStack(
    Workflow_Instance__c inst
  ) {
    try {
      return (List<String>) JSON.deserialize(
        inst.Compensation_Stack__c,
        List<String>.class
      );
    } catch (Exception ignored) {
      // Malformed Compensation_Stack__c; treat as having no compensations.
      return new List<String>();
    }
  }

  // Resolve (and memoize) a workflow's initial step name for reclaim routing.
  private static String resolveReclaimInitialStep(
    String wflowName,
    Map<String, String> initialStepByWorkflowName
  ) {
    if (initialStepByWorkflowName.containsKey(wflowName)) {
      return initialStepByWorkflowName.get(wflowName);
    }
    String initialStep = null;
    Type wflowType = WorkflowTypeResolver.resolve(
      wflowName,
      WorkflowTypeResolver.extractNamespace(wflowName)
    );
    if (wflowType != null) {
      try {
        Object defObj = wflowType.newInstance();
        if (defObj instanceof WorkflowDefinition) {
          initialStep = ((WorkflowDefinition) defObj).getInitialStep();
        }
      } catch (Exception ignored) {
        // Workflow type not instantiable here; leave initialStep null.
      }
    }
    initialStepByWorkflowName.put(wflowName, initialStep);
    return initialStep;
  }

  // Query the latest step executions for the target steps and lock them
  // FOR UPDATE, storing the resolved map on the shared state.
  private static void lockLatestReclaimSteps(ReclaimState state) {
    if (state.allTargetStepNames.isEmpty()) {
      return;
    }
    Set<Id> instanceIds = state.instanceIds;
    Set<String> allTargetStepNames = state.allTargetStepNames;
    // Query step executions to reset: first identify latest step execution IDs
    for (Workflow_Step_Execution__c se : [
      SELECT
        Id,
        Workflow_Instance__c,
        Step_Name__c,
        Status__c,
        Retry_Count__c,
        Error_Details__c,
        Timeout_At__c,
        CPU_Time_Ms__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instanceIds
        AND Step_Name__c IN :allTargetStepNames
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      String key = se.Workflow_Instance__c + ':' + se.Step_Name__c;
      if (!state.latestStepByName.containsKey(key)) {
        state.latestStepByName.put(key, se);
      }
    }

    // Then lock those specific records using FOR UPDATE
    Set<Id> stepIdsToLock = new Set<Id>();
    for (Workflow_Step_Execution__c se : state.latestStepByName.values()) {
      stepIdsToLock.add(se.Id);
    }
    if (!stepIdsToLock.isEmpty()) {
      for (Workflow_Step_Execution__c se : [
        SELECT
          Id,
          Workflow_Instance__c,
          Step_Name__c,
          Status__c,
          Retry_Count__c,
          Error_Details__c,
          Timeout_At__c,
          CPU_Time_Ms__c
        FROM Workflow_Step_Execution__c
        WHERE Id IN :stepIdsToLock
        WITH SYSTEM_MODE
        FOR UPDATE
      ]) {
        String key = se.Workflow_Instance__c + ':' + se.Step_Name__c;
        state.latestStepByName.put(key, se);
      }
    }
  }

  // Build the map of step executions whose status must be reset to Pending.
  private static Map<Id, Workflow_Step_Execution__c> collectReclaimStepsToReset(
    List<Workflow_Instance__c> orphanedInstances,
    ReclaimState state
  ) {
    Map<Id, Workflow_Step_Execution__c> stepsToResetMap = new Map<Id, Workflow_Step_Execution__c>();
    for (Workflow_Instance__c inst : orphanedInstances) {
      List<String> targetStepNames = state.targetStepsByInstanceId.get(inst.Id);
      for (String targetStepName : targetStepNames) {
        String key = inst.Id + ':' + targetStepName;
        Workflow_Step_Execution__c stepExec = state.latestStepByName.get(key);
        if (
          stepExec != null &&
          stepExec.Status__c != 'Completed' &&
          stepExec.Status__c != 'OperatorSkipped'
        ) {
          stepExec.Status__c = 'Pending';
          stepExec.Retry_Count__c = 0;
          stepExec.Error_Details__c = null;
          stepExec.Timeout_At__c = null;
          stepExec.CPU_Time_Ms__c = null;
          stepsToResetMap.put(stepExec.Id, stepExec);
        }
      }
    }
    return stepsToResetMap;
  }

  // Persist the step-execution resets, recording instances whose reset failed.
  private static void resetReclaimSteps(
    Map<Id, Workflow_Step_Execution__c> stepsToResetMap,
    ReclaimState state
  ) {
    if (stepsToResetMap.isEmpty()) {
      return;
    }
    List<Workflow_Step_Execution__c> stepsList = stepsToResetMap.values();
    Database.SaveResult[] stepSRs = Database.update(
      stepsList,
      false,
      AccessLevel.SYSTEM_MODE
    );
    for (Integer i = 0; i < stepSRs.size(); i++) {
      if (!stepSRs[i].isSuccess()) {
        state.failedInstanceIds.add(stepsList[i].Workflow_Instance__c);
      }
    }
  }

  // Clear the async job id on reclaimable instances, tracking which persisted.
  private static void clearReclaimAsyncJobIds(
    List<Workflow_Instance__c> orphanedInstances,
    ReclaimState state
  ) {
    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c inst : orphanedInstances) {
      if (!state.failedInstanceIds.contains(inst.Id)) {
        inst.Async_Job_Id__c = null;
        instancesToUpdate.add(inst);
      }
    }
    if (instancesToUpdate.isEmpty()) {
      return;
    }
    Database.SaveResult[] instSRs = Database.update(
      instancesToUpdate,
      false,
      AccessLevel.SYSTEM_MODE
    );
    for (Integer i = 0; i < instSRs.size(); i++) {
      if (instSRs[i].isSuccess()) {
        state.succeededInstanceIds.add(instancesToUpdate[i].Id);
      }
    }
  }

  // Emit operator-intervention audit logs for successfully reclaimed instances.
  private static void writeReclaimAuditLogs(
    List<Workflow_Instance__c> orphanedInstances,
    ReclaimState state
  ) {
    List<Workflow_Log__c> auditLogs = new List<Workflow_Log__c>();
    for (Workflow_Instance__c inst : orphanedInstances) {
      if (!state.succeededInstanceIds.contains(inst.Id)) {
        continue;
      }
      String stepDetail = String.isNotBlank(inst.Current_Step__c)
        ? inst.Current_Step__c
        : '(initial step)';
      auditLogs.add(
        new Workflow_Log__c(
          Workflow_Instance__c = inst.Id,
          Workflow_Name__c = inst.Workflow_Name__c,
          Correlation_Key__c = inst.Correlation_Key__c,
          Log_Type__c = 'OperatorIntervention',
          Message__c = 'Auto-reclaimed orphaned instance from step: ' +
            stepDetail,
          Outcome__c = 'Success',
          Level__c = 'INFO',
          Fire_Time__c = DateTime.now()
        )
      );
    }
    if (!auditLogs.isEmpty()) {
      Database.insert(auditLogs, false, AccessLevel.SYSTEM_MODE);
    }
  }

  // Re-enqueue orchestrators for reclaimed instances in a bulk fashion.
  private static void enqueueReclaimOrchestrators(
    List<Workflow_Instance__c> orphanedInstances,
    ReclaimState state
  ) {
    List<OrchestratorRequest> requests = new List<OrchestratorRequest>();
    for (Workflow_Instance__c inst : orphanedInstances) {
      if (!state.succeededInstanceIds.contains(inst.Id)) {
        continue;
      }
      requests.addAll(buildReclaimOrchestratorRequests(inst, state));
    }

    if (!requests.isEmpty()) {
      try {
        enqueueOrchestrators(requests);
      } catch (Exception ignored) {
        // Best-effort re-enqueue; the next watchdog heartbeat re-drives on failure.
      }
    }
  }

  // Build the orchestrator re-drive requests for a single reclaimed instance.
  private static List<OrchestratorRequest> buildReclaimOrchestratorRequests(
    Workflow_Instance__c inst,
    ReclaimState state
  ) {
    List<OrchestratorRequest> requests = new List<OrchestratorRequest>();
    List<String> targetStepNames = state.targetStepsByInstanceId.get(inst.Id);
    Boolean hasCompensations = state.hasCompensationsByInstanceId.get(inst.Id);

    if (
      hasCompensations ||
      String.isBlank(inst.Current_Step__c) ||
      !inst.Current_Step__c.contains(',')
    ) {
      requests.add(new OrchestratorRequest(inst.Id, null));
    } else {
      for (String targetStepName : targetStepNames) {
        String key = inst.Id + ':' + targetStepName;
        Workflow_Step_Execution__c stepExec = state.latestStepByName.get(key);
        if (
          stepExec == null ||
          (stepExec.Status__c != 'Completed' &&
          stepExec.Status__c != 'OperatorSkipped')
        ) {
          requests.add(new OrchestratorRequest(inst.Id, targetStepName));
        }
      }
    }
    return requests;
  }
}
