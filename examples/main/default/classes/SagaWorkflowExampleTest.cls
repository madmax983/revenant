@isTest
public class SagaWorkflowExampleTest {
  @isTest
  static void testSagaWorkflowCompensationsSuccess() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'SagaWorkflowExample.SagaWorkflow',
      'SagaKey_1',
      '{"email":"test@example.com"}'
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals(
      'Compensated',
      result.status,
      'Saga should fully compensate after the SMTP failure'
    );
    System.assertEquals(
      new List<String>{
        'SagaWorkflowExample.ProvisionServiceStep_Compensate',
        'SagaWorkflowExample.ChargeCreditCardStep_Compensate'
      },
      result.compensatedSteps,
      'Compensations must run in LIFO order'
    );

    // Verify compensation output details from the append-only audit trail.
    List<Workflow_Step_Execution__c> compLogs = [
      SELECT Step_Name__c, Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c LIKE '%_Compensate'
      ORDER BY CreatedDate ASC
    ];
    System.assertEquals(2, compLogs.size());
    System.assertEquals('Compensated', compLogs[0].Status__c);
    System.assertEquals('Compensated', compLogs[1].Status__c);
    System.assert(compLogs[1].Output__c.contains('refundId'));
    System.assert(compLogs[1].Output__c.contains('ch_12345'));
  }
}
