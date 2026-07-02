@isTest
public class StepContextTestBuilderTest {
  // A mock producer that throws an exception if called, defined at the outer class level
  private class ThrowingProducer implements CaptureProducer {
    public Object produce() {
      throw new IllegalArgumentException('Should not be called');
    }
  }

  private class StringProducer implements CaptureProducer {
    private String val;
    public StringProducer(String val) {
      this.val = val;
    }
    public Object produce() {
      return this.val;
    }
  }

  @isTest
  static void testBuilderDefaults() {
    StepContext ctx = new StepContextTestBuilder().build();

    System.assertNotEquals(
      null,
      ctx.workflowInstanceId,
      'Should auto-generate a workflow instance ID'
    );
    System.assertEquals(
      'TestWorkflow',
      ctx.workflowName,
      'Should default workflow name'
    );
    System.assertEquals('TestStep', ctx.stepName, 'Should default step name');
    System.assertEquals(1, ctx.workflowVersion, 'Should default version to 1');
    System.assertEquals(1, ctx.attempt, 'Should default attempt to 1');
    System.assertEquals(1, ctx.maxAttempts, 'Should default maxAttempts to 1');
    System.assertEquals(
      false,
      ctx.isTimeoutResume(),
      'Should default timeoutResume to false'
    );
  }

  @isTest
  static void testChainedSetters() {
    Id fakeInstanceId = Id.valueOf(
      Workflow_Instance__c.SObjectType.getDescribe().getKeyPrefix() +
      '000000000001'
    );
    Datetime past = Datetime.now().addDays(-1);

    StepContext ctx = new StepContextTestBuilder()
      .workflowInstanceId(fakeInstanceId)
      .workflowName('MyCustomWorkflow')
      .stepName('MyCustomStep')
      .inputJson('{"x":1}')
      .previousStepOutput('{"y":2}')
      .stepStateJson('{"z":3}')
      .workflowInputJson('{"w":4}')
      .workflowVersion(3)
      .stepVisit(2)
      .previousRunAt(past)
      .timeoutResume(true)
      .attempt(3)
      .maxAttempts(5)
      .build();

    System.assertEquals(fakeInstanceId, ctx.workflowInstanceId);
    System.assertEquals('MyCustomWorkflow', ctx.workflowName);
    System.assertEquals('MyCustomStep', ctx.stepName);
    System.assertEquals('{"x":1}', ctx.inputJson);
    System.assertEquals('{"y":2}', ctx.previousStepOutput);
    System.assertEquals('{"z":3}', ctx.stepStateJson);
    System.assertEquals('{"w":4}', ctx.workflowInputJson);
    System.assertEquals(3, ctx.workflowVersion);
    System.assertEquals(past, ctx.previousRunAt);
    System.assertEquals(true, ctx.isTimeoutResume());
    System.assertEquals(3, ctx.attempt);
    System.assertEquals(5, ctx.maxAttempts);
  }

  @isTest
  static void testOverloadedObjectSetters() {
    Map<String, Object> inputMap = new Map<String, Object>{ 'a' => 1 };
    Map<String, Object> stateMap = new Map<String, Object>{ 'b' => 2 };

    StepContext ctx = new StepContextTestBuilder()
      .input(inputMap)
      .stepState(stateMap)
      .workflowInput(new Map<String, Object>{ 'c' => 3 })
      .previousStepOutput(new Map<String, Object>{ 'd' => 4 })
      .build();

    System.assertEquals('{"a":1}', ctx.inputJson);
    System.assertEquals('{"b":2}', ctx.stepStateJson);
    System.assertEquals('{"c":3}', ctx.workflowInputJson);
    System.assertEquals('{"d":4}', ctx.previousStepOutput);
  }

