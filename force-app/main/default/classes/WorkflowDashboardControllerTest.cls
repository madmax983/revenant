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
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', '', '')
          .page(10, 0, '')
          .build()
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

  /**
   * Seeds three Workflow_Instance__c records with distinct statuses (Completed,
   * Failed, Running) across TestDefA/TestDefB. Shared fixture for the
   * filtered-instances and workflow-stats tests.
   */
  private static void seedMixedStatusInstances() {
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
  }

  @IsTest
  static void testGetFilteredInstances() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Create 3 instances with distinct details
      seedMixedStatusInstances();

      Test.startTest();
      // 1. Test filtering by Workflow Name
      List<Map<String, Object>> resWorkflow = WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('TestDefA', '', '')
          .page(10, 0, 'cb1')
          .build()
      );
      System.assertEquals(
        2,
        resWorkflow.size(),
        'Should find 2 instances with definition TestDefA'
      );

      // 2. Test filtering by Status
      List<Map<String, Object>> resStatus = WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', 'Running', '')
          .page(10, 0, 'cb2')
          .build()
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
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', '', 'Banana')
          .page(10, 0, 'cb3')
          .build()
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
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', '', 'banana')
          .page(10, 0, 'cb4')
          .build()
      );
      System.assertEquals(
        1,
        resSearchError.size(),
        'Search term search should be case-insensitive'
      );

      // 5. Test pagination: limit and offset
      List<Map<String, Object>> page1 = WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', '', '')
          .page(2, 0, 'cb5')
          .build()
      );
      System.assertEquals(
        2,
        page1.size(),
        'Page 1 limit 2 should return 2 records'
      );

      List<Map<String, Object>> page2 = WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', '', '')
          .page(2, 2, 'cb6')
          .build()
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
      seedMixedStatusInstances();

      Test.startTest();
      // 1. Get stats overall (no filters)
      Map<String, Integer> statsAll = WorkflowDashboardController.getWorkflowStats(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', '', '')
          .build()
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
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('TestDefA', '', '')
          .build()
      );
      System.assertEquals(2, statsDefA.get('total'));
      System.assertEquals(0, statsDefA.get('active'));
      System.assertEquals(1, statsDefA.get('completed'));
      System.assertEquals(1, statsDefA.get('failed'));

      // 3. Get stats filtered by search term
      Map<String, Integer> statsSearch = WorkflowDashboardController.getWorkflowStats(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter('', '', 'Banana')
          .build()
      );
      System.assertEquals(1, statsSearch.get('total'));
      System.assertEquals(1, statsSearch.get('failed'));
      Test.stopTest();
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // getDefinitionTrends — per-definition success-rate & throughput (Issue #33)
  // ──────────────────────────────────────────────────────────────────────────

  /**
   * @description Returns the row Map for the given workflow name from a getDefinitionTrends result.
   * @param trends The getDefinitionTrends result whose 'rows' list is scanned.
   * @param workflowName The workflow name to match.
   * @return The matching row Map, or null if no row matches the name.
   */
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
}
