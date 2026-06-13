@isTest
public class CleanupWorkflowTest {
  @isTest
  static void testCleanupWorkflowPurge() {
    // 1. Create a set of test workflow instances

    // Record A: Completed, 40 days old (should be purged)
    Workflow_Instance__c instA = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'KeyA',
      Input__c = '"InputA"',
      Output__c = '"OutputA"'
    );
    insert instA;
    Test.setCreatedDate(instA.Id, DateTime.now().addDays(-40));

    // Insert step execution and signal for cascade delete check
    Workflow_Step_Execution__c stepA = new Workflow_Step_Execution__c(
      Workflow_Instance__c = instA.Id,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Completed',
      Retry_Count__c = 0
    );
    insert stepA;

    Workflow_Signal__c sigA = new Workflow_Signal__c(
      Workflow_Instance__c = instA.Id,
      Signal_Name__c = 'SignalA',
      Status__c = 'Consumed'
    );
    insert sigA;

    // Record B: Failed, 35 days old (should be purged)
    Workflow_Instance__c instB = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Failed',
      Correlation_Key__c = 'KeyB',
      Input__c = '"InputB"',
      Error_Message__c = 'Crash'
    );
    insert instB;
    Test.setCreatedDate(instB.Id, DateTime.now().addDays(-35));

    Workflow_Step_Execution__c stepB = new Workflow_Step_Execution__c(
      Workflow_Instance__c = instB.Id,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Failed',
      Retry_Count__c = 1
    );
    insert stepB;

    // Record C: Completed, 5 days old (should NOT be purged - too recent)
    Workflow_Instance__c instC = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'KeyC',
      Input__c = '"InputC"'
    );
    insert instC;
    Test.setCreatedDate(instC.Id, DateTime.now().addDays(-5));

    // Record D: Running, 40 days old (should NOT be purged - not in terminal status)
    Workflow_Instance__c instD = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running',
      Correlation_Key__c = 'KeyD',
      Input__c = '"InputD"'
    );
    insert instD;
    Test.setCreatedDate(instD.Id, DateTime.now().addDays(-40));

    // 2. Start the cleanup workflow
    // Use batchSize = 1 to verify yielding across multiple chunks
    Test.startTest();
    Id cleanupInstanceId = WorkflowEngine.start(
      'CleanupWorkflow',
      'Cleanup_Run_1',
      new Map<String, Object>{ 'retentionDays' => 30, 'batchSize' => 1 }
    );
    Test.stopTest(); // Wait for first queueable execution to complete

    // Manually run orchestrator for second batch (deletes instB)
    new WorkflowOrchestrator(cleanupInstanceId).execute(null);

    // Manually run orchestrator for final batch completion
    new WorkflowOrchestrator(cleanupInstanceId).execute(null);

    // 3. Verify assertions

    // Assert that instA and instB were deleted
    List<Workflow_Instance__c> deletedA = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Id = :instA.Id
    ];
    List<Workflow_Instance__c> deletedB = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Id = :instB.Id
    ];
    System.assert(deletedA.isEmpty(), 'instA should be deleted');
    System.assert(deletedB.isEmpty(), 'instB should be deleted');

    // Assert cascade deletes of steps and signals
    List<Workflow_Step_Execution__c> stepsA = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepA.Id
    ];
    List<Workflow_Signal__c> signalsA = [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE Id = :sigA.Id
    ];
    List<Workflow_Step_Execution__c> stepsB = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepB.Id
    ];
    System.assert(stepsA.isEmpty(), 'stepA should be cascade deleted');
    System.assert(signalsA.isEmpty(), 'sigA should be cascade deleted');
    System.assert(stepsB.isEmpty(), 'stepB should be cascade deleted');

    // Assert that instC and instD still exist
    List<Workflow_Instance__c> activeC = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Id = :instC.Id
    ];
    List<Workflow_Instance__c> activeD = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Id = :instD.Id
    ];
    System.assertEquals(1, activeC.size(), 'instC should still exist');
    System.assertEquals(1, activeD.size(), 'instD should still exist');

    // Assert that the cleanup workflow instance itself completed and logged the correct number of deleted instances
    Workflow_Instance__c cleanupInst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :cleanupInstanceId
    ];
    System.assertEquals('Completed', cleanupInst.Status__c);
    System.assertNotEquals(null, cleanupInst.Output__c);

    CleanupWorkflow.PurgeState finalState = (CleanupWorkflow.PurgeState) JSON.deserialize(
      cleanupInst.Output__c,
      CleanupWorkflow.PurgeState.class
    );
    System.assertEquals(
      2,
      finalState.deletedCount,
      'Should record 2 deleted instances'
    );
  }
}