  @isTest
  static void testSignalSeeding() {
    StepContext ctx = new StepContextTestBuilder()
      .addSignal('Approve:Order', '{"approved":true}')
      .addSignal('Approve:Order', '{"approved":false}')
      .build();

    List<StepContext.Signal> signals = ctx.getSignals();
    System.assertEquals(2, signals.size(), 'Should have seeded 2 signals');
    System.assertEquals('Approve:Order', signals[0].name);
    System.assertEquals('{"approved":true}', signals[0].payload);
    System.assertNotEquals(
      null,
      signals[0].signalId,
      'Should have auto-generated a signal ID'
    );
    System.assertNotEquals(
      null,
      signals[1].signalId,
      'Should have auto-generated a signal ID'
    );
    System.assertNotEquals(
      signals[0].signalId,
      signals[1].signalId,
      'Signal IDs should be distinct'
    );

    StepContext.Signal latest = ctx.getSignal('Approve:Order');
    System.assertNotEquals(null, latest);
    System.assertEquals(
      '{"approved":false}',
      latest.payload,
      'Should return the most recent signal matching the name'
    );
  }

  @isTest
  static void testSignalSeedingWithExistingSignal() {
    StepContext.Signal customSig = new StepContext.Signal(
      null,
      'Custom',
      '{"data":123}'
    );
    StepContext ctx = new StepContextTestBuilder().addSignal(customSig).build();

    List<StepContext.Signal> signals = ctx.getSignals();
    System.assertEquals(1, signals.size());
    System.assertEquals('Custom', signals[0].name);
    System.assertEquals('{"data":123}', signals[0].payload);
  }

  @isTest
  static void testOnceSeedingAndNormalization() {
    Datetime nowTime = Datetime.newInstance(2026, 7, 2, 9, 0, 0);
    StepContext ctx = new StepContextTestBuilder()
      .once('refNum', 'TX-999')
      // Seeding a complex object (like Datetime) should normalize to its JSON string form (behavioral fidelity)
      .once('timestamp', nowTime)
      .build();

    Object refResult = ctx.once('refNum', new ThrowingProducer());
    System.assertEquals(
      'TX-999',
      (String) refResult,
      'Should return seeded capture value and not invoke producer'
    );

    Object timeResult = ctx.once('timestamp', new ThrowingProducer());
    System.assert(
      timeResult instanceof String,
      'Datetime capture should have been normalized to String'
    );
    System.assertEquals(
      JSON.deserializeUntyped(JSON.serialize(nowTime)),
      timeResult,
      'Normalized value must match JSON serialize-deserialize form'
    );
  }

  @isTest
  static void testDistinctIdempotencyKeys() {
    Id fakeInstanceId = Id.valueOf(
      Workflow_Instance__c.SObjectType.getDescribe().getKeyPrefix() +
      '000000000001'
    );
    StepContext visit0 = new StepContextTestBuilder()
      .workflowInstanceId(fakeInstanceId)
      .stepName('StepA')
      .stepVisit(0)
      .build();

    StepContext visit1 = new StepContextTestBuilder()
      .workflowInstanceId(fakeInstanceId)
      .stepName('StepA')
      .stepVisit(1)
      .build();

    System.assertNotEquals(null, visit0.idempotencyKey);
    System.assertNotEquals(null, visit1.idempotencyKey);
    System.assertNotEquals(
      visit0.idempotencyKey,
      visit1.idempotencyKey,
      'Idempotency keys should be distinct per visit'
    );
  }

  @isTest
  static void testBuilderCapturedValuesIsolation() {
    StepContextTestBuilder builder = new StepContextTestBuilder()
      .once('key1', 'value1');

    StepContext ctx1 = builder.build();
    StepContext ctx2 = builder.build();

    // Verify both have value1
    System.assertEquals(
      'value1',
      (String) ctx1.once('key1', new ThrowingProducer())
    );
    System.assertEquals(
      'value1',
      (String) ctx2.once('key1', new ThrowingProducer())
    );

    // Call once() on ctx1 with a new key.
    ctx1.once('key2', new StringProducer('value2'));

    // Verify ctx2 does NOT have key2 (asserting they don't share the map reference)
    Object ctx2Result = ctx2.once('key2', new StringProducer('newValue'));
    System.assertEquals(
      'newValue',
      (String) ctx2Result,
      'ctx2 should not share capturedValues reference with ctx1'
    );
  }
}
