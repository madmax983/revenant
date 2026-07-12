@IsTest
public class CursorFanoutWorkflowExampleTest {
  @IsTest
  static void testCursorFanoutWorkflowSuccess() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
      WorkflowTestHarness.Result runResult = harness.drive();
      Test.stopTest();

      System.assertEquals('Completed', runResult.status);
      System.assert(runResult.output.contains('"totalProcessed":5'));
      System.assert(
        runResult.output.contains('Cursor fan-out verification complete')
      );

      // CursorQueryStep recorded the correct total.
      Workflow_Step_Execution__c queryExecution = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'CursorFanoutWorkflowExample.CursorQueryStep'
        LIMIT 1
      ];
      System.assert(queryExecution.Output__c.contains('"totalRecords":5'));
      System.assert(queryExecution.Output__c.contains('serializedCursor'));

      // Three chunks were spawned (all now Completed — queried from DB after drive).
      List<Workflow_Instance__c> chunkInstances = [
        SELECT Correlation_Key__c, Status__c, Progress__c
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :instanceId
        ORDER BY Correlation_Key__c ASC
      ];
      System.assertEquals(
        3,
        chunkInstances.size(),
        'Should spawn 3 child chunks for 5 records with chunk size 2'
      );
      System.assert(
        chunkInstances[0].Correlation_Key__c.contains('CursorChunk_0_')
      );
      System.assert(
        chunkInstances[1].Correlation_Key__c.contains('CursorChunk_2_')
      );
      System.assert(
        chunkInstances[2].Correlation_Key__c.contains('CursorChunk_4_')
      );
      for (Integer idx = 0; idx < chunkInstances.size(); idx++) {
        Workflow_Instance__c chunk = chunkInstances[idx];
        System.assertEquals('Completed', chunk.Status__c);
        System.assertNotEquals(
          null,
          chunk.Progress__c,
          'Child chunk workflow should have progress reported'
        );
        Map<String, Object> chunkProgress = (Map<String, Object>) JSON.deserializeUntyped(
          chunk.Progress__c
        );
        System.assertEquals(
          100.0,
          (Decimal) chunkProgress.get('percentComplete')
        );
        Integer expectedChunkOffset = idx * 2;
        System.assertEquals(
          'Chunk offset ' + expectedChunkOffset + ' processed successfully',
          (String) chunkProgress.get('message')
        );
      }

      // Verify parent progress is reported and matches final step
      Workflow_Instance__c parentRecord = [
        SELECT Progress__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertNotEquals(
        null,
        parentRecord.Progress__c,
        'Parent workflow should have progress reported'
      );
      Map<String, Object> parentSummary = (Map<String, Object>) JSON.deserializeUntyped(
        parentRecord.Progress__c
      );
      System.assertEquals(
        100.0,
        (Decimal) parentSummary.get('percentComplete')
      );
      System.assertEquals(
        'Verification complete; fanned-out records validated',
        (String) parentSummary.get('message')
      );
    }
  }

  @IsTest
  static void testCursorFanoutConfigurableChunkSize() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
        'Input chunkSize should override the default: ' +
        queryStepExec.Output__c
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
}
