@IsTest
public class WorkflowSchedulerTest {
  @IsTest
  static void testWorkflowSchedulerExecution() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Schedule the job
      Test.startTest();
      System.schedule(
        'TestSchedulerJob',
        '0 0 0 * * ?',
        new WorkflowScheduler(
          'WorkflowEngineTest.HappyWorkflow',
          'TestSched',
          '{"test": true}'
        )
      );
      Test.stopTest();

      // After Test.stopTest(), scheduled jobs run synchronously.
      // Assert that a Workflow_Instance__c was created
      List<Workflow_Instance__c> instances = [
        SELECT Id, Workflow_Name__c, Correlation_Key__c, Input__c, Status__c
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c LIKE 'TestSched_%'
      ];

      System.assertEquals(
        1,
        instances.size(),
        'Should have created one workflow instance'
      );
      System.assertEquals(
        'WorkflowEngineTest.HappyWorkflow',
        instances[0].Workflow_Name__c
      );
      System.assertEquals('{"test":true}', instances[0].Input__c);
    }
  }
}
