@isTest
private class ApprovalSignalWorkflowExampleTest {
  /**
   * Issue #11 reference scenario: suspend -> signal with payload -> duplicate
   * redelivered signal -> resume. The resuming step reads the decision from
   * StepContext and branches to reject; the redelivered duplicate must NOT make
   * the reject branch fire twice.
   */
  @isTest
  static void testRejectBranchWithRedeliveredSignalFiresOnce() {
    Id instanceId = WorkflowEngine.start(
      'ApprovalSignalWorkflowExample',
      'ApprovalSignalKey',
      new Map<String, Object>{ 'amount' => 500 }
    );

    // 1. First run: no decision yet -> suspends waiting for approval.
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', inst.Status__c);
    System.assertEquals(
      'ApprovalSignalWorkflowExample.RequestApprovalStep',
      inst.Current_Step__c
    );

    // 2. Approver signals a rejection -- delivered twice (at-least-once redelivery).
    String decision = '{"approved":false,"reason":"budget"}';
    WorkflowEngine.signal(
      'ApprovalSignalKey',
      ApprovalSignalWorkflowExample.DECISION_SIGNAL,
      decision
    );
    WorkflowEngine.signal(
      'ApprovalSignalKey',
      ApprovalSignalWorkflowExample.DECISION_SIGNAL,
      decision
    );

    // Two unconsumed signal records are now buffered.
    System.assertEquals(
      2,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
      ],
      'Both redelivered signals should be buffered before resume'
    );

    // 3. Resume: the step reads the decision from context and branches to reject.
    new WorkflowOrchestrator(instanceId).execute(null);
    // 4. Run the reject branch step.
    new WorkflowOrchestrator(instanceId).execute(null);

    inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assert(
      inst.Output__c.contains('"result":"rejected"'),
      'Expected reject output, got: ' + inst.Output__c
    );
    System.assert(
      inst.Output__c.contains('"reason":"budget"'),
      'Reject output should carry the rejection reason, got: ' + inst.Output__c
    );

    // The reject branch fired exactly once despite the redelivered duplicate.
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'ApprovalSignalWorkflowExample.RejectStep'
          AND Status__c = 'Completed'
      ],
      'Reject branch must fire exactly once'
    );

    // Both signals (the observed name) were consumed by the engine.
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
      ],
      'Engine must mark all observed signals consumed at COMPLETE'
    );
    System.assertEquals(
      2,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Consumed'
      ],
      'Both redelivered signals must end up Consumed'
    );
  }

  @isTest
  static void testApproveBranchReadsDecisionFromContext() {
    Id instanceId = WorkflowEngine.start(
      'ApprovalSignalWorkflowExample',
      'ApprovalSignalKey2',
      new Map<String, Object>{ 'amount' => 999 }
    );
    new WorkflowOrchestrator(instanceId).execute(null);

    WorkflowEngine.signal(
      'ApprovalSignalKey2',
      ApprovalSignalWorkflowExample.DECISION_SIGNAL,
      '{"approved":true}'
    );

    new WorkflowOrchestrator(instanceId).execute(null);
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assert(
      inst.Output__c.contains('"result":"approved"'),
      'Expected approve output, got: ' + inst.Output__c
    );
  }
}
