@IsTest
private class ApprovalWorkflowExampleTest {
  static final String KEY_PREFIX = 'ApprovalWorkflow_Test_';

  /**
   * Asserts the append-only audit trail recorded exactly one compensation whose logged
   * output confirms the reserved budget was released.
   */
  private static void assertReservationReleased(Id instanceId) {
    List<Workflow_Step_Execution__c> compLogs = [
      SELECT Step_Name__c, Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c LIKE '%_Compensate'
    ];
    System.assertEquals(1, compLogs.size());
    System.assertEquals('Compensated', compLogs[0].Status__c);
    System.assert(
      compLogs[0].Output__c != null &&
      compLogs[0].Output__c.contains('released'),
      'Compensation output must confirm the reservation was released, got: ' +
      compLogs[0].Output__c
    );
  }

  /**
   * Approved round trip: start -> Suspended on the approval gate -> approval signal
   * -> resume -> Completed, with no compensation.
   *
   * Drives through WorkflowTestHarness so the failing/throwing reject path (in the
   * other cases) is rescued by the engine's own crash handler (WorkflowEngine.handleCrash),
   * exactly as WorkflowFinalizer does in production. A raw WorkflowOrchestrator.execute(null)
   * would not attach the finalizer and a thrown step would escape the test instead of
   * triggering compensation.
   */
  @IsTest
  static void testApprovedRoundTripReachesCompleted() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String key = KEY_PREFIX + '1';

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'ApprovalWorkflowExample',
        key,
        new Map<String, Object>{ 'purchaseAmount' => 500 }
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      // Drives ReserveBudgetStep -> RequestApprovalStep -> suspends awaiting approval.
      WorkflowTestHarness.Result suspended = harness.drive();
      Test.stopTest();

      System.assertEquals(
        'Suspended',
        suspended.status,
        'Instance must suspend awaiting the approval signal'
      );
      System.assert(
        suspended.reachedStep('ApprovalWorkflowExample.ReserveBudgetStep'),
        'Budget should have been reserved before the approval gate'
      );

      // The "human" approves by signalling the workflow through the shipped signal path.
      WorkflowTestHarness.Result done = harness.injectSignal(
        key,
        ApprovalWorkflowExample.DECISION_SIGNAL,
        '{"approved":true,"approver":"manager@example.com"}'
      );

      System.assertEquals(
        'Completed',
        done.status,
        'Approved workflow must reach Completed'
      );
      System.assert(
        done.output.contains('"result":"approved"'),
        'Output must confirm the approved outcome, got: ' + done.output
      );
      System.assertEquals(
        0,
        done.compensatedSteps.size(),
        'Approved path must not trigger any compensation'
      );
    }
  }

  /**
   * Rejected round trip: the reject branch throws, the engine rolls the prior
   * CompensatableStep back in LIFO order, and the instance reaches Compensated.
   */
  @IsTest
  static void testRejectedRoundTripCompensatesPriorWork() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String key = KEY_PREFIX + '2';

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'ApprovalWorkflowExample',
        key,
        new Map<String, Object>{ 'purchaseAmount' => 9000 }
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      WorkflowTestHarness.Result suspended = harness.drive();
      Test.stopTest();

      System.assertEquals('Suspended', suspended.status);

      // The "human" rejects.
      WorkflowTestHarness.Result done = harness.injectSignal(
        key,
        ApprovalWorkflowExample.DECISION_SIGNAL,
        '{"approved":false,"reason":"over budget"}'
      );

      System.assertEquals(
        'Compensated',
        done.status,
        'Rejected workflow must reach Compensated after LIFO rollback'
      );
      System.assertEquals(
        new List<String>{
          'ApprovalWorkflowExample.ReserveBudgetStep_Compensate'
        },
        done.compensatedSteps,
        'The reserved budget must be the (only) compensated step'
      );

      // Verify the compensation detail from the append-only audit trail.
      assertReservationReleased(instanceId);
    }
  }

  /**
   * At-least-once redelivery: the same rejection signal delivered twice must not
   * double-advance the workflow or compensate twice. The engine consumes both
   * buffered signal records when the gate step completes.
   */
  @IsTest
  static void testDuplicateRejectSignalIsIdempotent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String key = KEY_PREFIX + '3';

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'ApprovalWorkflowExample',
        key,
        new Map<String, Object>{ 'purchaseAmount' => 1000 }
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      WorkflowTestHarness.Result suspended = harness.drive();
      Test.stopTest();

      System.assertEquals('Suspended', suspended.status);

      // Deliver the rejection twice (at-least-once redelivery) before resuming.
      String decision = '{"approved":false,"reason":"duplicate test"}';
      WorkflowEngine.signal(
        key,
        ApprovalWorkflowExample.DECISION_SIGNAL,
        decision
      );
      WorkflowEngine.signal(
        key,
        ApprovalWorkflowExample.DECISION_SIGNAL,
        decision
      );

      System.assertEquals(
        2,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Received'
        ],
        'Both signals must be buffered before resume'
      );

      WorkflowTestHarness.Result done = harness.drive();

      System.assertEquals(
        'Compensated',
        done.status,
        'Instance must reach Compensated'
      );

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
          WHERE
            Workflow_Instance__c = :instanceId
            AND Step_Name__c LIKE '%_Compensate'
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
}
