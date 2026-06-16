@isTest
private class ApprovalWorkflowExampleTest {

  static final String KEY_PREFIX = 'ApprovalWorkflow_Test_';

  @isTest
  static void testApprovedRoundTripReachesCompleted() {
    String key = KEY_PREFIX + '1';
    Id instanceId = WorkflowEngine.start(
      'ApprovalWorkflowExample',
      key,
      new Map<String, Object>{ 'purchaseAmount' => 500 }
    );

    // Hop 1: ReserveBudgetStep executes and completes (pushed onto Compensation_Stack__c).
    new WorkflowOrchestrator(instanceId).execute(null);
    // Hop 2: RequestApprovalStep — first run, no signal yet -> instance Suspended.
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', inst.Status__c, 'Instance must be Suspended awaiting approval');
    System.assertEquals(
      'ApprovalWorkflowExample.RequestApprovalStep',
      inst.Current_Step__c,
      'Current step must be RequestApprovalStep while suspended'
    );

    // Approver delivers an approval signal.
    WorkflowEngine.signal(
      key,
      ApprovalWorkflowExample.DECISION_SIGNAL,
      '{"approved":true,"approver":"manager@example.com"}'
    );

    // Hop 3: RequestApprovalStep resumes, reads signal, returns decision -> getNextStep -> PlaceOrderStep.
    new WorkflowOrchestrator(instanceId).execute(null);
    // Hop 4: PlaceOrderStep executes -> terminal Completed.
    new WorkflowOrchestrator(instanceId).execute(null);

    inst = [SELECT Status__c, Output__c FROM Workflow_Instance__c WHERE Id = :instanceId];
    System.assertEquals('Completed', inst.Status__c, 'Approved workflow must reach Completed');
    System.assert(
      inst.Output__c.contains('"result":"approved"'),
      'Output must confirm the approved outcome, got: ' + inst.Output__c
    );

    // No compensation steps should have run on the happy path.
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId AND Step_Name__c LIKE '%_Compensate'
      ],
      'Approved path must not trigger any compensation'
    );
  }

  @isTest
  static void testRejectedRoundTripCompensatesPriorWork() {
    String key = KEY_PREFIX + '2';
    Id instanceId = WorkflowEngine.start(
      'ApprovalWorkflowExample',
      key,
      new Map<String, Object>{ 'purchaseAmount' => 9000 }
    );

    new WorkflowOrchestrator(instanceId).execute(null); // ReserveBudgetStep
    new WorkflowOrchestrator(instanceId).execute(null); // RequestApprovalStep -> Suspended

    Workflow_Instance__c inst = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId];
    System.assertEquals('Suspended', inst.Status__c);

    // Approver delivers a rejection.
    WorkflowEngine.signal(
      key,
      ApprovalWorkflowExample.DECISION_SIGNAL,
      '{"approved":false,"reason":"over budget"}'
    );

    // Hop 3: RequestApprovalStep resumes -> getNextStep -> RejectStep.
    new WorkflowOrchestrator(instanceId).execute(null);
    // Hop 4: RejectStep throws WorkflowException -> LIFO compensation enqueued.
    new WorkflowOrchestrator(instanceId).execute(null);
    // Hop 5: ReserveBudgetStep_Compensate runs -> stack empty -> instance Compensated.
    new WorkflowOrchestrator(instanceId).execute(null);

    inst = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId];
    System.assertEquals(
      'Compensated',
      inst.Status__c,
      'Rejected workflow must reach Compensated after LIFO rollback'
    );

    // Verify the compensation audit trail.
    List<Workflow_Step_Execution__c> compLogs = [
      SELECT Step_Name__c, Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Step_Name__c LIKE '%_Compensate'
    ];
    System.assertEquals(
      1,
      compLogs.size(),
      'Exactly one CompensatableStep should have been rolled back'
    );
    System.assertEquals(
      'ApprovalWorkflowExample.ReserveBudgetStep_Compensate',
      compLogs[0].Step_Name__c,
      'ReserveBudgetStep must be compensated'
    );
    System.assertEquals('Compensated', compLogs[0].Status__c);
    System.assert(
      compLogs[0].Output__c != null && compLogs[0].Output__c.contains('released'),
      'Compensation output must confirm the reservation was released, got: ' + compLogs[0].Output__c
    );
  }

  @isTest
  static void testDuplicateRejectSignalIsIdempotent() {
    String key = KEY_PREFIX + '3';
    Id instanceId = WorkflowEngine.start(
      'ApprovalWorkflowExample',
      key,
      new Map<String, Object>{ 'purchaseAmount' => 1000 }
    );

    new WorkflowOrchestrator(instanceId).execute(null); // ReserveBudgetStep
    new WorkflowOrchestrator(instanceId).execute(null); // RequestApprovalStep -> Suspended

    // Deliver the rejection twice to simulate at-least-once redelivery.
    String decision = '{"approved":false,"reason":"duplicate test"}';
    WorkflowEngine.signal(key, ApprovalWorkflowExample.DECISION_SIGNAL, decision);
    WorkflowEngine.signal(key, ApprovalWorkflowExample.DECISION_SIGNAL, decision);

    System.assertEquals(
      2,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Received'
      ],
      'Both signals must be buffered before resume'
    );

    new WorkflowOrchestrator(instanceId).execute(null); // RequestApprovalStep resumes -> RejectStep
    new WorkflowOrchestrator(instanceId).execute(null); // RejectStep throws -> compensation
    new WorkflowOrchestrator(instanceId).execute(null); // ReserveBudgetStep_Compensate

    Workflow_Instance__c inst = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId];
    System.assertEquals('Compensated', inst.Status__c, 'Instance must reach Compensated');

    // RejectStep must have fired exactly once despite the duplicate signal.
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'ApprovalWorkflowExample.RejectStep'
      ],
      'RejectStep must fire exactly once regardless of duplicate signals'
    );

    // Compensation must have run exactly once.
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId AND Step_Name__c LIKE '%_Compensate'
      ],
      'Compensation must run exactly once'
    );

    // Engine must have consumed all signal records.
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Received'
      ],
      'No signals must remain in Received state'
    );
    System.assertEquals(
      2,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Consumed'
      ],
      'Both redelivered signals must be marked Consumed by the engine'
    );
  }
}
