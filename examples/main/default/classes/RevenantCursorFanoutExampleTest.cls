@IsTest
public class RevenantCursorFanoutExampleTest {
  @IsTest
  static void testCursorFanoutWorkflowSuccess() {
    User runAsUser = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
    System.runAs(runAsUser) {
      insert new List<Account>{
        new Account(Name = 'Account A'),
        new Account(Name = 'Account B'),
        new Account(Name = 'Account C'),
        new Account(Name = 'Account D'),
        new Account(Name = 'Account E')
      };

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'RevenantCursorFanoutExample.CursorFanoutWorkflow',
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
          AND Step_Name__c = 'RevenantCursorFanoutExample.CursorQueryStep'
        LIMIT 1
      ];
      System.assert(queryStepExec.Output__c.contains('"totalRecords":5'));
      System.assert(queryStepExec.Output__c.contains('serializedCursor'));

      // Three chunks were spawned (all now Completed — queried from DB after drive).
      List<Workflow_Instance__c> children = [
        SELECT Correlation_Key__c, Status__c, Progress__c
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
      for (Integer i = 0; i < children.size(); i++) {
        Workflow_Instance__c child = children[i];
        System.assertEquals('Completed', child.Status__c);
        System.assertNotEquals(
          null,
          child.Progress__c,
          'Child chunk workflow should have progress reported'
        );
        Map<String, Object> childProgress = (Map<String, Object>) JSON.deserializeUntyped(
          child.Progress__c
        );
        System.assertEquals(
          100.0,
          (Decimal) childProgress.get('percentComplete')
        );
        Integer expectedOffset = i * 2;
        System.assertEquals(
          'Chunk offset ' + expectedOffset + ' processed successfully',
          (String) childProgress.get('message')
        );
      }

      // Verify parent progress is reported and matches final step
      Workflow_Instance__c parentInst = [
        SELECT Progress__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertNotEquals(
        null,
        parentInst.Progress__c,
        'Parent workflow should have progress reported'
      );
      Map<String, Object> parentProgress = (Map<String, Object>) JSON.deserializeUntyped(
        parentInst.Progress__c
      );
      System.assertEquals(
        100.0,
        (Decimal) parentProgress.get('percentComplete')
      );
      System.assertEquals(
        'Verification complete; fanned-out records validated',
        (String) parentProgress.get('message')
      );
    }
  }

  @IsTest
  static void testCursorFanoutConfigurableChunkSize() {
    User runAsUser = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
    System.runAs(runAsUser) {
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
        'RevenantCursorFanoutExample.CursorFanoutWorkflow',
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
          AND Step_Name__c = 'RevenantCursorFanoutExample.CursorQueryStep'
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
