@IsTest
private class NativeApprovalWorkflowExampleTest {
  static final String KEY_PREFIX = 'NativeApprovalWorkflow_Test_';

  /**
   * Approved round trip: start -> Suspended on the approval gate -> the decision signal
   * (the exact payload the outbound record-triggered Flow publishes) -> resume -> Completed.
   *
   * Drives through WorkflowTestHarness so the failing/throwing reject path (in the other
   * cases) is rescued by the engine's own crash handler, exactly as WorkflowFinalizer does
   * in production.
   */
  @IsTest
  static void testApprovedRoundTripReachesCompleted() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String key = KEY_PREFIX + '1';

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'NativeApprovalWorkflowExample',
        key,
        new Map<String, Object>{ 'amount' => 500 }
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
        suspended.reachedStep(
          'NativeApprovalWorkflowExample.ReserveBudgetStep'
        ),
        'Budget should have been reserved before the approval gate'
      );

      // The native Approval Process reached final approval; its field-update final action
      // flips Approval_Status__c, and the outbound record-triggered Flow publishes this
      // exact signal via WorkflowSignalInvocableAction.
      WorkflowTestHarness.Result done = harness.injectSignal(
        key,
        NativeApprovalWorkflowExample.DECISION_SIGNAL,
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
   * CompensatableStep back in LIFO order, and the instance reaches Compensated -- the
   * saga rollback a native Approval Process alone cannot express.
   */
  @IsTest
  static void testRejectedRoundTripCompensates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String key = KEY_PREFIX + '2';

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'NativeApprovalWorkflowExample',
        key,
        new Map<String, Object>{ 'amount' => 9000 }
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      WorkflowTestHarness.Result suspended = harness.drive();
      Test.stopTest();

      System.assertEquals('Suspended', suspended.status);

      // The native Approval Process reached final rejection; the outbound Flow publishes
      // the reject decision the same way.
      WorkflowTestHarness.Result done = harness.injectSignal(
        key,
        NativeApprovalWorkflowExample.DECISION_SIGNAL,
        '{"approved":false,"comments":"over budget"}'
      );

      System.assertEquals(
        'Compensated',
        done.status,
        'Rejected workflow must reach Compensated after LIFO rollback'
      );
      System.assertEquals(
        new List<String>{
          'NativeApprovalWorkflowExample.ReserveBudgetStep_Compensate'
        },
        done.compensatedSteps,
        'The reserved budget must be the (only) compensated step'
      );

      // Verify the compensation detail from the append-only audit trail.
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
  }

  /**
   * At-least-once redelivery: a record-triggered Flow can re-fire (recalculation, retry)
   * and publish the same decision signal twice. The engine must not double-advance the
   * workflow or compensate twice -- proving the action path resolves solely through the
   * idempotent Approve: signal with no other mutation.
   */
  @IsTest
  static void testDuplicateDecisionSignalIsIdempotent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String key = KEY_PREFIX + '3';

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'NativeApprovalWorkflowExample',
        key,
        new Map<String, Object>{ 'amount' => 1000 }
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      WorkflowTestHarness.Result suspended = harness.drive();
      Test.stopTest();

      System.assertEquals('Suspended', suspended.status);

      // Deliver the rejection twice (at-least-once redelivery) before resuming.
      String decision = '{"approved":false,"comments":"duplicate test"}';
      WorkflowEngine.signal(
        key,
        NativeApprovalWorkflowExample.DECISION_SIGNAL,
        decision
      );
      WorkflowEngine.signal(
        key,
        NativeApprovalWorkflowExample.DECISION_SIGNAL,
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
            AND Step_Name__c = 'NativeApprovalWorkflowExample.RejectStep'
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

      // Engine must have consumed all signal records -- proving the action path resolves
      // solely through the Approve: signal (no other DML against these records is needed
      // for the decision to take effect exactly once).
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
