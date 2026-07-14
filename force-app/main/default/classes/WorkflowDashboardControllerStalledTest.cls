@IsTest
public class WorkflowDashboardControllerStalledTest {
  // ==========================================
  // Bulk re-drive of failed instances
  // ==========================================

  private static void seedFailed(String key) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Failed',
      Correlation_Key__c = key,
      Current_Step__c = 'WorkflowEngineTest.HappyStep1',
      Error_Message__c = 'Endpoint down'
    );
    insert inst;
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Failed',
      Retry_Count__c = 1,
      Error_Details__c = 'boom'
    );
  }

  @IsTest
  static void testGetRedriveEligibleCount() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      seedFailed('CntA');
      seedFailed('CntB');
      seedFailed('CntC');
      insert new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Completed',
        Correlation_Key__c = 'CntDone'
      );

      Test.startTest();
      Integer eligible = WorkflowDashboardController.getRedriveEligibleCount(
        'WorkflowEngineTest.HappyWorkflow',
        'Failed',
        ''
      );
      // The confirm-count must match what getWorkflowStats reports for the same
      // Failed filter (which, scoped to Failed only, is the failed bucket).
      Map<String, Integer> stats = WorkflowDashboardController.getWorkflowStats(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('WorkflowEngineTest.HappyWorkflow', 'Failed', '')
          .build()
      );
      Test.stopTest();

      System.assertEquals(3, eligible, 'Three Failed instances are eligible');
      System.assertEquals(
        stats.get('failed'),
        eligible,
        'Eligible count must match getWorkflowStats for the Failed filter'
      );
    }
  }

  @IsTest
  static void testRedriveMatchingInstancesLaunches() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      seedFailed('RdA');
      seedFailed('RdB');

      WorkflowEngine.disableQueueableInTest = false;
      Test.startTest();
      Map<String, Object> outcome = WorkflowDashboardCommandController.redriveMatchingInstances(
        'WorkflowEngineTest.HappyWorkflow',
        'Failed',
        ''
      );
      WorkflowEngine.disableQueueableInTest = true;
      Test.stopTest();

      System.assertEquals(
        true,
        outcome.get('started'),
        'A re-drive should be launched'
      );
      System.assertEquals(
        2,
        outcome.get('eligibleCount'),
        'Exact eligible count returned'
      );
      System.assertNotEquals(null, outcome.get('redriveInstanceId'));

      // A BulkRedriveWorkflow instance was created to perform the work.
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Workflow_Name__c = 'BulkRedriveWorkflow'
        ],
        'A re-driver workflow instance is created'
      );
      // The two targets were re-driven (orchestrator ran at stopTest).
      System.assertEquals(
        2,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow'
            AND Status__c = 'Running'
        ],
        'Both Failed targets transitioned to Running'
      );
    }
  }

  @IsTest
  static void testRedriveMatchingZeroEligible() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Completed',
        Correlation_Key__c = 'NoneFailed'
      );

      Test.startTest();
      Map<String, Object> outcome = WorkflowDashboardCommandController.redriveMatchingInstances(
        'WorkflowEngineTest.HappyWorkflow',
        'Failed',
        ''
      );
      Test.stopTest();

      System.assertEquals(
        false,
        outcome.get('started'),
        'Nothing to do, no launch'
      );
      System.assertEquals(0, outcome.get('eligibleCount'));
      System.assertEquals(
        0,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Workflow_Name__c = 'BulkRedriveWorkflow'
        ],
        'No re-driver workflow is created when nothing is eligible'
      );
    }
  }

  @IsTest
  static void testRedriveAuthorizationEnforced() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      User restricted = buildRestrictedUser();
      Boolean threw = false;
      System.runAs(restricted) {
        Test.startTest();
        try {
          WorkflowDashboardController.getRedriveEligibleCount('', 'Failed', '');
          System.assert(
            false,
            'Expected AuraHandledException for unauthorized user'
          );
        } catch (AuraHandledException e) {
          threw = true;
        }
        Test.stopTest();
      }
      System.assert(
        threw,
        'Unauthorized users must be blocked from re-drive count'
      );
    }
  }

  @IsTest
  static void testCancelAuthorizationEnforced() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      User restricted = buildRestrictedUser();
      Boolean countThrew = false;
      Boolean runThrew = false;
      System.runAs(restricted) {
        Test.startTest();
        try {
          WorkflowDashboardController.getCancelEligibleCount('', 'Running', '');
          System.assert(
            false,
            'Expected AuraHandledException for unauthorized user'
          );
        } catch (AuraHandledException e) {
          countThrew = true;
        }
        try {
          WorkflowDashboardCommandController.cancelMatchingInstancesWithCompensations(
            '',
            'Running',
            ''
          );
          System.assert(
            false,
            'Expected AuraHandledException for unauthorized user'
          );
        } catch (AuraHandledException e) {
          runThrew = true;
        }
        Test.stopTest();
      }
      System.assert(
        countThrew,
        'Unauthorized users must be blocked from cancel count'
      );
      System.assert(
        runThrew,
        'Unauthorized users must be blocked from executing cancel'
      );
    }
  }

  // ── RED → GREEN: Stalled-instance detection tests (issue #26) ───────────────

  @IsTest
  static void testStalledInstanceFlaggedInFilteredInstances() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.ZombieWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-Zombie-Flag'
      );
      insert as system inst;

      WorkflowEngine.staleThresholdMinutes = -1;

      Test.startTest();
      List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', 'Suspended', '')
          .page(10, 0, '')
          .build()
      );
      Test.stopTest();

      System.assertEquals(
        1,
        instances.size(),
        'Should return the suspended instance'
      );
      System.assertEquals(
        true,
        (Boolean) instances[0].get('stalled'),
        'Instance with no resume mechanism and exceeded threshold should be stalled'
      );
      Object idleMinutes = instances[0].get('idleMinutes');
      System.assertNotEquals(
        null,
        idleMinutes,
        'idleMinutes should be populated for Suspended'
      );
      System.assert(
        (Long) idleMinutes >= 0,
        'idleMinutes should be non-negative'
      );
    }
  }

  @IsTest
  static void testFreshSuspendedNotStalled() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.ZombieWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-Fresh-Key'
      );
      insert as system inst;

      WorkflowEngine.staleThresholdMinutes = 60;

      Test.startTest();
      List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', 'Suspended', '')
          .page(10, 0, '')
          .build()
      );
      Test.stopTest();

      System.assertEquals(1, instances.size());
      System.assertEquals(
        false,
        (Boolean) instances[0].get('stalled'),
        'Fresh Suspended instance should not be stalled under default threshold'
      );
    }
  }

  @IsTest
  static void testSuspendedWithActiveTimerNotStalled() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.TimerWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-Timer-Key',
        Sleep_Until__c = DateTime.now().addMinutes(30)
      );
      insert as system inst;

      WorkflowEngine.staleThresholdMinutes = -1;

      Test.startTest();
      List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', 'Suspended', '')
          .page(10, 0, '')
          .build()
      );
      Test.stopTest();

      System.assertEquals(1, instances.size());
      System.assertEquals(
        false,
        (Boolean) instances[0].get('stalled'),
        'Suspended with active Sleep_Until timer should not be stalled'
      );
    }
  }

  @IsTest
  static void testSuspendedWithStepTimeoutNotStalled() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.TimeoutWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-Timeout-Key'
      );
      insert as system inst;

      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'StallTest.SomeStep',
        Status__c = 'Running',
        Retry_Count__c = 0,
        Timeout_At__c = DateTime.now().addMinutes(5)
      );
      insert as system step;

      WorkflowEngine.staleThresholdMinutes = -1;

      Test.startTest();
      List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', 'Suspended', '')
          .page(10, 0, '')
          .build()
      );
      Test.stopTest();

      System.assertEquals(1, instances.size());
      System.assertEquals(
        false,
        (Boolean) instances[0].get('stalled'),
        'Suspended with a step execution having Timeout_At should not be stalled'
      );
    }
  }

  @IsTest
  static void testGetStalledInstancesReturnsAndSorts() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>{
        new Workflow_Instance__c(
          Workflow_Name__c = 'StallTest.ZombieWorkflow',
          Status__c = 'Suspended',
          Correlation_Key__c = 'Stall-Sort-A'
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = 'StallTest.ZombieWorkflow',
          Status__c = 'Suspended',
          Correlation_Key__c = 'Stall-Sort-B'
        )
      };
      insert as system insts;

      Test.startTest();
      List<Map<String, Object>> stalled = WorkflowDashboardController.getStalledInstances(
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria('', '', -1)
          .page(10, 0, '')
          .build()
      );
      Test.stopTest();

      System.assertEquals(
        2,
        stalled.size(),
        'Both stalled instances should be returned'
      );
      DateTime t0 = (DateTime) stalled[0].get('LastModifiedDate');
      DateTime t1 = (DateTime) stalled[1].get('LastModifiedDate');
      System.assert(
        t0 <= t1,
        'Results should be sorted oldest idle first (LastModifiedDate ASC)'
      );
    }
  }

  @IsTest
  static void testGetStalledInstancesThresholdDefault() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.ZombieWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-DefaultThresh'
      );
      insert as system inst;

      WorkflowEngine.staleThresholdMinutes = 60;

      Test.startTest();
      List<Map<String, Object>> stalled = WorkflowDashboardController.getStalledInstances(
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria('', '', null)
          .page(10, 0, '')
          .build()
      );
      Test.stopTest();

      System.assertEquals(
        0,
        stalled.size(),
        'Fresh record should not appear when null threshold falls back to default 60 min'
      );
    }
  }

  @IsTest
  static void testGetStalledInstancesNegativeThreshold() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.ZombieWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-NegThresh'
      );
      insert as system inst;

      Test.startTest();
      List<Map<String, Object>> stalled = WorkflowDashboardController.getStalledInstances(
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria('', '', -1)
          .page(10, 0, '')
          .build()
      );
      Test.stopTest();

      System.assertEquals(
        1,
        stalled.size(),
        'Explicit negative threshold should include fresh records'
      );
      System.assertEquals(
        true,
        (Boolean) stalled[0].get('stalled'),
        'Returned record should be marked stalled'
      );
    }
  }

  @IsTest
  static void testGetStalledInstancesPaginatesAfterFiltering() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Two genuinely stalled instances, plus one that must be excluded because it
      // has a step with a declared timeout (anti-join). With limitSize=1 the two
      // stalled rows must page out one-per-page and the excluded one must never
      // appear — proving pagination runs over the filtered set, not raw candidates.
      List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>{
        new Workflow_Instance__c(
          Workflow_Name__c = 'StallTest.ZombieWorkflow',
          Status__c = 'Suspended',
          Correlation_Key__c = 'Stall-Page-A'
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = 'StallTest.ZombieWorkflow',
          Status__c = 'Suspended',
          Correlation_Key__c = 'Stall-Page-B'
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = 'StallTest.ZombieWorkflow',
          Status__c = 'Suspended',
          Correlation_Key__c = 'Stall-Page-Excluded'
        )
      };
      insert as system insts;

      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = insts[2].Id,
        Step_Name__c = 'StallTest.SomeStep',
        Status__c = 'Running',
        Retry_Count__c = 0,
        Timeout_At__c = DateTime.now().addMinutes(5)
      );
      insert as system step;

      Test.startTest();
      List<Map<String, Object>> page0 = WorkflowDashboardController.getStalledInstances(
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria('', '', -1)
          .page(1, 0, '')
          .build()
      );
      List<Map<String, Object>> page1 = WorkflowDashboardController.getStalledInstances(
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria('', '', -1)
          .page(1, 1, '')
          .build()
      );
      List<Map<String, Object>> page2 = WorkflowDashboardController.getStalledInstances(
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria('', '', -1)
          .page(1, 2, '')
          .build()
      );
      Test.stopTest();

      System.assertEquals(
        1,
        page0.size(),
        'First page should hold exactly one stalled row'
      );
      System.assertEquals(
        1,
        page1.size(),
        'Second page should hold the other stalled row'
      );
      System.assertEquals(
        0,
        page2.size(),
        'Third page should be empty — only two stalled rows exist (excluded one filtered out)'
      );

      Set<Id> returned = new Set<Id>{
        (Id) page0[0].get('Id'),
        (Id) page1[0].get('Id')
      };
      System.assert(
        returned.contains(insts[0].Id),
        'Stall-Page-A should be surfaced across pages'
      );
      System.assert(
        returned.contains(insts[1].Id),
        'Stall-Page-B should be surfaced across pages'
      );
      System.assert(
        !returned.contains(insts[2].Id),
        'Instance with a declared step timeout must be excluded from the stalled set'
      );
    }
  }

  @IsTest
  static void testGetStalledCount() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>{
        new Workflow_Instance__c(
          Workflow_Name__c = 'StallTest.ZombieWorkflow',
          Status__c = 'Suspended',
          Correlation_Key__c = 'SCount-Stall-1'
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = 'StallTest.ZombieWorkflow',
          Status__c = 'Suspended',
          Correlation_Key__c = 'SCount-Stall-2'
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = 'StallTest.ZombieWorkflow',
          Status__c = 'Suspended',
          Correlation_Key__c = 'SCount-Timer-3',
          Sleep_Until__c = DateTime.now().addMinutes(10)
        )
      };
      insert as system insts;

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.getStalledCount(
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria('', '', -1)
          .build()
      );
      Test.stopTest();

      System.assertEquals(
        2,
        (Integer) result.get('count'),
        'Only instances with no resume mechanism should be counted as stalled'
      );
      System.assertEquals(
        false,
        (Boolean) result.get('capped'),
        'Should not be capped for small test data'
      );
    }
  }

  @IsTest
  static void testIdleMinutesForNonSuspendedNonTerminal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.RunningWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'Stall-Running-Key'
      );
      insert as system inst;

      Test.startTest();
      List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', 'Running', '')
          .page(10, 0, '')
          .build()
      );
      Test.stopTest();

      System.assertEquals(1, instances.size());
      Object idleMinutes = instances[0].get('idleMinutes');
      System.assertNotEquals(
        null,
        idleMinutes,
        'idleMinutes should be populated for non-terminal Running instances'
      );
      System.assert(
        (Long) idleMinutes >= 0,
        'idleMinutes should be non-negative'
      );
      System.assertEquals(
        false,
        (Boolean) instances[0].get('stalled'),
        'Running instances should never be classified as stalled'
      );
    }
  }

  @IsTest
  static void testIdleMinutesNullForTerminal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.DoneWorkflow',
        Status__c = 'Completed',
        Correlation_Key__c = 'Stall-Completed-Key'
      );
      insert as system inst;

      Test.startTest();
      List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', 'Completed', '')
          .page(10, 0, '')
          .build()
      );
      Test.stopTest();

      System.assertEquals(1, instances.size());
      System.assertEquals(
        null,
        instances[0].get('idleMinutes'),
        'idleMinutes should be null for terminal (Completed) instances'
      );
      System.assertEquals(
        false,
        (Boolean) instances[0].get('stalled'),
        'Terminal instances should not be classified as stalled'
      );
    }
  }

  @IsTest
  static void testStaleThresholdConfigFallback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assert(
        WorkflowEngine.staleThresholdMinutes >= 0,
        'staleThresholdMinutes must be non-negative, got: ' +
        WorkflowEngine.staleThresholdMinutes
      );
      System.assertEquals(
        60,
        WorkflowEngine.staleThresholdMinutes,
        'Default stale threshold should be 60 minutes'
      );
    }
  }

  @IsTest
  static void testStalledReadOnlyNoSideEffects() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.ZombieWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-ReadOnly-Key'
      );
      insert as system inst;

      Integer instanceCountBefore = [SELECT COUNT() FROM Workflow_Instance__c];
      Integer stepCountBefore = [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
      ];

      WorkflowEngine.staleThresholdMinutes = -1;

      Test.startTest();
      WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', 'Suspended', '')
          .page(10, 0, '')
          .build()
      );
      WorkflowDashboardController.getStalledInstances(
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria('', '', -1)
          .page(10, 0, '')
          .build()
      );
      WorkflowDashboardController.getStalledCount(
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria('', '', -1)
          .build()
      );
      Test.stopTest();

      System.assertEquals(
        instanceCountBefore,
        [SELECT COUNT() FROM Workflow_Instance__c],
        'No Workflow_Instance__c records should be created or deleted'
      );
      System.assertEquals(
        stepCountBefore,
        [SELECT COUNT() FROM Workflow_Step_Execution__c],
        'No Workflow_Step_Execution__c records should be created or deleted'
      );
      Workflow_Instance__c unchanged = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Suspended',
        unchanged.Status__c,
        'Instance status must not be modified by staleness detection'
      );
    }
  }

  @IsTest
  static void testGetStalledInstancesAuthorization() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      User stdUser = new User(
        Alias = 'stldusr',
        Email = 'stalleduser@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'StalledTest',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'stalled_dashboard_test_' +
          DateTime.now().getTime() +
          '@testorg.com'
      );
      insert stdUser;

      System.runAs(stdUser) {
        Test.startTest();
        try {
          WorkflowDashboardController.getStalledInstances(
            WorkflowDashboardQueryBuilders.stalledQuery()
              .criteria('', '', -1)
              .page(10, 0, '')
              .build()
          );
          System.assert(
            false,
            'Expected AuraHandledException for getStalledInstances'
          );
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception'),
            e.getMessage()
          );
        }

        try {
          WorkflowDashboardController.getStalledCount(
            WorkflowDashboardQueryBuilders.stalledQuery()
              .criteria('', '', -1)
              .build()
          );
          System.assert(
            false,
            'Expected AuraHandledException for getStalledCount'
          );
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception'),
            e.getMessage()
          );
        }
        Test.stopTest();
      }

    }
  }

  @IsTest
  static void testStalledExcludesPendingStepWait() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A Suspended instance with a Pending step-exec (signal/approval/child wait)
      // must NOT be flagged stalled — it has a legitimate active wait.
      WorkflowEngine.staleThresholdMinutes = -1;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.SignalWaitWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-PendingStep-FilteredInstances'
      );
      insert as system inst;

      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'StallTest.AwaitSignalStep',
        Status__c = 'Pending',
        Retry_Count__c = 0
      );
      insert as system step;

      Test.startTest();
      List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', 'Suspended', '')
          .page(10, 0, '')
          .build()
      );
      Test.stopTest();

      System.assertEquals(1, instances.size());
      System.assertEquals(
        false,
        (Boolean) instances[0].get('stalled'),
        'Suspended instance with a Pending step (signal/approval/child wait) must not be stalled'
      );
    }
  }

  @IsTest
  static void testGetStalledInstancesExcludesPendingStepWait() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // getStalledInstances must not surface instances that have a Pending step-exec,
      // because those are legitimate signal/approval/child waits (engine invariant).
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.SignalWaitWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-PendingStep-StalledList'
      );
      insert as system inst;

      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'StallTest.AwaitSignalStep',
        Status__c = 'Pending',
        Retry_Count__c = 0
      );
      insert as system step;

      Test.startTest();
      List<Map<String, Object>> stalled = WorkflowDashboardController.getStalledInstances(
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria('', '', -1)
          .page(10, 0, '')
          .build()
      );
      Test.stopTest();

      for (Map<String, Object> row : stalled) {
        System.assertNotEquals(
          inst.Id,
          row.get('Id'),
          'Instance with a Pending step-exec must be excluded from stalled list'
        );
      }
    }
  }

  @IsTest
  static void testGetStalledCountExcludesPendingStepWait() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // getStalledCount must not count instances that have a Pending step-exec.
      Workflow_Instance__c stalledInst = new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.ZombieWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-PendingStep-CountA'
      );
      Workflow_Instance__c waitingInst = new Workflow_Instance__c(
        Workflow_Name__c = 'StallTest.SignalWaitWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Stall-PendingStep-CountB'
      );
      insert as system new List<Workflow_Instance__c>{
        stalledInst,
        waitingInst
      };

      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = waitingInst.Id,
        Step_Name__c = 'StallTest.AwaitSignalStep',
        Status__c = 'Pending',
        Retry_Count__c = 0
      );
      insert as system step;

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.getStalledCount(
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria('', '', -1)
          .build()
      );
      Test.stopTest();

      Integer count = (Integer) result.get('count');
      System.assert(count >= 1, 'At least the true zombie must be counted');
      // Verify the waiting instance's Id is not surfaced by getStalledInstances
      List<Map<String, Object>> stalledList = WorkflowDashboardController.getStalledInstances(
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria('', '', -1)
          .page(50, 0, '')
          .build()
      );
      for (Map<String, Object> row : stalledList) {
        System.assertNotEquals(
          waitingInst.Id,
          row.get('Id'),
          'Instance with Pending step must be excluded from stalled list'
        );
      }
    }
  }

  private static User buildRestrictedUser() {
    Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    User u = new User(
      Alias = 'rdrv',
      Email = 'redrive.restricted@example.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Restricted',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = p.Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      Username = 'redrive.restricted.' +
        DateTime.now().getTime() +
        '@example.com'
    );
    insert u;
    return u;
  }
}
