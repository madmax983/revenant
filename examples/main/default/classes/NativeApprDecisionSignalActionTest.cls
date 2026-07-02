@isTest
private class NativeApprDecisionSignalActionTest {
  static final String KEY_PREFIX = 'NativeApprovalDecisionSignal_Test_';

  /**
   * A comment containing a line break is exactly the input that broke the old hand-built
   * Flow-formula JSON (an unescaped newline inside a JSON string is invalid). JSON.serialize()
   * must escape it correctly so the workflow still resumes to Completed.
   */
  @isTest
  static void testApprovedDecisionWithMultilineCommentsResumesWorkflow() {
    String key = KEY_PREFIX + '1';

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'NativeApprovalWorkflowExample',
      key,
      new Map<String, Object>{ 'amount' => 500 }
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result suspended = harness.drive();
    Test.stopTest();

    System.assertEquals('Suspended', suspended.status);

    NativeApprDecisionSignalAction.DecisionRequest req = new NativeApprDecisionSignalAction.DecisionRequest();
    req.targetKey = key;
    req.approved = true;
    req.comments = 'Looks good.\nApproved as discussed in the review meeting.';
    req.approverName = 'Jane Manager';

    NativeApprDecisionSignalAction.signalDecision(
      new List<NativeApprDecisionSignalAction.DecisionRequest>{ req }
    );

    WorkflowTestHarness.Result done = harness.drive();

    System.assertEquals(
      'Completed',
      done.status,
      'Approved workflow must reach Completed even with a multi-line comment'
    );
    System.assert(
      done.output.contains('"result":"approved"'),
      'Output must confirm the approved outcome, got: ' + done.output
    );
  }

  /**
   * A comment containing embedded double quotes and a backslash -- the other characters the
   * old formula's hand-rolled SUBSTITUTE-based escaping had to get right manually.
   */
  @isTest
  static void testRejectedDecisionWithQuotesAndBackslashesCompensates() {
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

    NativeApprDecisionSignalAction.DecisionRequest req = new NativeApprDecisionSignalAction.DecisionRequest();
    req.targetKey = key;
    req.approved = false;
    req.comments = 'Over budget -- see "Q3 plan" at C:\\budgets\\q3.xlsx';

    NativeApprDecisionSignalAction.signalDecision(
      new List<NativeApprDecisionSignalAction.DecisionRequest>{ req }
    );

    WorkflowTestHarness.Result done = harness.drive();

    System.assertEquals(
      'Compensated',
      done.status,
      'Rejected workflow must reach Compensated even with quotes/backslashes in the comment'
    );
  }

  @isTest
  static void testEmptyRequestListIsNoOp() {
    Test.startTest();
    NativeApprDecisionSignalAction.signalDecision(
      new List<NativeApprDecisionSignalAction.DecisionRequest>()
    );
    Test.stopTest();
    // No exception thrown is the assertion.
  }
}
