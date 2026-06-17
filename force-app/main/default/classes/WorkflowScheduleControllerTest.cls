@isTest
public class WorkflowScheduleControllerTest {
  private static final String TEST_WF = 'WorkflowEngineTest.HappyWorkflow';

  private static Workflow_Schedule__c makeSchedule(String name) {
    return new Workflow_Schedule__c(
      Name = name,
      Workflow_Name__c = TEST_WF,
      Cron_Expression__c = '0 2 * * *',
      Correlation_Key_Prefix__c = name,
      Enabled__c = true,
      Overlap_Policy__c = 'Skip',
      Dedicated_Slot__c = false
    );
  }

  @isTest
  static void testGetSchedules() {
    insert makeSchedule('CtrlGet');

    Test.startTest();
    List<Map<String, Object>> rows = WorkflowScheduleController.getSchedules('0');
    Test.stopTest();

    System.assertEquals(1, rows.size(), 'Should return the one schedule');
    System.assertEquals('CtrlGet', rows[0].get('Name'));
    System.assertEquals(false, rows[0].get('dedicatedJobArmed'), 'No dedicated job armed');
    System.assertNotEquals(null, rows[0].get('nextFireTime'), 'nextFireTime should be computed');
  }

  @isTest
  static void testSaveCreateAndEdit() {
    Test.startTest();
    // Create
    Id newId = WorkflowScheduleController.saveSchedule(
      new Map<String, Object>{
        'Name' => 'CtrlCreate',
        'Workflow_Name__c' => TEST_WF,
        'Cron_Expression__c' => '0 * * * *',
        'Correlation_Key_Prefix__c' => 'CtrlCreate',
        'Enabled__c' => true,
        'Overlap_Policy__c' => 'Allow',
        'Dedicated_Slot__c' => false,
        'Input_Json__c' => '{"a":1}'
      }
    );
    System.assertNotEquals(null, newId, 'Create should return an Id');

    // Edit
    WorkflowScheduleController.saveSchedule(
      new Map<String, Object>{
        'Id' => newId,
        'Name' => 'CtrlCreate',
        'Workflow_Name__c' => TEST_WF,
        'Cron_Expression__c' => '0 3 * * *',
        'Correlation_Key_Prefix__c' => 'CtrlCreate',
        'Enabled__c' => false,
        'Overlap_Policy__c' => 'Skip',
        'Dedicated_Slot__c' => false
      }
    );
    Test.stopTest();

    Workflow_Schedule__c saved = [
      SELECT Cron_Expression__c, Enabled__c
      FROM Workflow_Schedule__c
      WHERE Id = :newId
    ];
    System.assertEquals('0 3 * * *', saved.Cron_Expression__c, 'Cron should be updated');
    System.assertEquals(false, saved.Enabled__c, 'Enabled should be updated');
  }

  @isTest
  static void testSaveInvalidCronRejected() {
    Boolean threw = false;
    Test.startTest();
    try {
      WorkflowScheduleController.saveSchedule(
        new Map<String, Object>{
          'Name' => 'BadCron',
          'Workflow_Name__c' => TEST_WF,
          'Cron_Expression__c' => '99 * * * *',
          'Correlation_Key_Prefix__c' => 'BadCron'
        }
      );
    } catch (AuraHandledException e) {
      threw = true;
    }
    Test.stopTest();
    System.assert(threw, 'Invalid cron should throw AuraHandledException');
  }

  @isTest
  static void testSaveInvalidJsonRejected() {
    Boolean threw = false;
    Test.startTest();
    try {
      WorkflowScheduleController.saveSchedule(
        new Map<String, Object>{
          'Name' => 'BadJson',
          'Workflow_Name__c' => TEST_WF,
          'Cron_Expression__c' => '0 2 * * *',
          'Correlation_Key_Prefix__c' => 'BadJson',
          'Input_Json__c' => '{not valid json'
        }
      );
    } catch (AuraHandledException e) {
      threw = true;
    }
    Test.stopTest();
    System.assert(threw, 'Invalid JSON should throw AuraHandledException');
  }

  @isTest
  static void testSetEnabledAndDelete() {
    Workflow_Schedule__c sched = makeSchedule('CtrlToggle');
    insert sched;

    Test.startTest();
    WorkflowScheduleController.setEnabled(sched.Id, false);
    Workflow_Schedule__c afterToggle = [
      SELECT Enabled__c
      FROM Workflow_Schedule__c
      WHERE Id = :sched.Id
    ];
    System.assertEquals(false, afterToggle.Enabled__c, 'Should be disabled');

    WorkflowScheduleController.deleteSchedule(sched.Id);
    Test.stopTest();

    System.assertEquals(
      0,
      [SELECT COUNT() FROM Workflow_Schedule__c WHERE Id = :sched.Id],
      'Schedule should be deleted'
    );
  }

