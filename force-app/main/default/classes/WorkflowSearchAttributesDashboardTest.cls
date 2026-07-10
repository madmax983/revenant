@IsTest
public class WorkflowSearchAttributesDashboardTest {
  @IsTest
  static void testGetInstanceDetailsAttributes() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.PlainWaitWorkflow',
      'CK_DET_1',
      null,
      new Map<String, String>{
        'region' => 'EU',
        'tier' => 'enterprise'
      }
    );

    Test.startTest();
    Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(instanceId);
    Test.stopTest();

    System.assertNotEquals(null, details.get('attributes'), 'details map should contain attributes');
    List<Workflow_Search_Attribute__c> attrs = (List<Workflow_Search_Attribute__c>) details.get('attributes');
    System.assertEquals(2, attrs.size());
    System.assertEquals('region', attrs[0].Key__c);
    System.assertEquals('EU', attrs[0].Value__c);
    System.assertEquals('tier', attrs[1].Key__c);
    System.assertEquals('enterprise', attrs[1].Value__c);
  }

  @IsTest
  static void testGetFilteredInstancesByAttributes() {
    Id instId1 = WorkflowEngine.start(
      'StepContextSignalEngineTest.PlainWaitWorkflow',
      'CK_FILT_1',
      null,
      new Map<String, String>{
        'region' => 'EU',
        'tier' => 'enterprise'
      }
    );

    Id instId2 = WorkflowEngine.start(
      'StepContextSignalEngineTest.PlainWaitWorkflow',
      'CK_FILT_2',
      null,
      new Map<String, String>{
        'region' => 'US',
        'tier' => 'enterprise'
      }
    );

    Id instId3 = WorkflowEngine.start(
      'StepContextSignalEngineTest.PlainWaitWorkflow',
      'CK_FILT_3',
      null,
      new Map<String, String>{
        'region' => 'EU',
        'tier' => 'standard'
      }
    );

    Test.startTest();
    // 1. Filter by region=EU
    List<Map<String, Object>> res1 = WorkflowDashboardController.getFilteredInstances(
      null, null, null, null, 10, 0, null, '{"region":"EU"}'
    );
    System.assertEquals(2, res1.size(), 'Should find 2 instances for region=EU');
    Set<Id> ids1 = new Set<Id>{ (Id) res1[0].get('Id'), (Id) res1[1].get('Id') };
    System.assert(ids1.contains(instId1));
    System.assert(ids1.contains(instId3));

    // 2. Filter by region=EU AND tier=enterprise (AND combination)
    List<Map<String, Object>> res2 = WorkflowDashboardController.getFilteredInstances(
      null, null, null, null, 10, 0, null, '{"region":"EU","tier":"enterprise"}'
    );
    System.assertEquals(1, res2.size(), 'Should find 1 instance for region=EU AND tier=enterprise');
    System.assertEquals(instId1, (Id) res2[0].get('Id'));

    // 3. Filter by non-existent key
    List<Map<String, Object>> res3 = WorkflowDashboardController.getFilteredInstances(
      null, null, null, null, 10, 0, null, '{"nonexistent":"val"}'
    );
    System.assertEquals(0, res3.size(), 'Should find 0 instances');

    // 4. Test stats filter
    Map<String, Integer> stats = WorkflowDashboardController.getWorkflowStats(
      null, null, null, '{"region":"EU","tier":"enterprise"}'
    );
    System.assertEquals(1, stats.get('total'), 'Stats total should be 1');
    Test.stopTest();
  }

  @IsTest
  static void testGetStalledInstancesByAttributes() {
    Id instId = WorkflowEngine.start(
      'StepContextSignalEngineTest.PlainWaitWorkflow',
      'CK_STALL_1',
      null,
      new Map<String, String>{ 'region' => 'EU' }
    );

    // Force status to Suspended and delete any pending step executions so it is considered stalled
    delete [SELECT Id FROM Workflow_Step_Execution__c WHERE Workflow_Instance__c = :instId];
    Workflow_Instance__c inst = [SELECT Id FROM Workflow_Instance__c WHERE Id = :instId];
    inst.Status__c = 'Suspended';
    update inst;

    Test.startTest();
    // 1. Get stalled list with matching filter region=EU
    List<Map<String, Object>> stalledList1 = WorkflowDashboardController.getStalledInstances(
      null, null, -1, 10, 0, null, '{"region":"EU"}'
    );
    System.assertEquals(1, stalledList1.size(), 'Should find 1 stalled instance');
    System.assertEquals(instId, (Id) stalledList1[0].get('Id'));

    // 2. Get stalled count with matching filter region=EU
    Map<String, Object> countRes1 = WorkflowDashboardController.getStalledCount(
      null, null, -1, '{"region":"EU"}'
    );
    System.assertEquals(1, countRes1.get('count'), 'Count should be 1');

    // 3. Get stalled list with mismatching filter region=US
    List<Map<String, Object>> stalledList2 = WorkflowDashboardController.getStalledInstances(
      null, null, -1, 10, 0, null, '{"region":"US"}'
    );
    System.assertEquals(0, stalledList2.size(), 'Should find 0 stalled instances');
    Test.stopTest();
  }
}
