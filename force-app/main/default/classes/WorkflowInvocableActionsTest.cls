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
  static void testStartWorkflowInvocableDuplicateDoesNotFault() {
    WorkflowEngine.disableQueueableInTest = true;

    // Pre-existing active instance for the key
    Id existingId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'InvocableDupKey',
      null
    );

    WorkflowStartInvocableAction.StartRequest dup = new WorkflowStartInvocableAction.StartRequest();
    dup.workflowName = 'WorkflowEngineTest.HappyWorkflow';
    dup.correlationKey = 'InvocableDupKey';

    WorkflowStartInvocableAction.StartRequest fresh = new WorkflowStartInvocableAction.StartRequest();
    fresh.workflowName = 'WorkflowEngineTest.HappyWorkflow';
    fresh.correlationKey = 'InvocableFreshKey';

    Test.startTest();
    List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
      new List<WorkflowStartInvocableAction.StartRequest>{ dup, fresh }
    );
    Test.stopTest();

    System.assertEquals(2, results.size());
    // Duplicate resolves to existing Id without faulting the Flow
    System.assertEquals(existingId, results[0].workflowInstanceId);
    System.assertEquals(false, results[0].isNew);
    // Sibling unaffected
    System.assertNotEquals(null, results[1].workflowInstanceId);
    System.assertEquals(true, results[1].isNew);
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
      WHERE
        Id IN (:results[0].workflowInstanceId, :results[1].workflowInstanceId)
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
    System.assertEquals(
      'Approve:InvocableApproval1',
      signals[0].Signal_Name__c
    );
    System.assertEquals(
      'Approve:InvocableApproval2',
      signals[1].Signal_Name__c
    );
  }

  @isTest
  static void testStartWorkflowInvocableWithAttributes() {
    WorkflowStartInvocableAction.StartRequest req = new WorkflowStartInvocableAction.StartRequest();
    req.workflowName = 'WorkflowEngineTest.HappyWorkflow';
    req.correlationKey = 'InvocableAttrKey';
    req.inputJson = '"InvocableInput"';
    req.attributesJson = '{"region":"EU","tier":"enterprise"}';

    Test.startTest();
    List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
      new List<WorkflowStartInvocableAction.StartRequest>{ req }
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    Id instanceId = results[0].workflowInstanceId;
    System.assertNotEquals(null, instanceId);

    List<Workflow_Search_Attribute__c> attrs = [
      SELECT Key__c, Value__c
      FROM Workflow_Search_Attribute__c
      WHERE Workflow_Instance__c = :instanceId
      ORDER BY Key__c ASC
    ];
    System.assertEquals(2, attrs.size());
    System.assertEquals('region', attrs[0].Key__c);
    System.assertEquals('EU', attrs[0].Value__c);
    System.assertEquals('tier', attrs[1].Key__c);
    System.assertEquals('enterprise', attrs[1].Value__c);
  }

  @isTest
  static void testStartWorkflowInvocableWithCausationId() {
    WorkflowStartInvocableAction.StartRequest req = new WorkflowStartInvocableAction.StartRequest();
    req.workflowName = 'WorkflowEngineTest.HappyWorkflow';
    req.correlationKey = 'InvocableCausationKey';
    req.causationId = 'invocable-cause-789';

    Test.startTest();
    List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
      new List<WorkflowStartInvocableAction.StartRequest>{ req }
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    Id instanceId = results[0].workflowInstanceId;
    System.assertNotEquals(null, instanceId);

    Workflow_Instance__c inst = [
      SELECT Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('invocable-cause-789', inst.Causation_Id__c);
  }

  @isTest
  static void testInvocableActionsNullSafety() {
    Test.startTest();

    // Start Action Null Safety
    List<WorkflowStartInvocableAction.StartResult> startResults = WorkflowStartInvocableAction.startWorkflow(
      new List<WorkflowStartInvocableAction.StartRequest>{ null }
    );
    System.assertEquals(1, startResults.size());
    System.assertEquals(null, startResults[0].workflowInstanceId);

    // Signal Action Null Safety
    WorkflowSignalInvocableAction.signalWorkflow(
      new List<WorkflowSignalInvocableAction.SignalRequest>{ null }
    );

    // SignalOrStart Action Null Safety
    List<WorkflowSignalOrStartInvocableAction.SignalOrStartResult> signalOrStartResults = WorkflowSignalOrStartInvocableAction.signalOrStartWorkflow(
      new List<WorkflowSignalOrStartInvocableAction.SignalOrStartRequest>{
        null
      }
    );
    System.assertEquals(1, signalOrStartResults.size());
    System.assertEquals(null, signalOrStartResults[0].workflowInstanceId);

    Test.stopTest();
  }

  @isTest
  static void testFlowDebouncedStart() {
    WorkflowStartInvocableAction.StartRequest req = new WorkflowStartInvocableAction.StartRequest();
    req.workflowName = 'WorkflowEngineTest.HappyWorkflow';
    req.correlationKey = 'InvocableDebounceKey';
    req.inputJson = '{"val":1}';
    req.debounceSeconds = 10;
    req.maxWaitSeconds = 15;

    Test.startTest();
    List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
      new List<WorkflowStartInvocableAction.StartRequest>{ req }
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    System.assertEquals(
      null,
      results[0].workflowInstanceId,
      'Workflow should not start immediately'
    );

    List<Debounce_State__c> states = [
      SELECT Id, Fire_At__c, Input_Json__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'InvocableDebounceKey'
    ];
    System.assertEquals(1, states.size(), 'Debounce state should be created');
    System.assertEquals('{"val":1}', states[0].Input_Json__c);
  }

  @isTest
  static void testFlowNegativeDebounceValidation() {
    WorkflowStartInvocableAction.StartRequest req = new WorkflowStartInvocableAction.StartRequest();
    req.workflowName = 'WorkflowEngineTest.HappyWorkflow';
    req.correlationKey = 'InvocableDebounceKeyNeg';
    req.debounceSeconds = -5;

    Test.startTest();
    try {
      WorkflowStartInvocableAction.startWorkflow(
        new List<WorkflowStartInvocableAction.StartRequest>{ req }
      );
      System.assert(
        false,
        'Should have failed due to negative debounce seconds'
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      System.assert(
        ex.getMessage().contains('Debounce seconds must be non-negative'),
        'Exception message should mention non-negative constraint'
      );
    }
    Test.stopTest();
  }

  @isTest
  static void testFlowDebouncedStartWithMetadata() {
    WorkflowStartInvocableAction.StartRequest req = new WorkflowStartInvocableAction.StartRequest();
    req.workflowName = 'WorkflowEngineTest.HappyWorkflow';
    req.correlationKey = 'InvocableDebounceKeyMeta';
    req.inputJson = '{"val":1}';
    req.debounceSeconds = 10;
    req.maxWaitSeconds = 15;
    req.attributesJson = '{"attr2":"val2"}';
    req.causationId = 'flowCausation123';

    Test.startTest();
    List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
      new List<WorkflowStartInvocableAction.StartRequest>{ req }
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    System.assertEquals(
      null,
      results[0].workflowInstanceId,
      'Workflow should not start immediately'
    );

    List<Debounce_State__c> states = [
      SELECT Id, Attributes_Json__c, Causation_Id__c, Input_Json__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'InvocableDebounceKeyMeta'
    ];
    System.assertEquals(1, states.size(), 'Debounce state should be created');
    System.assertEquals('{"val":1}', states[0].Input_Json__c);
    System.assertEquals('{"attr2":"val2"}', states[0].Attributes_Json__c);
    System.assertEquals('flowCausation123', states[0].Causation_Id__c);
  }
}
