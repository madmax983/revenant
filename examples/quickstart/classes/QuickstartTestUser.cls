/**
 * @description Makes a test user with Revenant_Admin. The quickstart check reads
 * in user mode, so the tests must not depend on the access of the running user.
 */
@IsTest
public class QuickstartTestUser {
  /**
   * @description Inserts an administrator user with Revenant_Admin.
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
      // Not by name: the name of a standard profile changes with the org language.
      ProfileId = [
        SELECT Id
        FROM Profile
        WHERE PermissionsModifyAllData = TRUE AND UserType = 'Standard'
        ORDER BY CreatedDate
        LIMIT 1
      ]
      .Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      // Usernames are unique in all orgs, and test methods run in parallel.
      UserName = 'revenant.quickstart.' +
        UserInfo.getOrganizationId() +
        '.' +
        Datetime.now().getTime() +
        '.' +
        Math.abs(Crypto.getRandomInteger()) +
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
