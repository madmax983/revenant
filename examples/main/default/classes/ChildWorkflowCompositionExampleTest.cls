/**
 * Deterministic end-to-end test for ChildWorkflowCompositionExample.
 *
 * Acceptance criteria from issue #30
 * ────────────────────────────────────
 * [AC-c] Parent reaches Completed; child exists with Parent_Instance__c pointing at
 *        parent; parent consumed the child's credit-score output to drive its branch.
 * [AC-d] Cancelling the parent while the child is in-flight reaps the descendant
 *        (verified via Parent_Instance__c / child Status__c).
 * [AC-e] A redelivered ChildCompleted signal does not double-advance the parent
 *        (ApproveLoanStep fires exactly once; both signals end up Consumed).
 */
@isTest
private class ChildWorkflowCompositionExampleTest {

  // High-score applicant: income=100 000, amount=50 000 → score=690 (≥680, approved)
  private static final Map<String, Object> HIGH_SCORE_INPUT = new Map<String, Object>{
    'applicant' => 'Alice',
    'annualIncome' => 100000,
    'requestedAmount' => 50000
  };

  // Low-score applicant: income=20 000, amount=200 000 → score=580 (<680, declined)
  private static final Map<String, Object> LOW_SCORE_INPUT = new Map<String, Object>{
    'applicant' => 'Bob',
    'annualIncome' => 20000,
    'requestedAmount' => 200000
  };

