@isTest
private class NativeApprovalRequestSubmitInvocableActionTest {

  /**
   * Submission must fail gracefully (captured on the result, never thrown) when Approval.process()
   * can't find a matching Approval Process. This must be deterministic regardless of whether the
   * shipped Approval Process has since been activated in this org (the README's documented next
   * step), so the request explicitly names a definitely-nonexistent process rather than relying
   * on the shipped process still being inactive.
   */
  @isTest
  static void testSubmitWithNoActiveProcessCapturesFailureGracefully() {
    Approval_Request__c rec = new Approval_Request__c(Amount__c = 100);
    insert rec;

    NativeApprovalRequestSubmitInvocableAction.SubmitRequest req =
      new NativeApprovalRequestSubmitInvocableAction.SubmitRequest();
    req.recordId = rec.Id;
    req.processDefinitionNameOrId = 'Nonexistent_Approval_Process_For_Test_Only';

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
      'Submission must fail gracefully (captured, not thrown) when the named Approval Process does not exist'
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
