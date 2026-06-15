@isTest
public class CursorFanoutWorkflowExampleTest {
  @isTest
  static void testCursorFanoutWorkflowSuccess() {
    insert new List<Account>{
      new Account(Name = 'Account A'),
      new Account(Name = 'Account B'),
      new Account(Name = 'Account C'),
      new Account(Name = 'Account D'),
      new Account(Name = 'Account E')
    };

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'CursorFanoutWorkflowExample.CursorFanoutWorkflow',
      'CursorFanoutKey_1',
      null
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);
    System.assert(result.output.contains('"totalProcessed":5'));
    System.assert(
      result.output.contains('Cursor fan-out verification complete')
    );

    // CursorQueryStep recorded the correct total.
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

    // Three chunks were spawned (all now Completed — queried from DB after drive).
    List<Workflow_Instance__c> children = [
      SELECT Correlation_Key__c, Status__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :instanceId
      ORDER BY Correlation_Key__c ASC
    ];
    System.assertEquals(
      3,
      children.size(),
      'Should spawn 3 child chunks for 5 records with chunk size 2'
    );
    System.assert(children[0].Correlation_Key__c.contains('CursorChunk_0_'));
    System.assert(children[1].Correlation_Key__c.contains('CursorChunk_2_'));
    System.assert(children[2].Correlation_Key__c.contains('CursorChunk_4_'));
    for (Workflow_Instance__c child : children) {
      System.assertEquals('Completed', child.Status__c);
    }
  }

  @isTest
  static void testCursorFanoutConfigurableChunkSize() {
    // 5 accounts with chunkSize 5 supplied via input should fan out into a
    // single child chunk instead of the default 3.
    insert new List<Account>{
      new Account(Name = 'Cfg A'),
      new Account(Name = 'Cfg B'),
      new Account(Name = 'Cfg C'),
      new Account(Name = 'Cfg D'),
      new Account(Name = 'Cfg E')
    };

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'CursorFanoutWorkflowExample.CursorFanoutWorkflow',
      'CursorFanoutChunkCfgKey',
      new Map<String, Object>{ 'chunkSize' => 5 }
    );
    new WorkflowTestHarness(instanceId).drive();
    Test.stopTest();

    Workflow_Step_Execution__c queryStepExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'CursorFanoutWorkflowExample.CursorQueryStep'
      LIMIT 1
    ];
    System.assert(
      queryStepExec.Output__c.contains('"chunkSize":5'),
      'Input chunkSize should override the default: ' + queryStepExec.Output__c
    );

    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :instanceId
      ],
      'chunkSize 5 over 5 records should spawn exactly one child chunk'
    );
  }
}