  /**
   * [AC-c] Happy path — high-score applicant.
   *
   * harness.drive() advances the full parent→child→resume→terminal tree in one
   * call: it discovers the child via collectTree(), drives it to Completed (which
   * publishes the ChildCompleted Platform Event), delivers the event on the next
   * hop (deliverEvents()), wakes the parent, and drives it to Completed.
   *
   * Asserts:
   *   (a) parent Status__c = Completed
   *   (b) child exists with Parent_Instance__c = parentId, Status__c = Completed
   *   (c) parent output carries the child's creditScore (690) and the approved decision
   *   (d) ApproveLoanStep reached; DeclineLoanStep not reached
   *
   * The decline variant runs immediately after to prove the branch is genuinely
   * driven by the child-produced score, not hardwired.
   */
  @isTest
  static void testParentBranchesOnChildCreditScore() {
    // --- approve branch ---
    Test.startTest();
    Id parentId = WorkflowEngine.start(
      'ChildWorkflowCompositionExample',
      'LoanApp_Alice',
      HIGH_SCORE_INPUT
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(parentId);
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals(
      'Completed',
      result.status,
      'High-score parent must reach Completed'
    );
    System.assert(
      result.output.contains('"approved"'),
      'Output must carry the approved decision, got: ' + result.output
    );
    System.assert(
      result.output.contains('690') || result.output.contains('"creditScore":690'),
      'Output must carry the child-produced credit score (690), got: ' + result.output
    );
    System.assert(
      result.reachedStep(
        'ChildWorkflowCompositionExample.ApproveLoanStep'
      ),
      'ApproveLoanStep must have run for high-score applicant'
    );
    System.assert(
      !result.reachedStep(
        'ChildWorkflowCompositionExample.DeclineLoanStep'
      ),
      'DeclineLoanStep must NOT run for high-score applicant'
    );

    // (b) child exists, linked to parent, and Completed
    Workflow_Instance__c childInst = [
      SELECT Status__c, Parent_Instance__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :parentId
      LIMIT 1
    ];
    System.assertNotEquals(
      null,
      childInst,
      'A child instance must have been created'
    );
    System.assertEquals(
      parentId,
      childInst.Parent_Instance__c,
      'Child Parent_Instance__c must point at the parent'
    );
    System.assertEquals(
      'Completed',
      childInst.Status__c,
      'Child must reach Completed'
    );

    // --- decline branch (same method, separate start) ---
    Id parentId2 = WorkflowEngine.start(
      'ChildWorkflowCompositionExample',
      'LoanApp_Bob',
      LOW_SCORE_INPUT
    );
    WorkflowTestHarness harness2 = new WorkflowTestHarness(parentId2);
    WorkflowTestHarness.Result result2 = harness2.drive();

    System.assertEquals(
      'Completed',
      result2.status,
      'Low-score parent must also reach Completed (decision = declined)'
    );
    System.assert(
      result2.output.contains('"declined"'),
      'Output must carry the declined decision, got: ' + result2.output
    );
    System.assert(
      result2.reachedStep(
        'ChildWorkflowCompositionExample.DeclineLoanStep'
      ),
      'DeclineLoanStep must have run for low-score applicant'
    );
    System.assert(
      !result2.reachedStep(
        'ChildWorkflowCompositionExample.ApproveLoanStep'
      ),
      'ApproveLoanStep must NOT run for low-score applicant'
    );
  }

  /**
   * [AC-d] Cancellation propagation.
   *
   * After the parent launches the child (parent Suspended, child Pending/Running)
   * WorkflowEngine.cancel(parentId, false) must cancel both the parent and the
   * in-flight child instance.
   */
  @isTest
  static void testCancellingParentReapsInFlightChild() {
    Test.startTest();
    Id parentId = WorkflowEngine.start(
      'ChildWorkflowCompositionExample',
      'LoanApp_Cancel',
      HIGH_SCORE_INPUT
    );
    WorkflowTestHarness parentHarness = new WorkflowTestHarness(parentId);

    // Advance exactly one step: RequestCreditCheckStep issues startChild.
    // Parent becomes Suspended; child instance is created but not yet driven.
    parentHarness.step();
    Test.stopTest();

    Workflow_Instance__c parentInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    System.assertEquals(
      'Suspended',
      parentInst.Status__c,
      'Parent must be Suspended while awaiting the child'
    );

    Workflow_Instance__c childInst = [
      SELECT Id, Status__c, Parent_Instance__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :parentId
      LIMIT 1
    ];
    System.assertNotEquals(
      null,
      childInst,
      'Child instance must exist before cancellation'
    );
    System.assertEquals(
      parentId,
      childInst.Parent_Instance__c,
      'Child Parent_Instance__c must reference the parent'
    );

    // Cancel the parent — the engine cancels the parent and all of its active
    // descendants (root-first traversal over Parent_Instance__c), reaping the
    // in-flight child.
    WorkflowEngine.cancel(parentId, false);

    Workflow_Instance__c cancelledParent = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    System.assertEquals(
      'Cancelled',
      cancelledParent.Status__c,
      'Parent must be Cancelled after WorkflowEngine.cancel()'
    );

    Workflow_Instance__c cancelledChild = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :childInst.Id
    ];
    System.assertEquals(
      'Cancelled',
      cancelledChild.Status__c,
      'Descendant child must be Cancelled when parent is cancelled'
    );
  }

