/**
 * @description Makes a test user with Revenant_Admin. The quickstart check reads
 * in user mode, so the tests must not depend on the access of the running user.
 */
@IsTest
public class QuickstartTestUser {
  /**
   * @description Inserts a System Administrator user with Revenant_Admin.
   * @return The user. Use it in System.runAs.
   */
  public static User revenantAdmin() {
    User admin = new User(
      Alias = 'rvnqs',
      Email = 'revenant.quickstart@example.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Quickstart',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = [
        SELECT Id
        FROM Profile
        WHERE Name = 'System Administrator'
        LIMIT 1
      ]
      .Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      UserName = 'revenant.quickstart.' +
        Datetime.now().getTime() +
        '@example.com'
    );
    // Setup objects in their own runAs block. This prevents MIXED_DML errors.
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert admin;
      insert new PermissionSetAssignment(
        AssigneeId = admin.Id,
        PermissionSetId = [
          SELECT Id
          FROM PermissionSet
          WHERE Name = 'Revenant_Admin'
          LIMIT 1
        ]
        .Id
      );
    }
    return admin;
  }
}
