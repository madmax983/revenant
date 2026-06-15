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

  // ---------------------------------------------------------------------------
  // Idempotency key (issue #2)
  // ---------------------------------------------------------------------------

  @isTest
  static void testIdempotencyKeyIsNonBlankAndStableAcrossAttempts() {
    // Two contexts for the SAME logical (instance, step) but representing
    // different attempts: different previous output, step state, workflow
    // input, and even workflow version. A transient RetryPolicy retry, an
    // operator re-drive (#1), and an at-least-once Workflow_Event__e resume all
    // re-build a context like this -> the key must be identical every time.
    Id instanceId = '00D000000000001';
    StepContext attemptA = new StepContext(
      instanceId,
      'WF',
      'StepA',
      '{"input":1}',
      null,
      null,
      '{"wf":1}'
    );
    StepContext attemptB = new StepContext(
      instanceId,
      'WF',
      'StepA',
      '{"input":1}',
      '{"prev":"changed"}',
      '{"state":"changed"}',
      '{"wf":1}',
      9
    );

    System.assert(
      String.isNotBlank(attemptA.idempotencyKey),
      'idempotencyKey must be exposed and non-blank inside execute()'
    );
    System.assertEquals(
      attemptA.idempotencyKey,
      attemptB.idempotencyKey,
      'idempotencyKey must be stable across retries/re-drives of the same logical (instance, step)'
    );
  }

  @isTest
  static void testIdempotencyKeyDistinctPerStep() {
    Id instanceId = '00D000000000001';
    StepContext stepA = new StepContext(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null
    );
    StepContext stepB = new StepContext(
      instanceId,
      'WF',
      'StepB',
      null,
      null,
      null,
      null
    );
    System.assertNotEquals(
      stepA.idempotencyKey,
      stepB.idempotencyKey,
      'Two different steps in one instance must observe different keys'
    );
  }

  @isTest
  static void testIdempotencyKeyDistinctPerInstance() {
    // The same step name across two different instances (e.g. two parallel
    // fan-out branch instances with different Parent_Instance__c, or the same
    // step in two separate runs) must observe different keys.
    StepContext branchOne = new StepContext(
      '00D000000000001',
      'WF',
      'StepA',
      null,
      null,
      null,
      null
    );
    StepContext branchTwo = new StepContext(
      '00D000000000002',
      'WF',
      'StepA',
      null,
      null,
      null,
      null
    );
    System.assertNotEquals(
      branchOne.idempotencyKey,
      branchTwo.idempotencyKey,
      'The same step in two different instances must observe different keys'
    );
  }

  @isTest
  static void testIdempotencyKeyCompensateDistinctAndStable() {
    // The engine builds a compensate() context with stepName "<step>_Compensate"
    // (see WorkflowEngine.runCompensationStep). So the compensation key is
    // distinct from the forward execution key yet stable across compensation
    // retries.
    Id instanceId = '00D000000000001';
    StepContext forward = new StepContext(
      instanceId,
      'WF',
      'ChargeStep',
      null,
      null,
      null,
      null
    );
    StepContext compensate = new StepContext(
      instanceId,
      'WF',
      'ChargeStep_Compensate',
      null,
      null,
      null,
      null
    );
    StepContext compensateRetry = new StepContext(
      instanceId,
      'WF',
      'ChargeStep_Compensate',
      '{"different":"state"}',
      null,
      null,
      null
    );

    System.assertNotEquals(
      forward.idempotencyKey,
      compensate.idempotencyKey,
      'compensate() must observe a key distinct from the forward execution key'
    );
    System.assertEquals(
      compensate.idempotencyKey,
      compensateRetry.idempotencyKey,
      'compensate() key must be stable across compensation retries'
    );
  }

  @isTest
  static void testIdempotencyKeyDistinctPerVisit() {
    // When a workflow loops back to the same step in the same instance, each
    // completed visit must observe a different key so distinct side effects are
    // not wrongly deduped; the engine supplies an incrementing visit sequence.
    Id instanceId = '00D000000000001';
    StepContext visitZero = new StepContext(
      instanceId,
      'WF',
      'PollStep',
      null,
      null,
      null,
      null,
      1,
      0
    );
    StepContext visitOne = new StepContext(
      instanceId,
      'WF',
      'PollStep',
      null,
      null,
      null,
      null,
      1,
      1
    );
    // A retry/re-drive/resume of the SAME visit rebuilds the context with the
    // same visit sequence even though other state differs.
    StepContext visitOneRetry = new StepContext(
      instanceId,
      'WF',
      'PollStep',
      '{"changed":true}',
      null,
      null,
      null,
      1,
      1
    );

    System.assertNotEquals(
      visitZero.idempotencyKey,
      visitOne.idempotencyKey,
      'Two different completed visits of the same step must observe different keys'
    );
    System.assertEquals(
      visitOne.idempotencyKey,
      visitOneRetry.idempotencyKey,
      'Retries/re-drives of the same visit must observe the identical key'
    );
  }

  @isTest
  static void testIdempotencyKeyDefaultVisitMatchesExplicitZero() {
    // The additive visit param defaults to 0, so the 8-arg constructor and the
    // 9-arg constructor with stepVisit=0 must yield the identical key.
    Id instanceId = '00D000000000001';
    StepContext defaulted = new StepContext(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null,
      1
    );
    StepContext explicitZero = new StepContext(
      instanceId,
      'WF',
      'StepA',
      null,
      null,
      null,
      null,
      1,
      0
    );
    System.assertEquals(
      defaulted.idempotencyKey,
      explicitZero.idempotencyKey,
      'Default visit (0) must match an explicit stepVisit of 0'
    );
  }
}
