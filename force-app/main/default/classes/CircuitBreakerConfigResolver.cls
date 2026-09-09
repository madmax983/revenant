/**
 * CircuitBreakerConfigResolver — resolves the configured circuit-breaker
 * thresholds for a dependency key from `Circuit_Breaker_Config__mdt`, lifted out
 * of `CircuitBreakerGate` (issue #128) to keep the admission gate below the
 * class-level complexity thresholds, exactly as `ConcurrencyConfigResolver` sits
 * beside `ConcurrencyGate`.
 *
 * The resolution convention mirrors concurrency: a dependency key's DeveloperName
 * is derived by replacing non-alphanumeric chars with '_' and truncating to 40, an
 * exact match wins over the truncated form, and a `Default` record is the final
 * fallback. Reads go through the governor-free `Circuit_Breaker_Config__mdt.getAll()`
 * (re-keyed case-insensitively) so the admission hot path never consumes SOQL. The
 * per-transaction config cache and the normalized-config cache live here; test
 * config injection stays on `CircuitBreakerGate.mockConfigs` and is threaded in as a
 * parameter so this production class never needs to reach a @TestVisible member.
 *
 * A dependency key that resolves to no record (not even Default), or to a record
 * with a missing/non-positive required threshold, is treated as UNCONFIGURED — the
 * breaker fails open (no breaker, admit unconditionally) rather than silently
 * fast-failing every call, matching how ConcurrencyConfigResolver treats a
 * non-positive ceiling as unbounded.
 */
public inherited sharing class CircuitBreakerConfigResolver {
  // Per-transaction resolved-config cache. Absent key = not yet resolved; present
  // key with null value = resolved-unconfigured (no valid config). Keyed by the raw
  // dependency key.
  private static Map<String, Circuit_Breaker_Config__mdt> configCache = new Map<String, Circuit_Breaker_Config__mdt>();

  // Per-transaction, case-insensitive view of Circuit_Breaker_Config__mdt.getAll().
  // getAll() keys by exact DeveloperName and Apex map keys are case-sensitive, but
  // the durable state row keys off the case-insensitive unique Dependency_Key__c.
  // Re-keying by lowercase DeveloperName makes a case-variant key resolve the same
  // config the state row already shares, instead of missing the specific config and
  // silently falling back to Default/unconfigured.
  private static Map<String, Circuit_Breaker_Config__mdt> normalizedConfigsByName;

  /**
   * @description Resolves the circuit-breaker config for a dependency key, or null
   * when the dependency is unconfigured (no specific record and no Default, or a
   * misconfigured record with a missing/non-positive threshold). Cached per
   * transaction.
   * @param dependencyKey The dependency key to resolve a breaker config for.
   * @param mockConfigs Test-injected configs (from `CircuitBreakerGate.mockConfigs`),
   * consulted before the CMDT read, matching ConcurrencyConfigResolver ordering.
   * @return The matched, valid config record, or null when the dependency is unconfigured.
   */
  public static Circuit_Breaker_Config__mdt getConfig(
    String dependencyKey,
    Map<String, Circuit_Breaker_Config__mdt> mockConfigs
  ) {
    if (String.isBlank(dependencyKey)) {
      return null;
    }
    if (configCache.containsKey(dependencyKey)) {
      return configCache.get(dependencyKey);
    }

    String devName = dependencyKey.replaceAll('[^a-zA-Z0-9_]', '_');
    String truncatedDevName = devName.length() > 40
      ? devName.substring(0, 40)
      : devName;

    Circuit_Breaker_Config__mdt config = resolveConfig(
      devName,
      truncatedDevName,
      mockConfigs
    );
    // Fail open on a misconfigured record. The CMDT fields are plain required
    // numbers with no positive-minimum enforcement; a null/0/negative threshold,
    // window, open duration, or probe count would make the breaker either never
    // trip or park forever. Treat any such record as unconfigured (no breaker)
    // rather than silently fast-failing every guarded call.
    if (!isValid(config)) {
      config = null;
    }
    configCache.put(dependencyKey, config);
    return config;
  }

  // A config is usable only when every governing threshold is present and positive.
  private static Boolean isValid(Circuit_Breaker_Config__mdt config) {
    return config != null &&
      config.Failure_Threshold__c != null &&
      config.Failure_Threshold__c >= 1 &&
      config.Rolling_Window_Seconds__c != null &&
      config.Rolling_Window_Seconds__c >= 1 &&
      config.Open_Duration_Seconds__c != null &&
      config.Open_Duration_Seconds__c >= 1 &&
      config.Half_Open_Probe_Count__c != null &&
      config.Half_Open_Probe_Count__c >= 1;
  }

  // Resolves a config record for the derived DeveloperName forms: test mocks first
  // (exact, truncated, then Default), then the governor-free case-insensitive CMDT
  // view (exact, truncated, then Default).
  private static Circuit_Breaker_Config__mdt resolveConfig(
    String devName,
    String truncatedDevName,
    Map<String, Circuit_Breaker_Config__mdt> mockConfigs
  ) {
    // Mock configs first (test injection), matching ConcurrencyConfigResolver ordering.
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
    // the type. The admission gate resolves the config on every guarded RUN_STEP,
    // and a workflow driven through many guarded steps within a single Apex
    // transaction would otherwise let these reads accumulate toward the 100-query
    // limit. getAll() returns every record keyed by DeveloperName; the numeric
    // threshold fields we read are all included. Exact name wins over the
    // 40-char-truncated form, with the Default record as the final fallback.
    Map<String, Circuit_Breaker_Config__mdt> all = getNormalizedConfigs();
    Circuit_Breaker_Config__mdt config = all.get(devName.toLowerCase());
    if (config == null) {
      config = all.get(truncatedDevName.toLowerCase());
    }
    if (config == null) {
      config = all.get('default');
    }
    return config;
  }

  // Builds (and caches for the transaction) a case-insensitive view of every
  // Circuit_Breaker_Config__mdt record, keyed by lower-cased DeveloperName.
  private static Map<String, Circuit_Breaker_Config__mdt> getNormalizedConfigs() {
    if (normalizedConfigsByName == null) {
      normalizedConfigsByName = new Map<String, Circuit_Breaker_Config__mdt>();
      for (
        Circuit_Breaker_Config__mdt cfg : Circuit_Breaker_Config__mdt.getAll()
          .values()
      ) {
        normalizedConfigsByName.put(cfg.DeveloperName.toLowerCase(), cfg);
      }
    }
    return normalizedConfigsByName;
  }
}
