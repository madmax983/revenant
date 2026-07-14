/**
 * ConcurrencyConfigResolver — resolves the configured concurrency ceiling for a
 * workflow definition from `Concurrency_Config__mdt`, lifted out of
 * `ConcurrencyGate` (issue #28) to keep the admission gate below the class-level
 * complexity thresholds.
 *
 * The resolution convention is unchanged: a workflow's DeveloperName is derived by
 * replacing non-alphanumeric chars with '_' and truncating to 40, an exact match
 * wins over the truncated form, and a `Default` record is the final fallback. Reads
 * go through the governor-free `Concurrency_Config__mdt.getAll()` (re-keyed
 * case-insensitively) so the admission hot path never consumes SOQL. The per-
 * transaction ceiling cache and the normalized-config cache live here; test config
 * injection stays on `ConcurrencyGate.mockConfigs` and is threaded in as a parameter
 * so this production class never needs to reach a @TestVisible member.
 */
public inherited sharing class ConcurrencyConfigResolver {
  // Engine-internal workflows that must never be throttled — a Default config would
  // otherwise be able to starve the perpetual watchdog chain.
  private static final Set<String> EXEMPT_WORKFLOWS = new Set<String>{
    'WatchdogWorkflow'
  };

  // Per-transaction ceiling cache. Absent key = not yet resolved; present key with
  // null value = resolved-unbounded (no config). Keyed by the raw workflow name.
  private static Map<String, Integer> ceilingCache = new Map<String, Integer>();

  // Per-transaction, case-insensitive view of Concurrency_Config__mdt.getAll().
  // getAll() keys by exact DeveloperName and Apex map keys are case-sensitive, but
  // the durable state/release/reconcile paths key off the case-insensitive unique
  // Workflow_Definition__c. Re-keying by lowercase DeveloperName makes a case-variant
  // start resolve the same ceiling those paths already enforce, instead of missing
  // the specific config and silently falling back to Default/unbounded.
  private static Map<String, Concurrency_Config__mdt> normalizedConfigsByName;

  /**
   * @description Resolves the configured ceiling for a workflow definition, or null when
   * the workflow is unbounded (no specific record and no Default). Cached per transaction.
   * @param workflowName The workflow definition name to resolve a ceiling for.
   * @param mockConfigs Test-injected configs (from `ConcurrencyGate.mockConfigs`), consulted
   * before the CMDT read, matching WorkflowAlertManager ordering.
   * @return The configured positive ceiling, or null when the workflow is unbounded.
   */
  public static Integer getCeiling(
    String workflowName,
    Map<String, Concurrency_Config__mdt> mockConfigs
  ) {
    if (
      String.isBlank(workflowName) || EXEMPT_WORKFLOWS.contains(workflowName)
    ) {
      return null;
    }
    if (ceilingCache.containsKey(workflowName)) {
      return ceilingCache.get(workflowName);
    }

    String devName = workflowName.replaceAll('[^a-zA-Z0-9_]', '_');
    String truncatedDevName = devName.length() > 40
      ? devName.substring(0, 40)
      : devName;

    Concurrency_Config__mdt config = resolveConfig(
      devName,
      truncatedDevName,
      mockConfigs
    );
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
      ceiling = null;
    }
    ceilingCache.put(workflowName, ceiling);
    return ceiling;
  }

  // Resolves a config record for the derived DeveloperName forms: test mocks first
  // (exact, truncated, then Default), then the governor-free case-insensitive CMDT
  // view (exact, truncated, then Default).
  private static Concurrency_Config__mdt resolveConfig(
    String devName,
    String truncatedDevName,
    Map<String, Concurrency_Config__mdt> mockConfigs
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

  // Builds (and caches for the transaction) a case-insensitive view of every
  // Concurrency_Config__mdt record, keyed by lower-cased DeveloperName.
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
}
