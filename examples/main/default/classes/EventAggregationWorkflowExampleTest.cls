@IsTest
public class EventAggregationWorkflowExampleTest {
  @IsTest
  static void testEventAggregationEndToEnd() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      WorkflowEngine.StartRequest startReq = new WorkflowEngine.StartRequest(
        'EventAggregationWorkflowExample',
        'Cart-123',
        null
      );

      // 1. Deliver first event (starts workflow and records signal)
      Test.startTest();
      WorkflowEngine.StartResult res1 = WorkflowEngine.signalOrStart(
        startReq,
        EventAggregationWorkflowExample.EVENT_SIGNAL,
        '"Item-A"',
        'Idemp-E1'
      );

      // Verify first event started a new instance
      System.assertEquals(true, res1.isNew);
      Id instId = res1.instanceId;

      // Run the step to process the first event
      WorkflowEngine.runStep(instId);

      // Should be Suspended because we only have 1 event (need 3)
      Workflow_Instance__c instAfter1 = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instId
      ];
      System.assertEquals('Suspended', instAfter1.Status__c);
      System.assertEquals(
        'EventAggregationWorkflowExample.AccumulateStep',
        instAfter1.Current_Step__c
      );

      // 2. Deliver second event
      WorkflowEngine.StartResult res2 = WorkflowEngine.signalOrStart(
        startReq,
        EventAggregationWorkflowExample.EVENT_SIGNAL,
        '"Item-B"',
        'Idemp-E2'
      );

      // Verify it resolved to the existing instance
      System.assertEquals(instId, res2.instanceId);
      System.assertEquals(false, res2.isNew);

      // Run the step to process the second event
      WorkflowEngine.runStep(instId);

      // Still Suspended (2 events)
      Workflow_Instance__c instAfter2 = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instId
      ];
      System.assertEquals('Suspended', instAfter2.Status__c);

      // 3. Deliver third event
      WorkflowEngine.signalOrStart(
        startReq,
        EventAggregationWorkflowExample.EVENT_SIGNAL,
        '"Item-C"',
        'Idemp-E3'
      );

      // Run the step to process the third event
      WorkflowEngine.runStep(instId);

      // Now it should have transitioned to ProcessBatchStep (since it reached 3 events)
      Workflow_Instance__c instAfter3 = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instId
      ];
      System.assertEquals('Running', instAfter3.Status__c);
      System.assertEquals(
        'EventAggregationWorkflowExample.ProcessBatchStep',
        instAfter3.Current_Step__c
      );

      // Run the ProcessBatchStep to complete the workflow
      WorkflowEngine.runStep(instId);
      Test.stopTest();

      // Verify workflow is completed and output matches
      Workflow_Instance__c finalInst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instId
      ];
      System.assertEquals(
        'Completed',
        finalInst.Status__c,
        'Actual status: ' +
          finalInst.Status__c +
          ', Output: ' +
          finalInst.Output__c
      );
      System.assert(
        finalInst.Output__c.contains(
          'Processed 3 events: Item-A, Item-B, Item-C'
        ),
        'Output was: ' + finalInst.Output__c
      );
    }
  }
}
