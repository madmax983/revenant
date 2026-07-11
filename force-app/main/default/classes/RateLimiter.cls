public inherited sharing class RateLimiter {
  // Allows unit tests to inject custom configs without database DML dependencies
  @TestVisible
  private static Map<String, Rate_Limit_Config__mdt> mockConfigs = new Map<String, Rate_Limit_Config__mdt>();

  @TestVisible
  private static Boolean simulateDuplicateOnInsert = false;

  public class AcquireResult {
    public Boolean isAllowed { get; private set; }
    public Integer sleepDurationSeconds { get; private set; }

    // Constructed only through the intent-named factories below.
    private AcquireResult() {
      this.isAllowed = false;
      this.sleepDurationSeconds = 0;
    }

    // A token was consumed; the caller may proceed immediately.
    public static AcquireResult allowed() {
      AcquireResult r = new AcquireResult();
      r.isAllowed = true;
      r.sleepDurationSeconds = 0;
      return r;
    }

    // No token available; the caller should back off for sleepDurationSeconds.
    public static AcquireResult throttled(Integer sleepDurationSeconds) {
      AcquireResult r = new AcquireResult();
      r.isAllowed = false;
      r.sleepDurationSeconds = sleepDurationSeconds;
      return r;
    }
  }

  /**
   * Cooperatively checks and consumes a token for the specified integration key.
   * Locks the state record using SELECT ... FOR UPDATE to avoid concurrency issues.
   */
  public static AcquireResult acquire(String integrationKey) {
    // 1. Resolve + validate config
    Rate_Limit_Config__mdt config = resolveConfig(integrationKey);
    validateConfig(config);

    // 2. Query and lock the state record (lazy-provisioning on first use)
    List<Rate_Limit_State__c> states = lockState(integrationKey);
    Long now = System.currentTimeMillis();
    Rate_Limit_State__c state;
    if (states.isEmpty()) {
      state = new Rate_Limit_State__c(
        Integration_Key__c = integrationKey,
        Tokens_Remaining__c = config.Capacity__c,
        Last_Refill_Time_Ms__c = now
      );
      try {
        insert as system state;
      } catch (DmlException e) {
        state = recoverFromDuplicate(e, integrationKey);
        now = System.currentTimeMillis();
      }
    } else {
      state = states[0];
    }

    // 3. Refill based on elapsed time and 4. try consumption
    return refillAndConsume(state, config, now);
  }

  // Resolves the rate-limit config for the key, preferring an injected mock over the
  // CMDT record. Throws when no configuration exists.
  private static Rate_Limit_Config__mdt resolveConfig(String integrationKey) {
    if (mockConfigs.containsKey(integrationKey)) {
      return mockConfigs.get(integrationKey);
    }
    List<Rate_Limit_Config__mdt> configs = [
      SELECT Capacity__c, Refill_Rate_Per_Second__c
      FROM Rate_Limit_Config__mdt
      WHERE DeveloperName = :integrationKey
      WITH SYSTEM_MODE
    ];
    if (configs.isEmpty()) {
      throw new WorkflowEngine.WorkflowException(
        'No rate limit configuration found for: ' + integrationKey
      );
    }
    return configs[0];
  }

  private static void validateConfig(Rate_Limit_Config__mdt config) {
    if (config.Capacity__c < 1.0) {
      throw new WorkflowEngine.WorkflowException(
        'Capacity__c must be at least 1.0'
      );
    }
    if (config.Refill_Rate_Per_Second__c <= 0.0) {
      throw new WorkflowEngine.WorkflowException(
        'Refill_Rate_Per_Second__c must be greater than 0.0'
      );
    }
  }

  // Locks the state row for the key (empty list = none yet). Honors the test hook that
  // simulates a lost provision race by returning no row.
  private static List<Rate_Limit_State__c> lockState(String integrationKey) {
    if (Test.isRunningTest() && simulateDuplicateOnInsert) {
      return new List<Rate_Limit_State__c>();
    }
    return [
      SELECT Tokens_Remaining__c, Last_Refill_Time_Ms__c
      FROM Rate_Limit_State__c
      WHERE Integration_Key__c = :integrationKey
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
  }

  // Recovers from a concurrent first-use insert that lost the unique-key race: on a
  // DUPLICATE_VALUE the winner's row is re-locked and returned; any other DML error is
  // rethrown.
  private static Rate_Limit_State__c recoverFromDuplicate(
    DmlException e,
    String integrationKey
  ) {
    Boolean isDuplicate = false;
    for (Integer i = 0; i < e.getNumDml(); i++) {
      if (e.getDmlType(i) == StatusCode.DUPLICATE_VALUE) {
        isDuplicate = true;
        break;
      }
    }
    if (!isDuplicate && !e.getMessage().contains('DUPLICATE_VALUE')) {
      throw e;
    }
    List<Rate_Limit_State__c> existingStates = [
      SELECT Tokens_Remaining__c, Last_Refill_Time_Ms__c
      FROM Rate_Limit_State__c
      WHERE Integration_Key__c = :integrationKey
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (existingStates.isEmpty()) {
      throw e;
    }
    return existingStates[0];
  }

  // Refills the bucket for elapsed time and consumes one token when available.
  private static AcquireResult refillAndConsume(
    Rate_Limit_State__c state,
    Rate_Limit_Config__mdt config,
    Long now
  ) {
    Decimal elapsed = (Decimal) (now - state.Last_Refill_Time_Ms__c) / 1000.0;
    elapsed = (elapsed < 0.0) ? 0.0 : elapsed;
    Decimal calculatedTokens =
      state.Tokens_Remaining__c + (elapsed * config.Refill_Rate_Per_Second__c);
    Decimal currentTokens = Math.min(config.Capacity__c, calculatedTokens);

    if (currentTokens >= 1.0) {
      state.Tokens_Remaining__c = currentTokens - 1.0;
      state.Last_Refill_Time_Ms__c = now;
      update as system state;
      return AcquireResult.allowed();
    }

    // NOTE: We intentionally do NOT update the database record when consumption fails.
    // Bypassing database updates when throttled saves DML write statements, reducing
    // database CPU load and avoiding locking bottlenecks. The next call will calculate
    // the elapsed time since the last successful consumption (stored in
    // Last_Refill_Time_Ms__c), which correctly refills the token bucket.

    // Calculate delay until next token is available
    Decimal waitTime = (1.0 - currentTokens) / config.Refill_Rate_Per_Second__c;
    Double jitter = 0.5 + (Math.random() * 1.0); // 0.5 to 1.5 seconds jitter
    Integer sleepSecs = (Integer) Math.ceil(waitTime + jitter);
    return AcquireResult.throttled(sleepSecs);
  }
}
