/**
 * Dashboard tests for the DefinitionChanged park (issue #89). They cover the
 * diagnosis payload in getInstanceDetails, the release action, and the
 * operator-action gate on release.
 */
@IsTest
private class WorkflowDashboardDefinitionChangeTest {
  private static final String WF = 'WorkflowDefinitionChangeTest.MutableWorkflow';
  private static final String STEP_A = 'WorkflowDefinitionChangeTest.StepA';
  private static final String STEP_B = 'WorkflowDefinitionChangeTest.StepB';
  private static final String STEP_X = 'WorkflowDefinitionChangeTest.StepX';

  private static Id parkInstance(String key) {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowDefinitionChangeTest.shape = 0;
    Id instId = WorkflowEngine.start(WF, key, null);
    WorkflowEngine.runStep(instId);
    WorkflowDefinitionChangeTest.shape = 1; // insert StepX
    WorkflowEngine.runStep(instId);
    return instId;
  }

  @IsTest
  static void testDetailsIncludeStoredAndLiveSteps() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = parkInstance('DashDefChg-' + Datetime.now().getTime());
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        instId
      );
      Test.stopTest();

      Map<String, Object> change = (Map<String, Object>) details.get(
        'definitionChange'
      );
      System.assertNotEquals(null, change, 'Details must carry the diagnosis');
      System.assertEquals(
        new List<String>{ STEP_A, STEP_B },
        (List<String>) change.get('storedSteps'),
        'Stored steps are the start shape'
      );
      System.assertEquals(
        new List<String>{ STEP_A, STEP_X, STEP_B },
        (List<String>) change.get('liveSteps'),
        'Live steps are the deployed shape'
      );
      System.assertEquals(
        new List<String>{ STEP_X },
        (List<String>) change.get('addedSteps'),
        'Added steps are live minus stored'
      );
      System.assertEquals(
        new List<String>(),
        (List<String>) change.get('removedSteps'),
        'No step was removed'
      );
      System.assertEquals(
        true,
        change.get('currentStepInLive'),
        'Current step StepB is still live'
      );
      System.assertNotEquals(
        change.get('storedFingerprint'),
        change.get('liveFingerprint'),
        'Fingerprints must differ'
      );
    }
  }

  @IsTest
  static void testDetailsOmitDiagnosisForOtherStatuses() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowDefinitionChangeTest.shape = 0;
      Test.startTest();
      Id instId = WorkflowEngine.start(
        WF,
        'DashDefChgNone-' + Datetime.now().getTime(),
        null
      );
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        instId
      );
      Test.stopTest();
      System.assertEquals(
        null,
        details.get('definitionChange'),
        'Only a parked instance carries the diagnosis'
      );
    }
  }

  @IsTest
  static void testReleaseActionResumesInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instId = parkInstance('DashDefChgRel-' + Datetime.now().getTime());
      WorkflowDashboardCommandController.releaseDefinitionChangedInstance(
        instId
      );
      Test.stopTest();
      System.assertEquals(
        'Running',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instId]
        .Status__c,
        'Release must set Running'
      );
    }
  }

  @IsTest
  static void testReleaseActionWrapsErrors() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowDefinitionChangeTest.shape = 0;
      Test.startTest();
      Id instId = WorkflowEngine.start(
        WF,
        'DashDefChgErr-' + Datetime.now().getTime(),
        null
      );
      Boolean threw = false;
      try {
        WorkflowDashboardCommandController.releaseDefinitionChangedInstance(
          instId
        );
      } catch (AuraHandledException ex) {
        threw = true;
      }
      Test.stopTest();
      System.assert(threw, 'A non-parked release must surface an error');
    }
  }

  @IsTest
  static void testReleaseActionRequiresOperatorPermission() {
    User stdUser;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      stdUser = new User(
        Alias = 'dcusr',
        Email = 'defchg@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'DefChg',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'defchg_' + Datetime.now().getTime() + '@testorg.com'
      );
      insert stdUser;
    }
    Id instId;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      instId = parkInstance('DashDefChgAuth-' + Datetime.now().getTime());
    }
    Test.startTest();
    Boolean denied = false;
    System.runAs(stdUser) {
      try {
        WorkflowDashboardCommandController.releaseDefinitionChangedInstance(
          instId
        );
      } catch (AuraHandledException ex) {
        denied = ex.getMessage().startsWith('Unauthorized');
      }
    }
    Test.stopTest();
    System.assert(denied, 'Release must require operator permission');
  }
}
