@isTest
public class WorkflowWatchdogTest {
  @isTest
  static void testWatchdogScheduleAndQueueable() {
    Test.startTest();
    
    // Test Schedulable execution (enqueues Queueable in production, runs synchronously in tests)
    String jobId = System.schedule(
      'TestWatchdogJob',
      '0 0 0 * * ?',
      new WorkflowWatchdog()
    );
    
    // Test Queueable execution directly
    System.enqueueJob(new WorkflowWatchdog.QueueableWatchdog());
    
    Test.stopTest();
    
    // Assert that the cron job trigger exists
    CronTrigger ct = [SELECT Id, State FROM CronTrigger WHERE Id = :jobId];
    System.assertEquals('WAITING', ct.State);
  }
}
