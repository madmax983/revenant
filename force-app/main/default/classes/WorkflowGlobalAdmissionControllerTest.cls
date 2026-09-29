/**
 * @description Tests for WorkflowGlobalAdmissionController (issue #136): the
 * envelope keys and the permission set grants.
 */
@IsTest
private class WorkflowGlobalAdmissionControllerTest {
  @IsTest
  static void envelopeHasAllKeys() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Map<String, Object> result = WorkflowGlobalAdmissionController.getGlobalAdmission();
      for (
        String key : new List<String>{
          'asOfMs',
          'state',
          'governed',
          'reason',
          'reasons',
          'emergencyStop',
          'autoBrake',
          'capacityStatus',
          'ceiling',
          'inFlight',
          'parkedCount',
          'parkedCapped'
        }
      ) {
        Assert.isTrue(result.containsKey(key), 'Missing key: ' + key);
      }
    }
  }

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
            WHERE Name = 'WorkflowGlobalAdmissionController'
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
