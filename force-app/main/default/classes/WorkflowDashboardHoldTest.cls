/**
 * Dashboard tests for per-instance hold and release (issue #119). They cover
 * the hold fields in the list and detail reads, the Hold and Release actions,
 * and the operator-action gate.
 */
@IsTest
private class WorkflowDashboardHoldTest {
  private static final String WF = 'WorkflowInstanceHoldTest.HoldWorkflow';

  private static Id startAndRunFirstHop(String key) {
    WorkflowEngine.disableQueueableInTest = true;
    Id instId = WorkflowEngine.start(WF, key, null);
    WorkflowEngine.runStep(instId);
    return instId;
  }

  @IsTest
  static void testHoldActionRecordsHoldAndDetailsShowIt() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop('DashHold-' + Datetime.now().getTime());
      String outcome = WorkflowDashboardCommandController.holdInstance(
        instId,
        'look at payload'
      );
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        instId
      );
      Test.stopTest();

      System.assertEquals('HELD', outcome, 'Hold returns the outcome name');
      Workflow_Instance__c inst = (Workflow_Instance__c) details.get(
        'instance'
      );
      System.assertEquals(true, inst.Held__c, 'Details carry Held__c');
      System.assertEquals(
        'look at payload',
        inst.Hold_Reason__c,
        'Details carry the reason'
      );
      System.assertNotEquals(null, inst.Held_At__c, 'Details carry held-since');
    }
  }

  @IsTest
  static void testListCarriesHeldFlag() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop(
        'DashHoldList-' + Datetime.now().getTime()
      );
      WorkflowEngine.hold(instId, 'x');
      WorkflowDashboardController.InstanceQuery query = new WorkflowDashboardController.InstanceQuery();
      query.workflowName = WF;
      List<Map<String, Object>> page = WorkflowDashboardController.getFilteredInstances(
        query
      );
      Test.stopTest();
      System.assertEquals(1, page.size(), 'One row');
      System.assertEquals(
        true,
        page[0].get('Held__c'),
        'The list carries Held__c'
      );
    }
  }

  @IsTest
  static void testReleaseActionResumesParkedInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = startAndRunFirstHop('DashRel-' + Datetime.now().getTime());
      WorkflowDashboardCommandController.holdInstance(instId, 'x');
      WorkflowEngine.runStep(instId);
      String outcome = WorkflowDashboardCommandController.releaseHeldInstance(
        instId
      );
      Test.stopTest();
      System.assertEquals('RELEASED', outcome, 'Release returns the outcome');
      System.assertEquals(
        'Running',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instId]
        .Status__c,
        'Release sets Running'
      );
    }
  }

  @IsTest
  static void testHoldActionReportsRejection() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'Completed',
        Correlation_Key__c = 'DashHoldDone-' + Datetime.now().getTime()
      );
      insert inst;
      Test.startTest();
      String outcome = WorkflowDashboardCommandController.holdInstance(
        inst.Id,
        'x'
      );
      Test.stopTest();
      System.assertEquals(
        'REJECTED_TERMINAL',
        outcome,
        'A terminal run is rejected without an exception'
      );
    }
  }

  @IsTest
  static void testActionsRequireOperatorPermission() {
    User stdUser;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      stdUser = new User(
        Alias = 'hldusr',
        Email = 'hold@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'Hold',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'hold_' + Datetime.now().getTime() + '@testorg.com'
      );
      insert stdUser;
      // View-only operator: passes the view gate, so the action gate decides.
      insert new PermissionSetAssignment(
        AssigneeId = stdUser.Id,
        PermissionSetId = [
          SELECT Id
          FROM PermissionSet
          WHERE Name = 'Revenant_Operator'
          LIMIT 1
        ]
        .Id
      );
    }
    Id instId;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      instId = startAndRunFirstHop('DashHoldAuth-' + Datetime.now().getTime());
    }
    Test.startTest();
    Boolean holdDenied = false;
    Boolean releaseDenied = false;
    System.runAs(stdUser) {
      try {
        WorkflowDashboardCommandController.holdInstance(instId, 'x');
      } catch (AuraHandledException ex) {
        holdDenied = ex.getMessage().contains('Workflow_Operator_Action');
      }
      try {
        WorkflowDashboardCommandController.releaseHeldInstance(instId);
      } catch (AuraHandledException ex) {
        releaseDenied = ex.getMessage().contains('Workflow_Operator_Action');
      }
    }
    Test.stopTest();
    System.assert(holdDenied, 'Hold must fail on the operator-action gate');
    System.assert(
      releaseDenied,
      'Release must fail on the operator-action gate'
    );
    System.assertEquals(
      false,
      [SELECT Held__c FROM Workflow_Instance__c WHERE Id = :instId].Held__c,
      'A denied hold writes nothing'
    );
  }
}
