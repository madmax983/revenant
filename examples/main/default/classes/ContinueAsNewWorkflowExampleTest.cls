@isTest
public class ContinueAsNewWorkflowExampleTest {
  @isTest
  static void testPollerWorkflowContinueAsNew() {
    WorkflowEngine.disableQueueableInTest = true;

    Test.startTest();
    Id run1Id = WorkflowEngine.start(
      'ContinueAsNewWorkflowExample.PollerWorkflow',
      'PollerKey',
      0
    );
    Test.stopTest();

    Workflow_Instance__c run1 = [
      SELECT Status__c, Correlation_Key__c, Input__c
      FROM Workflow_Instance__c
      WHERE Id = :run1Id
    ];
    System.assertEquals('ContinuedAsNew', run1.Status__c);
    System.assertEquals('PollerKey', run1.Correlation_Key__c);

    Workflow_Instance__c run2 = [
      SELECT Id, Status__c, Correlation_Key__c, Input__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :run1Id
    ];
    System.assertEquals('Pending', run2.Status__c);
    System.assertEquals('PollerKey_run2', run2.Correlation_Key__c);
    System.assertEquals('1', run2.Input__c);

    new WorkflowOrchestrator(run2.Id).execute(null);

    run2 = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :run2.Id];
    System.assertEquals('ContinuedAsNew', run2.Status__c);

    Workflow_Instance__c run3 = [
      SELECT Id, Status__c, Correlation_Key__c, Input__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :run2.Id
    ];
    System.assertEquals('Pending', run3.Status__c);
    System.assertEquals('PollerKey_run3', run3.Correlation_Key__c);
    System.assertEquals('2', run3.Input__c);

    new WorkflowOrchestrator(run3.Id).execute(null);

    run3 = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :run3.Id];
    System.assertEquals('ContinuedAsNew', run3.Status__c);

    Workflow_Instance__c run4 = [
      SELECT Id, Status__c, Correlation_Key__c, Input__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :run3.Id
    ];
    System.assertEquals('Pending', run4.Status__c);
    System.assertEquals('PollerKey_run4', run4.Correlation_Key__c);
    System.assertEquals('3', run4.Input__c);

    new WorkflowOrchestrator(run4.Id).execute(null);

    run4 = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :run4.Id
    ];
    System.assertEquals('Completed', run4.Status__c);
    System.assert(
      run4.Output__c.contains('Successfully completed poller after 3 runs.')
    );
  }
}
