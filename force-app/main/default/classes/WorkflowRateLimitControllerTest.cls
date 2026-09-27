/**
 * @description Tests for WorkflowRateLimitController (#61): the authorization gate
 * and the permission-set class access for the Rate Limits panel.
 */
@IsTest
private class WorkflowRateLimitControllerTest {
  private static User insertStandardUser() {
    Profile stdProfile = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Standard User'
      LIMIT 1
    ];
    User stdUser = new User(
      Alias = 'rlusr',
      Email = 'ratelimit@testorg.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Testing',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = stdProfile.Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      UserName = 'stduser_ratelimit_test_' +
        DateTime.now().getTime() +
        '@testorg.com'
    );
    insert stdUser;
    return stdUser;
  }

  /**
   * @description AC5: an unauthorized user gets the same denial as every other panel.
   */
  @IsTest
  static void testUnauthorizedUserIsDeniedLikeOtherPanels() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      User stdUser = insertStandardUser();
      System.runAs(stdUser) {
        String panelMessage;
        try {
          WorkflowDashboardController.getConcurrencyStatus();
        } catch (AuraHandledException e) {
          panelMessage = e.getMessage();
        }
        try {
          WorkflowRateLimitController.getRateLimitStatus('1');
          System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized'),
            e.getMessage()
          );
          System.assertEquals(panelMessage, e.getMessage());
        }
      }
    }
  }

  /**
   * @description An authorized user gets the envelope with rows and asOfMs.
   */
  @IsTest
  static void testAuthorizedUserGetsStatus() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      RateLimiter.mockConfigs.put(
        'CtlApi',
        (Rate_Limit_Config__mdt) JSON.deserialize(
          '{"DeveloperName":"CtlApi","Capacity__c":3,"Refill_Rate_Per_Second__c":1.0}',
          Rate_Limit_Config__mdt.class
        )
      );
      Map<String, Object> result = WorkflowRateLimitController.getRateLimitStatus(
        'buster'
      );
      List<Map<String, Object>> rows = (List<Map<String, Object>>) result.get(
        'rows'
      );
      System.assertEquals(1, rows.size());
      System.assertEquals('IDLE', rows[0].get('status'));
      System.assertNotEquals(null, result.get('asOfMs'));
    }
  }

  /**
   * @description Both dashboard permission sets grant the new controller class.
   */
  @IsTest
  static void testPermissionSetsGrantController() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Set<String> granted = new Set<String>();
      for (SetupEntityAccess sea : [
        SELECT Parent.Name
        FROM SetupEntityAccess
        WHERE
          SetupEntityId IN (
            SELECT Id
            FROM ApexClass
            WHERE Name = 'WorkflowRateLimitController'
          )
          AND Parent.Name IN ('Revenant_Operator', 'Revenant_Admin')
      ]) {
        granted.add(sea.Parent.Name);
      }
      System.assert(granted.contains('Revenant_Operator'), granted);
      System.assert(granted.contains('Revenant_Admin'), granted);
    }
  }
}
