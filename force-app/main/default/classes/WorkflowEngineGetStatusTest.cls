@IsTest
private class WorkflowEngineGetStatusTest {
  private static final String OFFLOAD_PREFIX = '{"$attachmentId":';

  // ─── helpers ─────────────────────────────────────────────────────────────

  // Fluent builder replaces a wide positional helper: same records, no long
  // parameter list. build() inserts and returns the instance.
  private class InstanceBuilder {
    private String status;
    private String correlationKey;
    private String output;
    private String errorMessage;

    private InstanceBuilder status(String value) {
      this.status = value;
      return this;
    }

    private InstanceBuilder correlationKey(String value) {
      this.correlationKey = value;
      return this;
    }

    private InstanceBuilder output(String value) {
      this.output = value;
      return this;
    }

    private InstanceBuilder errorMessage(String value) {
      this.errorMessage = value;
      return this;
    }

    private Workflow_Instance__c build() {
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
  }

  // ─── getStatus(Id) ────────────────────────────────────────────────────────

  @IsTest
  static void testGetStatusByIdCompleted() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-completed-1')
        .output('{"result":true}')
        .errorMessage(null)
        .build();

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
  }

  @IsTest
  static void testGetStatusByIdRunningOutputIsNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Running')
        .correlationKey('key-running-1')
        .output(null)
        .errorMessage(null)
        .build();

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
  }

  @IsTest
  static void testGetStatusByIdSuspendedOutputIsNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Suspended')
        .correlationKey('key-suspended-1')
        .output(null)
        .errorMessage(null)
        .build();

      WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);

      System.assertEquals(false, ws.isTerminal);
      System.assertEquals(null, ws.output);
    }
  }

  @IsTest
  static void testGetStatusByIdFailedErrorMessagePopulated() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Failed')
        .correlationKey('key-failed-1')
        .output(null)
        .errorMessage('NullPointerException on line 42')
        .build();

      WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);

      System.assertEquals('Failed', ws.status);
      System.assertEquals(true, ws.isTerminal);
      System.assertEquals('NullPointerException on line 42', ws.errorMessage);
    }
  }

  @IsTest
  static void testGetStatusByIdCancelledIsTerminal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Cancelled')
        .correlationKey('key-cancelled-1')
        .output(null)
        .errorMessage(null)
        .build();

      WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);

      System.assertEquals(true, ws.isTerminal);
    }
  }

  @IsTest
  static void testGetStatusByIdCompensatedIsTerminal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Compensated')
        .correlationKey('key-compensated-1')
        .output(null)
        .errorMessage(null)
        .build();

      WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);

      System.assertEquals(true, ws.isTerminal);
    }
  }

  @IsTest
  static void testGetStatusByIdCompensationFailedNotTerminal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('CompensationFailed')
        .correlationKey('key-compfailed-1')
        .output(null)
        .errorMessage(null)
        .build();

      WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);

      System.assertEquals(
        false,
        ws.isTerminal,
        'CompensationFailed is not terminal'
      );
    }
  }

  @IsTest
  static void testGetStatusByIdNotFoundReturnsNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Use a well-formed but non-existent Id (same key prefix as Workflow_Instance__c)
      WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(
        (Id) (Workflow_Instance__c.SObjectType.getDescribe(
            SObjectDescribeOptions.DEFERRED
          )
          .getKeyPrefix() + '000000000001')
      );

      System.assertEquals(null, ws, 'Should return null for an unknown Id');
    }
  }

  @IsTest
  static void testGetStatusByIdCompletedBlankOutputTerminalFlag() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // AC4: isTerminal=true + blank output is different from a running instance
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-blank-output-1')
        .output('')
        .errorMessage(null)
        .build();

      WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(inst.Id);

      System.assertEquals(true, ws.isTerminal);
      System.assertEquals(
        '',
        ws.output,
        'Blank output should be surfaced as blank, not null'
      );
    }
  }

  // ─── getStatus(String) ────────────────────────────────────────────────────

  @IsTest
  static void testGetStatusByKeyActiveInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Running')
        .correlationKey('key-by-string-active')
        .output(null)
        .errorMessage(null)
        .build();

      WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(
        'key-by-string-active'
      );

      System.assertNotEquals(null, ws);
      System.assertEquals(inst.Id, ws.instanceId);
      System.assertEquals('Running', ws.status);
    }
  }

  @IsTest
  static void testGetStatusByKeyTerminalInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-by-string-done')
        .output('{"done":1}')
        .errorMessage(null)
        .build();

      WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(
        'key-by-string-done'
      );

      System.assertNotEquals(null, ws);
      System.assertEquals(inst.Id, ws.instanceId);
      System.assertEquals(true, ws.isTerminal);
    }
  }

  @IsTest
  static void testGetStatusByKeyPrefersActiveOverTerminal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Same correlation key: one terminal, one active -- active should win
      new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-prefer-active')
        .output('{"old":true}')
        .errorMessage(null)
        .build();
      Workflow_Instance__c activeInst = new InstanceBuilder()
        .status('Running')
        .correlationKey('key-prefer-active')
        .output(null)
        .errorMessage(null)
        .build();

      WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(
        'key-prefer-active'
      );

      System.assertEquals(
        activeInst.Id,
        ws.instanceId,
        'Active instance should be preferred over terminal one'
      );
    }
  }

  @IsTest
  static void testGetStatusByKeyNotFoundReturnsNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus(
        'key-does-not-exist-xyz123'
      );

      System.assertEquals(null, ws);
    }
  }

  @IsTest
  static void testGetStatusByKeyBlankReturnsNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(null, WorkflowEngine.getStatus(''));
      System.assertEquals(null, WorkflowEngine.getStatus((String) null));
    }
  }

  @IsTest
  static void testGetStatusByKeyCaseInsensitive() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Correlation key fields are case-insensitive; a differently-cased lookup must
      // still resolve the stored instance.
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Completed')
        .correlationKey('Order-123')
        .output('{"ci":true}')
        .errorMessage(null)
        .build();

      WorkflowEngine.WorkflowStatus ws = WorkflowEngine.getStatus('order-123');

      System.assertNotEquals(
        null,
        ws,
        'Differently-cased key should resolve the instance'
      );
      System.assertEquals(inst.Id, ws.instanceId);
      System.assertEquals('{"ci":true}', ws.output);
    }
  }

  @IsTest
  static void testGetStatusByKeyFollowsContinueAsNewViaRoot() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  @IsTest
  static void testGetStatusByKeyFollowsMultiGenerationChainFromIntermediateKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  @IsTest
  static void testBulkGetStatusByKeysHotKeyDoesNotStarveOthers() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Shrink the row cap so one hot key would fill a single global-LIMIT scan; the
      // per-key resolution must still resolve the other requested key (not return
      // null for it). The cap must leave room for one group per requested key.
      WorkflowEngine.dedupLookupRowCap = 2;

      // Anchor every age off one base so the CreatedDate values are exact and
      // distinct. Phase 1b of the bulk resolver keys on CreatedDate (not
      // Terminal_At__c), and all rows inserted in a single test transaction
      // otherwise share one CreatedDate — which collapses maxTimes to a single
      // value, makes every row match the bounded fetch, and lets the hot key's
      // extra rows crowd out the cold key under the LIMIT. Giving the hot key's
      // rows distinct CreatedDates means the GROUP BY keeps only its newest in
      // maxTimes, leaving a cap slot for the cold key (the property under test).
      Datetime base = System.now();

      // Cold key: a single, older terminal run.
      Workflow_Instance__c cold = new InstanceBuilder()
        .status('Completed')
        .correlationKey('cold-key')
        .output('{"c":1}')
        .errorMessage(null)
        .build();
      cold.Terminal_At__c = base.addHours(-1);
      update as system cold;
      Test.setCreatedDate(cold.Id, base.addHours(-1));

      // Hot key: several newer terminal runs that would dominate an ordered scan.
      // Distinct CreatedDates (-3, -2, -1 min) so only the newest is the group max.
      // Build the rows and their target created-dates in the loop, then apply the
      // update once in bulk (no per-iteration DML) before backdating each row.
      List<Workflow_Instance__c> hotRuns = new List<Workflow_Instance__c>();
      List<Datetime> hotCreatedDates = new List<Datetime>();
      for (Integer i = 0; i < 3; i++) {
        Workflow_Instance__c hot = new InstanceBuilder()
          .status('Completed')
          .correlationKey('hot-key')
          .output('{"h":' + i + '}')
          .errorMessage(null)
          .build();
        hot.Terminal_At__c = base;
        hotRuns.add(hot);
        hotCreatedDates.add(base.addMinutes(-(3 - i)));
      }
      update as system hotRuns;
      for (Integer i = 0; i < hotRuns.size(); i++) {
        Test.setCreatedDate(hotRuns[i].Id, hotCreatedDates[i]);
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
  }

  @IsTest
  static void testBulkGetStatusByKeysFollowsChainWhenPollingRootKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  @IsTest
  static void testBulkGetStatusByKeysResolvesRootlessLegacyInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Simulate a legacy row created before the Root_Correlation_Key__c default: the
      // trigger only defaults on insert, so null it out via a follow-up update.
      Workflow_Instance__c legacy = new InstanceBuilder()
        .status('Completed')
        .correlationKey('legacy-rootless')
        .output('{"legacy":true}')
        .errorMessage(null)
        .build();
      legacy.Root_Correlation_Key__c = null;
      update as system legacy;

      Workflow_Instance__c other = new InstanceBuilder()
        .status('Running')
        .correlationKey('other-key')
        .output(null)
        .errorMessage(null)
        .build();

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
  }

  @IsTest
  static void testBulkGetStatusByKeysDoesNotConflateReusedRoot() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
      new InstanceBuilder()
        .status('Running')
        .correlationKey('K')
        .output(null)
        .errorMessage(null)
        .build();

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
  }

  @IsTest
  static void testBulkGetStatusByKeysExpandsRootlessLegacyHandoff() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Legacy predecessor: blank root (pre-default), already handed off.
      Workflow_Instance__c legacy = new InstanceBuilder()
        .status('ContinuedAsNew')
        .correlationKey('legacy-chain')
        .output(null)
        .errorMessage(null)
        .build();
      legacy.Root_Correlation_Key__c = null;
      update as system legacy;

      // Successor inserted post-upgrade: continueAsNew sets its root to the
      // predecessor's own correlation key (the line 2995 fallback).
      Workflow_Instance__c successor = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineGetStatusTest.StubWorkflow',
        Status__c = 'Completed',
        Correlation_Key__c = 'legacy-chain_run2',
        Root_Correlation_Key__c = 'legacy-chain',
        Output__c = '{"legacyFinal":true}'
      );
      insert as system successor;

      List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
        new List<String>{ 'legacy-chain', 'no-such-key' }
      );

      System.assertEquals(2, results.size());
      System.assertEquals(
        successor.Id,
        results[0].instanceId,
        'A blank-root hand-off must still expand to its successor in bulk'
      );
      System.assertEquals(true, results[0].isTerminal);
      System.assertEquals('{"legacyFinal":true}', results[0].output);
    }
  }

  // ─── Offload rehydration (AC3 + AC7) ─────────────────────────────────────

  @IsTest
  static void testGetStatusByIdOffloadedOutputRehydratesTransparently() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String bigPayload = 'A'.repeat(110001);

      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-offload-id')
        .output(null)
        .errorMessage(null)
        .build();
      // Offload via the engine's own helper so the marker format is identical
      String marker = WorkflowPayloadOffload.savePayloadIfNeeded(
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
  }

  // ─── SOQL / DML bounds (AC5) ──────────────────────────────────────────────

  @IsTest
  static void testGetStatusByIdGovernorBoundsNoOffload() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-gov-noop')
        .output('{"x":1}')
        .errorMessage(null)
        .build();

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
  }

  @IsTest
  static void testGetStatusByIdGovernorBoundsOffloadedOutput() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String bigPayload = 'B'.repeat(110001);
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-gov-offload')
        .output(null)
        .errorMessage(null)
        .build();
      String marker = WorkflowPayloadOffload.savePayloadIfNeeded(
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
  }

  // ─── Bulk getStatus(List of Id) ──────────────────────────────────────────

  @IsTest
  static void testBulkGetStatusByIdsMixed() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c completed = new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-bulk-id-done')
        .output('{"bulk":1}')
        .errorMessage(null)
        .build();
      Workflow_Instance__c running = new InstanceBuilder()
        .status('Running')
        .correlationKey('key-bulk-id-run')
        .output(null)
        .errorMessage(null)
        .build();
      Workflow_Instance__c failed = new InstanceBuilder()
        .status('Failed')
        .correlationKey('key-bulk-id-fail')
        .output(null)
        .errorMessage('err')
        .build();

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
  }

  @IsTest
  static void testBulkGetStatusByIdsUnknownIdYieldsNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-bulk-id-known')
        .output('out')
        .errorMessage(null)
        .build();
      Id unknownId = (Id) (Workflow_Instance__c.SObjectType.getDescribe(
          SObjectDescribeOptions.DEFERRED
        )
        .getKeyPrefix() + '000000000099');

      List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
        new List<Id>{ inst.Id, unknownId }
      );

      System.assertEquals(2, results.size());
      System.assertNotEquals(null, results[0]);
      System.assertEquals(
        null,
        results[1],
        'Unknown Id should yield null slot'
      );
    }
  }

  @IsTest
  static void testBulkGetStatusByIdsEmptyList() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
        new List<Id>()
      );
      System.assertEquals(0, results.size());
    }
  }

  @IsTest
  static void testBulkGetStatusByIdsOffloadedOutputsSingleContentVersionQuery() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String big1 = 'X'.repeat(110001);
      String big2 = 'Y'.repeat(110001);

      Workflow_Instance__c inst1 = new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-bulk-off-1')
        .output(null)
        .errorMessage(null)
        .build();
      Workflow_Instance__c inst2 = new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-bulk-off-2')
        .output(null)
        .errorMessage(null)
        .build();

      inst1.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
        inst1.Id,
        big1,
        'Out-' + inst1.Id
      );
      inst2.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
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
  }

  // ─── Bulk getStatus(List of String) ──────────────────────────────────────

  @IsTest
  static void testBulkGetStatusByKeysMixed() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c done = new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-bulk-str-done')
        .output('{"k":2}')
        .errorMessage(null)
        .build();
      Workflow_Instance__c running = new InstanceBuilder()
        .status('Running')
        .correlationKey('key-bulk-str-run')
        .output(null)
        .errorMessage(null)
        .build();

      List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
        new List<String>{ 'key-bulk-str-done', 'key-bulk-str-run' }
      );

      System.assertEquals(2, results.size());
      System.assertEquals(done.Id, results[0].instanceId);
      System.assertEquals(true, results[0].isTerminal);
      System.assertEquals(running.Id, results[1].instanceId);
      System.assertEquals(false, results[1].isTerminal);
    }
  }

  @IsTest
  static void testBulkGetStatusByKeysPrefersActiveOverTerminal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-bulk-prefer')
        .output('old')
        .errorMessage(null)
        .build();
      Workflow_Instance__c activeInst = new InstanceBuilder()
        .status('Running')
        .correlationKey('key-bulk-prefer')
        .output(null)
        .errorMessage(null)
        .build();

      List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
        new List<String>{ 'key-bulk-prefer' }
      );

      System.assertEquals(
        activeInst.Id,
        results[0].instanceId,
        'Active instance should be preferred over terminal'
      );
    }
  }

  @IsTest
  static void testBulkGetStatusByKeysMissingKeyYieldsNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-bulk-str-known2')
        .output('v')
        .errorMessage(null)
        .build();

      List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
        new List<String>{ 'key-bulk-str-known2', 'key-not-exist-xyz987' }
      );

      System.assertEquals(2, results.size());
      System.assertNotEquals(null, results[0]);
      System.assertEquals(
        null,
        results[1],
        'Missing key should yield null slot'
      );
    }
  }

  @IsTest
  static void testBulkGetStatusByKeysBlankEntriesYieldNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-bulk-str-blank')
        .output('v')
        .errorMessage(null)
        .build();

      List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
        new List<String>{ 'key-bulk-str-blank', '', null }
      );

      System.assertEquals(3, results.size());
      System.assertNotEquals(null, results[0]);
      System.assertEquals(null, results[1], 'Blank key should yield null');
      System.assertEquals(null, results[2], 'Null key should yield null');
    }
  }

  @IsTest
  static void testBulkGetStatusByKeysEmptyList() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<WorkflowEngine.WorkflowStatus> results = WorkflowEngine.getStatus(
        new List<String>()
      );
      System.assertEquals(0, results.size());
    }
  }

  @IsTest
  static void testBulkGetStatusByKeysGovernorBoundsOffloaded() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String big = 'Z'.repeat(110001);
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-bulk-str-gov')
        .output(null)
        .errorMessage(null)
        .build();
      inst.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(
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
  }

  // ─── Single-record methods delegate to bulk (consistency check) ───────────

  @IsTest
  static void testSingleDelegatesConsistentWithBulk() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = new InstanceBuilder()
        .status('Completed')
        .correlationKey('key-delegate-check')
        .output('{"consistent":true}')
        .errorMessage(null)
        .build();

      WorkflowEngine.WorkflowStatus single = WorkflowEngine.getStatus(inst.Id);
      List<WorkflowEngine.WorkflowStatus> bulkResults = WorkflowEngine.getStatus(
        new List<Id>{ inst.Id }
      );

      System.assertEquals(single.instanceId, bulkResults[0].instanceId);
      System.assertEquals(single.status, bulkResults[0].status);
      System.assertEquals(single.output, bulkResults[0].output);
      System.assertEquals(single.isTerminal, bulkResults[0].isTerminal);
    }
  }

  // ─── Stub workflow inner class (required by InstanceBuilder Workflow_Name__c) ─
  // Not actually executed; here so the class name resolves in this test context.
  /**
   * @description Placeholder workflow class that is never executed; it only needs to
   * exist so the Workflow_Name__c used by InstanceBuilder resolves in this test.
   */
  public class StubWorkflow {
  }
}
