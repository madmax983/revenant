@IsTest
public class BulkWorkflowTestHelpers {
  /**
   * Rebuilds the driving StepContext for each chunk transaction, threading the
   * yielded step state (null on the first run) forward. Implemented by each test
   * class so the shared drive loop below stays workflow-agnostic.
   */
  public interface ChunkContextFactory {
    StepContext build(String stepStateJson);
  }

  /**
   * Drives a chunked bulk step through two YIELD transactions and a terminal
   * COMPLETE, asserting the action at each chunk boundary inside a single
   * Test.startTest/stopTest window. Returns the final StepResult so the caller
   * can assert its summary payload.
   *
   * Extracted from the identical drive-and-assert loops in
   * BulkCancelWorkflowTest and BulkRedriveWorkflowTest.
   */
  public static StepResult driveTwoYieldsThenComplete(
    WorkflowStep step,
    ChunkContextFactory contexts
  ) {
    Test.startTest();
    StepResult r1 = step.execute(contexts.build(null));
    System.assertEquals(
      StepResult.ActionType.YIELD,
      r1.action,
      'A selection larger than one chunk must yield to a fresh transaction'
    );
    StepResult r2 = step.execute(contexts.build(r1.stepStateJson));
    System.assertEquals(StepResult.ActionType.YIELD, r2.action);
    StepResult r3 = step.execute(contexts.build(r2.stepStateJson));
    Test.stopTest();

    System.assertEquals(
      StepResult.ActionType.COMPLETE,
      r3.action,
      'Final chunk completes the bulk operation'
    );
    return r3;
  }
}
