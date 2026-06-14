@isTest
public class VersionedWorkflowExampleTest {
  @isTest
  static void testVersion1LegacyRoutingAndLogic() {
    WorkflowEngine.disableQueueableInTest = true;

    Test.startTest();
    // 1. Start workflow - resolves latest version to 2
    Id instanceId = WorkflowEngine.start(
      'VersionedWorkflowExample.VersionedWorkflowImpl',
      'VersionKey_V1',
      null
    );

    // 2. Manually override version to 1 in DB to simulate an existing active legacy instance
    Workflow_Instance__c inst = [
      SELECT Definition_Version__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(2, inst.Definition_Version__c);
    inst.Definition_Version__c = 1;
    update inst;

    // 3. Execute StepA - should execute with legacy version context
    WorkflowEngine.runStep(instanceId, null);

    // Verify next step is routed to StepB (Legacy version 1 route) instead of NewStepB
    inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'VersionedWorkflowExample.StepBStep',
      inst.Current_Step__c
    );

    // Verify StepA execution output contains legacy message
    Workflow_Step_Execution__c stepAExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'VersionedWorkflowExample.StepAStep'
    ];
    System.assert(stepAExec.Output__c.contains('Legacy logic'));

    // 4. Run StepB to complete the workflow
    WorkflowEngine.runStep(instanceId, null);
    Test.stopTest();

    inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assert(inst.Output__c.contains('"legacy":true'));
  }

  @isTest
  static void testVersion2UpgradedRoutingAndLogic() {
    WorkflowEngine.disableQueueableInTest = true;

    Test.startTest();
    // 1. Start workflow - resolves latest version to 2
    Id instanceId = WorkflowEngine.start(
      'VersionedWorkflowExample.VersionedWorkflowImpl',
      'VersionKey_V2',
      null
    );

    // Verify version is resolved to 2
    Workflow_Instance__c inst = [
      SELECT Definition_Version__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(2, inst.Definition_Version__c);

    // 2. Run StepA
    WorkflowEngine.runStep(instanceId, null);

    // Verify next step is routed to NewStepB (Version 2+ route)
    inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'VersionedWorkflowExample.NewStepBStep',
      inst.Current_Step__c
    );

    // Verify StepA execution output contains upgraded message
    Workflow_Step_Execution__c stepAExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'VersionedWorkflowExample.StepAStep'
    ];
    System.assert(stepAExec.Output__c.contains('New logic'));

    // 3. Run NewStepB to complete the workflow
    WorkflowEngine.runStep(instanceId, null);
    Test.stopTest();

    inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assert(inst.Output__c.contains('"legacy":false'));
  }
}
