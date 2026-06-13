@isTest
public class RateLimiterTest {
  @isTest
  static void testRateLimiterAcquisitionAndRefill() {
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
    RateLimiter.AcquireResult resRefilled = RateLimiter.acquire('TestService');
    System.assert(resRefilled.isAllowed);
    System.assertEquals(0, resRefilled.sleepDurationSeconds);

    Test.stopTest();
  }

  @isTest
  static void testRateLimiterNoConfigException() {
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
          .contains('No rate limit configuration found for: NonExistentService')
      );
    }
    Test.stopTest();
  }
}
