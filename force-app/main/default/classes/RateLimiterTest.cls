@IsTest
public class RateLimiterTest {
  @IsTest
  static void testRateLimiterAcquisitionAndRefill() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Setup config mock via JSON deserialization
      String mockConfigJson = '{"DeveloperName":"TestService","Capacity__c":5,"Refill_Rate_Per_Second__c":2.0}';
      Rate_Limit_Config__mdt mockConfig = (Rate_Limit_Config__mdt) JSON.deserialize(
        mockConfigJson,
        Rate_Limit_Config__mdt.class
      );
      RateLimiter.mockConfigs.put('TestService', mockConfig);

      Test.startTest();

      // 1. Initial acquisition should auto-provision and succeed
      RateLimiter.AcquireResult res1 = RateLimiter.acquire('TestService');
      System.assert(res1.isAllowed);
      System.assertEquals(0, res1.sleepDurationSeconds);

      // Verify state record is created
      Rate_Limit_State__c state = [
        SELECT Tokens_Remaining__c, Last_Refill_Time_Ms__c
        FROM Rate_Limit_State__c
        WHERE Integration_Key__c = 'TestService'
      ];
      System.assertEquals(4.0, state.Tokens_Remaining__c); // 5.0 - 1.0

      // Consume remaining tokens
      RateLimiter.acquire('TestService'); // Remaining: 3
      RateLimiter.acquire('TestService'); // Remaining: 2
      RateLimiter.acquire('TestService'); // Remaining: 1
      RateLimiter.acquire('TestService'); // Remaining: 0

      // 2. Next acquisition should fail and return sleep duration
      RateLimiter.AcquireResult resDenied = RateLimiter.acquire('TestService');
      System.assert(!resDenied.isAllowed);
      System.assert(
        resDenied.sleepDurationSeconds >= 1,
        'Should require at least 1 second cooldown'
      );

      // 3. Mock time elapsed by updating state record's last modified timestamp backward
      state = [
        SELECT Tokens_Remaining__c, Last_Refill_Time_Ms__c
        FROM Rate_Limit_State__c
        WHERE Integration_Key__c = 'TestService'
      ];
      state.Last_Refill_Time_Ms__c = state.Last_Refill_Time_Ms__c - 2000; // 2 seconds ago
      update state;

      // 4. Acquisition should now succeed because 2 seconds * 2.0/sec = 4.0 tokens refilled
      RateLimiter.AcquireResult resRefilled = RateLimiter.acquire(
        'TestService'
      );
      System.assert(resRefilled.isAllowed);
      System.assertEquals(0, resRefilled.sleepDurationSeconds);

