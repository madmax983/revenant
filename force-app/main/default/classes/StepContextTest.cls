@isTest
public class StepContextTest {
  @isTest
  static void testConstructorAndProperties() {
    Id dummyInstanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      '{"input": 1}',
      '{"prev": 2}',
      '{"state": 3}',
      '{"wfInput": 4}'
    );

    System.assertEquals(dummyInstanceId, ctx.workflowInstanceId);
    System.assertEquals('TestWorkflow', ctx.workflowName);
    System.assertEquals('TestStep', ctx.stepName);
    System.assertEquals('{"input": 1}', ctx.inputJson);
    System.assertEquals('{"prev": 2}', ctx.previousStepOutput);
    System.assertEquals('{"state": 3}', ctx.stepStateJson);
    System.assertEquals('{"wfInput": 4}', ctx.workflowInputJson);
    System.assertEquals(1, ctx.workflowVersion);
  }

  @isTest
  static void testConstructorWithVersion() {
    Id dummyInstanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      '{"input": 1}',
      '{"prev": 2}',
      '{"state": 3}',
      '{"wfInput": 4}',
      3
    );

    System.assertEquals(dummyInstanceId, ctx.workflowInstanceId);
    System.assertEquals('TestWorkflow', ctx.workflowName);
    System.assertEquals('TestStep', ctx.stepName);
    System.assertEquals('{"input": 1}', ctx.inputJson);
    System.assertEquals('{"prev": 2}', ctx.previousStepOutput);
    System.assertEquals('{"state": 3}', ctx.stepStateJson);
    System.assertEquals('{"wfInput": 4}', ctx.workflowInputJson);
    System.assertEquals(3, ctx.workflowVersion);
  }

  @isTest
  static void testShouldYieldNormalConditions() {
    Id dummyInstanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null
    );

    // Under normal test execution conditions, limits should not be exceeded
    System.assertEquals(
      false,
      ctx.shouldYield(),
      'shouldYield should be false under normal conditions'
    );
  }

  @isTest
  static void testShouldYieldQueryRowsThresholdExceeded() {
    Id dummyInstanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null
    );

    // Set mock to trigger SOQL query row limits checking logic
    StepContext.mockQueryRowsFraction = 0.81;
    System.assertEquals(
      true,
      ctx.shouldYield(),
      'shouldYield should return true when query rows exceed 80%'
    );

    StepContext.mockQueryRowsFraction = 0.80;
    System.assertEquals(
      false,
      ctx.shouldYield(),
      'shouldYield should return false when query rows are exactly 80%'
    );

    StepContext.mockQueryRowsFraction = 0.79;
    System.assertEquals(
      false,
      ctx.shouldYield(),
      'shouldYield should return false when query rows are below 80%'
    );
  }

  @isTest
  static void testShouldYieldAsyncApexExecutionsLimit() {
    Id dummyInstanceId = '00D000000000001EAA';
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null
    );

    // Set mock fraction above 80%
    StepContext.mockAsyncExecutionsFraction = 0.81;
    System.assertEquals(
      true,
      ctx.shouldYield(),
      'shouldYield should return true when async executions exceed 80%'
    );

    // Set mock fraction at 80%
    StepContext.mockAsyncExecutionsFraction = 0.80;
    System.assertEquals(
      false,
      ctx.shouldYield(),
      'shouldYield should return false when async executions are exactly 80%'
    );

    // Set mock fraction below 80%
    StepContext.mockAsyncExecutionsFraction = 0.79;
    System.assertEquals(
      false,
      ctx.shouldYield(),
      'shouldYield should return false when async executions are below 80%'
    );

    // Reset
    StepContext.mockAsyncExecutionsFraction = null;
  }

  // --- Inbound signal payload accessors (issue #11) ---

  @isTest
  static void testNoPendingSignalsReturnsCleanEmptyResult() {
    Id dummyInstanceId = '00D000000000001EAA';
    // Construct via the existing 8-arg constructor (no signals supplied).
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null,
      1
    );

    System.assertEquals(
      0,
      ctx.getSignals().size(),
      'getSignals() must return an empty (never null) list when none pending'
    );
    System.assertEquals(
      0,
      ctx.getSignals('Anything').size(),
      'getSignals(name) must return an empty list when none pending'
    );
    System.assertEquals(
      false,
      ctx.hasSignal('Anything'),
      'hasSignal must be false when none pending'
    );

    StepContext.Signal sig = ctx.getSignal('Anything');
    System.assertNotEquals(
      null,
      sig,
      'getSignal must never return null (clean empty result)'
    );
    System.assertEquals(
      false,
      sig.isPresent(),
      'Empty signal must report isPresent() == false'
    );
    System.assertEquals(
      null,
      sig.payload,
      'Empty signal payload must be null, not a null-deref hazard'
    );
  }

  @isTest
  static void testPendingSignalsExposedInArrivalOrder() {
    Id dummyInstanceId = '00D000000000001EAA';
    List<StepContext.Signal> pending = new List<StepContext.Signal>{
      new StepContext.Signal(null, 'First', '{"n":1}'),
      new StepContext.Signal(null, 'Second', '{"n":2}'),
      new StepContext.Signal(null, 'First', '{"n":3}')
    };
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null,
      1,
      pending
    );

    List<StepContext.Signal> all = ctx.getSignals();
    System.assertEquals(3, all.size(), 'All pending signals must be exposed');
    System.assertEquals('First', all[0].name);
    System.assertEquals('{"n":1}', all[0].payload);
    System.assertEquals('Second', all[1].name);
    System.assertEquals('First', all[2].name);
  }

  @isTest
  static void testGetSignalReturnsMostRecentMatchingName() {
    Id dummyInstanceId = '00D000000000001EAA';
    List<StepContext.Signal> pending = new List<StepContext.Signal>{
      new StepContext.Signal(null, 'Approval', '{"approved":true}'),
      new StepContext.Signal(null, 'Other', '{"x":1}'),
      new StepContext.Signal(null, 'Approval', '{"approved":false}')
    };
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null,
      1,
      pending
    );

    StepContext.Signal latest = ctx.getSignal('Approval');
    System.assertEquals(true, latest.isPresent());
    System.assertEquals(
      '{"approved":false}',
      latest.payload,
      'getSignal must return the most recent (last-arriving) signal of that name'
    );

    List<StepContext.Signal> approvals = ctx.getSignals('Approval');
    System.assertEquals(2, approvals.size());
    System.assertEquals(true, ctx.hasSignal('Approval'));
    System.assertEquals(false, ctx.hasSignal('Nope'));
  }

  @isTest
  static void testConsumedSignalIdsTracksObservedNamesOnly() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'X',
      Status__c = 'Running'
    );
    insert inst;

    Workflow_Signal__c sA = new Workflow_Signal__c(
      Workflow_Instance__c = inst.Id,
      Signal_Name__c = 'Approval',
      Payload__c = '{"approved":false}',
      Status__c = 'Received'
    );
    Workflow_Signal__c sB = new Workflow_Signal__c(
      Workflow_Instance__c = inst.Id,
      Signal_Name__c = 'Other',
      Payload__c = '{"x":1}',
      Status__c = 'Received'
    );
    insert new List<Workflow_Signal__c>{ sA, sB };

    List<StepContext.Signal> pending = new List<StepContext.Signal>{
      new StepContext.Signal(sA.Id, 'Approval', sA.Payload__c),
      new StepContext.Signal(sB.Id, 'Other', sB.Payload__c)
    };
    StepContext ctx = new StepContext(
      inst.Id,
      'X',
      'Step',
      null,
      null,
      null,
      null,
      1,
      pending
    );

    // Before observing anything, nothing is consumable.
    System.assertEquals(
      0,
      ctx.getConsumedSignalIds().size(),
      'Nothing is consumed until observed'
    );

    // Observe only the "Approval" name.
    ctx.getSignal('Approval');
    Set<Id> consumed = ctx.getConsumedSignalIds();
    System.assertEquals(
      1,
      consumed.size(),
      'Only observed signal names should be consumable'
    );
    System.assert(
      consumed.contains(sA.Id),
      'Observed Approval signal must be consumable'
    );
    System.assert(
      !consumed.contains(sB.Id),
      'Unobserved Other signal must NOT be consumed'
    );
  }

  @isTest
  static void testGetSignalsAllMarksEverythingObserved() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'X',
      Status__c = 'Running'
    );
    insert inst;

    Workflow_Signal__c sA = new Workflow_Signal__c(
      Workflow_Instance__c = inst.Id,
      Signal_Name__c = 'A',
      Payload__c = 'a',
      Status__c = 'Received'
    );
    Workflow_Signal__c sB = new Workflow_Signal__c(
      Workflow_Instance__c = inst.Id,
      Signal_Name__c = 'B',
      Payload__c = 'b',
      Status__c = 'Received'
    );
    insert new List<Workflow_Signal__c>{ sA, sB };

    List<StepContext.Signal> pending = new List<StepContext.Signal>{
      new StepContext.Signal(sA.Id, 'A', 'a'),
      new StepContext.Signal(sB.Id, 'B', 'b')
    };
    StepContext ctx = new StepContext(
      inst.Id,
      'X',
      'Step',
      null,
      null,
      null,
      null,
      1,
      pending
    );

    // Reading the full list observes every pending signal.
    ctx.getSignals();
    System.assertEquals(
      2,
      ctx.getConsumedSignalIds().size(),
      'getSignals() (all) must mark every pending signal observed'
    );
  }

  @isTest
  static void testBlankNamedLookupMatchesNothing() {
    Id dummyInstanceId = '00D000000000001EAA';
    List<StepContext.Signal> pending = new List<StepContext.Signal>{
      new StepContext.Signal(null, 'Real', '{"v":1}')
    };
    StepContext ctx = new StepContext(
      dummyInstanceId,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null,
      1,
      pending
    );

    // A blank/null name must never fall through to the unscoped (all) query and
    // must not mark unrelated signals observed/consumable.
    System.assertEquals(false, ctx.getSignal('').isPresent());
    System.assertEquals(false, ctx.getSignal(null).isPresent());
    System.assertEquals(false, ctx.hasSignal(''));
    System.assertEquals(0, ctx.getSignals('').size());
    System.assertEquals(
      0,
      ctx.getConsumedSignalIds().size(),
      'A blank named lookup must not mark any signal consumable'
    );
  }
}
