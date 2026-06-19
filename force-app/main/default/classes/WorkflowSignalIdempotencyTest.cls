/**
 * TDD coverage for issue #48: caller-supplied idempotency key on inbound signals.
 *
 * RED phase: these tests are written before implementation and reference
 * Workflow_Event__e.Idempotency_Key__c, WorkflowEngine.signal/4, and
 * WorkflowSignalInvocableAction.SignalRequest.idempotencyKey — all of which
 * are added in the GREEN phase.
 */
@isTest
public class WorkflowSignalIdempotencyTest {
  // ── Inline workflow: suspends until 'Approve' signal, then completes ────────

  public class WaitWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'WorkflowSignalIdempotencyTest.WaitStep';
    }
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  public class WaitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (ctx.getSignal('Approve').isPresent()) {
        return StepResult.complete(null, '{"approved":true}');
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
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId].Status__c,
      'Instance must be Suspended before signal injection'
    );
    return instanceId;
  }

  // ── AC6 / Success Metric: N keyed platform-event publishes → exactly 1 row ──

  @isTest
  static void testKeyedPlatformEventDeduplicatesNPublishes() {
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
    System.assertEquals('Completed', inst.Status__c, 'Workflow must complete');
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

  // ── AC2 / AC3: second keyed deliver in separate trigger invocation is no-op ─

  @isTest
  static void testKeyedSignalSecondDeliveryIsSilentNoOp() {
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

  // ── AC4: no key → at-least-once preserved (backward compatible) ─────────────

  @isTest
  static void testUnkeyedSignalsAreAtLeastOnce() {
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

  // ── AC5a: distinct keys on the same instance both deliver ───────────────────

  @isTest
  static void testDistinctKeysSameInstanceBothDeliver() {
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

  // ── AC5b: same key on different instances both deliver (scope = per-instance) ─

  @isTest
  static void testSameKeyDifferentInstancesBothDeliver() {
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

  // ── AC1 – Apex API: signal/4 overload deduplicates on second call ───────────

  @isTest
  static void testApexApiIdempotencyKeyDeduplicates() {
    Id instanceId = startAndSuspend('idem-test-6');

    // First call: signal lands.
    WorkflowEngine.signal('idem-test-6', 'Approve', '{"v":1}', 'apex-key-001');

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
    WorkflowEngine.signal('idem-test-6', 'Approve', '{"v":2}', 'apex-key-001');

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

  // ── AC1 – Flow invocable: idempotencyKey field deduplicates ─────────────────

  @isTest
  static void testFlowInvocableIdempotencyKeyDeduplicates() {
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