      Test.stopTest();
    }
  }

  @IsTest
  static void testRateLimiterNoConfigException() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      try {
        RateLimiter.acquire('NonExistentService');
        System.assert(
          false,
          'Should have thrown WorkflowException when no configuration is found'
        );
      } catch (WorkflowEngine.WorkflowException e) {
        System.assert(
          e.getMessage()
            .contains(
              'No rate limit configuration found for: NonExistentService'
            )
        );
      }
      Test.stopTest();
    }
  }

  @IsTest
  static void testRateLimiterInvalidCapacity() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String mockConfigJson = '{"DeveloperName":"InvalidCapacityService","Capacity__c":0.5,"Refill_Rate_Per_Second__c":2.0}';
      Rate_Limit_Config__mdt mockConfig = (Rate_Limit_Config__mdt) JSON.deserialize(
        mockConfigJson,
        Rate_Limit_Config__mdt.class
      );
      RateLimiter.mockConfigs.put('InvalidCapacityService', mockConfig);

      Test.startTest();
      try {
        RateLimiter.acquire('InvalidCapacityService');
        System.assert(
          false,
          'Should have thrown WorkflowException due to invalid capacity'
        );
      } catch (WorkflowEngine.WorkflowException e) {
        System.assert(
          e.getMessage().contains('Capacity__c must be at least 1.0'),
          'Message: ' + e.getMessage()
        );
      }
      Test.stopTest();
    }
  }

  @IsTest
  static void testRateLimiterInvalidRefillRate() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String mockConfigJson = '{"DeveloperName":"InvalidRefillService","Capacity__c":5.0,"Refill_Rate_Per_Second__c":0.0}';
      Rate_Limit_Config__mdt mockConfig = (Rate_Limit_Config__mdt) JSON.deserialize(
        mockConfigJson,
        Rate_Limit_Config__mdt.class
      );
      RateLimiter.mockConfigs.put('InvalidRefillService', mockConfig);

      Test.startTest();
      try {
        RateLimiter.acquire('InvalidRefillService');
        System.assert(
          false,
          'Should have thrown WorkflowException due to invalid refill rate'
        );
      } catch (WorkflowEngine.WorkflowException e) {
        System.assert(
          e.getMessage()
            .contains('Refill_Rate_Per_Second__c must be greater than 0.0'),
          'Message: ' + e.getMessage()
        );
      }
      Test.stopTest();
    }
  }

  @IsTest
  static void testRateLimiterColdStartConcurrency() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 1. Setup valid config
      String mockConfigJson = '{"DeveloperName":"ConcurrencyService","Capacity__c":5.0,"Refill_Rate_Per_Second__c":2.0}';
      Rate_Limit_Config__mdt mockConfig = (Rate_Limit_Config__mdt) JSON.deserialize(
        mockConfigJson,
        Rate_Limit_Config__mdt.class
      );
      RateLimiter.mockConfigs.put('ConcurrencyService', mockConfig);

      // 2. Pre-insert a state record representing the concurrent transaction that already won the race.
      // Set Last_Refill_Time_Ms__c to 1 second in the future to verify that duplicate-insert recovery
      // handles clocks/race-times without producing negative elapsed calculations.
      Rate_Limit_State__c existingState = new Rate_Limit_State__c(
        Integration_Key__c = 'ConcurrencyService',
        Tokens_Remaining__c = 5.0,
        Last_Refill_Time_Ms__c = System.currentTimeMillis() + 1000 // 1 second in the future
      );
      insert existingState;

      // 3. Set the simulation flag to force the query to return empty and attempt insert
      RateLimiter.simulateDuplicateOnInsert = true;

      Test.startTest();
      // 4. Call acquire. This should:
      //    - Pretend states list is empty
      //    - Attempt to insert new Rate_Limit_State__c
      //    - Fail with DUPLICATE_VALUE DmlException
      //    - Catch it, re-query the existing record, lock it, and successfully consume a token
      RateLimiter.AcquireResult res = RateLimiter.acquire('ConcurrencyService');
      Test.stopTest();

      System.assert(
        res.isAllowed,
        'Should be allowed after recovering from concurrency'
      );

      // Verify the pre-inserted record was updated (tokens reduced by 1.0 plus any refill)
      Rate_Limit_State__c updatedState = [
        SELECT Tokens_Remaining__c
        FROM Rate_Limit_State__c
        WHERE Integration_Key__c = 'ConcurrencyService'
      ];
      // Original: 5.0. 1 second elapsed -> 2.0 refilled -> capped at Capacity (5.0).
      // Consumed 1.0 -> should be 4.0 remaining.
      System.assertEquals(4.0, updatedState.Tokens_Remaining__c);
    }
  }

  // Builds a config mock the same way the tests above do.
  private static Rate_Limit_Config__mdt config(
    String key,
    Decimal capacity,
    Decimal rate
  ) {
    return (Rate_Limit_Config__mdt) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'DeveloperName' => key,
          'Capacity__c' => capacity,
          'Refill_Rate_Per_Second__c' => rate
        }
      ),
      Rate_Limit_Config__mdt.class
    );
  }

  private static Rate_Limit_State__c state(Decimal tokens, Long lastMs) {
    return new Rate_Limit_State__c(
      Integration_Key__c = 'Any',
      Tokens_Remaining__c = tokens,
      Last_Refill_Time_Ms__c = lastMs
    );
  }

  private static final Long NOW_MS = 1790000000000L;

  /**
   * @description availableTokens adds elapsed seconds times the refill rate.
   */
  @IsTest
  static void testAvailableTokensRefillsFromElapsedTime() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Decimal tokens = RateLimiter.availableTokens(
        state(1.0, NOW_MS - 1500),
        config('K', 10, 2.0),
        NOW_MS
      );
      System.assertEquals(4.0, tokens, '1 + 1.5 s * 2/s = 4');
    }
  }

  /**
   * @description availableTokens never goes above capacity.
   */
  @IsTest
  static void testAvailableTokensCapsAtCapacity() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Decimal tokens = RateLimiter.availableTokens(
        state(9.0, NOW_MS - 10000),
        config('K', 10, 2.0),
        NOW_MS
      );
      System.assertEquals(10.0, tokens, 'Refill stops at capacity');
    }
  }

  /**
   * @description A future last-refill time counts as zero elapsed time.
   */
  @IsTest
  static void testAvailableTokensClampsFutureTimestamp() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Decimal tokens = RateLimiter.availableTokens(
        state(0.5, NOW_MS + 5000),
        config('K', 10, 2.0),
        NOW_MS
      );
      System.assertEquals(0.5, tokens, 'Negative elapsed time is clamped');
    }
  }

  /**
   * @description secondsUntilNextToken has no jitter.
   */
  @IsTest
  static void testSecondsUntilNextToken() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        0.25,
        RateLimiter.secondsUntilNextToken(0.5, config('K', 10, 2.0))
      );
      System.assertEquals(
        10.0,
        RateLimiter.secondsUntilNextToken(0.0, config('K', 10, 0.1))
      );
    }
  }

  /**
   * @description isValidConfig accepts a config only when acquire() accepts it.
   */
  @IsTest
  static void testIsValidConfigMatchesAcquire() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Map<String, Rate_Limit_Config__mdt> cases = new Map<String, Rate_Limit_Config__mdt>{
        'CapZero' => config('CapZero', 0, 1.0),
        'CapHalf' => config('CapHalf', 0.5, 1.0),
        'RateZero' => config('RateZero', 5, 0),
        'RateNegative' => config('RateNegative', 5, -1),
        'Valid' => config('Valid', 5, 1.0)
      };
      RateLimiter.mockConfigs.putAll(cases);
      System.assertEquals(false, RateLimiter.isValidConfig(null));
      for (String key : cases.keySet()) {
        Boolean acquireAccepts = true;
        try {
          RateLimiter.acquire(key);
        } catch (WorkflowEngine.WorkflowException e) {
          acquireAccepts = false;
        }
        System.assertEquals(
          acquireAccepts,
          RateLimiter.isValidConfig(cases.get(key)),
          'isValidConfig must match acquire() for ' + key
        );
      }
    }
  }

  /**
   * @description configuredLimits returns the test mocks when they exist.
   */
  @IsTest
  static void testConfiguredLimitsUsesMocks() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      RateLimiter.mockConfigs.put('MockOnly', config('MockOnly', 3, 1.0));
      Map<String, Rate_Limit_Config__mdt> configs = RateLimiter.configuredLimits();
      System.assertEquals(1, configs.size(), 'Mocks replace the CMDT records');
      System.assert(configs.containsKey('MockOnly'));
    }
  }

  /**
   * @description configuredLimits reads the CMDT records when no mocks exist.
   */
  @IsTest
  static void testConfiguredLimitsReadsCmdtWithoutMocks() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      RateLimiter.mockConfigs.clear();
      Map<String, Rate_Limit_Config__mdt> configs = RateLimiter.configuredLimits();
      System.assertNotEquals(null, configs);
      for (Rate_Limit_Config__mdt c : configs.values()) {
        System.assertNotEquals(null, c.DeveloperName);
      }
    }
  }
}
