@isTest
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
  @isTest
  static void testActiveDuplicateReturnsExistingNotThrow() {
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

  // ==========================================
  // AC #2: dedup covers recently-terminal instances within the window
  // ==========================================
  @isTest
  static void testTerminalDuplicateWithinWindowReturnsExisting() {
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

  // ==========================================
  // AC #3: minimum window preserves active-only behavior
  // ==========================================
  @isTest
  static void testTerminalDuplicateOutsideWindowStartsNew() {
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

  // ==========================================
  // AC #7: blank correlation key validation is unchanged (no dedup possible)
  // ==========================================
  @isTest
  static void testBlankKeyValidationUnchanged() {
    Boolean threw = false;
    try {
      WorkflowEngine.startOrGet('WorkflowEngineTest.HappyWorkflow', '', null);
    } catch (WorkflowEngine.WorkflowException ex) {
      threw = true;
      System.assert(ex.getMessage().contains('Correlation key is required'));
    }
    System.assert(threw, 'Blank key must retain existing validation behavior');
  }

  // ==========================================
  // AC #1 / #4 (bulk): one duplicate key never faults sibling requests
  // ==========================================
  @isTest
  static void testBulkDedupDoesNotFaultSiblings() {
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

    List<WorkflowEngine.StartResult> results = WorkflowEngine.startOrGet(reqs);

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

  // ==========================================
  // AC #5 (bulk intra-batch): duplicate keys in one invocation -> one instance
  // ==========================================
  @isTest
  static void testBulkIntraBatchDuplicateKeyYieldsOneInstance() {
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

    List<WorkflowEngine.StartResult> results = WorkflowEngine.startOrGet(reqs);

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

  // ==========================================
  // AC #1 backward-compat: legacy start() returns the existing Id (no throw)
  // ==========================================
  @isTest
  static void testLegacyStartReturnsExistingIdOnDuplicate() {
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

    System.assertEquals(id1, id2, 'Legacy start() must return the existing Id');
    System.assertEquals(1, totalInstancesForKey('GOS_Legacy'));
  }
}
