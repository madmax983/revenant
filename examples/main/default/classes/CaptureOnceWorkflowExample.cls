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
   */
  public class ProducerCallCounter {
    public static Integer refNumberCalls = 0;
    public static Integer startedAtCalls = 0;
    public static void reset() {
      refNumberCalls = 0;
      startedAtCalls = 0;
    }
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

      // Use stepStateJson to track how many times we have been called so the
      // step can force a yield then a retry before finally completing.
      Integer runCount = 0;
      if (String.isNotBlank(ctx.stepStateJson)) {
        Map<String, Object> state = (Map<String, Object>) JSON.deserializeUntyped(
          ctx.stepStateJson
        );
        Object rc = state.get('runCount');
        if (rc instanceof Integer) {
          runCount = (Integer) rc;
        } else if (rc instanceof Long) {
          runCount = ((Long) rc).intValue();
        } else if (rc instanceof Decimal) {
          runCount = ((Decimal) rc).intValue();
        } else if (rc instanceof Double) {
          runCount = ((Double) rc).intValue();
        }
      }
      runCount++;

      String newState = JSON.serialize(
        new Map<String, Object>{ 'runCount' => runCount }
      );

      if (runCount == 1) {
        // First execution: yield to prove captures survive a yield/resume.
        return StepResult.yield(newState);
      } else if (runCount == 2) {
        // Second execution (after yield resume): retry to prove captures survive RETRY.
        return StepResult.retry(new RetryPolicy(1, 1.0, 3));
      }

      // Third execution: complete, echoing captured values in output.
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'refNumber' => refNumber,
          'startedAt' => startedAt,
          'runCount' => runCount
        }
      );
    }
  }

  private class RefNumberProducer implements CaptureProducer {
    public Object produce() {
      ProducerCallCounter.refNumberCalls++;
      Blob randomBytes = Crypto.generateAesKey(128);
      String hex = EncodingUtil.convertToHex(randomBytes)
        .substring(0, 16)
        .toUpperCase();
      return 'REF-' + hex;
    }
  }

  private class StartedAtProducer implements CaptureProducer {
    public Object produce() {
      ProducerCallCounter.startedAtCalls++;
      return String.valueOf(Datetime.now().getTime());
    }
  }
}
