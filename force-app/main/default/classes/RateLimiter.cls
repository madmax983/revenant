public inherited sharing class RateLimiter {
  // Allows unit tests to inject custom configs without database DML dependencies
  @TestVisible
  private static Map<String, Rate_Limit_Config__mdt> mockConfigs = new Map<String, Rate_Limit_Config__mdt>();

  @TestVisible
  private static Boolean simulateDuplicateOnInsert = false;

  public class AcquireResult {
    public Boolean isAllowed { get; private set; }
    public Integer sleepDurationSeconds { get; private set; }

    public AcquireResult(Boolean isAllowed, Integer sleepDurationSeconds) {
      this.isAllowed = isAllowed;
      this.sleepDurationSeconds = sleepDurationSeconds;
    }
  }

  /**
   * Cooperatively checks and consumes a token for the specified integration key.
   * Locks the state record using SELECT ... FOR UPDATE to avoid concurrency issues.
   */
  public static AcquireResult acquire(String integrationKey) {
    // 1. Resolve Config
    Rate_Limit_Config__mdt config;
    if (mockConfigs.containsKey(integrationKey)) {
      config = mockConfigs.get(integrationKey);
    } else {
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
      config = configs[0];
    }

    // Validate Config
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

    // 2. Query and Lock State Record
    List<Rate_Limit_State__c> states;
    if (Test.isRunningTest() && simulateDuplicateOnInsert) {
      states = new List<Rate_Limit_State__c>();
    } else {
      states = [
        SELECT Tokens_Remaining__c, Last_Refill_Time_Ms__c
        FROM Rate_Limit_State__c
        WHERE Integration_Key__c = :integrationKey
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
    }

    Rate_Limit_State__c state;
    Long now = System.currentTimeMillis();

    if (states.isEmpty()) {
      // Lazy-provisioning
      state = new Rate_Limit_State__c(
        Integration_Key__c = integrationKey,
        Tokens_Remaining__c = config.Capacity__c,
        Last_Refill_Time_Ms__c = now
      );
      try {
        insert as system state;
      } catch (DmlException e) {
        Boolean isDuplicate = false;
        for (Integer i = 0; i < e.getNumDml(); i++) {
          if (e.getDmlType(i) == StatusCode.DUPLICATE_VALUE) {
            isDuplicate = true;
            break;
          }
        }
        if (isDuplicate || e.getMessage().contains('DUPLICATE_VALUE')) {
          List<Rate_Limit_State__c> existingStates = [
            SELECT Tokens_Remaining__c, Last_Refill_Time_Ms__c
            FROM Rate_Limit_State__c
            WHERE Integration_Key__c = :integrationKey
            WITH SYSTEM_MODE
            FOR UPDATE
          ];
          if (!existingStates.isEmpty()) {
            state = existingStates[0];
            now = System.currentTimeMillis();
          } else {
            throw e;
          }
        } else {
          throw e;
        }
      }
    } else {
      state = states[0];
    }

    // 3. Compute Refill based on elapsed time
    Decimal elapsed = (Decimal) (now - state.Last_Refill_Time_Ms__c) / 1000.0;
    elapsed = (elapsed < 0.0) ? 0.0 : elapsed;
    Decimal calculatedTokens =
      state.Tokens_Remaining__c + (elapsed * config.Refill_Rate_Per_Second__c);
    Decimal currentTokens = Math.min(config.Capacity__c, calculatedTokens);

    // 4. Try Consumption
    if (currentTokens >= 1.0) {
      state.Tokens_Remaining__c = currentTokens - 1.0;
      state.Last_Refill_Time_Ms__c = now;
      update as system state;
      return new AcquireResult(true, 0);
    } else {
      // NOTE: We intentionally do NOT update the database record when consumption fails.
      // Bypassing database updates when throttled saves DML write statements, reducing database CPU load
      // and avoiding locking bottlenecks. The next call will calculate the elapsed time since the last
      // successful consumption (stored in Last_Refill_Time_Ms__c), which correctly refills the token bucket.

      // Calculate delay until next token is available
      Decimal waitTime =
        (1.0 - currentTokens) / config.Refill_Rate_Per_Second__c;
      Double jitter = 0.5 + (Math.random() * 1.0); // 0.5 to 1.5 seconds jitter
      Integer sleepSecs = (Integer) Math.ceil(waitTime + jitter);
      return new AcquireResult(false, sleepSecs);
    }
  }
}
