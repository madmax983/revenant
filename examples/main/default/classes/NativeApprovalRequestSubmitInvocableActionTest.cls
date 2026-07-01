@isTest
private class NativeApprovalRequestSubmitInvocableActionTest {

  /**
   * The shipped Approval Process ships inactive (Approval Processes always deploy inactive).
   * In an org where it has not yet been activated, Approval.process() cannot find a matching
   * process and Salesforce throws -- this must be captured on the result, not allowed to
   * propagate, so the invocable never faults the Flow interview or blocks the workflow-start
   * action that runs before it in Revenant_Start_Approval_Workflow_Example.
   */
  @isTest
  static void testSubmitWithNoActiveProcessCapturesFailureGracefully() {
    Approval_Request__c rec = new Approval_Request__c(Amount__c = 100);
    insert rec;

    NativeApprovalRequestSubmitInvocableAction.SubmitRequest req =
      new NativeApprovalRequestSubmitInvocableAction.SubmitRequest();
    req.recordId = rec.Id;

    Test.startTest();
    List<NativeApprovalRequestSubmitInvocableAction.SubmitResult> results =
      NativeApprovalRequestSubmitInvocableAction.submitForApproval(
        new List<NativeApprovalRequestSubmitInvocableAction.SubmitRequest>{ req }
      );
    Test.stopTest();

    System.assertEquals(1, results.size(), 'One result per request');
    System.assertEquals(
      false,
      results[0].success,
      'Submission must fail gracefully (captured, not thrown) while no Approval Process is active'
    );
    System.assert(
      String.isNotBlank(results[0].errorMessage),
      'The failure reason must be captured for the caller to inspect'
    );
  }

  @isTest
  static void testEmptyRequestListReturnsEmptyResults() {
    Test.startTest();
    List<NativeApprovalRequestSubmitInvocableAction.SubmitResult> results =
      NativeApprovalRequestSubmitInvocableAction.submitForApproval(
        new List<NativeApprovalRequestSubmitInvocableAction.SubmitRequest>()
      );
    Test.stopTest();

    System.assertEquals(0, results.size());
  }
}
