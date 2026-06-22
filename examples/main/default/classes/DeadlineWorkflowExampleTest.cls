@isTest
public class DeadlineWorkflowExampleTest {
  @isTest
  static void testDeadlineExample() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'DeadlineWorkflowExample',
      'Deadline-Example-Key',
      null
    );

    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result result = harness.drive();

    System.assertEquals('Suspended', result.status);

    Workflow_Instance__c inst = [
      SELECT Status__c, Deadline_At__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertNotEquals(null, inst.Deadline_At__c);

    // Sleep to bypass deadline (in tests we can just update it to the past)
    inst.Deadline_At__c = DateTime.now().addSeconds(-15);
    update inst;

    Test.startTest();
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    Workflow_Instance__c expiredInst = [
      SELECT Status__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', expiredInst.Status__c);
    System.assertEquals('Execution deadline exceeded', expiredInst.Error_Message__c);
  }
}
