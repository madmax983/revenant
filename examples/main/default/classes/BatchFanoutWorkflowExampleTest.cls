@isTest
public class BatchFanoutWorkflowExampleTest {
  @isTest
  static void testBatchFanoutWorkflowSuccess() {
    // Seed 3 real Account records
    List<Account> testAccs = new List<Account>{
      new Account(Name = 'Acme Corp'),
      new Account(Name = 'Stark Industries'),
      new Account(Name = 'Wayne Enterprises')
    };
    insert testAccs;

    // 1. Start the parent BatchFanoutWorkflow
    Test.startTest();
    Id parentId = WorkflowEngine.start(
      'BatchFanoutWorkflowExample.BatchFanoutWorkflow',
      'ParentKey',
      null
    );
    Test.stopTest(); // Runs FetchRecordsStep and transitions to FanoutStep (does not execute FanoutStep yet)

    // Verify parent is Running on FanoutStep
    Workflow_Instance__c parentInst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    System.assertEquals('Running', parentInst.Status__c);
    System.assertEquals(
      'BatchFanoutWorkflowExample.FanoutStep',
      parentInst.Current_Step__c
    );

    // 2. Execute FanoutStep for the first time to spawn children and suspend
    new WorkflowOrchestrator(parentId).execute(null);

    // Verify parent is Suspended
    parentInst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    System.assertEquals('Suspended', parentInst.Status__c);
    System.assertEquals(
      'BatchFanoutWorkflowExample.FanoutStep',
      parentInst.Current_Step__c
    );

    // 3. Verify that 3 child ProcessRecordWorkflow instances were spawned
    List<Workflow_Instance__c> children = [
      SELECT Id, Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :parentId
    ];
    System.assertEquals(
      3,
      children.size(),
      'Should have spawned 3 child workflows'
    );
    for (Workflow_Instance__c child : children) {
      System.assertEquals('Pending', child.Status__c);
      System.assert(child.Correlation_Key__c.contains('Process_001'));
    }

    // 4. Manually run each child workflow to completion
    for (Workflow_Instance__c child : children) {
      new WorkflowOrchestrator(child.Id).execute(null);
    }

    // 5. Deliver the Platform Events (ChildCompleted signals) to the parent
    Test.getEventBus().deliver();

    // 6. Verify parent has been wiggled back to Running status
    parentInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    System.assertEquals(
      'Running',
      parentInst.Status__c,
      'Parent should be Running after signals are delivered'
    );

    // 7. Manually run the parent orchestrator to process FanoutStep join aggregation
    new WorkflowOrchestrator(parentId).execute(null);

    // Verify the step transitioned to VerifyBatchStep
    parentInst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    System.assertEquals(
      'VerifyBatchStep',
      parentInst.Current_Step__c.substringAfterLast('.')
    );

    // 8. Run parent orchestrator again to execute VerifyBatchStep and complete the workflow
    new WorkflowOrchestrator(parentId).execute(null);

    // 9. Assert final completion and output payload
    parentInst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    System.assertEquals('Completed', parentInst.Status__c);

    System.assertNotEquals(null, parentInst.Output__c);
    Map<String, Object> outputMap = (Map<String, Object>) JSON.deserializeUntyped(
      parentInst.Output__c
    );
    System.assertEquals(3, outputMap.get('totalProcessed'));
    System.assertEquals(
      'Batch completed successfully',
      outputMap.get('status')
    );

    Map<String, Object> details = (Map<String, Object>) outputMap.get(
      'details'
    );
    System.assertEquals(3, details.size());

    // Assert child audit results are aggregated and database was updated
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
}
