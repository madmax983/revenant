@IsTest
private class WorkflowGetOrStartTest {
  // ==========================================
  // Helpers
  // ==========================================
  private static Integer stepExecCount(Id instanceId) {
    return [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
    ];
  }

  private static Integer totalInstancesForKey(String key) {
    return [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :key
    ];
  }

  // ==========================================
  // AC #1 / #5: get-or-start returns existing active instance instead of throwing
  // ==========================================
  @IsTest
  static void testActiveDuplicateReturnsExistingNotThrow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      WorkflowEngine.StartResult first = WorkflowEngine.startOrGet(
        'WorkflowEngineTest.HappyWorkflow',
        'GOS_Active',
        null
      );
      System.assertEquals(true, first.isNew, 'First start should be new');
      System.assertNotEquals(null, first.instanceId);

      Integer execsBefore = stepExecCount(first.instanceId);
      Integer enqueuesBefore = Limits.getQueueableJobs();

      // Redelivery while the first is still active (Pending)
      WorkflowEngine.StartResult second = WorkflowEngine.startOrGet(
        'WorkflowEngineTest.HappyWorkflow',
        'GOS_Active',
        null
      );

      System.assertEquals(
        first.instanceId,
        second.instanceId,
        'Active duplicate must resolve to the existing instance Id'
      );
      System.assertEquals(
        false,
        second.isNew,
        'Active duplicate must be reported as existing (isNew=false)'
      );
      // AC #6: zero step-execution writes and zero enqueues for the duplicate
      System.assertEquals(
        execsBefore,
        stepExecCount(first.instanceId),
        'Deduped start must not write a Workflow_Step_Execution__c'
      );
      System.assertEquals(
        enqueuesBefore,
        Limits.getQueueableJobs(),
        'Deduped start must not enqueue an orchestrator'
      );
      System.assertEquals(
        1,
        totalInstancesForKey('GOS_Active'),
        'Exactly one instance should exist for the key'
      );
    }
  }

  // ==========================================
  // AC #2: dedup covers recently-terminal instances within the window
  // ==========================================
  @IsTest
  static void testTerminalDuplicateWithinWindowReturnsExisting() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.dedupWindowMinutes = 1440;

      // Run an instance to completion
      Id id1 = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'GOS_TermIn',
        null
      );
      WorkflowEngine.runStep(id1, null);
      WorkflowEngine.runStep(id1, null);
      System.assertEquals(
        'Completed',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :id1].Status__c
      );

      Integer execsBefore = stepExecCount(id1);

      // Redelivery after completion, within window -> resolves to original
      WorkflowEngine.StartResult redelivered = WorkflowEngine.startOrGet(
        'WorkflowEngineTest.HappyWorkflow',
        'GOS_TermIn',
        null
      );

      System.assertEquals(
        id1,
        redelivered.instanceId,
        'Redelivery within window must resolve to the original instance'
      );
      System.assertEquals(false, redelivered.isNew);
      System.assertEquals(
        execsBefore,
        stepExecCount(id1),
        'Deduped terminal start must not re-run side effects (no new step execs)'
      );
      System.assertEquals(
        1,
        totalInstancesForKey('GOS_TermIn'),
        'No duplicate instance should be created within the window'
      );
    }
  }

  // ==========================================
  // AC #3: minimum window preserves active-only behavior
  // ==========================================
  @IsTest
  static void testTerminalDuplicateOutsideWindowStartsNew() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.dedupWindowMinutes = 0; // minimum -> active-only

      Id id1 = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'GOS_TermOut',
        null
      );
      WorkflowEngine.runStep(id1, null);
      WorkflowEngine.runStep(id1, null);
      System.assertEquals(
        'Completed',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :id1].Status__c
      );

      // With the window disabled, a post-completion start creates a new instance
      WorkflowEngine.StartResult res = WorkflowEngine.startOrGet(
        'WorkflowEngineTest.HappyWorkflow',
        'GOS_TermOut',
        null
      );

      System.assertNotEquals(
        id1,
        res.instanceId,
        'With window disabled, a terminal key must start a new instance'
      );
      System.assertEquals(true, res.isNew);
      System.assertEquals(2, totalInstancesForKey('GOS_TermOut'));
    }
  }

  // ==========================================
  // AC #7: blank correlation key validation is unchanged (no dedup possible)
  // ==========================================
  @IsTest
  static void testBlankKeyValidationUnchanged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Boolean threw = false;
      try {
        WorkflowEngine.startOrGet('WorkflowEngineTest.HappyWorkflow', '', null);
      } catch (WorkflowEngine.WorkflowException ex) {
        threw = true;
        System.assert(ex.getMessage().contains('Correlation key is required'));
      }
      System.assert(
        threw,
        'Blank key must retain existing validation behavior'
      );
    }
  }

  // ==========================================
  // AC #1 / #4 (bulk): one duplicate key never faults sibling requests
  // ==========================================
  @IsTest
  static void testBulkDedupDoesNotFaultSiblings() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Pre-existing active instance for one of the keys
      Id existingId = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'GOS_BulkDup',
        null
      );

      List<WorkflowEngine.StartRequest> reqs = new List<WorkflowEngine.StartRequest>{
        new WorkflowEngine.StartRequest(
          'WorkflowEngineTest.HappyWorkflow',
          'GOS_BulkDup',
          null
        ),
        new WorkflowEngine.StartRequest(
          'WorkflowEngineTest.HappyWorkflow',
          'GOS_BulkNew',
          null
        )
      };

      List<WorkflowEngine.StartResult> results = WorkflowEngine.startOrGet(
        reqs
      );

      System.assertEquals(2, results.size());
      // First request deduped to the existing instance
      System.assertEquals(existingId, results[0].instanceId);
      System.assertEquals(false, results[0].isNew);
      // Sibling unaffected: a brand-new instance was started
      System.assertNotEquals(null, results[1].instanceId);
      System.assertEquals(true, results[1].isNew);
      System.assertEquals(1, totalInstancesForKey('GOS_BulkDup'));
      System.assertEquals(1, totalInstancesForKey('GOS_BulkNew'));
    }
  }

  // ==========================================
  // AC #5 (bulk intra-batch): duplicate keys in one invocation -> one instance
  // ==========================================
  @IsTest
  static void testBulkIntraBatchDuplicateKeyYieldsOneInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      List<WorkflowEngine.StartRequest> reqs = new List<WorkflowEngine.StartRequest>{
        new WorkflowEngine.StartRequest(
          'WorkflowEngineTest.HappyWorkflow',
          'GOS_Intra',
          null
        ),
        new WorkflowEngine.StartRequest(
          'WorkflowEngineTest.HappyWorkflow',
          'GOS_Intra',
          null
        )
      };

      List<WorkflowEngine.StartResult> results = WorkflowEngine.startOrGet(
        reqs
      );

      System.assertEquals(2, results.size());
      System.assertEquals(
        results[0].instanceId,
        results[1].instanceId,
        'Both intra-batch duplicates must resolve to the same instance'
      );
      System.assertEquals(
        true,
        results[0].isNew,
        'First wins as the new instance'
      );
      System.assertEquals(false, results[1].isNew, 'Second is a dedup');
      System.assertEquals(
        1,
        totalInstancesForKey('GOS_Intra'),
        'Intra-batch duplicate keys must yield exactly one instance'
      );
    }
  }

  // ==========================================
  // AC #1 backward-compat: legacy start() returns the existing Id (no throw)
  // ==========================================
  @IsTest
  static void testLegacyStartReturnsExistingIdOnDuplicate() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Id id1 = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'GOS_Legacy',
        null
      );
      Id id2 = WorkflowEngine.start(
        'WorkflowEngineTest.HappyWorkflow',
        'GOS_Legacy',
        null
      );

      System.assertEquals(
        id1,
        id2,
        'Legacy start() must return the existing Id'
      );
      System.assertEquals(1, totalInstancesForKey('GOS_Legacy'));
    }
  }

  // ==========================================
  // Review fix (P2): correlation keys dedup case-insensitively
  // ==========================================
  @IsTest
  static void testGetOrStartCaseInsensitiveKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      WorkflowEngine.StartResult first = WorkflowEngine.startOrGet(
        'WorkflowEngineTest.HappyWorkflow',
        'MixedCaseKey',
        null
      );
      System.assertEquals(true, first.isNew);

      // Redelivery with different casing must resolve to the same instance, since
      // Correlation_Key__c is case-insensitive.
      WorkflowEngine.StartResult second = WorkflowEngine.startOrGet(
        'WorkflowEngineTest.HappyWorkflow',
        'mixedcasekey',
        null
      );
      System.assertEquals(
        first.instanceId,
        second.instanceId,
        'A different-cased key must dedup to the same instance'
      );
      System.assertEquals(false, second.isNew);
    }
  }

  // ==========================================
  // Review fix (P2): case-variant duplicate keys in one batch -> one instance
  // ==========================================
  @IsTest
  static void testBulkCaseInsensitiveIntraBatch() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      List<WorkflowEngine.StartRequest> reqs = new List<WorkflowEngine.StartRequest>{
        new WorkflowEngine.StartRequest(
          'WorkflowEngineTest.HappyWorkflow',
          'BatchCase',
          null
        ),
        new WorkflowEngine.StartRequest(
          'WorkflowEngineTest.HappyWorkflow',
          'batchcase',
          null
        )
      };

      List<WorkflowEngine.StartResult> results = WorkflowEngine.startOrGet(
        reqs
      );

      System.assertEquals(
        results[0].instanceId,
        results[1].instanceId,
        'Case-variant duplicate keys in one batch must yield one instance'
      );
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Correlation_Key__c IN ('BatchCase', 'batchcase')
        ],
        'Only one instance should exist across the case variants'
      );
    }
  }

  // ==========================================
  // Review fix (P1): startSingleton ignores the terminal dedup window
  // ==========================================
  @IsTest
  static void testStartSingletonIgnoresTerminalWindow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.dedupWindowMinutes = 1440;

      // A recent terminal instance for the singleton key (window would cover it)
      Workflow_Instance__c terminal = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Status__c = 'Completed',
        Correlation_Key__c = 'GOS_Singleton'
      );
      insert terminal;

      Id newId = WorkflowEngine.startSingleton(
        'WorkflowEngineTest.HappyWorkflow',
        'GOS_Singleton',
        null
      );

      System.assertNotEquals(
        terminal.Id,
        newId,
        'Singleton start must not resolve to a terminal instance in the window'
      );
      System.assertEquals(
        2,
        totalInstancesForKey('GOS_Singleton'),
        'A fresh singleton instance must be started alongside the terminal one'
      );
    }
  }

  // ==========================================
  // Review fix (P2): many terminal rows for a key still dedup to one instance
  // (single-key lookup is row-bounded to the newest match)
  // ==========================================
  @IsTest
  static void testTerminalDedupWithMultipleTerminalRows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.dedupWindowMinutes = 1440;

      List<Workflow_Instance__c> terminals = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 3; i++) {
        terminals.add(
          new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Completed',
            Correlation_Key__c = 'GOS_MultiTerm'
          )
        );
      }
      insert terminals;

      WorkflowEngine.StartResult res = WorkflowEngine.startOrGet(
        'WorkflowEngineTest.HappyWorkflow',
        'GOS_MultiTerm',
        null
      );

      System.assertEquals(
        false,
        res.isNew,
        'Should dedup to an existing terminal instance'
      );
      Set<Id> termIds = new Set<Id>();
      for (Workflow_Instance__c t : terminals) {
        termIds.add(t.Id);
      }
      System.assert(
        termIds.contains(res.instanceId),
        'Must dedup to one of the existing terminal instances'
      );
      System.assertEquals(
        3,
        totalInstancesForKey('GOS_MultiTerm'),
        'No new instance should be created'
      );
    }
  }

  // ==========================================
  // Review fix (P2): in bulk, a hot key's many terminal rows must not crowd a
  // sibling key out of terminal dedup (per-key resolution)
  // ==========================================
  @IsTest
  static void testBulkTerminalDedupPerKeyNoCrowdOut() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.dedupWindowMinutes = 1440;

      List<Workflow_Instance__c> seed = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 5; i++) {
        seed.add(
          new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Completed',
            Correlation_Key__c = 'GOS_HotA'
          )
        );
      }
      seed.add(
        new Workflow_Instance__c(
          Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
          Status__c = 'Completed',
          Correlation_Key__c = 'GOS_ColdB'
        )
      );
      insert seed;

      List<WorkflowEngine.StartRequest> reqs = new List<WorkflowEngine.StartRequest>{
        new WorkflowEngine.StartRequest(
          'WorkflowEngineTest.HappyWorkflow',
          'GOS_HotA',
          null
        ),
        new WorkflowEngine.StartRequest(
          'WorkflowEngineTest.HappyWorkflow',
          'GOS_ColdB',
          null
        )
      };

      List<WorkflowEngine.StartResult> results = WorkflowEngine.startOrGet(
        reqs
      );

      System.assertEquals(2, results.size());
      System.assertEquals(
        false,
        results[0].isNew,
        'Hot key must dedup to an existing terminal instance'
      );
      System.assertEquals(
        false,
        results[1].isNew,
        'Cold key must also dedup (not crowded out by the hot key)'
      );
      System.assertEquals(
        5,
        totalInstancesForKey('GOS_HotA'),
        'No new instance for the hot key'
      );
      System.assertEquals(
        1,
        totalInstancesForKey('GOS_ColdB'),
        'No new instance for the cold key'
      );
    }
  }

  // ==========================================
  // Review fix (P2): a very large dedup window must not fault starts
  // ==========================================
  @IsTest
  static void testLargeDedupWindowDoesNotFault() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.dedupWindowMinutes = 999999999; // near the 9-digit maximum

      WorkflowEngine.StartResult res = WorkflowEngine.startOrGet(
        'WorkflowEngineTest.HappyWorkflow',
        'GOS_BigWindow',
        null
      );

      System.assertNotEquals(
        null,
        res.instanceId,
        'A large dedup window must be clamped, not throw a DateTime range error'
      );
      System.assertEquals(true, res.isNew);
    }
  }
}
