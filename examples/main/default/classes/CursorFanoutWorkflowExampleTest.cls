@isTest
public class CursorFanoutWorkflowExampleTest {
  @isTest
  static void testCursorFanoutWorkflowSuccess() {
    // Create 5 test Accounts to chunk
    List<Account> accounts = new List<Account>{
      new Account(Name = 'Account A'),
      new Account(Name = 'Account B'),
      new Account(Name = 'Account C'),
      new Account(Name = 'Account D'),
      new Account(Name = 'Account E')
    };
    insert accounts;

    // Ensure orchestrator queueables do not auto-enqueue again on subsequent steps
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Start parent workflow inside startTest/stopTest to execute the initial step (CursorQueryStep)
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'CursorFanoutWorkflowExample.CursorFanoutWorkflow',
      'CursorFanoutKey_1',
      null
    );
    Test.stopTest(); // Runs CursorQueryStep and transitions to CursorFanoutStep

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Running', inst.Status__c);
    System.assertEquals(
      'CursorFanoutWorkflowExample.CursorFanoutStep',
      inst.Current_Step__c
    );

    Workflow_Step_Execution__c queryStepExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'CursorFanoutWorkflowExample.CursorQueryStep'
      LIMIT 1
    ];
    System.assert(queryStepExec.Output__c.contains('"totalRecords":5'));
    System.assert(queryStepExec.Output__c.contains('serializedCursor'));

    // 2. Execute CursorFanoutStep (spawns 3 child workflows for chunks: 0-2, 2-4, 4-5 and suspends)
    new WorkflowOrchestrator(instanceId).execute(null);

    inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    // Parent should be suspended waiting for child completions
    System.assertEquals('Suspended', inst.Status__c);
    System.assertEquals(
      'CursorFanoutWorkflowExample.CursorFanoutStep',
      inst.Current_Step__c
    );

    List<Workflow_Instance__c> children = [
      SELECT Id, Status__c, Correlation_Key__c, Input__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :instanceId
      ORDER BY Correlation_Key__c ASC
    ];
    System.assertEquals(
      3,
      children.size(),
      'Should spawn 3 child workflows for 5 records with chunk size 2'
    );
    System.assert(children[0].Correlation_Key__c.contains('CursorChunk_0_'));
    System.assert(children[1].Correlation_Key__c.contains('CursorChunk_2_'));
    System.assert(children[2].Correlation_Key__c.contains('CursorChunk_4_'));

    // 3. Manually run each child workflow to completion
    for (Workflow_Instance__c child : children) {
      new WorkflowOrchestrator(child.Id).execute(null);
    }

    // Deliver Platform Events published by child completion handlers to wake up parent
    Test.getEventBus().deliver();

    // Check children have transitioned to Completed
    List<Workflow_Instance__c> updatedChildren = [
      SELECT Id, Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :instanceId
    ];
    for (Workflow_Instance__c child : updatedChildren) {
      System.assertEquals('Completed', child.Status__c);
      System.assertNotEquals(null, child.Output__c);
    }

    // Parent should now be wiggled back to Running status
    inst = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId];
    System.assertEquals('Running', inst.Status__c);

    // 4. Run parent CursorFanoutStep again (aggregates child outputs, moves to CursorVerifyStep)
    new WorkflowOrchestrator(instanceId).execute(null);

    inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'CursorFanoutWorkflowExample.CursorVerifyStep',
      inst.Current_Step__c
    );

    Workflow_Step_Execution__c fanoutStepExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'CursorFanoutWorkflowExample.CursorFanoutStep'
      LIMIT 1
    ];
    System.assert(fanoutStepExec.Output__c.contains('"totalProcessed":5'));

    // 5. Run CursorVerifyStep (verifies final stats, transitions to Completed)
    new WorkflowOrchestrator(instanceId).execute(null);

    inst = [
      SELECT Status__c, Current_Step__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assert(inst.Output__c.contains('"totalProcessed":5'));
    System.assert(
      inst.Output__c.contains('Cursor fan-out verification complete')
    );
  }
}