  /**
   * Idempotent launch — re-entering the launcher while the child is still in flight
   * (no ChildCompleted signal yet) must NOT start a second child.  The engine
   * re-runs the current step on any stray orchestrator hop while Suspended; without
   * the guard the second startChild() would hit the duplicate-active-key check and
   * fail the parent.  Here we reproduce that stray hop with a direct runStep().
   */
  @isTest
  static void testReentrantLaunchDoesNotStartDuplicateChild() {
    Test.startTest();
    Id parentId = WorkflowEngine.start(
      'ChildWorkflowCompositionExample',
      'LoanApp_Reentry',
      HIGH_SCORE_INPUT
    );
    WorkflowTestHarness parentHarness = new WorkflowTestHarness(parentId);

    // First run: startChild → parent Suspended, exactly one child created.
    parentHarness.step();

    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :parentId
      ],
      'Exactly one child must exist after the first launcher run'
    );

    // Reproduce a stray orchestrator hop re-entering the still-suspended launcher.
    // The guard must re-suspend rather than launching a duplicate or failing.
    WorkflowEngine.runStep(parentId, null);
    Test.stopTest();

    Workflow_Instance__c parentInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    System.assertEquals(
      'Suspended',
      parentInst.Status__c,
      'Parent must remain Suspended after a re-entrant launcher run (not Failed)'
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :parentId
      ],
      'Re-entry must NOT start a duplicate child'
    );
  }

  /**
   * [AC-e] Idempotent resume — redelivered ChildCompleted does not double-advance.
   *
   * Sequence:
   *   1. Start parent; step() once → RequestCreditCheckStep issues startChild →
   *      parent Suspended.
   *   2. Drive the child alone to Completed via a separate harness (publishes
   *      ChildCompleted Workflow_Event__e into the event bus, NOT yet delivered).
   *   3. Inject a duplicate ChildCompleted signal directly via WorkflowEngine.signal
   *      (simulates at-least-once Platform Event redelivery) → parent transitions
   *      Suspended→Running; one Workflow_Signal__c record inserted.
   *   4. parentHarness.drive() → deliverEvents() delivers the queued event from
   *      step 2, inserting a second Workflow_Signal__c → two Received signals.
   *      The step reads one via ctx.getSignal(); COMPLETE triggers markSignalsConsumed
   *      which consumes ALL same-name Received signals → ApproveLoanStep fires once
   *      → parent Completed.
   *
   * Asserts:
   *   - parent Completed
   *   - ApproveLoanStep fired exactly once (not twice)
   *   - 0 Received, 2 Consumed ChildCompleted signals on the parent
   */
  @isTest
  static void testRedeliveredChildCompletedDoesNotDoubleAdvance() {
    Test.startTest();
    Id parentId = WorkflowEngine.start(
      'ChildWorkflowCompositionExample',
      'LoanApp_Idem',
      HIGH_SCORE_INPUT
    );
    WorkflowTestHarness parentHarness = new WorkflowTestHarness(parentId);

    // 1. Run RequestCreditCheckStep (first run) — startChild, parent Suspended.
    parentHarness.step();
    Test.stopTest();

    Workflow_Instance__c childInstRec = [
      SELECT Id, Output__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :parentId
      LIMIT 1
    ];

    // 2. Drive the child to Completed with its own harness.
    //    notifyParentCompletion publishes ChildCompleted Workflow_Event__e —
    //    NOT yet delivered (Test.getEventBus().deliver() not called yet).
    new WorkflowTestHarness(childInstRec.Id).drive();

    // Fetch the child's serialised output to use as the duplicate payload.
    childInstRec = [
      SELECT Output__c
      FROM Workflow_Instance__c
      WHERE Id = :childInstRec.Id
    ];
    String childOutputJson = childInstRec.Output__c;

    // 3. Inject duplicate ChildCompleted via the public signal API (at-least-once
    //    redelivery simulation). WorkflowEngine.signal() directly inserts a
    //    Workflow_Signal__c and transitions the parent Suspended→Running.
    String childKey = 'CreditCheck_' + parentId;
    WorkflowEngine.signal(
      'LoanApp_Idem',
      'ChildCompleted:' + childKey,
      childOutputJson
    );

    // 4. parentHarness.drive() → deliverEvents() processes the queued event from
    //    step 2 (second Received signal) → parent is Running → step resumes →
    //    reads signal, returns COMPLETE → markSignalsConsumed consumes both →
    //    ApproveLoanStep runs → parent Completed.
    WorkflowTestHarness.Result result = parentHarness.drive();

    System.assertEquals(
      'Completed',
      result.status,
      'Parent must reach Completed after idempotent resume'
    );

    // ApproveLoanStep fired exactly once despite the duplicate signal.
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :parentId
          AND Step_Name__c = 'ChildWorkflowCompositionExample.ApproveLoanStep'
          AND Status__c = 'Completed'
      ],
      'ApproveLoanStep must fire exactly once (idempotent resume)'
    );

    // Engine consumed every Received signal of the observed name.
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :parentId
          AND Status__c = 'Received'
      ],
      'No signals must remain Received after COMPLETE transition'
    );
    System.assertEquals(
      2,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :parentId
          AND Status__c = 'Consumed'
      ],
      'Both the original and duplicate ChildCompleted signals must be Consumed'
    );
  }
}