  @isTest
  static void testRunNow() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Schedule__c sched = makeSchedule('CtrlRunNow');
    insert sched;

    Test.startTest();
    Id instanceId = WorkflowScheduleController.runNow(sched.Id);
    Test.stopTest();

    System.assertNotEquals(null, instanceId, 'runNow should return an instance Id');
    List<Workflow_Instance__c> instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c LIKE 'CtrlRunNow_manual_%'
    ];
    System.assertEquals(1, instances.size(), 'A manual instance should have started');
  }

  @isTest
  static void testGetScheduleDetail() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Schedule__c sched = makeSchedule('CtrlDetail');
    insert sched;
    // Generate a log via runNow.
    WorkflowScheduleController.runNow(sched.Id);

    Test.startTest();
    Map<String, Object> detail = WorkflowScheduleController.getScheduleDetail(sched.Id);
    Test.stopTest();

    System.assertNotEquals(null, detail.get('schedule'), 'Schedule should be present');
    List<Object> logs = (List<Object>) detail.get('logs');
    System.assert(logs.size() >= 1, 'Should include at least one fire log');
    System.assertNotEquals(null, detail.get('nextFireTime'), 'nextFireTime present');
  }

  @isTest
  static void testPreviewCron() {
    Test.startTest();
    Map<String, Object> good = WorkflowScheduleController.previewCron('0 2 * * *');
    Map<String, Object> bad = WorkflowScheduleController.previewCron('not a cron');
    Test.stopTest();

    System.assertEquals(true, good.get('valid'), 'Valid cron');
    System.assertNotEquals(null, good.get('nextFire'), 'Next fire computed');
    System.assertEquals(false, bad.get('valid'), 'Invalid cron');
  }

  @isTest
  static void testGetWorkflowDefinitions() {
    Test.startTest();
    List<String> defs = WorkflowScheduleController.getWorkflowDefinitions();
    Test.stopTest();
    System.assertNotEquals(null, defs, 'Definitions list should not be null');
  }

  @isTest
  static void testDedicatedJobRegisterUnregister() {
    Workflow_Schedule__c sched = makeSchedule('CtrlDed');
    sched.Dedicated_Slot__c = true;
    insert sched;

    Integer before = [SELECT COUNT() FROM CronTrigger];

    Test.startTest();
    WorkflowScheduleController.registerDedicatedJob(sched.Id);
    Integer afterReg = [SELECT COUNT() FROM CronTrigger];
    System.assertEquals(before + 1, afterReg, 'Register should add a CronTrigger');

    WorkflowScheduleController.unregisterDedicatedJob(sched.Id);
    Test.stopTest();

    Integer afterUnreg = [
      SELECT COUNT()
      FROM CronTrigger
      WHERE CronJobDetail.Name = 'RevenantSched_CtrlDed'
    ];
    System.assertEquals(0, afterUnreg, 'Unregister should remove the CronTrigger');
  }

  @isTest
  static void testUnauthorized() {
    // Create a user with a minimal profile and NO Revenant permission sets.
    User u = buildMinimalUser();
    if (u == null) {
      return; // Org lacks a usable minimal profile; skip rather than fail.
    }
    // Insert the setup (User) object inside its own runAs boundary to avoid a
    // mixed-DML error, and so System.runAs has a persisted user to switch to.
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert u;
    }

    Boolean threw = false;
    System.runAs(u) {
      Test.startTest();
      try {
        // checkAuthorization() throws before any query, so no schedule data is needed.
        WorkflowScheduleController.getSchedules('0');
      } catch (AuraHandledException e) {
        threw = true;
      }
      Test.stopTest();
    }
    System.assert(threw, 'Unauthorized user should be blocked');
  }

  private static User buildMinimalUser() {
    List<Profile> profiles = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Minimum Access - Salesforce' OR Name = 'Standard User'
      ORDER BY Name
      LIMIT 1
    ];
    if (profiles.isEmpty()) {
      return null;
    }
    String uniq = 'wfsched' + Datetime.now().getTime();
    return new User(
      Alias = 'wfsch',
      Email = uniq + '@example.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'NoAccess',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = profiles[0].Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      Username = uniq + '@example.com.revtest'
    );
  }
}
