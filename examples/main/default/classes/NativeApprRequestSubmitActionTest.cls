@isTest
private class NativeApprRequestSubmitActionTest {
  @testSetup
  static void setup() {
    User thisUser = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
    System.runAs(thisUser) {
      List<PermissionSet> existingPs = [
        SELECT Id
        FROM PermissionSet
        WHERE Name = 'Revenant_Examples_Access'
        LIMIT 1
      ];
      PermissionSet ps;
      if (existingPs.isEmpty()) {
        ps = new PermissionSet(
          Name = 'Revenant_Examples_Access',
          Label = 'Revenant Examples Access'
        );
        insert ps;

        ObjectPermissions op = new ObjectPermissions(
          ParentId = ps.Id,
          SobjectType = 'Approval_Request__c',
          PermissionsRead = true,
          PermissionsCreate = true,
          PermissionsEdit = true
        );
        insert op;

        List<FieldPermissions> fps = new List<FieldPermissions>{
          new FieldPermissions(
            ParentId = ps.Id,
            SobjectType = 'Approval_Request__c',
            Field = 'Approval_Request__c.Amount__c',
            PermissionsRead = true,
            PermissionsEdit = true
          ),
          new FieldPermissions(
            ParentId = ps.Id,
            SobjectType = 'Approval_Request__c',
            Field = 'Approval_Request__c.Approval_Comments__c',
            PermissionsRead = true,
            PermissionsEdit = true
          ),
          new FieldPermissions(
            ParentId = ps.Id,
            SobjectType = 'Approval_Request__c',
            Field = 'Approval_Request__c.Correlation_Key__c',
            PermissionsRead = true,
            PermissionsEdit = true
          )
        };
        insert fps;
      } else {
        ps = existingPs[0];
      }

      List<PermissionSetAssignment> existingPsa = [
        SELECT Id
        FROM PermissionSetAssignment
        WHERE AssigneeId = :thisUser.Id AND PermissionSetId = :ps.Id
        LIMIT 1
      ];
      if (existingPsa.isEmpty()) {
        PermissionSetAssignment psa = new PermissionSetAssignment(
          AssigneeId = thisUser.Id,
          PermissionSetId = ps.Id
        );
        insert psa;
      }
    }
  }

  /**
   * Submission must fail gracefully (captured on the result, never thrown) when Approval.process()
   * can't find a matching Approval Process. This must be deterministic regardless of whether the
   * shipped Approval Process has since been activated in this org (the README's documented next
   * step), so the request explicitly names a definitely-nonexistent process rather than relying
   * on the shipped process still being inactive.
   */
  @isTest
  static void testSubmitWithNoActiveProcessCapturesFailureGracefully() {
    User thisUser = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
    System.runAs(thisUser) {
      Approval_Request__c rec = new Approval_Request__c(Amount__c = 100);
      insert rec;

      NativeApprRequestSubmitAction.SubmitRequest req = new NativeApprRequestSubmitAction.SubmitRequest();
      req.recordId = rec.Id;
      req.processDefinitionNameOrId = 'Nonexistent_Approval_Process_For_Test_Only';

      Test.startTest();
      List<NativeApprRequestSubmitAction.SubmitResult> results = NativeApprRequestSubmitAction.submitForApproval(
        new List<NativeApprRequestSubmitAction.SubmitRequest>{ req }
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
  }

  @isTest
  static void testEmptyRequestListReturnsEmptyResults() {
    Test.startTest();
    List<NativeApprRequestSubmitAction.SubmitResult> results = NativeApprRequestSubmitAction.submitForApproval(
      new List<NativeApprRequestSubmitAction.SubmitRequest>()
    );
    Test.stopTest();

    System.assertEquals(0, results.size());
  }
}
