/**
 * @description Permission-assignment coverage for the least-privilege Revenant_Operator
 * permission set. Proves that a user holding ONLY Revenant_Operator can read the engine
 * data objects but has no create/edit/delete on the append-only Workflow_Step_Execution__c
 * audit trail or the Workflow_Instance__c.Compensation_Stack__c LIFO-integrity field, and
 * that the operator passes the read-only dashboard authorization gate while being rejected
 * by the operator-action gate that guards the mutating recovery endpoints.
 */
@IsTest
public class RevenantOperatorPermSetTest {
  // Builds a fresh Standard User with no engine access other than what an assigned
  // permission set grants, so CRUD/FLS assertions reflect the permission set alone.
  private static User buildOperatorUser() {
    Profile stdProfile = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Standard User'
      LIMIT 1
    ];
    return new User(
      Alias = 'revop',
      Email = 'revoperator@testorg.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Operator',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = stdProfile.Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      UserName = 'revenant_operator_test_' +
        DateTime.now().getTime() +
        '@testorg.com'
    );
  }

  /**
   * A user assigned only Revenant_Operator can READ instances/steps/signals but cannot
   * edit or delete the append-only step-execution trail or the LIFO compensation stack.
   */
  @IsTest
  static void testOperatorIsReadOnlyOnEngineObjects() {
    User operator = buildOperatorUser();
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert operator;
      PermissionSet ps = [
        SELECT Id
        FROM PermissionSet
        WHERE Name = 'Revenant_Operator'
        LIMIT 1
      ];
      insert new PermissionSetAssignment(
        AssigneeId = operator.Id,
        PermissionSetId = ps.Id
      );
    }

    System.runAs(operator) {
      // Positive: the operator can read every object the dashboard surfaces.
      System.assertEquals(
        true,
        Schema.SObjectType.Workflow_Instance__c.isAccessible(),
        'Operator must be able to read Workflow_Instance__c'
      );
      System.assertEquals(
        true,
        Schema.SObjectType.Workflow_Step_Execution__c.isAccessible(),
        'Operator must be able to read Workflow_Step_Execution__c'
      );
      System.assertEquals(
        true,
        Schema.SObjectType.Workflow_Signal__c.isAccessible(),
        'Operator must be able to read Workflow_Signal__c'
      );

      // Negative: NO create/edit/delete/modifyAll on the append-only audit trail.
      System.assertEquals(
        false,
        Schema.SObjectType.Workflow_Step_Execution__c.isCreateable(),
        'Operator must NOT be able to create step-execution audit rows'
      );
      System.assertEquals(
        false,
        Schema.SObjectType.Workflow_Step_Execution__c.isUpdateable(),
        'Operator must NOT be able to edit the append-only step-execution trail'
      );
      System.assertEquals(
        false,
        Schema.SObjectType.Workflow_Step_Execution__c.isDeletable(),
        'Operator must NOT be able to delete step-execution audit rows'
      );

      // Negative: instance object itself is read-only for the operator.
      System.assertEquals(
        false,
        Schema.SObjectType.Workflow_Instance__c.isUpdateable(),
        'Operator must NOT be able to edit Workflow_Instance__c'
      );
      System.assertEquals(
        false,
        Schema.SObjectType.Workflow_Instance__c.isDeletable(),
        'Operator must NOT be able to delete Workflow_Instance__c'
      );

      // Negative: the LIFO compensation-stack field is readable but NOT editable.
      Schema.DescribeFieldResult compStack = Workflow_Instance__c.Compensation_Stack__c.getDescribe();
      System.assertEquals(
        true,
        compStack.isAccessible(),
        'Operator should be able to read Compensation_Stack__c'
      );
      System.assertEquals(
        false,
        compStack.isUpdateable(),
        'Operator must NOT be able to edit the LIFO Compensation_Stack__c field'
      );

      // Negative: a representative append-only audit field is readable but NOT editable.
      Schema.DescribeFieldResult stepOutput = Workflow_Step_Execution__c.Output__c.getDescribe();
      System.assertEquals(
        true,
        stepOutput.isAccessible(),
        'Operator should be able to read Workflow_Step_Execution__c.Output__c'
      );
      System.assertEquals(
        false,
        stepOutput.isUpdateable(),
        'Operator must NOT be able to edit Workflow_Step_Execution__c.Output__c'
      );
    }
  }

  /**
   * The operator passes the read-only dashboard authorization gate (via the
   * Workflow_Dashboard_View custom permission granted by the set) but is rejected by the
   * operator-action gate, proving that "view the dashboard" does not imply "mutate state."
   */
  @IsTest
  static void testOperatorPassesViewGateButNotActionGate() {
    User operator = buildOperatorUser();
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert operator;
      PermissionSet ps = [
        SELECT Id
        FROM PermissionSet
        WHERE Name = 'Revenant_Operator'
        LIMIT 1
      ];
      insert new PermissionSetAssignment(
        AssigneeId = operator.Id,
        PermissionSetId = ps.Id
      );
    }

    System.runAs(operator) {
      Test.startTest();
      // View gate: must NOT throw for a Revenant_Operator holder.
      WorkflowDashboardSupport.checkAuthorization();

      // Action gate: must throw, because the set does not grant Workflow_Operator_Action.
      Boolean actionBlocked = false;
      try {
        WorkflowDashboardSupport.checkOperatorAction();
      } catch (AuraHandledException e) {
        actionBlocked = true;
        System.assert(
          e.getMessage().contains('Workflow_Operator_Action') ||
          e.getMessage().contains('Script-thrown exception'),
          e.getMessage()
        );
      }
      Test.stopTest();

      System.assert(
        actionBlocked,
        'A read-only operator must be blocked from the operator-action gate'
      );
    }
  }
}
