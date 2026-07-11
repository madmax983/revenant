/**
 * StepContext unit tests for capture-once semantics, exposed retry properties,
 * auto-replay at yield, and child-outcome resolution. Split out of
 * StepContextTest to keep each @IsTest class within the analyzer's size and
 * complexity limits. Shared fake SignalSource/CaptureProducer fixtures live in
 * StepContextTestData.
 */
@IsTest
public class StepContextCaptureReplayTest {
  // Builds a StepContext backed by a single child-outcome signal. Shared by the
  // getChildOutcome tests to avoid duplicating the context-assembly arrange block.
  private static StepContext childOutcomeContext(
    Map<String, StepContext.Signal> sigs
  ) {
    return new StepContext(
      TestIdFactory.generate(Organization.SObjectType),
      'W',
      'S',
      null,
      null,
      null,
      null,
      1,
      new StepContextTestData.MapSignalSource(sigs)
    );
  }

  private static StepContext childOutcomeContext(
    String signalName,
    String payload
  ) {
    return childOutcomeContext(
      new Map<String, StepContext.Signal>{
        signalName.toLowerCase() => new StepContext.Signal(
          null,
          signalName,
          payload
        )
      }
    );
  }

  // ---------------------------------------------------------------------------
  // capture-once / once() (issue #44)
  // ---------------------------------------------------------------------------

