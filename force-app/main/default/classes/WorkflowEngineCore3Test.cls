@IsTest
public class WorkflowEngineCore3Test {
  @IsTest
  static void testPreviousRunAtFlowsThroughContinueAsNew() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id run1Id = WorkflowEngine.start(
        'WorkflowEngineTestMocksA.PreviousRunAtWorkflow',
        'PreviousRunAtKey',
        null
      );
      new WorkflowOrchestrator(run1Id).execute(null);

      Workflow_Instance__c run1 = [
        SELECT Status__c, Previous_Run_At__c
        FROM Workflow_Instance__c
        WHERE Id = :run1Id
      ];
      System.assertEquals('ContinuedAsNew', run1.Status__c);
      System.assertEquals(
        null,
        run1.Previous_Run_At__c,
        'First instance must not have Previous_Run_At__c set'
      );

      Workflow_Instance__c run2 = [
        SELECT Id, Previous_Run_At__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :run1Id
      ];
      System.assertNotEquals(
        null,
        run2.Previous_Run_At__c,
        'Continuation instance must have Previous_Run_At__c set'
      );

      new WorkflowOrchestrator(run2.Id).execute(null);

      Workflow_Instance__c run2Final = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :run2.Id
      ];
      System.assertEquals('Completed', run2Final.Status__c);
      Long outputTime = Long.valueOf(run2Final.Output__c);
      Long fieldTime = run2.Previous_Run_At__c.getTime();
      System.assertEquals(
        fieldTime,
        outputTime,
        'StepContext.previousRunAt must equal Previous_Run_At__c on the instance'
      );
    }
  }
}
