/**
 * @description Tests for WorkflowAsyncCapacityController (#129): the view gate and
 * the permission-set class access.
 */
@IsTest
private class WorkflowAsyncCapacityControllerTest {
  private static User insertStandardUser() {
    Profile stdProfile = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Standard User'
      LIMIT 1
    ];
    User stdUser = new User(
      Alias = 'acusr',
      Email = 'asynccapacity@testorg.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Testing',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = stdProfile.Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      UserName = 'stduser_asynccap_test_' +
        DateTime.now().getTime() +
        '@testorg.com'
    );
    insert stdUser;
    return stdUser;
  }

  /**
   * @description An unauthorized user gets the same denial as the other panels.
   */
  @IsTest
  static void unauthorizedUserIsDeniedLikeOtherPanels() {
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
          WorkflowAsyncCapacityController.getAsyncCapacity();
          Assert.fail('Expected AuraHandledException');
        } catch (AuraHandledException e) {
          Assert.isTrue(
            e.getMessage().contains('Unauthorized'),
            e.getMessage()
          );
          Assert.areEqual(
            panelMessage,
            e.getMessage(),
            'The denial must match the other dashboard panels'
          );
        }
      }
    }
  }

  /**
   * @description An authorized user gets the capacity envelope.
   */
  @IsTest
  static void authorizedUserGetsCapacity() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Map<String, Object> result = WorkflowAsyncCapacityController.getAsyncCapacity();
      Assert.isNotNull(result.get('status'));
      Assert.isNotNull(result.get('asOfMs'));
      Assert.areEqual(3, ((List<Object>) result.get('metrics')).size());
    }
  }

  /**
   * @description Both dashboard permission sets grant the controller class.
   */
  @IsTest
  static void permissionSetsGrantController() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Set<String> granted = new Set<String>();
      for (SetupEntityAccess sea : [
        SELECT Parent.Name
        FROM SetupEntityAccess
        WHERE
          SetupEntityId IN (
            SELECT Id
            FROM ApexClass
            WHERE Name = 'WorkflowAsyncCapacityController'
          )
          AND Parent.Name IN ('Revenant_Operator', 'Revenant_Admin')
      ]) {
        granted.add(sea.Parent.Name);
      }
      Assert.isTrue(
        granted.contains('Revenant_Operator'),
        String.valueOf(granted)
      );
      Assert.isTrue(
        granted.contains('Revenant_Admin'),
        String.valueOf(granted)
      );
    }
  }
}
