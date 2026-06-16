@isTest
public class IncrementalSyncWorkflowExampleTest {
  @isTest
  static void testFirstRunUsesColdStartWindow() {
    // Shorten the lookback so the test doesn't depend on pre-existing data.
    IncrementalSyncWorkflowExample.COLD_START_LOOKBACK_HOURS = 1;

    Account acc = new Account(Name = 'Revenant Test Account');
    insert acc;

    Test.startTest();
    Id run1Id = WorkflowEngine.start(
      'IncrementalSyncWorkflowExample.SyncPollerWorkflow',
      'IncrementalSyncKey',
      null
    );
    WorkflowTestHarness.Result r = new WorkflowTestHarness(run1Id).drive();
    Test.stopTest();

    // Run 1 transitions to ContinuedAsNew after SyncStep + ContinueStep.
    System.assertEquals('ContinuedAsNew', r.status);

    // The SyncChangedAccountsStep output carries the processed count.
    Workflow_Step_Execution__c syncExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :run1Id
        AND Step_Name__c = 'IncrementalSyncWorkflowExample.SyncChangedAccountsStep'
        AND Status__c = 'Completed'
      LIMIT 1
    ];
    Map<String, Object> out = (Map<String, Object>) JSON.deserializeUntyped(
      syncExec.Output__c
    );
    System.assert(
      (Integer) out.get('processedCount') >= 1,
      'Cold-start run must pick up the account inserted in this test'
    );
    System.assert(
      String.isNotBlank((String) out.get('since')),
      'Output must include the since timestamp'
    );
  }

  @isTest
  static void testSuccessorRunReceivesPreviousRunAt() {
    IncrementalSyncWorkflowExample.COLD_START_LOOKBACK_HOURS = 1;

    Test.startTest();
    Id run1Id = WorkflowEngine.start(
      'IncrementalSyncWorkflowExample.SyncPollerWorkflow',
      'IncrementalSyncKey2',
      null
    );
    new WorkflowTestHarness(run1Id).drive();
    Test.stopTest();

    // The successor instance must have Previous_Run_At__c populated.
    Workflow_Instance__c run2 = [
      SELECT Id, Previous_Run_At__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :run1Id
    ];
    System.assertNotEquals(
      null,
      run2.Previous_Run_At__c,
      'Successor instance must carry the predecessor run timestamp'
    );

    // Drive run 2 and verify previousRunAt reaches the step (the "since"
    // timestamp in the output should match the predecessor's Previous_Run_At__c).
    WorkflowTestHarness.Result r2 = new WorkflowTestHarness(run2.Id).drive();
    System.assertEquals('ContinuedAsNew', r2.status);

    Workflow_Step_Execution__c syncExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :run2.Id
        AND Step_Name__c = 'IncrementalSyncWorkflowExample.SyncChangedAccountsStep'
        AND Status__c = 'Completed'
      LIMIT 1
    ];
    Map<String, Object> out = (Map<String, Object>) JSON.deserializeUntyped(
      syncExec.Output__c
    );
    System.assert(
      String.isNotBlank((String) out.get('since')),
      'Run 2 output must include the since timestamp derived from previousRunAt'
    );
    // The since timestamp must be within a few seconds of Previous_Run_At__c.
    Datetime sinceTs = (Datetime) JSON.deserialize(
      '"' + (String) out.get('since') + '"',
      Datetime.class
    );
    Long deltaMs = Math.abs(
      sinceTs.getTime() - run2.Previous_Run_At__c.getTime()
    );
    System.assert(
      deltaMs < 5000,
      'Step\'s since timestamp must match Previous_Run_At__c within 5 s'
    );
  }
}