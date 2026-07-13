@IsTest
public class WorkflowEngineCausationTest {
  @IsTest
  static void testCausationIdPersistenceAndLineage() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Start A (root) with a causation ID
      WorkflowEngine.StartRequest reqA = new WorkflowEngine.StartRequest(
        'WorkflowEngineTest.HappyWorkflow',
        'CausationKeyA',
        null
      );
      reqA.causationId = 'root-causation-trace-123';

      Test.startTest();
      WorkflowEngine.StartResult resultA = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ reqA }
      )[0];
      System.assertEquals(true, resultA.isNew);

      Workflow_Instance__c instA = [
        SELECT Causation_Id__c
        FROM Workflow_Instance__c
        WHERE Id = :resultA.instanceId
      ];
      System.assertEquals(
        'root-causation-trace-123',
        instA.Causation_Id__c,
        'Causation ID must be persisted'
      );

      // Test getStatus read API
      WorkflowEngine.WorkflowStatus statusA = WorkflowEngine.getStatus(
        resultA.instanceId
      );
      System.assertEquals(
        'root-causation-trace-123',
        statusA.causationId,
        'Status DTO must expose causationId'
      );

      // Start B (downstream) using A as cause
      WorkflowEngine.StartRequest reqB = new WorkflowEngine.StartRequest(
        'WorkflowEngineTest.HappyWorkflow',
        'CausationKeyB',
        null
      );
      reqB.causationId = resultA.instanceId;
      WorkflowEngine.StartResult resultB = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ reqB }
      )[0];

      // Start C (downstream) using B as cause
      WorkflowEngine.StartRequest reqC = new WorkflowEngine.StartRequest(
        'WorkflowEngineTest.HappyWorkflow',
        'CausationKeyC',
        null
      );
      reqC.causationId = resultB.instanceId;
      WorkflowEngine.StartResult resultC = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ reqC }
      )[0];

      // Verify lineage walk: C -> B -> A
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        resultC.instanceId
      );
      System.assertNotEquals(null, lineage);
      System.assertEquals(3, lineage.size(), 'Lineage size mismatch');
      System.assertEquals(resultC.instanceId, lineage[0].instanceId);
      System.assertEquals(resultB.instanceId, lineage[1].instanceId);
      System.assertEquals(resultA.instanceId, lineage[2].instanceId);

      Test.stopTest();
    }
  }

  @IsTest
  static void testCausationIdInheritedOnContinueAsNew() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Start with a causation ID
      WorkflowEngine.StartRequest req = new WorkflowEngine.StartRequest(
        'WorkflowEngineMocksBTest.DaemonWorkflow',
        'CausationDaemonKey',
        0
      );
      req.causationId = 'trace-456';

      Id instanceId = WorkflowEngine.startOrGet(
          new List<WorkflowEngine.StartRequest>{ req }
        )[0]
        .instanceId;
      new WorkflowOrchestrator(instanceId).execute(null); // Runs the first execution run -> continueAsNew

      // Find Run 2
      Workflow_Instance__c run2 = [
        SELECT Id, Status__c, Causation_Id__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :instanceId
      ];
      System.assertEquals('Pending', run2.Status__c);
      System.assertEquals(
        'trace-456',
        run2.Causation_Id__c,
        'Successor must inherit causation ID'
      );
    }
  }

  @IsTest
  static void testCausationIdParentFallback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Start Parent
      Id parentId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'ParentKey',
        null
      );

      // Start Child under Parent
      Id childId = WorkflowEngine.start(
        new WorkflowEngine.StartRequest(
            'WorkflowEngineTest.HappyWorkflow',
            'ChildKey',
            null
          )
          .withParent(parentId)
      );

      Workflow_Instance__c child = [
        SELECT Causation_Id__c, Parent_Instance__c
        FROM Workflow_Instance__c
        WHERE Id = :childId
      ];
      System.assertEquals(
        parentId,
        child.Causation_Id__c,
        'Causation ID must fallback to Parent Instance ID on build'
      );

      // Verify lineage walk follows Parent_Instance__c fallback even if Causation_Id__c was blank (test by manually nulling it)
      child.Causation_Id__c = null;
      update child;

      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        childId
      );
      System.assertEquals(2, lineage.size());
      System.assertEquals(childId, lineage[0].instanceId);
      System.assertEquals(parentId, lineage[1].instanceId);
    }
  }

  @IsTest
  static void testCausationIdReusedKeyTimeBound() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Create original parent
      Id originalParentId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'ReusedKey',
        null
      );

      // Start Child using correlation key of parent
      WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
        'WorkflowEngineTest.HappyWorkflow',
        'ChildKeyReused',
        null
      );
      childReq.causationId = 'key:ReusedKey';
      Id childId = WorkflowEngine.startOrGet(
          new List<WorkflowEngine.StartRequest>{ childReq }
        )[0]
        .instanceId;

      // 2. Create a new, later run with the same correlation key
      // Since Correlation_Key__c unique index prevents multiple active runs, we make the original parent complete first.
      Workflow_Instance__c origParent = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :originalParentId
      ];
      origParent.Status__c = 'Completed';
      update origParent;
      origParent.Terminal_At__c = DateTime.now().addDays(-2);
      update origParent;

      Id newerParentId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'ReusedKey',
        null
      );

      // Explicitly set CreatedDates to bound them
      Test.setCreatedDate(originalParentId, DateTime.now().addMinutes(-10));
      Test.setCreatedDate(childId, DateTime.now().addMinutes(-5));
      Test.setCreatedDate(newerParentId, DateTime.now());

      // Update child's Causation_Id__c timestamp to match its mocked CreatedDate
      Workflow_Instance__c childInst = [
        SELECT Causation_Id__c
        FROM Workflow_Instance__c
        WHERE Id = :childId
      ];
      childInst.Causation_Id__c =
        'key:ReusedKey::ts::' +
        String.valueOf(DateTime.now().addMinutes(-5).getTime());
      update childInst;

      // Assert that getCausationLineage on child resolves to originalParentId (older) and NOT newerParentId (newer)
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        childId
      );
      System.assertEquals(2, lineage.size());
      System.assertEquals(childId, lineage[0].instanceId);
      System.assertEquals(
        originalParentId,
        lineage[1].instanceId,
        'Must resolve to the parent that existed at child creation time'
      );
    }
  }

  @IsTest
  static void testCausationIdInheritedOnContinueAsNewFallback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Start Parent
      Id parentId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'ParentKey',
        null
      );

      // Start Child under Parent with blank causationId (so it has only Parent_Instance__c)
      WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
          'WorkflowEngineMocksBTest.DaemonWorkflow',
          'ChildDaemonKey',
          0
        )
        .withParent(parentId);
      Id childId = WorkflowEngine.startOrGet(
          new List<WorkflowEngine.StartRequest>{ childReq }
        )[0]
        .instanceId;

      // Verify child has blank Causation_Id__c but non-blank Parent_Instance__c
      Workflow_Instance__c child = [
        SELECT Causation_Id__c, Parent_Instance__c
        FROM Workflow_Instance__c
        WHERE Id = :childId
      ];
      child.Causation_Id__c = null;
      update child;

      // Execute run -> triggers continueAsNew
      new WorkflowOrchestrator(childId).execute(null);

      // Find Run 2 of Child (the successor)
      Workflow_Instance__c run2 = [
        SELECT Id, Status__c, Causation_Id__c, Previous_Instance__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :childId
      ];
      // successor must inherit parentId as causationId since predecessor's Causation_Id__c was blank but Parent_Instance__c was parentId
      System.assertEquals(
        parentId,
        run2.Causation_Id__c,
        'Successor must inherit parentId as causationId'
      );

      // Verify lineage walk from Run 2 correctly resolves to Parent
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        run2.Id
      );
      System.assertEquals(2, lineage.size());
      System.assertEquals(run2.Id, lineage[0].instanceId);
      System.assertEquals(parentId, lineage[1].instanceId);
    }
  }

  @IsTest
  static void testCausationLineageCarriesTerminalOutputs() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Start Parent
      Id parentId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'ParentKey',
        '{"val": "ParentInput"}'
      );

      // Complete the Parent by executing it
      new WorkflowOrchestrator(parentId).execute(null);
      new WorkflowOrchestrator(parentId).execute(null);

      // Verify it is completed and has output
      Workflow_Instance__c parent = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :parentId
      ];
      System.assertEquals('Completed', parent.Status__c);
      System.assertNotEquals(null, parent.Output__c);

      // Start Child under Parent
      Id childId = WorkflowEngine.start(
        new WorkflowEngine.StartRequest(
            'WorkflowEngineTest.HappyWorkflow',
            'ChildKey',
            null
          )
          .withParent(parentId)
      );

      // Get causation lineage on Child
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        childId
      );
      System.assertEquals(2, lineage.size());
      System.assertEquals(childId, lineage[0].instanceId);
      System.assertEquals(parentId, lineage[1].instanceId);

      // Verify parent's output in the lineage matches the actual output
      System.assertNotEquals(null, lineage[1].output);
      System.assertNotEquals('', lineage[1].output);
      System.assertEquals(
        parent.Output__c,
        lineage[1].output,
        'Terminal lineage entries must carry rehydrated output'
      );
    }
  }

  @IsTest
  static void testCausationIdReusedKeySelfExclusion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Create original parent
      Id originalParentId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'ReusedKeySame',
        null
      );

      // Make the original parent complete first to release the Active_Correlation_Key__c
      Workflow_Instance__c origParent = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :originalParentId
      ];
      origParent.Status__c = 'Completed';
      update origParent;
      origParent.Terminal_At__c = DateTime.now().addDays(-2);
      update origParent;

      // 2. Start a downstream/child workflow with the SAME correlation key, caused by the parent key
      WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
        'WorkflowEngineTest.HappyWorkflow',
        'ReusedKeySame',
        null
      );
      childReq.causationId = 'key:ReusedKeySame';
      Id childId = WorkflowEngine.startOrGet(
          new List<WorkflowEngine.StartRequest>{ childReq }
        )[0]
        .instanceId;

      // Set CreatedDates so child is newer
      Test.setCreatedDate(originalParentId, DateTime.now().addMinutes(-10));
      Test.setCreatedDate(childId, DateTime.now());

      // Get causation lineage on Child. It should NOT resolve to itself, but correctly walk up to originalParentId.
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        childId
      );
      System.assertEquals(2, lineage.size(), 'Must walk up to parent');
      System.assertEquals(childId, lineage[0].instanceId);
      System.assertEquals(
        originalParentId,
        lineage[1].instanceId,
        'Must resolve to the parent and not self'
      );
    }
  }

  @IsTest
  static void testCausationIdLooksLikeIdFallback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Get key prefix for Workflow_Instance__c (usually 'a01' or 'a00')
      String prefix = Workflow_Instance__c.SObjectType.getDescribe(
          SObjectDescribeOptions.DEFERRED
        )
        .getKeyPrefix();
      // Pad to 15 characters to make it look like a valid Salesforce ID
      String lookalikeId = prefix + '000000000000';

      // 1. Create parent with this lookalike correlation key
      Id parentId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        lookalikeId,
        null
      );

      // 2. Start child caused by the lookalike correlation key
      WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
        'WorkflowEngineTest.HappyWorkflow',
        'ChildKey',
        null
      );
      childReq.causationId = 'key:' + lookalikeId;
      Id childId = WorkflowEngine.startOrGet(
          new List<WorkflowEngine.StartRequest>{ childReq }
        )[0]
        .instanceId;

      // Get causation lineage on Child.
      // Even though lookalikeId is a valid ID syntax, it does not exist in the database,
      // so getCausationLineage should fall back to key-based query and resolve to parentId.
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        childId
      );
      System.assertEquals(
        2,
        lineage.size(),
        'Must walk up to parent via fallback key lookup'
      );
      System.assertEquals(childId, lineage[0].instanceId);
      System.assertEquals(parentId, lineage[1].instanceId);
    }
  }

  @IsTest
  static void testCausationIdInheritedOnContinueAsNewReusedKeyTimeBound() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Create original parent
      Id originalParentId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'ParentKeyReused',
        null
      );

      // Make original parent complete to release the key
      Workflow_Instance__c origParent = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :originalParentId
      ];
      origParent.Status__c = 'Completed';
      update origParent;
      origParent.Terminal_At__c = DateTime.now().addDays(-2);
      update origParent;

      // 2. Start Child caused by 'ParentKeyReused'
      WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
        'WorkflowEngineMocksBTest.DaemonWorkflow',
        'ChildDaemonKey',
        (Object) 0
      );
      childReq.causationId = 'key:ParentKeyReused';
      Id childId = WorkflowEngine.startOrGet(
          new List<WorkflowEngine.StartRequest>{ childReq }
        )[0]
        .instanceId;

      // Execute run -> triggers continueAsNew, spawning successor
      new WorkflowOrchestrator(childId).execute(null);

      // Find Run 2 of Child (successor)
      Workflow_Instance__c run2 = [
        SELECT Id, Status__c, Causation_Id__c, Previous_Instance__c
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :childId
      ];
      System.assert(
        run2.Causation_Id__c.startsWith('key:{"') &&
        run2.Causation_Id__c.contains('"k":"ParentKeyReused"')
      );

      // 3. Create a NEW parent run with the same key AFTER the child was created
      Id newerParentId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'ParentKeyReused',
        null
      );

      // Explicitly set CreatedDates to order them in the past:
      // originalParent (30 mins ago) -> child/predecessor (20 mins ago) -> newParent (10 mins ago) -> run2 (5 mins ago)
      Test.setCreatedDate(originalParentId, DateTime.now().addMinutes(-30));
      Test.setCreatedDate(childId, DateTime.now().addMinutes(-20));
      Test.setCreatedDate(newerParentId, DateTime.now().addMinutes(-10));
      Test.setCreatedDate(run2.Id, DateTime.now().addMinutes(-5));

      // Update run2's Causation_Id__c timestamp to match predecessor's mocked CreatedDate
      run2.Causation_Id__c =
        'key:ParentKeyReused::ts::' +
        String.valueOf(DateTime.now().addMinutes(-20).getTime());
      update run2;

      // Get causation lineage on successor (run2).
      // Because lineage lookup bounds key resolution by the earliest predecessor creation time (5 mins ago),
      // it should resolve to originalParentId (10 mins ago) and NOT newerParentId (now).
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        run2.Id
      );
      System.assertEquals(
        2,
        lineage.size(),
        'Lineage walk must resolve to the original parent'
      );
      System.assertEquals(run2.Id, lineage[0].instanceId);
      System.assertEquals(
        originalParentId,
        lineage[1].instanceId,
        'Must resolve to original parent and not newer parent with reused key'
      );
    }
  }

  @IsTest
  static void testCausationIdInheritedOnContinueAsNewReusedKeyTimeBoundCapped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Create a chain of 7 instances linked by Previous_Instance__c.
      // Build all records first and bulk-insert them, then link each to its
      // predecessor via a single bulk update. This keeps the stored data
      // identical (chain[i].Previous_Instance__c = chain[i - 1].Id) while
      // avoiding DML inside the loop.
      List<Workflow_Instance__c> chain = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 7; i++) {
        chain.add(
          new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Correlation_Key__c = 'ChainKey-' + i,
            Causation_Id__c = 'ParentKey'
          )
        );
      }
      insert chain;
      for (Integer i = 1; i < chain.size(); i++) {
        chain[i].Previous_Instance__c = chain[i - 1].Id;
      }
      update chain;

      // Run getCausationLineage on the last item.
      // It should not throw any exceptions (governor limits) and should complete successfully.
      Test.startTest();
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        chain[6].Id
      );
      Test.stopTest();

      System.assertNotEquals(
        null,
        lineage,
        'Lineage must be returned successfully'
      );
    }
  }

  @IsTest
  static void testCausationIdInheritedOnContinueAsNewReusedKeyTimeBoundLongChain() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Create original parent
      Id originalParentId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'ParentKeyReusedLong',
        null
      );

      // Make original parent complete to release the key
      Workflow_Instance__c origParent = [
        SELECT Status__c
        FROM Workflow_Instance__c
        WHERE Id = :originalParentId
      ];
      origParent.Status__c = 'Completed';
      update origParent;
      origParent.Terminal_At__c = DateTime.now().addDays(-2);
      update origParent;

      // 2. Create a chain of 8 continue-as-new instances caused by 'ParentKeyReusedLong'.
      // Build all records first and bulk-insert them, then link each to its
      // predecessor via a single bulk update. This keeps the stored data
      // identical (chain[i].Previous_Instance__c = chain[i - 1].Id) while
      // avoiding DML inside the loop.
      List<Workflow_Instance__c> chain = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 8; i++) {
        chain.add(
          new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Correlation_Key__c = 'ChainDaemonKey-' + i,
            Causation_Id__c = 'key:ParentKeyReusedLong::ts::' +
              String.valueOf(DateTime.now().addMinutes(-20).getTime())
          )
        );
      }
      insert chain;
      for (Integer i = 1; i < chain.size(); i++) {
        chain[i].Previous_Instance__c = chain[i - 1].Id;
      }
      update chain;

      // 3. Create a NEW parent run with the same key AFTER the child was created
      Id newerParentId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'ParentKeyReusedLong',
        null
      );

      // Explicitly set CreatedDates to order them in the past:
      // originalParent (30 mins ago) -> first run (20 mins ago) -> newParent (10 mins ago) -> last run (5 mins ago)
      Test.setCreatedDate(originalParentId, DateTime.now().addMinutes(-30));
      Test.setCreatedDate(chain[0].Id, DateTime.now().addMinutes(-20));
      Test.setCreatedDate(newerParentId, DateTime.now().addMinutes(-10));
      Test.setCreatedDate(chain[7].Id, DateTime.now().addMinutes(-5));

      // Get causation lineage on the last run of the chain.
      // Because we bulk-query 5 levels at a time, we will successfully walk back all 8 levels to the first run (5 mins ago),
      // and correctly resolve to originalParentId (10 mins ago) instead of newerParentId (now).
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        chain[7].Id
      );
      System.assertEquals(
        2,
        lineage.size(),
        'Lineage walk must resolve to the original parent'
      );
      System.assertEquals(chain[7].Id, lineage[0].instanceId);
      System.assertEquals(
        originalParentId,
        lineage[1].instanceId,
        'Must resolve to original parent and not newer parent with reused key'
      );
    }
  }

  @IsTest
  static void testCausationIdTimestampPropagationAndLineage() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Start a parent workflow
      Id parentId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'MyRealParentKey',
        null
      );

      // 2. Start a child with a key-based causation ID
      WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
        'WorkflowEngineTest.HappyWorkflow',
        'MyChildKey',
        null
      );
      childReq.causationId = 'key:MyRealParentKey';
      Id childId = WorkflowEngine.startOrGet(
          new List<WorkflowEngine.StartRequest>{ childReq }
        )[0]
        .instanceId;

      // Verify child instance contains the causationId with the timestamp
      Workflow_Instance__c childInst = [
        SELECT Causation_Id__c, CreatedDate
        FROM Workflow_Instance__c
        WHERE Id = :childId
      ];
      System.assert(
        childInst.Causation_Id__c.startsWith('key:{"') &&
        childInst.Causation_Id__c.contains('"k":"MyRealParentKey"'),
        'CausationId was actually: ' + childInst.Causation_Id__c
      );

      // 3. Resolve lineage and verify it correctly parses and matches to parentId,
      // and returns the clean causationId in the DTO.
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        childId
      );
      System.assertEquals(2, lineage.size());
      System.assertEquals(parentId, lineage[1].instanceId);
      System.assertEquals('key:MyRealParentKey', lineage[0].causationId);
    }
  }

  @IsTest
  static void testCausationIdWithHashInKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Start a parent workflow with a key containing '#'
      Id parentId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'order#123',
        null
      );

      // 2. Start a child with a key-based causation ID referencing 'order#123'
      WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
        'WorkflowEngineTest.HappyWorkflow',
        'MyChildKeyHash',
        null
      );
      childReq.causationId = 'key:order#123';
      Id childId = WorkflowEngine.startOrGet(
          new List<WorkflowEngine.StartRequest>{ childReq }
        )[0]
        .instanceId;

      // Verify child instance contains the causationId with the timestamp appended after order#123
      Workflow_Instance__c childInst = [
        SELECT Causation_Id__c
        FROM Workflow_Instance__c
        WHERE Id = :childId
      ];
      System.assert(
        childInst.Causation_Id__c.startsWith('key:{"') &&
        childInst.Causation_Id__c.contains('"k":"order#123"')
      );

      // 3. Resolve lineage and verify it correctly parses 'order#123' (preserving the '#' character) and resolves to parentId
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        childId
      );
      System.assertEquals(2, lineage.size());
      System.assertEquals(parentId, lineage[1].instanceId);
      System.assertEquals('key:order#123', lineage[0].causationId);
    }
  }

  @IsTest
  static void testCausationIdBulkStartRaceCondition() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Prepare a bulk start request containing both parent and child
      WorkflowEngine.StartRequest parentReq = new WorkflowEngine.StartRequest(
        'WorkflowEngineTest.HappyWorkflow',
        'BulkParentKey',
        null
      );

      WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
        'WorkflowEngineTest.HappyWorkflow',
        'BulkChildKey',
        null
      );
      childReq.causationId = 'key:BulkParentKey';

      // Start both workflows in the same bulk transaction
      List<WorkflowEngine.StartResult> results = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ parentReq, childReq }
      );
      Id parentId = results[0].instanceId;
      Id childId = results[1].instanceId;

      // Resolve lineage. Since the child's causation timestamp is stamped with the actual database CreatedDate
      // after insert, the parent is correctly resolved even without any buffer.
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        childId
      );
      System.assertEquals(2, lineage.size());
      System.assertEquals(parentId, lineage[1].instanceId);
    }
  }

  @IsTest
  static void testCausationIdResolveThroughChainRoot() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Insert parent run 1 (stale ContinuedAsNew)
      Workflow_Instance__c run1 = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Correlation_Key__c = 'ParentKeyRoot',
        Root_Correlation_Key__c = 'ParentKeyRoot',
        Status__c = 'ContinuedAsNew'
      );
      insert run1;
      Test.setCreatedDate(run1.Id, DateTime.now().addMinutes(-10));

      // 2. Insert parent run 2 (live completed successor)
      Workflow_Instance__c run2 = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Correlation_Key__c = 'ParentKeyRoot-1',
        Root_Correlation_Key__c = 'ParentKeyRoot',
        Previous_Instance__c = run1.Id,
        Status__c = 'Completed'
      );
      insert run2;
      Test.setCreatedDate(run2.Id, DateTime.now().addMinutes(-5));

      // 3. Start a child caused by the root key 'ParentKeyRoot'
      WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
        'WorkflowEngineTest.HappyWorkflow',
        'ChildKey',
        null
      );
      childReq.causationId = 'key:ParentKeyRoot';
      Id childId = WorkflowEngine.startOrGet(
          new List<WorkflowEngine.StartRequest>{ childReq }
        )[0]
        .instanceId;
      Test.setCreatedDate(childId, DateTime.now());

      // Resolve lineage. It should trace back to the terminal successor (run2) and NOT the stale predecessor (run1)
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        childId
      );
      System.assertEquals(2, lineage.size());
      System.assertEquals(run2.Id, lineage[1].instanceId);
      System.assertEquals('key:ParentKeyRoot', lineage[0].causationId);
    }
  }

  @IsTest
  static void testCausationIdWithNumericHashSuffixInKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Start a parent workflow with a key containing '#' followed by 13 digits
      Id parentId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'order#1234567890123',
        null
      );

      // 2. Start a child with a key-based causation ID referencing 'order#1234567890123'
      WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
        'WorkflowEngineTest.HappyWorkflow',
        'MyChildKeyNumericHash',
        null
      );
      childReq.causationId = 'key:order#1234567890123';
      Id childId = WorkflowEngine.startOrGet(
          new List<WorkflowEngine.StartRequest>{ childReq }
        )[0]
        .instanceId;

      // Verify child instance contains the causationId with the ::ts:: suffix appended after the full key
      Workflow_Instance__c childInst = [
        SELECT Causation_Id__c
        FROM Workflow_Instance__c
        WHERE Id = :childId
      ];
      System.assert(
        childInst.Causation_Id__c.startsWith('key:{"') &&
        childInst.Causation_Id__c.contains('"k":"order#1234567890123"')
      );

      // 3. Resolve lineage and verify it correctly parses 'order#1234567890123' (preserving the '#' and 13 digits) and resolves to parentId
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        childId
      );
      System.assertEquals(2, lineage.size());
      System.assertEquals(parentId, lineage[1].instanceId);
      System.assertEquals('key:order#1234567890123', lineage[0].causationId);
    }
  }

  @IsTest
  static void testCausationIdWithDelimiterInKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Start a parent workflow with a key containing '::ts::'
      Id parentId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'order::ts::prod',
        null
      );

      // 2. Start a child with a key-based causation ID referencing 'order::ts::prod'
      WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
        'WorkflowEngineTest.HappyWorkflow',
        'MyChildKeyDelimiter',
        null
      );
      childReq.causationId = 'key:order::ts::prod';
      Id childId = WorkflowEngine.startOrGet(
          new List<WorkflowEngine.StartRequest>{ childReq }
        )[0]
        .instanceId;

      // Verify child instance contains the causationId with the ::ts:: suffix appended after the full key
      Workflow_Instance__c childInst = [
        SELECT Causation_Id__c
        FROM Workflow_Instance__c
        WHERE Id = :childId
      ];
      System.assert(
        childInst.Causation_Id__c.startsWith('key:{"') &&
        childInst.Causation_Id__c.contains('"k":"order::ts::prod"')
      );

      // 3. Resolve lineage and verify it correctly parses 'order::ts::prod' (preserving the '::ts::prod' prefix) and resolves to parentId
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        childId
      );
      System.assertEquals(2, lineage.size());
      System.assertEquals(parentId, lineage[1].instanceId);
      System.assertEquals('key:order::ts::prod', lineage[0].causationId);
    }
  }

  @IsTest
  static void testCausationIdWithTimestampShapedKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // 1. Start a parent workflow with a key that literally ends with ::ts::<timestamp>
      WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'order::ts::1719859200000',
        null
      );

      // 2. Start a child with a key-based causation ID referencing 'order::ts::1719859200000'
      WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
        'WorkflowEngineTest.HappyWorkflow',
        'MyChildKeyTimestampShaped',
        null
      );
      childReq.causationId = 'key:order::ts::1719859200000';
      Id childId = WorkflowEngine.startOrGet(
          new List<WorkflowEngine.StartRequest>{ childReq }
        )[0]
        .instanceId;

      // Verify child instance contains the causationId with the JSON envelope, preserving the full key
      Workflow_Instance__c childInst = [
        SELECT Causation_Id__c
        FROM Workflow_Instance__c
        WHERE Id = :childId
      ];
      System.assert(
        childInst.Causation_Id__c.startsWith('key:{"') &&
        childInst.Causation_Id__c.contains('"k":"order::ts::1719859200000"')
      );

      // 3. Resolve lineage and verify it correctly parses 'order::ts::1719859200000' (preserving the full key) and resolves to parentId
      List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
        childId
      );
      System.assertEquals(2, lineage.size());
    }
  }
}
