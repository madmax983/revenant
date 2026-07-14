/**
 * TDD coverage for issue #48: caller-supplied idempotency key on inbound signals.
 *
 * RED phase: these tests are written before implementation and reference
 * Workflow_Event__e.Idempotency_Key__c, WorkflowEngine.signal/4, and
 * WorkflowSignalInvocableAction.SignalRequest.idempotencyKey — all of which
 * are added in the GREEN phase.
 */
@IsTest
public class WorkflowSignalIdempotencyTest {
  // ── Inline workflow: suspends until 'Approve' signal, then completes ────────

  /**
   * @description Test fixture workflow that suspends on a single step until an
   * 'Approve' signal arrives, then completes.
   */
  public class WaitWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single WaitStep.
     * @return The one-element list naming WaitStep.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowSignalIdempotencyTest.WaitStep' };
    }
    /**
     * @description Returns the sole WaitStep as the entry point.
     * @return The name of the initial step.
     */
    public String getInitialStep() {
      return 'WorkflowSignalIdempotencyTest.WaitStep';
    }
    /**
     * @description Terminates after the single step.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, marking the workflow complete.
     */
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  /**
   * @description Fixture step that completes once the 'Approve' signal is present,
   * otherwise suspends awaiting it.
   */
  public class WaitStep implements WorkflowStep {
    /**
     * @description Completes when the 'Approve' signal has arrived, else suspends.
     * @param ctx The durable step context used to poll for the signal.
     * @return A complete result once approved, or a suspend result otherwise.
     */
    public StepResult execute(StepContext ctx) {
      if (ctx.signals().getSignal('Approve').isPresent()) {
        return StepResult.complete(null, '{"approved":true}');
      }
      return StepResult.suspend();
    }
  }

  // ── Inline workflow: suspends until a 'Go' signal (ignores 'Approve') ───────
  // Stays active after an 'Approve' lands, so the pre-arrival-to-active dedup
  // boundary can be exercised without the instance completing first.

  /**
   * @description Test fixture workflow that suspends until a 'Go' signal, ignoring
   * 'Approve' so the pre-arrival-to-active dedup boundary can be exercised while the
   * instance stays active.
   */
  public class WaitForGoWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single WaitForGoStep.
     * @return The one-element list naming WaitForGoStep.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowSignalIdempotencyTest.WaitForGoStep' };
    }
    /**
     * @description Returns the sole WaitForGoStep as the entry point.
     * @return The name of the initial step.
     */
    public String getInitialStep() {
      return 'WorkflowSignalIdempotencyTest.WaitForGoStep';
    }
    /**
     * @description Terminates after the single step.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, marking the workflow complete.
     */
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  /**
   * @description Fixture step that completes once the 'Go' signal is present,
   * otherwise suspends awaiting it.
   */
  public class WaitForGoStep implements WorkflowStep {
    /**
     * @description Completes when the 'Go' signal has arrived, else suspends.
     * @param ctx The durable step context used to poll for the signal.
     * @return A complete result once signalled, or a suspend result otherwise.
     */
    public StepResult execute(StepContext ctx) {
      if (ctx.signals().getSignal('Go').isPresent()) {
        return StepResult.complete(null, null);
      }
      return StepResult.suspend();
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  private static Id startAndSuspend(String corrKey) {
    Id instanceId = WorkflowEngine.start(
      'WorkflowSignalIdempotencyTest.WaitWorkflow',
      corrKey,
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);
    System.assertEquals(
      'Suspended',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
      .Status__c,
      'Instance must be Suspended before signal injection'
    );
    return instanceId;
  }

  // ── AC6 / Success Metric: N keyed platform-event publishes → exactly 1 row ──

  @IsTest
  static void testKeyedPlatformEventDeduplicatesNPublishes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = startAndSuspend('idem-test-1');

      // Publish N=5 platform events, all with the same caller-supplied key.
      List<Workflow_Event__e> events = new List<Workflow_Event__e>();
      for (Integer i = 0; i < 5; i++) {
        events.add(
          new Workflow_Event__e(
            Event_Type__c = 'SIGNAL:Approve',
            Workflow_Instance_Id__c = 'idem-test-1',
            Payload__c = '{"attempt":' + i + '}',
            Idempotency_Key__c = 'webhook-retry-001'
          )
        );
      }
      EventBus.publish(events);
      Test.getEventBus().deliver();

      // Exactly one signal row must have been persisted.
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId
        ],
        'N keyed platform-event publishes must produce exactly 1 signal row'
      );

      // Drive to completion: resumed branch ran exactly once.
      new WorkflowOrchestrator(instanceId).execute(null);
      Workflow_Instance__c inst = [
        SELECT Status__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Completed',
        inst.Status__c,
        'Workflow must complete'
      );
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Step_Execution__c
          WHERE
            Workflow_Instance__c = :instanceId
            AND Step_Name__c = 'WorkflowSignalIdempotencyTest.WaitStep'
            AND Status__c = 'Completed'
        ],
        'WaitStep must have been completed exactly once'
      );
    }
  }

  // ── AC2 / AC3: second keyed deliver in separate trigger invocation is no-op ─

  @IsTest
  static void testKeyedSignalSecondDeliveryIsSilentNoOp() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = startAndSuspend('idem-test-2');

      Workflow_Event__e evt = new Workflow_Event__e(
        Event_Type__c = 'SIGNAL:Approve',
        Workflow_Instance_Id__c = 'idem-test-2',
        Payload__c = '{"v":1}',
        Idempotency_Key__c = 'webhook-retry-002'
      );

      // First delivery: signal lands, instance wakes.
      EventBus.publish(evt);
      Test.getEventBus().deliver();

      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId
        ],
        'First keyed delivery must produce 1 row'
      );

      // Manually re-suspend the instance to simulate at-least-once state (the
      // orchestrator hasn't consumed the signal yet; a second deliver arrives).
      // In a real scenario the second publish arrives before or during processing.
      // Simulate by publishing the exact same key again, separate deliver() call
      // (= separate trigger invocation = logically separate transaction).
      EventBus.publish(evt);
      Boolean threw = false;
      try {
        Test.getEventBus().deliver();
      } catch (Exception ex) {
        threw = true;
      }

      System.assert(!threw, 'Duplicate keyed signal must not throw');
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId
        ],
        'Duplicate keyed delivery must leave exactly 1 row (no second row)'
      );
    }
  }

  // ── AC4: no key → at-least-once preserved (backward compatible) ─────────────

  @IsTest
  static void testUnkeyedSignalsAreAtLeastOnce() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = startAndSuspend('idem-test-3');

      // Two platform events with NO Idempotency_Key__c.
      EventBus.publish(
        new Workflow_Event__e(
          Event_Type__c = 'SIGNAL:Approve',
          Workflow_Instance_Id__c = 'idem-test-3',
          Payload__c = '{"v":1}'
        )
      );
      EventBus.publish(
        new Workflow_Event__e(
          Event_Type__c = 'SIGNAL:Approve',
          Workflow_Instance_Id__c = 'idem-test-3',
          Payload__c = '{"v":2}'
        )
      );
      Test.getEventBus().deliver();

      System.assertEquals(
        2,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId
        ],
        'Unkeyed signals must preserve at-least-once (2 rows for 2 publishes)'
      );
    }
  }

  // ── AC5a: distinct keys on the same instance both deliver ───────────────────

  @IsTest
  static void testDistinctKeysSameInstanceBothDeliver() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = startAndSuspend('idem-test-4');

      List<Workflow_Event__e> events = new List<Workflow_Event__e>{
        new Workflow_Event__e(
          Event_Type__c = 'SIGNAL:Approve',
          Workflow_Instance_Id__c = 'idem-test-4',
          Payload__c = '{"src":"webhookA"}',
          Idempotency_Key__c = 'key-A'
        ),
        new Workflow_Event__e(
          Event_Type__c = 'SIGNAL:Approve',
          Workflow_Instance_Id__c = 'idem-test-4',
          Payload__c = '{"src":"webhookB"}',
          Idempotency_Key__c = 'key-B'
        )
      };
      EventBus.publish(events);
      Test.getEventBus().deliver();

      System.assertEquals(
        2,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId
        ],
        'Two distinct keys on the same instance must both produce rows'
      );
    }
  }

  // ── AC5b: same key on different instances both deliver (scope = per-instance) ─

  @IsTest
  static void testSameKeyDifferentInstancesBothDeliver() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceA = startAndSuspend('idem-test-5a');
      Id instanceB = startAndSuspend('idem-test-5b');

      List<Workflow_Event__e> events = new List<Workflow_Event__e>{
        new Workflow_Event__e(
          Event_Type__c = 'SIGNAL:Approve',
          Workflow_Instance_Id__c = 'idem-test-5a',
          Payload__c = '{"v":1}',
          Idempotency_Key__c = 'shared-key-xyz'
        ),
        new Workflow_Event__e(
          Event_Type__c = 'SIGNAL:Approve',
          Workflow_Instance_Id__c = 'idem-test-5b',
          Payload__c = '{"v":2}',
          Idempotency_Key__c = 'shared-key-xyz'
        )
      };
      EventBus.publish(events);
      Test.getEventBus().deliver();

      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceA
        ],
        'Instance A must receive exactly 1 signal row'
      );
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceB
        ],
        'Instance B must receive exactly 1 signal row (scope is per-instance)'
      );
    }
  }

  // ── AC1 – Apex API: signal/4 overload deduplicates on second call ───────────

  @IsTest
  static void testApexApiIdempotencyKeyDeduplicates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = startAndSuspend('idem-test-6');

      // First call: signal lands.
      WorkflowEngine.signal(
        new WorkflowEngine.SignalRequest('idem-test-6', 'Approve', '{"v":1}')
          .withIdempotencyKey('apex-key-001')
      );

      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId
        ],
        'First keyed Apex signal must produce 1 row'
      );

      // Manually put instance back to Suspended (so it can receive the second call
      // without completing mid-test).
      Workflow_Instance__c inst = [
        SELECT Id, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      inst.Status__c = 'Suspended';
      update as system inst;

      // Second call with the same key: silent no-op.
      WorkflowEngine.signal(
        new WorkflowEngine.SignalRequest('idem-test-6', 'Approve', '{"v":2}')
          .withIdempotencyKey('apex-key-001')
      );

      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId
        ],
        'Second identical keyed Apex signal must not produce a second row'
      );
    }
  }

  // ── AC1 – Flow invocable: idempotencyKey field deduplicates ─────────────────

  @IsTest
  static void testFlowInvocableIdempotencyKeyDeduplicates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = startAndSuspend('idem-test-7');

      WorkflowSignalInvocableAction.SignalRequest req1 = new WorkflowSignalInvocableAction.SignalRequest();
      req1.targetKey = 'idem-test-7';
      req1.signalName = 'Approve';
      req1.payloadJson = '{"v":1}';
      req1.idempotencyKey = 'flow-key-001';

      WorkflowSignalInvocableAction.signalWorkflow(
        new List<WorkflowSignalInvocableAction.SignalRequest>{ req1 }
      );

      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId
        ],
        'First Flow invocable keyed signal must produce 1 row'
      );

      // Reset to Suspended for the second call.
      Workflow_Instance__c inst = [
        SELECT Id, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      inst.Status__c = 'Suspended';
      update as system inst;

      WorkflowSignalInvocableAction.SignalRequest req2 = new WorkflowSignalInvocableAction.SignalRequest();
      req2.targetKey = 'idem-test-7';
      req2.signalName = 'Approve';
      req2.payloadJson = '{"v":2}';
      req2.idempotencyKey = 'flow-key-001';

      WorkflowSignalInvocableAction.signalWorkflow(
        new List<WorkflowSignalInvocableAction.SignalRequest>{ req2 }
      );

      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId
        ],
        'Second identical Flow invocable keyed signal must not produce a second row'
      );
    }
  }

  // ── Bulk keyed insert: genuine row error rolls back all-or-none ──────────────
  // Regression for PR #79 review: a mixed bulk request where one keyed signal is
  // valid and another fails for a non-duplicate reason must NOT leave the valid
  // row committed (which would strand a Received signal and consume its key).

  @IsTest
  static void testBulkKeyedInsertGenuineErrorRollsBackAllOrNone() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = startAndSuspend('idem-test-8');

      // Signal_Name__c is Text(255); 500 chars forces a non-duplicate DML error.
      String tooLongName = 'X'.repeat(500);

      List<WorkflowEngine.SignalRequest> reqs = new List<WorkflowEngine.SignalRequest>{
        new WorkflowEngine.SignalRequest('idem-test-8', 'Approve', '{"v":1}')
          .withIdempotencyKey('good-key'),
        new WorkflowEngine.SignalRequest('idem-test-8', tooLongName, '{"v":2}')
          .withIdempotencyKey('bad-key')
      };

      Boolean threw = false;
      try {
        WorkflowEngine.signal(reqs);
      } catch (Exception ex) {
        threw = true;
      }

      System.assert(threw, 'A genuine (non-duplicate) row error must surface');
      System.assertEquals(
        0,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId
        ],
        'A genuine row error must roll back the successfully-inserted sibling (all-or-none)'
      );
    }
  }

  // ── Keyed Cancel: dedup + no-throw on redelivery after terminal ──────────────

  @IsTest
  static void testKeyedCancelDeduplicatesAndNoThrowAfterTerminal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = startAndSuspend('idem-cancel-1');

      // First keyed cancel (no compensations) drives the instance terminal.
      WorkflowEngine.signal(
        new WorkflowEngine.SignalRequest(
            'idem-cancel-1',
            'Cancel',
            '{"runCompensations":false}'
          )
          .withIdempotencyKey('cancel-key-1')
      );

      System.assertEquals(
        'Cancelled',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
        .Status__c,
        'First keyed cancel must cancel the workflow'
      );
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId AND Signal_Name__c = 'Cancel'
        ],
        'A keyed cancel persists exactly one dedup tombstone'
      );

      // Redelivered keyed cancel after terminal: silent no-op, must NOT throw.
      Boolean threw = false;
      try {
        WorkflowEngine.signal(
          new WorkflowEngine.SignalRequest(
              'idem-cancel-1',
              'Cancel',
              '{"runCompensations":false}'
            )
            .withIdempotencyKey('cancel-key-1')
        );
      } catch (Exception ex) {
        threw = true;
      }
      System.assert(
        !threw,
        'A redelivered keyed cancel after terminal must be a no-op, not a throw'
      );
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId AND Signal_Name__c = 'Cancel'
        ],
        'Duplicate keyed cancel must not add a second tombstone'
      );
    }
  }

  // ── Keyed Cancel: duplicates in one bulk batch run cancellation once ─────────

  @IsTest
  static void testBulkDuplicateKeyedCancelRunsOnce() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = startAndSuspend('idem-cancel-2');

      List<WorkflowEngine.SignalRequest> reqs = new List<WorkflowEngine.SignalRequest>{
        new WorkflowEngine.SignalRequest(
            'idem-cancel-2',
            'Cancel',
            '{"runCompensations":false}'
          )
          .withIdempotencyKey('cancel-key-2'),
        new WorkflowEngine.SignalRequest(
            'idem-cancel-2',
            'Cancel',
            '{"runCompensations":false}'
          )
          .withIdempotencyKey('cancel-key-2')
      };
      WorkflowEngine.signal(reqs);

      System.assertEquals(
        'Cancelled',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
        .Status__c,
        'Bulk keyed cancel must cancel the workflow'
      );
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId AND Signal_Name__c = 'Cancel'
        ],
        'A duplicate keyed cancel in the same batch must claim the tombstone once'
      );
    }
  }

  // ── Unrouted (pre-arrival) keyed signals dedup by correlation key ────────────

  @IsTest
  static void testUnroutedKeyedSignalsDeduplicate() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // No instance exists for this correlation key, so the signals are captured
      // as Unrouted. N publishes with the same Idempotency_Key__c (distinct
      // EventUuids) must collapse to a single Unrouted row.
      List<Workflow_Event__e> events = new List<Workflow_Event__e>();
      for (Integer i = 0; i < 3; i++) {
        events.add(
          new Workflow_Event__e(
            Event_Type__c = 'SIGNAL:Approve',
            Workflow_Instance_Id__c = 'no-such-instance-key',
            Payload__c = '{"v":' + i + '}',
            Idempotency_Key__c = 'unrouted-key-1'
          )
        );
      }
      EventBus.publish(events);
      Test.getEventBus().deliver();

      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE
            Correlation_Key__c = 'no-such-instance-key'
            AND Status__c = 'Unrouted'
        ],
        'N unrouted keyed publishes with the same key must collapse to 1 row'
      );
    }
  }

  // ── Unrouted: same key, different correlation keys both captured ─────────────

  @IsTest
  static void testUnroutedSameKeyDifferentCorrelationBothCaptured() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      EventBus.publish(
        new List<Workflow_Event__e>{
          new Workflow_Event__e(
            Event_Type__c = 'SIGNAL:Approve',
            Workflow_Instance_Id__c = 'unrouted-corr-A',
            Payload__c = '{"v":1}',
            Idempotency_Key__c = 'shared-unrouted-key'
          ),
          new Workflow_Event__e(
            Event_Type__c = 'SIGNAL:Approve',
            Workflow_Instance_Id__c = 'unrouted-corr-B',
            Payload__c = '{"v":2}',
            Idempotency_Key__c = 'shared-unrouted-key'
          )
        }
      );
      Test.getEventBus().deliver();

      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE
            Correlation_Key__c = 'unrouted-corr-A'
            AND Status__c = 'Unrouted'
        ],
        'Unrouted dedup is scoped per correlation key (A captured)'
      );
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE
            Correlation_Key__c = 'unrouted-corr-B'
            AND Status__c = 'Unrouted'
        ],
        'Unrouted dedup is scoped per correlation key (B captured)'
      );
    }
  }

  // ── Unrouted dedup is case-insensitive (matches SOQL correlation matching) ───

  @IsTest
  static void testUnroutedKeyedDedupIsCaseInsensitive() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Correlation_Key__c matches case-insensitively in SOQL, so 'Order-1' and
      // 'order-1' resolve to the same instance and must collapse to one Unrouted
      // row when published with the same idempotency key.
      EventBus.publish(
        new List<Workflow_Event__e>{
          new Workflow_Event__e(
            Event_Type__c = 'SIGNAL:Approve',
            Workflow_Instance_Id__c = 'Order-1',
            Payload__c = '{"v":1}',
            Idempotency_Key__c = 'case-key'
          ),
          new Workflow_Event__e(
            Event_Type__c = 'SIGNAL:Approve',
            Workflow_Instance_Id__c = 'order-1',
            Payload__c = '{"v":2}',
            Idempotency_Key__c = 'case-key'
          )
        }
      );
      Test.getEventBus().deliver();

      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Correlation_Key__c LIKE 'order-1' AND Status__c = 'Unrouted'
        ],
        'Same key + case-variant correlation keys must collapse to one Unrouted row'
      );
    }
  }

  // ── Unrouted keyed capture is first-wins (does not overwrite on duplicate) ───

  @IsTest
  static void testUnroutedKeyedCaptureIsFirstWins() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // First capture (transaction 1).
      EventBus.publish(
        new List<Workflow_Event__e>{
          new Workflow_Event__e(
            Event_Type__c = 'SIGNAL:Approve',
            Workflow_Instance_Id__c = 'first-wins-corr',
            Payload__c = '{"v":"first"}',
            Idempotency_Key__c = 'first-wins-key'
          )
        }
      );
      Test.getEventBus().deliver();

      // Duplicate capture, same key, different payload (transaction 2).
      EventBus.publish(
        new List<Workflow_Event__e>{
          new Workflow_Event__e(
            Event_Type__c = 'SIGNAL:Approve',
            Workflow_Instance_Id__c = 'first-wins-corr',
            Payload__c = '{"v":"second"}',
            Idempotency_Key__c = 'first-wins-key'
          )
        }
      );
      Test.getEventBus().deliver();

      List<Workflow_Signal__c> rows = [
        SELECT Payload__c
        FROM Workflow_Signal__c
        WHERE Correlation_Key__c = 'first-wins-corr' AND Status__c = 'Unrouted'
      ];
      System.assertEquals(
        1,
        rows.size(),
        'Duplicate capture must not add a row'
      );
      System.assertEquals(
        '{"v":"first"}',
        rows[0].Payload__c,
        'First capture wins; a duplicate must not overwrite the payload'
      );
    }
  }

  // ── Pre-arrival keyed capture dedups across the active boundary (issue P2) ───

  @IsTest
  static void testPreArrivalKeyedDedupsAcrossActiveBoundary() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // 1. Capture a keyed 'Approve' before any instance exists.
      EventBus.publish(
        new List<Workflow_Event__e>{
          new Workflow_Event__e(
            Event_Type__c = 'SIGNAL:Approve',
            Workflow_Instance_Id__c = 'boundary-1',
            Payload__c = '{"v":1}',
            Idempotency_Key__c = 'boundary-key'
          )
        }
      );
      Test.getEventBus().deliver();
      Workflow_Signal__c captured = [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE Correlation_Key__c = 'boundary-1' AND Status__c = 'Unrouted'
        LIMIT 1
      ];

      // 2. Start an instance with that correlation key; it suspends waiting for
      //    'Go', so an 'Approve' leaves it active.
      Id instanceId = WorkflowEngine.start(
        'WorkflowSignalIdempotencyTest.WaitForGoWorkflow',
        'boundary-1',
        null
      );
      new WorkflowOrchestrator(instanceId).execute(null);

      // 3. Redeliver the captured signal: it reparents and rewrites its dedup key
      //    from the correlation-scoped hash to the instance-scoped routed hash.
      WorkflowEngine.redeliverCapturedSignal(captured.Id);

      // 4. A routed duplicate of the same idempotency key must be deduped.
      WorkflowEngine.signal(
        new WorkflowEngine.SignalRequest('boundary-1', 'Approve', '{"v":2}')
          .withIdempotencyKey('boundary-key')
      );

      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE
            Workflow_Instance__c = :instanceId
            AND Signal_Name__c = 'Approve'
        ],
        'Pre-arrival capture + post-arrival routed duplicate of the same key must collapse to one row'
      );
    }
  }

  // ── Bulk: a keyed cancel must not be resurrected by a sibling forward signal ─

  @IsTest
  static void testBulkKeyedCancelSkipsSiblingForwardSignal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Instance suspends waiting for 'Go' (a different signal leaves it active).
      Id instanceId = WorkflowEngine.start(
        'WorkflowSignalIdempotencyTest.WaitForGoWorkflow',
        'resurrect-1',
        null
      );
      new WorkflowOrchestrator(instanceId).execute(null);
      System.assertEquals(
        'Suspended',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
        .Status__c,
        'precondition: instance must be Suspended waiting for Go'
      );

      // One bulk call pairs a forward 'Go' (listed first) with a keyed 'Cancel'
      // for the same instance. The keyed-cancel pre-pass drives the instance
      // Cancelled before the forward loop; the sibling 'Go' must be skipped, not
      // accepted against the stale Suspended SObject (which would flip it back to
      // Running and resurrect a Cancelled workflow).
      Test.startTest();
      WorkflowEngine.signal(
        new List<WorkflowEngine.SignalRequest>{
          new WorkflowEngine.SignalRequest('resurrect-1', 'Go', null),
          new WorkflowEngine.SignalRequest('resurrect-1', 'Cancel', null)
            .withIdempotencyKey('cancel-key')
        }
      );
      Test.stopTest();

      System.assertEquals(
        'Cancelled',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
        .Status__c,
        'keyed cancel must win; sibling Go must not resurrect the workflow'
      );
      System.assertEquals(
        0,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE
            Workflow_Instance__c = :instanceId
            AND Signal_Name__c = 'Go'
            AND Status__c = 'Received'
        ],
        'a forward signal for a cancelled instance must not be delivered'
      );
    }
  }

  // ── Bulk keyed cancel addressed by a different-cased correlation key ─────────

  @IsTest
  static void testBulkKeyedCancelMatchesCorrelationKeyCaseInsensitively() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Stored correlation key is mixed-case; the cancel request addresses it in
      // lower case. Correlation-key matching is case-insensitive, so the keyed
      // cancel must reach the instance rather than be skipped as unmatched.
      Id instanceId = WorkflowEngine.start(
        'WorkflowSignalIdempotencyTest.WaitForGoWorkflow',
        'Order-CI-1',
        null
      );
      new WorkflowOrchestrator(instanceId).execute(null);
      System.assertEquals(
        'Suspended',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
        .Status__c,
        'precondition: instance must be Suspended'
      );

      Test.startTest();
      WorkflowEngine.signal(
        new List<WorkflowEngine.SignalRequest>{
          new WorkflowEngine.SignalRequest('order-ci-1', 'Cancel', null)
            .withIdempotencyKey('ci-cancel-key')
        }
      );
      Test.stopTest();

      System.assertEquals(
        'Cancelled',
        [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
        .Status__c,
        'keyed cancel addressed by a case-variant correlation key must still cancel'
      );
    }
  }
}
