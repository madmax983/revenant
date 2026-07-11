@IsTest
public class WorkflowDashboardControllerTest {
  @IsTest
  static void testGetInstancesAndDetails() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Create mock parent workflow instance
      Workflow_Instance__c parentInst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Completed',
        Correlation_Key__c = 'TestParentKey',
        Input__c = '"ParentInput"'
      );
      insert parentInst;

      // Create mock child workflow instance
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Pending',
        Correlation_Key__c = 'TestDashboardKey',
        Input__c = '"InputData"',
        Parent_Instance__c = parentInst.Id
      );
      insert inst;

      // Create mock step execution
      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.HappyStep1',
        Status__c = 'Completed',
        Input__c = '"InputData"',
        Output__c = '"Output1"',
        Retry_Count__c = 0,
        CPU_Time_Ms__c = 50,
        SOQL_Query_Count__c = 5,
        Heap_Size_Bytes__c = 1000
      );
      insert step;

      Test.startTest();
      List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
        '',
        '',
        '',
        10,
        0,
        ''
      );
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        inst.Id
      );
      Map<String, Object> parentDetails = WorkflowDashboardController.getInstanceDetails(
        parentInst.Id
      );
      Test.stopTest();

      // Re-query parentInst to get the auto-number Name field
      parentInst = [
        SELECT Name
        FROM Workflow_Instance__c
        WHERE Id = :parentInst.Id
      ];

      // Should find two instances now
      System.assertEquals(2, instances.size(), 'Should find two instances');

      Workflow_Instance__c returnedInst = (Workflow_Instance__c) details.get(
        'instance'
      );
      List<Workflow_Step_Execution__c> returnedSteps = (List<Workflow_Step_Execution__c>) details.get(
        'steps'
      );
      List<Workflow_Instance__c> returnedChildren = (List<Workflow_Instance__c>) details.get(
        'children'
      );

      System.assertEquals(inst.Id, returnedInst.Id);
      System.assertEquals(parentInst.Id, returnedInst.Parent_Instance__c);
      System.assertEquals(
        parentInst.Name,
        returnedInst.Parent_Instance__r.Name
      );
      System.assertEquals(
        1,
        returnedSteps.size(),
        'Should find one step execution'
      );
      System.assertEquals(step.Id, returnedSteps[0].Id);
      System.assertEquals(50, returnedSteps[0].CPU_Time_Ms__c);
      System.assertEquals(5, returnedSteps[0].SOQL_Query_Count__c);
      System.assertEquals(1000, returnedSteps[0].Heap_Size_Bytes__c);
      System.assertEquals(0, returnedChildren.size(), 'Child has no children');

      // Check parent's details for children
      List<Workflow_Instance__c> parentChildren = (List<Workflow_Instance__c>) parentDetails.get(
        'children'
      );
      System.assertEquals(
        1,
        parentChildren.size(),
        'Parent should have one child'
      );
      System.assertEquals(inst.Id, parentChildren[0].Id);
    }
  }

  @IsTest
  static void testGetDefinitions() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      List<String> definitions = WorkflowDashboardController.getDefinitions();
      Test.stopTest();

      // Should return a list of classes containing "implements WorkflowDefinition" or "implements VersionedWorkflow"
      System.assert(definitions != null, 'Definitions list should not be null');
      System.assert(
        definitions.contains('CleanupWorkflow'),
        'Should find CleanupWorkflow'
      );
      System.assert(
        !definitions.contains('BulkCancelWorkflow'),
        'Should not find BulkCancelWorkflow (system workflow)'
      );
      System.assert(
        definitions.contains('BatchFanoutWorkflowExample.BatchFanoutWorkflow'),
        'Should find BatchFanoutWorkflowExample.BatchFanoutWorkflow inner class'
      );
      System.assert(
        definitions.contains('SagaWorkflowExample.SagaWorkflow'),
        'Should find SagaWorkflowExample.SagaWorkflow inner class'
      );
      // Regression (PR #?, 2026-06-20): the @IsTest-substring guard skipped any
      // class merely *mentioning* @IsTest in a comment. Both AI examples document
      // @IsTest in their doc comments, so they silently fell out of discovery.
      System.assert(
        definitions.contains('AiSupportTriageWorkflowExample.TriageWorkflow'),
        'Should find AiSupportTriageWorkflowExample.TriageWorkflow despite the ' +
        '@IsTest mention in its doc comment'
      );
      System.assert(
        definitions.contains(
          'AgentConversationWorkflowExample.AgentConversationWorkflow'
        ),
        'Should find AgentConversationWorkflowExample.AgentConversationWorkflow ' +
        'despite the @IsTest mention in its doc comment'
      );
      // Regression: the discovery regex matched comment prose. A doc comment in
      // WorkflowScheduleSweeper reads "...a class that implements WorkflowDefinition",
      // which captured "that" as a phantom definition.
      System.assert(
        !definitions.contains('WorkflowScheduleSweeper.that'),
        'Comment prose must not be scanned as a definition (no phantom ".that")'
      );
    }
  }

  @IsTest
  static void testStartWorkflow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Id instanceId = WorkflowDashboardController.startWorkflow(
        'WorkflowEngineTest.HappyWorkflow',
        'StartDashboardKey',
        '"InputPayload"'
      );
      Test.stopTest();

      System.assertNotEquals(
        null,
        instanceId,
        'Should start workflow and return ID'
      );

      Workflow_Instance__c inst = [
        SELECT Workflow_Name__c, Status__c, Correlation_Key__c, Input__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'WorkflowEngineTest.HappyWorkflow',
        inst.Workflow_Name__c
      );
      System.assertEquals('StartDashboardKey', inst.Correlation_Key__c);
      System.assertEquals('"InputPayload"', inst.Input__c);
    }
  }

  @IsTest
  static void testRetryWorkflowInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Create a failed instance
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Failed',
        Correlation_Key__c = 'FailedKey',
        Input__c = '"InputData"',
        Current_Step__c = 'WorkflowEngineTest.HappyStep1'
      );
      insert inst;

      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.HappyStep1',
        Status__c = 'Failed',
        Retry_Count__c = 1,
        Error_Details__c = 'Some error'
      );
      insert step;

      Test.startTest();
      WorkflowDashboardController.retryWorkflowInstance(inst.Id);
      Test.stopTest();

      Workflow_Instance__c updatedInst = [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals('Running', updatedInst.Status__c);
      System.assertEquals(null, updatedInst.Error_Message__c);

      Workflow_Step_Execution__c updatedStep = [
        SELECT Status__c, Retry_Count__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :step.Id
      ];
      System.assertEquals('Completed', updatedStep.Status__c);
      System.assertEquals(0, updatedStep.Retry_Count__c);
      System.assertEquals(null, updatedStep.Error_Details__c);
    }
  }

  @IsTest
  static void testSubmitApproval() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Create active instance
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'ApprovalKey',
        Input__c = '"InputData"'
      );
      insert inst;

      Test.startTest();
      WorkflowDashboardController.ApprovalRequest approvalReq = new WorkflowDashboardController.ApprovalRequest();
      approvalReq.instanceId = inst.Id;
      approvalReq.approvalKey = 'ExpenseApproval';
      approvalReq.approved = true;
      approvalReq.comments = 'Looks good';
      WorkflowDashboardController.submitApproval(approvalReq);
      Test.stopTest();

      // Deliver Platform Event
      Test.getEventBus().deliver();

      // Verify a signal is received in database
      List<Workflow_Signal__c> signals = [
        SELECT Id, Signal_Name__c, Payload__c, Status__c
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :inst.Id
      ];
      System.assertEquals(1, signals.size());
      System.assertEquals('Approve:ExpenseApproval', signals[0].Signal_Name__c);
      System.assert(signals[0].Payload__c.contains('"approved":true'));
      System.assert(signals[0].Payload__c.contains('"comments":"Looks good"'));
    }
  }

  @IsTest
  static void testCancelWorkflowInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Create running instance
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'CancelDashKey',
        Input__c = '"InputData"'
      );
      insert inst;

      Test.startTest();
      WorkflowDashboardController.CancelRequest cancelReq = new WorkflowDashboardController.CancelRequest();
      cancelReq.instanceId = inst.Id;
      cancelReq.runCompensations = false;
      WorkflowDashboardController.cancelWorkflow(cancelReq);
      Test.stopTest();

      Workflow_Instance__c updatedInst = [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals('Cancelled', updatedInst.Status__c);
      System.assertEquals('Cancelled by user.', updatedInst.Error_Message__c);
    }
  }

  @IsTest
  static void testGetFilteredInstances() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Create 3 instances with distinct details
      List<Workflow_Instance__c> testInstances = new List<Workflow_Instance__c>{
        new Workflow_Instance__c(
          Workflow_Name__c = 'TestDefA',
          Status__c = 'Completed',
          Correlation_Key__c = 'AppleKey',
          Input__c = '"TestInput"'
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = 'TestDefA',
          Status__c = 'Failed',
          Correlation_Key__c = 'BananaKey',
          Input__c = '"TestInput"',
          Error_Message__c = 'Slipped on banana'
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = 'TestDefB',
          Status__c = 'Running',
          Correlation_Key__c = 'OrangeKey',
          Input__c = '"TestInput"'
        )
      };
      insert testInstances;

      Test.startTest();
      // 1. Test filtering by Workflow Name
      List<Map<String, Object>> resWorkflow = WorkflowDashboardController.getFilteredInstances(
        'TestDefA',
        '',
        '',
        10,
        0,
        'cb1'
      );
      System.assertEquals(
        2,
        resWorkflow.size(),
        'Should find 2 instances with definition TestDefA'
      );

      // 2. Test filtering by Status
      List<Map<String, Object>> resStatus = WorkflowDashboardController.getFilteredInstances(
        '',
        'Running',
        '',
        10,
        0,
        'cb2'
      );
      System.assertEquals(
        1,
        resStatus.size(),
        'Should find 1 instance with Status Running'
      );
      System.assertEquals(
        'OrangeKey',
        (String) resStatus[0].get('Correlation_Key__c')
      );

      // 3. Test filtering by Search Term on Correlation Key
      List<Map<String, Object>> resSearchKey = WorkflowDashboardController.getFilteredInstances(
        '',
        '',
        'Banana',
        10,
        0,
        'cb3'
      );
      System.assertEquals(
        1,
        resSearchKey.size(),
        'Should find 1 instance matching search Banana'
      );
      System.assertEquals(
        'BananaKey',
        (String) resSearchKey[0].get('Correlation_Key__c')
      );

      // 4. Test filtering by Search Term case-insensitivity on Correlation Key
      List<Map<String, Object>> resSearchError = WorkflowDashboardController.getFilteredInstances(
        '',
        '',
        'banana',
        10,
        0,
        'cb4'
      );
      System.assertEquals(
        1,
        resSearchError.size(),
        'Search term search should be case-insensitive'
      );

      // 5. Test pagination: limit and offset
      List<Map<String, Object>> page1 = WorkflowDashboardController.getFilteredInstances(
        '',
        '',
        '',
        2,
        0,
        'cb5'
      );
      System.assertEquals(
        2,
        page1.size(),
        'Page 1 limit 2 should return 2 records'
      );

      List<Map<String, Object>> page2 = WorkflowDashboardController.getFilteredInstances(
        '',
        '',
        '',
        2,
        2,
        'cb6'
      );
      System.assertEquals(
        1,
        page2.size(),
        'Page 2 offset 2 limit 2 should return the remaining 1 record'
      );

      Test.stopTest();
    }
  }

  @IsTest
  static void testGetWorkflowStats() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Create 3 instances with distinct details
      List<Workflow_Instance__c> testInstances = new List<Workflow_Instance__c>{
        new Workflow_Instance__c(
          Workflow_Name__c = 'TestDefA',
          Status__c = 'Completed',
          Correlation_Key__c = 'AppleKey',
          Input__c = '"TestInput"'
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = 'TestDefA',
          Status__c = 'Failed',
          Correlation_Key__c = 'BananaKey',
          Input__c = '"TestInput"',
          Error_Message__c = 'Slipped on banana'
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = 'TestDefB',
          Status__c = 'Running',
          Correlation_Key__c = 'OrangeKey',
          Input__c = '"TestInput"'
        )
      };
      insert testInstances;

      Test.startTest();
      // 1. Get stats overall (no filters)
      Map<String, Integer> statsAll = WorkflowDashboardController.getWorkflowStats(
        '',
        '',
        ''
      );
      System.assertEquals(
        3,
        statsAll.get('total'),
        'Should count 3 total runs'
      );
      System.assertEquals(
        1,
        statsAll.get('active'),
        'Should count 1 active run'
      );
      System.assertEquals(
        1,
        statsAll.get('completed'),
        'Should count 1 completed run'
      );
      System.assertEquals(
        1,
        statsAll.get('failed'),
        'Should count 1 failed run'
      );

      // 2. Get stats filtered by definition A
      Map<String, Integer> statsDefA = WorkflowDashboardController.getWorkflowStats(
        'TestDefA',
        '',
        ''
      );
      System.assertEquals(2, statsDefA.get('total'));
      System.assertEquals(0, statsDefA.get('active'));
      System.assertEquals(1, statsDefA.get('completed'));
      System.assertEquals(1, statsDefA.get('failed'));

      // 3. Get stats filtered by search term
      Map<String, Integer> statsSearch = WorkflowDashboardController.getWorkflowStats(
        '',
        '',
        'Banana'
      );
      System.assertEquals(1, statsSearch.get('total'));
      System.assertEquals(1, statsSearch.get('failed'));
      Test.stopTest();
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // getDefinitionTrends — per-definition success-rate & throughput (Issue #33)
  // ──────────────────────────────────────────────────────────────────────────

  /** Returns the row Map for the given workflow name from a getDefinitionTrends result. */
  private static Map<String, Object> findTrendRow(
    Map<String, Object> trends,
    String workflowName
  ) {
    List<Object> rows = (List<Object>) trends.get('rows');
    for (Object o : rows) {
      Map<String, Object> row = (Map<String, Object>) o;
      if (workflowName.equals((String) row.get('workflowName'))) {
        return row;
      }
    }
    return null;
  }

  @IsTest
  static void testGetDefinitionTrends() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = Datetime.now();
      List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>();
      // OnboardingWorkflow: 4 success (Completed), 1 failure (Failed) → 80% over 5 terminal
      for (Integer i = 0; i < 4; i++) {
        insts.add(
          new Workflow_Instance__c(
            Workflow_Name__c = 'OnboardingWorkflow',
            Status__c = 'Completed',
            Terminal_At__c = now
          )
        );
      }
      insts.add(
        new Workflow_Instance__c(
          Workflow_Name__c = 'OnboardingWorkflow',
          Status__c = 'Failed',
          Terminal_At__c = now
        )
      );
      // BillingWorkflow: 1 success (Completed), 2 failure (Failed) → 33.3% over 3 terminal
      insts.add(
        new Workflow_Instance__c(
          Workflow_Name__c = 'BillingWorkflow',
          Status__c = 'Completed',
          Terminal_At__c = now
        )
      );
      for (Integer i = 0; i < 2; i++) {
        insts.add(
          new Workflow_Instance__c(
            Workflow_Name__c = 'BillingWorkflow',
            Status__c = 'Failed',
            Terminal_At__c = now
          )
        );
      }
      // SagaWorkflow: exercises the full bucketing convention for genuinely terminal
      // statuses. CompensationFailed is intentionally omitted: it is non-terminal
      // and WorkflowInstanceTrigger never stamps Terminal_At__c for it, so the
      // windowed query can never see such instances in production.
      // success = ContinuedAsNew; failure = Compensated / Cancelled / Failed
      insts.add(
        new Workflow_Instance__c(
          Workflow_Name__c = 'SagaWorkflow',
          Status__c = 'ContinuedAsNew',
          Terminal_At__c = now
        )
      );
      insts.add(
        new Workflow_Instance__c(
          Workflow_Name__c = 'SagaWorkflow',
          Status__c = 'Compensated',
          Terminal_At__c = now
        )
      );
      insts.add(
        new Workflow_Instance__c(
          Workflow_Name__c = 'SagaWorkflow',
          Status__c = 'Cancelled',
          Terminal_At__c = now
        )
      );
      insts.add(
        new Workflow_Instance__c(
          Workflow_Name__c = 'SagaWorkflow',
          Status__c = 'Failed',
          Terminal_At__c = now
        )
      );
      insert insts;

      Test.startTest();
      Map<String, Object> trends = WorkflowDashboardController.getDefinitionTrends(
        '24h'
      );
      Test.stopTest();

      System.assertEquals(
        24,
        trends.get('windowHours'),
        'windowHours should be 24'
      );
      List<Object> rows = (List<Object>) trends.get('rows');
      System.assertEquals(3, rows.size(), 'Should have one row per definition');

      // Rows are worst-first (highest failure count). Saga(3) > Billing(2) > Onboarding(1).
      Map<String, Object> first = (Map<String, Object>) rows[0];
      System.assertEquals(
        'SagaWorkflow',
        first.get('workflowName'),
        'Highest-failure definition should sort first'
      );

      Map<String, Object> onboarding = findTrendRow(
        trends,
        'OnboardingWorkflow'
      );
      System.assertEquals(5, onboarding.get('terminalCount'));
      System.assertEquals(4, onboarding.get('successCount'));
      System.assertEquals(1, onboarding.get('failureCount'));
      System.assertEquals(
        80.0,
        (Decimal) onboarding.get('successRate'),
        'Success rate should be success/terminal as a percent'
      );
      System.assertNotEquals(
        null,
        onboarding.get('throughputPerHour'),
        'throughputPerWindow was removed; throughputPerHour must be present'
      );
      System.assertEquals(
        0.21,
        (Decimal) onboarding.get('throughputPerHour'),
        'Throughput per hour = 5 terminal / 24h, rounded to 2dp'
      );

      Map<String, Object> billing = findTrendRow(trends, 'BillingWorkflow');
      System.assertEquals(3, billing.get('terminalCount'));
      System.assertEquals(1, billing.get('successCount'));
      System.assertEquals(2, billing.get('failureCount'));
      System.assertEquals(33.3, (Decimal) billing.get('successRate'));

      Map<String, Object> saga = findTrendRow(trends, 'SagaWorkflow');
      System.assertEquals(4, saga.get('terminalCount'));
      System.assertEquals(
        1,
        saga.get('successCount'),
        'ContinuedAsNew is success'
      );
      System.assertEquals(
        3,
        saga.get('failureCount'),
        'Compensated/Cancelled/Failed are failures; CompensationFailed excluded (non-terminal)'
      );
      System.assertEquals(25.0, (Decimal) saga.get('successRate'));
    }
  }

  @IsTest
  static void testGetDefinitionTrendsWindowFiltersByTerminalTime() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = Datetime.now();

      // WorkflowInstanceTrigger (before insert) stamps Terminal_At__c = System.now()
      // for every terminal status on insert, overwriting any value set in the test.
      // To control Terminal_At__c, we insert without specifying it, then update the
      // record that must appear "old". An update where Status__c stays Completed →
      // Completed is a terminal→terminal transition, so the trigger's wasTerminal guard
      // fires and it does NOT re-stamp, leaving our backdated value intact.
      Workflow_Instance__c recentInst = new Workflow_Instance__c(
        Workflow_Name__c = 'WindowDef',
        Status__c = 'Completed'
        // Trigger stamps Terminal_At__c = System.now() — inside both 24h and 7d windows.
      );
      Workflow_Instance__c oldInst = new Workflow_Instance__c(
        Workflow_Name__c = 'WindowDef',
        Status__c = 'Completed'
        // Trigger stamps now on insert; we backdate it below.
      );
      insert new List<Workflow_Instance__c>{
        recentInst,
        oldInst,
        // Active instance: trigger sets Terminal_At__c = null for non-terminal statuses.
        new Workflow_Instance__c(
          Workflow_Name__c = 'WindowDef',
          Status__c = 'Running'
        )
      };

      // Backdate to 3 days ago — inside 7d but outside 24h.
      // Trigger does not re-stamp: old status == new status == Completed (wasTerminal = true).
      oldInst.Terminal_At__c = now.addDays(-3);
      update oldInst;

      Test.startTest();
      Map<String, Object> last24h = WorkflowDashboardController.getDefinitionTrends(
        '24h'
      );
      Map<String, Object> last7d = WorkflowDashboardController.getDefinitionTrends(
        '7d'
      );
      Test.stopTest();

      Map<String, Object> row24 = findTrendRow(last24h, 'WindowDef');
      System.assertEquals(
        1,
        row24.get('terminalCount'),
        'Only the instance terminal within 24h counts; active (null Terminal_At__c) excluded'
      );

      System.assertEquals(
        168,
        last7d.get('windowHours'),
        '7d window is 168 hours'
      );
      Map<String, Object> row7 = findTrendRow(last7d, 'WindowDef');
      System.assertEquals(
        2,
        row7.get('terminalCount'),
        'Both terminal instances fall within 7d; active still excluded'
      );
    }
  }

  @IsTest
  static void testGetDefinitionTrendsEmptyRendersCleanly() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Only an active instance exists — nothing terminal in the window.
      insert new Workflow_Instance__c(
        Workflow_Name__c = 'QuietDef',
        Status__c = 'Running'
      );

      Test.startTest();
      Map<String, Object> trends = WorkflowDashboardController.getDefinitionTrends(
        '24h'
      );
      Test.stopTest();

      List<Object> rows = (List<Object>) trends.get('rows');
      System.assertEquals(
        0,
        rows.size(),
        'No terminal activity in window yields an empty (not null) rows list, no divide-by-zero'
      );
    }
  }

  @IsTest
  static void testGetDefinitionTrendsWindowKeyMapping() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      System.assertEquals(
        1,
        WorkflowDashboardController.getDefinitionTrends('1h').get('windowHours')
      );
      System.assertEquals(
        24,
        WorkflowDashboardController.getDefinitionTrends('24h')
          .get('windowHours')
      );
      System.assertEquals(
        168,
        WorkflowDashboardController.getDefinitionTrends('7d').get('windowHours')
      );
      // Blank / unrecognized defaults to 24h.
      System.assertEquals(
        24,
        WorkflowDashboardController.getDefinitionTrends(null).get('windowHours')
      );
      System.assertEquals(
        24,
        WorkflowDashboardController.getDefinitionTrends('bogus')
          .get('windowHours')
      );
      Test.stopTest();
    }
  }

  @IsTest
  static void testGetDefinitionTrendsAuthorization() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      User stdUser = new User(
        Alias = 'stdusr',
        Email = 'stduser@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'Testing',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'stduser_trends_test_' +
          DateTime.now().getTime() +
          '@testorg.com'
      );
      insert stdUser;

      System.runAs(stdUser) {
        try {
          WorkflowDashboardController.getDefinitionTrends('24h');
          System.assert(
            false,
            'Expected AuraHandledException for getDefinitionTrends'
          );
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception'),
            e.getMessage()
          );
        }
      }

    }
  }

  @IsTest
  static void testAuthorizationFailures() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Create standard user who does not have the custom permission or System Administrator profile
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      User stdUser = new User(
        Alias = 'stdusr',
        Email = 'stduser@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'Testing',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'stduser_dashboard_test_' +
          DateTime.now().getTime() +
          '@testorg.com'
      );
      insert stdUser;

      System.runAs(stdUser) {
        // 1. getFilteredInstances
        try {
          WorkflowDashboardController.getFilteredInstances(
            '',
            '',
            '',
            10,
            0,
            ''
          );
          System.assert(
            false,
            'Expected AuraHandledException for getFilteredInstances'
          );
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception'),
            e.getMessage()
          );
        }

        // 2. getWorkflowStats
        try {
          WorkflowDashboardController.getWorkflowStats('', '', '');
          System.assert(
            false,
            'Expected AuraHandledException for getWorkflowStats'
          );
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception'),
            e.getMessage()
          );
        }

        // 3. getInstanceDetails
        try {
          WorkflowDashboardController.getInstanceDetails(null);
          System.assert(
            false,
            'Expected AuraHandledException for getInstanceDetails'
          );
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception'),
            e.getMessage()
          );
        }

        // 4. getDefinitions
        try {
          WorkflowDashboardController.getDefinitions();
          System.assert(
            false,
            'Expected AuraHandledException for getDefinitions'
          );
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception'),
            e.getMessage()
          );
        }

        // 5. startWorkflow
        try {
          WorkflowDashboardController.startWorkflow('', '', '');
          System.assert(
            false,
            'Expected AuraHandledException for startWorkflow'
          );
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception'),
            e.getMessage()
          );
        }

        // 6. retryWorkflowInstance
        try {
          WorkflowDashboardController.retryWorkflowInstance(null);
          System.assert(
            false,
            'Expected AuraHandledException for retryWorkflowInstance'
          );
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception'),
            e.getMessage()
          );
        }

        // 7. cancelWorkflow
        try {
          WorkflowDashboardController.CancelRequest cancelReq = new WorkflowDashboardController.CancelRequest();
          cancelReq.instanceId = null;
          cancelReq.runCompensations = false;
          WorkflowDashboardController.cancelWorkflow(cancelReq);
          System.assert(
            false,
            'Expected AuraHandledException for cancelWorkflow'
          );
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception'),
            e.getMessage()
          );
        }

        // 8. submitApproval
        try {
          WorkflowDashboardController.ApprovalRequest approvalReq = new WorkflowDashboardController.ApprovalRequest();
          approvalReq.instanceId = null;
          approvalReq.approvalKey = '';
          approvalReq.approved = false;
          approvalReq.comments = '';
          WorkflowDashboardController.submitApproval(approvalReq);
          System.assert(
            false,
            'Expected AuraHandledException for submitApproval'
          );
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception'),
            e.getMessage()
          );
        }
      }

    }
  }

  @IsTest
  static void testAuthorizationSuccessWithCustomPermission() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Create standard user
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      User stdUser = new User(
        Alias = 'stdusr',
        Email = 'stduser@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'Testing',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'stduser_dashboard_ok_' +
          DateTime.now().getTime() +
          '@testorg.com'
      );
      insert stdUser;

      // Create a PermissionSet and SetupEntityAccess for custom permission
      CustomPermission cp = [
        SELECT Id
        FROM CustomPermission
        WHERE DeveloperName = 'Workflow_Admin'
        LIMIT 1
      ];
      PermissionSet ps = new PermissionSet(
        Label = 'Workflow Admin Test PS',
        Name = 'Workflow_Admin_Test_PS'
      );
      insert ps;

      SetupEntityAccess sea = new SetupEntityAccess(
        ParentId = ps.Id,
        SetupEntityId = cp.Id
      );
      insert sea;

      PermissionSetAssignment psa = new PermissionSetAssignment(
        AssigneeId = stdUser.Id,
        PermissionSetId = ps.Id
      );
      insert psa;

      System.runAs(stdUser) {
        // Call getDefinitions, should not throw unauthorized exception
        List<String> definitions = WorkflowDashboardController.getDefinitions();
        System.assertNotEquals(null, definitions);
      }

    }
  }

  @IsTest
  static void testSearchByErrorMessage() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Create instance with error message
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'TestDefC',
        Status__c = 'Failed',
        Correlation_Key__c = 'UnrelatedKey',
        Input__c = '"TestInput"',
        Error_Message__c = 'Unique error message xyz'
      );
      insert inst;

      Test.startTest();
      List<Map<String, Object>> res = WorkflowDashboardController.getFilteredInstances(
        '',
        '',
        'xyz',
        10,
        0,
        'cbError'
      );
      Test.stopTest();

      System.assertEquals(
        1,
        res.size(),
        'Should find 1 instance with Error Message matching xyz'
      );
      System.assertEquals(inst.Id, (Id) res[0].get('Id'));
    }
  }

  @IsTest
  static void testBulkPayloadResolutionAndTruncation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Create ContentVersion records
      ContentVersion cv1 = new ContentVersion(
        Title = 'TestCV1',
        PathOnClient = 'test1.json',
        VersionData = Blob.valueOf('{"small":"json"}')
      );
      ContentVersion cv2 = new ContentVersion(
        Title = 'TestCV2',
        PathOnClient = 'test2.json',
        VersionData = Blob.valueOf('A'.repeat(50005))
      );
      ContentVersion cv3 = new ContentVersion(
        Title = 'TestCV3',
        PathOnClient = 'test3.json',
        VersionData = Blob.valueOf('B'.repeat(60000))
      );
      ContentVersion cv4 = new ContentVersion(
        Title = 'TestCV4',
        PathOnClient = 'test4.json',
        VersionData = Blob.valueOf('{"result":"ok"}')
      );
      insert new List<ContentVersion>{ cv1, cv2, cv3, cv4 };

      // Query ContentDocumentId for each
      Map<Id, Id> cvIdToDocId = new Map<Id, Id>();
      for (ContentVersion cv : [
        SELECT Id, ContentDocumentId
        FROM ContentVersion
        WHERE Id IN (:cv1.Id, :cv2.Id, :cv3.Id, :cv4.Id)
      ]) {
        cvIdToDocId.put(cv.Id, cv.ContentDocumentId);
      }

      String marker1 = '{"$attachmentId":"' + cvIdToDocId.get(cv1.Id) + '"}';
      String marker2 = '{"$attachmentId":"' + cvIdToDocId.get(cv2.Id) + '"}';
      String marker3 = '{"$attachmentId":"' + cvIdToDocId.get(cv3.Id) + '"}';
      String marker4 = '{"$attachmentId":"' + cvIdToDocId.get(cv4.Id) + '"}';

      // Create instance
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'TestDefBulk',
        Status__c = 'Running',
        Correlation_Key__c = 'BulkKey',
        Input__c = marker1,
        Output__c = marker2
      );
      insert inst;

      // Link ContentDocuments to the instance to pass ownership checks
      List<ContentDocumentLink> cdls = new List<ContentDocumentLink>();
      for (Id docId : cvIdToDocId.values()) {
        cdls.add(
          new ContentDocumentLink(
            ContentDocumentId = docId,
            LinkedEntityId = inst.Id,
            ShareType = 'V'
          )
        );
      }
      insert cdls;

      // Create step
      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'BulkStep',
        Status__c = 'Completed',
        Input__c = marker3,
        Output__c = marker4,
        Retry_Count__c = 0
      );
      insert step;

      // Create another step with raw long input (exceeding 50k characters) to test safety truncation
      Workflow_Step_Execution__c stepSafety = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'SafetyStep',
        Status__c = 'Completed',
        Input__c = 'C'.repeat(51000),
        Output__c = 'ShortOutput',
        Retry_Count__c = 0
      );
      insert stepSafety;

      Test.startTest();
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        inst.Id
      );
      Test.stopTest();

      Workflow_Instance__c returnedInst = (Workflow_Instance__c) details.get(
        'instance'
      );
      List<Workflow_Step_Execution__c> returnedSteps = (List<Workflow_Step_Execution__c>) details.get(
        'steps'
      );

      System.assertEquals('{"small":"json"}', returnedInst.Input__c);
      System.assertEquals(
        'A'.repeat(50000) + '... (truncated)',
        returnedInst.Output__c
      );

      // Check steps
      Workflow_Step_Execution__c returnedStep1;
      Workflow_Step_Execution__c returnedStepSafety;
      for (Workflow_Step_Execution__c s : returnedSteps) {
        if (s.Step_Name__c == 'BulkStep') {
          returnedStep1 = s;
        } else if (s.Step_Name__c == 'SafetyStep') {
          returnedStepSafety = s;
        }
      }

      System.assertNotEquals(null, returnedStep1);
      System.assertEquals(
        'B'.repeat(50000) + '... (truncated)',
        returnedStep1.Input__c
      );
      System.assertEquals('{"result":"ok"}', returnedStep1.Output__c);

      System.assertNotEquals(null, returnedStepSafety);
      System.assertEquals(
        'C'.repeat(50000) + '... (truncated)',
        returnedStepSafety.Input__c
      );
      System.assertEquals('ShortOutput', returnedStepSafety.Output__c);

      // Attachment-backed payloads that were truncated should expose a download
      // descriptor; tiny/inline payloads should not.
      Map<String, Object> payloadFiles = (Map<String, Object>) details.get(
        'payloadFiles'
      );
      System.assertNotEquals(
        null,
        payloadFiles,
        'payloadFiles should be present'
      );

      // instance.Output (cv2, 50005 chars) crossed the display limit -> has a file.
      System.assert(
        payloadFiles.containsKey('instance.Output'),
        'Truncated attachment-backed instance Output should have a download file'
      );
      Map<String, Object> outFile = (Map<String, Object>) payloadFiles.get(
        'instance.Output'
      );
      System.assertEquals(50005, (Integer) outFile.get('fullLength'));
      System.assert(
        ((String) outFile.get('downloadUrl'))
          .startsWith('/sfc/servlet.shepherd/document/download/'),
        'downloadUrl should point at the ContentDocument: ' +
        outFile.get('downloadUrl')
      );

      // BulkStep Input (cv3, 60000 chars) crossed the limit -> has a file.
      System.assert(
        payloadFiles.containsKey('step.' + returnedStep1.Id + '.Input'),
        'Truncated attachment-backed step Input should have a download file'
      );

      // Tiny inline payloads (instance Input cv1, BulkStep Output cv4) get no file.
      System.assert(
        !payloadFiles.containsKey('instance.Input'),
        'Small inline instance Input should not have a download file'
      );
      System.assert(
        !payloadFiles.containsKey('step.' + returnedStep1.Id + '.Output'),
        'Small inline step Output should not have a download file'
      );
      // The raw (non-attachment) 51k Safety Input is truncated but has no file to link.
      System.assert(
        !payloadFiles.containsKey('step.' + returnedStepSafety.Id + '.Input'),
        'Non-attachment truncated payload should not have a download file'
      );
    }
  }

  @IsTest
  static void testProgressRehydrationInDetails() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 1. Create a ContentVersion record for offloaded progress
      ContentVersion cv = new ContentVersion(
        Title = 'TestProgressCV',
        PathOnClient = 'progress.json',
        VersionData = Blob.valueOf('P'.repeat(50005))
      );
      insert cv;

      Id docId = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv.Id
      ]
      .ContentDocumentId;
      String offloadedMarker = '{"$attachmentId":"' + docId + '"}';

      // 2. Create one instance with inline progress, and one with offloaded progress
      Workflow_Instance__c instInline = new Workflow_Instance__c(
        Workflow_Name__c = 'TestDefInlineProgress',
        Status__c = 'Running',
        Correlation_Key__c = 'ProgressInlineKey',
        Progress__c = '{"percent":42.0}'
      );
      Workflow_Instance__c instOffloaded = new Workflow_Instance__c(
        Workflow_Name__c = 'TestDefOffloadedProgress',
        Status__c = 'Running',
        Correlation_Key__c = 'ProgressOffloadedKey',
        Progress__c = offloadedMarker
      );
      insert new List<Workflow_Instance__c>{ instInline, instOffloaded };

      ContentDocumentLink cdl = new ContentDocumentLink(
        ContentDocumentId = docId,
        LinkedEntityId = instOffloaded.Id,
        ShareType = 'V'
      );
      insert cdl;

      Test.startTest();
      Map<String, Object> inlineDetails = WorkflowDashboardController.getInstanceDetails(
        instInline.Id
      );
      Map<String, Object> offloadedDetails = WorkflowDashboardController.getInstanceDetails(
        instOffloaded.Id
      );
      Test.stopTest();

      Workflow_Instance__c returnedInline = (Workflow_Instance__c) inlineDetails.get(
        'instance'
      );
      System.assertEquals('{"percent":42.0}', returnedInline.Progress__c);
      Map<String, Object> inlinePayloadFiles = (Map<String, Object>) inlineDetails.get(
        'payloadFiles'
      );
      System.assert(
        !inlinePayloadFiles.containsKey('instance.Progress'),
        'Small inline progress should not have a download file'
      );

      Workflow_Instance__c returnedOffloaded = (Workflow_Instance__c) offloadedDetails.get(
        'instance'
      );
      System.assertEquals(
        'P'.repeat(50000) + '... (truncated)',
        returnedOffloaded.Progress__c
      );
      Map<String, Object> offloadedPayloadFiles = (Map<String, Object>) offloadedDetails.get(
        'payloadFiles'
      );
      System.assert(
        offloadedPayloadFiles.containsKey('instance.Progress'),
        'Truncated offloaded progress should have a download file'
      );
      Map<String, Object> progressFile = (Map<String, Object>) offloadedPayloadFiles.get(
        'instance.Progress'
      );
      System.assertEquals(50005, (Integer) progressFile.get('fullLength'));
      System.assertEquals(docId, (Id) progressFile.get('contentDocumentId'));
    }
  }

  @IsTest
  static void testWatchdogStatusAndEnqueue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Mock the WatchdogWorkflow instance
      Workflow_Instance__c watchdogInst = new Workflow_Instance__c(
        Workflow_Name__c = 'WatchdogWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SystemWatchdog'
      );
      insert watchdogInst;

      Test.startTest();
      Map<String, Object> status = WorkflowDashboardController.getWatchdogStatus();
      WorkflowDashboardController.enqueueWatchdog();
      Test.stopTest();

      System.assertNotEquals(null, status);
      System.assertEquals(true, status.get('isRunning'));
      System.assertNotEquals(null, status.get('latestJob'));
      System.assert(status.containsKey('scheduledJobsCount'));
      System.assert(status.containsKey('sleepingInstances'));
      System.assert(status.containsKey('pendingTimeouts'));
      System.assert(status.containsKey('config'));
      System.assert(status.containsKey('dailyAsyncValue'));
      System.assert(status.containsKey('dailyAsyncLimit'));
      System.assert(status.containsKey('hasElasticLimit'));
      System.assert(status.containsKey('elasticAsyncValue'));
      System.assert(status.containsKey('elasticAsyncLimit'));
    }
  }

  @IsTest
  static void testConcurrencyStatus() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A governed workflow with a durable counter and a parked instance.
      ConcurrencyGate.mockConfigs.put(
        'DashConcWf',
        (Concurrency_Config__mdt) JSON.deserialize(
          '{"DeveloperName":"DashConcWf","Max_Concurrent_Instances__c":5}',
          Concurrency_Config__mdt.class
        )
      );
      insert new Concurrency_State__c(
        Workflow_Definition__c = 'DashConcWf',
        In_Flight_Count__c = 5
      );
      insert new Workflow_Instance__c(
        Workflow_Name__c = 'DashConcWf',
        Status__c = 'Suspended',
        Correlation_Key__c = 'dash-parked-1',
        Concurrency_Parked__c = true
      );

      Test.startTest();
      List<Map<String, Object>> rows = WorkflowDashboardController.getConcurrencyStatus();
      Test.stopTest();

      System.assertEquals(1, rows.size(), 'One governed workflow row expected');
      Map<String, Object> row = rows[0];
      System.assertEquals('DashConcWf', row.get('workflowName'));
      System.assertEquals(
        5,
        row.get('ceiling'),
        'Ceiling surfaced from config'
      );
      System.assertEquals(
        5,
        row.get('inFlight'),
        'In-flight surfaced from counter'
      );
      System.assertEquals(1, row.get('parked'), 'Parked count surfaced');
    }
  }

  @IsTest
  static void testResumeWorkflowAndWaitingOn() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Create a mock suspended instance
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'TestResumeKey',
        Sleep_Until__c = DateTime.now().addMinutes(5),
        Async_Job_Id__c = TestIdFactory.generate(AsyncApexJob.SObjectType)
      );
      insert as system inst;

      // Test getFilteredInstances returns the computed waitingOn
      Test.startTest();
      List<Map<String, Object>> instances = WorkflowDashboardController.getFilteredInstances(
        '',
        'Suspended',
        '',
        10,
        0,
        ''
      );
      System.assertEquals(1, instances.size());
      // Since it's a fake ID and not active, it should fall back to 'Watchdog'
      System.assertEquals('Watchdog', (String) instances[0].get('waitingOn'));

      // Test getInstanceDetails returns details + waitingOn
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        inst.Id
      );
      System.assertNotEquals(null, details);
      System.assertEquals('Watchdog', (String) details.get('waitingOn'));

      // Test resumeWorkflowInstance
      WorkflowDashboardController.resumeWorkflowInstance(inst.Id);
      Test.stopTest();

      // Verify it updated the status and cleared sleep and async job fields
      Workflow_Instance__c updatedInst = [
        SELECT Status__c, Sleep_Until__c, Async_Job_Id__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assert(
        updatedInst.Status__c == 'Running' ||
          updatedInst.Status__c == 'Completed',
        'Expected Status to be Running or Completed but was: ' +
        updatedInst.Status__c
      );
      System.assertEquals(null, updatedInst.Sleep_Until__c);
      System.assertEquals(null, updatedInst.Async_Job_Id__c);
    }
  }

  @IsTest
  static void testFilteredInstancesClamping() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      List<Map<String, Object>> res1 = WorkflowDashboardController.getFilteredInstances(
        '',
        '',
        '',
        -10,
        -5,
        ''
      );
      List<Map<String, Object>> res2 = WorkflowDashboardController.getFilteredInstances(
        '',
        '',
        '',
        500,
        5000,
        ''
      );
      Test.stopTest();
      System.assertNotEquals(null, res1);
      System.assertNotEquals(null, res2);
    }
  }

  @IsTest
  static void testGetDefinitionsFallback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Force the ApexTypeImplementor fallback path (used when the source scan would
      // approach a governor limit) and verify it still discovers top-level and inner-class
      // workflow definitions.
      WorkflowDashboardController.forceDefinitionFallback = true;
      Test.startTest();
      List<String> definitions = WorkflowDashboardController.getDefinitions();
      Test.stopTest();
      WorkflowDashboardController.forceDefinitionFallback = false;

      System.assertNotEquals(
        null,
        definitions,
        'Fallback should return a list'
      );
      System.assert(
        definitions.contains('CleanupWorkflow'),
        'Fallback should find top-level CleanupWorkflow: ' + definitions
      );
      System.assert(
        !definitions.contains('BulkCancelWorkflow'),
        'Fallback should not find BulkCancelWorkflow (system workflow): ' +
        definitions
      );
      System.assert(
        definitions.contains('SagaWorkflowExample.SagaWorkflow'),
        'Fallback should find inner-class SagaWorkflowExample.SagaWorkflow: ' +
        definitions
      );
      // Test workflow definitions must remain excluded in the fallback path too.
      for (String def : definitions) {
        System.assert(
          !def.contains('WorkflowEngineTest'),
          'Test workflow definitions must be excluded: ' + def
        );
      }
    }
  }

  @IsTest
  static void testSubmitApprovalRoleEnforced() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A non-admin user holding Workflow_Admin (so they pass the dashboard gate) but NOT
      // the approval's designated role must be blocked from approving that specific gate.
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      User stdUser = new User(
        Alias = 'apprusr',
        Email = 'appruser@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'Approver',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'stduser_approval_test_' +
          DateTime.now().getTime() +
          '@testorg.com'
      );
      // Isolate setup-object DML (User/PermissionSet/...) in its own context so it does not
      // collide with the non-setup Workflow_Instance__c DML below (MIXED_DML_OPERATION).
      System.runAs(new User(Id = UserInfo.getUserId())) {
        insert stdUser;
        CustomPermission cp = [
          SELECT Id
          FROM CustomPermission
          WHERE DeveloperName = 'Workflow_Admin'
          LIMIT 1
        ];
        PermissionSet ps = new PermissionSet(
          Label = 'Workflow Admin Appr PS',
          Name = 'Workflow_Admin_Appr_PS'
        );
        insert ps;
        insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = cp.Id);
        insert new PermissionSetAssignment(
          AssigneeId = stdUser.Id,
          PermissionSetId = ps.Id
        );
      }

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'RoleApprovalKey',
        Input__c = '"InputData"'
      );
      insert inst;

      // Pending approval gate that requires a custom permission the std user does not hold.
      Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'WorkflowEngineTest.HappyStep1',
        Status__c = 'Pending',
        Retry_Count__c = 0,
        Output__c = JSON.serialize(
          new Map<String, Object>{
            'waitingForApproval' => true,
            'approvalKey' => 'ExpenseApproval',
            'approvalRole' => 'Nonexistent_Finance_Approver_Perm'
          }
        )
      );
      insert step;

      Test.startTest();
      System.runAs(stdUser) {
        Boolean threw = false;
        try {
          WorkflowDashboardController.ApprovalRequest approvalReq = new WorkflowDashboardController.ApprovalRequest();
          approvalReq.instanceId = inst.Id;
          approvalReq.approvalKey = 'ExpenseApproval';
          approvalReq.approved = true;
          approvalReq.comments = 'Approving without the role';
          WorkflowDashboardController.submitApproval(approvalReq);
        } catch (AuraHandledException e) {
          threw = true;
          System.assert(
            e.getMessage().contains('requires') ||
              e.getMessage().contains('Unauthorized') ||
              e.getMessage().contains('Script-thrown exception'),
            e.getMessage()
          );
        }
        System.assert(
          threw,
          'Approver without the designated role must be blocked'
        );
      }
      Test.stopTest();

      // No approval signal should have been recorded.
      System.assertEquals(
        0,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :inst.Id
        ],
        'No signal should be created when the role check fails'
      );
    }
  }

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
        'WorkflowEngineTest.HappyWorkflow',
        'Failed',
        ''
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
      Map<String, Object> outcome = WorkflowDashboardController.redriveMatchingInstances(
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
      Map<String, Object> outcome = WorkflowDashboardController.redriveMatchingInstances(
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
          WorkflowDashboardController.cancelMatchingInstancesWithCompensations(
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
        '',
        'Suspended',
        '',
        10,
        0,
        ''
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
        '',
        'Suspended',
        '',
        10,
        0,
        ''
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
        '',
        'Suspended',
        '',
        10,
        0,
        ''
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
        '',
        'Suspended',
        '',
        10,
        0,
        ''
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
        '',
        '',
        -1,
        10,
        0,
        ''
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
        '',
        '',
        null,
        10,
        0,
        ''
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
        '',
        '',
        -1,
        10,
        0,
        ''
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
        '',
        '',
        -1,
        1,
        0,
        ''
      );
      List<Map<String, Object>> page1 = WorkflowDashboardController.getStalledInstances(
        '',
        '',
        -1,
        1,
        1,
        ''
      );
      List<Map<String, Object>> page2 = WorkflowDashboardController.getStalledInstances(
        '',
        '',
        -1,
        1,
        2,
        ''
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
        '',
        '',
        -1
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
        '',
        'Running',
        '',
        10,
        0,
        ''
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
        '',
        'Completed',
        '',
        10,
        0,
        ''
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
        '',
        'Suspended',
        '',
        10,
        0,
        ''
      );
      WorkflowDashboardController.getStalledInstances('', '', -1, 10, 0, '');
      WorkflowDashboardController.getStalledCount('', '', -1);
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
            '',
            '',
            -1,
            10,
            0,
            ''
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
          WorkflowDashboardController.getStalledCount('', '', -1);
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
        '',
        'Suspended',
        '',
        10,
        0,
        ''
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
        '',
        '',
        -1,
        10,
        0,
        ''
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
        '',
        '',
        -1
      );
      Test.stopTest();

      Integer count = (Integer) result.get('count');
      System.assert(count >= 1, 'At least the true zombie must be counted');
      // Verify the waiting instance's Id is not surfaced by getStalledInstances
      List<Map<String, Object>> stalledList = WorkflowDashboardController.getStalledInstances(
        '',
        '',
        -1,
        50,
        0,
        ''
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

  // ── Version Drain Tests ────────────────────────────────────────────────────

  @IsTest
  static void testGetVersionDrain_perVersionClassification() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String wfName = 'TestVersionDrainWorkflow.Main';

      // v1: 1 non-terminal (Running) + 1 terminal (Completed)
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfName,
        Status__c = 'Running',
        Correlation_Key__c = 'drain-v1-running',
        Definition_Version__c = 1
      );
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfName,
        Status__c = 'Completed',
        Correlation_Key__c = 'drain-v1-done',
        Definition_Version__c = 1
      );

      // v2: all terminal (Completed)
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfName,
        Status__c = 'Completed',
        Correlation_Key__c = 'drain-v2-done',
        Definition_Version__c = 2
      );

      Test.startTest();
      List<Map<String, Object>> rows = WorkflowDashboardController.getVersionDrain(
        wfName
      );
      Test.stopTest();

      System.assertEquals(2, rows.size(), 'Expected exactly 2 version rows');

      Map<String, Object> v1Row = null;
      Map<String, Object> v2Row = null;
      for (Map<String, Object> row : rows) {
        if ((Integer) row.get('version') == 1) {
          v1Row = row;
        } else if ((Integer) row.get('version') == 2) {
          v2Row = row;
        }
      }

      System.assertNotEquals(null, v1Row, 'Expected a row for version 1');
      System.assertEquals(
        1,
        (Integer) v1Row.get('nonTerminalCount'),
        'v1 nonTerminal should be 1'
      );
      System.assertEquals(
        0,
        (Integer) v1Row.get('failedCount'),
        'v1 failed should be 0'
      );
      System.assertEquals(
        1,
        (Integer) v1Row.get('terminalCount'),
        'v1 terminal should be 1'
      );
      System.assertEquals(
        false,
        (Boolean) v1Row.get('safeToRetire'),
        'v1 should NOT be safe'
      );

      System.assertNotEquals(null, v2Row, 'Expected a row for version 2');
      System.assertEquals(
        0,
        (Integer) v2Row.get('nonTerminalCount'),
        'v2 nonTerminal should be 0'
      );
      System.assertEquals(
        0,
        (Integer) v2Row.get('failedCount'),
        'v2 failed should be 0'
      );
      System.assertEquals(
        1,
        (Integer) v2Row.get('terminalCount'),
        'v2 terminal should be 1'
      );
      System.assertEquals(
        true,
        (Boolean) v2Row.get('safeToRetire'),
        'v2 SHOULD be safe'
      );
    }
  }

  @IsTest
  static void testGetVersionDrain_failedCountedSeparatelyAndBlocksRetire() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String wfName = 'TestVersionDrainWorkflow.Failed';

      // v1: only Failed instances — terminal in lifecycle, but re-drivable on this
      // version, so it must be surfaced as failedCount and block safeToRetire.
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfName,
        Status__c = 'Failed',
        Correlation_Key__c = 'drain-failed-v1-a',
        Definition_Version__c = 1
      );
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfName,
        Status__c = 'Failed',
        Correlation_Key__c = 'drain-failed-v1-b',
        Definition_Version__c = 1
      );

      // v2: Failed + Completed — failed and clean-terminal must be in distinct buckets.
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfName,
        Status__c = 'Failed',
        Correlation_Key__c = 'drain-failed-v2',
        Definition_Version__c = 2
      );
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfName,
        Status__c = 'Completed',
        Correlation_Key__c = 'drain-done-v2',
        Definition_Version__c = 2
      );

      Test.startTest();
      List<Map<String, Object>> rows = WorkflowDashboardController.getVersionDrain(
        wfName
      );
      Test.stopTest();

      Map<String, Object> v1Row = null;
      Map<String, Object> v2Row = null;
      for (Map<String, Object> row : rows) {
        if ((Integer) row.get('version') == 1) {
          v1Row = row;
        } else if ((Integer) row.get('version') == 2) {
          v2Row = row;
        }
      }

      System.assertNotEquals(null, v1Row, 'Expected a row for version 1');
      System.assertEquals(
        0,
        (Integer) v1Row.get('nonTerminalCount'),
        'v1 nonTerminal should be 0'
      );
      System.assertEquals(
        2,
        (Integer) v1Row.get('failedCount'),
        'v1 failed should be 2'
      );
      System.assertEquals(
        0,
        (Integer) v1Row.get('terminalCount'),
        'Failed must NOT be counted as clean terminal'
      );
      System.assertEquals(
        2,
        (Integer) v1Row.get('totalCount'),
        'v1 total should be 2'
      );
      System.assertEquals(
        false,
        (Boolean) v1Row.get('safeToRetire'),
        're-drivable failures must block retire'
      );

      System.assertNotEquals(null, v2Row, 'Expected a row for version 2');
      System.assertEquals(
        1,
        (Integer) v2Row.get('failedCount'),
        'v2 failed should be 1'
      );
      System.assertEquals(
        1,
        (Integer) v2Row.get('terminalCount'),
        'v2 clean terminal should be 1'
      );
      System.assertEquals(
        false,
        (Boolean) v2Row.get('safeToRetire'),
        'v2 still has a re-drivable failure'
      );
    }
  }

  @IsTest
  static void testGetVersionDrain_safeOnlyWhenZeroNonTerminal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String wfName = 'TestVersionDrainWorkflow.NonTerminal';
      List<String> nonTerminalStatuses = new List<String>{
        'Pending',
        'Running',
        'Suspended',
        'Compensating',
        'Cancelling',
        'CompensationFailed'
      };

      Integer ver = 10;
      for (String s : nonTerminalStatuses) {
        insert new Workflow_Instance__c(
          Workflow_Name__c = wfName,
          Status__c = s,
          Correlation_Key__c = 'drain-nonterminal-' + s,
          Definition_Version__c = ver
        );
        ver++;
      }

      Test.startTest();
      List<Map<String, Object>> rows = WorkflowDashboardController.getVersionDrain(
        wfName
      );
      Test.stopTest();

      System.assertEquals(
        nonTerminalStatuses.size(),
        rows.size(),
        'Expected one row per non-terminal status version'
      );
      for (Map<String, Object> row : rows) {
        System.assertEquals(
          false,
          (Boolean) row.get('safeToRetire'),
          'Version with a non-terminal instance must NOT be safe to retire: ' +
          row.get('version')
        );
        System.assertEquals(
          1,
          (Integer) row.get('nonTerminalCount'),
          'nonTerminalCount should be 1 for version: ' + row.get('version')
        );
      }
    }
  }

  @IsTest
  static void testGetVersionDrain_scopedByWorkflowName_absenceNotSafe() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String wfX = 'TestVersionDrainWorkflow.X';
      String wfY = 'TestVersionDrainWorkflow.Y';

      // wfX v1 is fully drained
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfX,
        Status__c = 'Completed',
        Correlation_Key__c = 'drain-x-v1',
        Definition_Version__c = 1
      );

      // wfY v1 has a non-terminal — must NOT bleed into wfX results
      insert new Workflow_Instance__c(
        Workflow_Name__c = wfY,
        Status__c = 'Running',
        Correlation_Key__c = 'drain-y-v1',
        Definition_Version__c = 1
      );

      Test.startTest();
      List<Map<String, Object>> rows = WorkflowDashboardController.getVersionDrain(
        wfX
      );
      Test.stopTest();

      // Only wfX instances reported; wfY instances absent from results
      System.assertEquals(
        1,
        rows.size(),
        'Only versions observed under wfX should appear'
      );
      Map<String, Object> row = rows[0];
      System.assertEquals(1, (Integer) row.get('version'));
      System.assertEquals(
        0,
        (Integer) row.get('nonTerminalCount'),
        'wfY running instance must not contaminate wfX count'
      );
      System.assertEquals(
        true,
        (Boolean) row.get('safeToRetire'),
        'wfX v1 should be safe'
      );
    }
  }

  @IsTest
  static void testGetVersionDrain_blankWorkflowName_returnsEmpty() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      List<Map<String, Object>> rows = WorkflowDashboardController.getVersionDrain(
        ''
      );
      Test.stopTest();
      System.assertEquals(
        0,
        rows.size(),
        'Blank workflow name should return empty list'
      );
    }
  }

  @IsTest
  static void testGetVersionDrain_authorizationEnforced() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
      User stdUser = new User(
        Alias = 'drainusr',
        Email = 'drain.user@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'DrainTest',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = p.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'drain_user_' + DateTime.now().getTime() + '@testorg.com'
      );
      insert stdUser;

      System.runAs(stdUser) {
        try {
          WorkflowDashboardController.getVersionDrain('SomeWorkflow.Def');
          System.assert(
            false,
            'Expected AuraHandledException for unauthorized user'
          );
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception'),
            'Exception message should indicate unauthorized access'
          );
        }
      }

    }
  }

  // ── Unrouted-signal dashboard tests ───────────────────────────────────────

  @IsTest
  static void testGetUnroutedSignals_returnsUnroutedRows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Signal__c sig1 = new Workflow_Signal__c(
        Correlation_Key__c = 'Unrouted-Key-1',
        Signal_Name__c = 'PingA',
        Status__c = 'Unrouted'
      );
      Workflow_Signal__c sig2 = new Workflow_Signal__c(
        Correlation_Key__c = 'Unrouted-Key-2',
        Signal_Name__c = 'PingB',
        Status__c = 'Unrouted'
      );
      insert new List<Workflow_Signal__c>{ sig1, sig2 };

      // A Received signal must NOT appear in the unrouted list.
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'Matched-Running-Key'
      );
      insert inst;
      insert new Workflow_Signal__c(
        Correlation_Key__c = 'Matched-Running-Key',
        Workflow_Instance__c = inst.Id,
        Signal_Name__c = 'MatchedSignal',
        Status__c = 'Received'
      );

      Test.startTest();
      List<Map<String, Object>> results = WorkflowDashboardController.getUnroutedSignals(
        null,
        10,
        0,
        ''
      );
      Test.stopTest();

      System.assertEquals(
        2,
        results.size(),
        'Only Unrouted signals must be returned'
      );
      Set<String> returnedKeys = new Set<String>();
      for (Map<String, Object> row : results) {
        returnedKeys.add((String) row.get('correlationKey'));
        System.assertNotEquals(
          null,
          row.get('ageMinutes'),
          'ageMinutes must be populated'
        );
        System.assertNotEquals(null, row.get('signalName'));
      }
      System.assert(returnedKeys.contains('Unrouted-Key-1'));
      System.assert(returnedKeys.contains('Unrouted-Key-2'));
    }
  }

  @IsTest
  static void testGetUnroutedSignalCount_returnsCount() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new List<Workflow_Signal__c>{
        new Workflow_Signal__c(
          Correlation_Key__c = 'Count-Key-1',
          Signal_Name__c = 'S1',
          Status__c = 'Unrouted'
        ),
        new Workflow_Signal__c(
          Correlation_Key__c = 'Count-Key-2',
          Signal_Name__c = 'S2',
          Status__c = 'Unrouted'
        )
      };

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.getUnroutedSignalCount(
        null
      );
      Test.stopTest();

      System.assertEquals(2, (Integer) result.get('count'));
      System.assertEquals(false, (Boolean) result.get('capped'));
    }
  }

  @IsTest
  static void testRedeliverSignal_matchedReturnsTrue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Signal__c sig = new Workflow_Signal__c(
        Correlation_Key__c = 'Dashboard-Redeliver-Key',
        Signal_Name__c = 'Wake',
        Status__c = 'Unrouted'
      );
      insert sig;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'Dashboard-Redeliver-Key'
      );
      insert inst;

      WorkflowEngine.disableQueueableInTest = true;

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.redeliverSignal(
        sig.Id
      );
      Test.stopTest();

      System.assertEquals(
        true,
        (Boolean) result.get('matched'),
        'Re-deliver must return matched=true when instance found'
      );

      Workflow_Signal__c reloaded = [
        SELECT Status__c
        FROM Workflow_Signal__c
        WHERE Id = :sig.Id
      ];
      System.assertEquals(
        'Received',
        reloaded.Status__c,
        'Re-delivered signal must transition to Received'
      );
    }
  }

  @IsTest
  static void testRedeliverSignal_noMatchReturnsFalse() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Signal__c sig = new Workflow_Signal__c(
        Correlation_Key__c = 'Dashboard-NoMatch-Key',
        Signal_Name__c = 'Orphan',
        Status__c = 'Unrouted'
      );
      insert sig;

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.redeliverSignal(
        sig.Id
      );
      Test.stopTest();

      System.assertEquals(
        false,
        (Boolean) result.get('matched'),
        'Re-deliver must return matched=false when no active instance'
      );
    }
  }

  @IsTest
  static void testUnroutedSignalMethods_authorizationEnforced() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
      User stdUser = new User(
        Alias = 'unrtusr',
        Email = 'unrouted.user@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'UnroutedTest',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = p.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'unrouted_user_' + DateTime.now().getTime() + '@testorg.com'
      );
      insert stdUser;

      System.runAs(stdUser) {
        try {
          WorkflowDashboardController.getUnroutedSignals(null, 10, 0, '');
          System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception')
          );
        }
        try {
          WorkflowDashboardController.getUnroutedSignalCount(null);
          System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception')
          );
        }
        try {
          WorkflowDashboardController.redeliverSignal(null);
          System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized') ||
            e.getMessage().contains('Script-thrown exception')
          );
        }
      }

    }
  }

  @IsTest
  static void testGetWorkflowFailureBreakdown_emptyState() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.getWorkflowFailureBreakdown(
        'CleanupWorkflow',
        '24h'
      );
      Test.stopTest();

      System.assertEquals('CleanupWorkflow', result.get('workflowName'));
      System.assertEquals('24h', result.get('timeWindow'));
      System.assertEquals(false, result.get('isCapped'));
      System.assertEquals(0, result.get('totalFailures'));
      List<Object> steps = (List<Object>) result.get('steps');
      System.assertEquals(0, steps.size());
    }
  }

  @IsTest
  static void testGetWorkflowFailureBreakdown_filtersAndGroups() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst1 = new Workflow_Instance__c(
        Workflow_Name__c = 'CleanupWorkflow',
        Status__c = 'Failed'
      );
      insert inst1;

      List<Workflow_Step_Execution__c> stepsToInsert = new List<Workflow_Step_Execution__c>{
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst1.Id,
          Step_Name__c = 'StepOne',
          Status__c = 'Failed',
          Error_Details__c = 'System.NullPointerException: Attempt to de-reference a null object\nClass.MyClass.method: line 10'
        ),
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst1.Id,
          Step_Name__c = 'StepOne',
          Status__c = 'Failed',
          Error_Details__c = 'System.NullPointerException: Attempt to de-reference a null object\nClass.MyClass.method: line 15'
        ),
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst1.Id,
          Step_Name__c = 'StepTwo',
          Status__c = 'Failed',
          Error_Details__c = 'System.DmlException: Insert failed. First exception on row 0; first error: REQUIRED_FIELD_MISSING, Required fields are missing: [Name]: [Name]'
        )
      };
      insert stepsToInsert;

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.getWorkflowFailureBreakdown(
        'CleanupWorkflow',
        '24h'
      );
      Test.stopTest();

      System.assertEquals('CleanupWorkflow', result.get('workflowName'));
      System.assertEquals('24h', result.get('timeWindow'));
      System.assertEquals(3, result.get('totalFailures'));

      List<Object> steps = (List<Object>) result.get('steps');
      System.assertEquals(
        2,
        steps.size(),
        'Should have 2 failing steps grouped'
      );

      Map<String, Object> step1 = (Map<String, Object>) steps[0];
      System.assertEquals('StepOne', step1.get('stepName'));
      System.assertEquals(2, step1.get('failureCount'));

      List<Object> signatures1 = (List<Object>) step1.get('errorSignatures');
      System.assertEquals(
        1,
        signatures1.size(),
        'Should group both NPEs together'
      );
      Map<String, Object> sig1 = (Map<String, Object>) signatures1[0];
      System.assertEquals(
        'System.NullPointerException: Attempt to de-reference a null object',
        sig1.get('signature')
      );
      System.assertEquals(2, sig1.get('count'));

      List<Object> examples1 = (List<Object>) sig1.get('examples');
      System.assertEquals(
        1,
        examples1.size(),
        'Should unique examples by instance'
      );

      Map<String, Object> step2 = (Map<String, Object>) steps[1];
      System.assertEquals('StepTwo', step2.get('stepName'));
      System.assertEquals(1, step2.get('failureCount'));
    }
  }

  @IsTest
  static void testGetWorkflowFailureBreakdown_normalization() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst1 = new Workflow_Instance__c(
        Workflow_Name__c = 'CleanupWorkflow',
        Status__c = 'Failed'
      );
      insert inst1;

      List<Workflow_Step_Execution__c> stepsToInsert = new List<Workflow_Step_Execution__c>{
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst1.Id,
          Step_Name__c = 'NormalizeStep',
          Status__c = 'Failed',
          Error_Details__c = 'Failed to update Account 001DSv00000CFwWKMA at 2026-06-22T20:16:30Z with transaction 3d3b7e41-0f46-4c4f-9e7b-c9e504c5fb43. Retries: 3'
        )
      };
      insert stepsToInsert;

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.getWorkflowFailureBreakdown(
        'CleanupWorkflow',
        'all'
      );
      Test.stopTest();

      List<Object> steps = (List<Object>) result.get('steps');
      Map<String, Object> step = (Map<String, Object>) steps[0];
      List<Object> signatures = (List<Object>) step.get('errorSignatures');
      Map<String, Object> sig = (Map<String, Object>) signatures[0];

      String signature = (String) sig.get('signature');
      System.assert(
        signature.contains('[ID]'),
        'Should contain [ID]: ' + signature
      );
      System.assert(
        signature.contains('[DATETIME]'),
        'Should contain [DATETIME]: ' + signature
      );
      System.assert(
        signature.contains('[UUID]'),
        'Should contain [UUID]: ' + signature
      );
      System.assert(
        signature.contains('[NUM]'),
        'Should contain [NUM]: ' + signature
      );
    }
  }

  @IsTest
  static void testSearchWithSingleQuote() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'O\'Connor.Workflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'O\'ConnorKey',
        Input__c = '"TestInput"'
      );
      insert inst;

      Workflow_Signal__c sig = new Workflow_Signal__c(
        Correlation_Key__c = 'O\'ConnorKey',
        Signal_Name__c = 'O\'ConnorSignal',
        Status__c = 'Unrouted'
      );
      insert sig;

      Test.startTest();
      List<Map<String, Object>> filteredInsts = WorkflowDashboardController.getFilteredInstances(
        '',
        '',
        'O\'Connor',
        10,
        0,
        ''
      );

      List<Map<String, Object>> stalledInsts = WorkflowDashboardController.getStalledInstances(
        '',
        'O\'Connor',
        -1,
        10,
        0,
        ''
      );

      Map<String, Object> stalledCountResult = WorkflowDashboardController.getStalledCount(
        '',
        'O\'Connor',
        -1
      );

      List<Map<String, Object>> unroutedSigs = WorkflowDashboardController.getUnroutedSignals(
        'O\'Connor',
        10,
        0,
        ''
      );

      Map<String, Object> unroutedCountResult = WorkflowDashboardController.getUnroutedSignalCount(
        'O\'Connor'
      );
      Test.stopTest();

      System.assertEquals(
        1,
        filteredInsts.size(),
        'Should find 1 filtered instance'
      );
      System.assertEquals(
        1,
        stalledInsts.size(),
        'Should find 1 stalled instance'
      );
      System.assertEquals(
        1,
        (Integer) stalledCountResult.get('count'),
        'Should count 1 stalled instance'
      );
      System.assertEquals(
        1,
        unroutedSigs.size(),
        'Should find 1 unrouted signal'
      );
      System.assertEquals(
        1,
        (Integer) unroutedCountResult.get('count'),
        'Should count 1 unrouted signal'
      );
    }
  }

  @IsTest
  static void testFailureCategoryFiltering() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> testInstances = new List<Workflow_Instance__c>{
        new Workflow_Instance__c(
          Workflow_Name__c = 'TestDefA',
          Status__c = 'Failed',
          Correlation_Key__c = 'TimeoutKey',
          Failure_Category__c = 'TIMEOUT'
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = 'TestDefA',
          Status__c = 'Failed',
          Correlation_Key__c = 'StepExceptionKey',
          Failure_Category__c = 'STEP_EXCEPTION'
        ),
        new Workflow_Instance__c(
          Workflow_Name__c = 'TestDefB',
          Status__c = 'Failed',
          Correlation_Key__c = 'RetriesExhaustedKey',
          Failure_Category__c = 'RETRIES_EXHAUSTED'
        )
      };
      insert testInstances;

      Test.startTest();
      // Calls the 7-parameter WorkflowDashboardController.getFilteredInstances with failureCategory = 'TIMEOUT'
      List<Map<String, Object>> resCategory = WorkflowDashboardController.getFilteredInstances(
        '',
        'Failed',
        '',
        'TIMEOUT',
        10,
        0,
        'cb'
      );

      // Calls WorkflowDashboardController.getInstanceDetails for the first instance
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        testInstances[0].Id
      );

      // Calls the 6-parameter WorkflowDashboardController.getFilteredInstances with searchTerm = 'StepExceptionKey'
      List<Map<String, Object>> resSearch = WorkflowDashboardController.getFilteredInstances(
        '',
        '',
        'StepExceptionKey',
        10,
        0,
        'cb'
      );
      Test.stopTest();

      // asserts only the matching instance is returned and contains the correct category
      System.assertEquals(
        1,
        resCategory.size(),
        'Should find exactly 1 instance for TIMEOUT category'
      );
      System.assertEquals(
        testInstances[0].Id,
        (Id) resCategory[0].get('Id'),
        'Should return the correct instance'
      );
      System.assertEquals(
        'TIMEOUT',
        (String) resCategory[0].get('Failure_Category__c'),
        'Should contain the correct failure category'
      );

      // asserts Failure_Category__c equals 'TIMEOUT'
      Workflow_Instance__c returnedInst = (Workflow_Instance__c) details.get(
        'instance'
      );
      System.assertNotEquals(
        null,
        returnedInst,
        'Returned instance details should not be null'
      );
      System.assertEquals(
        'TIMEOUT',
        returnedInst.Failure_Category__c,
        'Failure_Category__c should be TIMEOUT'
      );

      // asserts the matching instance is returned
      System.assertEquals(
        1,
        resSearch.size(),
        'Should find exactly 1 instance matching StepExceptionKey searchTerm'
      );
      System.assertEquals(
        testInstances[1].Id,
        (Id) resSearch[0].get('Id'),
        'Should return the correct instance matching search term'
      );
    }
  }

  @IsTest
  static void testCompensateWorkflowInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Create a target Completed workflow instance with compensation stack
      Workflow_Instance__c target = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Completed',
        Compensation_Stack__c = JSON.serialize(
          new List<String>{
            'WorkflowEngineTest.NonCompensatableStep',
            'WorkflowEngineTest.CompensatableHappyStep'
          }
        ),
        Correlation_Key__c = 'TestKey_Comp_Controller',
        Input__c = '{"key": "val"}'
      );
      insert target;

      // Create the original completed step execution for the compensatable step
      Workflow_Step_Execution__c origExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = target.Id,
        Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep',
        Status__c = 'Completed',
        Input__c = '{"stepInput": 1}',
        Output__c = '{"stepOutput": 2}'
      );
      insert origExec;

      Test.startTest();
      Id compensatingId = WorkflowDashboardController.compensateWorkflow(
        target.Id
      );
      Test.stopTest();

      System.assertNotEquals(
        null,
        compensatingId,
        'Compensating run ID should be returned from controller'
      );

      // Verify detail retrieval shows Compensated_By__c
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        target.Id
      );
      Workflow_Instance__c instReload = (Workflow_Instance__c) details.get(
        'instance'
      );
      System.assertEquals(
        compensatingId,
        instReload.Compensated_By__c,
        'getInstanceDetails should return linked Compensated_By__c field'
      );
    }
  }

  @IsTest
  static void testInjectSignalSuccess() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKey1',
        Input__c = '"InputData"',
        Sleep_Until__c = Datetime.now().addDays(1)
      );
      insert inst;

      WorkflowEngine.disableQueueableInTest = true;

      Test.startTest();
      WorkflowDashboardController.injectSignal(
        inst.Id,
        'PaymentReceived',
        '{"amount": 100}'
      );
      Test.stopTest();

      List<Workflow_Signal__c> signals = [
        SELECT Id, Signal_Name__c, Payload__c
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :inst.Id
      ];
      System.assertEquals(1, signals.size());
      System.assertEquals('PaymentReceived', signals[0].Signal_Name__c);
      System.assert(
        signals[0].Payload__c.contains('"amount":100') ||
        signals[0].Payload__c.contains('"amount": 100'),
        'Payload should match'
      );

      // Verify status mutation and sleep until clearing
      Workflow_Instance__c updatedInst = [
        SELECT Status__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id = :inst.Id
      ];
      System.assertEquals(
        'Running',
        updatedInst.Status__c,
        'Instance status should transition to Running after signal injection'
      );
      System.assertEquals(
        null,
        updatedInst.Sleep_Until__c,
        'Sleep_Until__c should be cleared (null) after signal injection'
      );
    }
  }

  @IsTest
  static void testInjectSignalNonSuspendedRejection() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'SignalKey2',
        Input__c = '"InputData"'
      );
      insert inst;

      try {
        WorkflowDashboardController.injectSignal(
          inst.Id,
          'PaymentReceived',
          '{}'
        );
        System.assert(
          false,
          'Should throw exception on non-Suspended instance'
        );
      } catch (AuraHandledException e) {
        System.assert(e.getMessage().contains('Suspended'), e.getMessage());
      }
    }
  }

  @IsTest
  static void testInjectSignalInvalidJsonRejection() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKey3',
        Input__c = '"InputData"'
      );
      insert inst;

      try {
        WorkflowDashboardController.injectSignal(
          inst.Id,
          'PaymentReceived',
          '{invalid}'
        );
        System.assert(false, 'Should throw exception on invalid JSON');
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Invalid payload JSON'),
          e.getMessage()
        );
      }
    }
  }

  @IsTest
  static void testInjectSignalAuthorization() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      User stdUser = new User(
        Alias = 'sigusr',
        Email = 'siguser@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'Signaler',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'stduser_sig_test_' +
          DateTime.now().getTime() +
          '@testorg.com'
      );

      System.runAs(new User(Id = UserInfo.getUserId())) {
        insert stdUser;
        CustomPermission cp = [
          SELECT Id
          FROM CustomPermission
          WHERE DeveloperName = 'Workflow_Admin'
          LIMIT 1
        ];
        PermissionSet ps = new PermissionSet(
          Label = 'Workflow Admin Sig PS',
          Name = 'Workflow_Admin_Sig_PS'
        );
        insert ps;
        insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = cp.Id);
        insert new PermissionSetAssignment(
          AssigneeId = stdUser.Id,
          PermissionSetId = ps.Id
        );
      }

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKey4',
        Input__c = '"InputData"'
      );
      insert inst;

      System.runAs(stdUser) {
        try {
          WorkflowDashboardController.injectSignal(
            inst.Id,
            'PaymentReceived',
            '{}'
          );
          System.assert(
            false,
            'Should be blocked without Workflow_Signal_Injection permission'
          );
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Workflow_Signal_Injection'),
            e.getMessage()
          );
        }
      }

    }
  }

  @IsTest
  static void testInjectSignalAttribution() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKey5',
        Input__c = '"InputData"'
      );
      insert inst;

      WorkflowEngine.disableQueueableInTest = true;

      Test.startTest();
      WorkflowDashboardController.injectSignal(
        inst.Id,
        'PaymentReceived',
        '{}'
      );
      Test.stopTest();

      List<Workflow_Signal__c> signals = [
        SELECT Id, Payload__c
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :inst.Id
      ];
      System.assertEquals(1, signals.size());

      Map<String, Object> payloadMap = (Map<String, Object>) JSON.deserializeUntyped(
        signals[0].Payload__c
      );
      System.assertEquals(
        UserInfo.getUserId(),
        (String) payloadMap.get('operatorId'),
        'operatorId should match running user ID'
      );
      System.assertEquals(
        UserInfo.getUserName(),
        (String) payloadMap.get('operatorUsername'),
        'operatorUsername should match running user username'
      );
      System.assertEquals(
        UserInfo.getName(),
        (String) payloadMap.get('operator'),
        'operator should match running user display name'
      );
    }
  }

  @IsTest
  static void testInjectSignalNullInstanceRejection() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      try {
        WorkflowDashboardController.injectSignal(null, 'PaymentReceived', '{}');
        System.assert(false, 'Should throw exception on null instance ID');
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Workflow instance not found') ||
          e.getMessage().contains('Instance ID is required'),
          'Exception message should contain relevant validation error, but was: ' +
          e.getMessage()
        );
      }
    }
  }

  @IsTest
  static void testInjectSignalBlankSignalNameRejection() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKeyBlankSig',
        Input__c = '"InputData"'
      );
      insert inst;

      try {
        WorkflowDashboardController.injectSignal(inst.Id, ' ', '{}');
        System.assert(false, 'Should throw exception on blank signal name');
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Signal name is required.'),
          e.getMessage()
        );
      }
    }
  }

  @IsTest
  static void testInjectSignalNoDashboardAccess() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      User stdUser = new User(
        Alias = 'signo',
        Email = 'signouser@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'SignalerNo',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'stduser_signo_test_' +
          DateTime.now().getTime() +
          '@testorg.com'
      );
      insert stdUser;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKey7',
        Input__c = '"InputData"'
      );
      insert inst;

      System.runAs(stdUser) {
        try {
          WorkflowDashboardController.injectSignal(
            inst.Id,
            'PaymentReceived',
            '{}'
          );
          System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage()
              .contains(
                'Unauthorized: Access to the Workflow Dashboard is restricted.'
              ),
            e.getMessage()
          );
        }
      }

    }
  }

  @IsTest
  static void testInjectSignalAuthorizationSuccess() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      User stdUser = new User(
        Alias = 'sigok',
        Email = 'sigokuser@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'SignalerOk',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'stduser_sigok_test_' +
          DateTime.now().getTime() +
          '@testorg.com'
      );

      System.runAs(new User(Id = UserInfo.getUserId())) {
        insert stdUser;

        CustomPermission cpAdmin = [
          SELECT Id
          FROM CustomPermission
          WHERE DeveloperName = 'Workflow_Admin'
          LIMIT 1
        ];
        CustomPermission cpInject = [
          SELECT Id
          FROM CustomPermission
          WHERE DeveloperName = 'Workflow_Signal_Injection'
          LIMIT 1
        ];

        PermissionSet ps = new PermissionSet(
          Label = 'Workflow Admin and Inject PS',
          Name = 'Workflow_Admin_Inject_PS'
        );
        insert ps;

        insert new List<SetupEntityAccess>{
          new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = cpAdmin.Id),
          new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = cpInject.Id)
        };
        insert new PermissionSetAssignment(
          AssigneeId = stdUser.Id,
          PermissionSetId = ps.Id
        );
      }

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKey6',
        Input__c = '"InputData"'
      );
      insert inst;

      WorkflowEngine.disableQueueableInTest = true;

      System.runAs(stdUser) {
        Test.startTest();
        WorkflowDashboardController.injectSignal(
          inst.Id,
          'PaymentReceived',
          '{}'
        );
        Test.stopTest();
      }

      List<Workflow_Signal__c> signals = [
        SELECT Id, Signal_Name__c, Payload__c
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :inst.Id
      ];
      System.assertEquals(
        1,
        signals.size(),
        'Should have inserted one signal record'
      );
    }
  }

  @IsTest
  static void testInjectSignalExceptionMapping() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKeyException',
        Input__c = '"InputData"'
      );
      insert inst;

      // Use a signal name that is too long (length > 255) to trigger a DmlException inside WorkflowEngine.signal
      String longSignalName = 'A'.repeat(300);

      try {
        WorkflowDashboardController.injectSignal(inst.Id, longSignalName, '{}');
        System.assert(
          false,
          'Should have thrown AuraHandledException due to DmlException mapping'
        );
      } catch (AuraHandledException e) {
        System.assertNotEquals(
          null,
          e.getMessage(),
          'Exception message should not be null'
        );
      }
    }
  }

  @IsTest
  static void testInjectSignalOversizedPayloadRejection() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Suspended',
        Correlation_Key__c = 'SignalKeyOversized',
        Input__c = '"InputData"'
      );
      insert inst;

      String oversizedString = 'A'.repeat(250001);

      try {
        WorkflowDashboardController.injectSignal(
          inst.Id,
          'PaymentReceived',
          oversizedString
        );
        System.assert(
          false,
          'Should have thrown AuraHandledException due to oversized payload'
        );
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Payload size exceeds maximum'),
          'Exception message should indicate payload size limit: ' +
          e.getMessage()
        );
      }
    }
  }

  @IsTest
  static void testResumePastStepControllerAuthorization() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile stdProfile = [
        SELECT Id
        FROM Profile
        WHERE Name = 'Standard User'
        LIMIT 1
      ];
      User stdUser = new User(
        Alias = 'stdno',
        Email = 'stdno@testorg.com',
        EmailEncodingKey = 'UTF-8',
        LastName = 'NoAdmin',
        LanguageLocaleKey = 'en_US',
        LocaleSidKey = 'en_US',
        ProfileId = stdProfile.Id,
        TimeZoneSidKey = 'America/Los_Angeles',
        UserName = 'stduser_noadmin_test_' +
          DateTime.now().getTime() +
          '@testorg.com'
      );
      insert stdUser;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Failed',
        Correlation_Key__c = 'SkipKeyAuth'
      );
      insert inst;

      System.runAs(stdUser) {
        try {
          WorkflowDashboardController.resumePastStepInstance(
            inst.Id,
            'StepOne',
            '{}'
          );
          System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized'),
            e.getMessage()
          );
        }
      }

    }
  }

  @IsTest
  static void testResumePastStepControllerRejections() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'SkipKeyRej'
      );
      insert inst;

      // Test: invalid status
      try {
        WorkflowDashboardController.resumePastStepInstance(
          inst.Id,
          'StepOne',
          '{}'
        );
        System.assert(false, 'Should fail for non-failed instance');
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Resume past step is only allowed'),
          e.getMessage()
        );
      }

      // Test: null instance
      try {
        WorkflowDashboardController.resumePastStepInstance(
          null,
          'StepOne',
          '{}'
        );
        System.assert(false, 'Should fail for null instance');
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Instance ID is required'),
          e.getMessage()
        );
      }

      // Test: blank step name
      try {
        WorkflowDashboardController.resumePastStepInstance(inst.Id, ' ', '{}');
        System.assert(false, 'Should fail for blank step name');
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('Step name is required'),
          e.getMessage()
        );
      }

      // Test: malformed JSON
      inst.Status__c = 'Failed';
      update as system inst;

      // We also need a mock step execution to test invalid step/JSON:
      Workflow_Step_Execution__c se = new Workflow_Step_Execution__c(
        Workflow_Instance__c = inst.Id,
        Step_Name__c = 'StepOne',
        Status__c = 'Failed'
      );
      insert as system se;

      inst.Current_Step__c = 'StepOne';
      update as system inst;

      try {
        WorkflowDashboardController.resumePastStepInstance(
          inst.Id,
          'StepOne',
          '{invalid_json}'
        );
        System.assert(false, 'Should fail on invalid JSON');
      } catch (AuraHandledException e) {
        System.assert(e.getMessage().contains('valid JSON'), e.getMessage());
      }

      // Test: oversized payload
      try {
        WorkflowDashboardController.resumePastStepInstance(
          inst.Id,
          'StepOne',
          'A'.repeat(250001)
        );
        System.assert(false, 'Should fail on oversized payload');
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage().contains('exceeds maximum allowed limit'),
          e.getMessage()
        );
      }

      // Test: CompensationFailed status (should fail, as there is resumeCompensation)
      inst.Status__c = 'CompensationFailed';
      update as system inst;
      try {
        WorkflowDashboardController.resumePastStepInstance(
          inst.Id,
          'StepOne',
          '{}'
        );
        System.assert(false, 'Should fail for CompensationFailed instance');
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage()
            .contains(
              'Resume past step is only allowed for instances in Failed state'
            ),
          e.getMessage()
        );
      }

      // Test: Reject reserved $attachmentId marker
      inst.Status__c = 'Failed';
      update as system inst;
      try {
        WorkflowDashboardController.resumePastStepInstance(
          inst.Id,
          'StepOne',
          '{"$attachmentId":"069Sv00000KaTSzKAN"}'
        );
        System.assert(false, 'Should fail on reserved $attachmentId marker');
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage()
            .contains('cannot contain reserved "$attachmentId" markers'),
          e.getMessage()
        );
      }

      // Test: Reject skipping a step that is not Failed (e.g. Pending)
      se.Status__c = 'Pending';
      update as system se;
      try {
        WorkflowDashboardController.resumePastStepInstance(
          inst.Id,
          'StepOne',
          '{}'
        );
        System.assert(false, 'Should fail for non-failed step execution');
      } catch (AuraHandledException e) {
        System.assert(
          e.getMessage()
            .contains('cannot be skipped because it is not in Failed status'),
          e.getMessage()
        );
      }
    }
  }

  @IsTest
  static void testGetInstanceDetailsIncludesBreadcrumbs() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Running'
      );
      insert inst;

      Datetime now = Datetime.now();

      List<Workflow_Log__c> logs = new List<Workflow_Log__c>{
        new Workflow_Log__c(
          Workflow_Instance__c = inst.Id,
          Workflow_Name__c = inst.Workflow_Name__c,
          Log_Type__c = StepContext.LOG_TYPE_BREADCRUMB,
          Level__c = 'INFO',
          Message__c = 'Second Breadcrumb',
          Fire_Time__c = now.addSeconds(10)
        ),
        new Workflow_Log__c(
          Workflow_Instance__c = inst.Id,
          Workflow_Name__c = inst.Workflow_Name__c,
          Log_Type__c = StepContext.LOG_TYPE_BREADCRUMB,
          Level__c = 'INFO',
          Message__c = 'First Breadcrumb',
          Fire_Time__c = now
        ),
        new Workflow_Log__c(
          Workflow_Instance__c = inst.Id,
          Workflow_Name__c = inst.Workflow_Name__c,
          Log_Type__c = 'SomeOtherType', // should not be returned
          Level__c = 'INFO',
          Message__c = 'Not a breadcrumb',
          Fire_Time__c = now.addSeconds(5)
        )
      };
      insert logs;

      Test.startTest();
      Map<String, Object> result = WorkflowDashboardController.getInstanceDetails(
        inst.Id
      );
      Test.stopTest();

      System.assertNotEquals(null, result, 'Result should not be null');
      System.assert(
        result.containsKey('breadcrumbs'),
        'Result should contain breadcrumbs key'
      );

      List<Workflow_Log__c> breadcrumbs = (List<Workflow_Log__c>) result.get(
        'breadcrumbs'
      );
      System.assertEquals(
        2,
        breadcrumbs.size(),
        'Should only return StepBreadcrumb logs'
      );
      System.assertEquals(
        'First Breadcrumb',
        breadcrumbs[0].Message__c,
        'Chronological ordering by Fire_Time__c ASC failed'
      );
      System.assertEquals(
        'Second Breadcrumb',
        breadcrumbs[1].Message__c,
        'Chronological ordering by Fire_Time__c ASC failed'
      );
    }
  }
}
