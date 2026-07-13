@IsTest
public class WorkflowSearchAttributesDashboardTest {
  @IsTest
  static void testGetInstanceDetailsAttributes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = WorkflowEngine.start(
        new WorkflowEngine.StartRequest(
            'StepContextSignalEngineTest.PlainWaitWorkflow',
            'CK_DET_1',
            null
          )
          .withAttributes(
            new Map<String, String>{ 'region' => 'EU', 'tier' => 'enterprise' }
          )
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
        new WorkflowEngine.StartRequest(
            'StepContextSignalEngineTest.PlainWaitWorkflow',
            'CK_FILT_1',
            null
          )
          .withAttributes(
            new Map<String, String>{ 'region' => 'EU', 'tier' => 'enterprise' }
          )
      );

      WorkflowEngine.start(
        new WorkflowEngine.StartRequest(
            'StepContextSignalEngineTest.PlainWaitWorkflow',
            'CK_FILT_2',
            null
          )
          .withAttributes(
            new Map<String, String>{ 'region' => 'US', 'tier' => 'enterprise' }
          )
      );

      Id instId3 = WorkflowEngine.start(
        new WorkflowEngine.StartRequest(
            'StepContextSignalEngineTest.PlainWaitWorkflow',
            'CK_FILT_3',
            null
          )
          .withAttributes(
            new Map<String, String>{ 'region' => 'EU', 'tier' => 'standard' }
          )
      );

      Test.startTest();
      // 1. Filter by region=EU
      List<Map<String, Object>> res1 = WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter(null, null, null)
          .page(10, 0, null)
          .attributesFilter('{"region":"EU"}')
          .build()
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
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter(null, null, null)
          .page(10, 0, null)
          .attributesFilter('{"region":"EU","tier":"enterprise"}')
          .build()
      );
      System.assertEquals(
        1,
        res2.size(),
        'Should find 1 instance for region=EU AND tier=enterprise'
      );
      System.assertEquals(instId1, (Id) res2[0].get('Id'));

      // 3. Filter by non-existent key
      List<Map<String, Object>> res3 = WorkflowDashboardController.getFilteredInstances(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter(null, null, null)
          .page(10, 0, null)
          .attributesFilter('{"nonexistent":"val"}')
          .build()
      );
      System.assertEquals(0, res3.size(), 'Should find 0 instances');

      // 4. Test stats filter
      Map<String, Integer> stats = WorkflowDashboardController.getWorkflowStats(
        WorkflowDashboardQueryBuilders.instanceQuery()
          .filter(null, null, null)
          .attributesFilter('{"region":"EU","tier":"enterprise"}')
          .build()
      );
      System.assertEquals(1, stats.get('total'), 'Stats total should be 1');
      Test.stopTest();
    }
  }

  @IsTest
  static void testGetStalledInstancesByAttributes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instId = WorkflowEngine.start(
        new WorkflowEngine.StartRequest(
            'StepContextSignalEngineTest.PlainWaitWorkflow',
            'CK_STALL_1',
            null
          )
          .withAttributes(new Map<String, String>{ 'region' => 'EU' })
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
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria(null, null, -1)
          .page(10, 0, null)
          .attributesFilter('{"region":"EU"}')
          .build()
      );
      System.assertEquals(
        1,
        stalledList1.size(),
        'Should find 1 stalled instance'
      );
      System.assertEquals(instId, (Id) stalledList1[0].get('Id'));

      // 2. Get stalled count with matching filter region=EU
      Map<String, Object> countRes1 = WorkflowDashboardController.getStalledCount(
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria(null, null, -1)
          .attributesFilter('{"region":"EU"}')
          .build()
      );
      System.assertEquals(1, countRes1.get('count'), 'Count should be 1');

      // 3. Get stalled list with mismatching filter region=US
      List<Map<String, Object>> stalledList2 = WorkflowDashboardController.getStalledInstances(
        WorkflowDashboardQueryBuilders.stalledQuery()
          .criteria(null, null, -1)
          .page(10, 0, null)
          .attributesFilter('{"region":"US"}')
          .build()
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
