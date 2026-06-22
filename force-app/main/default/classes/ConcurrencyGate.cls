/**
 * ConcurrencyGate — a durable, crash-safe semaphore that caps the number of
 * simultaneously in-flight instances of a workflow definition (issue #28).
 *
 * A slot is acquired once at admission (the first time an instance is about to
 * execute a step) and released on every terminal transition. The ceiling N is
 * declared per definition in a `Concurrency_Config__mdt` record, resolved by the
 * same DeveloperName convention as `Workflow_Alert_Config__mdt` (non-alphanumeric
 * chars -> '_', truncated to 40), with a `Default` fallback record. A workflow
 * with no matching record (and no Default) is unbounded.
 *
 * The live count lives in a `Concurrency_State__c` counter row, mutated under
 * `SELECT ... FOR UPDATE` so concurrent admissions are serialized and the ceiling
 * is never exceeded — the same locking discipline as `RateLimiter`/`Rate_Limit_State__c`.
 * Admission is a single guarded counter check, never an unbounded SOQL scan.
 *
 * Slot accounting is entirely separate from the append-only step audit trail and
 * the compensation stack.
 */
public inherited sharing class ConcurrencyGate {
  // Test-only config injection (mirrors RateLimiter.mockConfigs / WorkflowAlertManager).
  @TestVisible
  private static Map<String, Concurrency_Config__mdt> mockConfigs = new Map<String, Concurrency_Config__mdt>();

  // Per-transaction ceiling cache. Absent key = not yet resolved; present key with
  // null value = resolved-unbounded (no config). Keyed by the raw workflow name.
  @TestVisible
  private static Map<String, Integer> ceilingCache = new Map<String, Integer>();

  @TestVisible
  private static Boolean simulateDuplicateOnInsert = false;

  // Engine-internal workflows that must never be throttled — a Default config would
  // otherwise be able to starve the perpetual watchdog chain.
  private static final Set<String> EXEMPT_WORKFLOWS = new Set<String>{
    'WatchdogWorkflow'
  };

  // Instance statuses that no longer hold a slot. A slot-holder is any instance NOT
  // in this set (so the recoverable, non-terminal CompensationFailed still counts).
  private static final Set<String> TERMINAL_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled',
    'ContinuedAsNew'
  };

  public class AdmissionResult {
    // True if the instance may proceed to execute (either it took a slot, or the
    // workflow is unbounded).
    public Boolean admitted { get; private set; }
    // True only when a real slot was consumed (a ceiling is configured). When false
    // and admitted is true, the workflow is unbounded and no counter was touched.
    public Boolean slotConsumed { get; private set; }

    public AdmissionResult(Boolean admitted, Boolean slotConsumed) {
      this.admitted = admitted;
      this.slotConsumed = slotConsumed;
    }
  }

  /**
   * Resolves the configured ceiling for a workflow definition, or null when the
   * workflow is unbounded (no specific record and no Default). Cached per transaction.
   */
  public static Integer getCeiling(String workflowName) {
    if (String.isBlank(workflowName) || EXEMPT_WORKFLOWS.contains(workflowName)) {
      return null;
    }
    if (ceilingCache.containsKey(workflowName)) {
      return ceilingCache.get(workflowName);
    }

    String devName = workflowName.replaceAll('[^a-zA-Z0-9_]', '_');
    String truncatedDevName = devName.length() > 40
      ? devName.substring(0, 40)
      : devName;

    Concurrency_Config__mdt config = resolveConfig(devName, truncatedDevName);
    Integer ceiling = (config != null &&
        config.Max_Concurrent_Instances__c != null)
      ? (Integer) config.Max_Concurrent_Instances__c
      : null;
    // Fail open on a misconfigured ceiling. The CMDT field is a plain required
    // number with no positive-minimum enforcement; a 0 or negative value would make
    // `inFlight < ceiling` never true and park every instance forever. Treat any
    // non-positive ceiling as unbounded (with a warning) rather than silently
    // starving admissions — intentional blocking is what the pause feature is for.
    if (ceiling != null && ceiling < 1) {
      System.debug(
        LoggingLevel.WARN,
        'ConcurrencyGate: ignoring non-positive Max_Concurrent_Instances__c (' +
          ceiling +
          ') for ' +
          workflowName +
          '; treating as unbounded.'
      );
      ceiling = null;
    }
    ceilingCache.put(workflowName, ceiling);
    return ceiling;
  }

  private static Concurrency_Config__mdt resolveConfig(
    String devName,
    String truncatedDevName
  ) {
    // Mock configs first (test injection), matching WorkflowAlertManager ordering.
    if (mockConfigs.containsKey(devName)) {
      return mockConfigs.get(devName);
    }
    if (mockConfigs.containsKey(truncatedDevName)) {
      return mockConfigs.get(truncatedDevName);
    }
    if (mockConfigs.containsKey('Default')) {
      return mockConfigs.get('Default');
    }

    // Governor-free CMDT read: getAll() consumes NO SOQL query, unlike a SELECT on
    // the type. The admission gate resolves the ceiling on every RUN_STEP, and a
    // workflow driven through many steps within a single Apex transaction (e.g. the
    // test harness, or a synchronous re-drive chain) would otherwise let these
    // reads accumulate toward the 100-query limit. getAll() returns every record
    // keyed by DeveloperName; it omits long-text fields, but the only field we read
    // (Max_Concurrent_Instances__c, a Number) is included. Exact name wins over the
    // 40-char-truncated form, with the Default record as the final fallback.
    Map<String, Concurrency_Config__mdt> all = getNormalizedConfigs();
    Concurrency_Config__mdt config = all.get(devName.toLowerCase());
    if (config == null) {
      config = all.get(truncatedDevName.toLowerCase());
    }
    if (config == null) {
      config = all.get('default');
    }
    return config;
  }

  // Per-transaction, case-insensitive view of Concurrency_Config__mdt.getAll().
  // getAll() keys by exact DeveloperName and Apex map keys are case-sensitive, but
  // the durable state/release/reconcile paths key off the case-insensitive unique
  // Workflow_Definition__c. Re-keying by lowercase DeveloperName makes a case-variant
  // start resolve the same ceiling those paths already enforce, instead of missing
  // the specific config and silently falling back to Default/unbounded.
  private static Map<String, Concurrency_Config__mdt> normalizedConfigsByName;

  private static Map<String, Concurrency_Config__mdt> getNormalizedConfigs() {
    if (normalizedConfigsByName == null) {
      normalizedConfigsByName = new Map<String, Concurrency_Config__mdt>();
      for (
        Concurrency_Config__mdt cfg : Concurrency_Config__mdt.getAll().values()
      ) {
        normalizedConfigsByName.put(cfg.DeveloperName.toLowerCase(), cfg);
      }
    }
    return normalizedConfigsByName;
  }

  /** True when the workflow has a concurrency ceiling configured. */
  public static Boolean isConfigured(String workflowName) {
    return getCeiling(workflowName) != null;
  }

  /**
   * Attempts to acquire a slot for the workflow. For an unbounded workflow this is
   * a no-op that admits without touching any counter. For a bounded workflow it
   * locks the durable counter row and admits (incrementing) only while the live
   * count is below the ceiling.
   */
  public static AdmissionResult tryAcquire(String workflowName) {
    Integer ceiling = getCeiling(workflowName);
    if (ceiling == null) {
      return new AdmissionResult(true, false); // unbounded
    }

    Concurrency_State__c state = lockOrProvision(workflowName);
    Integer inFlight = (state.In_Flight_Count__c == null)
      ? 0
      : (Integer) state.In_Flight_Count__c;

    if (inFlight < ceiling) {
      state.In_Flight_Count__c = inFlight + 1;
      update as system state;
      return new AdmissionResult(true, true);
    }
    return new AdmissionResult(false, false);
  }

  /**
   * Releases `count` slots for the workflow (floored at zero). No-op when no counter
   * row exists. Used by the terminal-transition release path.
   */
  public static void release(String workflowName, Integer count) {
    if (String.isBlank(workflowName) || count == null || count <= 0) {
      return;
    }
    releaseBulk(new Map<String, Integer>{ workflowName => count });
  }

  /**
   * Bulk release keyed by workflow definition -> number of slots to free. Locks each
   * existing counter row once and decrements (floored at zero). Called from the
   * instance trigger so many concurrent terminal transitions decrement correctly.
   */
  public static void releaseBulk(Map<String, Integer> countsByWorkflow) {
    if (countsByWorkflow == null || countsByWorkflow.isEmpty()) {
      return;
    }
    Set<String> keys = countsByWorkflow.keySet();
    // Workflow_Definition__c is a case-insensitive unique field, so the SOQL below
    // matches a state row regardless of the casing the terminal instance was started
    // with. Apex Map lookups are case-sensitive, though, so a differently-cased key
    // would miss the count and silently skip the decrement (leaking a slot). Fold the
    // requested counts into a case-normalized map and look up by the same normalization.
    Map<String, Integer> normalizedCounts = new Map<String, Integer>();
    for (String key : keys) {
      Integer c = countsByWorkflow.get(key);
      if (c == null) {
        continue;
      }
      String nk = key.toLowerCase();
      normalizedCounts.put(
        nk,
        (normalizedCounts.containsKey(nk) ? normalizedCounts.get(nk) : 0) + c
      );
    }
    List<Concurrency_State__c> states = [
      SELECT Workflow_Definition__c, In_Flight_Count__c
      FROM Concurrency_State__c
      WHERE Workflow_Definition__c IN :keys
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    List<Concurrency_State__c> toUpdate = new List<Concurrency_State__c>();
    for (Concurrency_State__c state : states) {
      Integer current = (state.In_Flight_Count__c == null)
        ? 0
        : (Integer) state.In_Flight_Count__c;
      Integer dec = normalizedCounts.get(state.Workflow_Definition__c.toLowerCase());
      Integer next = current - (dec == null ? 0 : dec);
      state.In_Flight_Count__c = next < 0 ? 0 : next;
      toUpdate.add(state);
    }
    if (!toUpdate.isEmpty()) {
      update as system toUpdate;
    }
  }

  /**
   * Reconciles the counter for a single workflow to the true number of non-terminal
   * slot-holding instances. Reclaims slots leaked by instances that died without
   * releasing (crash / killed transaction). Heavy enough to live on the watchdog
   * sweep, never on the admission hot path.
   */
  public static void reconcile(String workflowName) {
    reconcileAll(new Set<String>{ workflowName });
  }

  /** Reconciles every existing counter row. Called by the watchdog heartbeat. */
  public static void reconcileAll() {
    reconcileAll(null);
  }

  private static void reconcileAll(Set<String> onlyWorkflows) {
    List<Concurrency_State__c> states = (onlyWorkflows == null)
      ? [
          SELECT Workflow_Definition__c, In_Flight_Count__c
          FROM Concurrency_State__c
          WITH SYSTEM_MODE
          FOR UPDATE
        ]
      : [
          SELECT Workflow_Definition__c, In_Flight_Count__c
          FROM Concurrency_State__c
          WHERE Workflow_Definition__c IN :onlyWorkflows
          WITH SYSTEM_MODE
          FOR UPDATE
        ];
    if (states.isEmpty()) {
      return;
    }

    Set<String> workflowNames = new Set<String>();
    for (Concurrency_State__c state : states) {
      workflowNames.add(state.Workflow_Definition__c);
    }

    // One aggregate yields the true non-terminal slot-holder count per workflow.
    // Key the counts case-insensitively: Workflow_Definition__c is a case-insensitive
    // unique field, so instances started with differing casing all map to one state
    // row, but a case-sensitive Apex lookup would miss them and wrongly reset the
    // counter to 0. Fold each group into a normalized (lower-cased) key, summing.
    Map<String, Integer> trueCounts = new Map<String, Integer>();
    for (AggregateResult ar : [
      SELECT Workflow_Name__c wf, COUNT(Id) cnt
      FROM Workflow_Instance__c
      WHERE
        Workflow_Name__c IN :workflowNames
        AND Concurrency_Slot_Held__c = true
        AND Status__c NOT IN :TERMINAL_STATUSES
      WITH SYSTEM_MODE
      GROUP BY Workflow_Name__c
    ]) {
      String nk = ((String) ar.get('wf')).toLowerCase();
      Integer cnt = (Integer) ar.get('cnt');
      trueCounts.put(
        nk,
        (trueCounts.containsKey(nk) ? trueCounts.get(nk) : 0) + cnt
      );
    }

    List<Concurrency_State__c> toUpdate = new List<Concurrency_State__c>();
    for (Concurrency_State__c state : states) {
      String stateKey = state.Workflow_Definition__c.toLowerCase();
      Integer truth = trueCounts.containsKey(stateKey)
        ? trueCounts.get(stateKey)
        : 0;
      if (
        state.In_Flight_Count__c == null ||
        (Integer) state.In_Flight_Count__c != truth
      ) {
        state.In_Flight_Count__c = truth;
        toUpdate.add(state);
      }
    }
    if (!toUpdate.isEmpty()) {
      update as system toUpdate;
    }
  }

  /**
   * Locks the workflow's counter row, lazily provisioning it on first use. Mirrors
   * RateLimiter's duplicate-insert race recovery: a concurrent first-use insert that
   * loses the unique-key race is caught and the winner's row is re-locked.
   */
  private static Concurrency_State__c lockOrProvision(String workflowName) {
    List<Concurrency_State__c> states;
    if (Test.isRunningTest() && simulateDuplicateOnInsert) {
      states = new List<Concurrency_State__c>();
    } else {
      states = [
        SELECT In_Flight_Count__c
        FROM Concurrency_State__c
        WHERE Workflow_Definition__c = :workflowName
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
    }
    if (!states.isEmpty()) {
      return states[0];
    }

    Concurrency_State__c state = new Concurrency_State__c(
      Workflow_Definition__c = workflowName,
      In_Flight_Count__c = 0
    );
    try {
      insert as system state;
      return state;
    } catch (DmlException e) {
      Boolean isDuplicate = e.getMessage().contains('DUPLICATE_VALUE');
      for (Integer i = 0; !isDuplicate && i < e.getNumDml(); i++) {
        if (e.getDmlType(i) == StatusCode.DUPLICATE_VALUE) {
          isDuplicate = true;
        }
      }
      if (!isDuplicate) {
        throw e;
      }
      List<Concurrency_State__c> existing = [
        SELECT In_Flight_Count__c
        FROM Concurrency_State__c
        WHERE Workflow_Definition__c = :workflowName
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
      if (existing.isEmpty()) {
        throw e;
      }
      return existing[0];
    }
  }
}
