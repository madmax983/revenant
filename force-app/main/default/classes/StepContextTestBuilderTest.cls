@IsTest
public class StepContextTestBuilderTest {
  // A mock producer that throws an exception if called, defined at the outer class level
  private class ThrowingProducer implements CaptureProducer {
    /**
     * @description Throws if invoked, so a test can assert once() replays a prior
     * capture without ever calling the producer.
     * @return Never returns; always throws.
     */
    public Object produce() {
      throw new IllegalArgumentException('Should not be called');
    }
  }

  private class StringProducer implements CaptureProducer {
    private String val;
    /**
     * @description Constructs the producer with the value to return.
     * @param val The String to produce.
     */
    public StringProducer(String val) {
      this.val = val;
    }
    /**
     * @description Returns the configured value.
     * @return The configured String value.
     */
    public Object produce() {
      return this.val;
    }
  }

  @IsTest
  static void testBuilderDefaults() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
      System.assertEquals(
        1,
        ctx.workflowVersion,
        'Should default version to 1'
      );
      System.assertEquals(1, ctx.attempt, 'Should default attempt to 1');
      System.assertEquals(
        1,
        ctx.retry().maxAttempts,
        'Should default maxAttempts to 1'
      );
      System.assertEquals(
        false,
        ctx.retry().isTimeoutResume(),
        'Should default timeoutResume to false'
      );
    }
  }

  @IsTest
  static void testChainedSetters() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id fakeInstanceId = Id.valueOf(
        Workflow_Instance__c.SObjectType.getDescribe(
            SObjectDescribeOptions.DEFERRED
          )
          .getKeyPrefix() + '000000000001'
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
        .timeoutResume()
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
      System.assertEquals(true, ctx.retry().isTimeoutResume());
      System.assertEquals(3, ctx.attempt);
      System.assertEquals(5, ctx.retry().maxAttempts);
    }
  }

  @IsTest
  static void testOverloadedObjectSetters() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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

      // Assert that string inputs and nulls serialize properly matching the engine
      StepContext ctx2 = new StepContextTestBuilder()
        .input('abc')
        .stepState(null)
        .build();

      System.assertEquals(
        '"abc"',
        ctx2.inputJson,
        'String value should be JSON serialized'
      );
      System.assertEquals(
        null,
        ctx2.stepStateJson,
        'Null value should remain null'
      );
    }
  }

  @IsTest
  static void testSignalSeeding() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = new StepContextTestBuilder()
        .addSignal(
          new StepContext.Signal(null, 'Approve:Order', '{"approved":true}')
        )
        .addSignal(
          new StepContext.Signal(null, 'Approve:Order', '{"approved":false}')
        )
        .build();

      List<StepContext.Signal> signals = ctx.signals().getSignals();
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

      StepContext.Signal latest = ctx.signals().getSignal('Approve:Order');
      System.assertNotEquals(null, latest);
      System.assertEquals(
        '{"approved":false}',
        latest.payload,
        'Should return the most recent signal matching the name'
      );
    }
  }

  @IsTest
  static void testSignalSeedingWithExistingSignal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext.Signal customSig = new StepContext.Signal(
        null,
        'Custom',
        '{"data":123}'
      );
      StepContext ctx = new StepContextTestBuilder()
        .addSignal(customSig)
        .build();

      List<StepContext.Signal> signals = ctx.signals().getSignals();
      System.assertEquals(1, signals.size());
      System.assertEquals('Custom', signals[0].name);
      System.assertEquals('{"data":123}', signals[0].payload);
    }
  }

  @IsTest
  static void testOnceSeedingAndNormalization() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime nowTime = Datetime.newInstance(2026, 7, 2, 9, 0, 0);
      StepContext ctx = new StepContextTestBuilder()
        .once('refNum', 'TX-999')
        // Seeding a complex object (like Datetime) should normalize to its JSON string form (behavioral fidelity)
        .once('timestamp', nowTime)
        .build();

      Object refResult = ctx.captures().once('refNum', new ThrowingProducer());
      System.assertEquals(
        'TX-999',
        (String) refResult,
        'Should return seeded capture value and not invoke producer'
      );

      Object timeResult = ctx.captures()
        .once('timestamp', new ThrowingProducer());
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
  }

  @IsTest
  static void testDistinctIdempotencyKeys() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id fakeInstanceId = Id.valueOf(
        Workflow_Instance__c.SObjectType.getDescribe(
            SObjectDescribeOptions.DEFERRED
          )
          .getKeyPrefix() + '000000000001'
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
  }

  @IsTest
  static void testBuilderCapturedValuesIsolation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContextTestBuilder builder = new StepContextTestBuilder()
        .once('key1', 'value1');

      StepContext ctx1 = builder.build();
      StepContext ctx2 = builder.build();

      // Verify both have value1
      System.assertEquals(
        'value1',
        (String) ctx1.captures().once('key1', new ThrowingProducer())
      );
      System.assertEquals(
        'value1',
        (String) ctx2.captures().once('key1', new ThrowingProducer())
      );

      // Call once() on ctx1 with a new key.
      ctx1.captures().once('key2', new StringProducer('value2'));

      // Verify ctx2 does NOT have key2 (asserting they don't share the map reference)
      Object ctx2Result = ctx2.captures()
        .once('key2', new StringProducer('newValue'));
      System.assertEquals(
        'newValue',
        (String) ctx2Result,
        'ctx2 should not share capturedValues reference with ctx1'
      );
    }
  }

  @IsTest
  static void testSignalLatestArrivalOrder() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = Datetime.now();
      // Seed signals out of chronological order (newer signal added first, older signal added second)
      StepContext.Signal newerSig = new StepContext.Signal(
          null,
          'MySignal',
          '{"status":"newer"}'
        )
        .withCreatedDate(now.addMinutes(10));
      StepContext.Signal olderSig = new StepContext.Signal(
          null,
          'MySignal',
          '{"status":"older"}'
        )
        .withCreatedDate(now);

      StepContext ctx = new StepContextTestBuilder()
        .addSignal(newerSig)
        .addSignal(olderSig)
        .build();

      // The builder's mock source should order by arrival when returning the latest signal
      StepContext.Signal latest = ctx.signals().getSignal('MySignal');
      System.assertEquals(
        '{"status":"newer"}',
        latest.payload,
        'Should return the chronologically newer signal'
      );
    }
  }

  @IsTest
  static void testSignalListArrivalOrder() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = Datetime.now();
      StepContext.Signal newerSig = new StepContext.Signal(
          null,
          'MySignal',
          '{"status":"newer"}'
        )
        .withCreatedDate(now.addMinutes(10));
      StepContext.Signal olderSig = new StepContext.Signal(
          null,
          'MySignal',
          '{"status":"older"}'
        )
        .withCreatedDate(now);

      StepContext ctx = new StepContextTestBuilder()
        .addSignal(newerSig)
        .addSignal(olderSig)
        .build();

      // Call named getSignals('MySignal') first, bypassing loadAll()
      List<StepContext.Signal> signals = ctx.signals().getSignals('MySignal');
      System.assertEquals(2, signals.size());
      System.assertEquals(
        '{"status":"older"}',
        signals[0].payload,
        'Older signal should be sorted first'
      );
      System.assertEquals(
        '{"status":"newer"}',
        signals[1].payload,
        'Newer signal should be sorted second'
      );
    }
  }
}
