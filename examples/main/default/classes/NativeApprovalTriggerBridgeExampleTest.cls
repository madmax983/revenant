@isTest
private class NativeApprovalTriggerBridgeExampleTest {

  /**
   * Unlike the Flow-based bridge (whose Flow layer can't be driven end-to-end in an Apex
   * test), this whole round trip -- Case insert, workflow start, native submission attempt,
   * Case update, decision signal -- runs through real DML and the actual trigger, not
   * WorkflowEngine.start()/signal() called directly or WorkflowTestHarness.injectSignal().
   */
  @isTest
  static void testApprovedRoundTripReachesCompleted() {
    Case cse = new Case(Subject = 'Trigger bridge approved test');

    Test.startTest();
    insert cse;
    WorkflowTestHarness harness = new WorkflowTestHarness(queryInstanceId(cse.Id));
    WorkflowTestHarness.Result suspended = harness.drive();
    Test.stopTest();

    System.assertEquals(
      'Suspended',
      suspended.status,
      'Instance must suspend awaiting the approval signal'
    );
    System.assert(
      suspended.reachedStep('NativeApprovalWorkflowExample.ReserveBudgetStep'),
      'Budget should have been reserved before the approval gate'
    );

    cse.Approval_Status__c = 'Approved';
    update cse;

    WorkflowTestHarness.Result done = harness.drive();

    System.assertEquals('Completed', done.status, 'Approved workflow must reach Completed');
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

  @isTest
  static void testRejectedRoundTripCompensates() {
    Case cse = new Case(Subject = 'Trigger bridge rejected test');

    Test.startTest();
    insert cse;
    WorkflowTestHarness harness = new WorkflowTestHarness(queryInstanceId(cse.Id));
    WorkflowTestHarness.Result suspended = harness.drive();
    Test.stopTest();

    System.assertEquals('Suspended', suspended.status);

    cse.Approval_Status__c = 'Rejected';
    update cse;

    WorkflowTestHarness.Result done = harness.drive();

    System.assertEquals(
      'Compensated',
      done.status,
      'Rejected workflow must reach Compensated after LIFO rollback'
    );
    System.assertEquals(
      new List<String>{ 'NativeApprovalWorkflowExample.ReserveBudgetStep_Compensate' },
      done.compensatedSteps
    );
  }

  /**
   * Proves the trigger's bulk-safe design: inserting several Cases in one DML statement
   * starts one independent workflow instance per Case, correlated by that Case's own Id.
   */
  @isTest
  static void testBulkInsertStartsIndependentInstances() {
    List<Case> cases = new List<Case>{
      new Case(Subject = 'Bulk trigger bridge test 1'),
      new Case(Subject = 'Bulk trigger bridge test 2'),
      new Case(Subject = 'Bulk trigger bridge test 3')
    };

    Test.startTest();
    insert cases;
    Test.stopTest();

    for (Case cse : cases) {
      WorkflowTestHarness harness = new WorkflowTestHarness(queryInstanceId(cse.Id));
      WorkflowTestHarness.Result suspended = harness.drive();
      System.assertEquals(
        'Suspended',
        suspended.status,
        'Each Case in the bulk insert must independently reach Suspended'
      );
    }
  }

  /**
   * The shipped Approval Process ships inactive (Approval Processes always deploy inactive).
   * Approval.process() failing to find a match must be captured, not allowed to propagate --
   * so inserting a Case never throws even though the native submission fails, and the
   * workflow still reaches Suspended regardless of the submission outcome.
   */
  @isTest
  static void testInsertDoesNotThrowWhenApprovalProcessInactive() {
    Case cse = new Case(Subject = 'Trigger bridge inactive process test');

    Test.startTest();
    insert cse;
    WorkflowTestHarness.Result suspended = new WorkflowTestHarness(queryInstanceId(cse.Id)).drive();
    Test.stopTest();

    System.assertEquals(
      'Suspended',
      suspended.status,
      'Workflow must still start and suspend even if native submission fails gracefully'
    );
  }

  private static Id queryInstanceId(Id caseId) {
    return [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :String.valueOf(caseId)
      LIMIT 1
    ]
    .Id;
  }
}
