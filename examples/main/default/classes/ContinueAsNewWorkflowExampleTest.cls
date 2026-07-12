@IsTest
public class ContinueAsNewWorkflowExampleTest {
  @IsTest
  static void testPollerWorkflowContinueAsNew() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // ContinueAsNew chains produce independent successor instances. Each run gets
      // its own harness — the prior run's instance is terminal (ContinuedAsNew), so
      // it cannot be driven further.
      Test.startTest();
      Id run1Id = WorkflowEngine.start(
        'ContinueAsNewWorkflowExample.PollerWorkflow',
        'PollerKey',
        0,
        new Map<String, String>{ 'poller_type' => 'daily' }
      );
      WorkflowTestHarness.Result run1Result = new WorkflowTestHarness(run1Id)
        .drive();
      System.assertEquals('ContinuedAsNew', run1Result.status);

      Workflow_Instance__c run2 = [
        SELECT Id, Status__c, Correlation_Key__c, Input__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :run1Id
      ];
      System.assertEquals('Pending', run2.Status__c);
      System.assertEquals('PollerKey_run2', run2.Correlation_Key__c);
      System.assertEquals('1', run2.Input__c);

      List<Workflow_Search_Attribute__c> run2Attrs = [
        SELECT Key__c, Value__c
        FROM Workflow_Search_Attribute__c
        WHERE Workflow_Instance__c = :run2.Id
      ];
      System.assertEquals(
        1,
        run2Attrs.size(),
        'Successor run2 should inherit predecessor attributes'
      );
      System.assertEquals('poller_type', run2Attrs[0].Key__c);
      System.assertEquals('daily', run2Attrs[0].Value__c);

      WorkflowTestHarness.Result run2Result = new WorkflowTestHarness(run2.Id)
        .drive();
      System.assertEquals('ContinuedAsNew', run2Result.status);

      Workflow_Instance__c run3 = [
        SELECT Id, Status__c, Correlation_Key__c, Input__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :run2.Id
      ];
      System.assertEquals('Pending', run3.Status__c);
      System.assertEquals('PollerKey_run3', run3.Correlation_Key__c);
      System.assertEquals('2', run3.Input__c);

      WorkflowTestHarness.Result run3Result = new WorkflowTestHarness(run3.Id)
        .drive();
      System.assertEquals('ContinuedAsNew', run3Result.status);

      Workflow_Instance__c run4 = [
        SELECT Id, Status__c, Correlation_Key__c, Input__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :run3.Id
      ];
      System.assertEquals('Pending', run4.Status__c);
      System.assertEquals('PollerKey_run4', run4.Correlation_Key__c);
      System.assertEquals('3', run4.Input__c);

      WorkflowTestHarness.Result run4Result = new WorkflowTestHarness(run4.Id)
        .drive();
      Test.stopTest();

      System.assertEquals('Completed', run4Result.status);
      System.assert(
        run4Result.output.contains(
          'Successfully completed poller after 3 runs.'
        )
      );
    }
  }
}
