@isTest
public class SagaStalledRollbackExampleTest {
  /**
   * End-to-end demonstration of the recoverable "rollback incomplete" condition:
   *   1. A 4-step saga charges, reserves, ships, and books a courier (all
   *      compensatable), then a 5th step fails and triggers a LIFO rollback.
   *   2. The second-from-top compensation (ShipOrderStep) fails transiently. The
   *      engine parks the saga in the distinguishable CompensationFailed state and
   *      preserves the remaining un-run stack intact (depth reported = 3).
   *   3. The operator resumes the rollback from exactly the stalled point. The
   *      transient failure has cleared, so every remaining compensation runs in
   *      strict LIFO order and the saga ends fully Compensated.
   *   4. Every forward step is compensated exactly once; no compensation that
   *      already succeeded is re-run, and no forward step is re-executed.
   */
  @isTest
  static void testStalledRollbackResumesToFullyCompensated() {
    WorkflowEngine.disableQueueableInTest = true;
    SagaStalledRollbackExample.failShipmentCompensation = true;

    Test.startTest();

    Id instanceId = WorkflowEngine.start(
      'SagaStalledRollbackExample.StalledSagaWorkflow',
      'StalledSagaKey_1',
      '{"orderId":"ord_777"}'
    );

    // Drive the four compensatable forward steps to completion.
    WorkflowEngine.runStep(instanceId, null); // ChargeCardStep
    WorkflowEngine.runStep(instanceId, null); // ReserveInventoryStep
    WorkflowEngine.runStep(instanceId, null); // ShipOrderStep
    WorkflowEngine.runStep(instanceId, null); // BookCourierStep

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c, Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'SagaStalledRollbackExample.ConfirmDeliveryStep',
      inst.Current_Step__c,
      'Should be poised on the failing forward step'
    );
    List<String> stack = (List<String>) JSON.deserialize(
      inst.Compensation_Stack__c,
      List<String>.class
    );
    System.assertEquals(4, stack.size(), 'All four forward steps recorded');

    // Run the failing forward step -> triggers Saga compensation.
    try {
      WorkflowEngine.runStep(instanceId, null);
      System.assert(false, 'ConfirmDeliveryStep should have thrown');
    } catch (Exception ex) {
      WorkflowEngine.handleCrash(instanceId, ex);
    }

