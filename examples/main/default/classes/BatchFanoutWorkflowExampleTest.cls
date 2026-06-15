@isTest
public class BatchFanoutWorkflowExampleTest {
  @isTest
  static void testBatchFanoutWorkflowSuccess() {
    List<Account> testAccs = new List<Account>{
      new Account(Name = 'Acme Corp'),
      new Account(Name = 'Stark Industries'),
      new Account(Name = 'Wayne Enterprises')
    };
    insert testAccs;

    Test.startTest();
    Id parentId = WorkflowEngine.start(
      'BatchFanoutWorkflowExample.BatchFanoutWorkflow',
      'ParentKey',
      null
    );
    WorkflowTestHarness.Result result = new WorkflowTestHarness(parentId).drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);

    Map<String, Object> outputMap = (Map<String, Object>) JSON.deserializeUntyped(
      result.output
    );
    System.assertEquals(3, outputMap.get('totalProcessed'));
    System.assertEquals('Batch completed successfully', outputMap.get('status'));

    Map<String, Object> details = (Map<String, Object>) outputMap.get('details');
    System.assertEquals(3, details.size());

    String child1Key = 'Process_' + testAccs[0].Id + '_' + parentId;
    Map<String, Object> child1 = (Map<String, Object>) details.get(child1Key);
    System.assertEquals('Audited & Updated', child1.get('status'));
    System.assertEquals('Acme Corp', child1.get('accountName'));

    Account updatedAcc = [
      SELECT Description
      FROM Account
      WHERE Id = :testAccs[0].Id
    ];
    System.assertNotEquals(null, updatedAcc.Description);
    System.assert(
      updatedAcc.Description.contains('Audited by Revenant Workflow')
    );
  }

  @isTest
  static void testFanoutStepIdempotentOnRetryWithStaleOffset() {
    List<Account> testAccs = new List<Account>{
      new Account(Name = 'Acme Corp'),
      new Account(Name = 'Stark Industries'),
      new Account(Name = 'Wayne Enterprises')
    };
    insert testAccs;

    Test.startTest();
    Id parentId = WorkflowEngine.start(
      'BatchFanoutWorkflowExample.BatchFanoutWorkflow',
      'StaleOffsetKey',
      null
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(parentId);
    // Advance through FetchRecordsStep then FanoutStep (spawns children, suspends
    // parent). Using step() to pause before DB surgery without driving children.
    harness.step(); // FetchRecordsStep → parent Running at FanoutStep
    harness.step(); // FanoutStep → spawns 3 children, parent Suspended
    Test.stopTest();

    // Inject a stale spawn offset to simulate a crash mid-spawn.
    Workflow_Step_Execution__c stepExec = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :parentId
        AND Step_Name__c = 'BatchFanoutWorkflowExample.FanoutStep'
      LIMIT 1
    ];
    stepExec.Output__c = '{"offset":1}';
    update stepExec;

    Workflow_Instance__c parentInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    parentInst.Status__c = 'Failed';
    update parentInst;

    WorkflowEngine.retryWorkflow(parentId);

    // Drive to completion: FanoutStep re-runs idempotently (skips already-spawned
    // children), children complete, parent finishes. If FanoutStep were NOT
    // idempotent it would throw on duplicate correlation keys and the instance
    // would be left Failed — caught by the status assertion below.
    WorkflowTestHarness.Result result = harness.drive();
    System.assertEquals(
      'Completed',
      result.status,
      'FanoutStep re-run with stale offset must be idempotent and complete'
    );
  }
}
