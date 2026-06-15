@isTest
public class VersionedWorkflowExampleTest {
  @isTest
  static void testVersion1LegacyRoutingAndLogic() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'VersionedWorkflowExample.VersionedWorkflowImpl',
      'VersionKey_V1',
      null
    );

    // Override to v1 before any step runs. Must happen before the harness drives
    // the first step so the engine resolves the v1 routing table.
    Workflow_Instance__c inst = [
      SELECT Definition_Version__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(2, inst.Definition_Version__c);
    inst.Definition_Version__c = 1;
    update inst;

    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

    // Run StepA under the v1 routing context, then inspect before proceeding.
    harness.step();

    inst = [
      SELECT Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'VersionedWorkflowExample.StepBStep',
      inst.Current_Step__c,
      'v1 should route StepA to StepBStep (legacy path)'
    );

    Workflow_Step_Execution__c stepAExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'VersionedWorkflowExample.StepAStep'
    ];
    System.assert(stepAExec.Output__c.contains('Legacy logic'));

    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);
    System.assert(result.output.contains('"legacy":true'));
  }

  @isTest
  static void testVersion2UpgradedRoutingAndLogic() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'VersionedWorkflowExample.VersionedWorkflowImpl',
      'VersionKey_V2',
      null
    );

    Workflow_Instance__c inst = [
      SELECT Definition_Version__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(2, inst.Definition_Version__c);

    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.step(); // StepA under v2 routing

    inst = [
      SELECT Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'VersionedWorkflowExample.NewStepBStep',
      inst.Current_Step__c,
      'v2 should route StepA to NewStepBStep (upgraded path)'
    );

    Workflow_Step_Execution__c stepAExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'VersionedWorkflowExample.StepAStep'
    ];
    System.assert(stepAExec.Output__c.contains('New logic'));

    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);
    System.assert(result.output.contains('"legacy":false'));
  }
}
