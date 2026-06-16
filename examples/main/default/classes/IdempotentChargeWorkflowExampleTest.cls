@isTest
public class IdempotentChargeWorkflowExampleTest {
  /**
   * Success metric for issue #2: a "charge payment" step that forwards
   * ctx.idempotencyKey to a mock idempotent endpoint produces EXACTLY ONE
   * effective side effect across a forced sequence of
   * {transient retry -> operator re-drive -> duplicate Workflow_Event__e resume}
   * -- duplicate-side-effect rate 0%.
   */
  @isTest
  static void testForwardingIdempotencyKeyYieldsExactlyOneSideEffect() {
    MockIdempotentPaymentGateway.reset();

    String stepName = 'IdempotentChargeWorkflowExample.ChargePaymentStep';

    Test.startTest();
    // First, real attempt: drive through the engine so the idempotency key is
    // the engine-constructed one (proving the engine populates it correctly).
    Id instanceId = WorkflowEngine.start(
      'IdempotentChargeWorkflowExample.ChargeWorkflow',
      'idem-charge-1',
      new Map<String, Object>{ 'amountCents' => 4200 }
    );
    WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId).drive();
    Test.stopTest();

    System.assertEquals(
      'Completed',
      result.status,
      'Single-step charge workflow should complete'
    );
    System.assertEquals(
      1,
      MockIdempotentPaymentGateway.effectiveSideEffectCount,
      'First execution should produce exactly one effective charge'
    );

    String firstChargeId = completedChargeId(instanceId, stepName);
    System.assert(
      String.isNotBlank(firstChargeId),
      'The first attempt should have recorded a charge id'
    );

    // The requested amount (4200) must survive the JSON round-trip rather than
    // silently falling back to the default; guards the numeric-cast handling.
    Workflow_Step_Execution__c firstExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = :stepName
        AND Status__c = 'Completed'
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    System.assert(
      firstExec.Output__c.contains('"amountCents":4200'),
      'The charged amount should be the requested 4200, not the default: ' +
      firstExec.Output__c
    );

    // Now force three more re-executions of the SAME logical (instance, step),
    // standing in for: a transient retry, an operator re-drive (#1), and a
    // duplicate at-least-once Workflow_Event__e resume. Each writes a NEW
    // append-only audit record with a distinct record Id -- proving the key
    // reflects logical (instance, step) identity, not the physical attempt Id.
    String[] scenarios = new List<String>{
      'transient-retry',
      'operator-re-drive',
      'duplicate-event-resume'
    };
    for (String scenario : scenarios) {
      Workflow_Step_Execution__c replayAudit = new Workflow_Step_Execution__c(
        Workflow_Instance__c = instanceId,
        Step_Name__c = stepName,
        Status__c = 'Running',
        Retry_Count__c = 0
      );
      insert replayAudit;

      StepContext ctx = new StepContext(
        instanceId,
        'IdempotentChargeWorkflowExample.ChargeWorkflow',
        stepName,
        '{"amountCents":4200}',
        null,
        null,
        '{"amountCents":4200}'
      );

      // AC: the key is NOT derived from the per-attempt step-execution record Id.
      System.assertNotEquals(
        (String) replayAudit.Id,
        ctx.idempotencyKey,
        'idempotencyKey must not be the per-attempt Workflow_Step_Execution__c Id (' +
        scenario +
        ')'
      );

      StepResult res = new IdempotentChargeWorkflowExample.ChargePaymentStep()
        .execute(ctx);
      Map<String, Object> out = (Map<String, Object>) JSON.deserializeUntyped(
        res.outputJson
      );
      System.assertEquals(
        firstChargeId,
        (String) out.get('chargeId'),
        'Re-execution (' +
        scenario +
        ') must observe the prior charge via the same key'
      );
      System.assertEquals(
        true,
        out.get('deduplicated'),
        'Gateway should report the repeat call (' +
        scenario +
        ') as deduplicated'
      );
    }

    // The whole point: across the original charge + 3 re-executions, the
    // effective-side-effect count is still exactly one. Duplicate rate = 0%.
    System.assertEquals(
      1,
      MockIdempotentPaymentGateway.effectiveSideEffectCount,
      'Forwarding ctx.idempotencyKey must yield exactly one effective side effect across all re-executions'
    );
  }

  /**
   * The loop/polling case (Codex P2): when a workflow genuinely revisits the
   * same step in the same instance, each completed visit must produce a distinct
   * key so the second visit's side effect is NOT wrongly deduped as a retry.
   */
  @isTest
  static void testDistinctVisitsAreNotDeduped() {
    MockIdempotentPaymentGateway.reset();
    Id instanceId = '00D000000000009';
    String stepName = 'IdempotentChargeWorkflowExample.ChargePaymentStep';

    StepContext visitZero = new StepContext(
      instanceId,
      'IdempotentChargeWorkflowExample.ChargeWorkflow',
      stepName,
      '{"amountCents":500}',
      null,
      null,
      '{"amountCents":500}',
      1,
      0
    );
    StepContext visitOne = new StepContext(
      instanceId,
      'IdempotentChargeWorkflowExample.ChargeWorkflow',
      stepName,
      '{"amountCents":500}',
      null,
      null,
      '{"amountCents":500}',
      1,
      1
    );

    Map<String, Object> outZero = (Map<String, Object>) JSON.deserializeUntyped(
      new IdempotentChargeWorkflowExample.ChargePaymentStep()
        .execute(visitZero)
        .outputJson
    );
    Map<String, Object> outOne = (Map<String, Object>) JSON.deserializeUntyped(
      new IdempotentChargeWorkflowExample.ChargePaymentStep()
        .execute(visitOne)
        .outputJson
    );

    System.assertEquals(
      false,
      outZero.get('deduplicated'),
      'First visit should produce a real charge'
    );
    System.assertEquals(
      false,
      outOne.get('deduplicated'),
      'A genuine second visit must charge again, not be deduped as a retry'
    );
    System.assertNotEquals(
      outZero.get('chargeId'),
      outOne.get('chargeId'),
      'Distinct visits must produce distinct charges'
    );
    System.assertEquals(
      2,
      MockIdempotentPaymentGateway.effectiveSideEffectCount,
      'Two distinct visits must produce two effective charges'
    );
  }

  private static String completedChargeId(Id instanceId, String stepName) {
    Workflow_Step_Execution__c se = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = :stepName
        AND Status__c = 'Completed'
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    Map<String, Object> out = (Map<String, Object>) JSON.deserializeUntyped(
      se.Output__c
    );
    return (String) out.get('chargeId');
  }
}