  @IsTest
  static void testOnceFirstCallInvokesProducerAndReturnsValue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        instanceId,
        'WF',
        'StepA',
        null,
        null,
        null,
        null
      );
      StepContextTestData.StringProducer p = new StepContextTestData.StringProducer(
        'hello'
      );
      Object result = ctx.once('myKey', p);
      System.assertEquals(
        'hello',
        result,
        'once() must return the produced value on first call'
      );
      System.assertEquals(
        1,
        p.callCount,
        'Producer must be called exactly once on first access'
      );
    }
  }

  @IsTest
  static void testOnceSecondCallReturnsSameValueWithoutCallingProducer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        instanceId,
        'WF',
        'StepA',
        null,
        null,
        null,
        null
      );
      StepContextTestData.StringProducer p = new StepContextTestData.StringProducer(
        'stable'
      );
      ctx.once('k', p);
      Object second = ctx.once('k', p);
      System.assertEquals(
        'stable',
        second,
        'once() must return the same value on subsequent calls'
      );
      System.assertEquals(
        1,
        p.callCount,
        'Producer must NOT be called again after the first capture'
      );
    }
  }

  @IsTest
  static void testOnceDistinctKeysAreIndependent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        instanceId,
        'WF',
        'StepA',
        null,
        null,
        null,
        null
      );
      StepContextTestData.StringProducer pA = new StepContextTestData.StringProducer(
        'alpha'
      );
      StepContextTestData.StringProducer pB = new StepContextTestData.StringProducer(
        'beta'
      );
      Object a = ctx.once('keyA', pA);
      Object b = ctx.once('keyB', pB);
      System.assertEquals('alpha', a);
      System.assertEquals('beta', b);
      System.assertEquals(1, pA.callCount);
      System.assertEquals(1, pB.callCount);
    }
  }

  @IsTest
  static void testOnceWithPriorCapturesSkipsProducer() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
      // Seed a prior-capture JSON as if loaded from Workflow_Step_Execution__c.Captured_Values__c
      String priorJson = JSON.serialize(
        new Map<String, Object>{ 'refNumber' => 'REF-001' }
      );
      StepContext ctx = StepContext.withCapturedValues(
        instanceId,
        'WF',
        'StepA',
        null,
        null,
        null,
        null,
        1,
        0,
        null,
        null,
        priorJson
      );
      StepContextTestData.StringProducer p = new StepContextTestData.StringProducer(
        'SHOULD-NOT-BE-CALLED'
      );
      Object result = ctx.once('refNumber', p);
      System.assertEquals(
        'REF-001',
        result,
        'once() must return the durably stored value, not a new one'
      );
      System.assertEquals(
        0,
        p.callCount,
        'Producer must NOT be called when the key was already captured'
      );
    }
  }

  @IsTest
  static void testGetCapturedValuesJsonRoundTrips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        instanceId,
        'WF',
        'StepA',
        null,
        null,
        null,
        null
      );
      ctx.once('k1', new StepContextTestData.StringProducer('v1'));
      ctx.once('k2', new StepContextTestData.StringProducer('v2'));
      String capturedJson = ctx.getCapturedValuesJson();
      Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
        capturedJson
      );
      System.assertEquals('v1', parsed.get('k1'));
      System.assertEquals('v2', parsed.get('k2'));
    }
  }

  @IsTest
  static void testGetCapturedValuesJsonNullWhenNoCaptures() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        instanceId,
        'WF',
        'StepA',
        null,
        null,
        null,
        null
      );
      System.assertEquals(
        null,
        ctx.getCapturedValuesJson(),
        'getCapturedValuesJson() must return null when nothing was captured'
      );
    }
  }

  @IsTest
  static void testOnceValuesAreJsonRoundTripped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Numbers and booleans JSON-round-trip to a consistent type so values are
      // byte-identical regardless of whether they come from in-memory or rehydrated.
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        instanceId,
        'WF',
        'StepA',
        null,
        null,
        null,
        null
      );
      ctx.once('num', new StepContextTestData.StringProducer('42'));
      String captured = ctx.getCapturedValuesJson();
      // Rehydrate into a new context
      StepContext ctx2 = StepContext.withCapturedValues(
        instanceId,
        'WF',
        'StepA',
        null,
        null,
        null,
        null,
        1,
        0,
        null,
        null,
        captured
      );
      StepContextTestData.StringProducer p2 = new StepContextTestData.StringProducer(
        'different'
      );
      Object v = ctx2.once('num', p2);
      System.assertEquals(
        '42',
        v,
        'Rehydrated value must match the originally captured value'
      );
      System.assertEquals(
        0,
        p2.callCount,
        'Producer must not be called on rehydration'
      );
    }
  }

  @IsTest
  static void testExposedRetryPropertiesAndDefaults() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        instanceId,
        'WF',
        'StepA',
        null,
        null,
        null,
        null
      );
      System.assertEquals(1, ctx.attempt, 'Default attempt should be 1');
      System.assertEquals(
        1,
        ctx.maxAttempts,
        'Default maxAttempts should be 1'
      );
      System.assert(
        ctx.isFinalAttempt(),
        'Default context should be final attempt'
      );
    }
  }

  @IsTest
  static void testExposedRetryPropertiesOverloads() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = StepContext.withCapturedValues(
        instanceId,
        'WF',
        'StepA',
        null,
        null,
        null,
        null,
        1,
        0,
        null,
        null,
        null,
        2,
        5
      );
      System.assertEquals(2, ctx.attempt);
      System.assertEquals(5, ctx.maxAttempts);
      System.assert(!ctx.isFinalAttempt());
    }
  }

  @IsTest
  static void testExposedRetryPropertiesFromCapturedValues() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
      String priorJson = JSON.serialize(
        new Map<String, Object>{
          'refNumber' => 'REF-001',
          '__maxAttempts' => 3
        }
      );
      StepContext ctx = StepContext.withCapturedValues(
        instanceId,
        'WF',
        'StepA',
        null,
        null,
        null,
        null,
        1,
        0,
        null,
        null,
        priorJson
      );
      System.assertEquals(1, ctx.attempt);
      System.assertEquals(3, ctx.maxAttempts);
      System.assert(!ctx.isFinalAttempt());
      // Verify that '__maxAttempts' was stripped from the in-memory captured values map (so a once() check executes the producer)
      System.assertEquals(
        5,
        Integer.valueOf(
          ctx.once('__maxAttempts', new StepContextTestData.ObjectProducer(5))
        ),
        'Should strip __maxAttempts from in-memory captured values'
      );
    }
  }

  @IsTest
  static void testExposedRetryPropertiesStatePreservationOnYield() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);
      String priorJson = JSON.serialize(
        new Map<String, Object>{
          'refNumber' => 'REF-001',
          '__maxAttempts' => 3
        }
      );
      // Hydrate
      StepContext ctx = StepContext.withCapturedValues(
        instanceId,
        'WF',
        'StepA',
        null,
        null,
        null,
        null,
        1,
        0,
        null,
        null,
        priorJson,
        1, // attempt
        3 // maxAttempts
      );
      System.assertEquals(3, ctx.maxAttempts);

      // Simulate step execution yielding and capturing a new value
      ctx.once('newValue', new StepContextTestData.ObjectProducer('val'));
      System.assert(ctx.hasNewCaptures());

      // Get serialized JSON to write back to db
      String outputJson = ctx.getCapturedValuesJson();
      System.assert(outputJson.contains('newValue'));
      System.assert(outputJson.contains('REF-001'));
      System.assert(outputJson.contains('__maxAttempts')); // MUST contain max attempts!

      // De-serialize and verify
      Map<String, Object> deserialized = (Map<String, Object>) JSON.deserializeUntyped(
        outputJson
      );
      System.assertEquals(
        3,
        Integer.valueOf(deserialized.get('__maxAttempts'))
      );
    }
  }

  @IsTest
  static void testRetryRobustnessDecimalAndMalformedJson() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = TestIdFactory.generate(Organization.SObjectType);

      // 1. Double/Decimal value parsed from JSON
      String decimalJson = '{"__maxAttempts":3.0}';
      StepContext ctx = StepContext.withCapturedValues(
        instanceId,
        'WF',
        'StepA',
        null,
        null,
        null,
        null,
        1,
        0,
        null,
        null,
        decimalJson
      );
      System.assertEquals(
        3,
        ctx.maxAttempts,
        'Should parse double/decimal attempts safely'
      );

      // 2. Malformed JSON should not crash
      StepContext ctx2 = StepContext.withCapturedValues(
        instanceId,
        'WF',
        'StepA',
        null,
        null,
        null,
        null,
        1,
        0,
        null,
        null,
        '{"__maxAttempts":'
      );
      System.assertEquals(
        1,
        ctx2.maxAttempts,
        'Should fallback to default 1 on malformed JSON'
      );
    }
  }

  @IsTest
  static void testReportProgress() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id dummyInstanceId = TestIdFactory.generate(Organization.SObjectType);
      StepContext ctx = new StepContext(
        dummyInstanceId,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null
      );

      System.assertEquals(false, ctx.isProgressReported());
      System.assertEquals(null, ctx.getProgressJson());

      ctx.reportProgress(42.5, 'Processing batch 3');
      System.assertEquals(true, ctx.isProgressReported());
      Map<String, Object> progress = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.getProgressJson()
      );
      System.assertEquals(42.5, (Decimal) progress.get('percentComplete'));
      System.assertEquals(
        'Processing batch 3',
        (String) progress.get('message')
      );

      ctx.reportProgress(new Map<String, Object>{ 'custom' => 'data' });
      System.assertEquals(true, ctx.isProgressReported());
      Map<String, Object> customProgress = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.getProgressJson()
      );
      System.assertEquals('data', (String) customProgress.get('custom'));

      ctx.reportProgress(null);
      System.assertEquals(true, ctx.isProgressReported());
      System.assertEquals(null, ctx.getProgressJson());
    }
  }

  @IsTest
  static void testAutoReplayAtYieldTime() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'TestWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'CorrKey-123'
      );
      insert inst;

      Workflow_Signal__c sig = new Workflow_Signal__c(
        Correlation_Key__c = 'CorrKey-123',
        Signal_Name__c = 'Go',
        Payload__c = '{"val":42}',
        Status__c = 'Unrouted'
      );
      insert sig;

      StepContext ctx = new StepContext(
        inst.Id,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null,
        1,
        new WorkflowEngine.PendingSignalSource(inst.Id)
      );

      // Call getSignal first to populate cache with empty result (no signals present yet in the context cache)
      System.assertEquals(false, ctx.getSignal('Go').isPresent());

      Test.startTest();
      WorkflowEngine.redeliverMatchingSignalsForInstance(
        inst.Id,
        inst.Correlation_Key__c
      );

      // Create a new context since the old one cached the empty signal list
      ctx = new StepContext(
        inst.Id,
        'TestWorkflow',
        'TestStep',
        null,
        null,
        null,
        null,
        1,
        new WorkflowEngine.PendingSignalSource(inst.Id)
      );
      Test.stopTest();

      Workflow_Signal__c reloadedSig = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Id = :sig.Id
      ];
      System.assertEquals('Received', reloadedSig.Status__c);
      System.assertEquals(inst.Id, reloadedSig.Workflow_Instance__c);

      // Cache should be cleared and the new signal should be returned
      StepContext.Signal fetched = ctx.getSignal('Go');
      System.assertEquals(true, fetched.isPresent());
      System.assertEquals('{"val":42}', fetched.payload);
    }
  }

  @IsTest
  static void testAutoReplayAtYieldTimeOldestFirst() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'TestWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'CorrKey-456'
      );
      insert inst;

      Workflow_Signal__c sig1 = new Workflow_Signal__c(
        Correlation_Key__c = 'CorrKey-456',
        Signal_Name__c = 'Go',
        Payload__c = '{"val":1}',
        Status__c = 'Unrouted'
      );
      insert sig1;

      Workflow_Signal__c sig2 = new Workflow_Signal__c(
        Correlation_Key__c = 'CorrKey-456',
        Signal_Name__c = 'Go',
        Payload__c = '{"val":2}',
        Status__c = 'Unrouted'
      );
      insert sig2;

      Test.startTest();
      WorkflowEngine.redeliverMatchingSignalsForInstance(
        inst.Id,
        inst.Correlation_Key__c
      );
      Test.stopTest();

      Workflow_Signal__c reloadedSig1 = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Id = :sig1.Id
      ];
      System.assertEquals(
        'Received',
        reloadedSig1.Status__c,
        'Oldest signal must be auto-delivered'
      );

      Workflow_Signal__c reloadedSig2 = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Id = :sig2.Id
      ];
      System.assertEquals(
        'Received',
        reloadedSig2.Status__c,
        'Newer signal must also be auto-delivered'
      );
    }
  }

  @IsTest
  static void testAutoReplayDrainsAllSignals() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'TestWorkflow',
        Status__c = 'Running',
        Correlation_Key__c = 'CorrKey-LargeBacklog'
      );
      insert inst;

      List<Workflow_Signal__c> signals = new List<Workflow_Signal__c>();
      // Insert 120 signals to exceed any previous 100-limit cap
      for (Integer i = 0; i < 120; i++) {
        signals.add(
          new Workflow_Signal__c(
            Correlation_Key__c = 'CorrKey-LargeBacklog',
            Signal_Name__c = 'Go',
            Payload__c = '{"val":' + i + '}',
            Status__c = 'Unrouted'
          )
        );
      }
      insert signals;

      Test.startTest();
      WorkflowEngine.redeliverMatchingSignalsForInstance(
        inst.Id,
        inst.Correlation_Key__c
      );
      Test.stopTest();

      List<Workflow_Signal__c> reloadedSignals = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Correlation_Key__c = 'CorrKey-LargeBacklog'
      ];
      System.assertEquals(120, reloadedSignals.size());
      for (Workflow_Signal__c sig : reloadedSignals) {
        System.assertEquals(
          'Received',
          sig.Status__c,
          'All signals in the large backlog must be auto-delivered'
        );
        System.assertEquals(
          inst.Id,
          sig.Workflow_Instance__c,
          'All signals must be bound to the correct instance'
        );
      }
    }
  }

  @IsTest
  static void testGetChildOutcomeNotPresent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = childOutcomeContext(
        new Map<String, StepContext.Signal>()
      );

      StepContext.ChildOutcome outcome = ctx.getChildOutcome('CC_1');
      System.assertEquals(false, outcome.isPresent());
      System.assertEquals(false, outcome.isSuccess());
      System.assertEquals(null, outcome.status);
      System.assertEquals(null, outcome.errorMessage);
      System.assertEquals(null, outcome.output);
    }
  }

  @IsTest
  static void testGetChildOutcomeCompleted() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = childOutcomeContext(
        'ChildCompleted:CC_1',
        '{"score":700}'
      );

      StepContext.ChildOutcome outcome = ctx.getChildOutcome('CC_1');
      System.assertEquals(true, outcome.isPresent());
      System.assertEquals(true, outcome.isSuccess());
      System.assertEquals('Completed', outcome.status);
      System.assertEquals(null, outcome.errorMessage);
      System.assertEquals('{"score":700}', outcome.output);
    }
  }

  @IsTest
  static void testGetChildOutcomeFailedStructured() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Map<String, StepContext.Signal> sigs = new Map<String, StepContext.Signal>{
        'childfailed:cc_1' => new StepContext.Signal(
          null,
          'ChildFailed:CC_1',
          '{"status":"Failed","errorMessage":"Step crashed","output":"partialData"}'
        )
      };
      StepContext ctx = childOutcomeContext(sigs);

      StepContext.ChildOutcome outcome = ctx.getChildOutcome('CC_1');
      System.assertEquals(true, outcome.isPresent());
      System.assertEquals(false, outcome.isSuccess());
      System.assertEquals('Failed', outcome.status);
      System.assertEquals('Step crashed', outcome.errorMessage);
      System.assertEquals('partialData', outcome.output);
    }
  }

  @IsTest
  static void testGetChildOutcomeFailedMalformed() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Map<String, StepContext.Signal> sigs = new Map<String, StepContext.Signal>{
        'childfailed:cc_1' => new StepContext.Signal(
          null,
          'ChildFailed:CC_1',
          'Raw error message string'
        )
      };
      StepContext ctx = childOutcomeContext(sigs);

      StepContext.ChildOutcome outcome = ctx.getChildOutcome('CC_1');
      System.assertEquals(true, outcome.isPresent());
      System.assertEquals(false, outcome.isSuccess());
      System.assertEquals('Failed', outcome.status);
      System.assertEquals('Raw error message string', outcome.errorMessage);
      System.assertEquals(null, outcome.output);
    }
  }

  @IsTest
  static void testGetChildOutcomeConsumesBothSignals() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = childOutcomeContext(
        'ChildCompleted:CC_1',
        '{"score":700}'
      );

      StepContext.ChildOutcome outcome = ctx.getChildOutcome('CC_1');
      System.assertEquals(true, outcome.isPresent());
      System.assertEquals(true, outcome.isSuccess());

      Set<String> consumedNames = ctx.getConsumedSignalNames();
      System.assert(
        consumedNames.contains('ChildCompleted:CC_1'),
        'Must consume ChildCompleted signal name'
      );
      System.assert(
        consumedNames.contains('ChildFailed:CC_1'),
        'Must consume ChildFailed signal name unconditionally to clean up duplicate/delayed sibling signals'
      );
    }
  }

  @IsTest
  static void testGetChildOutcomeConsumesBothSignalsWhenFailed() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Map<String, StepContext.Signal> sigs = new Map<String, StepContext.Signal>{
        'childfailed:cc_1' => new StepContext.Signal(
          null,
          'ChildFailed:CC_1',
          '{"status":"Failed"}'
        )
      };
      StepContext ctx = childOutcomeContext(sigs);

      StepContext.ChildOutcome outcome = ctx.getChildOutcome('CC_1');
      System.assertEquals(true, outcome.isPresent());
      System.assertEquals(false, outcome.isSuccess());

      Set<String> consumedNames = ctx.getConsumedSignalNames();
      System.assert(
        consumedNames.contains('ChildCompleted:CC_1'),
        'Must consume ChildCompleted signal name unconditionally'
      );
      System.assert(
        consumedNames.contains('ChildFailed:CC_1'),
        'Must consume ChildFailed signal name'
      );
    }
  }

  @IsTest
  static void testGetChildOutcomeDoesNotConsumeWhenAbsent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      StepContext ctx = childOutcomeContext(
        new Map<String, StepContext.Signal>()
      );

      StepContext.ChildOutcome outcome = ctx.getChildOutcome('CC_1');
      System.assertEquals(false, outcome.isPresent());

      Set<String> consumedNames = ctx.getConsumedSignalNames();
      System.assert(
        !consumedNames.contains('ChildCompleted:CC_1'),
        'Must not consume ChildCompleted signal name when absent'
      );
      System.assert(
        !consumedNames.contains('ChildFailed:CC_1'),
        'Must not consume ChildFailed signal name when absent'
      );
    }
  }
}
