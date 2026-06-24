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
  private static Integer DEDUP_LOOKUP_ROW_CAP = 10000;

  // Search Attributes configuration limits
  public static final Integer MAX_ATTRIBUTES_PER_INSTANCE = 10;
  public static final Integer MAX_ATTRIBUTE_KEY_LENGTH = 100;
  public static final Integer MAX_ATTRIBUTE_VALUE_LENGTH = 150;

  // Max number of timed-out steps a single watchdog heartbeat will fail. Each failure
  // triggers failWorkflowInstance() (its own SOQL/DML + optional alert queries), so this
  // bounds the heartbeat's governor usage. Remaining timeouts drain on the next heartbeat.
  @TestVisible
  private static Integer WATCHDOG_TIMEOUT_BATCH_SIZE = 50;
  // Max number of sleeping instances a single heartbeat resumes, for the same reason.
  @TestVisible
  private static Integer WATCHDOG_RESUME_BATCH_SIZE = 200;
  // Max number of expired instances a single heartbeat fails/compensates, for the same reason.
  @TestVisible
  private static Integer WATCHDOG_DEADLINE_BATCH_SIZE = 100;

  static {
    try {
      List<Revenant_Config__mdt> configs = [
        SELECT
          Watchdog_Delay_Minutes__c,
          Use_Dynamic_Scheduling__c,
          Publish_Lifecycle_Events__c,
          Dedup_Window_Minutes__c,
          Stale_Threshold_Minutes__c
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
      }
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.WARN,
        'Revenant configuration metadata query failed: ' + ex.getMessage()
      );
    }
  }

  @TestVisible
  private static Set<Id> enqueuedInstanceIds = new Set<Id>();
  // Per-(instance, branch) enqueue dedup so resuming a parallel instance can
  // wake each branch by name without the instance-level dedup blocking siblings.
  @TestVisible
  private static Set<String> enqueuedBranchKeys = new Set<String>();
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

    public StartResult(Id instanceId, Boolean isNew) {
      this.instanceId = instanceId;
      this.isNew = isNew;
    }
  }

  // ─── Read API ──────────────────────────────────────────────────────────────
  //
  // Terminal statuses for the read API. ContinuedAsNew is deliberately excluded
  // (it is a hand-off, not an outcome) and CompensationFailed is excluded
  // (it is non-terminal — the rollback can still be resumed/retried).
  private static final Set<String> TERMINAL_GETSTATUS_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled'
  };

  /**
   * Stable read-only DTO returned by WorkflowEngine.getStatus. All fields are
   * read-only to callers; the engine populates them via the private constructor.
   */
  public class WorkflowStatus {
    public Id instanceId { get; private set; }
    public String definitionName { get; private set; }
    public String correlationKey { get; private set; }
    public String status { get; private set; }
    public Boolean isTerminal { get; private set; }
    public String errorMessage { get; private set; }
    // Fully rehydrated output for terminal instances; null for in-flight instances.
    public String output { get; private set; }

    private WorkflowStatus(
      Id instanceId,
      String definitionName,
      String correlationKey,
      String status,
      Boolean isTerminal,
      String errorMessage,
      String output
    ) {
      this.instanceId = instanceId;
      this.definitionName = definitionName;
      this.correlationKey = correlationKey;
      this.status = status;
      this.isTerminal = isTerminal;
      this.errorMessage = errorMessage;
      this.output = output;
    }
  }

  /**
   * Returns the current status and rehydrated output for a workflow instance by Id,
   * or null if no instance with that Id exists.
   * Costs at most 2 SOQL queries and zero DML.
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
        Output__c
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
   */
  public static List<WorkflowStatus> getStatus(List<String> correlationKeys) {
    List<WorkflowStatus> out = new List<WorkflowStatus>();
    if (correlationKeys == null || correlationKeys.isEmpty()) {
      return out;
    }

    // Correlation key fields are case-insensitive in SOQL but Apex Set/Map lookups
    // are case-sensitive, so all bucketing is done on the normalized (lower-cased)
    // key to keep in-memory matching consistent with what the query returns.
    Set<String> normalizedKeys = new Set<String>();
    for (String k : correlationKeys) {
      if (String.isNotBlank(k)) {
        normalizedKeys.add(normalizeKey(k));
      }
    }

    // Resolve the winning instance Id per requested key using metadata only (no
    // Output__c), so a hot key's many candidate rows can never load enough inline
    // payloads to exhaust the heap. Resolution is per-key bounded (no single key can
    // crowd out others) and follows ContinuedAsNew chains via the shared root key.
    Map<String, Id> winnerIdByKey = resolveWinnerIdByKey(normalizedKeys);

    // Fetch Output__c (and the remaining DTO fields) only for the winners, then
    // rehydrate any offloaded outputs in one ContentVersion query — the same bounded
    // tail used by the Id-based overload.
    Set<Id> winnerIds = new Set<Id>(winnerIdByKey.values());
    Map<Id, Workflow_Instance__c> instById = new Map<Id, Workflow_Instance__c>();
    if (!winnerIds.isEmpty()) {
      for (Workflow_Instance__c inst : [
        SELECT
          Id,
          Workflow_Name__c,
          Correlation_Key__c,
          Status__c,
          Error_Message__c,
          Output__c
        FROM Workflow_Instance__c
        WHERE Id IN :winnerIds
        WITH SYSTEM_MODE
      ]) {
        instById.put(inst.Id, inst);
      }
    }

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
        LIMIT :DEDUP_LOOKUP_ROW_CAP
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
          LIMIT :DEDUP_LOOKUP_ROW_CAP
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

    // 1b) Keys with no active run → most-recent row by correlation key (any status,
    //     so a ContinuedAsNew hand-off is detected for the chain expansion below). An
    //     aggregate yields one MAX(CreatedDate) per key (a hot key collapses to a
    //     single group), then a bounded fetch resolves the Id(s) at those timestamps.
    Set<String> remaining = unresolved(keys, bestByKey);
    if (!remaining.isEmpty()) {
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
      if (!maxTimes.isEmpty()) {
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
          LIMIT :DEDUP_LOOKUP_ROW_CAP
        ]) {
          if (
            inst.CreatedDate ==
            maxByKey.get(normalizeKey(inst.Correlation_Key__c))
          ) {
            bucketByOwnKey(inst, keys, bestByKey);
          }
        }
      }
    }

    // 2) For keys whose direct winner is a ContinuedAsNew hand-off, the chain has
    //    moved on — follow it to the live/final successor via the shared root key.
    //    (Phase 1 matched on the key itself, not on root, so the successors — which
    //    carry a different correlation key — were not seen yet, even when the polled
    //    key is the chain root.)
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
    if (!expandRoots.isEmpty()) {
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

    Map<String, Id> winnerByKey = new Map<String, Id>();
    for (String reqKey : bestByKey.keySet()) {
      winnerByKey.put(reqKey, bestByKey.get(reqKey).Id);
    }
    return winnerByKey;
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
   */
  private static Map<String, Workflow_Instance__c> resolveWinnersByRoot(
    Set<String> roots
  ) {
    Map<String, Workflow_Instance__c> winnerByRoot = new Map<String, Workflow_Instance__c>();

    // Active runs — bounded to ~one per chain by the unique active-key index.
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

    // Roots with no active run → most-recent non-hand-off terminal generation.
    Set<String> remainingRoots = unresolved(roots, winnerByRoot);
    if (!remainingRoots.isEmpty()) {
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
      if (!maxTimes.isEmpty()) {
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
          LIMIT :DEDUP_LOOKUP_ROW_CAP
        ]) {
          String r = normalizeKey(inst.Root_Correlation_Key__c);
          if (inst.CreatedDate == maxByRoot.get(r)) {
            putBestByRoot(winnerByRoot, r, inst);
          }
        }
      }
    }

    // Fallback for an all-hand-off chain: keep the most-recent matched row so the
    // caller still sees the latest generation rather than null.
    Set<String> stuckRoots = unresolved(roots, winnerByRoot);
    if (!stuckRoots.isEmpty()) {
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
        LIMIT :DEDUP_LOOKUP_ROW_CAP
      ]) {
        putBestByRoot(
          winnerByRoot,
          normalizeKey(inst.Root_Correlation_Key__c),
          inst
        );
      }
    }
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
    return new WorkflowStatus(
      inst.Id,
      inst.Workflow_Name__c,
      inst.Correlation_Key__c,
      inst.Status__c,
      terminal,
      inst.Error_Message__c,
      output
    );
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
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.FINE,
          'getStatus: offload marker parse fallback: ' + ex.getMessage()
        );
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
   * Starts a new durable workflow instance (get-or-start). If an instance with
   * the same correlation key already exists within the dedup scope, returns
   * that instance's Id instead of inserting a duplicate.
   */
  public static Id start(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    return doStart(workflowName, correlationKey, input, null, null).instanceId;
  }

  public static Id start(
    String workflowName,
    String correlationKey,
    Object input,
    Map<String, String> attributes
  ) {
    return doStart(workflowName, correlationKey, input, null, attributes).instanceId;
  }

  /**
   * Starts a new durable workflow instance with a parent workflow reference
   * (get-or-start).
   */
  public static Id start(
    String workflowName,
    String correlationKey,
    Object input,
    Id parentInstanceId
  ) {
    return doStart(workflowName, correlationKey, input, parentInstanceId, null)
      .instanceId;
  }

  public static Id start(
    String workflowName,
    String correlationKey,
    Object input,
    Id parentInstanceId,
    Map<String, String> attributes
  ) {
    return doStart(workflowName, correlationKey, input, parentInstanceId, attributes)
      .instanceId;
  }

  /**
   * Get-or-start variant that exposes whether a new instance was created or an
   * existing one was returned.
   */
  public static StartResult startOrGet(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    return doStart(workflowName, correlationKey, input, null, null);
  }

  public static StartResult startOrGet(
    String workflowName,
    String correlationKey,
    Object input,
    Map<String, String> attributes
  ) {
    return doStart(workflowName, correlationKey, input, null, attributes);
  }

  public static StartResult startOrGet(
    String workflowName,
    String correlationKey,
    Object input,
    Id parentInstanceId
  ) {
    return doStart(workflowName, correlationKey, input, parentInstanceId, true, null);
  }

  public static StartResult startOrGet(
    String workflowName,
    String correlationKey,
    Object input,
    Id parentInstanceId,
    Map<String, String> attributes
  ) {
    return doStart(workflowName, correlationKey, input, parentInstanceId, true, attributes);
  }

  /**
   * Active-only get-or-start for engine-internal singleton workflows (e.g. the
   * watchdog). Never dedups against terminal instances, so a failed or
   * continued-as-new singleton is always restarted rather than resolving to a
   * dead terminal run within the dedup window.
   */
  public static Id startSingleton(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    return doStart(workflowName, correlationKey, input, null, false, null).instanceId;
  }

  private static void validateAttributes(Map<String, String> attributes) {
    if (attributes == null || attributes.isEmpty()) {
      return;
    }
    if (attributes.size() > MAX_ATTRIBUTES_PER_INSTANCE) {
      throw new WorkflowException('Attribute count exceeds maximum limit of ' + MAX_ATTRIBUTES_PER_INSTANCE);
    }
    for (String key : attributes.keySet()) {
      if (String.isBlank(key)) {
        throw new WorkflowException('Attribute key cannot be blank');
      }
      if (key.length() > MAX_ATTRIBUTE_KEY_LENGTH) {
        throw new WorkflowException('Attribute key length exceeds maximum limit of ' + MAX_ATTRIBUTE_KEY_LENGTH + ' characters: ' + key);
      }
      String val = attributes.get(key);
      if (val != null && val.length() > MAX_ATTRIBUTE_VALUE_LENGTH) {
        throw new WorkflowException('Attribute value length exceeds maximum limit of ' + MAX_ATTRIBUTE_VALUE_LENGTH + ' characters: ' + val);
      }
    }
  }

  private static List<Workflow_Search_Attribute__c> buildAttributes(Id instanceId, Map<String, String> attributes) {
    List<Workflow_Search_Attribute__c> records = new List<Workflow_Search_Attribute__c>();
    if (attributes == null || attributes.isEmpty()) {
      return records;
    }
    for (String key : attributes.keySet()) {
      String val = attributes.get(key);
      records.add(new Workflow_Search_Attribute__c(
        Workflow_Instance__c = instanceId,
        Key__c = key,
        Value__c = val,
        Key_Value__c = key + '=' + (val == null ? '' : val)
      ));
    }
    return records;
  }

  private static StartResult doStart(
    String workflowName,
    String correlationKey,
    Object input,
    Id parentInstanceId,
    Map<String, String> attributes
  ) {
    return doStart(workflowName, correlationKey, input, parentInstanceId, true, attributes);
  }

  private static StartResult doStart(
    String workflowName,
    String correlationKey,
    Object input,
    Id parentInstanceId,
    Boolean includeTerminal,
    Map<String, String> attributes
  ) {
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
      Workflow_Instance__c match = findExistingByKey(
          new Set<String>{ correlationKey },
          includeTerminal
        )
        .get(normalizeKey(correlationKey));
      if (match != null) {
        return new StartResult(match.Id, false);
      }
    }

    Workflow_Instance__c instance = buildInstance(
      new StartRequest(workflowName, correlationKey, input, parentInstanceId)
    );

    try {
      insert as system instance;
      List<Workflow_Search_Attribute__c> attrsToInsert = buildAttributes(instance.Id, attributes);
      if (!attrsToInsert.isEmpty()) {
        insert as system attrsToInsert;
      }
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        // Concurrency backstop: a sibling start won the race on the unique
        // Active_Correlation_Key__c index. A sibling provably exists, so resolve
        // the winner regardless of the dedup window (it may have completed
        // mid-race) and return its Id so the loser is a safe no-op.
        Workflow_Instance__c winner = findAnyByKey(
            new Set<String>{ correlationKey }
          )
          .get(normalizeKey(correlationKey));
        if (winner != null) {
          return new StartResult(winner.Id, false);
        }
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' +
          correlationKey
        );
      }
      throw ex;
    }

    instance.Input__c = savePayloadIfNeeded(
      instance.Id,
      (input != null) ? JSON.serialize(input) : null,
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
    update as system instance;

    if (String.isNotBlank(instance.Current_Step__c)) {
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
        Integer timeout = getStepTimeoutSeconds(instance.Current_Step__c);
        if (timeout != null && timeout > 0) {
          stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
        }
      }
      insert as system stepExec;
    }

    // Park at start if the definition is currently paused. The initial Pending
    // Workflow_Step_Execution__c (inserted above, with no timeout clock) gives the
    // resume path a concrete step to drive. Skip timeout scheduling and the first
    // enqueue; the watchdog re-drives held work on resume.
    if (parkAtStart) {
      instance.Status__c = 'Paused';
      update as system instance;
      return new StartResult(instance.Id, true);
    }

    // Schedule watchdog for the initial step before executing it — unless this is a
    // bounded workflow, where the admission gate arms the timeout once a slot is won.
    if (!deferTimeoutForConcurrency) {
      scheduleTimeoutJobForInstance(instance.Id);
    }

    // Enqueue the first step execution
    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(instance.Id));
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
    return new StartResult(instance.Id, true);
  }

  /**
   * Builds an unsaved Workflow_Instance__c for a start request, resolving the
   * definition version and initial step.
   */
  private static Workflow_Instance__c buildInstance(StartRequest req) {
    Workflow_Instance__c instance = new Workflow_Instance__c();
    instance.Workflow_Name__c = req.workflowName;
    instance.Status__c = 'Pending';
    instance.Correlation_Key__c = req.correlationKey;
    instance.Parent_Instance__c = req.parentInstanceId;

    if (String.isNotBlank(req.workflowName)) {
      List<ApexTypeImplementor> impls = [
        SELECT ClassName
        FROM ApexTypeImplementor
        WHERE ClassName = :req.workflowName
          AND InterfaceName IN ('WorkflowDefinition', 'VersionedWorkflow')
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (impls.isEmpty()) {
        throw new WorkflowException('Unauthorized or invalid workflow definition: ' + req.workflowName);
      }
    }

    Type wflowType = Type.forName(req.workflowName);
    if (wflowType != null) {
      Object defObj = wflowType.newInstance();
      if (defObj instanceof VersionedWorkflow) {
        instance.Definition_Version__c = ((VersionedWorkflow) defObj)
          .getLatestVersion();
      } else {
        instance.Definition_Version__c = 1;
      }
      if (defObj instanceof WorkflowDefinition) {
        instance.Current_Step__c = ((WorkflowDefinition) defObj)
          .getInitialStep();
      }
      if (defObj instanceof ExecutionTimeoutConfigurable) {
        Integer timeoutSecs = ((ExecutionTimeoutConfigurable) defObj)
          .getExecutionTimeoutSeconds();
        if (timeoutSecs != null) {
          instance.Deadline_At__c = DateTime.now().addSeconds(timeoutSecs);
        }
      }
    } else {
      instance.Definition_Version__c = 1;
    }
    return instance;
  }

  /**
   * Canonical form of a correlation key for in-memory dedup maps/sets.
   * Correlation_Key__c is case-insensitive (and the unique
   * Active_Correlation_Key__c index is too), but Apex Map/Set keys are
   * case-sensitive, so keys are lower-cased to match the database semantics.
   */
  private static String normalizeKey(String key) {
    return key == null ? null : key.toLowerCase();
  }

  /**
   * The set of statuses for which an inbound signal can still wake an instance:
   * a forward signal resumes Suspended/Running, and a compensation step may
   * await a signal while Compensating/Cancelling. Terminal statuses are not
   * signalable.
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
   * Removes the given instances (and their parallel branch keys) from the static
   * enqueue guards. Called after a wake-up failure is rolled back so a caller
   * that catches the exception and retries in the same transaction can re-enqueue
   * the resume — otherwise the guard would suppress the retry's wake and leave
   * the workflow unwoken despite the re-inserted signal.
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
      insert as system marker;
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
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'Failed to parse cancel payload, using default runCompensations: ' +
        e.getMessage()
      );
    }
    return true;
  }

  /**
   * Wakes an instance after a routed signal lands. A Suspended instance flips to
   * Running; a Running/Compensating/Cancelling instance is re-driven in place (a
   * compensation step can depend on inbound signals, so it is woken rather than
   * rejected). A Paused instance keeps its status — the held signal is observed
   * when resume re-drives the wait step.
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
        update as system instance;
      }
      enqueueResume(instance.Id);
    }
  }

  /**
   * Resolves the dedup-winner instance for each correlation key: an active
   * instance if one exists, otherwise (when includeTerminal is true) the most
   * recent terminal instance that became terminal within the configured dedup
   * window. The returned map is keyed by the normalized correlation key.
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

    // Fast path: a single key needs only the single most-relevant row (an active
    // instance preferred via NULLS FIRST, else the newest in-window terminal).
    // One indexed SOQL with LIMIT 1 keeps the common start path to a single
    // query and bounds the row governor regardless of how many historical
    // terminal runs the key has. SOQL equality is case-insensitive, so a stored
    // "Foo" matches a requested "foo".
    if (keys.size() == 1) {
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

    // 2) Most-recent terminal per key not already resolved to an active
    //    instance. An aggregate yields one MAX(Terminal_At__c) per key (each
    //    grouped result counts as a single row toward the SOQL row limit, so a
    //    hot key cannot exhaust it), then a bounded fetch resolves the Id at
    //    those timestamps. Because the unique active-key index forces terminal
    //    runs of one key to occur serially, their Terminal_At__c values are
    //    distinct, so the fetch matches ~one row per key.
    Set<String> remaining = new Set<String>();
    for (String k : keys) {
      if (!result.containsKey(normalizeKey(k))) {
        remaining.add(k);
      }
    }
    if (remaining.isEmpty()) {
      return result;
    }

    DateTime windowStart = dedupWindowStart();
    Map<String, Datetime> maxTimeByKey = new Map<String, Datetime>();
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
    if (maxTimes.isEmpty()) {
      return result;
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
   */
  private static Map<String, Workflow_Instance__c> findAnyByKey(
    Set<String> keys
  ) {
    Map<String, Workflow_Instance__c> result = new Map<String, Workflow_Instance__c>();
    if (keys == null || keys.isEmpty()) {
      return result;
    }
    Integer rowLimit = keys.size() == 1 ? 1 : DEDUP_LOOKUP_ROW_CAP;
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
   */
  private static DateTime dedupWindowStart() {
    if (dedupWindowMinutes != null && dedupWindowMinutes > 0) {
      Integer minutes = Math.min(dedupWindowMinutes, MAX_DEDUP_WINDOW_MINUTES);
      return DateTime.now().addMinutes(-minutes);
    }
    return DateTime.now().addYears(1000);
  }

  public class StartRequest {
    public String workflowName;
    public String correlationKey;
    public Object input;
    public Id parentInstanceId;
    public Map<String, String> attributes;

    public StartRequest(
      String workflowName,
      String correlationKey,
      Object input
    ) {
      this.workflowName = workflowName;
      this.correlationKey = correlationKey;
      this.input = input;
    }

    public StartRequest(
      String workflowName,
      String correlationKey,
      Object input,
      Map<String, String> attributes
    ) {
      this.workflowName = workflowName;
      this.correlationKey = correlationKey;
      this.input = input;
      this.attributes = attributes;
    }

    public StartRequest(
      String workflowName,
      String correlationKey,
      Object input,
      Id parentInstanceId
    ) {
      this.workflowName = workflowName;
      this.correlationKey = correlationKey;
      this.input = input;
      this.parentInstanceId = parentInstanceId;
    }

    public StartRequest(
      String workflowName,
      String correlationKey,
      Object input,
      Id parentInstanceId,
      Map<String, String> attributes
    ) {
      this.workflowName = workflowName;
      this.correlationKey = correlationKey;
      this.input = input;
      this.parentInstanceId = parentInstanceId;
      this.attributes = attributes;
    }
  }

  public class ResumeRequest {
    public String correlationKey;
    public Id instanceId;
    public String payload;

    public ResumeRequest(String correlationKey, String payload) {
      this.correlationKey = correlationKey;
      this.payload = payload;
    }

    public ResumeRequest(Id instanceId, String payload) {
      this.instanceId = instanceId;
      this.payload = payload;
    }
  }

  public class SignalRequest {
    public String keyOrId;
    public String signalName;
    public String payload;
    public String dedupKey;
    public String idempotencyKey;

    public SignalRequest(String keyOrId, String signalName, String payload) {
      this.keyOrId = keyOrId;
      this.signalName = signalName;
      this.payload = payload;
    }

    public SignalRequest(
      String keyOrId,
      String signalName,
      String payload,
      String dedupKey
    ) {
      this.keyOrId = keyOrId;
      this.signalName = signalName;
      this.payload = payload;
      this.dedupKey = dedupKey;
    }

    public SignalRequest(
      String keyOrId,
      String signalName,
      String payload,
      String dedupKey,
      String idempotencyKey
    ) {
      this.keyOrId = keyOrId;
      this.signalName = signalName;
      this.payload = payload;
      this.dedupKey = dedupKey;
      this.idempotencyKey = idempotencyKey;
    }
  }

  /**
   * Starts multiple durable workflow instances in a bulk-friendly transaction
   * (get-or-start). A duplicate correlation key resolves to the existing
   * instance and never faults sibling requests in the same invocation.
   */
  public static List<Id> start(List<StartRequest> requests) {
    List<Id> ids = new List<Id>();
    for (StartResult r : startOrGet(requests)) {
      ids.add(r == null ? null : r.instanceId);
    }
    return ids;
  }

  /**
   * Bulk get-or-start. Returns a result per request (index-aligned) reporting
   * the resolved instance Id and whether it was newly created or deduped.
   */
  public static List<StartResult> startOrGet(List<StartRequest> requests) {
    List<StartResult> results = new List<StartResult>();
    if (requests == null || requests.isEmpty()) {
      return results;
    }

    // 1. Validate and gather correlation keys
    Set<String> correlationKeys = new Set<String>();
    for (StartRequest req : requests) {
      validateCorrelationKey(req.correlationKey);
      validateAttributes(req.attributes);
      if (String.isNotBlank(req.correlationKey)) {
        correlationKeys.add(req.correlationKey);
      }
    }

    // 2. Pre-resolve existing instances within the dedup scope (keyed by the
    //    normalized correlation key to honor case-insensitive matching).
    Map<String, Workflow_Instance__c> existingByKey = findExistingByKey(
      correlationKeys,
      true
    );

    // 3. Decide per request (preserving order): dedup to an existing instance,
    //    dedup to an intra-batch sibling, or build a fresh instance to insert.
    for (Integer i = 0; i < requests.size(); i++) {
      results.add(null);
    }
    List<Workflow_Instance__c> toInsert = new List<Workflow_Instance__c>();
    List<Integer> insertReqIndexes = new List<Integer>();
    Set<String> newKeysInBatch = new Set<String>();

    for (Integer i = 0; i < requests.size(); i++) {
      StartRequest req = requests[i];
      String key = req.correlationKey;
      String normKey = normalizeKey(key);

      if (String.isNotBlank(key) && existingByKey.containsKey(normKey)) {
        results[i] = new StartResult(existingByKey.get(normKey).Id, false);
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

    // 4. Insert fresh instances, tolerating per-row DUPLICATE_VALUE from a
    //    concurrent winner (the unique Active_Correlation_Key__c backstop).
    List<Workflow_Instance__c> insertedInstances = new List<Workflow_Instance__c>();
    List<Integer> insertedReqIndexes = new List<Integer>();
    Set<String> concurrentLoserKeys = new Set<String>();

    if (!toInsert.isEmpty()) {
      Database.SaveResult[] saveResults = Database.insert(
        toInsert,
        false,
        AccessLevel.SYSTEM_MODE
      );
      String genuineError = null;
      for (Integer j = 0; j < saveResults.size(); j++) {
        Database.SaveResult sr = saveResults[j];
        Integer reqIdx = insertReqIndexes[j];
        if (sr.isSuccess()) {
          Workflow_Instance__c inst = toInsert[j];
          insertedInstances.add(inst);
          insertedReqIndexes.add(reqIdx);
          results[reqIdx] = new StartResult(inst.Id, true);
        } else {
          Boolean isDup = false;
          for (Database.Error err : sr.getErrors()) {
            if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
              isDup = true;
              break;
            }
          }
          String key = requests[reqIdx].correlationKey;
          if (isDup && String.isNotBlank(key)) {
            concurrentLoserKeys.add(key);
          } else if (genuineError == null) {
            genuineError = sr.getErrors()[0].getMessage();
          }
        }
      }
      // A genuine (non-duplicate) row failure restores all-or-none semantics:
      // delete every sibling row that succeeded in this partial insert (no
      // savepoint is spent on the all-success path) and surface the error so no
      // orphan Pending instances are left behind.
      if (genuineError != null) {
        if (!insertedInstances.isEmpty()) {
          delete as system insertedInstances;
        }
        throw new WorkflowException(
          'Failed to start workflow: ' + genuineError
        );
      }
    }

    if (!insertedInstances.isEmpty()) {
      List<Workflow_Search_Attribute__c> attrsToInsert = new List<Workflow_Search_Attribute__c>();
      for (Integer j = 0; j < insertedInstances.size(); j++) {
        StartRequest req = requests[insertedReqIndexes[j]];
        Workflow_Instance__c instance = insertedInstances[j];
        if (req.attributes != null && !req.attributes.isEmpty()) {
          for (String key : req.attributes.keySet()) {
            String val = req.attributes.get(key);
            attrsToInsert.add(new Workflow_Search_Attribute__c(
              Workflow_Instance__c = instance.Id,
              Key__c = key,
              Value__c = val,
              Key_Value__c = key + '=' + (val == null ? '' : val)
            ));
          }
        }
      }
      if (!attrsToInsert.isEmpty()) {
        insert as system attrsToInsert;
      }
    }

    // 5. Build a key -> resolved Id map for newly inserted instances and for
    //    any concurrent winners, then fill remaining (intra-batch / loser)
    //    results. A DUPLICATE_VALUE proves a sibling exists, so losers are
    //    resolved regardless of the dedup window (the winner may have completed
    //    mid-race, including when the window is disabled).
    Map<String, Id> resolvedIdByKey = new Map<String, Id>();
    for (Integer j = 0; j < insertedInstances.size(); j++) {
      String key = requests[insertedReqIndexes[j]].correlationKey;
      if (String.isNotBlank(key)) {
        resolvedIdByKey.put(normalizeKey(key), insertedInstances[j].Id);
      }
    }
    if (!concurrentLoserKeys.isEmpty()) {
      Map<String, Workflow_Instance__c> winners = findAnyByKey(
        concurrentLoserKeys
      );
      for (String normalized : winners.keySet()) {
        if (!resolvedIdByKey.containsKey(normalized)) {
          resolvedIdByKey.put(normalized, winners.get(normalized).Id);
        }
      }
    }
    for (Integer i = 0; i < requests.size(); i++) {
      if (results[i] != null) {
        continue;
      }
      String normKey = normalizeKey(requests[i].correlationKey);
      if (
        String.isNotBlank(requests[i].correlationKey) &&
        resolvedIdByKey.containsKey(normKey)
      ) {
        results[i] = new StartResult(resolvedIdByKey.get(normKey), false);
      }
    }

    // Safety net: every request carries a non-blank key (validated above) and
    // must resolve to an instance. A lingering null would mean a duplicate
    // loser whose winner could not be located; rather than return a null
    // instance Id, roll back this invocation's inserts and surface an error.
    List<String> unresolvedKeys = new List<String>();
    for (Integer i = 0; i < requests.size(); i++) {
      if (results[i] == null) {
        unresolvedKeys.add(requests[i].correlationKey);
      }
    }
    if (!unresolvedKeys.isEmpty()) {
      if (!insertedInstances.isEmpty()) {
        delete as system insertedInstances;
      }
      throw new WorkflowException(
        'Failed to resolve workflow start for correlation key(s): ' +
        String.join(unresolvedKeys, ', ')
      );
    }

    // 6. Resolve input payloads for newly inserted instances
    for (Integer j = 0; j < insertedInstances.size(); j++) {
      StartRequest req = requests[insertedReqIndexes[j]];
      Workflow_Instance__c instance = insertedInstances[j];
      String inputJson = (req.input != null) ? JSON.serialize(req.input) : null;
      instance.Input__c = savePayloadIfNeeded(
        instance.Id,
        inputJson,
        'Input_' + instance.Id
      );
    }
    if (!insertedInstances.isEmpty()) {
      update as system insertedInstances;
    }

    // Operator pause gate (bulk path — used by scheduled jobs and the Flow
    // invocable): instances whose definition is paused are parked at start. They
    // get a Pending initial step with NO timeout clock and are excluded from
    // timeout scheduling and the initial enqueue, mirroring the scalar doStart.
    Boolean anyPaused = WorkflowPauseGate.anyPaused();
    Set<Id> parkedIds = new Set<Id>();
    List<Workflow_Instance__c> instancesToPark = new List<Workflow_Instance__c>();
    if (anyPaused) {
      for (Workflow_Instance__c instance : insertedInstances) {
        if (WorkflowPauseGate.isDefinitionPaused(instance.Workflow_Name__c)) {
          instance.Status__c = 'Paused';
          parkedIds.add(instance.Id);
          instancesToPark.add(instance);
        }
      }
    }

    // Concurrency-bounded workflows defer the initial timeout clock until the
    // admission gate wins a slot (mirrors doStart). A bounded first step is enqueued
    // so its RUN_STEP reaches the gate, but a still-Pending overflow item sitting in
    // the event/queue backlog during a burst would be failed by the timeout sweep
    // before it ever reaches the gate to park. Admission re-arms the timeout via
    // reArmTimeoutsForResume. isConfigured is memoized per name, so this is bulk-safe.
    Set<Id> deferTimeoutIds = new Set<Id>();
    List<Workflow_Instance__c> deferredToMark = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c instance : insertedInstances) {
      if (ConcurrencyGate.isConfigured(instance.Workflow_Name__c)) {
        deferTimeoutIds.add(instance.Id);
        // Durable awaiting-admission marker (see doStart): the pre-start watchdog
        // keys its null-deadline skip off this, not the live CMDT, so a ceiling added
        // later cannot silence a genuine unbounded pre-start watchdog. Cleared on
        // admission. Parked-at-start instances are handled by instancesToPark below.
        if (!parkedIds.contains(instance.Id)) {
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
      update as system deferredToMark;
    }

    // 7. Construct initial Step Execution logs for inserted instances only
    List<Workflow_Step_Execution__c> stepExecs = new List<Workflow_Step_Execution__c>();
    for (Workflow_Instance__c instance : insertedInstances) {
      if (String.isNotBlank(instance.Current_Step__c)) {
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
          !parkedIds.contains(instance.Id) &&
          !deferTimeoutIds.contains(instance.Id)
        ) {
          Integer timeout = getStepTimeoutSeconds(instance.Current_Step__c);
          if (timeout != null && timeout > 0) {
            stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
          }
        }
        stepExecs.add(stepExec);
      }
    }
    if (!stepExecs.isEmpty()) {
      insert as system stepExecs;
    }

    // Persist the parked status transition; parked instances are neither scheduled
    // nor enqueued — the resume path drives them when the definition is resumed.
    if (!instancesToPark.isEmpty()) {
      update as system instancesToPark;
    }

    // 8. Schedule timeout jobs for non-parked, non-deferred instances and enqueue
    // orchestrators for all non-parked instances. Concurrency-bounded instances are
    // still enqueued so their first RUN_STEP reaches the admission gate, but their
    // timeout job is deferred until the gate arms it on admission (see deferTimeoutIds).
    List<Workflow_Instance__c> instancesToSchedule = new List<Workflow_Instance__c>();
    List<Id> instanceIds = new List<Id>();
    for (Workflow_Instance__c instance : insertedInstances) {
      if (parkedIds.contains(instance.Id)) {
        continue;
      }
      instanceIds.add(instance.Id);
      if (!deferTimeoutIds.contains(instance.Id)) {
        instancesToSchedule.add(instance);
      }
    }
    if (!instancesToSchedule.isEmpty()) {
      scheduleTimeoutJobsForInstances(instancesToSchedule);
    }
    if (!instanceIds.isEmpty()) {
      enqueueOrchestrators(instanceIds);
    }

    return results;
  }

  /**
   * Resumes a suspended workflow matching the correlation key.
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
    update as system instance;

    // If there is an active step, we can store the resume payload in its step execution record
    if (String.isNotBlank(instance.Current_Step__c)) {
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
      if (!activeSteps.isEmpty()) {
        Workflow_Step_Execution__c stepExec = activeSteps[0];
        stepExec.Status__c = 'Running';
        stepExec.Output__c = savePayloadIfNeeded(
          instance.Id,
          payload,
          'Resume_' + stepExec.Id
        );
        Integer timeout = getStepTimeoutSeconds(instance.Current_Step__c);
        if (timeout != null && timeout > 0) {
          stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
        } else {
          stepExec.Timeout_At__c = null;
        }
        update as system stepExec;
      }
    }

    scheduleTimeoutJobForInstance(instance.Id);

    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(instance.Id));
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  /**
   * Resumes a suspended workflow instance directly by its database ID.
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
    update as system instance;

    // If there is an active step, we can store the resume payload in its step execution record
    if (String.isNotBlank(instance.Current_Step__c)) {
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
      if (!activeSteps.isEmpty()) {
        Workflow_Step_Execution__c stepExec = activeSteps[0];
        stepExec.Status__c = 'Running';
        stepExec.Output__c = savePayloadIfNeeded(
          instance.Id,
          payload,
          'Resume_' + stepExec.Id
        );
        Integer timeout = getStepTimeoutSeconds(instance.Current_Step__c);
        if (timeout != null && timeout > 0) {
          stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
        } else {
          stepExec.Timeout_At__c = null;
        }
        update as system stepExec;
      }
    }

    scheduleTimeoutJobForInstance(instance.Id);

    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(instance.Id));
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  /**
   * Resumes multiple suspended workflows in a bulk-friendly transaction.
   */
  public static void resume(List<ResumeRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    Set<String> keys = new Set<String>();
    Set<Id> ids = new Set<Id>();
    for (ResumeRequest req : requests) {
      if (req.instanceId != null) {
        ids.add(req.instanceId);
      } else if (String.isNotBlank(req.correlationKey)) {
        keys.add(req.correlationKey);
      }
    }

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

    Map<Id, Workflow_Instance__c> instById = new Map<Id, Workflow_Instance__c>();
    Map<String, Workflow_Instance__c> instByKey = new Map<String, Workflow_Instance__c>();
    for (Workflow_Instance__c inst : instances) {
      instById.put(inst.Id, inst);
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        instByKey.put(inst.Correlation_Key__c, inst);
      }
    }

    // Verify that we found a suspended instance for every request
    for (ResumeRequest req : requests) {
      Workflow_Instance__c inst = null;
      if (req.instanceId != null) {
        inst = instById.get(req.instanceId);
      } else if (String.isNotBlank(req.correlationKey)) {
        inst = instByKey.get(req.correlationKey);
      }
      if (inst == null) {
        throw new WorkflowException(
          'No suspended workflow found with key or ID: ' +
          (req.instanceId != null
            ? (String) req.instanceId
            : req.correlationKey)
        );
      }
    }

    // Gathers active step execution logs for the instances in bulk
    Set<Id> activeInstIds = instById.keySet();
    List<Workflow_Step_Execution__c> allActiveSteps = [
      SELECT Id, Workflow_Instance__c, Step_Name__c, Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :activeInstIds
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    Map<Id, Workflow_Step_Execution__c> latestStepByInstanceId = new Map<Id, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c step : allActiveSteps) {
      if (!latestStepByInstanceId.containsKey(step.Workflow_Instance__c)) {
        Workflow_Instance__c inst = instById.get(step.Workflow_Instance__c);
        if (inst != null && String.isNotBlank(inst.Current_Step__c)) {
          Boolean stepMatches = false;
          if (inst.Current_Step__c.contains(',')) {
            for (String pStep : inst.Current_Step__c.split(',')) {
              if (pStep.trim() == step.Step_Name__c) {
                stepMatches = true;
                break;
              }
            }
          } else if (inst.Current_Step__c == step.Step_Name__c) {
            stepMatches = true;
          }
          if (stepMatches) {
            latestStepByInstanceId.put(step.Workflow_Instance__c, step);
          }
        }
      }
    }

    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    List<Workflow_Step_Execution__c> stepsToUpdate = new List<Workflow_Step_Execution__c>();

    for (ResumeRequest req : requests) {
      Workflow_Instance__c inst = null;
      if (req.instanceId != null) {
        inst = instById.get(req.instanceId);
      } else if (String.isNotBlank(req.correlationKey)) {
        inst = instByKey.get(req.correlationKey);
      }

      if (inst != null) {
        inst.Status__c = 'Running';
        // Disarm any armed timed-wait timeout so the watchdog does not mis-route
        // to the fallback step after a manual resume wins the race (issue #35).
        inst.Sleep_Until__c = null;
        instancesToUpdate.add(inst);

        Workflow_Step_Execution__c stepExec = latestStepByInstanceId.get(
          inst.Id
        );
        if (stepExec != null) {
          stepExec.Status__c = 'Running';
          stepExec.Output__c = savePayloadIfNeeded(
            inst.Id,
            req.payload,
            'Resume_' + stepExec.Id
          );
          Integer timeout = getStepTimeoutSeconds(inst.Current_Step__c);
          if (timeout != null && timeout > 0) {
            stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
          } else {
            stepExec.Timeout_At__c = null;
          }
          stepsToUpdate.add(stepExec);
        }
      }
    }

    update as system instancesToUpdate;
    if (!stepsToUpdate.isEmpty()) {
      update as system stepsToUpdate;
    }

    scheduleTimeoutJobsForInstances(instancesToUpdate);

    List<Id> instanceIds = new List<Id>();
    for (Workflow_Instance__c inst : instancesToUpdate) {
      instanceIds.add(inst.Id);
    }
    enqueueOrchestrators(instanceIds);
  }

  /**
   * Executes the active step for a workflow instance. Designed to run in a Queueable context.
   */
  public static void runStep(Id instanceId) {
    runStep(instanceId, null);
  }

  public static void runStep(Id instanceId, String stepName) {
    // 1. Fetch instance state (NO FOR UPDATE lock to allow parallel execution and direct callouts)
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
        Failure_Category__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];

    if (instances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instanceId);
    }

    Workflow_Instance__c instance = instances[0];
    if (
      instance.Status__c == 'Completed' ||
      instance.Status__c == 'Failed' ||
      instance.Status__c == 'Compensated' ||
      instance.Status__c == 'CompensationFailed' ||
      instance.Status__c == 'Cancelled' ||
      instance.Status__c == 'ContinuedAsNew'
    ) {
      return; // Already finished
    }

    Boolean isCompensating = (instance.Status__c == 'Compensating' ||
    instance.Status__c == 'Cancelling');
    // A compensation step that SUSPENDed (e.g. waiting on a signal) leaves the
    // instance Suspended; signal() then flips it to Running before re-enqueueing.
    // In either state a latest step ending in '_Compensate' means the instance
    // is still compensating and must route to runCompensationStep, not the
    // forward path -- otherwise a signal-driven compensation is skipped and the
    // instance stays stuck Running with the compensation step pending.
    if (instance.Status__c == 'Suspended' || instance.Status__c == 'Running') {
      // Only treat a trailing-'_Compensate' latest step as a live compensation
      // when the instance's compensation stack actually holds the matching base
      // step. A normal forward step that happens to be named '<x>_Compensate'
      // and is resumed by signal() (Suspended/Running with no -- or unrelated --
      // stack) must NOT be misrouted to runCompensationStep, which would see no
      // matching stack entry and mark the instance Compensated instead of
      // resuming it. The forward execution of compensatable steps grows the
      // stack too, so a non-empty stack alone is not enough; require the base
      // name to be on it.
      List<String> compStack = String.isNotBlank(instance.Compensation_Stack__c)
        ? (List<String>) JSON.deserialize(
            instance.Compensation_Stack__c,
            List<String>.class
          )
        : new List<String>();
      if (!compStack.isEmpty()) {
        List<Workflow_Step_Execution__c> latestSteps = [
          SELECT Step_Name__c
          FROM Workflow_Step_Execution__c
          WHERE Workflow_Instance__c = :instance.Id
          WITH SYSTEM_MODE
          ORDER BY CreatedDate DESC, Id DESC
          LIMIT 1
        ];
        if (
          !latestSteps.isEmpty() &&
          latestSteps[0].Step_Name__c != null &&
          latestSteps[0].Step_Name__c.endsWith('_Compensate') &&
          compStack.contains(
            latestSteps[0].Step_Name__c.removeEnd('_Compensate')
          )
        ) {
          isCompensating = true;
        }
      }
    }

    if (isCompensating) {
      // Re-assert the compensating status before running the step: runCompensationStep
      // early-exits unless the instance is Compensating/Cancelling, so a
      // Suspended (initial detection) or Running (signal-resumed) instance must
      // be restored to the right compensation status first.
      String reassertedStatus = null;
      if (
        instance.Status__c == 'Suspended' ||
        instance.Status__c == 'Running'
      ) {
        reassertedStatus = (instance.Error_Message__c != null &&
          instance.Error_Message__c.contains('Cancelled by user'))
          ? 'Cancelling'
          : 'Compensating';
        instance.Status__c = reassertedStatus;
        instance.Async_Job_Id__c = null;
        // Set the compensating status in memory but DEFER its DML to
        // runCompensationStep. A compensation step resumed by a signal may be a
        // CalloutStep that makes a payload-driven callout in compensate(), and
        // Salesforce forbids a callout once the transaction holds uncommitted
        // DML. Committing here (as this used to) made that callout illegal.
        // runCompensationStep re-applies this phase after its own re-query and
        // commits it before compensate() for an ordinary step / after it for a
        // CalloutStep. A crash before that commit leaves the instance Suspended/
        // Running with the '_Compensate' step on the stack, which this same
        // detection re-routes on the next drive.
      }
      runCompensationStep(instance, reassertedStatus);
      return;
    }

    // 2a. Operator pause gate — park at the chain handoff instead of proceeding.
    //     Compensating/Cancelling instances bypass this (already returned above) so
    //     cancel + rollback always proceed on a paused definition.
    Boolean definitionPaused =
      WorkflowPauseGate.anyPaused() &&
      WorkflowPauseGate.isDefinitionPaused(instance.Workflow_Name__c);
    // A still-Paused row must NOT execute even once its definition has been
    // resumed: chunked resume deletes the pause record before every Paused row is
    // flipped to Running, so a stale RUN_STEP delivered in that window would
    // otherwise run the step before the drain re-arms its timeout / flips it. Let
    // the resume drain own the Paused -> Running transition.
    if (definitionPaused || instance.Status__c == 'Paused') {
      // Park a not-yet-parked instance whose definition is paused; an
      // already-Paused row is just a no-op until the drain flips it to Running.
      if (definitionPaused && instance.Status__c != 'Paused') {
        instance.Status__c = 'Paused';
        update as system instance;
      }
      return;
    }

    // 2b. Concurrency admission gate. An instance that does not yet hold a slot must
    //     acquire one before executing any step of a definition with a configured
    //     ceiling. Acquisition commits the guarded counter increment in THIS
    //     transaction and re-drives the step in a fresh transaction, so execute()
    //     never runs while the counter DML is uncommitted (which would make a
    //     CalloutStep — the primary use case for this feature — illegal). A held slot
    //     is released only on a terminal transition (WorkflowInstanceTrigger).
    //     Compensating/Cancelling instances already returned to runCompensationStep
    //     above; they keep the slot acquired on the forward path and are never re-gated.
    if (!instance.Concurrency_Slot_Held__c) {
      // Only bounded workflows are gated; resolving the ceiling first (a
      // governor-free CMDT read) keeps unbounded workflows on the exact path they
      // take today, with no instance lock.
      if (ConcurrencyGate.isConfigured(instance.Workflow_Name__c)) {
        // Serialize concurrent RUN_STEP deliveries for the SAME instance: both may
        // have read Concurrency_Slot_Held__c = false from the unlocked instance
        // query above. Re-read the authoritative flag under a row lock so the loser
        // observes the winner's committed acquire and no-ops, instead of either
        // double-consuming a slot (ceiling > 1) or parking over the just-admitted
        // row (ceiling = 1).
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
          return;
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
          return;
        }

        // Resolve the initial step for a fresh start BEFORE consuming a slot, so an
        // unresolvable workflow class fails cleanly here (the same WorkflowException
        // the validation below would throw) instead of holding a slot that
        // reconciliation would count forever. Throwing before tryAcquire takes no
        // slot; throwing after would roll back the uncommitted increment anyway.
        String resolvedStep = instance.Current_Step__c;
        if (String.isBlank(resolvedStep)) {
          Type wfType = Type.forName(instance.Workflow_Name__c);
          if (wfType == null) {
            throw new WorkflowException(
              'Could not resolve workflow definition class: ' +
              instance.Workflow_Name__c
            );
          }
          resolvedStep = ((WorkflowDefinition) wfType.newInstance())
            .getInitialStep();
        }

        ConcurrencyGate.AdmissionResult admission = ConcurrencyGate.tryAcquire(
          instance.Workflow_Name__c
        );
        if (admission.admitted) {
          // Slot acquired: commit the acquire + flag, then re-drive in a fresh
          // transaction. Clear the admission-retry sleep markers and restamp the
          // step's watchdog deadline (cleared on park) durably via
          // reArmTimeoutsForResume, so a re-admitted step keeps its timeout safety
          // net even when dynamic scheduling is off or at the job limit.
          instance.Concurrency_Slot_Held__c = true;
          instance.Concurrency_Parked__c = false;
          instance.Current_Step__c = resolvedStep;
          instance.Status__c = 'Running';
          instance.Sleep_Until__c = null;
          instance.Async_Job_Id__c = null;
          update as system instance;
          reArmTimeoutsForResume(new List<Workflow_Instance__c>{ instance });
          if (!(Test.isRunningTest() && disableQueueableInTest)) {
            enqueueResume(instance.Id);
          }
          return;
        }
        // Ceiling full: park and re-attempt admission automatically through the
        // existing sleep/watchdog resume plumbing.
        parkForConcurrency(instance);
        return;
      }
      // Otherwise unbounded (no ceiling): fall through and run exactly as today. If
      // this instance was parked under a ceiling that an admin has since removed or
      // disabled, clear the stale admission-retry markers before running. Leaving a
      // due Sleep_Until__c in place would let the watchdog treat a later real SUSPEND
      // as an overdue sleeper and re-run the step without its external signal.
      if (instance.Concurrency_Parked__c) {
        instance.Concurrency_Parked__c = false;
        instance.Sleep_Until__c = null;
        instance.Async_Job_Id__c = null;
        update as system instance;
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
        return;
      }
    }

    // 2. Initialize initial step in memory if this is the start (DML deferred to outcome handler)
    if (String.isBlank(instance.Current_Step__c)) {
      Type wflowType = Type.forName(instance.Workflow_Name__c);
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

    // If stepName is blank but Current_Step__c is a parallel list, this is a stale/duplicate orchestrator run. Return early.
    if (
      String.isBlank(stepName) &&
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',')
    ) {
      return;
    }

    // Validate explicit stepName only when Current_Step__c is a parallel list and the requested step is in that list
    if (String.isNotBlank(stepName) && instance.Current_Step__c != stepName) {
      if (
        String.isBlank(instance.Current_Step__c) ||
        !instance.Current_Step__c.contains(',')
      ) {
        throw new WorkflowException(
          'Step ' +
            stepName +
            ' is not the active/expected step for this instance: ' +
            instance.Current_Step__c
        );
      }
      Boolean isValid = false;
      for (String pStep : instance.Current_Step__c.split(',')) {
        if (pStep.trim() == stepName) {
          isValid = true;
          break;
        }
      }
      if (!isValid) {
        throw new WorkflowException(
          'Step ' +
            stepName +
            ' is not the active/expected step for this instance: ' +
            instance.Current_Step__c
        );
      }
    }

    // Determine step name to execute
    String activeStepName = String.isNotBlank(stepName)
      ? stepName
      : instance.Current_Step__c;

    // 3. Retrieve or create Step Execution log with FOR UPDATE lock.
    // Load all executions for this step so we can derive the visit count in
    // Apex without an extra COUNT() SOQL query.
    // Captured_Values__c is intentionally NOT selected here: this bulk read loads
    // every prior execution of the step only to count completed visits and pick
    // the latest row, so pulling each historical capture payload (up to ~100 KB
    // inline) would waste heap on a looping step. It is selected on the single-row
    // FOR UPDATE requery below, where only the latest row's captures are needed.
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Step_Name__c, Status__c, Input__c, Output__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = :activeStepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    Integer stepVisit = 0;
    for (Workflow_Step_Execution__c exec : stepExecs) {
      if (exec.Status__c == 'Completed') {
        stepVisit++;
      }
    }

    if (!stepExecs.isEmpty()) {
      stepExecs = [
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

    // Re-query the instance after acquiring the lock on the step execution to get the most up-to-date committed state
    instances = [
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
        CreatedDate
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instanceId);
    }
    instance = instances[0];

    // Check early exit conditions for instance status
    if (
      instance.Status__c == 'Completed' ||
      instance.Status__c == 'Failed' ||
      instance.Status__c == 'Compensated' ||
      instance.Status__c == 'CompensationFailed' ||
      instance.Status__c == 'Cancelled' ||
      instance.Status__c == 'ContinuedAsNew'
    ) {
      return; // Already finished
    }

    Workflow_Step_Execution__c stepExec;
    if (stepExecs.isEmpty()) {
      stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instanceId;
      stepExec.Step_Name__c = activeStepName;
      stepExec.Status__c = 'Running';
      stepExec.Retry_Count__c = 0;
      stepExec.Transient_Retry_Count__c = 0;

      // Get previous step's output to feed as input
      List<Workflow_Step_Execution__c> completedSteps = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Completed'
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      stepExec.Input__c = !completedSteps.isEmpty()
        ? completedSteps[0].Output__c
        : instance.Input__c;
    } else {
      stepExec = stepExecs[0];
      if (
        stepExec.Status__c == 'Completed' ||
        stepExec.Status__c == 'Failed' ||
        stepExec.Status__c == 'Cancelled' ||
        stepExec.Status__c == 'Compensated'
      ) {
        return; // Already completed or terminated by concurrent thread
      }
      stepExec.Status__c = 'Running';
    }

    // 4. Resolve previous step output & step state (for yielded/resumed executions)
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
          AND Status__c = 'Completed'
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
          AND Status__c = 'Completed'
          AND Step_Name__c != :activeStepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
    }
    if (!lastCompleted.isEmpty()) {
      prevOutput = lastCompleted[0].Output__c;
    }

    // 5. Invoke Step Execution
    Type stepType = Type.forName(activeStepName);
    if (stepType == null) {
      throw new WorkflowException(
        'Could not resolve class for step: ' + activeStepName
      );
    }
    WorkflowStep stepInstance = (WorkflowStep) stepType.newInstance();

    Boolean isParallelBranchStep =
      String.isNotBlank(stepName) &&
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',');
    // A parallel branch claims signals at read time (Received -> Processing) so
    // siblings cannot double-process them. That claim is uncommitted DML, which
    // would make a payload-driven callout illegal, so a step that declares
    // CalloutStep opts out of claiming and reads at-least-once instead.
    Boolean claimSignals =
      isParallelBranchStep && !(stepInstance instanceof CalloutStep);
    StepContext.SignalSource signalSrc = claimSignals
      ? (StepContext.SignalSource) new ParallelBranchSignalSource(instanceId)
      : (StepContext.SignalSource) new PendingSignalSource(instanceId);
    // stepVisit: number of already-completed runs of this step in this instance.
    // Computed above from the stepExecs list (before FOR UPDATE re-assigns it)
    // to avoid a separate COUNT() SOQL query.
    // Detect and strip the $timeoutResume marker (issue #35): the watchdog sets it
    // in Input__c of the fallback exec to durably signal the timeout-triggered path.
    // Strip it before passing inputJson to the context so the author step never
    // sees the engine-internal key.
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
    // Strip the engine-internal $timeoutStep marker from the state JSON a timed
    // wait persisted in Output__c, so a signal-win resume that re-runs the wait
    // step does not surface the reserved key to the author via stepStateJson.
    String resolvedState = resolvePayload(stepExec.Output__c);
    if (
      String.isNotBlank(resolvedState) && resolvedState.contains('$timeoutStep')
    ) {
      resolvedState = stripJsonMapKey(resolvedState, '$timeoutStep');
    }

    Integer attempt = stepExec.Retry_Count__c != null ? (Integer) stepExec.Retry_Count__c + 1 : 1;
    Integer maxAttempts = 1;
    Map<String, Object> capturesMap = new Map<String, Object>();
    if (stepInstance instanceof RetryConfigurable) {
      RetryPolicy policy = sanitizePolicy(((RetryConfigurable) stepInstance).getRetryPolicy());
      maxAttempts = policy.maximumAttempts;
    } else if (String.isNotBlank(stepExec.Captured_Values__c)) {
      String resolvedCaptures = resolvePayload(stepExec.Captured_Values__c);
      if (String.isNotBlank(resolvedCaptures)) {
        try {
          capturesMap = (Map<String, Object>) JSON.deserializeUntyped(resolvedCaptures);
          if (capturesMap.containsKey('__maxAttempts')) {
            maxAttempts = Integer.valueOf(capturesMap.get('__maxAttempts'));
          }
        } catch (Exception e) {
          System.debug(LoggingLevel.ERROR, 'Failed to deserialize captured values: ' + e.getMessage());
        }
      }
    }

    StepContext context = StepContext.withCapturedValuesMap(
      instanceId,
      instance.Workflow_Name__c,
      activeStepName,
      resolvedInput,
      resolvePayload(prevOutput),
      resolvedState,
      resolvePayload(instance.Input__c),
      instance.Definition_Version__c != null
        ? (Integer) instance.Definition_Version__c
        : 1,
      stepVisit,
      signalSrc,
      instance.Previous_Run_At__c,
      capturesMap,
      isTimeoutResume,
      attempt,
      maxAttempts
    );

    // Save/Commit step execution status and set Timeout_At__c before executing the step so watchdog can detect timeouts.
    // A CalloutStep performs a synchronous, payload-driven HTTP callout inside
    // execute(), and Salesforce forbids a callout once the transaction holds
    // pending DML. We already skip signal claiming for such a step (claimSignals
    // above), but this timeout bookkeeping also writes DML, so defer that write
    // past execute() for a CalloutStep. The step's Timeout_At__c and scheduled
    // timeout job were already committed when it was queued, so the watchdog
    // stays armed across the callout; the finally block reconciles the timeout
    // once execute() returns.
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

    StepResult result;
    try {
      result = stepInstance.execute(context);
    } finally {
      if (timeoutSeconds != null && timeoutSeconds > 0) {
        stepExec.Timeout_At__c = null;
        saveStepExec(stepExec);
        cancelTimeoutJob(instanceId, activeStepName);
      }
    }

    // 6. Handle Step Outcome
    handleStepResult(instance, stepExec, result, context);
  }

  // Caps how many signals a serial step may observe in one execution. Serial
  // steps never claim (no read-side DML), so the only DML is the COMPLETE
  // consume; 8 000 keeps the consume update (matched ids + same-name duplicate
  // cleanup) safely under the 10 000 DML-row limit while never exposing more
  // rows than completion can consume. Excess rows stay Received for a later read.
  // @TestVisible (non-final) so a test can shrink the cap to exercise budget
  // exhaustion without inserting thousands of rows.
  @TestVisible
  private static Integer SERIAL_SIGNAL_ROW_CAP = 8000;

  /**
   * Lazily supplies the pending (unconsumed) signals targeting an instance so a
   * step that never reads signals pays no query/heap cost for unrelated
   * unconsumed signals on the instance. Tracks a cumulative row budget across
   * accessor calls so the step can never observe (and mark consumed) more rows
   * than the COMPLETE consume pass can handle.
   */
  private class PendingSignalSource implements StepContext.SignalSource {
    private final Id instanceId;
    private Integer rowBudget = SERIAL_SIGNAL_ROW_CAP;
    private Boolean capped = false;

    private PendingSignalSource(Id instanceId) {
      this.instanceId = instanceId;
    }

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
      // SERIAL_SIGNAL_ROW_CAP (8 000) and the 9 000-row consume cap. A step
      // would exhaust SOQL long before it could match more ids than
      // markSignalsConsumed() can update, so no consume-overflow redelivery
      // arises (Codex L1108 documented as not reachable, not gated).
      StepContext.Signal latest = loadLatestSignal(this.instanceId, signalName);
      if (latest != null && rowBudget > 0) {
        rowBudget -= 1;
      }
      return latest;
    }

    public Boolean readWasCapped() {
      return capped;
    }
  }

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
  private class ParallelBranchSignalSource implements StepContext.SignalSource {
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
            resolvedPayloads[i],
            rows[i].CreatedDate
          )
        );
      }
      return out;
    }

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

        List<Workflow_Signal__c> locked = [
          SELECT Id
          FROM Workflow_Signal__c
          WHERE Id IN :candidateIds AND Status__c = 'Received'
          WITH SYSTEM_MODE
          FOR UPDATE
        ];
        if (locked.isEmpty()) {
          continue; // whole page lost to siblings; try the next page
        }

        Set<Id> claimedIds = new Set<Id>();
        for (Workflow_Signal__c sig : locked) {
          sig.Status__c = 'Processing';
          claimedIds.add(sig.Id);
        }
        update as system locked; // one statement for the whole page
        claimBudget -= claimedIds.size();
        claimStatementBudget -= 1;

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
              resolvedPayloads[i],
              claimedRows[i].CreatedDate,
              true
            )
          );
        }
        return result;
      }
      return new List<StepContext.Signal>();
    }

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
        // Fetch recent candidates newest-first.
        List<Workflow_Signal__c> candidates = [
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
            resolvePayload(c.Payload__c),
            c.CreatedDate
          );
        }
        // Try to claim each candidate newest-first; if a sibling wins the race on
        // the newest row, fall back to the next-newest still-Received row instead
        // of reporting absence while a matching signal is still available.
        for (Workflow_Signal__c cand : candidates) {
          Id targetId = cand.Id;
          List<Workflow_Signal__c> locked = [
            SELECT Id
            FROM Workflow_Signal__c
            WHERE Id = :targetId AND Status__c = 'Received'
            WITH SYSTEM_MODE
            FOR UPDATE
          ];
          if (locked.isEmpty()) {
            continue; // lost the race on this row; try the next-newest
          }
          locked[0].Status__c = 'Processing';
          update as system locked[0];
          claimBudget -= 1;
          claimStatementBudget -= 1;
          // claimed = true: this branch now exclusively owns the row.
          return new StepContext.Signal(
            cand.Id,
            cand.Signal_Name__c,
            resolvePayload(cand.Payload__c),
            cand.CreatedDate,
            true
          );
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
  }

  /**
   * Loads only the single most-recent pending signal matching a name, so a step
   * reading one decision via getSignal/hasSignal does not pull every duplicate
   * payload (consumption still re-queries by name, without payloads). Returns
   * null when no matching Received signal exists.
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
      resolvePayload(records[0].Payload__c),
      records[0].CreatedDate
    );
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
   */
  private static List<StepContext.Signal> loadPendingSignals(
    Id instanceId,
    String signalName,
    Integer rowLimit
  ) {
    Integer effectiveLimit = (rowLimit != null &&
      rowLimit > 0)
      ? rowLimit
      : SERIAL_SIGNAL_ROW_CAP;
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
          resolvedPayloads[i],
          records[i].CreatedDate
        )
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
    update as system toRollback;
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
   */
  private static void markSignalsConsumed(
    Id instanceId,
    StepContext context,
    Boolean parallelBranch
  ) {
    if (context == null) {
      return;
    }
    Set<Id> matchedIds = context.getConsumedSignalIds();
    if (matchedIds == null) {
      matchedIds = new Set<Id>();
    }
    Set<Id> claimedIds = context.getClaimedSignalIds();
    if (claimedIds == null) {
      claimedIds = new Set<Id>();
    }
    Set<String> matchedNames = context.getConsumedSignalNames();
    if (matchedNames == null) {
      matchedNames = new Set<String>();
    }
    // A step that matched nothing triggers no query, keeping non-signal steps cheap.
    if (matchedIds.isEmpty() && matchedNames.isEmpty()) {
      return;
    }

    final Integer ROW_CAP = 9000;
    Map<Id, Workflow_Signal__c> toConsume = new Map<Id, Workflow_Signal__c>();

    // 1a. Claimed ids: consume while Received OR Processing (this branch's own
    //     exclusive claim).
    if (!claimedIds.isEmpty()) {
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

    // 1b. Observed-but-not-claimed ids: consume only while STILL Received, so a
    //     row a sibling has since claimed (Processing) is left for the sibling.
    Set<Id> observedOnly = new Set<Id>(matchedIds);
    observedOnly.removeAll(claimedIds);
    if (!observedOnly.isEmpty() && toConsume.size() < ROW_CAP) {
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

    // 2. Serial steps only, and only when no read was capped: clean up same-name
    //    at-least-once duplicates that arrived after the snapshot. Skipped on a
    //    capped read so backlog rows the step never observed are not consumed
    //    (lost); restricted to still-Received rows so it never steals a sibling's
    //    claim.
    //
    //    Known limitation (accepted): signalReadWasCapped() is a single flag for
    //    the whole execution, so if ANY name's read was capped, duplicate cleanup
    //    is suppressed for EVERY matched name -- even names whose own read was not
    //    capped. Those names then degrade to at-least-once (an older duplicate may
    //    survive and be reprocessed later). Scoping suppression per-name would
    //    require threading capped-name tracking through the SignalSource into
    //    consume; it is not done because the cap only triggers at pathological
    //    scale (thousands of unconsumed same-name rows on one instance), where
    //    at-least-once is already the documented contract.
    Integer remaining = ROW_CAP - toConsume.size();
    if (
      !parallelBranch &&
      !context.signalReadWasCapped() &&
      !matchedNames.isEmpty() &&
      remaining > 0
    ) {
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

    if (toConsume.isEmpty()) {
      return;
    }
    for (Workflow_Signal__c sig : toConsume.values()) {
      sig.Status__c = 'Consumed';
    }
    update as system toConsume.values();
  }

  private static void populateTelemetry(Workflow_Step_Execution__c stepExec, Boolean isCrash) {
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

  private static void saveStepExec(Workflow_Step_Execution__c stepExec, Boolean isCrash) {
    populateTelemetry(stepExec, isCrash);
    if (stepExec.Id == null) {
      insert as system stepExec;
    } else {
      update as system stepExec;
    }
  }

  /**
   * Counts terminal (completed) executions of a step name within an instance.
   * Used to derive the per-visit idempotency sequence for StepContext: the
   * current (not-yet-completed) visit is excluded, so this is 0 for the first
   * visit and increments each time the engine loops back to the same step.
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
    if (context != null && context.getPendingEmits() != null) {
      for (SObject e : context.getPendingEmits()) {
        if (e != null) {
          events.add(e);
        }
      }
    }
    if (result != null && result.outboundEvents != null) {
      for (SObject e : result.outboundEvents) {
        if (e != null) {
          events.add(e);
        }
      }
    }
    if (events.isEmpty()) {
      return;
    }
    WorkflowOutboundEventPublisher.publish(events);
  }

  private static void handleStepResult(
    Workflow_Instance__c instance,
    Workflow_Step_Execution__c stepExec,
    StepResult result,
    StepContext context
  ) {
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
        Progress__c
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (context != null && context.isProgressReported()) {
      String progJson = context.getProgressJson();
      freshInstance.Progress__c = savePayloadIfNeeded(
        freshInstance.Id,
        progJson,
        'Progress_' + (stepExec != null && String.isNotBlank(stepExec.Step_Name__c) ? stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_') : 'Default')
      );
    }
    if (
      String.isBlank(freshInstance.Current_Step__c) &&
      String.isNotBlank(instance.Current_Step__c)
    ) {
      freshInstance.Current_Step__c = instance.Current_Step__c;
    }
    if (
      freshInstance.Status__c == 'Failed' ||
      freshInstance.Status__c == 'Compensating' ||
      freshInstance.Status__c == 'Compensated' ||
      freshInstance.Status__c == 'CompensationFailed' ||
      freshInstance.Status__c == 'Cancelled' ||
      freshInstance.Status__c == 'Cancelling' ||
      freshInstance.Status__c == 'ContinuedAsNew'
    ) {
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
    instance = freshInstance;

    // Reaching here means this drive acquired the instance lock that the crash path
    // re-drives on (the parent FOR UPDATE above) — i.e. any transient row-lock
    // contention on this step has cleared. Reset the CONSECUTIVE transient-retry
    // counter so a later, unrelated contention burst on this same long-lived
    // suspend/join step gets the full budget again instead of inheriting a stale
    // near-exhausted count from an earlier wake.
    if (
      stepExec != null &&
      stepExec.Id != null &&
      stepExec.Transient_Retry_Count__c != null &&
      stepExec.Transient_Retry_Count__c > 0
    ) {
      // Targeted single-field update so this early reset never persists any other
      // in-memory staging the outcome branches below have yet to commit.
      update as system new Workflow_Step_Execution__c(
        Id = stepExec.Id,
        Transient_Retry_Count__c = 0
      );
      stepExec.Transient_Retry_Count__c = 0;
    }

    Boolean isParallel =
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',');

    // Persist capture-once values produced during this execution. This runs once
    // before the action dispatch so every outcome (COMPLETE, YIELD, SLEEP,
    // SUSPEND, RETRY, etc.) durably records captures. Critically, RETRY only
    // nulls Output__c — it never touches Captured_Values__c — so captures
    // survive retries and are replayed byte-identically on the next attempt.
    // Only writes when new captures were added; re-executions that only read
    // prior captures produce no new DML here.
    if (context.hasNewCaptures()) {
      String capturedJson = context.getCapturedValuesJson();
      stepExec.Captured_Values__c = savePayloadIfNeeded(
        instance.Id,
        capturedJson,
        'Captures_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
    }

    if (result.action == StepResult.ActionType.COMPLETE) {
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

      // Update compensation stack if step is CompensatableStep
      Type stepType = Type.forName(stepExec.Step_Name__c);
      if (stepType != null) {
        Object stepInstanceObj = stepType.newInstance();
        if (stepInstanceObj instanceof CompensatableStep) {
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
          update as system instance;
        }
      }

      if (!isParallel) {
        // Determine next step
        Type wflowType = Type.forName(instance.Workflow_Name__c);
        WorkflowDefinition def = (WorkflowDefinition) wflowType.newInstance();
        String nextStepName;
        if (def instanceof VersionedWorkflow) {
          nextStepName = ((VersionedWorkflow) def)
            .getNextStep(
              instance.Current_Step__c,
              result,
              instance.Definition_Version__c != null
                ? (Integer) instance.Definition_Version__c
                : 1
            );
        } else {
          nextStepName = def.getNextStep(instance.Current_Step__c, result);
        }

        if (String.isBlank(nextStepName)) {
          // Workflow is finished
          instance.Status__c = 'Completed';
          instance.Output__c = savePayloadIfNeeded(
            instance.Id,
            result.outputJson,
            'Output_Final'
          );
          instance.Current_Step__c = null;
          update as system instance;

          // Notify parent completion if this is a child workflow. This publishes
          // the load-bearing Workflow_Event__e, so it must run BEFORE the
          // best-effort lifecycle publish to keep first claim on DML budget.
          notifyParentCompletion(instance);

          // Fire-and-forget outbound lifecycle event on terminal transition.
          WorkflowLifecyclePublisher.publish(instance);
          return;
        }

        // Advance to next step
        instance.Current_Step__c = nextStepName;
        update as system instance;

        Workflow_Step_Execution__c nextStepExec = new Workflow_Step_Execution__c();
        nextStepExec.Workflow_Instance__c = instance.Id;
        nextStepExec.Step_Name__c = nextStepName;
        nextStepExec.Status__c = 'Pending';
        nextStepExec.Input__c = stepExec.Output__c;
        nextStepExec.Retry_Count__c = 0;
        insert as system nextStepExec;

        // Pass the in-memory instance (Current_Step__c just advanced to nextStepName,
        // committed above) so the per-advance watchdog scheduling does not re-query the
        // instance on every step — that re-read is what exhausts the SOQL limit on a
        // long synchronous drive.
        scheduleTimeoutJobForInstance(instance);
        enqueueOrchestrator(instance.Id, null);
        return;
      }

      // Parallel logic (which was under if (isParallel))
      List<String> activeParallelSteps = instance.Current_Step__c.split(',');
      List<Workflow_Step_Execution__c> parallelExecs = [
        SELECT Step_Name__c, Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instance.Id
          AND Step_Name__c IN :activeParallelSteps
        WITH SYSTEM_MODE
      ];

      Boolean allDone = true;
      for (String ps : activeParallelSteps) {
        Boolean found = false;
        for (Workflow_Step_Execution__c pe : parallelExecs) {
          if (pe.Step_Name__c == ps && pe.Status__c == 'Completed') {
            found = true;
            break;
          }
        }
        if (!found) {
          allDone = false;
          break;
        }
      }

      if (!allDone) {
        return;
      }

      // All parallel steps completed. Proceed to Join step.
      List<Workflow_Step_Execution__c> spawningSteps = [
        SELECT Step_Name__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instance.Id
          AND Status__c = 'Completed'
          AND Step_Name__c NOT IN :activeParallelSteps
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];

      Type wflowType = Type.forName(instance.Workflow_Name__c);
      WorkflowDefinition def = (WorkflowDefinition) wflowType.newInstance();

      String spawningStepName = !spawningSteps.isEmpty()
        ? spawningSteps[0].Step_Name__c
        : '';
      StepResult mockResult = StepResult.complete(
        null,
        !spawningSteps.isEmpty() ? spawningSteps[0].Output__c : null
      );

      String nextStepName;
      if (def instanceof VersionedWorkflow) {
        nextStepName = ((VersionedWorkflow) def)
          .getNextStep(
            spawningStepName,
            mockResult,
            instance.Definition_Version__c != null
              ? (Integer) instance.Definition_Version__c
              : 1
          );
      } else {
        nextStepName = def.getNextStep(spawningStepName, mockResult);
      }

      Map<String, Object> joinInput = new Map<String, Object>();
      for (Workflow_Step_Execution__c pe : parallelExecs) {
        Object outputVal = null;
        String resolvedOutput = resolvePayload(pe.Output__c);
        if (String.isNotBlank(resolvedOutput)) {
          try {
            outputVal = JSON.deserializeUntyped(resolvedOutput);
          } catch (Exception ex) {
            System.debug(
              LoggingLevel.FINE,
              'Parallel step output was not JSON, falling back to raw string: ' +
              ex.getMessage()
            );
            outputVal = resolvedOutput;
          }
        }
        joinInput.put(pe.Step_Name__c, outputVal);
      }
      String joinInputJson = JSON.serialize(joinInput);

      if (String.isBlank(nextStepName)) {
        instance.Status__c = 'Completed';
        instance.Output__c = savePayloadIfNeeded(
          instance.Id,
          joinInputJson,
          'Output_Join'
        );
        instance.Current_Step__c = null;
        update as system instance;

        // Parent notification publishes the load-bearing Workflow_Event__e, so it
        // runs BEFORE the best-effort lifecycle publish (first claim on DML budget).
        notifyParentCompletion(instance);

        // Fire-and-forget outbound lifecycle event on terminal transition.
        WorkflowLifecyclePublisher.publish(instance);
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
      insert as system joinStepExec;

      instance.Current_Step__c = nextStepName;
      update as system instance;

      scheduleTimeoutJobForInstance(instance.Id);
      enqueueOrchestrator(instance.Id, null);
    } else if (result.action == StepResult.ActionType.YIELD) {
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

      update as system instance;

      scheduleTimeoutJobForInstance(instance.Id);
      enqueueOrchestrator(instance.Id, null);
    } else if (result.action == StepResult.ActionType.SUSPEND) {
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
      update as system instance;
    } else if (result.action == StepResult.ActionType.SLEEP) {
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
        result.sleepDurationSeconds
      );
      update as system instance;
    } else if (result.action == StepResult.ActionType.START_CHILD) {
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
        'State_ChildInfo_' +
        stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      instance.Status__c = 'Suspended';
      update as system instance;

      startChildWorkflow(
        instance.Id,
        result.childWorkflowName,
        result.childCorrelationKey,
        result.childInputJson
      );
    } else if (result.action == StepResult.ActionType.WAIT_FOR_APPROVAL) {
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
        'State_Approval_' +
        stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      instance.Status__c = 'Suspended';
      update as system instance;
    } else if (result.action == StepResult.ActionType.SPLIT) {
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
      update as system instance;

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
        Integer timeout = getStepTimeoutSeconds(ps);
        if (timeout != null && timeout > 0) {
          pe.Timeout_At__c = DateTime.now().addSeconds(timeout);
        }
        parallelExecs.add(pe);
      }
      insert as system parallelExecs;

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
    } else if (result.action == StepResult.ActionType.RETRY) {
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
            captures = (Map<String, Object>) JSON.deserializeUntyped(resolvedCaptures);
          } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to deserialize captures in retry handler: ' + e.getMessage());
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

        failWorkflowInstance(
          instance.Id,
          instance.Current_Step__c,
          'Max retries exceeded.',
          CAT_RETRIES_EXHAUSTED
        );
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
        update as system instance;
      }
    } else if (result.action == StepResult.ActionType.CONTINUE_AS_NEW) {
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
      update as system instance;

      // Resolve initial step for successor instance
      String initialStep = null;
      Datetime nextDeadline = null;
      Type wflowType = Type.forName(instance.Workflow_Name__c);
      if (wflowType != null) {
        Object defObj = wflowType.newInstance();
        if (defObj instanceof WorkflowDefinition) {
          initialStep = ((WorkflowDefinition) defObj).getInitialStep();
        }
        if (defObj instanceof ExecutionTimeoutConfigurable) {
          Integer timeoutSecs = ((ExecutionTimeoutConfigurable) defObj)
            .getExecutionTimeoutSeconds();
          if (timeoutSecs != null) {
            nextDeadline = DateTime.now().addSeconds(timeoutSecs);
          }
        }
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
        // Use the predecessor's CreatedDate (when it started) rather than
        // System.now() (when it finished). This prevents a gap: records
        // modified during the predecessor's execution window are covered by
        // the successor's query (>= predecessor start). The tradeoff is
        // bounded overlap near the boundary, which is correct at-least-once
        // behavior — the same contract Temporal/DBOS use for polling cursors.
        Previous_Run_At__c = instance.CreatedDate
      );
      try {
        insert as system nextInstance;
      } catch (DmlException ex) {
        if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
          throw new WorkflowException(
            'An active workflow already exists with correlation key: ' + newKey
          );
        }
        throw ex;
      }

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
      update as system nextInstance;

      // Pre-create the successor's first step execution log
      if (String.isNotBlank(initialStep)) {
        Workflow_Step_Execution__c nextStepExec = new Workflow_Step_Execution__c();
        nextStepExec.Workflow_Instance__c = nextInstance.Id;
        nextStepExec.Step_Name__c = initialStep;
        nextStepExec.Status__c = 'Pending';
        nextStepExec.Input__c = nextInstance.Input__c;
        nextStepExec.Retry_Count__c = 0;
        Integer timeout = getStepTimeoutSeconds(initialStep);
        if (timeout != null && timeout > 0 && !deferTimeoutForConcurrency) {
          nextStepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
        }
        insert as system nextStepExec;
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
    } else if (result.action == StepResult.ActionType.FAIL) {
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

      failWorkflowInstance(
        instance.Id,
        stepExec.Step_Name__c,
        result.failureReason,
        CAT_EXPLICIT_FAIL
      );
    }
  }

  /**
   * Rescues a workflow when the host transaction fails or hits governor limits.
   * Invoked from a System.Finalizer.
   */
  public static void handleCrash(Id instanceId, Exception ex) {
    handleCrash(instanceId, null, ex);
  }

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

    // Resolve target step name. An explicit stepName always wins. Otherwise, if the
    // instance is mid-rollback the crashing work is the top-of-stack compensation (the
    // compensation orchestrator is enqueued without a stepName), so record the crash
    // against that '_Compensate' step rather than the stale forward Current_Step__c.
    // This keeps the failed compensation in the append-only audit trail and lets the
    // resume path append a fresh attempt instead of mistaking a stale log for in-flight.
    //
    // The instance is mid-rollback when its status is Compensating/Cancelling, OR when it
    // is Suspended and its most recent step execution is a '_Compensate' attempt. The
    // latter is the sleeping/approval-gated compensation case: a compensation returned
    // SLEEP/SUSPEND/WAIT_FOR_APPROVAL, so the engine parked the instance as Suspended and
    // resumed it later via WorkflowOrchestrator(instanceId) with no stepName. runStep()
    // flips that Suspended status back to Compensating/Cancelling in-transaction (using
    // the same latest-'_Compensate' signal), but a crash rolls that flip back, leaving the
    // persisted status as Suspended here. Detect it the same way runStep() does so the
    // crash is recorded against the '_Compensate' step instead of the stale forward step.
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

    String targetStepName;
    if (String.isNotBlank(stepName)) {
      targetStepName = stepName;
    } else if (
      midRollback && String.isNotBlank(instance.Compensation_Stack__c)
    ) {
      List<String> stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
      targetStepName = stack.isEmpty()
        ? instance.Current_Step__c
        : stack[stack.size() - 1] + '_Compensate';
    } else {
      targetStepName = instance.Current_Step__c;
    }

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

    // Mark step failed first
    if (String.isNotBlank(targetStepName)) {
      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = :targetStepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      if (!stepExecs.isEmpty()) {
        Workflow_Step_Execution__c stepExec = stepExecs[0];
        stepExec.Status__c = 'Failed';
        stepExec.Error_Details__c = (ex != null
          ? ex.getMessage() + '\n' + ex.getStackTraceString()
          : 'Unknown governor limit / crash');
        saveStepExec(stepExec, true);
      } else {
        // Construct and insert the step execution log with failed status
        Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
        stepExec.Workflow_Instance__c = instanceId;
        stepExec.Step_Name__c = targetStepName;
        stepExec.Status__c = 'Failed';
        stepExec.Error_Details__c = (ex != null
          ? ex.getMessage() + '\n' + ex.getStackTraceString()
          : 'Unknown governor limit / crash');

        if (targetStepName.endsWith('_Compensate')) {
          // Crash row for a compensation step: seed from THIS step's own forward
          // execution (input/output), matching how compensation logs are seeded
          // everywhere else. Using the latest completed step overall would be wrong
          // once earlier compensations have popped — that row belongs to a step that
          // is already reversed, giving the wrong undo context on resume.
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
        } else {
          // Forward step crash: feed the previous step's output as input.
          List<Workflow_Step_Execution__c> completedSteps = [
            SELECT Output__c
            FROM Workflow_Step_Execution__c
            WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Completed'
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
          ];
          stepExec.Input__c = !completedSteps.isEmpty()
            ? completedSteps[0].Output__c
            : instance.Input__c;
        }
        saveStepExec(stepExec, true);
      }
    }

    // Use fail helper
    String errorMsg =
      'Transaction crashed: ' +
      (ex != null ? ex.getMessage() : 'Unknown governor limit');
    failWorkflowInstance(instanceId, targetStepName, errorMsg, CAT_STEP_EXCEPTION);
  }

  /**
   * True when the exception is a transient row-lock contention error
   * (UNABLE_TO_LOCK_ROW / "record currently unavailable") rather than a genuine
   * crash. These resolve on their own once the competing transaction commits, so
   * the crash handler re-drives the step instead of failing the workflow.
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
      } catch (Exception unexpected) {
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
   */
  private static Boolean scheduleTransientLockRetry(
    Workflow_Instance__c instance,
    String stepName
  ) {
    // Never resurrect an already-terminal instance: a stray late crash must fall
    // through to the (idempotent) fail path, not flip a finished run back to Suspended.
    if (
      instance.Status__c == 'Completed' ||
      instance.Status__c == 'Failed' ||
      instance.Status__c == 'Compensated' ||
      instance.Status__c == 'Cancelled' ||
      instance.Status__c == 'ContinuedAsNew'
    ) {
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
    update as system stepExec;

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
    update as system instance;

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
   * Transitions a workflow instance to Failed or Compensating state.
   */
  public static void failWorkflowInstance(
    Id instanceId,
    String stepName,
    String errorMessage
  ) {
    failWorkflowInstance(instanceId, stepName, errorMessage, CAT_UNKNOWN);
  }

  public static void failWorkflowInstance(
    Id instanceId,
    String stepName,
    String errorMessage,
    String failureCategory
  ) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Name,
        Status__c,
        Error_Message__c,
        Compensation_Stack__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Failure_Category__c
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

    // Check if there are compensations to run
    Boolean hasCompensations = false;
    if (String.isNotBlank(instance.Compensation_Stack__c)) {
      List<String> stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
      hasCompensations = !stack.isEmpty();
    }

    if (!hasCompensations) {
      instance.Status__c = 'Failed';
      instance.Failure_Category__c = failureCategory;
      instance.Error_Message__c = ('Failed at step ' +
        stepName +
        ': ' +
        errorMessage)
        .left(255);
      update as system instance;
      WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
      WorkflowLifecyclePublisher.publish(instance);
      return;
    }

    Boolean isCompensationFailure = (instance.Status__c == 'Compensating' ||
    instance.Status__c == 'Cancelling' ||
    (String.isNotBlank(stepName) && stepName.endsWith('_Compensate')));

    if (isCompensationFailure) {
      // The rollback itself could not complete. Because the failed step's entry is
      // never popped, the remaining LIFO stack is still intact here. Rather than
      // driving to a generic terminal Failed and silently abandoning the deeper
      // (un-run) compensations, park the saga in the recoverable, operator-visible
      // "rollback incomplete" condition so it can be resumed from this exact point.
      //
      // Detect the cancel phase via the engine-owned 'Cancelled by user' marker in
      // addition to the live status: when a cancel-driven rollback crashed while a
      // compensation was Suspended (sleep/approval), the in-transaction flip back to
      // 'Cancelling' was rolled back, so the persisted status is 'Suspended' but the
      // preserved Error_Message__c still carries the marker. Reading it keeps the saga on
      // the cancel path so it finishes 'Cancelled' rather than 'Compensated' on resume.
      Boolean wasCancelling =
        instance.Status__c == 'Cancelling' ||
        (instance.Error_Message__c != null &&
        instance.Error_Message__c.contains('Cancelled by user'));
      instance.Status__c = 'CompensationFailed';
      instance.Failure_Category__c = CAT_COMPENSATION_FAILED;
      instance.Error_Message__c = buildRollbackIncompleteMessage(
          wasCancelling,
          'Rollback incomplete at compensation step ' +
            stepName +
            ': ' +
            errorMessage
        )
        .left(255);
      // Clear any stale sleep/retry deadline so the watchdog cannot prematurely wake a
      // remaining SUSPEND/approval gate once the rollback is resumed.
      instance.Sleep_Until__c = null;
      instance.Async_Job_Id__c = null;
      update as system instance;
      WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
      WorkflowLifecyclePublisher.publish(instance);
      return;
    }

    instance.Status__c = 'Compensating';
    instance.Error_Message__c = ('Failed at step ' +
      stepName +
      ': ' +
      errorMessage)
      .left(255);
    preCreateFirstCompensationStep(instance);
    update as system instance;

    // Kick off rollback loop
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instance.Id));
      }
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  private static void startChildWorkflow(
    Id parentId,
    String workflowName,
    String correlationKey,
    String inputJson
  ) {
    validateCorrelationKey(correlationKey);
    if (String.isNotBlank(correlationKey)) {
      List<Workflow_Instance__c> existing = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE
          Correlation_Key__c = :correlationKey
          AND Status__c IN (
            'Pending',
            'Running',
            'Suspended',
            'CompensationFailed'
          )
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (!existing.isEmpty()) {
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' +
          correlationKey
        );
      }
    }

    Workflow_Instance__c instance = new Workflow_Instance__c();
    instance.Workflow_Name__c = workflowName;
    instance.Status__c = 'Pending';
    instance.Correlation_Key__c = correlationKey;
    instance.Parent_Instance__c = parentId;

    // Resolve child version
    Type wflowType = Type.forName(workflowName);
    if (wflowType != null) {
      Object defObj = wflowType.newInstance();
      if (defObj instanceof VersionedWorkflow) {
        instance.Definition_Version__c = ((VersionedWorkflow) defObj)
          .getLatestVersion();
      } else {
        instance.Definition_Version__c = 1;
      }
      if (defObj instanceof WorkflowDefinition) {
        instance.Current_Step__c = ((WorkflowDefinition) defObj)
          .getInitialStep();
      }
    } else {
      instance.Definition_Version__c = 1;
    }

    try {
      insert as system instance;
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' +
          correlationKey
        );
      }
      throw ex;
    }

    instance.Input__c = savePayloadIfNeeded(
      instance.Id,
      inputJson,
      'Input_Child_' + instance.Id
    );
    update as system instance;

    if (String.isNotBlank(instance.Current_Step__c)) {
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = instance.Current_Step__c;
      stepExec.Status__c = 'Pending';
      stepExec.Input__c = instance.Input__c;
      stepExec.Retry_Count__c = 0;
      insert as system stepExec;
    }

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
      update as system instance;
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
      update as system instance;
    }

    if (!Test.isRunningTest()) {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  private static void notifyParentCompletion(
    Workflow_Instance__c childInstance
  ) {
    if (childInstance.Parent_Instance__c != null) {
      Workflow_Instance__c parent = [
        SELECT Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE Id = :childInstance.Parent_Instance__c
        WITH SYSTEM_MODE
      ];

      String targetKey = String.isNotBlank(parent.Correlation_Key__c)
        ? parent.Correlation_Key__c
        : parent.Id;

      String signalName = 'ChildCompleted';
      if (String.isNotBlank(childInstance.Correlation_Key__c)) {
        signalName += ':' + childInstance.Correlation_Key__c;
      } else {
        signalName += ':' + childInstance.Id;
      }

      Workflow_Event__e event = new Workflow_Event__e(
        Workflow_Instance_Id__c = targetKey,
        Event_Type__c = 'SIGNAL:' + signalName,
        Payload__c = childInstance.Output__c
      );
      Database.SaveResult sr = EventBus.publish(event);
      if (!sr.isSuccess()) {
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
  }

  /**
   * Sends an external signal to a workflow instance by correlation key or instance ID.
   */
  public static void signal(String keyOrId, String signalName, String payload) {
    signal(keyOrId, signalName, payload, null);
  }

  /**
   * Sends an external signal with an optional caller-supplied idempotency key.
   * When idempotencyKey is non-blank, at-most-once delivery is enforced per
   * (instance, key) pair: a duplicate with the same key is swallowed as a
   * successful no-op — no error is returned and no second wake-up fires. Dedup
   * is constraint-based (unique Signal_Key__c per instance hash) so it holds
   * across concurrent transactions without adding SOQL to the hot path.
   * Passing null preserves the existing at-least-once behavior.
   */
  public static void signal(
    String keyOrId,
    String signalName,
    String payload,
    String idempotencyKey
  ) {
    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe()
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');
    Boolean isId =
      String.isNotBlank(keyOrId) &&
      idPattern.matcher(keyOrId).matches() &&
      keyOrId.startsWith(wflowPrefix);
    Id targetId = isId ? (Id) keyOrId : null;

    // A Cancel signal must also be able to reach a stalled rollback (CompensationFailed)
    // so cancellation can resume it to completion or force it terminal. Other signals keep
    // the active-only lookup — a stalled rollback is not a forward-signal target.
    Boolean isCancelSignal =
      String.isNotBlank(signalName) &&
      (signalName.equalsIgnoreCase('Cancel') ||
      signalName.equalsIgnoreCase('CancelWorkflow'));
    // 'Paused' is included in both branches so a signal reaches a parked instance:
    // a forward signal is held (Received) and re-observed on resume, and a Cancel
    // signal can still cancel a paused instance (matching the bulk signal path).
    List<String> lookupStatuses = isCancelSignal
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

    List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
    if (isId) {
      // Query by ID first to prevent matching a correlation key that equals this ID string
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

    if (instances.isEmpty()) {
      if (isCancelSignal) {
        // A keyed cancel with no active match is an idempotent no-op: either the
        // first delivery already drove the instance terminal (and a duplicate is
        // now arriving) or there is nothing to cancel. Swallow rather than throw
        // so an at-least-once redelivered keyed cancel never faults the publisher.
        if (String.isNotBlank(idempotencyKey)) {
          return;
        }
        throw new WorkflowException(
          'No active workflow found with key or ID: ' + keyOrId
        );
      }
      // Non-cancel signal with no active match: capture as Unrouted so it is
      // never silently lost and can be re-delivered by an operator.
      captureUnroutedSignals(
        new List<SignalRequest>{
          new SignalRequest(keyOrId, signalName, payload, null, idempotencyKey)
        }
      );
      return;
    }

    Workflow_Instance__c instance = instances[0];

    if (
      signalName.equalsIgnoreCase('Cancel') ||
      signalName.equalsIgnoreCase('CancelWorkflow')
    ) {
      Boolean runCompensations = parseRunCompensations(payload);
      // A keyed cancel is deduped via a Consumed tombstone so an at-least-once
      // redelivery runs cancellation at most once. The claim and the cancellation
      // share one savepoint: if cancel() fails the tombstone is rolled back so a
      // retry of the same key re-attempts cancellation rather than no-op'ing on a
      // claim for a cancel that never completed. A duplicate (DUPLICATE_VALUE on
      // the per-instance hash) is a silent no-op.
      if (String.isNotBlank(idempotencyKey)) {
        Savepoint sp = Database.setSavepoint();
        if (!claimKeyedCancel(instance.Id, signalName, idempotencyKey)) {
          return;
        }
        try {
          cancel(instance.Id, runCompensations);
        } catch (Exception e) {
          Database.rollback(sp);
          throw e;
        }
        return;
      }
      cancel(instance.Id, runCompensations);
      return;
    }

    // Insert the signal record. When a caller-supplied idempotency key is present,
    // store a per-instance-scoped hash on Signal_Key__c and catch DUPLICATE_VALUE
    // to treat a repeat delivery as an idempotent no-op (no row, no wake-up).
    Workflow_Signal__c sig = new Workflow_Signal__c();
    sig.Workflow_Instance__c = instance.Id;
    sig.Signal_Name__c = signalName;
    sig.Payload__c = payload;
    sig.Status__c = 'Received';

    if (String.isNotBlank(idempotencyKey)) {
      // Keyed delivery: the row insert and the wake-up share one savepoint. The
      // unique Signal_Key__c makes a duplicate insert a silent no-op; if the
      // wake-up then fails, the row is rolled back so a retry of the same key
      // re-inserts and re-wakes rather than no-op'ing on a Received signal left
      // stranded on a still-Suspended instance.
      sig.Signal_Key__c = deriveSignalDedupKey(instance.Id, idempotencyKey);
      Savepoint sp = Database.setSavepoint();
      try {
        insert as system sig;
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

    insert as system sig;
    wakeInstanceForSignal(instance);
  }

  /**
   * Wakes a (possibly parallel) instance to resume execution. When
   * Current_Step__c is a parallel branch list, each still-incomplete branch is
   * enqueued by its own step name: runStep returns early for a comma-separated
   * Current_Step__c with a blank stepName, so a single blank enqueue would never
   * resume a branch suspended on a signal. A serial instance is enqueued once
   * with a null stepName.
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
    if (enqueuedInstanceIds.contains(instanceId)) {
      return;
    }
    enqueuedInstanceIds.add(instanceId);
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instanceId));
      }
    } else {
      try {
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
          System.enqueueJob(new WorkflowOrchestrator(instanceId));
        } else {
          enqueueOrchestrator(instanceId, null);
        }
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.WARN,
          'Queueable enqueue failed, falling back to Platform Event: ' +
          ex.getMessage()
        );
        enqueueOrchestrator(instanceId, null);
      }
    }
  }

  /**
   * Sends external signals to multiple workflow instances in bulk.
   */
  public static void signal(List<SignalRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe()
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');
    Set<Id> ids = new Set<Id>();
    Set<String> keys = new Set<String>();

    for (SignalRequest req : requests) {
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
          cancel(cancelClaimInstIds[i], cancelClaimRunComp[i]);
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

    for (SignalRequest req : requests) {
      Workflow_Instance__c inst = instById.get(req.keyOrId);
      if (inst == null) {
        inst = instByKey.get(normalizeKey(req.keyOrId));
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
          cancel(inst.Id, parseRunCompensations(req.payload));
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
        insert as system unkeyedSignals;
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
          inst.Status__c = 'Running';
          // Disarm the wait deadline (issue #35): a signal-wake ends the current
          // wait, so any armed Sleep_Until__c (timed-wait timeout, or a plain
          // sleeper's deadline) must be cleared or the watchdog would later
          // re-select this instance and mis-route/double-wake it. The resumed
          // step re-arms its own deadline if it suspends or sleeps again.
          inst.Sleep_Until__c = null;
          instancesToUpdate.add(inst);
        }
        activeInstances.add(inst);
      }

      if (!instancesToUpdate.isEmpty()) {
        update as system instancesToUpdate;
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
        if (latestStatusByKey.get(key) == 'Completed') {
          continue; // branch already finished
        }
        if (enqueuedBranchKeys.contains(key)) {
          continue;
        }
        enqueuedBranchKeys.add(key);
        if (Test.isRunningTest()) {
          if (!disableQueueableInTest) {
            System.enqueueJob(new WorkflowOrchestrator(instId, b));
          }
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
   * Resumes a failed workflow instance from the step where it failed, resetting its state and retry counter.
   */
  public static void retryWorkflow(Id instanceId) {
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

    Boolean hasCompensations = false;
    List<String> stack = new List<String>();
    if (String.isNotBlank(instance.Compensation_Stack__c)) {
      stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
      hasCompensations = !stack.isEmpty();
    }

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

    if (String.isBlank(instance.Current_Step__c) && !hasCompensations) {
      Type wflowType = Type.forName(instance.Workflow_Name__c);
      if (wflowType != null) {
        Object defObj = wflowType.newInstance();
        if (defObj instanceof WorkflowDefinition) {
          instance.Current_Step__c = ((WorkflowDefinition) defObj)
            .getInitialStep();
          targetStepNames.add(instance.Current_Step__c);
        }
      }
    }

    // Reset the failed step's execution status to let it execute again. Bulk-load the
    // latest execution per target step in ONE query (was one SOQL per step in a loop),
    // build a name->latest map, then update the resettable ones together.
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
      if (stepExec != null && stepExec.Status__c != 'Completed') {
        stepExec.Status__c = 'Pending';
        stepExec.Retry_Count__c = 0; // reset retry counter
        stepExec.Error_Details__c = null;
        stepsToReset.add(stepExec);
      }
    }
    if (!stepsToReset.isEmpty()) {
      update as system stepsToReset;
    }

    if (hasCompensations) {
      instance.Status__c = 'Compensating';
    } else {
      instance.Status__c = 'Running';
    }
    instance.Error_Message__c = null;
    instance.Failure_Category__c = null;
    update as system instance;

    // Enqueue the orchestrator to resume execution
    if (
      hasCompensations ||
      String.isBlank(instance.Current_Step__c) ||
      !instance.Current_Step__c.contains(',')
    ) {
      if (Test.isRunningTest()) {
        if (!disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(instanceId));
        }
      } else {
        enqueueOrchestrator(instanceId, null);
      }
      return;
    }

    // Parallel forward execution retry: enqueue only incomplete branches. Reuse the
    // already-loaded step map (reset steps are now 'Pending' in memory) instead of
    // re-querying once per branch.
    for (String targetStepName : targetStepNames) {
      Workflow_Step_Execution__c stepExec = latestStepByName.get(
        targetStepName
      );
      if (stepExec == null || stepExec.Status__c != 'Completed') {
        if (Test.isRunningTest()) {
          if (!disableQueueableInTest) {
            System.enqueueJob(
              new WorkflowOrchestrator(instanceId, targetStepName)
            );
          }
        } else {
          enqueueOrchestrator(instanceId, targetStepName);
        }
      }
    }
  }

  /**
   * Builds the Error_Message for a stalled ("rollback incomplete") saga, preserving
   * the cancel-driven phase marker when applicable. The resume paths (resumeCompensation,
   * the watchdog sleep-resume, and runStep) infer whether to resume as 'Cancelling'
   * vs 'Compensating' from the presence of 'Cancelled' in this text, so a cancel-driven
   * rollback must retain that marker across the stall — otherwise a cancelled saga would
   * resume as a plain compensation and wrongly terminate as 'Compensated' instead of
   * 'Cancelled'.
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
   */
  public static void resumeCompensation(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT Id, Status__c, Compensation_Stack__c, Error_Message__c, Failure_Category__c
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
      update as system instance;
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
    update as system instance;

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
    if (!existing.isEmpty()) {
      String latestStatus = existing[0].Status__c;
      if (
        latestStatus == 'Pending' ||
        latestStatus == 'Running' ||
        latestStatus == 'Retrying'
      ) {
        return;
      }
    }

    // Seed the retry attempt. Prefer any checkpoint the failed compensation already saved
    // (a YIELD stores progress in its own Output__c → StepContext.stepStateJson), so a
    // resumed compensation continues from where it left off rather than re-running partial
    // rollback side effects from the start. Fall back to the original forward execution's
    // input/output (the initial undo context) when the failed attempt has no saved state
    // (e.g. a RETRY attempt nulls its Output before exhausting).
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

    // Carry the failed attempt's capture-once values onto the appended retry so a
    // resumed compensation replays the same once() values instead of re-invoking
    // its producers (which would drift generated undo reference numbers/timestamps
    // across operator resumes). Append-only: the prior captures are copied, never
    // mutated.
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
    insert as system compStepExec;
  }

  private static void runCompensationStep(
    Workflow_Instance__c instance,
    String reassertedStatus
  ) {
    // Determine the source of the forward executions (original completed run or this run)
    Id forwardSourceInstanceId = instance.Id;
    Id prevInstId = null;
    try {
      prevInstId = instance.Previous_Instance__c;
    } catch (SObjectException ex) {
      List<Workflow_Instance__c> temp = [
        SELECT Previous_Instance__c FROM Workflow_Instance__c WHERE Id = :instance.Id WITH SYSTEM_MODE LIMIT 1
      ];
      if (!temp.isEmpty()) {
        prevInstId = temp[0].Previous_Instance__c;
      }
    }
    if (prevInstId != null) {
      List<Workflow_Instance__c> preds = [
        SELECT Status__c FROM Workflow_Instance__c WHERE Id = :prevInstId WITH SYSTEM_MODE LIMIT 1
      ];
      if (!preds.isEmpty() && preds[0].Status__c == 'Completed') {
        forwardSourceInstanceId = prevInstId;
      }
    }

    // 1. Read the compensation stack
    if (String.isBlank(instance.Compensation_Stack__c)) {
      instance.Status__c = (instance.Status__c == 'Cancelling')
        ? 'Cancelled'
        : 'Compensated';
      instance.Current_Step__c = null;
      update as system instance;
      // Fire-and-forget outbound lifecycle event on terminal transition.
      WorkflowLifecyclePublisher.publish(instance);
      return;
    }

    List<String> stack = (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
    if (stack.isEmpty()) {
      instance.Status__c = (instance.Status__c == 'Cancelling')
        ? 'Cancelled'
        : 'Compensated';
      instance.Current_Step__c = null;
      update as system instance;
      // Fire-and-forget outbound lifecycle event on terminal transition.
      WorkflowLifecyclePublisher.publish(instance);
      return;
    }

    // 2. Get the top step to compensate (do not pop yet, only pop on success)
    String activeStepName = stack[stack.size() - 1];

    // 3. Create or retrieve the compensation step execution log with FOR UPDATE lock.
    // Load all executions so compensateVisit can be derived in Apex without an
    // extra COUNT() SOQL query.
    String compensationStepLogName = activeStepName + '_Compensate';
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

    Integer compensateVisit = 0;
    for (Workflow_Step_Execution__c exec : stepExecs) {
      if (exec.Status__c == 'Compensated' || exec.Status__c == 'Completed') {
        compensateVisit++;
      }
    }

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

    // A signal-resumed compensation: runStep detected the rollback but DEFERRED
    // the Suspended/Running -> Compensating status DML (so a CalloutStep callout
    // stays legal), so the re-queried status is still Suspended/Running. Restore
    // the in-memory compensating phase runStep computed so the guard below and the
    // terminal-status decisions use the correct phase; the DML is committed later
    // (before compensate() for an ordinary step, after it for a CalloutStep). Only
    // restore from Suspended/Running -- a status another transaction drove to a
    // terminal/failed value is left intact so the guard can early-exit on it.
    if (
      reassertedStatus != null &&
      (instance.Status__c == 'Suspended' ||
      instance.Status__c == 'Running')
    ) {
      instance.Status__c = reassertedStatus;
      instance.Async_Job_Id__c = null;
    }

    // Check early exit conditions for instance status
    if (
      instance.Status__c != 'Compensating' &&
      instance.Status__c != 'Cancelling'
    ) {
      return; // Already completed compensation or aborted
    }

    Workflow_Step_Execution__c stepExec;
    if (stepExecs.isEmpty()) {
      stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = compensationStepLogName;
      stepExec.Status__c = 'Running';
      stepExec.Retry_Count__c = 0;

      // Retrieve the original step execution to get inputs/outputs
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
        stack.remove(stack.size() - 1);
        instance.Compensation_Stack__c = JSON.serialize(stack);
        update as system instance;

        if (!stack.isEmpty()) {
          preCreateFirstCompensationStep(instance);
          scheduleTimeoutJobForInstance(instance.Id);
        }

        if (Test.isRunningTest()) {
          if (!disableQueueableInTest) {
            System.enqueueJob(new WorkflowOrchestrator(instance.Id));
          }
        } else {
          enqueueOrchestrator(instance.Id, null);
        }
        return;
      }
      stepExec.Status__c = 'Running';
    }

    // 4. Instantiate the step and execute compensate
    Type stepType = Type.forName(activeStepName);
    if (stepType == null) {
      throw new WorkflowException(
        'Could not resolve class for step compensation: ' + activeStepName
      );
    }

    Object stepInstanceObj = stepType.newInstance();
    if (!(stepInstanceObj instanceof CompensatableStep)) {
      stepExec.Status__c = 'Compensated';
      saveStepExec(stepExec);

      stack.remove(stack.size() - 1);
      instance.Compensation_Stack__c = JSON.serialize(stack);
      update as system instance;

      if (!stack.isEmpty()) {
        scheduleTimeoutJobForInstance(instance.Id);
      }

      if (Test.isRunningTest()) {
        if (!disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(instance.Id));
        }
      } else {
        enqueueOrchestrator(instance.Id, null);
      }
      return;
    }

    CompensatableStep compensatableStepInstance = (CompensatableStep) stepInstanceObj;

    // Build context for compensate
    String prevOutput = null;
    List<Workflow_Step_Execution__c> completedBefore = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :forwardSourceInstanceId
        AND Status__c = 'Completed'
        AND Step_Name__c != :activeStepName
        AND Step_Name__c != :compensationStepLogName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (!completedBefore.isEmpty()) {
      prevOutput = completedBefore[0].Output__c;
    }

    Integer attempt = stepExec.Retry_Count__c != null ? (Integer) stepExec.Retry_Count__c + 1 : 1;
    Integer maxAttempts = 1;
    Map<String, Object> capturesMap = new Map<String, Object>();
    if (compensatableStepInstance instanceof RetryConfigurable) {
      RetryPolicy policy = sanitizePolicy(((RetryConfigurable) compensatableStepInstance).getRetryPolicy());
      maxAttempts = policy.maximumAttempts;
    } else if (String.isNotBlank(stepExec.Captured_Values__c)) {
      String resolvedCaptures = resolvePayload(stepExec.Captured_Values__c);
      if (String.isNotBlank(resolvedCaptures)) {
        try {
          capturesMap = (Map<String, Object>) JSON.deserializeUntyped(resolvedCaptures);
          if (capturesMap.containsKey('__maxAttempts')) {
            maxAttempts = Integer.valueOf(capturesMap.get('__maxAttempts'));
          }
        } catch (Exception e) {
          System.debug(LoggingLevel.ERROR, 'Failed to deserialize captured values: ' + e.getMessage());
        }
      }
    }

    StepContext context = StepContext.withCapturedValuesMap(
      instance.Id,
      instance.Workflow_Name__c,
      compensationStepLogName,
      resolvePayload(stepExec.Input__c),
      resolvePayload(prevOutput),
      resolvePayload(stepExec.Output__c),
      resolvePayload(instance.Input__c),
      instance.Definition_Version__c != null
        ? (Integer) instance.Definition_Version__c
        : 1,
      compensateVisit,
      new PendingSignalSource(instance.Id),
      instance.Previous_Run_At__c,
      capturesMap,
      attempt,
      maxAttempts
    );

    // Save/Commit step execution status and set Timeout_At__c before executing compensation so watchdog can detect timeouts.
    // As in the forward execute() path, a CalloutStep performs a synchronous,
    // payload-driven callout inside compensate() and Salesforce forbids a
    // callout once the transaction holds pending DML, so defer this timeout
    // write past compensate() for a CalloutStep. The step's Timeout_At__c and
    // scheduled job were already committed when it was queued, so the watchdog
    // stays armed; the finally block reconciles the timeout afterward.
    Boolean deferPreExecDml = compensatableStepInstance instanceof CalloutStep;
    // Persist the compensating status that runStep re-asserted in memory. For an
    // ordinary step commit it now (matching the prior commit-before-compensate()
    // behavior); for a CalloutStep leave it uncommitted so the payload-driven
    // callout in compensate() below stays legal -- handleCompensationStepResult
    // writes the instance after compensate() returns. The earlier early-return
    // branches (already-terminal exec, non-CompensatableStep) commit the status
    // via their own update, so a pending re-assert is never dropped.
    if (reassertedStatus != null && !deferPreExecDml) {
      update as system instance;
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

    StepResult result;
    try {
      result = compensatableStepInstance.compensate(context);
    } catch (Exception ex) {
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
      return;
    } finally {
      if (timeoutSeconds != null && timeoutSeconds > 0) {
        stepExec.Timeout_At__c = null;
        saveStepExec(stepExec);
        cancelTimeoutJob(instance.Id, compensationStepLogName);
      }
    }

    handleCompensationStepResult(instance, stepExec, result, stack, context);
  }

  private static void handleCompensationStepResult(
    Workflow_Instance__c instance,
    Workflow_Step_Execution__c stepExec,
    StepResult result,
    List<String> stack,
    StepContext context
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
    instance = freshInstance;
    if (context != null && context.isProgressReported()) {
      String progJson = context.getProgressJson();
      instance.Progress__c = savePayloadIfNeeded(
        instance.Id,
        progJson,
        'Progress_' + (stepExec != null && String.isNotBlank(stepExec.Step_Name__c) ? stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_') : 'Default')
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

    if (result.action == StepResult.ActionType.COMPLETE) {
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
      update as system instance;

      if (!stack.isEmpty()) {
        scheduleTimeoutJobForInstance(instance.Id);
      }

      if (Test.isRunningTest()) {
        if (!disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(instance.Id));
        }
      } else {
        enqueueOrchestrator(instance.Id, null);
      }

      // Fire-and-forget outbound lifecycle event; only fires once the stack is
      // drained and the instance has reached Compensated/Cancelled. Runs LAST so
      // the load-bearing orchestrator enqueue above keeps first claim on DML budget.
      WorkflowLifecyclePublisher.publish(instance);
    } else if (result.action == StepResult.ActionType.YIELD) {
      stepExec.Status__c = 'Running';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.stepStateJson,
        'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      update as system instance;

      scheduleTimeoutJobForInstance(instance.Id);
      enqueueOrchestrator(instance.Id, null);
    } else if (result.action == StepResult.ActionType.SUSPEND) {
      if (String.isNotBlank(result.timeoutStep)) {
        System.debug(
          LoggingLevel.WARN,
          'StepResult.suspend(timeoutSeconds, timeoutStep) used from compensate() — ' +
          'timed-wait timeout is not supported in compensation steps; the timeout will not be armed.'
        );
      }
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
      update as system instance;
    } else if (result.action == StepResult.ActionType.SLEEP) {
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
          result.sleepDurationSeconds
        );
      }
      update as system instance;
    } else if (result.action == StepResult.ActionType.WAIT_FOR_APPROVAL) {
      if (String.isNotBlank(result.timeoutStep)) {
        System.debug(
          LoggingLevel.WARN,
          'StepResult.waitForApproval(..., timeoutSeconds, timeoutStep) used from compensate() — ' +
          'timed-wait timeout is not supported in compensation steps; the timeout will not be armed.'
        );
      }
      stepExec.Status__c = 'Pending';
      Map<String, Object> state = new Map<String, Object>{
        'waitingForApproval' => true,
        'approvalKey' => result.approvalKey,
        'approvalRole' => result.approvalRole
      };
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        JSON.serialize(state),
        'State_Approval_' +
        stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);
      instance.Status__c = 'Suspended';
      update as system instance;
    } else if (result.action == StepResult.ActionType.RETRY) {
      stepExec.Retry_Count__c += 1;
      // Get and sanitize retry policy
      RetryPolicy policy = sanitizePolicy(result.retryPolicy);

      Map<String, Object> captures = new Map<String, Object>();
      if (String.isNotBlank(stepExec.Captured_Values__c)) {
        String resolvedCaptures = resolvePayload(stepExec.Captured_Values__c);
        if (String.isNotBlank(resolvedCaptures)) {
          try {
            captures = (Map<String, Object>) JSON.deserializeUntyped(resolvedCaptures);
          } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to deserialize captures in compensation retry handler: ' + e.getMessage());
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
        Boolean wasCancelling = (instance.Status__c == 'Cancelling');
        instance.Status__c = 'CompensationFailed';
        instance.Failure_Category__c = CAT_COMPENSATION_FAILED;
        instance.Error_Message__c = buildRollbackIncompleteMessage(
            wasCancelling,
            'Rollback incomplete: compensation step ' +
              stepExec.Step_Name__c +
              ' failed after max retries.'
          )
          .left(255);
        // This branch was reached by the scheduled retry firing, so clear that elapsed
        // sleep deadline; otherwise a later resumed SUSPEND/approval gate would be
        // immediately re-woken by the watchdog (Sleep_Until__c <= now).
        instance.Sleep_Until__c = null;
        instance.Async_Job_Id__c = null;
        update as system instance;
        WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
        WorkflowLifecyclePublisher.publish(instance);
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
        update as system instance;
      }
    } else if (result.action == StepResult.ActionType.FAIL) {
      // A compensation step returned an explicit fail() — treat it as a deliberate
      // compensation crash: park the saga in the recoverable CompensationFailed state
      // with the author's reason, preserving the remaining LIFO stack for operator
      // resume. Same format as the RETRY-exhausted and thrown-exception paths.
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c = (result.failureDataJson != null)
        ? result.failureReason + '\nfailureData: ' + result.failureDataJson
        : result.failureReason;
      saveStepExec(stepExec);

      Boolean wasCancellingFail = (instance.Status__c == 'Cancelling');
      instance.Status__c = 'CompensationFailed';
      instance.Failure_Category__c = CAT_COMPENSATION_FAILED;
      instance.Error_Message__c = buildRollbackIncompleteMessage(
          wasCancellingFail,
          'Rollback incomplete: compensation step ' +
            stepExec.Step_Name__c +
            ' failed: ' +
            result.failureReason
        )
        .left(255);
      instance.Sleep_Until__c = null;
      instance.Async_Job_Id__c = null;
      update as system instance;
      WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
      WorkflowLifecyclePublisher.publish(instance);
    } else {
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c =
        'Unsupported compensation action: ' +
        (result != null ? result.action : null);
      saveStepExec(stepExec);

      // Remaining stack is intact; leave the saga recoverable rather than abandoning it.
      Boolean wasCancelling = (instance.Status__c == 'Cancelling');
      instance.Status__c = 'CompensationFailed';
      instance.Failure_Category__c = CAT_COMPENSATION_FAILED;
      instance.Error_Message__c = buildRollbackIncompleteMessage(
          wasCancelling,
          'Rollback incomplete: compensation step ' +
            stepExec.Step_Name__c +
            ' failed: Unsupported action.'
        )
        .left(255);
      // Clear any stale sleep/retry deadline (see the max-retries branch above).
      instance.Sleep_Until__c = null;
      instance.Async_Job_Id__c = null;
      update as system instance;
      WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
      WorkflowLifecyclePublisher.publish(instance);
    }
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
    Id forwardSourceInstanceId = instance.Id;
    Id prevInstId = null;
    try {
      prevInstId = instance.Previous_Instance__c;
    } catch (SObjectException ex) {
      List<Workflow_Instance__c> temp = [
        SELECT Previous_Instance__c FROM Workflow_Instance__c WHERE Id = :instance.Id WITH SYSTEM_MODE LIMIT 1
      ];
      if (!temp.isEmpty()) {
        prevInstId = temp[0].Previous_Instance__c;
      }
    }
    if (prevInstId != null) {
      List<Workflow_Instance__c> preds = [
        SELECT Status__c FROM Workflow_Instance__c WHERE Id = :prevInstId WITH SYSTEM_MODE LIMIT 1
      ];
      if (!preds.isEmpty() && preds[0].Status__c == 'Completed') {
        forwardSourceInstanceId = prevInstId;
      }
    }

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
    insert as system compStepExec;
  }

  private static void preCreateFirstCompensationSteps(
    List<Workflow_Instance__c> instances
  ) {
    if (instances == null || instances.isEmpty()) {
      return;
    }

    Set<Id> instanceIds = new Set<Id>();
    List<Workflow_Instance__c> validInstances = new List<Workflow_Instance__c>();
    Map<Id, String> activeStepNames = new Map<Id, String>();
    Map<Id, String> compStepNames = new Map<Id, String>();

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

      instanceIds.add(instance.Id);
      validInstances.add(instance);
      activeStepNames.put(instance.Id, activeStepName);
      compStepNames.put(instance.Id, compensationStepLogName);
    }

    if (instanceIds.isEmpty()) {
      return;
    }

    // Query existing compensation steps in bulk to avoid duplicates
    List<Workflow_Step_Execution__c> existingCompSteps = [
      SELECT Workflow_Instance__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :instanceIds
        AND Step_Name__c LIKE '%\_Compensate'
      WITH SYSTEM_MODE
    ];
    Set<String> existingKeys = new Set<String>();
    for (Workflow_Step_Execution__c step : existingCompSteps) {
      existingKeys.add(step.Workflow_Instance__c + ':' + step.Step_Name__c);
    }

    // Query original executions to map Input/Output in bulk
    List<Workflow_Step_Execution__c> originalExecs = [
      SELECT Workflow_Instance__c, Step_Name__c, Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :instanceIds
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    // Build a map of the latest execution for each step to resolve Input/Output
    Map<String, Workflow_Step_Execution__c> latestOrigExecs = new Map<String, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c exec : originalExecs) {
      String key = exec.Workflow_Instance__c + ':' + exec.Step_Name__c;
      if (!latestOrigExecs.containsKey(key)) {
        latestOrigExecs.put(key, exec);
      }
    }

    List<Workflow_Step_Execution__c> stepsToInsert = new List<Workflow_Step_Execution__c>();
    for (Workflow_Instance__c instance : validInstances) {
      String compName = compStepNames.get(instance.Id);
      String key = instance.Id + ':' + compName;
      if (existingKeys.contains(key)) {
        continue;
      }

      String activeName = activeStepNames.get(instance.Id);
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

    if (!stepsToInsert.isEmpty()) {
      insert as system stepsToInsert;
    }
  }

  /**
   * Manually triggers compensation for a completed workflow instance.
   * Validates status, copies the compensation stack, spawns a new compensating instance,
   * links it to the original instance, and runs the rollback.
   */
  public static Id compensate(Id instanceId) {
    if (instanceId == null) {
      throw new WorkflowException('Instance ID cannot be null.');
    }

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
        Input__c
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
      throw new WorkflowException('No compensation stack found on instance: ' + instanceId);
    }

    List<String> stack = (List<String>) JSON.deserialize(
      target.Compensation_Stack__c,
      List<String>.class
    );
    if (stack.isEmpty()) {
      throw new WorkflowException('Compensation stack is empty for instance: ' + instanceId);
    }

    // Spawn successor compensating instance. Carry the root correlation key forward.
    Workflow_Instance__c compensatingInstance = new Workflow_Instance__c(
      Workflow_Name__c = target.Workflow_Name__c,
      Correlation_Key__c = target.Correlation_Key__c,
      Root_Correlation_Key__c = String.isNotBlank(target.Root_Correlation_Key__c) ? target.Root_Correlation_Key__c : target.Correlation_Key__c,
      Previous_Instance__c = target.Id,
      Definition_Version__c = target.Definition_Version__c,
      Status__c = 'Compensating',
      Compensation_Stack__c = target.Compensation_Stack__c,
      Input__c = target.Input__c
    );

    insert as system compensatingInstance;

    // Link original instance to new compensating instance
    target.Compensated_By__c = compensatingInstance.Id;
    update as system target;

    // Pre-create the first compensation step execution log
    preCreateFirstCompensationStep(compensatingInstance);

    // Schedule watchdog and enqueue orchestrator
    scheduleTimeoutJobForInstance(compensatingInstance.Id);
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(compensatingInstance.Id));
      }
    } else {
      enqueueOrchestrator(compensatingInstance.Id, null);
    }

    return compensatingInstance.Id;
  }

  /**
   * Cancels a workflow instance, aborts scheduled jobs, and optionally runs saga compensations.
   */
  public static void cancel(Id instanceId, Boolean runCompensations) {
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
    WorkflowLifecyclePublisher.publish(terminallyCancelled);
  }

  /**
   * Breadth-first collection of an instance plus all of its active descendants using one
   * set-based query per tree level. Returns IDs in parent-before-child order. A `seen`
   * guard makes the traversal safe against accidental parent-reference cycles.
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
   * Cancels a single workflow instance (no descendant traversal). When throwIfMissing is
   * true the original not-found exception is preserved for the top-level target.
   *
   * Returns the instance when this call drove it to a terminal Cancelled state (the
   * no-compensation path), otherwise null. The caller (cancel()) collects these and
   * publishes one bulk lifecycle batch AFTER the whole tree is cancelled, so a
   * per-node publish can never spend the DML budget that a later child cancellation
   * still needs. (The compensation path reaches Cancelled asynchronously and emits
   * its own event from the orchestrator.)
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
    if (
      instance.Status__c == 'Completed' ||
      instance.Status__c == 'Failed' ||
      instance.Status__c == 'Compensated' ||
      instance.Status__c == 'Cancelled' ||
      instance.Status__c == 'ContinuedAsNew'
    ) {
      return null; // Already in terminal state
    }
    // Note: CompensationFailed is intentionally NOT treated as terminal here — a stalled
    // rollback is resumable and still holds un-reversed side effects, so cancellation must
    // reach it (handled explicitly below) rather than skip it.

    // Lock active step executions FOR UPDATE second
    List<Workflow_Step_Execution__c> stepExecs = new List<Workflow_Step_Execution__c>();
    if (String.isNotBlank(instance.Current_Step__c)) {
      List<String> activeStepNames = new List<String>();
      if (instance.Current_Step__c.contains(',')) {
        activeStepNames = instance.Current_Step__c.split(',');
      } else {
        activeStepNames.add(instance.Current_Step__c);
      }

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
      update as system stepExecs;
    }

    // A stalled rollback (CompensationFailed) being cancelled is handled per cancel mode:
    // with compensations requested, resume the remaining rollback under the cancel phase so
    // it drains to 'Cancelled' (every remaining side effect reversed); without, force it
    // terminal 'Cancelled', abandoning the un-run compensations but releasing its key.
    if (instance.Status__c == 'CompensationFailed') {
      List<String> remaining = new List<String>();
      if (String.isNotBlank(instance.Compensation_Stack__c)) {
        remaining = (List<String>) JSON.deserialize(
          instance.Compensation_Stack__c,
          List<String>.class
        );
      }
      if (runCompensations && !remaining.isEmpty()) {
        instance.Status__c = 'Cancelling';
        instance.Error_Message__c = 'Cancelled by user. Compensating.';
        update as system instance;

        // Append a fresh attempt for the stalled top-of-stack step (the prior Failed
        // attempt is preserved) so the existing compensation loop re-runs it.
        appendCompensationRetryStep(instance, remaining);
        scheduleTimeoutJobForInstance(instance.Id);
        if (Test.isRunningTest()) {
          if (!disableQueueableInTest) {
            System.enqueueJob(new WorkflowOrchestrator(instance.Id));
          }
        } else {
          enqueueOrchestrator(instance.Id, null);
        }
        // Not terminal yet — the orchestrator emits the lifecycle event when the
        // compensation stack drains to Cancelled.
        return null;
      } else {
        instance.Status__c = 'Cancelled';
        instance.Error_Message__c = 'Cancelled by user.';
        update as system instance;
        // Terminal immediately — hand back to cancel() for bulk lifecycle publish.
        return instance;
      }
    }

    // Check for compensations
    Boolean hasCompensations = false;
    if (runCompensations && String.isNotBlank(instance.Compensation_Stack__c)) {
      List<String> stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
      hasCompensations = !stack.isEmpty();
    }

    if (hasCompensations) {
      instance.Status__c = 'Cancelling';
      instance.Error_Message__c = 'Cancelled by user. Compensating.';
      preCreateFirstCompensationStep(instance);
      update as system instance;

      // Kick off rollback loop
      if (Test.isRunningTest()) {
        if (!disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(instance.Id));
        }
      } else {
        enqueueOrchestrator(instance.Id, null);
      }
      // Not terminal yet (Cancelling); the orchestrator emits the lifecycle event
      // when the compensation stack drains to Cancelled.
      return null;
    }

    instance.Status__c = 'Cancelled';
    instance.Error_Message__c = 'Cancelled by user.';
    update as system instance;
    // Terminal: hand the instance back to cancel() for a single bulk publish after
    // the whole descendant tree is cancelled (preserves DML headroom mid-loop).
    // Active child workflows are handled by the caller (cancel()) via iterative
    // descendant traversal, so no recursive child cancellation happens here.
    return instance;
  }

  /**
   * Aborts all Scheduled Apex cron jobs associated with the workflow instance.
   */
  public static void abortScheduledJobs(Id instanceId) {
    abortScheduledJobs(new Set<Id>{ instanceId });
  }

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
      WHERE
        CronJobDetail.Name LIKE :nameLikeFilters
      WITH SYSTEM_MODE
    ];
    for (CronTrigger triggerJob : triggers) {
      try {
        System.abortJob(triggerJob.Id);
      } catch (Exception e) {
        System.debug(
          LoggingLevel.WARN,
          'Failed to abort job ' + triggerJob.Id + ': ' + e.getMessage()
        );
      }
    }
  }

  public static void enqueueOrchestrators(List<Id> instanceIds) {
    WorkflowWatchdog.bootstrap();
    if (Test.isRunningTest()) {
      // Honor the manual-drive switch: a test that sets disableQueueableInTest is
      // driving steps itself and must observe the pre-execution state (e.g. a
      // bounded bulk start whose initial timeout is deferred until admission).
      // The scalar enqueueOrchestrator already returns early in tests; without
      // this, the bulk path's auto-run at Test.stopTest() would admit/advance the
      // very instances the test froze, defeating the assertion.
      if (disableQueueableInTest) {
        return;
      }
      for (Id instId : instanceIds) {
        try {
          if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new WorkflowOrchestrator(instId));
          }
        } catch (Exception e) {
          System.debug(
            LoggingLevel.WARN,
            'Failed to enqueue WorkflowOrchestrator for ' +
              instId +
              ': ' +
              e.getMessage()
          );
        }
      }
      return;
    }
    List<Workflow_Event__e> events = new List<Workflow_Event__e>();
    for (Id instId : instanceIds) {
      events.add(
        new Workflow_Event__e(
          Workflow_Instance_Id__c = instId,
          Event_Type__c = 'RUN_STEP',
          Payload__c = null
        )
      );
    }
    if (!events.isEmpty()) {
      List<Database.SaveResult> srs = EventBus.publish(events);
      for (Database.SaveResult sr : srs) {
        if (!sr.isSuccess()) {
          List<String> errMsgs = new List<String>();
          for (Database.Error err : sr.getErrors()) {
            errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
          }
          throw new WorkflowException(
            'Failed to publish orchestrator event: ' +
            String.join(errMsgs, ', ')
          );
        }
      }
    }
  }

  public static void enqueueOrchestrator(Id instanceId, String stepName) {
    WorkflowWatchdog.bootstrap();
    if (Test.isRunningTest()) {
      return;
    }
    Workflow_Event__e event = new Workflow_Event__e(
      Workflow_Instance_Id__c = instanceId,
      Event_Type__c = 'RUN_STEP',
      Payload__c = stepName
    );
    Database.SaveResult sr = EventBus.publish(event);
    if (!sr.isSuccess()) {
      List<String> errMsgs = new List<String>();
      for (Database.Error err : sr.getErrors()) {
        errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
      }
      throw new WorkflowException(
        'Failed to publish orchestrator event: ' + String.join(errMsgs, ', ')
      );
    }
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
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.WARN,
          'Failed to resolve offloaded payload, falling back to raw value: ' +
          ex.getMessage()
        );
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
   */
  private static List<String> resolvePayloads(List<String> rawValues) {
    Map<Integer, Id> markerDocByIndex = new Map<Integer, Id>();
    Set<Id> docIds = new Set<Id>();
    for (Integer i = 0; i < rawValues.size(); i++) {
      String v = rawValues[i];
      if (String.isNotBlank(v) && v.startsWith('{"$attachmentId":')) {
        try {
          Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(
            v
          );
          Id docId = (Id) marker.get('$attachmentId');
          markerDocByIndex.put(i, docId);
          docIds.add(docId);
        } catch (Exception ex) {
          System.debug(
            LoggingLevel.WARN,
            'Failed to parse offload marker, using raw value: ' +
            ex.getMessage()
          );
        }
      }
    }
    Map<Id, String> resolvedByDoc = new Map<Id, String>();
    if (!docIds.isEmpty()) {
      for (ContentVersion cv : [
        SELECT ContentDocumentId, VersionData
        FROM ContentVersion
        WHERE ContentDocumentId IN :docIds AND IsLatest = TRUE
        WITH SYSTEM_MODE
      ]) {
        resolvedByDoc.put(cv.ContentDocumentId, cv.VersionData.toString());
      }
    }
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
      insert as system cv;

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
        insert as system cdl;
      } catch (DmlException ex) {
        System.debug(
          LoggingLevel.FINE,
          'ContentDocumentLink insert failed with default visibility, retrying with AllUsers: ' +
          ex.getMessage()
        );
        cdl.Visibility = 'AllUsers';
        insert as system cdl;
      }

      return JSON.serialize(
        new Map<String, String>{ '$attachmentId' => docId }
      );
    }
    return textValue;
  }

  /**
   * Evaluates and resumes suspended workflows that have exceeded their sleep time,
   * and terminates active steps that have exceeded their timeout limits.
   */
  public static void processWatchdogHeartbeat() {
    Datetime now = System.now();

    // Terminal instances finalized by the timed-out-steps section below. Their
    // lifecycle events are published once at the very END of the heartbeat, after
    // ALL required work (including the sleep-resume section) is done, so the
    // best-effort publish can never spend a DML statement the resume section needs.
    List<Workflow_Instance__c> watchdogTerminalInstances = new List<Workflow_Instance__c>();

    // 1. Process Timed-out Steps. Exclude steps whose parent is Paused: a parked
    // parent is not runnable, so its step rows (e.g. parallel branch rows the SPLIT
    // path stamped with Timeout_At__c before their RUN_STEP reached the gate, or a
    // parked initial step) would otherwise be selected and skipped, wasting the
    // bounded batch and delaying real timeouts in other workflows. Resume re-arms
    // these deadlines (see reArmTimeoutsForResume).
    List<Workflow_Step_Execution__c> timedOutSteps = [
      SELECT Id, Workflow_Instance__c, Step_Name__c, Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE
        Status__c IN ('Running', 'Pending')
        AND Timeout_At__c <= :now
        AND Workflow_Instance__r.Status__c != 'Paused'
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT :WATCHDOG_TIMEOUT_BATCH_SIZE
    ];

    if (!timedOutSteps.isEmpty()) {
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
            Failure_Category__c
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

      List<Workflow_Step_Execution__c> stepsToUpdate = new List<Workflow_Step_Execution__c>();
      Map<Id, Workflow_Instance__c> instancesToUpdate = new Map<Id, Workflow_Instance__c>();
      List<Workflow_Step_Execution__c> compensationStepsToInsert = new List<Workflow_Step_Execution__c>();
      List<Id> orchestratorInstanceIds = new List<Id>();

      Set<Id> instancesNeedingCompensationInfo = new Set<Id>();
      Set<String> activeStepNamesForComp = new Set<String>();

      for (Workflow_Step_Execution__c step : timedOutSteps) {
        Workflow_Instance__c parent = parents.get(step.Workflow_Instance__c);
        if (parent == null) {
          continue;
        }
        if (
          parent.Status__c != 'Pending' &&
          parent.Status__c != 'Running' &&
          parent.Status__c != 'Compensating' &&
          parent.Status__c != 'Cancelling'
        ) {
          continue;
        }

        Workflow_Step_Execution__c lockedStep = lockedSteps.get(step.Id);
        if (lockedStep == null) {
          continue;
        }
        if (
          lockedStep.Status__c != 'Running' &&
          lockedStep.Status__c != 'Pending'
        ) {
          continue;
        }

        // Operator pause gate (mirrors WorkflowTimeoutJob): if the definition is
        // paused while the parent is still Pending/Running (handoff armed the
        // deadline before the delayed RUN_STEP reached the gate), only hold
        // pre-start Pending steps — clear their deadline so a post-resume
        // heartbeat cannot fire instantly; re-armed on park/re-run.
        // Running (stuck) steps are NOT held: the instance stays Running so
        // reArmTimeoutsForResume will not re-arm them on resume; clearing their
        // deadline here would leave them permanently unenforceable.
        // Compensating/Cancelling bypass the pause gate normally.
        if (
          (parent.Status__c == 'Pending' ||
          parent.Status__c == 'Running') &&
          WorkflowPauseGate.anyPaused() &&
          WorkflowPauseGate.isDefinitionPaused(parent.Workflow_Name__c)
        ) {
          if (lockedStep.Status__c == 'Pending') {
            lockedStep.Timeout_At__c = null;
            stepsToUpdate.add(lockedStep);
            continue;
          }
          // Running step — fall through to enforce the timeout normally
        }

        String errorMsg = (lockedStep.Status__c == 'Running')
          ? 'Step execution timed out.'
          : 'Step execution timed out before starting.';

        lockedStep.Status__c = 'Failed';
        lockedStep.Error_Details__c = errorMsg;
        lockedStep.Timeout_At__c = null;
        stepsToUpdate.add(lockedStep);

        if (!instancesToUpdate.containsKey(parent.Id)) {
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
            instancesToUpdate.put(parent.Id, parent);
          } else if (!hasCompensations) {
            parent.Status__c = 'Failed';
            parent.Failure_Category__c = CAT_TIMEOUT;
            parent.Error_Message__c =
              'Failed at step ' +
              step.Step_Name__c +
              ': ' +
              errorMsg;
            instancesToUpdate.put(parent.Id, parent);
          } else {
            parent.Status__c = 'Compensating';
            parent.Error_Message__c =
              'Failed at step ' +
              step.Step_Name__c +
              ': ' +
              errorMsg;
            instancesToUpdate.put(parent.Id, parent);

            instancesNeedingCompensationInfo.add(parent.Id);
            if (!stack.isEmpty()) {
              activeStepNamesForComp.add(stack[stack.size() - 1]);
            }
          }
        }
      }

      Map<String, Workflow_Step_Execution__c> existingCompSteps = new Map<String, Workflow_Step_Execution__c>();
      Map<String, Workflow_Step_Execution__c> originalStepsMap = new Map<String, Workflow_Step_Execution__c>();

      if (!instancesNeedingCompensationInfo.isEmpty()) {
        List<Workflow_Step_Execution__c> existing = [
          SELECT Id, Workflow_Instance__c, Step_Name__c
          FROM Workflow_Step_Execution__c
          WHERE
            Workflow_Instance__c IN :instancesNeedingCompensationInfo
            AND Step_Name__c LIKE '%\_Compensate'
          WITH SYSTEM_MODE
        ];
        for (Workflow_Step_Execution__c e : existing) {
          existingCompSteps.put(
            e.Workflow_Instance__c + ':' + e.Step_Name__c,
            e
          );
        }

        List<Workflow_Step_Execution__c> originalExecs = [
          SELECT Workflow_Instance__c, Step_Name__c, Input__c, Output__c
          FROM Workflow_Step_Execution__c
          WHERE
            Workflow_Instance__c IN :instancesNeedingCompensationInfo
            AND Step_Name__c IN :activeStepNamesForComp
          WITH SYSTEM_MODE
          ORDER BY CreatedDate DESC, Id DESC
        ];
        for (Workflow_Step_Execution__c o : originalExecs) {
          String key = o.Workflow_Instance__c + ':' + o.Step_Name__c;
          if (!originalStepsMap.containsKey(key)) {
            originalStepsMap.put(key, o);
          }
        }
      }

      for (Id instId : instancesNeedingCompensationInfo) {
        Workflow_Instance__c parent = parents.get(instId);
        List<String> stack = (List<String>) JSON.deserialize(
          parent.Compensation_Stack__c,
          List<String>.class
        );
        String activeStepName = stack[stack.size() - 1];
        String compensationStepLogName = activeStepName + '_Compensate';

        if (
          existingCompSteps.containsKey(
            parent.Id + ':' + compensationStepLogName
          )
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
        compensationStepsToInsert.add(compStepExec);
        orchestratorInstanceIds.add(parent.Id);
      }

      if (!stepsToUpdate.isEmpty()) {
        update as system stepsToUpdate;
      }
      if (!compensationStepsToInsert.isEmpty()) {
        insert as system compensationStepsToInsert;
      }
      if (!instancesToUpdate.isEmpty()) {
        update as system instancesToUpdate.values();
      }

      for (Workflow_Instance__c parent : instancesToUpdate.values()) {
        WorkflowAlertManager.sendAlert(parent, parent.Error_Message__c);
      }

      if (!orchestratorInstanceIds.isEmpty()) {
        if (Test.isRunningTest() && disableQueueableInTest) {
          // Do nothing
        } else {
          enqueueOrchestrators(orchestratorInstanceIds);
        }
      }

      // Defer lifecycle publishing to the end of the heartbeat. Only the parents
      // transitioned to a terminal state (Failed) emit — Compensating parents are
      // skipped by the publisher.
      watchdogTerminalInstances.addAll(instancesToUpdate.values());
    }

    // 1b. Process Exceeded Execution Deadlines (bounded per heartbeat).
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
      LIMIT :WATCHDOG_DEADLINE_BATCH_SIZE
      FOR UPDATE
    ];

    if (!expiredInstances.isEmpty()) {
      List<Workflow_Step_Execution__c> deadlineStepsToInsert = new List<Workflow_Step_Execution__c>();
      List<Workflow_Instance__c> instancesToFail = new List<Workflow_Instance__c>();
      List<Id> deadlineOrchestratorIds = new List<Id>();

      // Bulk abort all scheduled jobs for all expired instances
      Set<Id> expiredInstanceIds = new Set<Id>();
      for (Workflow_Instance__c inst : expiredInstances) {
        expiredInstanceIds.add(inst.Id);
      }
      abortScheduledJobs(expiredInstanceIds);

      for (Workflow_Instance__c inst : expiredInstances) {
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
        deadlineStepsToInsert.add(deadlineStep);

        if (hasCompensations) {
          inst.Status__c = 'Compensating';
          inst.Error_Message__c = 'Execution deadline exceeded';
          instancesToFail.add(inst);
          deadlineOrchestratorIds.add(inst.Id);
        } else {
          inst.Status__c = 'Failed';
          inst.Failure_Category__c = CAT_TIMEOUT;
          inst.Error_Message__c = 'Execution deadline exceeded';
          instancesToFail.add(inst);
          watchdogTerminalInstances.add(inst);
        }
      }

      if (!deadlineStepsToInsert.isEmpty()) {
        insert as system deadlineStepsToInsert;
      }

      preCreateFirstCompensationSteps(expiredInstances);

      if (!instancesToFail.isEmpty()) {
        update as system instancesToFail;
      }

      for (Workflow_Instance__c inst : instancesToFail) {
        if (inst.Status__c == 'Failed') {
          WorkflowAlertManager.sendAlert(inst, inst.Error_Message__c);
        }
      }

      if (!deadlineOrchestratorIds.isEmpty()) {
        if (Test.isRunningTest() && disableQueueableInTest) {
          // Do nothing
        } else {
          enqueueOrchestrators(deadlineOrchestratorIds);
        }
      }
    }

    // 2. Process Sleep Resumptions (bounded per heartbeat; backlog drains on subsequent
    // heartbeats so an unbounded suspended-instance backlog cannot blow row/heap limits).
    // Paused definitions are excluded at the SOQL level so paused sleepers cannot fill
    // the bounded batch and starve resumable rows from other workflows (they would be
    // re-selected and skipped every heartbeat). An org-wide '*' pause means nothing is
    // resumable, so the phase is skipped entirely.
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
          Concurrency_Slot_Held__c
        FROM Workflow_Instance__c
        WHERE
          Status__c = 'Suspended'
          AND Sleep_Until__c <= :now
          AND Workflow_Name__c NOT IN :pausedDefNames
        WITH SYSTEM_MODE
        LIMIT :WATCHDOG_RESUME_BATCH_SIZE
        FOR UPDATE
      ];
    }

    if (!readyToResume.isEmpty()) {
      Set<Id> resumeIds = new Set<Id>();
      for (Workflow_Instance__c inst : readyToResume) {
        resumeIds.add(inst.Id);
      }

      List<Workflow_Step_Execution__c> latestSteps = [
        SELECT Workflow_Instance__c, Step_Name__c, Output__c, Id, Status__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c IN :resumeIds
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
      ];

      Map<Id, Workflow_Step_Execution__c> latestStepByInstId = new Map<Id, Workflow_Step_Execution__c>();
      for (Workflow_Step_Execution__c step : latestSteps) {
        if (!latestStepByInstId.containsKey(step.Workflow_Instance__c)) {
          latestStepByInstId.put(step.Workflow_Instance__c, step);
        }
      }

      List<Id> instanceIds = new List<Id>();
      List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
      // Parallel instances (comma-separated Current_Step__c) ignore the blank-stepName
      // orchestrator enqueued below, so a branch suspended for a transient row-lock
      // retry would never re-drive off the watchdog. Collect them here to re-drive
      // their retrying branches BY NAME after the loop.
      List<Id> parallelResumeIds = new List<Id>();
      // Timed-wait fallback execs to bulk-insert after the loop (issue #35).
      List<Workflow_Step_Execution__c> timedWaitFallbackExecs = new List<Workflow_Step_Execution__c>();
      for (Workflow_Instance__c inst : readyToResume) {
        // Hold, not drop: if the definition is paused, leave the instance Suspended
        // with Sleep_Until__c intact so it re-fires on the next heartbeat after resume.
        if (
          WorkflowPauseGate.anyPaused() &&
          WorkflowPauseGate.isDefinitionPaused(inst.Workflow_Name__c)
        ) {
          continue;
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
          instanceIds.add(inst.Id);
          continue;
        }
        Workflow_Step_Execution__c latestStep = latestStepByInstId.get(inst.Id);
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
            timedWaitFallbackExecs.add(fallbackExec);
            inst.Current_Step__c = timedWaitTarget;
          }
          inst.Status__c = 'Running';
          if (
            String.isNotBlank(inst.Current_Step__c) &&
            inst.Current_Step__c.contains(',')
          ) {
            parallelResumeIds.add(inst.Id);
          }
        }
        inst.Sleep_Until__c = null;
        inst.Async_Job_Id__c = null;
        instanceIds.add(inst.Id);
        instancesToUpdate.add(inst);
      }
      if (!timedWaitFallbackExecs.isEmpty()) {
        insert as system timedWaitFallbackExecs;
      }
      if (!instancesToUpdate.isEmpty()) {
        for (Workflow_Instance__c inst : instancesToUpdate) {
          resumedInstanceIds.add(inst.Id);
        }
        update as system instancesToUpdate;
      }
      // Honor the test opt-out (mirrors the timed-out-step enqueue above) so a
      // suite asserting only the Suspended -> Running wake transition is not
      // carried to completion by a worker draining at Test.stopTest().
      if (!(Test.isRunningTest() && disableQueueableInTest)) {
        enqueueOrchestrators(instanceIds);
      }
      // For a resumed parallel instance the blank-stepName orchestrator above is a
      // no-op (runStep ignores it for a comma-separated Current_Step__c), so re-drive
      // each branch parked for a transient row-lock retry BY NAME. Scoped to Pending/
      // Running steps carrying Transient_Retry_Count__c > 0 — the durable target the
      // transient-lock backoff persists. handleCrash leaves the row Pending after a
      // rollback, or Running when the synchronous harness calls it without one, so both
      // statuses are matched; genuinely in-flight branches (count 0) and ordinary
      // fan-out steps are left untouched. The actual enqueue honors the test opt-out
      // internally (like the bulk signal path) so the query/re-arm still run under it.
      if (!parallelResumeIds.isEmpty()) {
        reDriveTransientRetryBranches(
          [
            SELECT Id, Workflow_Instance__c, Step_Name__c
            FROM Workflow_Step_Execution__c
            WHERE
              Workflow_Instance__c IN :parallelResumeIds
              AND Status__c IN ('Pending', 'Running')
              AND Transient_Retry_Count__c > 0
            WITH SYSTEM_MODE
          ]
        );
      }
    }

    // 3. Process due recurring schedules (0-slot: runs inside the watchdog heartbeat,
    // so enabling N Workflow_Schedule__c records adds 0 scheduled-job slots).
    try {
      WorkflowScheduleSweeper.sweep();
    } catch (Exception scheduleEx) {
      System.debug(
        LoggingLevel.ERROR,
        'WorkflowEngine: schedule sweep failed: ' + scheduleEx.getMessage()
      );
    }

    // 4. Reconcile concurrency slot counters. Recomputes each configured workflow's
    // in-flight count from the true number of non-terminal slot-holding instances,
    // reclaiming any slot leaked by an instance that died without releasing (crash,
    // killed transaction) so a parked instance is never starved indefinitely.
    try {
      ConcurrencyGate.reconcileAll();
    } catch (Exception concEx) {
      System.debug(
        LoggingLevel.ERROR,
        'WorkflowEngine: concurrency reconcile failed: ' + concEx.getMessage()
      );
    }

    // 5. Rescue transient-lock retry branches orphaned when a parallel sibling that
    // completed during the backoff flipped the parent out of Suspended (e.g. a
    // CompensatableStep persisting the parent as Running). The sleep-resume above only
    // selects Suspended parents, so such a retry branch would otherwise never be
    // re-driven and the workflow would hang. Sleep_Until__c survives on the instance,
    // so re-drive any due retry-marked branch under a non-terminal, non-Suspended
    // (Running) parallel parent. Best-effort like the sweeps above: a publish hiccup
    // retries on the next heartbeat (Sleep_Until__c is left intact) instead of aborting
    // the core wake/timeout work. Self-resolving — once re-driven the branch either
    // succeeds (counter resets to 0) or re-crashes back to Suspended (handled above).
    try {
      if (!WorkflowPauseGate.wildcardPaused()) {
        Set<String> orphanPausedDefs = WorkflowPauseGate.pausedNames();
        reDriveTransientRetryBranches(
          [
            SELECT Id, Workflow_Instance__c, Step_Name__c
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
            LIMIT :WATCHDOG_RESUME_BATCH_SIZE
          ]
        );
      }
    } catch (Exception orphanEx) {
      System.debug(
        LoggingLevel.ERROR,
        'WorkflowEngine: orphaned transient-retry sweep failed: ' +
        orphanEx.getMessage()
      );
    }

    // Run proactive stall detection and alerting hook
    try {
      WorkflowAlertManager.detectAndAlertStalls();
    } catch (Exception stallEx) {
      System.debug(
        LoggingLevel.ERROR,
        'WorkflowEngine: stall detection sweep failed: ' + stallEx.getMessage()
      );
    }

    // All required heartbeat work (timed-out-step failures, sleep resumptions,
    // and schedule sweeps) is now done, so the best-effort lifecycle publish
    // runs last with no risk of starving a required update/enqueue of its DML budget.
    WorkflowLifecyclePublisher.publish(watchdogTerminalInstances);
  }




  private static Integer getStepTimeoutSeconds(String stepName) {
    if (String.isBlank(stepName)) {
      return null;
    }
    String className = stepName.endsWith('_Compensate')
      ? stepName.substring(0, stepName.lastIndexOf('_Compensate'))
      : stepName;
    try {
      Type stepType = Type.forName(className);
      if (stepType != null) {
        Object stepObj = stepType.newInstance();
        if (stepObj instanceof TimeoutConfigurable) {
          return ((TimeoutConfigurable) stepObj).getTimeoutSeconds();
        }
      }
    } catch (Exception e) {
      System.debug(
        LoggingLevel.FINE,
        'Failed to instantiate type to read timeout duration for step: ' +
          className +
          ', error: ' +
          e.getMessage()
      );
    }
    return null;
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

  public static void scheduleTimeoutJobsForInstances(
    List<Workflow_Instance__c> instances
  ) {
    for (Workflow_Instance__c instance : instances) {
      if (
        instance.Status__c == 'Compensating' ||
        instance.Status__c == 'Cancelling'
      ) {
        if (String.isNotBlank(instance.Compensation_Stack__c)) {
          List<String> stack = (List<String>) JSON.deserialize(
            instance.Compensation_Stack__c,
            List<String>.class
          );
          if (!stack.isEmpty()) {
            scheduleTimeoutJobIfNeeded(
              instance.Id,
              stack[stack.size() - 1] + '_Compensate'
            );
          }
        }
      } else if (String.isNotBlank(instance.Current_Step__c)) {
        if (instance.Current_Step__c.contains(',')) {
          for (String pStep : instance.Current_Step__c.split(',')) {
            scheduleTimeoutJobIfNeeded(instance.Id, pStep.trim());
          }
        } else {
          scheduleTimeoutJobIfNeeded(instance.Id, instance.Current_Step__c);
        }
      }
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
   */
  private static void reDriveTransientRetryBranches(
    List<Workflow_Step_Execution__c> retryBranches
  ) {
    if (retryBranches == null || retryBranches.isEmpty()) {
      return;
    }
    // Re-arm only the retry-marked rows whose deadline scheduleTransientLockRetry
    // cleared for backoff (their instance is necessarily past admission, so no
    // concurrency-defer check is needed) — never every active step on the instance.
    List<Workflow_Step_Execution__c> toReArm = new List<Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c branch : retryBranches) {
      Integer timeout = getStepTimeoutSeconds(branch.Step_Name__c);
      if (timeout != null && timeout > 0) {
        toReArm.add(
          new Workflow_Step_Execution__c(
            Id = branch.Id,
            Timeout_At__c = DateTime.now().addSeconds(timeout)
          )
        );
      }
    }
    if (!toReArm.isEmpty()) {
      update as system toReArm;
    }

    List<Workflow_Event__e> branchEvents = new List<Workflow_Event__e>();
    for (Workflow_Step_Execution__c branch : retryBranches) {
      if (Test.isRunningTest()) {
        if (!disableQueueableInTest) {
          System.enqueueJob(
            new WorkflowOrchestrator(
              branch.Workflow_Instance__c,
              branch.Step_Name__c
            )
          );
        }
      } else {
        branchEvents.add(
          new Workflow_Event__e(
            Workflow_Instance_Id__c = branch.Workflow_Instance__c,
            Event_Type__c = 'RUN_STEP',
            Payload__c = branch.Step_Name__c
          )
        );
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
            'Failed to publish transient-retry branch event: ' +
            String.join(errMsgs, ', ')
          );
        }
      }
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

    // A concurrency-bounded instance that has not yet won an admission slot must NOT
    // have its initial step's deadline re-armed here. It is re-driven through the
    // admission gate (the paused-resume and watchdog wake paths both enqueue it), and
    // a deadline stamped before admission could fail the still-waiting step in the
    // backlog. The admission path itself calls this method AFTER acquiring a slot
    // (Concurrency_Slot_Held__c = true), so re-admitted steps still get re-armed.
    // Re-query the authoritative slot flag so an in-memory caller value cannot skew it.
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

    List<Workflow_Step_Execution__c> steps = [
      SELECT Id, Workflow_Instance__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :instanceIds
        AND Status__c IN ('Pending', 'Running')
      WITH SYSTEM_MODE
    ];
    List<Workflow_Step_Execution__c> toUpdate = new List<Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c step : steps) {
      if (deferIds.contains(step.Workflow_Instance__c)) {
        continue;
      }
      Integer timeout = getStepTimeoutSeconds(step.Step_Name__c);
      if (timeout != null && timeout > 0) {
        step.Timeout_At__c = DateTime.now().addSeconds(timeout);
        toUpdate.add(step);
      }
    }
    if (!toUpdate.isEmpty()) {
      update as system toUpdate;
    }
    // Schedule the dynamic timeout jobs (Schedulable/Queueable) for the genuinely
    // active step rows only. A parallel instance keeps every branch name in
    // Current_Step__c until the join, so a completed branch lingers there; driving
    // off the queried Pending/Running rows (instead of parsing Current_Step__c)
    // avoids scheduling a timeout for a completed branch that would later find no
    // active step row and wrongly fail the whole instance "before starting".
    for (Workflow_Step_Execution__c step : steps) {
      if (deferIds.contains(step.Workflow_Instance__c)) {
        continue;
      }
      scheduleTimeoutJobIfNeeded(step.Workflow_Instance__c, step.Step_Name__c);
    }
  }

  public static void scheduleTimeoutJobForInstance(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT
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

  public static void scheduleTimeoutJobIfNeeded(
    Id instanceId,
    String stepName
  ) {
    if (String.isBlank(stepName) || !useDynamicScheduling) {
      return;
    }
    try {
      Integer timeoutSeconds = getStepTimeoutSeconds(stepName);
      if (timeoutSeconds != null && timeoutSeconds > 0) {
        if (
          !Test.isRunningTest() &&
          timeoutSeconds >= 60 &&
          timeoutSeconds <= 600 &&
          Math.mod(timeoutSeconds, 60) == 0
        ) {
          if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(
              new WorkflowTimeoutJob.QueueableTimeoutJob(instanceId, stepName),
              timeoutSeconds / 60
            );
            return;
          }
        }
        WorkflowTimeoutJob job = new WorkflowTimeoutJob(instanceId, stepName);
        Datetime runTime = Datetime.now()
          .addSeconds(
            Test.isRunningTest() ? timeoutSeconds + 60 : timeoutSeconds
          );
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
    } catch (AsyncException ex) {
      System.debug(
        LoggingLevel.INFO,
        'Async timeout scheduling limit reached, relying on watchdog: ' +
        ex.getMessage()
      );
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.WARN,
        'Failed to schedule timeout job: ' + ex.getMessage()
      );
    }
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
      if (
        !Test.isRunningTest() &&
        delaySeconds >= 60 &&
        delaySeconds <= 600 &&
        Math.mod(delaySeconds, 60) == 0
      ) {
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
          return String.valueOf(
            System.enqueueJob(
              new WorkflowRetryJob.QueueableRetryJob(instanceId, stepName),
              delaySeconds / 60
            )
          );
        }
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
    } catch (AsyncException ex) {
      System.debug(
        LoggingLevel.INFO,
        'Async retry scheduling limit reached, relying on watchdog: ' +
        ex.getMessage()
      );
      return null;
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.WARN,
        'Failed to schedule retry job: ' + ex.getMessage()
      );
      return null;
    }
  }

  /**
   * Parks an instance that could not acquire a concurrency slot. It suspends with a
   * short admission-retry wake time and re-enters admission through the SAME sleep/
   * watchdog resume path used by SLEEP — no busy spin, no dropped Queueable chain. The
   * current Pending step's watchdog deadline is cleared so a parked (not-yet-executed)
   * step is never failed by the timeout sweep; admission re-arms it.
   */
  private static void parkForConcurrency(Workflow_Instance__c instance) {
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
      update as system pending;
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
    instance.Async_Job_Id__c = scheduleSleepResume(instance.Id, retrySeconds);
    update as system instance;
  }

  private static String scheduleSleepResume(
    Id instanceId,
    Integer delaySeconds
  ) {
    if (!useDynamicScheduling) {
      return null;
    }
    try {
      if (
        !Test.isRunningTest() &&
        delaySeconds >= 60 &&
        delaySeconds <= 600 &&
        Math.mod(delaySeconds, 60) == 0
      ) {
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
          return String.valueOf(
            System.enqueueJob(
              new WorkflowSleepJob.QueueableSleepJob(instanceId),
              delaySeconds / 60
            )
          );
        }
      }
      WorkflowSleepJob job = new WorkflowSleepJob(instanceId);
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
          'WorkflowSleep_' + instanceId + '_' + runTime.getTime(),
          cronStr,
          job
        )
      );
    } catch (AsyncException ex) {
      System.debug(
        LoggingLevel.INFO,
        'Async sleep scheduling limit reached, relying on watchdog: ' +
        ex.getMessage()
      );
      return null;
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.WARN,
        'Failed to schedule sleep job: ' + ex.getMessage()
      );
      return null;
    }
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
      } catch (Exception e) {
        System.debug(
          LoggingLevel.WARN,
          'Failed to cancel timeout job ' +
            triggerJob.Id +
            ': ' +
            e.getMessage()
        );
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
   */
  @TestVisible
  private static void captureUnroutedSignals(List<SignalRequest> unmatched) {
    if (unmatched == null || unmatched.isEmpty()) {
      return;
    }

    Map<String, Workflow_Signal__c> keyedRows = new Map<String, Workflow_Signal__c>();
    List<Workflow_Signal__c> unkeyedRows = new List<Workflow_Signal__c>();

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

    // First-wins: insert (allOrNone=false) and swallow per-row DUPLICATE_VALUE so
    // a duplicate capture (same key, possibly different payload/name) is a no-op
    // against the already-captured row — matching the routed keyed path — rather
    // than overwriting it the way an upsert would. Genuine errors surface.
    if (!keyedRows.isEmpty()) {
      Database.SaveResult[] srs = Database.insert(
        keyedRows.values(),
        false,
        AccessLevel.SYSTEM_MODE
      );
      String genuineError = null;
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
        if (!isDup && genuineError == null) {
          genuineError = sr.getErrors()[0].getMessage();
        }
      }
      if (genuineError != null) {
        Database.rollback(sp);
        throw new WorkflowException(
          'Failed to capture unrouted signal: ' + genuineError
        );
      }
    }
    if (!unkeyedRows.isEmpty()) {
      try {
        insert as system unkeyedRows;
      } catch (Exception e) {
        Database.rollback(sp);
        throw e;
      }
    }
  }

  /**
   * Re-delivers a captured (Unrouted) signal by correlating it to a now-active
   * workflow instance. If a match is found the signal row is re-parented
   * (Workflow_Instance__c set, Status flipped to 'Received') and the instance
   * is woken via the normal resume handoff. Returns true if a match was found,
   * false if the signal is still unmatched (safe no-op).
   */
  public static Boolean redeliverCapturedSignal(Id signalId) {
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
    if (rows.isEmpty()) {
      return false;
    }
    Workflow_Signal__c sig = rows[0];

    String keyOrId = sig.Correlation_Key__c;
    if (String.isBlank(keyOrId)) {
      return false;
    }

    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe()
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');
    Boolean isId =
      idPattern.matcher(keyOrId).matches() && keyOrId.startsWith(wflowPrefix);

    List<String> activeStatuses = new List<String>{
      'Pending',
      'Running',
      'Suspended',
      'Compensating',
      'Cancelling',
      'Paused'
    };

    List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
    if (isId) {
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

    if (instances.isEmpty()) {
      return false;
    }

    Workflow_Instance__c instance = instances[0];

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
      update as system sig;
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        // A routed delivery already claimed this instance+key, so the canonical
        // Received row exists and was (or will be) woken. This captured row is a
        // duplicate: retire it as a keyless Consumed tombstone (releasing the
        // key it could not take) rather than delivering a second copy.
        sig.Workflow_Instance__c = null;
        sig.Signal_Key__c = null;
        sig.Status__c = 'Consumed';
        update as system sig;
        return true;
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

    return true;
  }

  private static RetryPolicy sanitizePolicy(RetryPolicy policy) {
    RetryPolicy clean = new RetryPolicy();
    if (policy != null) {
      if (policy.maximumAttempts != null && policy.maximumAttempts > 0) {
        clean.maximumAttempts = policy.maximumAttempts;
      }
      if (policy.initialIntervalSeconds != null && policy.initialIntervalSeconds > 0) {
        clean.initialIntervalSeconds = policy.initialIntervalSeconds;
      }
      if (policy.backoffCoefficient != null && policy.backoffCoefficient >= 1.0) {
        clean.backoffCoefficient = policy.backoffCoefficient;
      }
    }
    return clean;
  }
}
