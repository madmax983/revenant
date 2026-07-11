@IsTest
public class WorkflowSearchAttributesDashboardTest {
  // Query-wrapper builders: assemble the WorkflowDashboardController read-method request
  // objects by field assignment (a 1:1 repackaging of the former positional arguments).
  private static WorkflowDashboardController.InstanceQuery iqOf(
    String workflowName,
    String status,
    String searchTerm,
    String failureCategory,
    Integer limitSize,
    Integer offsetSize,
    String cacheBuster,
    String attributesFilterJson
  ) {
    WorkflowDashboardController.InstanceQuery q = new WorkflowDashboardController.InstanceQuery();
    q.workflowName = workflowName;
    q.status = status;
    q.searchTerm = searchTerm;
    q.failureCategory = failureCategory;
    q.limitSize = limitSize;
    q.offsetSize = offsetSize;
    q.cacheBuster = cacheBuster;
    q.attributesFilterJson = attributesFilterJson;
    return q;
  }

  private static WorkflowDashboardController.InstanceQuery sqOf(
    String workflowName,
    String status,
    String searchTerm,
    String attributesFilterJson
  ) {
    WorkflowDashboardController.InstanceQuery q = new WorkflowDashboardController.InstanceQuery();
    q.workflowName = workflowName;
    q.status = status;
    q.searchTerm = searchTerm;
    q.attributesFilterJson = attributesFilterJson;
    return q;
  }

  private static WorkflowDashboardController.StalledQuery stalledOf(
    String workflowName,
    String searchTerm,
    Integer thresholdMinutes,
    Integer limitSize,
    Integer offsetSize,
    String cacheBuster,
    String attributesFilterJson
  ) {
    WorkflowDashboardController.StalledQuery q = new WorkflowDashboardController.StalledQuery();
    q.workflowName = workflowName;
    q.searchTerm = searchTerm;
    q.thresholdMinutes = thresholdMinutes;
    q.limitSize = limitSize;
    q.offsetSize = offsetSize;
    q.cacheBuster = cacheBuster;
    q.attributesFilterJson = attributesFilterJson;
    return q;
  }

  private static WorkflowDashboardController.StalledQuery countOf(
    String workflowName,
    String searchTerm,
    Integer thresholdMinutes,
    String attributesFilterJson
  ) {
    WorkflowDashboardController.StalledQuery q = new WorkflowDashboardController.StalledQuery();
    q.workflowName = workflowName;
    q.searchTerm = searchTerm;
    q.thresholdMinutes = thresholdMinutes;
    q.attributesFilterJson = attributesFilterJson;
    return q;
  }

  @IsTest
  static void testGetInstanceDetailsAttributes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = WorkflowEngine.start(
        'StepContextSignalEngineTest.PlainWaitWorkflow',
        'CK_DET_1',
        null,
        new Map<String, String>{ 'region' => 'EU', 'tier' => 'enterprise' }
      );

      Test.startTest();
      Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
        instanceId
      );
      Test.stopTest();

      System.assertNotEquals(
        null,
        details.get('attributes'),
        'details map should contain attributes'
      );
      List<Workflow_Search_Attribute__c> attrs = (List<Workflow_Search_Attribute__c>) details.get(
        'attributes'
      );
      System.assertEquals(2, attrs.size());
      System.assertEquals('region', attrs[0].Key__c);
      System.assertEquals('EU', attrs[0].Value__c);
      System.assertEquals('tier', attrs[1].Key__c);
      System.assertEquals('enterprise', attrs[1].Value__c);
    }
  }

  @IsTest
  static void testGetFilteredInstancesByAttributes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instId1 = WorkflowEngine.start(
        'StepContextSignalEngineTest.PlainWaitWorkflow',
        'CK_FILT_1',
        null,
        new Map<String, String>{ 'region' => 'EU', 'tier' => 'enterprise' }
      );

      WorkflowEngine.start(
        'StepContextSignalEngineTest.PlainWaitWorkflow',
        'CK_FILT_2',
        null,
        new Map<String, String>{ 'region' => 'US', 'tier' => 'enterprise' }
      );

      Id instId3 = WorkflowEngine.start(
        'StepContextSignalEngineTest.PlainWaitWorkflow',
        'CK_FILT_3',
        null,
        new Map<String, String>{ 'region' => 'EU', 'tier' => 'standard' }
      );

      Test.startTest();
      // 1. Filter by region=EU
      List<Map<String, Object>> res1 = WorkflowDashboardController.getFilteredInstances(
        iqOf(null, null, null, null, 10, 0, null, '{"region":"EU"}')
      );
      System.assertEquals(
        2,
        res1.size(),
        'Should find 2 instances for region=EU'
      );
      Set<Id> ids1 = new Set<Id>{
        (Id) res1[0].get('Id'),
        (Id) res1[1].get('Id')
      };
      System.assert(ids1.contains(instId1));
      System.assert(ids1.contains(instId3));

      // 2. Filter by region=EU AND tier=enterprise (AND combination)
      List<Map<String, Object>> res2 = WorkflowDashboardController.getFilteredInstances(
        iqOf(
          null,
          null,
          null,
          null,
          10,
          0,
          null,
          '{"region":"EU","tier":"enterprise"}'
        )
      );
      System.assertEquals(
        1,
        res2.size(),
        'Should find 1 instance for region=EU AND tier=enterprise'
      );
      System.assertEquals(instId1, (Id) res2[0].get('Id'));

      // 3. Filter by non-existent key
      List<Map<String, Object>> res3 = WorkflowDashboardController.getFilteredInstances(
        iqOf(null, null, null, null, 10, 0, null, '{"nonexistent":"val"}')
      );
      System.assertEquals(0, res3.size(), 'Should find 0 instances');

      // 4. Test stats filter
      Map<String, Integer> stats = WorkflowDashboardController.getWorkflowStats(
        sqOf(null, null, null, '{"region":"EU","tier":"enterprise"}')
      );
      System.assertEquals(1, stats.get('total'), 'Stats total should be 1');
      Test.stopTest();
    }
  }

  @IsTest
  static void testGetStalledInstancesByAttributes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instId = WorkflowEngine.start(
        'StepContextSignalEngineTest.PlainWaitWorkflow',
        'CK_STALL_1',
        null,
        new Map<String, String>{ 'region' => 'EU' }
      );

      // Force status to Suspended and delete any pending step executions so it is considered stalled
      delete [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instId
      ];
      Workflow_Instance__c inst = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Id = :instId
      ];
      inst.Status__c = 'Suspended';
      update inst;

      Test.startTest();
      // 1. Get stalled list with matching filter region=EU
      List<Map<String, Object>> stalledList1 = WorkflowDashboardController.getStalledInstances(
        stalledOf(null, null, -1, 10, 0, null, '{"region":"EU"}')
      );
      System.assertEquals(
        1,
        stalledList1.size(),
        'Should find 1 stalled instance'
      );
      System.assertEquals(instId, (Id) stalledList1[0].get('Id'));

      // 2. Get stalled count with matching filter region=EU
      Map<String, Object> countRes1 = WorkflowDashboardController.getStalledCount(
        countOf(null, null, -1, '{"region":"EU"}')
      );
      System.assertEquals(1, countRes1.get('count'), 'Count should be 1');

      // 3. Get stalled list with mismatching filter region=US
      List<Map<String, Object>> stalledList2 = WorkflowDashboardController.getStalledInstances(
        stalledOf(null, null, -1, 10, 0, null, '{"region":"US"}')
      );
      System.assertEquals(
        0,
        stalledList2.size(),
        'Should find 0 stalled instances'
      );
      Test.stopTest();
    }
  }
}
