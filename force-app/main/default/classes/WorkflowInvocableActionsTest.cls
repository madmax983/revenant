@isTest
public class WorkflowInvocableActionsTest {
  @isTest
  static void testStartWorkflowInvocable() {
    WorkflowStartInvocableAction.StartRequest req = new WorkflowStartInvocableAction.StartRequest();
    req.workflowName = 'WorkflowEngineTest.HappyWorkflow';
    req.correlationKey = 'InvocableKey';
    req.inputJson = '"InvocableInput"';

    Test.startTest();
    List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
      new List<WorkflowStartInvocableAction.StartRequest>{ req }
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    Id instanceId = results[0].workflowInstanceId;
    System.assertNotEquals(null, instanceId);

    Workflow_Instance__c inst = [
      SELECT Workflow_Name__c, Status__c, Correlation_Key__c, Input__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'WorkflowEngineTest.HappyWorkflow',
      inst.Workflow_Name__c
    );
    System.assertEquals('InvocableKey', inst.Correlation_Key__c);
    System.assertEquals('"InvocableInput"', inst.Input__c);
  }

  @isTest
  static void testSignalWorkflowInvocable() {
    // Create active instance
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'InvocableSignalKey',
      Input__c = '"InputData"'
    );
    insert inst;

    WorkflowSignalInvocableAction.SignalRequest req = new WorkflowSignalInvocableAction.SignalRequest();
    req.targetKey = 'InvocableSignalKey';
    req.signalName = 'Approve:InvocableApproval';
    req.payloadJson = '{"approved":true}';

    Test.startTest();
    WorkflowSignalInvocableAction.signalWorkflow(
      new List<WorkflowSignalInvocableAction.SignalRequest>{ req }
    );
    Test.stopTest();

    // Deliver Platform Event
    Test.getEventBus().deliver();

    List<Workflow_Signal__c> signals = [
      SELECT Signal_Name__c, Payload__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :inst.Id
    ];
    System.assertEquals(1, signals.size());
    System.assertEquals('Approve:InvocableApproval', signals[0].Signal_Name__c);
  }

  @isTest
  static void testStartWorkflowInvocableBulk() {
    WorkflowStartInvocableAction.StartRequest req1 = new WorkflowStartInvocableAction.StartRequest();
    req1.workflowName = 'WorkflowEngineTest.HappyWorkflow';
    req1.correlationKey = 'InvocableKey1';
    req1.inputJson = '"InvocableInput1"';

    WorkflowStartInvocableAction.StartRequest req2 = new WorkflowStartInvocableAction.StartRequest();
    req2.workflowName = 'WorkflowEngineTest.HappyWorkflow';
    req2.correlationKey = 'InvocableKey2';
    req2.inputJson = '"InvocableInput2"';

    Test.startTest();
    List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
      new List<WorkflowStartInvocableAction.StartRequest>{ req1, req2 }
    );
    Test.stopTest();

    System.assertEquals(2, results.size());
    System.assertNotEquals(null, results[0].workflowInstanceId);
    System.assertNotEquals(null, results[1].workflowInstanceId);

    List<Workflow_Instance__c> insts = [
      SELECT Workflow_Name__c, Status__c, Correlation_Key__c, Input__c
      FROM Workflow_Instance__c
      WHERE Id IN (:results[0].workflowInstanceId, :results[1].workflowInstanceId)
      ORDER BY Correlation_Key__c ASC
    ];
    System.assertEquals(2, insts.size());
    System.assertEquals('InvocableKey1', insts[0].Correlation_Key__c);
    System.assertEquals('InvocableKey2', insts[1].Correlation_Key__c);
  }

  @isTest
  static void testSignalWorkflowInvocableBulk() {
    Workflow_Instance__c inst1 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'InvocableSignalKey1',
      Input__c = '"InputData1"'
    );
    Workflow_Instance__c inst2 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'InvocableSignalKey2',
      Input__c = '"InputData2"'
    );
    insert new List<Workflow_Instance__c>{ inst1, inst2 };

    WorkflowSignalInvocableAction.SignalRequest req1 = new WorkflowSignalInvocableAction.SignalRequest();
    req1.targetKey = 'InvocableSignalKey1';
    req1.signalName = 'Approve:InvocableApproval1';
    req1.payloadJson = '{"approved":true}';

    WorkflowSignalInvocableAction.SignalRequest req2 = new WorkflowSignalInvocableAction.SignalRequest();
    req2.targetKey = 'InvocableSignalKey2';
    req2.signalName = 'Approve:InvocableApproval2';
    req2.payloadJson = '{"approved":true}';

    Test.startTest();
    WorkflowSignalInvocableAction.signalWorkflow(
      new List<WorkflowSignalInvocableAction.SignalRequest>{ req1, req2 }
    );
    Test.stopTest();

    Test.getEventBus().deliver();

    List<Workflow_Signal__c> signals = [
      SELECT Signal_Name__c, Payload__c, Workflow_Instance__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c IN (:inst1.Id, :inst2.Id)
      ORDER BY Signal_Name__c ASC
    ];
    System.assertEquals(2, signals.size());
    System.assertEquals('Approve:InvocableApproval1', signals[0].Signal_Name__c);
    System.assertEquals('Approve:InvocableApproval2', signals[1].Signal_Name__c);
  }
}
