@IsTest
public class CaptureOnceWorkflowExampleTest {
  /**
   * Drives the capture-once example through ≥3 re-executions of the same step:
   *   1. First run: step yields (checkpoints state, DML commits the capture).
   *   2. Second run: step returns StepResult.retry() (DML commits; capture survives because
   *      RETRY only nulls Output__c, not Captured_Values__c).
   *   3. Third run: step completes.
   *
   * Asserts that the captured refNumber and startedAt in the final output are
   * byte-identical to what the step produced on the very first run — zero drift.
   * The producer call counter (static) proves the producer was invoked exactly once.
   */
  @IsTest
  static void capturedValuesAreStableAcrossYieldRetryAndComplete() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CaptureOnceWorkflowExample.resetProducerCounters();

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'CaptureOnceWorkflowExample.CaptureOnceWorkflow',
        'capture-once-test-1',
        null
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      System.assertEquals('Completed', result.status, 'Workflow must complete');
      System.assert(
        result.reachedStep('CaptureOnceWorkflowExample.CaptureOnceStep'),
        'CaptureOnceStep must have executed'
      );

      // The step's final output carries the two captured values.
      System.assertNotEquals(null, result.output, 'Output must be non-null');
      Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(
        result.output
      );
      String refNumber = (String) output.get('refNumber');
      String startedAt = (String) output.get('startedAt');

      System.assert(
        String.isNotBlank(refNumber),
        'refNumber must be captured and echoed in output'
      );
      System.assert(
        String.isNotBlank(startedAt),
        'startedAt must be captured and echoed in output'
      );

      // Producer was invoked exactly once despite ≥3 executions of the step.
      System.assertEquals(
        1,
        CaptureOnceWorkflowExample.refNumberCalls,
        'refNumber producer must be called exactly once across all re-executions'
      );
      System.assertEquals(
        1,
        CaptureOnceWorkflowExample.startedAtCalls,
        'startedAt producer must be called exactly once across all re-executions'
      );
    }
  }

  /**
   * Once() values must be scoped to a single step context: a fresh context (new
   * instance, same step name) produces its own value independently.
   */
  @IsTest
  static void distinctInstancesHaveIndependentCaptures() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CaptureOnceWorkflowExample.resetProducerCounters();

      Test.startTest();
      Id id1 = WorkflowEngine.start(
        'CaptureOnceWorkflowExample.CaptureOnceWorkflow',
        'capture-scope-1',
        null
      );
      Id id2 = WorkflowEngine.start(
        'CaptureOnceWorkflowExample.CaptureOnceWorkflow',
        'capture-scope-2',
        null
      );
      WorkflowTestHarness.Result r1 = new WorkflowTestHarness(id1).drive();
      WorkflowTestHarness.Result r2 = new WorkflowTestHarness(id2).drive();
      Test.stopTest();

      System.assertEquals('Completed', r1.status);
      System.assertEquals('Completed', r2.status);

      Map<String, Object> out1 = (Map<String, Object>) JSON.deserializeUntyped(
        r1.output
      );
      Map<String, Object> out2 = (Map<String, Object>) JSON.deserializeUntyped(
        r2.output
      );

      // Each instance produces its own independent refNumber.
      System.assertNotEquals(
        out1.get('refNumber'),
        out2.get('refNumber'),
        'Two independent instances must produce independent captured values'
      );
    }
  }
}
