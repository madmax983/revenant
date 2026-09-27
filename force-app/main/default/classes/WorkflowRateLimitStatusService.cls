/**
 * @description Read service for the System Doctor Rate Limits panel (#61). It shows the
 * live token bucket of each Rate_Limit_Config__mdt key and uses the RateLimiter formula.
 * It writes no records and locks no rows.
 */
public inherited sharing class WorkflowRateLimitStatusService {
  private static final String STATUS_INVALID = 'INVALID';
  private static final String STATUS_THROTTLING = 'THROTTLING';
  private static final String STATUS_AVAILABLE = 'AVAILABLE';
  private static final String STATUS_IDLE = 'IDLE';

  // Row order. Bad news comes first.
  private static final List<String> STATUS_ORDER = new List<String>{
    STATUS_INVALID,
    STATUS_THROTTLING,
    STATUS_AVAILABLE,
    STATUS_IDLE
  };

  /**
   * @description Returns the live token bucket of each configured rate limit. It checks
   * the dashboard view gate first.
   * @return A map with asOfMs (the clock time in epoch ms) and rows (one map per key).
   */
  public static Map<String, Object> rateLimitStatus() {
    WorkflowDashboardSupport.checkAuthorization();
    try {
      Long nowMs = System.currentTimeMillis();
      Map<String, Rate_Limit_Config__mdt> configs = RateLimiter.configuredLimits();
      return new Map<String, Object>{
        'asOfMs' => nowMs,
        'rows' => buildRows(configs, queryStates(configs.keySet()), nowMs)
      };
    } catch (Exception ex) {
      throw new AuraHandledException(ex.getMessage());
    }
  }

  // Reads the state rows of the configured keys. The IN match ignores case. No FOR UPDATE,
  // so the read never blocks acquire().
  private static List<Rate_Limit_State__c> queryStates(Set<String> keys) {
    if (keys.isEmpty()) {
      return new List<Rate_Limit_State__c>();
    }
    return [
      SELECT Integration_Key__c, Tokens_Remaining__c, Last_Refill_Time_Ms__c
      FROM Rate_Limit_State__c
      WHERE Integration_Key__c IN :keys
      WITH SYSTEM_MODE
      LIMIT 50000
    ];
  }

  // Builds one row per config. It uses no SOQL and no clock. acquire() stores the key
  // casing of the caller, so the join ignores case.
  @TestVisible
  private static List<Map<String, Object>> buildRows(
    Map<String, Rate_Limit_Config__mdt> configs,
    List<Rate_Limit_State__c> states,
    Long nowMs
  ) {
    Map<String, Rate_Limit_State__c> stateByKey = new Map<String, Rate_Limit_State__c>();
    for (Rate_Limit_State__c state : states) {
      if (state.Integration_Key__c != null) {
        stateByKey.put(state.Integration_Key__c.toLowerCase(), state);
      }
    }
    Map<String, String> keyByLower = new Map<String, String>();
    for (String key : configs.keySet()) {
      keyByLower.put(key.toLowerCase(), key);
    }
    List<String> sortedKeys = new List<String>(keyByLower.keySet());
    sortedKeys.sort();

    Map<String, List<Map<String, Object>>> rowsByStatus = new Map<String, List<Map<String, Object>>>();
    for (String status : STATUS_ORDER) {
      rowsByStatus.put(status, new List<Map<String, Object>>());
    }
    for (String lowerKey : sortedKeys) {
      String key = keyByLower.get(lowerKey);
      Rate_Limit_Config__mdt config = configs.get(key);
      Map<String, Object> row = buildRow(
        key,
        config,
        liveTokens(config, stateByKey.get(lowerKey), nowMs)
      );
      rowsByStatus.get((String) row.get('status')).add(row);
    }

    List<Map<String, Object>> rows = new List<Map<String, Object>>();
    for (String status : STATUS_ORDER) {
      rows.addAll(rowsByStatus.get(status));
    }
    return rows;
  }

  // Returns the live tokens, or null when the key has no state row or an invalid config.
  private static Decimal liveTokens(
    Rate_Limit_Config__mdt config,
    Rate_Limit_State__c state,
    Long nowMs
  ) {
    if (state == null || !RateLimiter.isValidConfig(config)) {
      return null;
    }
    return RateLimiter.availableTokens(state, config, nowMs);
  }

  // Builds the row for one key. Status precedence: INVALID, IDLE, THROTTLING, AVAILABLE.
  // The status uses the value before rounding. The shown value rounds down.
  private static Map<String, Object> buildRow(
    String key,
    Rate_Limit_Config__mdt config,
    Decimal tokens
  ) {
    Map<String, Object> row = new Map<String, Object>{
      'integrationKey' => key,
      'capacity' => config?.Capacity__c,
      'refillRatePerSecond' => config?.Refill_Rate_Per_Second__c,
      'status' => STATUS_INVALID,
      'availableTokens' => null,
      'secondsUntilNextToken' => null
    };
    if (!RateLimiter.isValidConfig(config)) {
      return row;
    }
    if (tokens == null) {
      row.put('status', STATUS_IDLE);
      row.put('availableTokens', config.Capacity__c.setScale(2));
      return row;
    }
    row.put('availableTokens', tokens.setScale(2, System.RoundingMode.FLOOR));
    if (tokens >= 1.0) {
      row.put('status', STATUS_AVAILABLE);
      return row;
    }
    row.put('status', STATUS_THROTTLING);
    row.put(
      'secondsUntilNextToken',
      RateLimiter.secondsUntilNextToken(tokens, config)
        .round(System.RoundingMode.CEILING)
    );
    return row;
  }
}
