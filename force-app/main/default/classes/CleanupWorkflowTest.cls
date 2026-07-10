@IsTest
public class CleanupWorkflowTest {
  @IsTest
  static void testCleanupWorkflowPurge() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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

  @IsTest
  static void testDataLossPrevention() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Purged instance: Completed, 40 days old
      Workflow_Instance__c instPurge = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Completed',
        Correlation_Key__c = 'KeyPurge',
        Input__c = '"InputPurge"'
      );
      insert instPurge;
      Test.setCreatedDate(instPurge.Id, DateTime.now().addDays(-40));

      // Keep instance: Completed, 5 days old (not purged)
      Workflow_Instance__c instKeep = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Completed',
        Correlation_Key__c = 'KeyKeep',
        Input__c = '"InputKeep"'
      );
      insert instKeep;
      Test.setCreatedDate(instKeep.Id, DateTime.now().addDays(-5));

      // Create File 1: Engine owned, shared with both instPurge and instKeep (should NOT be deleted)
      ContentVersion cv1 = new ContentVersion(
        Title = 'Input_Shared',
        PathOnClient = 'Input_Shared.json',
        VersionData = Blob.valueOf('{}')
      );
      insert cv1;
      Id docId1 = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv1.Id
      ]
      .ContentDocumentId;

      ContentDocumentLink cdl1a = new ContentDocumentLink(
        ContentDocumentId = docId1,
        LinkedEntityId = instPurge.Id,
        ShareType = 'V',
        Visibility = 'AllUsers'
      );
      insert cdl1a;

      ContentDocumentLink cdl1b = new ContentDocumentLink(
        ContentDocumentId = docId1,
        LinkedEntityId = instKeep.Id,
        ShareType = 'V',
        Visibility = 'AllUsers'
      );
      insert cdl1b;

      // Create File 2: Engine owned, linked ONLY to instPurge (should BE deleted)
      ContentVersion cv2 = new ContentVersion(
        Title = 'Input_Private',
        PathOnClient = 'Input_Private.json',
        VersionData = Blob.valueOf('{}')
      );
      insert cv2;
      Id docId2 = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv2.Id
      ]
      .ContentDocumentId;

      ContentDocumentLink cdl2 = new ContentDocumentLink(
        ContentDocumentId = docId2,
        LinkedEntityId = instPurge.Id,
        ShareType = 'V',
        Visibility = 'AllUsers'
      );
      insert cdl2;

      // Create File 3: User owned (no prefix), linked ONLY to instPurge (should NOT be deleted)
      ContentVersion cv3 = new ContentVersion(
        Title = 'MyImportantDocument',
        PathOnClient = 'MyImportantDocument.pdf',
        VersionData = Blob.valueOf('PDF DATA')
      );
      insert cv3;
      Id docId3 = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv3.Id
      ]
      .ContentDocumentId;

      ContentDocumentLink cdl3 = new ContentDocumentLink(
        ContentDocumentId = docId3,
        LinkedEntityId = instPurge.Id,
        ShareType = 'V',
        Visibility = 'AllUsers'
      );
      insert cdl3;

      // Run cleanup
      Test.startTest();
      WorkflowEngine.start(
        'CleanupWorkflow',
        'Cleanup_Run_DataLoss',
        new Map<String, Object>{ 'retentionDays' => 30, 'batchSize' => 10 }
      );
      Test.stopTest();

      // Verify instance was deleted
      List<Workflow_Instance__c> deletedInstances = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Id = :instPurge.Id
      ];
      System.assert(deletedInstances.isEmpty(), 'instPurge should be deleted');

      // Verify files
      List<ContentDocument> docs = [
        SELECT Id, Title
        FROM ContentDocument
        WHERE Id IN (:docId1, :docId2, :docId3)
      ];
      Set<Id> remainingDocIds = new Set<Id>();
      for (ContentDocument d : docs) {
        remainingDocIds.add(d.Id);
      }

      System.assert(
        remainingDocIds.contains(docId1),
        'Shared file Input_Shared should NOT be deleted'
      );
      System.assert(
        !remainingDocIds.contains(docId2),
        'Private file Input_Private should BE deleted'
      );
      System.assert(
        remainingDocIds.contains(docId3),
        'User file MyImportantDocument should NOT be deleted'
      );
    }
  }

  @IsTest
  static void testInputValidation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Test Malformed JSON
      try {
        Workflow_Instance__c instMalformed = new Workflow_Instance__c(
          Workflow_Name__c = 'CleanupWorkflow',
          Status__c = 'Running',
          Input__c = '{malformed json}'
        );
        insert instMalformed;
        StepContext ctx = new StepContext(
          instMalformed.Id,
          'CleanupWorkflow',
          'CleanupWorkflow.PurgeOldInstancesStep',
          null,
          null,
          null,
          instMalformed.Input__c
        );
        new CleanupWorkflow.PurgeOldInstancesStep().execute(ctx);
        System.assert(false, 'Should throw exception on malformed JSON');
      } catch (Exception ex) {
        System.assert(
          ex.getMessage().contains('Malformed JSON'),
          'Expected Malformed JSON error, got: ' + ex.getMessage()
        );
      }

      // Test invalid retentionDays type
      try {
        Workflow_Instance__c instBadType = new Workflow_Instance__c(
          Workflow_Name__c = 'CleanupWorkflow',
          Status__c = 'Running',
          Input__c = '{"retentionDays":"not-an-integer"}'
        );
        insert instBadType;
        StepContext ctx = new StepContext(
          instBadType.Id,
          'CleanupWorkflow',
          'CleanupWorkflow.PurgeOldInstancesStep',
          null,
          null,
          null,
          instBadType.Input__c
        );
        new CleanupWorkflow.PurgeOldInstancesStep().execute(ctx);
        System.assert(
          false,
          'Should throw exception on invalid retentionDays type'
        );
      } catch (Exception ex) {
        System.assert(
          ex.getMessage().contains('Invalid retentionDays parameter type'),
          'Expected invalid type error, got: ' + ex.getMessage()
        );
      }

      // Test negative retentionDays
      try {
        Workflow_Instance__c instNeg = new Workflow_Instance__c(
          Workflow_Name__c = 'CleanupWorkflow',
          Status__c = 'Running',
          Input__c = '{"retentionDays":-5}'
        );
        insert instNeg;
        StepContext ctx = new StepContext(
          instNeg.Id,
          'CleanupWorkflow',
          'CleanupWorkflow.PurgeOldInstancesStep',
          null,
          null,
          null,
          instNeg.Input__c
        );
        new CleanupWorkflow.PurgeOldInstancesStep().execute(ctx);
        System.assert(
          false,
          'Should throw exception on negative retentionDays'
        );
      } catch (Exception ex) {
        System.assert(
          ex.getMessage()
            .contains('retentionDays parameter cannot be negative'),
          'Expected negative error, got: ' + ex.getMessage()
        );
      }

      // Test zero batchSize
      try {
        Workflow_Instance__c instZero = new Workflow_Instance__c(
          Workflow_Name__c = 'CleanupWorkflow',
          Status__c = 'Running',
          Input__c = '{"batchSize":0}'
        );
        insert instZero;
        StepContext ctx = new StepContext(
          instZero.Id,
          'CleanupWorkflow',
          'CleanupWorkflow.PurgeOldInstancesStep',
          null,
          null,
          null,
          instZero.Input__c
        );
        new CleanupWorkflow.PurgeOldInstancesStep().execute(ctx);
        System.assert(false, 'Should throw exception on zero batchSize');
      } catch (Exception ex) {
        System.assert(
          ex.getMessage()
            .contains('batchSize parameter must be greater than zero'),
          'Expected zero batchSize error, got: ' + ex.getMessage()
        );
      }

      // Test invalid batchSize type
      try {
        Workflow_Instance__c instBadBatchType = new Workflow_Instance__c(
          Workflow_Name__c = 'CleanupWorkflow',
          Status__c = 'Running',
          Input__c = '{"batchSize":"not-an-integer"}'
        );
        insert instBadBatchType;
        StepContext ctx = new StepContext(
          instBadBatchType.Id,
          'CleanupWorkflow',
          'CleanupWorkflow.PurgeOldInstancesStep',
          null,
          null,
          null,
          instBadBatchType.Input__c
        );
        new CleanupWorkflow.PurgeOldInstancesStep().execute(ctx);
        System.assert(
          false,
          'Should throw exception on invalid batchSize type'
        );
      } catch (Exception ex) {
        System.assert(
          ex.getMessage().contains('Invalid batchSize parameter type'),
          'Expected invalid type error, got: ' + ex.getMessage()
        );
      }
    }
  }

  @IsTest
  static void testLimitSafetyClamping() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 60 old workflow instances
      List<Workflow_Instance__c> oldInstances = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 60; i++) {
        oldInstances.add(
          new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Completed',
            Correlation_Key__c = 'KeyClamp_' + i,
            Input__c = '"InputClamp"'
          )
        );
      }
      insert oldInstances;
      for (Workflow_Instance__c inst : oldInstances) {
        Test.setCreatedDate(inst.Id, DateTime.now().addDays(-40));
      }

      // Start cleanup with batchSize = 100, which should clamp to 50
      Test.startTest();
      Id cleanupInstanceId = WorkflowEngine.start(
        'CleanupWorkflow',
        'Cleanup_Run_Clamp',
        new Map<String, Object>{ 'retentionDays' => 30, 'batchSize' => 100 }
      );
      Test.stopTest();

      // Query the latest step execution record's output since it yielded
      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :cleanupInstanceId
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      System.assert(!stepExecs.isEmpty());

      CleanupWorkflow.PurgeState midState = (CleanupWorkflow.PurgeState) JSON.deserialize(
        WorkflowEngine.resolvePayload(stepExecs[0].Output__c),
        CleanupWorkflow.PurgeState.class
      );
      System.assertEquals(
        50,
        midState.deletedCount,
        'Should have processed exactly 50 instances (clamped)'
      );
    }
  }

  @IsTest
  static void testSingleHugeInstancePurge() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 1. Create a workflow instance that is old and completed
      Workflow_Instance__c instA = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Completed',
        Correlation_Key__c = 'KeyHuge',
        Input__c = '"InputHuge"'
      );
      insert instA;
      Test.setCreatedDate(instA.Id, DateTime.now().addDays(-40));

      // 2. Create 105 ContentVersions bulk style
      List<ContentVersion> versions = new List<ContentVersion>();
      for (Integer i = 0; i < 105; i++) {
        versions.add(
          new ContentVersion(
            Title = 'Input_Huge_' + i,
            PathOnClient = 'Input_Huge_' + i + '.json',
            VersionData = Blob.valueOf('{}')
          )
        );
      }
      insert versions;

      // Query ContentDocumentIds
      List<Id> versionIds = new List<Id>();
      for (ContentVersion cv : versions) {
        versionIds.add(cv.Id);
      }
      List<ContentVersion> queriedVersions = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id IN :versionIds
      ];

      // Create ContentDocumentLink for each document
      List<ContentDocumentLink> links = new List<ContentDocumentLink>();
      for (ContentVersion cv : queriedVersions) {
        links.add(
          new ContentDocumentLink(
            ContentDocumentId = cv.ContentDocumentId,
            LinkedEntityId = instA.Id,
            ShareType = 'V',
            Visibility = 'AllUsers'
          )
        );
      }
      insert links;

      // Execute the purge step on this instance
      CleanupWorkflow.PurgeOldInstancesStep purgeStep = new CleanupWorkflow.PurgeOldInstancesStep();
      StepContext purgeCtx = new StepContext(
        instA.Id,
        'CleanupWorkflow',
        'CleanupWorkflow.PurgeOldInstancesStep',
        null,
        null,
        null,
        '{"retentionDays":30,"batchSize":10}',
        1
      );

      Test.startTest();
      StepResult purgeResult = purgeStep.execute(purgeCtx);
      Test.stopTest();

      // Verify it completed because it processed the single candidate successfully
      System.assertEquals(StepResult.ActionType.COMPLETE, purgeResult.action);

      // Verify all 105 files and links were deleted
      List<ContentDocumentLink> remainingLinks = [
        SELECT ContentDocumentId
        FROM ContentDocumentLink
        WHERE LinkedEntityId = :instA.Id
      ];
      System.assertEquals(
        0,
        remainingLinks.size(),
        'All 105 links should be deleted'
      );

      List<Workflow_Instance__c> remainingInstances = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Id = :instA.Id
      ];
      System.assertEquals(
        0,
        remainingInstances.size(),
        'Workflow instance should be deleted'
      );
    }
  }
}
