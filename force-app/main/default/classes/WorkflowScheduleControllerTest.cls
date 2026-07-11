@IsTest
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

  @IsTest
  static void testGetSchedules() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // getSchedules surfaces the persisted Next_Fire_Window__c cursor as nextFireTime
      // (no per-row cron scan), so seed the cursor to verify it passes through.
      Workflow_Schedule__c sched = makeSchedule('CtrlGet');
      DateTime cursor = DateTime.now().addHours(1);
      sched.Next_Fire_Window__c = cursor;
      insert sched;

      Test.startTest();
      List<Map<String, Object>> rows = WorkflowScheduleController.getSchedules(
        '0'
      );
      Test.stopTest();

      System.assertEquals(1, rows.size(), 'Should return the one schedule');
      System.assertEquals('CtrlGet', rows[0].get('Name'));
      System.assertEquals(
        false,
        rows[0].get('dedicatedJobArmed'),
        'No dedicated job armed'
      );
      System.assertEquals(
        cursor,
        rows[0].get('nextFireTime'),
        'nextFireTime should be the persisted Next_Fire_Window__c cursor, not a per-row scan'
      );
    }
  }

  @IsTest
  static void testSaveCreateSeedsCursor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id newId = WorkflowScheduleController.saveSchedule(
        new Map<String, Object>{
          'Name' => 'CtrlSeed',
          'Workflow_Name__c' => TEST_WF,
          'Cron_Expression__c' => '0 2 * * *',
          'Correlation_Key_Prefix__c' => 'CtrlSeed',
          'Enabled__c' => true,
          'Overlap_Policy__c' => 'Skip',
          'Dedicated_Slot__c' => false
        }
      );
      Test.stopTest();

      Workflow_Schedule__c saved = [
        SELECT Next_Fire_Window__c
        FROM Workflow_Schedule__c
        WHERE Id = :newId
      ];
      System.assertNotEquals(
        null,
        saved.Next_Fire_Window__c,
        'Creating a schedule should seed the Next_Fire_Window__c cursor for the list view'
      );
    }
  }

  @IsTest
  static void testEditCronResetsCursor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A monthly schedule whose cursor sits far in the future.
      Workflow_Schedule__c sched = makeSchedule('CtrlCursor');
      sched.Cron_Expression__c = '0 0 1 * *';
      sched.Next_Fire_Window__c = DateTime.now().addDays(20);
      insert sched;
      DateTime staleCursor = sched.Next_Fire_Window__c;

      Test.startTest();
      // Edit it to fire every minute — the stale far-future cursor would keep it out
      // of the sweep batch (which only selects cursor <= now) until next month.
      WorkflowScheduleController.saveSchedule(
        new Map<String, Object>{
          'Id' => sched.Id,
          'Name' => 'CtrlCursor',
          'Workflow_Name__c' => TEST_WF,
          'Cron_Expression__c' => '* * * * *',
          'Correlation_Key_Prefix__c' => 'CtrlCursor',
          'Enabled__c' => true,
          'Overlap_Policy__c' => 'Skip',
          'Dedicated_Slot__c' => false
        }
      );
      Test.stopTest();

      Workflow_Schedule__c after = [
        SELECT Next_Fire_Window__c
        FROM Workflow_Schedule__c
        WHERE Id = :sched.Id
      ];
      System.assert(
        after.Next_Fire_Window__c < staleCursor,
        'Changing the cron must recompute the cursor so the sweep sees the new cadence'
      );
      System.assert(
        after.Next_Fire_Window__c <= DateTime.now().addMinutes(1),
        'An every-minute cron should leave the cursor due now (not next month)'
      );
    }
  }

  @IsTest
  static void testSaveCreateAndEdit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
      System.assertEquals(
        '0 3 * * *',
        saved.Cron_Expression__c,
        'Cron should be updated'
      );
      System.assertEquals(false, saved.Enabled__c, 'Enabled should be updated');
    }
  }

  @IsTest
  static void testSaveInvalidCronRejected() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  @IsTest
  static void testSaveInvalidJsonRejected() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  @IsTest
  static void testReEnableRecomputesCursor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A paused schedule whose cursor has fallen into the past while disabled.
      Workflow_Schedule__c sched = makeSchedule('CtrlReEnable');
      sched.Cron_Expression__c = '0 0 * * *'; // daily at midnight UTC
      sched.Enabled__c = false;
      sched.Next_Fire_Window__c = DateTime.now().addDays(-1);
      insert sched;

      Test.startTest();
      WorkflowScheduleController.enableSchedule(sched.Id);
      Test.stopTest();

      Workflow_Schedule__c after = [
        SELECT Next_Fire_Window__c
        FROM Workflow_Schedule__c
        WHERE Id = :sched.Id
      ];
      System.assert(
        after.Next_Fire_Window__c > DateTime.now(),
        'Re-enabling must move the cursor to the next future window, not leave a stale past one that fires immediately'
      );
    }
  }

  @IsTest
  static void testSetEnabledAndDelete() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Schedule__c sched = makeSchedule('CtrlToggle');
      insert sched;

      Test.startTest();
      WorkflowScheduleController.disableSchedule(sched.Id);
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
  }

  @IsTest
  static void testRunNow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Schedule__c sched = makeSchedule('CtrlRunNow');
      insert sched;

      Test.startTest();
      Id instanceId = WorkflowScheduleController.runNow(sched.Id);
      Test.stopTest();

      System.assertNotEquals(
        null,
        instanceId,
        'runNow should return an instance Id'
      );
      List<Workflow_Instance__c> instances = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c LIKE 'CtrlRunNow_manual_%'
      ];
      System.assertEquals(
        1,
        instances.size(),
        'A manual instance should have started'
      );
    }
  }

  @IsTest
  static void testGetScheduleDetail() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Schedule__c sched = makeSchedule('CtrlDetail');
      insert sched;
      // Generate a log via runNow.
      WorkflowScheduleController.runNow(sched.Id);

      Test.startTest();
      Map<String, Object> detail = WorkflowScheduleController.getScheduleDetail(
        sched.Id
      );
      Test.stopTest();

      System.assertNotEquals(
        null,
        detail.get('schedule'),
        'Schedule should be present'
      );
      List<Object> logs = (List<Object>) detail.get('logs');
      System.assert(logs.size() >= 1, 'Should include at least one fire log');
      System.assertNotEquals(
        null,
        detail.get('nextFireTime'),
        'nextFireTime present'
      );
    }
  }

  @IsTest
  static void testPreviewCron() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Map<String, Object> good = WorkflowScheduleController.previewCron(
        '0 2 * * *'
      );
      Map<String, Object> bad = WorkflowScheduleController.previewCron(
        'not a cron'
      );
      Test.stopTest();

      System.assertEquals(true, good.get('valid'), 'Valid cron');
      System.assertNotEquals(null, good.get('nextFire'), 'Next fire computed');
      System.assertEquals(false, bad.get('valid'), 'Invalid cron');
    }
  }

  @IsTest
  static void testGetWorkflowDefinitions() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      List<String> defs = WorkflowScheduleController.getWorkflowDefinitions();
      Test.stopTest();
      System.assertNotEquals(null, defs, 'Definitions list should not be null');
    }
  }

  @IsTest
  static void testDedicatedJobRegisterUnregister() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Schedule__c sched = makeSchedule('CtrlDed');
      sched.Dedicated_Slot__c = true;
      insert sched;

      Integer before = [SELECT COUNT() FROM CronTrigger];

      Test.startTest();
      WorkflowScheduleController.registerDedicatedJob(sched.Id);
      Integer afterReg = [SELECT COUNT() FROM CronTrigger];
      System.assertEquals(
        before + 1,
        afterReg,
        'Register should add a CronTrigger'
      );

      WorkflowScheduleController.unregisterDedicatedJob(sched.Id);
      Test.stopTest();

      Integer afterUnreg = [
        SELECT COUNT()
        FROM CronTrigger
        WHERE
          CronJobDetail.Name = :WorkflowScheduleSweeper.dedicatedJobName(
            sched.Id
          )
      ];
      System.assertEquals(
        0,
        afterUnreg,
        'Unregister should remove the CronTrigger'
      );
    }
  }

  @IsTest
  static void testSavePrefixTooLong() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Boolean threw = false;
      String longPrefix = '';
      for (Integer k = 0; k < 81; k++) {
        longPrefix += 'P';
      }
      Test.startTest();
      try {
        WorkflowScheduleController.saveSchedule(
          new Map<String, Object>{
            'Name' => 'LongPrefix',
            'Workflow_Name__c' => TEST_WF,
            'Cron_Expression__c' => '0 2 * * *',
            'Correlation_Key_Prefix__c' => longPrefix
          }
        );
      } catch (AuraHandledException e) {
        threw = true;
      }
      Test.stopTest();
      System.assert(threw, 'Prefix over 80 chars should be rejected');
    }
  }

  @IsTest
  static void testSaveDuplicatePrefix() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new Workflow_Schedule__c(
        Name = 'FirstSched',
        Workflow_Name__c = TEST_WF,
        Cron_Expression__c = '0 2 * * *',
        Correlation_Key_Prefix__c = 'SharedPrefix',
        Enabled__c = true,
        Overlap_Policy__c = 'Skip'
      );

      Boolean threw = false;
      Test.startTest();
      try {
        WorkflowScheduleController.saveSchedule(
          new Map<String, Object>{
            'Name' => 'SecondSched',
            'Workflow_Name__c' => TEST_WF,
            'Cron_Expression__c' => '0 3 * * *',
            'Correlation_Key_Prefix__c' => 'SharedPrefix'
          }
        );
      } catch (AuraHandledException e) {
        threw = true;
      }
      Test.stopTest();
      System.assert(threw, 'Duplicate prefix should be rejected');
    }
  }

  @IsTest
  static void testSetEnabledAbortsDedicatedJob() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Schedule__c sched = makeSchedule('CtrlDisableDed');
      sched.Dedicated_Slot__c = true;
      insert sched;

      String jobName = WorkflowScheduleSweeper.dedicatedJobName(sched.Id);
      Test.startTest();
      WorkflowScheduleController.registerDedicatedJob(sched.Id);
      Integer armed = [
        SELECT COUNT()
        FROM CronTrigger
        WHERE CronJobDetail.Name = :jobName
      ];
      System.assertEquals(1, armed, 'Dedicated job should be armed');

      WorkflowScheduleController.disableSchedule(sched.Id);
      Test.stopTest();

      Integer afterDisable = [
        SELECT COUNT()
        FROM CronTrigger
        WHERE CronJobDetail.Name = :jobName
      ];
      System.assertEquals(
        0,
        afterDisable,
        'Disabling a dedicated schedule should abort its CronTrigger'
      );
    }
  }

  @IsTest
  static void testEditCronReArmsDedicatedJob() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Schedule__c sched = makeSchedule('CtrlReArm');
      sched.Dedicated_Slot__c = true;
      insert sched;

      Test.startTest();
      WorkflowScheduleController.registerDedicatedJob(sched.Id);
      CronTrigger before = [
        SELECT Id, CronExpression
        FROM CronTrigger
        WHERE
          CronJobDetail.Name = :WorkflowScheduleSweeper.dedicatedJobName(
            sched.Id
          )
        LIMIT 1
      ];

      // Edit only the cron of an already-armed dedicated schedule.
      WorkflowScheduleController.saveSchedule(
        new Map<String, Object>{
          'Id' => sched.Id,
          'Name' => 'CtrlReArm',
          'Workflow_Name__c' => TEST_WF,
          'Cron_Expression__c' => '0 5 * * *',
          'Correlation_Key_Prefix__c' => 'CtrlReArm',
          'Enabled__c' => true,
          'Overlap_Policy__c' => 'Skip',
          'Dedicated_Slot__c' => true
        }
      );
      Test.stopTest();

      CronTrigger after = [
        SELECT Id, CronExpression
        FROM CronTrigger
        WHERE
          CronJobDetail.Name = :WorkflowScheduleSweeper.dedicatedJobName(
            sched.Id
          )
        LIMIT 1
      ];
      System.assertNotEquals(
        before.CronExpression,
        after.CronExpression,
        'Editing the cron of an armed dedicated schedule should re-arm with the new cadence'
      );
    }
  }

  @IsTest
  static void testSaveTurningOffDedicatedAbortsJob() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Schedule__c sched = makeSchedule('CtrlUnded');
      sched.Dedicated_Slot__c = true;
      insert sched;

      Test.startTest();
      WorkflowScheduleController.registerDedicatedJob(sched.Id);
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM CronTrigger
          WHERE
            CronJobDetail.Name = :WorkflowScheduleSweeper.dedicatedJobName(
              sched.Id
            )
        ],
        'Dedicated job should be armed before the edit'
      );

      // Edit the schedule via the modal path, unchecking Dedicated Slot.
      WorkflowScheduleController.saveSchedule(
        new Map<String, Object>{
          'Id' => sched.Id,
          'Name' => 'CtrlUnded',
          'Workflow_Name__c' => TEST_WF,
          'Cron_Expression__c' => '0 2 * * *',
          'Correlation_Key_Prefix__c' => 'CtrlUnded',
          'Enabled__c' => true,
          'Overlap_Policy__c' => 'Skip',
          'Dedicated_Slot__c' => false
        }
      );
      Test.stopTest();

      System.assertEquals(
        0,
        [
          SELECT COUNT()
          FROM CronTrigger
          WHERE
            CronJobDetail.Name = :WorkflowScheduleSweeper.dedicatedJobName(
              sched.Id
            )
        ],
        'Turning off Dedicated Slot via save should abort the orphaned CronTrigger'
      );
    }
  }

  @IsTest
  static void testLogsFollowScheduleRename() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Schedule__c sched = makeSchedule('CtrlRename');
      insert sched;
      // Generate a log linked by schedule Id.
      WorkflowScheduleController.runNow(sched.Id);

      // Rename the schedule — logs are keyed by Id, so they must still resolve.
      sched.Name = 'CtrlRenamed';
      update sched;

      Test.startTest();
      Map<String, Object> detail = WorkflowScheduleController.getScheduleDetail(
        sched.Id
      );
      Test.stopTest();

      List<Object> logs = (List<Object>) detail.get('logs');
      System.assert(
        logs.size() >= 1,
        'Fire logs must remain attached to the schedule after a rename (keyed by Id)'
      );
    }
  }

  @IsTest
  static void testUnauthorized() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
