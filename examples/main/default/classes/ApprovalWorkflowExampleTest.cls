@IsTest
private class ApprovalWorkflowExampleTest {
  static final String KEY_PREFIX = 'ApprovalWorkflow_Test_';

  /**
   * @description Asserts the append-only audit trail recorded exactly one compensation
   * whose logged output confirms the reserved budget was released.
   * @param instanceId The workflow instance whose compensation log is inspected.
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
   * @description Returns the notification anchor rows of an instance.
   * @param instanceId The workflow instance.
   * @return The Workflow_Log__c rows of type Notification.
   */
  private static List<Workflow_Log__c> notificationRows(Id instanceId) {
    return [
      SELECT Outcome__c, Message__c
      FROM Workflow_Log__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Log_Type__c = :WorkflowNotifier.LOG_TYPE
      WITH SYSTEM_MODE
    ];
  }

  /**
   * Issue #123: the approval gate asks the engine to notify the approver in
   * the workflow input. The example has no Messaging code.
   */
  @IsTest
  static void testApproverIsNotified() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String key = KEY_PREFIX + 'notify';
      String approverId = String.valueOf(UserInfo.getUserId());
      // Any Id: test context does not call send().
      WorkflowNotifier.typeIds.put(
        WorkflowNotification.DEFAULT_TYPE,
        UserInfo.getOrganizationId()
      );

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'ApprovalWorkflowExample',
        key,
        new Map<String, Object>{
          'purchaseAmount' => 500,
          ApprovalWorkflowExample.APPROVER_KEY => approverId
        }
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      WorkflowTestHarness.Result suspended = harness.drive();
      Test.stopTest();

      Assert.areEqual('Suspended', suspended.status);
      Assert.areEqual(
        1,
        WorkflowNotifier.publishedEvents.size(),
        'One notify request for the approval wait'
      );
      Test.getEventBus().deliver();
      List<Workflow_Log__c> rows = notificationRows(instanceId);
      Assert.areEqual(1, rows.size(), 'One anchor row for the wait');
      Assert.areEqual(WorkflowNotifier.OUTCOME_SENT, rows[0].Outcome__c);
      Assert.areEqual(1, WorkflowNotifier.sentNotifications.size());
      Assert.areEqual(
        new Set<String>{ approverId },
        WorkflowNotifier.sentNotifications[0].recipients,
        'The approver in the input gets the notification'
      );
      Assert.areEqual(
        instanceId,
        WorkflowNotifier.sentNotifications[0].targetId,
        'The notification opens the waiting instance'
      );

      WorkflowTestHarness.Result done = harness.injectSignal(
        key,
        ApprovalWorkflowExample.DECISION_SIGNAL,
        '{"approved":true}'
      );
      Assert.areEqual('Completed', done.status);
      Assert.areEqual(
        1,
        WorkflowNotifier.publishedEvents.size(),
        'The approval must not notify again'
      );
    }
  }

  /**
   * Issue #123: unit test of the gate with StepContextTestBuilder (0 DML).
   */
  @IsTest
  static void testGateRequestsNotificationForApprover() {
    StepContext ctx = new StepContextTestBuilder()
      .workflowInput(
        new Map<String, Object>{
          'purchaseAmount' => 750,
          ApprovalWorkflowExample.APPROVER_KEY => UserInfo.getUserId()
        }
      )
      .build();

    StepResult result = new ApprovalWorkflowExample.RequestApprovalStep()
      .execute(ctx);

    Assert.areEqual(
      StepResult.ActionType.WAIT_FOR_APPROVAL,
      result.directive().action
    );
    WorkflowNotification n = result.directive().notification;
    Assert.isNotNull(n, 'The gate must request a notification');
    Assert.areEqual(
      new Set<String>{ ApprovalWorkflowExample.APPROVER_KEY },
      n.inputKeys
    );
    Assert.isTrue(n.body.contains('750'), n.body);
  }

  /**
   * Issue #123: with no approver in the input, the gate notifies the owner of
   * the instance (the user who started it).
   */
  @IsTest
  static void testGateFallsBackToInstanceOwner() {
    StepContext ctx = new StepContextTestBuilder()
      .workflowInput(new Map<String, Object>{ 'purchaseAmount' => 10 })
      .build();

    StepResult result = new ApprovalWorkflowExample.RequestApprovalStep()
      .execute(ctx);

    WorkflowNotification n = result.directive().notification;
    Assert.isTrue(n.inputKeys.isEmpty());
    Assert.areEqual(new Set<Id>{ ctx.workflowInstanceId }, n.ownerRecordIds);
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
        new Map<String, Object>{
          'purchaseAmount' => 500,
          ApprovalWorkflowExample.APPROVER_KEY => UserInfo.getUserId()
        }
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

      // Issue #123: no approver in the input. The owner fallback still makes
      // one request, and the saga is not changed.
      Assert.areEqual(1, notificationRows(instanceId).size());
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
