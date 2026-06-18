@isTest
private class WorkflowEngineGetStatusTest {
  private static final String OFFLOAD_PREFIX = '{"$attachmentId":';

  // ─── helpers ─────────────────────────────────────────────────────────────

  private static Workflow_Instance__c makeInstance(
    String status,
    String correlationKey,
    String output,
    String errorMessage
  ) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineGetStatusTest.StubWorkflow',
      Status__c = status,
      Correlation_Key__c = correlationKey,
      Output__c = output,
      Error_Message__c = errorMessage
    );
    // Active instances carry Active_Correlation_Key__c; terminal ones have it cleared.
    if (
      new Set<String>{
          'Pending',
          'Running',
          'Suspended',
          'Compensating',
          'Cancelling',
          'CompensationFailed'
        }
        .contains(status)
    ) {
      inst.Active_Correlation_Key__c = correlationKey;
    }
    insert as system inst;
    return inst;
  }

  // ─── getStatus(Id) ────────────────────────────────────────────────────────

  @isTest
  static void testGetStatusById_Completed() {
    Workflow_Instance__c inst = makeInstance(
      'Completed',
      'key-completed-1',
      '{"result":true}',
      null
    );

    Test.startTest();
    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);
    Test.stopTest();

    System.assertNotEquals(null, ws, 'Should return a DTO for a known Id');
    System.assertEquals(inst.Id, ws.instanceId);
    System.assertEquals(
      'WorkflowEngineGetStatusTest.StubWorkflow',
      ws.definitionName
    );
    System.assertEquals('key-completed-1', ws.correlationKey);
    System.assertEquals('Completed', ws.status);
    System.assertEquals(true, ws.isTerminal);
    System.assertEquals(null, ws.errorMessage);
    System.assertEquals('{"result":true}', ws.output);
  }

  @isTest
  static void testGetStatusById_Running_outputIsNull() {
    Workflow_Instance__c inst = makeInstance(
      'Running',
      'key-running-1',
      null,
      null
    );

    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);

    System.assertNotEquals(null, ws);
    System.assertEquals('Running', ws.status);
    System.assertEquals(false, ws.isTerminal);
    System.assertEquals(
      null,
      ws.output,
      'Output must be null for non-terminal'
    );
  }

  @isTest
  static void testGetStatusById_Suspended_outputIsNull() {
    Workflow_Instance__c inst = makeInstance(
      'Suspended',
      'key-suspended-1',
      null,
      null
    );

    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);

    System.assertEquals(false, ws.isTerminal);
    System.assertEquals(null, ws.output);
  }

  @isTest
  static void testGetStatusById_Failed_errorMessagePopulated() {
    Workflow_Instance__c inst = makeInstance(
      'Failed',
      'key-failed-1',
      null,
      'NullPointerException on line 42'
    );

    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);

    System.assertEquals('Failed', ws.status);
    System.assertEquals(true, ws.isTerminal);
    System.assertEquals('NullPointerException on line 42', ws.errorMessage);
  }

  @isTest
  static void testGetStatusById_Cancelled_isTerminal() {
    Workflow_Instance__c inst = makeInstance(
      'Cancelled',
      'key-cancelled-1',
      null,
      null
    );

    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);

    System.assertEquals(true, ws.isTerminal);
  }

  @isTest
  static void testGetStatusById_Compensated_isTerminal() {
    Workflow_Instance__c inst = makeInstance(
      'Compensated',
      'key-compensated-1',
      null,
      null
    );

    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);

    System.assertEquals(true, ws.isTerminal);
  }

  @isTest
  static void testGetStatusById_CompensationFailed_notTerminal() {
    Workflow_Instance__c inst = makeInstance(
      'CompensationFailed',
      'key-compfailed-1',
      null,
      null
    );

    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);

    System.assertEquals(
      false,
      ws.isTerminal,
      'CompensationFailed is not terminal'
    );
  }

  @isTest
  static void testGetStatusById_NotFound_returnsNull() {
    // Use a well-formed but non-existent Id (same key prefix as Workflow_Instance__c)
    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(
      (Id) (Workflow_Instance__c.SObjectType.getDescribe().getKeyPrefix() +
      '000000000001')
    );

    System.assertEquals(null, ws, 'Should return null for an unknown Id');
  }

  @isTest
  static void testGetStatusById_Completed_blankOutput_terminalFlag() {
    // AC4: isTerminal=true + blank output is different from a running instance
    Workflow_Instance__c inst = makeInstance(
      'Completed',
      'key-blank-output-1',
      '',
      null
    );

    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);

    System.assertEquals(true, ws.isTerminal);
    System.assertEquals(
      '',
      ws.output,
      'Blank output should be surfaced as blank, not null'
    );
  }

  // ─── getStatus(String) ────────────────────────────────────────────────────

  @isTest
  static void testGetStatusByKey_ActiveInstance() {
    Workflow_Instance__c inst = makeInstance(
      'Running',
      'key-by-string-active',
      null,
      null
    );

    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(
      'key-by-string-active'
    );

    System.assertNotEquals(null, ws);
    System.assertEquals(inst.Id, ws.instanceId);
    System.assertEquals('Running', ws.status);
  }

  @isTest
  static void testGetStatusByKey_TerminalInstance() {
    Workflow_Instance__c inst = makeInstance(
      'Completed',
      'key-by-string-done',
      '{"done":1}',
      null
    );

    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(
      'key-by-string-done'
    );

    System.assertNotEquals(null, ws);
    System.assertEquals(inst.Id, ws.instanceId);
    System.assertEquals(true, ws.isTerminal);
  }

  @isTest
  static void testGetStatusByKey_PrefersActiveOverTerminal() {
    // Same correlation key: one terminal, one active -- active should win
    makeInstance('Completed', 'key-prefer-active', '{"old":true}', null);
    Workflow_Instance__c activeInst = makeInstance(
      'Running',
      'key-prefer-active',
      null,
      null
    );

    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(
      'key-prefer-active'
    );

    System.assertEquals(
      activeInst.Id,
      ws.instanceId,
      'Active instance should be preferred over terminal one'
    );
  }

  @isTest
  static void testGetStatusByKey_NotFound_returnsNull() {
    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(
      'key-does-not-exist-xyz123'
    );

    System.assertEquals(null, ws);
  }

  @isTest
  static void testGetStatusByKey_Blank_returnsNull() {
    System.assertEquals(null, WorkflowEngine.getStatus(''));
    System.assertEquals(null, WorkflowEngine.getStatus((String) null));
  }

  @isTest
  static void testGetStatusByKey_CaseInsensitive() {
    // Correlation key fields are case-insensitive; a differently-cased lookup must
    // still resolve the stored instance.
    Workflow_Instance__c inst = makeInstance(
      'Completed',
      'Order-123',
      '{"ci":true}',
      null
    );

    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus('order-123');

    System.assertNotEquals(
      null,
      ws,
      'Differently-cased key should resolve the instance'
    );
    System.assertEquals(inst.Id, ws.instanceId);
    System.assertEquals('{"ci":true}', ws.output);
  }

  @isTest
  static void testGetStatusByKey_FollowsContinueAsNewViaRoot() {
    // Predecessor handed off via ContinuedAsNew (terminal-ish, no active key).
    Workflow_Instance__c predecessor = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineGetStatusTest.StubWorkflow',
      Status__c = 'ContinuedAsNew',
      Correlation_Key__c = 'PollerKey',
      Root_Correlation_Key__c = 'PollerKey'
    );
    insert as system predecessor;

    // Live/final successor: default continue-as-new key scheme renames to _run2 and
    // preserves the original as Root_Correlation_Key__c.
    Workflow_Instance__c successor = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineGetStatusTest.StubWorkflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'PollerKey_run2',
      Root_Correlation_Key__c = 'PollerKey',
      Output__c = '{"final":true}'
    );
    insert as system successor;

    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus('PollerKey');

    System.assertNotEquals(null, ws);
    System.assertEquals(
      successor.Id,
      ws.instanceId,
      'Polling the original key should resolve to the live/final successor'
    );
    System.assertEquals(true, ws.isTerminal);
    System.assertEquals('{"final":true}', ws.output);
  }

  @isTest
  static void testGetStatusByKey_FollowsMultiGenerationChainFromIntermediateKey() {
    // Chain: A (ContinuedAsNew) → A_run2 (ContinuedAsNew) → A_run3 (Completed).
    // Every generation shares Root_Correlation_Key__c = 'A'.
    Workflow_Instance__c gen1 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineGetStatusTest.StubWorkflow',
      Status__c = 'ContinuedAsNew',
      Correlation_Key__c = 'A',
      Root_Correlation_Key__c = 'A'
    );
    insert as system gen1;
    Workflow_Instance__c gen2 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineGetStatusTest.StubWorkflow',
      Status__c = 'ContinuedAsNew',
      Correlation_Key__c = 'A_run2',
      Root_Correlation_Key__c = 'A'
    );
    insert as system gen2;
    Workflow_Instance__c gen3 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineGetStatusTest.StubWorkflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'A_run3',
      Root_Correlation_Key__c = 'A',
      Output__c = '{"gen":3}'
    );
    insert as system gen3;

    // Polling the *intermediate* successor key must follow the chain to the final
    // generation, not return the stale ContinuedAsNew predecessor it names directly.
    WorkflowEngine.WorkflowStatus mid = WorkflowEngine.getStatus('A_run2');
    System.assertNotEquals(
      null,
      mid,
      'Intermediate key should resolve via the shared root'
    );
    System.assertEquals(
      gen3.Id,
      mid.instanceId,
      'Polling an intermediate key should follow the chain to the final generation'
    );
    System.assertEquals(true, mid.isTerminal);
    System.assertEquals('{"gen":3}', mid.output);

    // Polling the original root key resolves the same final generation.
    WorkflowEngine.WorkflowStatus rootWs = WorkflowEngine.getStatus('A');
    System.assertNotEquals(null, rootWs);
    System.assertEquals(gen3.Id, rootWs.instanceId);
    System.assertEquals('{"gen":3}', rootWs.output);
  }

  @isTest
  static void testBulkGetStatusByKeys_hotKeyDoesNotStarveOthers() {
    // Shrink the row cap so one hot key would fill a single global-LIMIT scan; the
    // per-key resolution must still resolve the other requested key (not return
    // null for it). The cap must leave room for one group per requested key.
    WorkflowEngine.DEDUP_LOOKUP_ROW_CAP = 2;

    // Cold key: a single, older terminal run.
    Workflow_Instance__c cold = makeInstance(
      'Completed',
      'cold-key',
      '{"c":1}',
      null
    );
    cold.Terminal_At__c = System.now().addHours(-1);
    update as system cold;

    // Hot key: several newer terminal runs that would dominate an ordered scan.
    for (Integer i = 0; i < 3; i++) {
      Workflow_Instance__c hot = makeInstance(
        'Completed',
        'hot-key',
        '{"h":' + i + '}',
        null
      );
      hot.Terminal_At__c = System.now();
      update as system hot;
    }

    List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
      new List<String>{ 'hot-key', 'cold-key' }
    );

    System.assertEquals(2, results.size());
    System.assertNotEquals(null, results[0], 'Hot key should resolve');
    System.assertEquals('hot-key', results[0].correlationKey);
    System.assertNotEquals(
      null,
      results[1],
      'Cold key must not be crowded out by the hot key'
    );
    System.assertEquals('cold-key', results[1].correlationKey);
    System.assertEquals(cold.Id, results[1].instanceId);
  }

  @isTest
  static void testBulkGetStatusByKeys_followsChainWhenPollingRootKey() {
    // gen1 hands off (ContinuedAsNew); the successor carries a different
    // correlation key but the shared root. The bulk path matches the polled root
    // by correlation key first (finding only the hand-off), so it must still expand
    // via the root to reach the live/final successor.
    Workflow_Instance__c gen1 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineGetStatusTest.StubWorkflow',
      Status__c = 'ContinuedAsNew',
      Correlation_Key__c = 'BulkRoot',
      Root_Correlation_Key__c = 'BulkRoot'
    );
    insert as system gen1;
    Workflow_Instance__c successor = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineGetStatusTest.StubWorkflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'BulkRoot_run2',
      Root_Correlation_Key__c = 'BulkRoot',
      Output__c = '{"final":true}'
    );
    insert as system successor;

    List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
      new List<String>{ 'BulkRoot', 'unrelated-key' }
    );

    System.assertEquals(2, results.size());
    System.assertNotEquals(null, results[0], 'Root key should resolve');
    System.assertEquals(
      successor.Id,
      results[0].instanceId,
      'Bulk polling the root key must follow the chain to the live successor'
    );
    System.assertEquals('{"final":true}', results[0].output);
    System.assertEquals(null, results[1], 'Unrelated key has no instance');
  }

  @isTest
  static void testBulkGetStatusByKeys_resolvesRootlessLegacyInstance() {
    // Simulate a legacy row created before the Root_Correlation_Key__c default: the
    // trigger only defaults on insert, so null it out via a follow-up update.
    Workflow_Instance__c legacy = makeInstance(
      'Completed',
      'legacy-rootless',
      '{"legacy":true}',
      null
    );
    legacy.Root_Correlation_Key__c = null;
    update as system legacy;

    Workflow_Instance__c other = makeInstance(
      'Running',
      'other-key',
      null,
      null
    );

    List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
      new List<String>{ 'legacy-rootless', 'other-key' }
    );

    System.assertEquals(2, results.size());
    System.assertNotEquals(
      null,
      results[0],
      'A rootless legacy row must resolve via its correlation key in bulk'
    );
    System.assertEquals(legacy.Id, results[0].instanceId);
    System.assertEquals('{"legacy":true}', results[0].output);
    System.assertEquals(other.Id, results[1].instanceId);
  }

  @isTest
  static void testBulkGetStatusByKeys_doesNotConflateReusedRoot() {
    // Chain: K (ContinuedAsNew) → K_run2 (Completed). Both share root 'K'.
    Workflow_Instance__c gen1 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineGetStatusTest.StubWorkflow',
      Status__c = 'ContinuedAsNew',
      Correlation_Key__c = 'K',
      Root_Correlation_Key__c = 'K'
    );
    insert as system gen1;
    Workflow_Instance__c kRun2 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineGetStatusTest.StubWorkflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'K_run2',
      Root_Correlation_Key__c = 'K',
      Output__c = '{"run2":true}'
    );
    insert as system kRun2;

    // A later, independent run reuses correlation key 'K' (root defaults to 'K'),
    // so it shares the chain root but is unrelated to K_run2.
    Workflow_Instance__c independentK = makeInstance(
      'Running',
      'K',
      null,
      null
    );

    // Two keys force the bulk path (a single-element list takes the single-key
    // fast path), which is where root-keyed conflation would occur.
    List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
      new List<String>{ 'K_run2', 'no-such-key' }
    );

    System.assertEquals(2, results.size());
    System.assertEquals(
      kRun2.Id,
      results[0].instanceId,
      'Polling K_run2 must return its own run, not the unrelated reused-K run'
    );
    System.assertEquals('{"run2":true}', results[0].output);
    System.assertEquals(null, results[1], 'Unrelated key has no instance');
  }

  // ─── Offload rehydration (AC3 + AC7) ─────────────────────────────────────

  @isTest
  static void testGetStatusById_OffloadedOutput_rehydratesTransparently() {
    String bigPayload = 'A'.repeat(110001);

    Workflow_Instance__c inst = makeInstance(
      'Completed',
      'key-offload-id',
      null,
      null
    );
    // Offload via the engine's own helper so the marker format is identical
    String marker = WorkflowEngine.savePayloadIfNeeded(
      inst.Id,
      bigPayload,
      'Output-' + inst.Id
    );
    inst.Output__c = marker;
    update as system inst;

    // Precondition: the stored value is a marker, not the real data
    System.assert(
      marker.startsWith(OFFLOAD_PREFIX),
      'Precondition: savePayloadIfNeeded should have returned a marker'
    );

    Test.startTest();
    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);
    Test.stopTest();

    System.assertNotEquals(null, ws);
    System.assertEquals(
      bigPayload,
      ws.output,
      'output should equal the full rehydrated payload, not the marker'
    );
    System.assert(
      !ws.output.startsWith(OFFLOAD_PREFIX),
      'Marker must never be surfaced to the caller'
    );
    System.assertEquals(110001, ws.output.length());
  }

  // ─── SOQL / DML bounds (AC5) ──────────────────────────────────────────────

  @isTest
  static void testGetStatusById_governorBounds_noOffload() {
    Workflow_Instance__c inst = makeInstance(
      'Completed',
      'key-gov-noop',
      '{"x":1}',
      null
    );

    Integer queriesBefore = Limits.getQueries();
    Integer dmlBefore = Limits.getDmlStatements();
    WorkflowEngine.getStatus(inst.Id);
    Integer queriesUsed = Limits.getQueries() - queriesBefore;
    Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;

    System.assertEquals(
      1,
      queriesUsed,
      'Should use exactly 1 SOQL for inline output'
    );
    System.assertEquals(0, dmlUsed, 'getStatus must perform zero DML');
  }

  @isTest
  static void testGetStatusById_governorBounds_offloadedOutput() {
    String bigPayload = 'B'.repeat(110001);
    Workflow_Instance__c inst = makeInstance(
      'Completed',
      'key-gov-offload',
      null,
      null
    );
    String marker = WorkflowEngine.savePayloadIfNeeded(
      inst.Id,
      bigPayload,
      'Output-' + inst.Id
    );
    inst.Output__c = marker;
    update as system inst;

    Integer queriesBefore = Limits.getQueries();
    Integer dmlBefore = Limits.getDmlStatements();
    WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);
    Integer queriesUsed = Limits.getQueries() - queriesBefore;
    Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;

    System.assert(
      queriesUsed <= 2,
      'Should use at most 2 SOQL queries (instance + ContentVersion): used ' +
      queriesUsed
    );
    System.assertEquals(0, dmlUsed, 'getStatus must perform zero DML');
    System.assertEquals(bigPayload, ws.output);
  }

  // ─── Bulk getStatus(List of Id) ──────────────────────────────────────────

  @isTest
  static void testBulkGetStatusByIds_mixed() {
    Workflow_Instance__c completed = makeInstance(
      'Completed',
      'key-bulk-id-done',
      '{"bulk":1}',
      null
    );
    Workflow_Instance__c running = makeInstance(
      'Running',
      'key-bulk-id-run',
      null,
      null
    );
    Workflow_Instance__c failed = makeInstance(
      'Failed',
      'key-bulk-id-fail',
      null,
      'err'
    );

    List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
      new List<Id>{ completed.Id, running.Id, failed.Id }
    );

    System.assertEquals(3, results.size());
    System.assertEquals('Completed', results[0].status);
    System.assertEquals(true, results[0].isTerminal);
    System.assertEquals('{"bulk":1}', results[0].output);
    System.assertEquals('Running', results[1].status);
    System.assertEquals(false, results[1].isTerminal);
    System.assertEquals(null, results[1].output);
    System.assertEquals('Failed', results[2].status);
    System.assertEquals('err', results[2].errorMessage);
  }

  @isTest
  static void testBulkGetStatusByIds_unknownIdYieldsNull() {
    Workflow_Instance__c inst = makeInstance(
      'Completed',
      'key-bulk-id-known',
      'out',
      null
    );
    Id unknownId = (Id) (Workflow_Instance__c.SObjectType.getDescribe()
      .getKeyPrefix() + '000000000099');

    List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
      new List<Id>{ inst.Id, unknownId }
    );

    System.assertEquals(2, results.size());
    System.assertNotEquals(null, results[0]);
    System.assertEquals(null, results[1], 'Unknown Id should yield null slot');
  }

  @isTest
  static void testBulkGetStatusByIds_emptyList() {
    List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
      new List<Id>()
    );
    System.assertEquals(0, results.size());
  }

  @isTest
  static void testBulkGetStatusByIds_offloadedOutputs_singleContentVersionQuery() {
    String big1 = 'X'.repeat(110001);
    String big2 = 'Y'.repeat(110001);

    Workflow_Instance__c inst1 = makeInstance(
      'Completed',
      'key-bulk-off-1',
      null,
      null
    );
    Workflow_Instance__c inst2 = makeInstance(
      'Completed',
      'key-bulk-off-2',
      null,
      null
    );

    inst1.Output__c = WorkflowEngine.savePayloadIfNeeded(
      inst1.Id,
      big1,
      'Out-' + inst1.Id
    );
    inst2.Output__c = WorkflowEngine.savePayloadIfNeeded(
      inst2.Id,
      big2,
      'Out-' + inst2.Id
    );
    update as system new List<Workflow_Instance__c>{ inst1, inst2 };

    Integer queriesBefore = Limits.getQueries();
    List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
      new List<Id>{ inst1.Id, inst2.Id }
    );
    Integer queriesUsed = Limits.getQueries() - queriesBefore;

    System.assert(
      queriesUsed <= 2,
      'Bulk fetch of 2 offloaded outputs should cost at most 2 SOQL: used ' +
      queriesUsed
    );
    System.assertEquals(big1, results[0].output);
    System.assertEquals(big2, results[1].output);
  }

  // ─── Bulk getStatus(List of String) ──────────────────────────────────────

  @isTest
  static void testBulkGetStatusByKeys_mixed() {
    Workflow_Instance__c done = makeInstance(
      'Completed',
      'key-bulk-str-done',
      '{"k":2}',
      null
    );
    Workflow_Instance__c running = makeInstance(
      'Running',
      'key-bulk-str-run',
      null,
      null
    );

    List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
      new List<String>{ 'key-bulk-str-done', 'key-bulk-str-run' }
    );

    System.assertEquals(2, results.size());
    System.assertEquals(done.Id, results[0].instanceId);
    System.assertEquals(true, results[0].isTerminal);
    System.assertEquals(running.Id, results[1].instanceId);
    System.assertEquals(false, results[1].isTerminal);
  }

  @isTest
  static void testBulkGetStatusByKeys_prefersActiveOverTerminal() {
    makeInstance('Completed', 'key-bulk-prefer', 'old', null);
    Workflow_Instance__c activeInst = makeInstance(
      'Running',
      'key-bulk-prefer',
      null,
      null
    );

    List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
      new List<String>{ 'key-bulk-prefer' }
    );

    System.assertEquals(
      activeInst.Id,
      results[0].instanceId,
      'Active instance should be preferred over terminal'
    );
  }

  @isTest
  static void testBulkGetStatusByKeys_missingKeyYieldsNull() {
    Workflow_Instance__c inst = makeInstance(
      'Completed',
      'key-bulk-str-known2',
      'v',
      null
    );

    List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
      new List<String>{ 'key-bulk-str-known2', 'key-not-exist-xyz987' }
    );

    System.assertEquals(2, results.size());
    System.assertNotEquals(null, results[0]);
    System.assertEquals(null, results[1], 'Missing key should yield null slot');
  }

  @isTest
  static void testBulkGetStatusByKeys_blankEntriesYieldNull() {
    Workflow_Instance__c inst = makeInstance(
      'Completed',
      'key-bulk-str-blank',
      'v',
      null
    );

    List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
      new List<String>{ 'key-bulk-str-blank', '', null }
    );

    System.assertEquals(3, results.size());
    System.assertNotEquals(null, results[0]);
    System.assertEquals(null, results[1], 'Blank key should yield null');
    System.assertEquals(null, results[2], 'Null key should yield null');
  }

  @isTest
  static void testBulkGetStatusByKeys_emptyList() {
    List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
      new List<String>()
    );
    System.assertEquals(0, results.size());
  }

  @isTest
  static void testBulkGetStatusByKeys_governorBounds_offloaded() {
    String big = 'Z'.repeat(110001);
    Workflow_Instance__c inst = makeInstance(
      'Completed',
      'key-bulk-str-gov',
      null,
      null
    );
    inst.Output__c = WorkflowEngine.savePayloadIfNeeded(
      inst.Id,
      big,
      'Out-' + inst.Id
    );
    update as system inst;

    Integer queriesBefore = Limits.getQueries();
    Integer dmlBefore = Limits.getDmlStatements();
    List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
      new List<String>{ 'key-bulk-str-gov' }
    );
    Integer queriesUsed = Limits.getQueries() - queriesBefore;
    Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;

    // The key path resolves the winner from metadata, then fetches the winner's
    // output and rehydrates the offload: a small constant (here metadata lookup +
    // winner fetch + ContentVersion = 3), independent of list size, zero DML.
    System.assert(
      queriesUsed <= 4,
      'Bulk-by-key with offloaded output should cost a small constant SOQL: used ' +
      queriesUsed
    );
    System.assertEquals(0, dmlUsed, 'getStatus must perform zero DML');
    System.assertEquals(big, results[0].output);
  }

  // ─── Single-record methods delegate to bulk (consistency check) ───────────

  @isTest
  static void testSingleDelegatesConsistentWithBulk() {
    Workflow_Instance__c inst = makeInstance(
      'Completed',
      'key-delegate-check',
      '{"consistent":true}',
      null
    );

    WorkflowEngine.WorkflowStatus single = WorkflowEngine.getStatus(inst.Id);
    List<WorkflowEngine.WorkflowStatus> bulkResults = WorkflowEngine.getStatus(
      new List<Id>{ inst.Id }
    );

    System.assertEquals(single.instanceId, bulkResults[0].instanceId);
    System.assertEquals(single.status, bulkResults[0].status);
    System.assertEquals(single.output, bulkResults[0].output);
    System.assertEquals(single.isTerminal, bulkResults[0].isTerminal);
  }

  // ─── Stub workflow inner class (required by makeInstance Workflow_Name__c) ─
  // Not actually executed; here so the class name resolves in this test context.
  public class StubWorkflow {
  }
}