    inst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'Compensating',
      inst.Status__c,
      'Forward failure should kick off rollback'
    );

    // Compensate BookCourierStep (top of stack) -> succeeds, pops to depth 3.
    WorkflowEngine.runStep(instanceId, null);
    // Compensate ShipOrderStep (second-from-top) -> throws transiently -> stalls.
    WorkflowEngine.runStep(instanceId, null);

    inst = [
      SELECT Status__c, Compensation_Stack__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];

    // AC: distinguishable "rollback incomplete" condition, NOT a generic Failed.
    System.assertEquals(
      'CompensationFailed',
      inst.Status__c,
      'A failed compensation must leave a recoverable, distinguishable state'
    );

    // AC: the remaining LIFO stack is preserved intact (never truncated/popped past
    // the failed step). BookCourierStep was compensated; Ship/Reserve/Charge remain.
    stack = (List<String>) JSON.deserialize(
      inst.Compensation_Stack__c,
      List<String>.class
    );
    System.assertEquals(
      3,
      stack.size(),
      'Three forward steps still have un-reversed side effects'
    );
    System.assertEquals(
      'SagaStalledRollbackExample.ShipOrderStep',
      stack[stack.size() - 1],
      'The stalled compensation remains on top of the stack'
    );

    // AC: operator-visible depth derivable cheaply via the dashboard controller.
    Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
      instanceId
    );
    System.assertEquals(
      3,
      (Integer) details.get('pendingCompensationCount'),
      'Dashboard should report the exact count of un-reversed steps'
    );

    // The transient outage clears, then the operator resumes the rollback.
    SagaStalledRollbackExample.failShipmentCompensation = false;
    WorkflowEngine.resumeCompensation(instanceId);

    // Drive the resumed rollback to completion: Ship -> Reserve -> Charge -> done.
    WorkflowEngine.runStep(instanceId, null); // ShipOrderStep compensate (now succeeds)
    WorkflowEngine.runStep(instanceId, null); // ReserveInventoryStep compensate
    WorkflowEngine.runStep(instanceId, null); // ChargeCardStep compensate
    WorkflowEngine.runStep(instanceId, null); // stack empty -> Compensated

    Test.stopTest();

    inst = [
      SELECT Status__c, Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    // AC: terminal state reflects FULLY compensated, distinct from "failed".
    System.assertEquals(
      'Compensated',
      inst.Status__c,
      'Resumed rollback must reach the fully-compensated terminal state'
    );
    List<String> finalStack = (List<String>) JSON.deserialize(
      inst.Compensation_Stack__c,
      List<String>.class
    );
    System.assertEquals(0, finalStack.size(), 'Stack fully drained');

    // AC: every compensation outcome is an append-only Workflow_Step_Execution__c
    // record; the failed attempt is preserved alongside the successful retry.
    List<Workflow_Step_Execution__c> compLogs = [
      SELECT Step_Name__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c LIKE '%_Compensate'
      ORDER BY CreatedDate ASC, Id ASC
    ];

    // Each of the four forward steps compensated exactly once (Compensated), and
    // ShipOrderStep additionally carries one preserved Failed attempt.
    Integer compensatedCount = 0;
    Integer failedShipAttempts = 0;
    Integer compensatedShipAttempts = 0;
    Set<String> compensatedSteps = new Set<String>();
    for (Workflow_Step_Execution__c log : compLogs) {
      if (log.Status__c == 'Compensated') {
        compensatedCount++;
        System.assert(
          !compensatedSteps.contains(log.Step_Name__c),
          'A successful compensation must never run twice: ' + log.Step_Name__c
        );
        compensatedSteps.add(log.Step_Name__c);
      }
      if (
        log.Step_Name__c ==
        'SagaStalledRollbackExample.ShipOrderStep_Compensate'
      ) {
        if (log.Status__c == 'Failed') {
          failedShipAttempts++;
        } else if (log.Status__c == 'Compensated') {
          compensatedShipAttempts++;
        }
      }
    }

    System.assertEquals(
      4,
      compensatedCount,
      'All four forward steps compensated exactly once'
    );
    System.assertEquals(
      1,
      failedShipAttempts,
      'The transient failed attempt is preserved in the audit trail'
    );
    System.assertEquals(
      1,
      compensatedShipAttempts,
      'ShipOrderStep was successfully compensated on resume'
    );
    System.assert(
      compensatedSteps.contains(
        'SagaStalledRollbackExample.ChargeCardStep_Compensate'
      ),
      'The deepest forward effect (the charge) was reversed end to end'
    );
  }

  /**
   * AC: resuming a stalled rollback is idempotent. A second resume call that races
   * the first (the instance is no longer in CompensationFailed) is a safe no-op and
   * never double-runs a compensation or spawns a second rollback chain.
   */
  @isTest
  static void testResumeCompensationIsIdempotent() {
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'SagaStalledRollbackExample.StalledSagaWorkflow',
      Status__c = 'CompensationFailed',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'SagaStalledRollbackExample.ChargeCardStep' }
      ),
      Error_Message__c = 'Failed at step ...ShipOrderStep_Compensate: boom'
    );
    insert inst;

    Test.startTest();
    // First resume transitions out of the stalled state.
    WorkflowEngine.resumeCompensation(inst.Id);
    // Second (double-click) resume must be a no-op: status is no longer
    // CompensationFailed, so nothing is re-enqueued or mutated.
    WorkflowEngine.resumeCompensation(inst.Id);
    Test.stopTest();

    Workflow_Instance__c afterResume = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      'Compensating',
      afterResume.Status__c,
      'Resume should transition the stalled rollback back into Compensating'
    );

    // Exactly one fresh (non-terminal) compensation attempt was created for the
    // stalled top-of-stack step, never two.
    Integer activeAttempts = [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :inst.Id
        AND Step_Name__c = 'SagaStalledRollbackExample.ChargeCardStep_Compensate'
        AND Status__c IN ('Pending', 'Running', 'Retrying')
    ];
    System.assertEquals(
      1,
      activeAttempts,
      'A double resume must not create two concurrent compensation attempts'
    );
  }
}
