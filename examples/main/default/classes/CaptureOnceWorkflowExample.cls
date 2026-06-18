/**
 * Reference example: capture-once API (StepContext.once()).
 *
 * Demonstrates that a generated reference number and a timestamp captured via
 * once() are stable across multiple re-executions of the same logical step —
 * including a forced yield/resume and a forced retry — driven by
 * WorkflowTestHarness.
 *
 * Key contrast with idempotencyKey:
 *   - idempotencyKey  → forward to an EXTERNAL system (e.g. a Stripe header)
 *                       to make an external API call effective-once.
 *   - once()          → stabilize a VALUE generated LOCALLY inside a step so
 *                       it does not drift across retries, resumes, or re-drives.
 *
 * See README.md for a full explanation of when to use each primitive.
 */
public inherited sharing class CaptureOnceWorkflowExample {
  /**
   * Counts how many times each producer was invoked across all executions.
   * The test asserts these are both 1, proving once() never re-invokes the
   * producer after the first capture.
   *
   * These live on the top-level class because Apex permits static members only
   * on a top-level type, not on an inner class.
   */
  public static Integer refNumberCalls = 0;
  public static Integer startedAtCalls = 0;
  public static void resetProducerCounters() {
    refNumberCalls = 0;
    startedAtCalls = 0;
  }

  public class CaptureOnceWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'CaptureOnceWorkflowExample.CaptureOnceStep';
    }
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  /**
   * On the first execution the step:
   *   1. Captures a generated reference number and a timestamp via once().
   *   2. Yields (checkpoints; commits captures to Captured_Values__c).
   *
   * On the second execution (resume after yield) the step:
   *   3. Reads the same captured values (producers NOT called again).
   *   4. Returns StepResult.retry() (commits; Captured_Values__c is untouched).
   *
   * On the third execution (resume after retry) the step:
   *   5. Reads the same captured values again (producers still NOT called).
   *   6. Completes, echoing the captured values in its output.
   *
   * Sequencing note: we cannot drive this yield -> retry -> complete progression
   * off stepStateJson alone, because the engine's RETRY handler clears Output__c
   * (and therefore stepStateJson) before scheduling the next attempt. Instead we
   * use the durable Retry_Count__c on this step's own execution row, which DOES
   * survive the retry, to tell a post-retry resume apart from a fresh first run.
   * Captured_Values__c likewise survives every one of these re-executions
   * unchanged — which is exactly what once() guarantees and what this example
   * proves.
   *
   * The test uses WorkflowTestHarness.drive() which auto-resumes yield and
   * retry waits, driving the step through all three re-executions in one call.
   */
  public class CaptureOnceStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Capture a generated reference number — stable across all re-executions.
      String refNumber = (String) ctx.once(
        'refNumber',
        new RefNumberProducer()
      );

      // Capture the step's logical start time — stable across all re-executions.
      String startedAt = (String) ctx.once(
        'startedAt',
        new StartedAtProducer()
      );

      Integer retryCount = currentRetryCount(ctx);
      Boolean resumedFromYield = String.isNotBlank(ctx.stepStateJson);

      if (retryCount == 0 && !resumedFromYield) {
        // First execution: yield to prove captures survive a yield/resume.
        return StepResult.yield('{"phase":"yielded"}');
      }
      if (retryCount == 0 && resumedFromYield) {
        // Resumed after the yield: retry to prove captures survive a RETRY (which
        // increments Retry_Count__c and clears Output__c, but not Captured_Values__c).
        return StepResult.retry(new RetryPolicy(1, (Double) 1.0, 3));
      }

      // Resumed after the retry (Retry_Count__c >= 1): complete, echoing the
      // captured values so the test can assert they never drifted.
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'refNumber' => refNumber,
          'startedAt' => startedAt
        }
      );
    }

    // Reads the durable retry count for this step's current execution. Unlike
    // stepStateJson (cleared on RETRY), Retry_Count__c persists across the retry,
    // so it deterministically distinguishes a fresh run (0) from a post-retry
    // resume (>= 1).
    private Integer currentRetryCount(StepContext ctx) {
      List<Workflow_Step_Execution__c> execs = [
        SELECT Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :ctx.workflowInstanceId
          AND Step_Name__c = :ctx.stepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      if (execs.isEmpty() || execs[0].Retry_Count__c == null) {
        return 0;
      }
      return execs[0].Retry_Count__c.intValue();
    }
  }

  private class RefNumberProducer implements CaptureProducer {
    public Object produce() {
      CaptureOnceWorkflowExample.refNumberCalls++;
      Blob randomBytes = Crypto.generateAesKey(128);
      String hex = EncodingUtil.convertToHex(randomBytes)
        .substring(0, 16)
        .toUpperCase();
      return 'REF-' + hex;
    }
  }

  private class StartedAtProducer implements CaptureProducer {
    public Object produce() {
      CaptureOnceWorkflowExample.startedAtCalls++;
      return String.valueOf(Datetime.now().getTime());
    }
  }
}
