@IsTest
private class WorkflowDashboardChainTest {
  private static final String WF = 'WorkflowDashboardChainTest.StubWorkflow';

  // Inserts a linked chain of size rows. The last row is Running.
  private static List<Workflow_Instance__c> chain(String root, Integer size) {
    List<Workflow_Instance__c> gens = new List<Workflow_Instance__c>();
    for (Integer i = 1; i <= size; i++) {
      gens.add(
        new Workflow_Instance__c(
          Workflow_Name__c = WF,
          Status__c = i == size ? 'Running' : 'ContinuedAsNew',
          Correlation_Key__c = i == 1 ? root : root + '_run' + i,
          Root_Correlation_Key__c = root
        )
      );
    }
    Database.insert(gens, AccessLevel.SYSTEM_MODE);
    for (Integer i = 1; i < size; i++) {
      gens[i].Previous_Instance__c = gens[i - 1].Id;
    }
    Database.update(gens, AccessLevel.SYSTEM_MODE);
    Datetime base = Datetime.now().addDays(-1);
    for (Integer i = 0; i < size; i++) {
      Test.setCreatedDate(gens[i].Id, base.addMinutes(i));
    }
    return gens;
  }

  private static List<Map<String, Object>> generations(
    Map<String, Object> view
  ) {
    return (List<Map<String, Object>>) view.get('generations');
  }

  @IsTest
  static void mapsChainForTheDashboard() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('dash', 3);
      gens[1].Failure_Category__c = 'TIMEOUT';
      Database.update(gens[1], AccessLevel.SYSTEM_MODE);

      Map<String, Object> view = WorkflowDashboardController.getInstanceChain(
        gens[0].Id,
        null
      );

      Assert.areEqual(3, view.get('totalCount'));
      Assert.areEqual(false, view.get('isTotalCapped'));
      Assert.areEqual(false, view.get('hasMore'));
      Assert.isNull(view.get('nextCursor'));
      Assert.areEqual('dash', view.get('rootCorrelationKey'));

      List<Map<String, Object>> rows = generations(view);
      Assert.areEqual(3, rows.size());
      Map<String, Object> top = rows[0];
      Assert.areEqual(gens[2].Id, top.get('instanceId'));
      Assert.isNotNull(top.get('instanceName'), 'Name for the row label');
      Assert.areEqual(3, top.get('generation'));
      Assert.areEqual('Running', top.get('status'));
      Assert.areEqual('dash_run3', top.get('correlationKey'));
      Assert.isNotNull(top.get('startedAt'));
      Assert.isNull(top.get('endedAt'));
      Assert.isNull(top.get('outcome'));

      Map<String, Object> mid = rows[1];
      Assert.areEqual('ContinuedAsNew', mid.get('outcome'));
      Assert.isNotNull(mid.get('continuedAt'));
      Assert.areEqual('TIMEOUT', mid.get('failureCategory'));
    }
  }

  @IsTest
  static void passesCursorForOlderPages() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('deep', 3);
      WorkflowDashboardChainService.pageSize = 2;

      Map<String, Object> p1 = WorkflowDashboardController.getInstanceChain(
        gens[2].Id,
        null
      );
      Assert.areEqual(true, p1.get('hasMore'));
      Assert.areEqual(2, generations(p1).size());

      Map<String, Object> p2 = WorkflowDashboardController.getInstanceChain(
        gens[2].Id,
        (String) p1.get('nextCursor')
      );
      Assert.areEqual(false, p2.get('hasMore'));
      Assert.areEqual(1, generations(p2).size());
      Assert.areEqual(gens[0].Id, generations(p2)[0].get('instanceId'));
      Assert.areEqual(1, generations(p2)[0].get('generation'));
    }
  }

  @IsTest
  static void singleGenerationReturnsOneRow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c solo = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'Completed',
        Correlation_Key__c = 'dash-solo'
      );
      Database.insert(solo, AccessLevel.SYSTEM_MODE);

      Map<String, Object> view = WorkflowDashboardController.getInstanceChain(
        solo.Id,
        null
      );

      Assert.areEqual(1, generations(view).size());
      Assert.areEqual(1, view.get('totalCount'));
    }
  }

  @IsTest
  static void rejectsMissingIdAndBadCursor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('dash-bad', 2);
      try {
        WorkflowDashboardController.getInstanceChain(null, null);
        Assert.fail('Expected AuraHandledException for a null Id');
      } catch (AuraHandledException e) {
        Assert.isTrue(e.getMessage().contains('instanceId'), e.getMessage());
      }
      try {
        WorkflowDashboardController.getInstanceChain(gens[0].Id, 'bad');
        Assert.fail('Expected AuraHandledException for a bad cursor');
      } catch (AuraHandledException e) {
        Assert.isTrue(e.getMessage().contains('cursor'), e.getMessage());
      }
    }
  }

  @IsTest
  static void unknownInstanceReturnsNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id unknown = (Id) (Workflow_Instance__c.SObjectType.getDescribe(
          SObjectDescribeOptions.DEFERRED
        )
        .getKeyPrefix() + '000000000001');
      Assert.isNull(
        WorkflowDashboardController.getInstanceChain(unknown, null)
      );
    }
  }

  @IsTest
  static void requiresDashboardAccess() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      User stdUser = new User(
        Alias = 'chnusr',
        Email = 'chainuser@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'Testing',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'chainuser_dashboard_test_' +
          DateTime.now().getTime() +
          '@testorg.com'
      );
      insert stdUser;

      System.runAs(stdUser) {
        try {
          WorkflowDashboardController.getInstanceChain(null, null);
          Assert.fail('Expected AuraHandledException');
        } catch (AuraHandledException e) {
          Assert.isTrue(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception'),
            e.getMessage()
          );
        }
      }
    }
  }
}
