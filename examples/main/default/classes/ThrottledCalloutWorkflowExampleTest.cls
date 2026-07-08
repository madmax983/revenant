@isTest
public class ThrottledCalloutWorkflowExampleTest {
  @isTest
  static void testThrottledCalloutWorkflowObeysRateLimitAndResumes() {
    ThrottledCalloutWorkflowExample.reset();

    // Mock RateLimiter config: 1 capacity, 1.0 refill rate per second
    String mockConfigJson = '{"DeveloperName":"ThrottledService","Capacity__c":1.0,"Refill_Rate_Per_Second__c":1.0}';
    Rate_Limit_Config__mdt mockConfig = (Rate_Limit_Config__mdt) JSON.deserialize(
      mockConfigJson,
      Rate_Limit_Config__mdt.class
    );
    RateLimiter.mockConfigs.put('ThrottledService', mockConfig);

    Test.startTest();
    // Start two workflow instances. Since capacity is 1, the second instance should get blocked and sleep.
    Id instId1 = WorkflowEngine.start(
      'ThrottledCalloutWorkflowExample.ThrottledCalloutWorkflow',
      'c1',
      null
    );
    Id instId2 = WorkflowEngine.start(
      'ThrottledCalloutWorkflowExample.ThrottledCalloutWorkflow',
      'c2',
      null
    );

    // Drive workflow 1
    WorkflowTestHarness.Result res1 = new WorkflowTestHarness(instId1).drive();
    System.assertEquals(
      'Completed',
      res1.status,
      'First instance should complete immediately'
    );
    System.assertEquals(
      1,
      ThrottledCalloutWorkflowExample.successfulCallouts,
      'Should have 1 successful callout'
    );
    System.assert(
      res1.reachedStep('ThrottledCalloutWorkflowExample.AcquireTokenStep'),
      'First instance should have reached AcquireTokenStep'
    );
    System.assert(
      res1.reachedStep('ThrottledCalloutWorkflowExample.ThrottledCalloutStep'),
      'First instance should have reached ThrottledCalloutStep'
    );

    // Drive workflow 2
    WorkflowTestHarness harness2 = new WorkflowTestHarness(instId2);
    harness2.disableAutoTimeSkip = true;
    WorkflowTestHarness.Result res2 = harness2.drive();

    // Assert: Throttled instance must suspend with sleep
    System.assertEquals(
      'Suspended',
      res2.status,
      'Second instance should be suspended/sleeping'
    );
    System.assert(res2.isSleeping, 'Instance 2 should be sleeping');
    System.assert(
      res2.reachedStep('ThrottledCalloutWorkflowExample.AcquireTokenStep'),
      'Second instance should have reached AcquireTokenStep'
    );
    System.assert(
      !res2.reachedStep('ThrottledCalloutWorkflowExample.ThrottledCalloutStep'),
      'Second instance should not have reached ThrottledCalloutStep while suspended'
    );

    // Advance/mock time or allow token refill:
    // Update state's Last_Refill_Time_Ms__c to 2 seconds ago to allow token refill
    Rate_Limit_State__c state = [
      SELECT Last_Refill_Time_Ms__c
      FROM Rate_Limit_State__c
      WHERE Integration_Key__c = 'ThrottledService'
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    state.Last_Refill_Time_Ms__c = state.Last_Refill_Time_Ms__c - 2000;
    update as system state;

    // Drive workflow 2 again to resume
    harness2.disableAutoTimeSkip = false;
    WorkflowTestHarness.Result res2Resume = harness2.drive();
    System.assertEquals(
      'Completed',
      res2Resume.status,
      'Second instance should complete after token refill'
    );
    System.assert(
      res2Resume.reachedStep(
        'ThrottledCalloutWorkflowExample.ThrottledCalloutStep'
      ),
      'Second instance should have reached ThrottledCalloutStep after resumption'
    );

    Test.stopTest();

    // Idempotency verification:
    // Successful callouts must be 2, callout attempts must be 2 (due to idempotencyKey)
    System.assertEquals(
      2,
      ThrottledCalloutWorkflowExample.successfulCallouts,
      'Should have exactly 2 successful callouts (one for each workflow instance)'
    );
    System.assertEquals(
      2,
      ThrottledCalloutWorkflowExample.calloutAttempts,
      'Should have exactly 2 callout attempts (each executed exactly once, no duplicates due to idempotency key)'
    );
  }
}
