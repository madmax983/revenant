@isTest
public class WorkflowSignalOrStartTest {
  public class TestAggregationWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowSignalOrStartTest.TestAggregationStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowSignalOrStartTest.TestAggregationStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class TestAggregationStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal sig = ctx.getSignal('Approve:MySignal');
      if (sig.isPresent()) {
        return StepResult.complete(null, 'ResumedWith_' + sig.payload);
      }
      return StepResult.waitForApproval('MySignal', 'User');
    }
  }

  @isTest
  static void testSignalOrStartNewInstance() {
    WorkflowEngine.disableQueueableInTest = true;

    WorkflowEngine.StartRequest startReq = new WorkflowEngine.StartRequest(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Key-NewInstance',
      'InitialInput'
    );

    Test.startTest();
    WorkflowEngine.StartResult result = WorkflowEngine.signalOrStart(
      startReq,
      'Approve:MySignal',
      '"SignalPayload"',
      'Idemp-1'
    );
    Test.stopTest();

    System.assertNotEquals(null, result.instanceId);
    System.assertEquals(true, result.isNew);

    // Verify signal is recorded
    List<Workflow_Signal__c> signals = [
      SELECT Status__c, Signal_Name__c, Payload__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :result.instanceId
    ];
    System.assertEquals(1, signals.size());
    System.assertEquals('Approve:MySignal', signals[0].Signal_Name__c);
    System.assertEquals('"SignalPayload"', signals[0].Payload__c);
    System.assertEquals('Received', signals[0].Status__c);
  }

  @isTest
  static void testSignalOrStartExistingActiveInstance() {
    WorkflowEngine.disableQueueableInTest = true;

    // Start instance
    Id instanceId = WorkflowEngine.start(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Key-ActiveInstance',
      'InitialInput'
    );

    // Run first step to suspend it
    WorkflowEngine.runStep(instanceId);

    Workflow_Instance__c instBefore = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', instBefore.Status__c);

    WorkflowEngine.StartRequest startReq = new WorkflowEngine.StartRequest(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Key-ActiveInstance',
      'InitialInput'
    );

    WorkflowEngine.disableQueueableInTest = false;
    Test.startTest();
    WorkflowEngine.StartResult result = WorkflowEngine.signalOrStart(
      startReq,
      'Approve:MySignal',
      '"SignalPayload"',
      'Idemp-2'
    );

    System.assertEquals(instanceId, result.instanceId);
    System.assertEquals(false, result.isNew);

    // Verify signal is recorded and instance is woken (before queueable execution)
    List<Workflow_Signal__c> signals = [
      SELECT Status__c, Signal_Name__c, Payload__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :instanceId
    ];
    System.assertEquals(1, signals.size());
    System.assertEquals('Approve:MySignal', signals[0].Signal_Name__c);
    System.assertEquals('Received', signals[0].Status__c);

    Workflow_Instance__c instAfter = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Running', instAfter.Status__c);

    Test.stopTest();

    // After queueables run, the instance should complete
    Workflow_Instance__c instCompleted = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', instCompleted.Status__c);
  }

  @isTest
  static void testSignalOrStartIdempotency() {
    WorkflowEngine.disableQueueableInTest = true;

    WorkflowEngine.StartRequest startReq = new WorkflowEngine.StartRequest(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Key-Idemp',
      'InitialInput'
    );

    Test.startTest();
    // First delivery
    WorkflowEngine.StartResult result1 = WorkflowEngine.signalOrStart(
      startReq,
      'Approve:MySignal',
      '"SignalPayload"',
      'Idemp-3'
    );

    // Second delivery (redelivery of same key + signal + idemp key)
    WorkflowEngine.StartResult result2 = WorkflowEngine.signalOrStart(
      startReq,
      'Approve:MySignal',
      '"SignalPayload"',
      'Idemp-3'
    );
    Test.stopTest();

    System.assertEquals(result1.instanceId, result2.instanceId);
    System.assertEquals(true, result1.isNew);
    System.assertEquals(false, result2.isNew);

    // Verify only 1 signal record exists (idempotency caught duplicate)
    List<Workflow_Signal__c> signals = [
      SELECT Status__c, Signal_Name__c, Payload__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :result1.instanceId
    ];
    System.assertEquals(1, signals.size());
  }

  @isTest
  static void testSignalOrStartTerminalInstance() {
    WorkflowEngine.disableQueueableInTest = true;

    // Start and run to completion (no signal needed if step doesn't suspend,
    // but here it suspends, so let's start, resume, and let it complete).
    Id instanceId = WorkflowEngine.start(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Key-Terminal',
      'InitialInput'
    );
    WorkflowEngine.runStep(instanceId); // Suspends
    WorkflowEngine.signal(instanceId, 'Approve:MySignal', '"SignalPayload"');
    WorkflowEngine.runStep(instanceId); // Completes

    Workflow_Instance__c instBefore = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', instBefore.Status__c);

    WorkflowEngine.StartRequest startReq = new WorkflowEngine.StartRequest(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Key-Terminal',
      'InitialInput'
    );

    Test.startTest();
    // Within dedup window: should return existing terminal instance and swallow signal
    WorkflowEngine.StartResult result = WorkflowEngine.signalOrStart(
      startReq,
      'Approve:MySignal',
      '"NewSignalPayload"',
      'Idemp-4'
    );
    Test.stopTest();

    System.assertEquals(instanceId, result.instanceId);
    System.assertEquals(false, result.isNew);

    // Verify no new signal record with "NewSignalPayload" was created
    List<Workflow_Signal__c> signals = [
      SELECT Status__c, Signal_Name__c, Payload__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :instanceId
    ];
    for (Workflow_Signal__c sig : signals) {
      System.assertNotEquals('"NewSignalPayload"', sig.Payload__c);
    }
  }

  @isTest
  static void testSignalOrStartBulk() {
    WorkflowEngine.disableQueueableInTest = true;

    // Prepare an existing active instance for bulk test
    Id activeId = WorkflowEngine.start(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Bulk-Active',
      'Input'
    );
    WorkflowEngine.runStep(activeId); // Suspends

    List<WorkflowEngine.SignalOrStartRequest> requests = new List<WorkflowEngine.SignalOrStartRequest>();

    // Request 1: New instance
    WorkflowEngine.StartRequest startNew = new WorkflowEngine.StartRequest(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Bulk-New',
      'Input'
    );
    requests.add(new WorkflowEngine.SignalOrStartRequest(startNew, 'Approve:MySignal', '"PayloadNew"', 'Idemp-Bulk-1'));

    // Request 2: Existing active instance
    WorkflowEngine.StartRequest startActive = new WorkflowEngine.StartRequest(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Bulk-Active',
      'Input'
    );
    requests.add(new WorkflowEngine.SignalOrStartRequest(startActive, 'Approve:MySignal', '"PayloadActive"', 'Idemp-Bulk-2'));

    // Request 3: Duplicate of Request 1 in same batch (in-batch duplicate)
    requests.add(new WorkflowEngine.SignalOrStartRequest(startNew, 'Approve:MySignal', '"PayloadNew"', 'Idemp-Bulk-1'));

    WorkflowEngine.disableQueueableInTest = false;
    Test.startTest();
    List<WorkflowEngine.StartResult> results = WorkflowEngine.signalOrStart(requests);

    System.assertEquals(3, results.size());

    // Result 1: New
    System.assertNotEquals(null, results[0].instanceId);
    System.assertEquals(true, results[0].isNew);

    // Result 2: Existing active
    System.assertEquals(activeId, results[1].instanceId);
    System.assertEquals(false, results[1].isNew);

    // Result 3: Duplicate of Result 1
    System.assertEquals(results[0].instanceId, results[2].instanceId);
    System.assertEquals(false, results[2].isNew);

    // Verify signal count for the new instance is exactly 1 (duplicate swallowed)
    List<Workflow_Signal__c> signalsNew = [
      SELECT Status__c, Signal_Name__c, Payload__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :results[0].instanceId
    ];
    System.assertEquals(1, signalsNew.size());
    System.assertEquals('"PayloadNew"', signalsNew[0].Payload__c);

    // Verify signal for the active instance is recorded and status is Running (before queueable run)
    List<Workflow_Signal__c> signalsActive = [
      SELECT Status__c, Signal_Name__c, Payload__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :activeId
    ];
    System.assertEquals(1, signalsActive.size());
    System.assertEquals('"PayloadActive"', signalsActive[0].Payload__c);

    Workflow_Instance__c activeInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :activeId
    ];
    System.assertEquals('Running', activeInst.Status__c);

    Test.stopTest();

    // After stopTest, the active instance should run to completion
    Workflow_Instance__c activeInstCompleted = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :activeId
    ];
    System.assertEquals('Completed', activeInstCompleted.Status__c);
  }

  @isTest
  static void testInvocableAction() {
    WorkflowEngine.disableQueueableInTest = true;

    WorkflowSignalOrStartInvocableAction.SignalOrStartRequest req = new WorkflowSignalOrStartInvocableAction.SignalOrStartRequest();
    req.workflowName = 'WorkflowSignalOrStartTest.TestAggregationWorkflow';
    req.correlationKey = 'InvocableKey-1';
    req.inputJson = '"InvocableInput"';
    req.signalName = 'Approve:MySignal';
    req.payloadJson = '"SignalInput"';
    req.idempotencyKey = 'Idemp-Invocable';

    Test.startTest();
    List<WorkflowSignalOrStartInvocableAction.SignalOrStartResult> results = WorkflowSignalOrStartInvocableAction.signalOrStartWorkflow(
      new List<WorkflowSignalOrStartInvocableAction.SignalOrStartRequest>{ req }
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    System.assertNotEquals(null, results[0].workflowInstanceId);
    System.assertEquals(true, results[0].isNew);

    // Verify signal is recorded
    List<Workflow_Signal__c> signals = [
      SELECT Status__c, Signal_Name__c, Payload__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :results[0].workflowInstanceId
    ];
    System.assertEquals(1, signals.size());
    System.assertEquals('Approve:MySignal', signals[0].Signal_Name__c);
    System.assertEquals('"SignalInput"', signals[0].Payload__c);
    System.assertEquals('Received', signals[0].Status__c);
  }

  @isTest
  static void testSignalOrStartCancel() {
    WorkflowEngine.disableQueueableInTest = true;

    // Start instance
    Id instanceId = WorkflowEngine.start(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Key-CancelInstance',
      'InitialInput'
    );

    // Run step to suspend
    WorkflowEngine.runStep(instanceId);

    Workflow_Instance__c instBefore = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', instBefore.Status__c);

    WorkflowEngine.StartRequest startReq = new WorkflowEngine.StartRequest(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Key-CancelInstance',
      'InitialInput'
    );

    Test.startTest();
    WorkflowEngine.StartResult result = WorkflowEngine.signalOrStart(
      startReq,
      'Cancel',
      'false', // runCompensations = false
      'Idemp-Cancel-Key'
    );
    Test.stopTest();

    System.assertEquals(instanceId, result.instanceId);
    System.assertEquals(false, result.isNew);

    // Verify status is Cancelled
    Workflow_Instance__c instAfter = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Cancelled', instAfter.Status__c);

    // Verify no unconsumed or Received signal is left in the DB for the Cancel signal
    List<Workflow_Signal__c> signals = [
      SELECT Status__c, Signal_Name__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :instanceId AND Signal_Name__c = 'Cancel'
    ];
    // Keyed cancel creates a 'Consumed' signal record to claim idempotency, but NOT a 'Received' record.
    System.assertEquals(1, signals.size());
    System.assertEquals('Consumed', signals[0].Status__c);
  }

  @isTest
  static void testSignalOrStartCompensationFailed() {
    WorkflowEngine.disableQueueableInTest = true;

    // Start instance
    Id instanceId = WorkflowEngine.start(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Key-CompFailedInstance',
      'InitialInput'
    );

    // Forcefully update the status to CompensationFailed
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Id = instanceId,
      Status__c = 'CompensationFailed'
    );
    update as system inst;

    WorkflowEngine.StartRequest startReq = new WorkflowEngine.StartRequest(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Key-CompFailedInstance',
      'InitialInput'
    );

    Test.startTest();
    WorkflowEngine.StartResult result = WorkflowEngine.signalOrStart(
      startReq,
      'Approve:MySignal',
      '"SignalPayload"',
      'Idemp-CompFailed-1'
    );
    Test.stopTest();

    System.assertEquals(instanceId, result.instanceId);
    System.assertEquals(false, result.isNew);

    // Verify no signal record is created in the DB
    List<Workflow_Signal__c> signals = [
      SELECT Status__c, Signal_Name__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :instanceId AND Signal_Name__c = 'Approve:MySignal'
    ];
    System.assertEquals(0, signals.size());
  }

  @isTest
  static void testSignalOrStartContinuedAsNew() {
    WorkflowEngine.disableQueueableInTest = true;

    // Start instance
    Id instanceId = WorkflowEngine.start(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Key-ContinuedAsNewInstance',
      'InitialInput'
    );

    // Forcefully update the status to ContinuedAsNew
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Id = instanceId,
      Status__c = 'ContinuedAsNew'
    );
    update as system inst;

    WorkflowEngine.StartRequest startReq = new WorkflowEngine.StartRequest(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Key-ContinuedAsNewInstance',
      'InitialInput'
    );

    Test.startTest();
    WorkflowEngine.StartResult result = WorkflowEngine.signalOrStart(
      startReq,
      'Approve:MySignal',
      '"SignalPayload"',
      'Idemp-ContNew-1'
    );
    Test.stopTest();

    System.assertEquals(instanceId, result.instanceId);
    System.assertEquals(false, result.isNew);

    // Verify no signal record is created in the DB
    List<Workflow_Signal__c> signals = [
      SELECT Status__c, Signal_Name__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :instanceId AND Signal_Name__c = 'Approve:MySignal'
    ];
    System.assertEquals(0, signals.size());
  }

  @isTest
  static void testSignalOrStartChildWakeGating() {
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Create a parent workflow instance and set its status to Suspended
    Id parentId = WorkflowEngine.start(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Parent-Key',
      'InitialInput'
    );
    Workflow_Instance__c parent = new Workflow_Instance__c(
      Id = parentId,
      Status__c = 'Suspended'
    );
    update as system parent;

    // 2. Create a pending step execution for the parent with childCorrelationKeys in output
    Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
      Workflow_Instance__c = parentId,
      Step_Name__c = 'WaitForChildren',
      Status__c = 'Pending',
      Output__c = '{"childCorrelationKeys":["ChildKey1","ChildKey2"]}'
    );
    insert step;

    // 3. Create two child workflow instances under this parent:
    // Child 1 (active/Pending) and Child 2 (terminal/Completed)
    Workflow_Instance__c child1 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      Status__c = 'Pending',
      Parent_Instance__c = parentId,
      Correlation_Key__c = 'ChildKey1',
      Input__c = '"Child1Input"'
    );
    Workflow_Instance__c child2 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      Status__c = 'Completed',
      Parent_Instance__c = parentId,
      Correlation_Key__c = 'ChildKey2',
      Input__c = '"Child2Input"'
    );
    insert new List<Workflow_Instance__c>{child1, child2};

    WorkflowEngine.StartRequest startReq = new WorkflowEngine.StartRequest(
      'WorkflowSignalOrStartTest.TestAggregationWorkflow',
      'Parent-Key',
      'InitialInput'
    );

    // 4. Send child completed signal for Child 2 (terminal, but Child 1 is still Pending)
    Test.startTest();
    WorkflowEngine.StartResult result1 = WorkflowEngine.signalOrStart(
      startReq,
      'ChildCompleted:ChildKey2',
      '{}',
      'Idemp-Child2'
    );

    // Verify parent is still Suspended (gated)
    Workflow_Instance__c parentRefreshed1 = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :parentId];
    System.assertEquals('Suspended', parentRefreshed1.Status__c);

    // 5. Force Child 1 to be Completed (terminal)
    child1.Status__c = 'Completed';
    update as system child1;

    // Send child completed signal for Child 1 (all children are now terminal/ready)
    WorkflowEngine.StartResult result2 = WorkflowEngine.signalOrStart(
      startReq,
      'ChildCompleted:ChildKey1',
      '{}',
      'Idemp-Child1'
    );
    Test.stopTest();

    // Verify parent is now Running (woken)
    Workflow_Instance__c parentRefreshed2 = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :parentId];
    System.assertEquals('Running', parentRefreshed2.Status__c);
  }
}
