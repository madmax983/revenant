@IsTest
public class WorkflowEngineMocksATest {
  public static Boolean failParallelC = true;
  public static Boolean shouldSucceedOnFailingStep = false;
  public static Boolean compensationShouldFail = false;
  public static Datetime capturedCompensatePreviousRunAt = null;
  public static Boolean compensatePreviousRunAtCaptured = false;
  public static Boolean cancelWordCompensationShouldFail = false;
  public static Boolean capturedIsTimeoutResume = null;
  public static List<Map<String, Object>> observedAttemptStates = new List<Map<String, Object>>();
  public static List<Map<String, Object>> dynamicObservedStates = new List<Map<String, Object>>();

  /**
   * @description HttpCalloutMock that returns a 200 JSON success body, used to
   * satisfy steps that perform HTTP callouts during engine tests.
   */
  public class MockCalloutResponse implements HttpCalloutMock {
    /**
     * @description Answers any request with a 200 application/json success body.
     * @param req The outbound HTTP request being mocked.
     * @return A canned 200 response carrying a success JSON payload.
     */
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setHeader('Content-Type', 'application/json');
      res.setBody('{"status":"success"}');
      res.setStatusCode(200);
      return res;
    }
  }

  /**
   * @description Workflow definition exercising a large parallel split/join whose
   * split and join steps live in the sibling mock class, used to test parallel
   * fan-out across large step sets.
   */
  public class LargeParallelWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the split, branch, and join steps of the parallel DAG.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.LargeParallelSplitStep',
        'WorkflowEngineMocksATest.LargeOutputStep',
        'WorkflowEngineMocksATest.ParallelStep2',
        'WorkflowEngineMocksBTest.LargeParallelJoinStep'
      };
    }
    /**
     * @description Names the split step where instances begin.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.LargeParallelSplitStep';
    }
    /**
     * @description Routes the split step to the join step; all other completions
     * terminate the workflow.
     * @param currentStepName The step that just completed.
     * @param result The result of the completed step.
     * @return The join step name after the split, otherwise null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (
        currentStepName == 'WorkflowEngineMocksBTest.LargeParallelSplitStep'
      ) {
        return 'WorkflowEngineMocksBTest.LargeParallelJoinStep';
      }
      return null;
    }
  }

  /**
   * @description Step that emits an oversized (~110KB) output string to test that
   * the engine durably persists large step outputs.
   */
  public class LargeOutputStep implements WorkflowStep {
    /**
     * @description Completes with a ~110KB output payload.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult carrying the large output string.
     */
    public StepResult execute(StepContext ctx) {
      String largeStr = 'a'.repeat(110000);
      return StepResult.complete(null, largeStr);
    }
  }

  /**
   * @description Single-step definition used to test large workflow-input payload
   * handling.
   */
  public class LargePayloadWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single large-payload step.
     * @return The list containing the sole step name.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.LargePayloadStep' };
    }
    /**
     * @description Names the sole step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.LargePayloadStep';
    }
    /**
     * @description Terminal single-step workflow with no successor.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Step asserting that a large (>100KB) workflow input survived
   * durable persistence before returning a large output.
   */
  public class LargePayloadStep implements WorkflowStep {
    /**
     * @description Asserts the workflow input JSON is present and oversized, then
     * completes with a large output.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult carrying a large output string.
     */
    public StepResult execute(StepContext ctx) {
      System.assertNotEquals(null, ctx.workflowInputJson);
      System.assert(ctx.workflowInputJson.length() > 100000);
      return StepResult.complete(null, 'B'.repeat(110000));
    }
  }

  /**
   * @description Plain state holder capturing chunked-yielding progress as a
   * processed/total pair across resumes.
   */
  public class YieldingChunkState {
    /** @description Number of items processed so far across yields. */
    public Integer processed;
    /** @description Total number of items to be processed. */
    public Integer total;
  }

  /**
   * @description Definition wrapping a step that throws, used to test the engine's
   * crash-handling and finalizer recovery path.
   */
  public class CrashingWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single crashing step.
     * @return The list containing the sole step name.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.CrashingStep' };
    }
    /**
     * @description Names the crashing step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.CrashingStep';
    }
    /**
     * @description Terminal single-step workflow with no successor.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Step that throws an unhandled exception to simulate an
   * uncontrolled step crash.
   */
  public class CrashingStep implements WorkflowStep {
    /**
     * @description Throws immediately to simulate a crashing step.
     * @param ctx The durable per-step execution context.
     * @return Never returns; always throws IllegalArgumentException.
     */
    public StepResult execute(StepContext ctx) {
      throw new IllegalArgumentException('Simulated Crash');
    }
  }

  /**
   * @description Single-step definition wrapping a step that fails, used to test
   * failure handling.
   */
  public class FailingWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single failing step.
     * @return The list containing the sole step name.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.FailingStep' };
    }
    /**
     * @description Names the failing step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.FailingStep';
    }
    /**
     * @description Terminal single-step workflow with no successor.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Single-step definition used to test approval-signal wait and
   * resume behaviour.
   */
  public class ApprovalWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single approval step.
     * @return The list containing the sole step name.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.ApprovalStep' };
    }
    /**
     * @description Names the approval step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.ApprovalStep';
    }
    /**
     * @description Terminal single-step workflow with no successor.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Step that parks for a manager approval signal and, once the
   * matching received signal exists, consumes it exactly once and completes.
   */
  public class ApprovalStep implements WorkflowStep {
    /**
     * @description Waits for approval when no received signal is present;
     * otherwise consumes the signal and completes as approved.
     * @param ctx The durable per-step execution context.
     * @return A wait-for-approval result, or a completed result once approved.
     */
    public StepResult execute(StepContext ctx) {
      List<Workflow_Signal__c> signals = [
        SELECT Id, Signal_Name__c, Payload__c
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :ctx.workflowInstanceId
          AND Signal_Name__c = 'Approve:ExpenseApproval'
          AND Status__c = 'Received'
        LIMIT 1
      ];

      if (signals.isEmpty()) {
        return StepResult.waitForApproval('ExpenseApproval', 'Manager');
      }

      Workflow_Signal__c sig = signals[0];
      sig.Status__c = 'Consumed';
      update sig;

      return StepResult.complete(null, 'Approved');
    }
  }

  /**
   * @description Step that always requests a retry with a fixed delay, used to
   * test retry scheduling.
   */
  public class RetryingStep implements WorkflowStep {
    /**
     * @description Requests a retry after 5 seconds.
     * @param ctx The durable per-step execution context.
     * @return A retry StepResult with a 5-second delay.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.retry(5);
    }
  }

  /**
   * @description Step that suspends until a PaymentReceived signal arrives, then
   * consumes it once and completes with the signal payload.
   */
  public class SignaledStep implements WorkflowStep {
    /**
     * @description Suspends when the payment signal is absent; otherwise consumes
     * it and completes with the payload appended.
     * @param ctx The durable per-step execution context.
     * @return A suspend result, or a completed result carrying the payment payload.
     */
    public StepResult execute(StepContext ctx) {
      List<Workflow_Signal__c> signals = [
        SELECT Id, Payload__c
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :ctx.workflowInstanceId
          AND Signal_Name__c = 'PaymentReceived'
          AND Status__c = 'Received'
        LIMIT 1
      ];

      if (signals.isEmpty()) {
        return StepResult.suspend();
      }

      Workflow_Signal__c sig = signals[0];
      sig.Status__c = 'Consumed';
      update sig;

      return StepResult.complete(null, 'Paid_' + sig.Payload__c);
    }
  }

  /**
   * @description Two-step definition exercising a durable timer sleep followed by
   * a resume step.
   */
  public class SleepingWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the sleeping step and its after-sleep successor.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.SleepingStep',
        'WorkflowEngineMocksBTest.AfterSleepStep'
      };
    }
    /**
     * @description Names the sleeping step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.SleepingStep';
    }
    /**
     * @description Routes the sleeping step to the after-sleep step; otherwise
     * terminates.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return The after-sleep step name, or null when complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineMocksBTest.SleepingStep') {
        return 'WorkflowEngineMocksBTest.AfterSleepStep';
      }
      return null;
    }
  }

  /**
   * @description Parent-side definition used to test starting and awaiting a child
   * workflow.
   */
  public class ParentWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single parent step.
     * @return The list containing the sole step name.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.ParentStep' };
    }
    /**
     * @description Names the parent step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.ParentStep';
    }
    /**
     * @description Terminal single-step workflow with no successor.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Child-side definition started by a parent workflow to test
   * parent/child orchestration.
   */
  public class ChildWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single child step.
     * @return The list containing the sole step name.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.ChildStep' };
    }
    /**
     * @description Names the child step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.ChildStep';
    }
    /**
     * @description Terminal single-step workflow with no successor.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Child step that echoes its deserialized input with a _ChildDone
   * suffix, letting the parent assert the child ran.
   */
  public class ChildStep implements WorkflowStep {
    /**
     * @description Completes with the input string suffixed by _ChildDone.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult carrying the suffixed input.
     */
    public StepResult execute(StepContext ctx) {
      String input = (String) JSON.deserialize(ctx.inputJson, String.class);
      return StepResult.complete(null, input + '_ChildDone');
    }
  }

  /**
   * @description Step that fans out into two parallel branches, used to test
   * split/branch input propagation.
   */
  public class SplitStep implements WorkflowStep {
    /**
     * @description Splits execution into ParallelStep1 and ParallelStep2 with a
     * shared branch input.
     * @param ctx The durable per-step execution context.
     * @return A split StepResult naming the two parallel branch steps.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowEngineMocksATest.ParallelStep1',
          'WorkflowEngineMocksATest.ParallelStep2'
        },
        'BranchInput'
      );
    }
  }

  /**
   * @description Parallel branch step that echoes its input with a _P1Done suffix.
   */
  public class ParallelStep1 implements WorkflowStep {
    /**
     * @description Completes with the branch input suffixed by _P1Done.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult carrying the suffixed input.
     */
    public StepResult execute(StepContext ctx) {
      String input = (String) JSON.deserialize(ctx.inputJson, String.class);
      return StepResult.complete(null, input + '_P1Done');
    }
  }

  /**
   * @description Parallel branch step that echoes its input with a _P2Done suffix.
   */
  public class ParallelStep2 implements WorkflowStep {
    /**
     * @description Completes with the branch input suffixed by _P2Done.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult carrying the suffixed input.
     */
    public StepResult execute(StepContext ctx) {
      String input = (String) JSON.deserialize(ctx.inputJson, String.class);
      return StepResult.complete(null, input + '_P2Done');
    }
  }

  /**
   * @description Compensatable step that completes normally but whose compensation
   * optionally retries, used to test compensation retry/failure paths via the
   * compensationShouldFail flag.
   */
  public class CompensatableFailingStep implements CompensatableStep {
    /**
     * @description Completes the forward action successfully.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    /**
     * @description Retries compensation under a bounded policy when
     * compensationShouldFail is set; otherwise completes compensation.
     * @param ctx The durable per-step execution context.
     * @return A retry result while forced to fail, otherwise a completed result.
     */
    public StepResult compensate(StepContext ctx) {
      if (WorkflowEngineMocksATest.compensationShouldFail) {
        RetryPolicy policy = new RetryPolicy();
        policy.maximumAttempts = 2;
        policy.initialIntervalSeconds = 1;
        policy.backoffCoefficient = 2.0;
        return StepResult.retry(policy);
      }
      return StepResult.complete(null, 'CompensatedFailing');
    }
  }

  /**
   * @description HttpCalloutMock returning a 204 No Content response, used for
   * compensation callouts that expect an empty success.
   */
  public class CompOkMock implements HttpCalloutMock {
    /**
     * @description Answers any request with a 204 empty-body response.
     * @param req The outbound HTTP request being mocked.
     * @return A canned 204 No Content response.
     */
    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(204);
      res.setBody('');
      return res;
    }
  }

  /**
   * @description Step that suspends until a 'Go' signal is present, then completes,
   * used to test signal-gated compensation staging.
   */
  public class Stage_Compensate implements WorkflowStep {
    /**
     * @description Suspends until the 'Go' signal arrives, then completes.
     * @param ctx The durable per-step execution context.
     * @return A suspend result while waiting, otherwise a completed result.
     */
    public StepResult execute(StepContext ctx) {
      if (!ctx.hasSignal('Go')) {
        return StepResult.suspend();
      }
      return StepResult.complete(null, 'done');
    }
  }

  /**
   * @description Terminal single-step definition wrapping Stage_Compensate.
   */
  public class SuffixForwardWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single staging step.
     * @return The list containing the sole step name.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.Stage_Compensate' };
    }
    /**
     * @description Names the staging step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.Stage_Compensate';
    }
    /**
     * @description Terminal single-step workflow with no successor.
     * @param currentStepName The step that just completed.
     * @param result The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null; // terminal
    }
  }

  /**
   * @description Queueable that attaches a workflow finalizer, used to test
   * finalizer-based crash recovery from an enqueued job.
   */
  public class MockQueueable implements Queueable {
    /**
     * @description Attaches a mock queueable finalizer and returns.
     * @param ctx The queueable execution context.
     */
    public void execute(QueueableContext ctx) {
      System.attachFinalizer(
        new WorkflowEngineMocksBTest.MockQueueableFinalizer()
      );
      return;
    }
  }

  /**
   * @description Single-step definition used to verify a step observes the
   * previous run-at timestamp on resume.
   */
  public class PreviousRunAtWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single previous-run-at capture step.
     * @return The list containing the sole step name.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.PreviousRunAtCaptureStep'
      };
    }
    /**
     * @description Names the capture step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.PreviousRunAtCaptureStep';
    }
    /**
     * @description Terminal single-step workflow with no successor.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Step that increments a counter and continues-as-new until the
   * counter reaches 2, used to test the continue-as-new loop mechanism.
   */
  public class IncrementCounterStep implements WorkflowStep {
    /**
     * @description Reads the counter from the workflow input, continuing as new
     * while below 2 and completing once the limit is reached.
     * @param ctx The durable per-step execution context.
     * @return A continue-as-new result while looping, otherwise a completed result.
     */
    public StepResult execute(StepContext ctx) {
      Integer counter = 0;
      if (String.isNotBlank(ctx.workflowInputJson)) {
        counter = Integer.valueOf(ctx.workflowInputJson);
      }
      if (counter < 2) {
        return StepResult.continueAsNew(counter + 1);
      }
      return StepResult.complete(null, counter + 1);
    }
  }

  /**
   * @description Single-step definition used to test timeout-driven
   * continuation.
   */
  public class TimeoutContinueWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single timeout-continue step.
     * @return The list containing the sole step name.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.TimeoutContinueStep' };
    }
    /**
     * @description Names the timeout-continue step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.TimeoutContinueStep';
    }
    /**
     * @description Terminal single-step workflow with no successor.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description A class that deliberately does NOT implement WorkflowStep, used
   * to test the validator's rejection of a declared step lacking the step
   * contract.
   */
  public class NotARealStep {
    /**
     * @description Returns a marker label identifying this as a non-step class.
     * @return The literal string 'not a step'.
     */
    public String label() {
      return 'not a step';
    }
  }

  /**
   * @description Intentionally malformed definition whose initial step is not in
   * getSteps() and whose successor is undeclared, used to exercise validator
   * error reporting.
   */
  public class MalformedValidatorWorkflow implements WorkflowDefinition {
    /**
     * @description Declares a single step that is not a valid WorkflowStep.
     * @return The list containing the non-step class name.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.NotARealStep' };
    }
    /**
     * @description Returns an initial step deliberately absent from getSteps().
     * @return A step name not contained in getSteps().
     */
    public String getInitialStep() {
      return 'WorkflowEngineTest.HappyStep1'; // not contained in getSteps()
    }
    /**
     * @description Returns a dangling, undeclared successor to trip the validator.
     * @param currentStepName The step that just completed.
     * @param result The result of the completed step.
     * @return An undeclared successor step name.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return 'WorkflowEngineTest.NoSuchStep'; // dangling, undeclared successor
    }
  }

  /**
   * @description Approval step configured with a timeout fallback, used to test
   * that an unmet approval routes to the fallback step after the timeout.
   */
  public class TimedApprovalStep implements WorkflowStep {
    /**
     * @description Consumes a received approval signal and completes; otherwise
     * waits for approval with a 60-second timeout to a fallback step.
     * @param ctx The durable per-step execution context.
     * @return A completed result once approved, else a timed wait-for-approval
     * result.
     */
    public StepResult execute(StepContext ctx) {
      List<Workflow_Signal__c> signals = [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :ctx.workflowInstanceId
          AND Signal_Name__c = 'Approve:TimedApproval'
          AND Status__c = 'Received'
        LIMIT 1
      ];
      if (!signals.isEmpty()) {
        signals[0].Status__c = 'Consumed';
        update signals[0];
        return StepResult.complete(null, 'approved');
      }
      return StepResult.waitForApproval('TimedApproval', 'Manager')
        .withApprovalTimeout(
          60,
          'WorkflowEngineMocksBTest.ApprovalTimeoutFallbackStep'
        );
    }
  }

  /**
   * @description Step that records the observed attempt/max/final-attempt state
   * and supplies its own RetryPolicy, used to verify retry metadata exposure and
   * final-attempt fallback.
   */
  public class RetryExposeStep implements WorkflowStep, RetryConfigurable {
    /**
     * @description Captures the current attempt state, then completes on the final
     * attempt or requests a retry under the step's policy.
     * @param ctx The durable per-step execution context.
     * @return A completed result on the final attempt, otherwise a retry result.
     */
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksATest.observedAttemptStates.add(
        new Map<String, Object>{
          'attempt' => ctx.attempt,
          'maxAttempts' => ctx.maxAttempts,
          'isFinalAttempt' => ctx.isFinalAttempt()
        }
      );
      RetryPolicy policy = getRetryPolicy();
      if (ctx.isFinalAttempt()) {
        return StepResult.complete(null, 'FallbackComplete');
      }
      return StepResult.retry(policy);
    }

    /**
     * @description Supplies the retry policy (1s initial interval, 1.0 backoff, 3
     * attempts) governing this step's retries.
     * @return The RetryPolicy applied to this step.
     */
    public RetryPolicy getRetryPolicy() {
      return new RetryPolicy(1, (Double) 1.0, 3);
    }
  }

  /**
   * @description Two-step definition where the second step always fails, used to
   * test compensation of an earlier compensatable step after a downstream
   * failure.
   */
  public class CompensatableRetryWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the compensatable retry step and the downstream
     * always-fail step.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.CompensatableRetryStep',
        'WorkflowEngineMocksATest.AlwaysFailStep'
      };
    }
    /**
     * @description Names the compensatable retry step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.CompensatableRetryStep';
    }
    /**
     * @description Routes the compensatable step to the always-fail step; other
     * completions terminate.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return The always-fail step name, or null when complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (
        currentStepName == 'WorkflowEngineMocksBTest.CompensatableRetryStep'
      ) {
        return 'WorkflowEngineMocksATest.AlwaysFailStep';
      }
      return null;
    }
  }

  /**
   * @description Step that always fails, used to force compensation of prior
   * steps in a saga.
   */
  public class AlwaysFailStep implements WorkflowStep {
    /**
     * @description Fails unconditionally to trigger compensation.
     * @param ctx The durable per-step execution context.
     * @return A failed StepResult.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('Forced fail to trigger compensation');
    }
  }

  /**
   * @description Definition whose router follows the successor named in the step
   * result, used to test result-driven looping.
   */
  public class LoopExposeWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single loop-expose step.
     * @return The list containing the sole step name.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.LoopExposeStep' };
    }
    /**
     * @description Names the loop-expose step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.LoopExposeStep';
    }
    /**
     * @description Routes to whatever successor the step result specifies.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return The next step name carried by the result.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return stepResult.nextStepName;
    }
  }

  /**
   * @description Two-step definition whose router re-runs the first step on YIELD,
   * used to test yield-based progress looping.
   */
  public class ProgressWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the two progress steps.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.ProgressStep1',
        'WorkflowEngineMocksATest.ProgressStep2'
      };
    }
    /**
     * @description Names the first progress step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.ProgressStep1';
    }
    /**
     * @description Re-runs the first step while it yields, otherwise advances to
     * the second step and then terminates.
     * @param currentStepName The step that just completed.
     * @param sr The result of the completed step.
     * @return The next step name based on the yield action, or null when complete.
     */
    public String getNextStep(String currentStepName, StepResult sr) {
      if (currentStepName == 'WorkflowEngineMocksBTest.ProgressStep1') {
        if (sr.action == StepResult.ActionType.YIELD) {
          return 'WorkflowEngineMocksBTest.ProgressStep1';
        }
        return 'WorkflowEngineMocksATest.ProgressStep2';
      }
      return null;
    }
  }

  /**
   * @description Second progress step that reports progress and continues-as-new
   * with a successor input, used to test progress reporting across continuation.
   */
  public class ProgressStep2 implements WorkflowStep {
    /**
     * @description Reports interim progress, continues as new until the successor
     * input is present, then reports completion and completes.
     * @param ctx The durable per-step execution context.
     * @return A continue-as-new result on the first pass, otherwise a completed
     * result.
     */
    public StepResult execute(StepContext ctx) {
      ctx.reportProgress(
        new Map<String, Object>{ 'stage' => 'Step 2 final', 'percent' => 90.0 }
      );
      String inputStr = ctx.workflowInputJson;
      if (String.isBlank(inputStr) || !inputStr.contains('isSuccessor')) {
        return StepResult.continueAsNew(
          '{"isSuccessor": true}',
          'key_successor'
        );
      }
      ctx.reportProgress(100.0, 'Workflow Complete');
      return StepResult.complete(null, 'Done');
    }
  }

  /**
   * @description First step of a skip/compensation scenario that completes with a
   * fixed output feeding the poison second step.
   */
  public class SkipTestStep1 implements WorkflowStep {
    /**
     * @description Completes with a fixed output for the downstream step.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult carrying 'InputToTwo'.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'InputToTwo');
    }
  }

  /**
   * @description Compensatable poison step that always fails permanently, whose
   * compensation completes, used to test saga rollback.
   */
  public class SkipTestStep2 implements CompensatableStep {
    /**
     * @description Fails permanently to act as a poison step.
     * @param ctx The durable per-step execution context.
     * @return A failed StepResult.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('Poison step: failed permanently');
    }
    /**
     * @description Completes the compensation for this step.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult marking compensation done.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, 'CompensatedTwo');
    }
  }

  /**
   * @description Parallel definition with a poison branch, used to test skipping
   * and joining after a failed parallel branch.
   */
  public class SkipParallelWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the split, two branch steps, and join step.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.SkipParallelSplitStep',
        'WorkflowEngineMocksBTest.SkipParallelA',
        'WorkflowEngineMocksATest.SkipParallelB',
        'WorkflowEngineMocksATest.SkipParallelJoinStep'
      };
    }
    /**
     * @description Names the split step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.SkipParallelSplitStep';
    }
    /**
     * @description Routes the split step to the join step; other completions
     * terminate.
     * @param currentStepName The step that just completed.
     * @param result The result of the completed step.
     * @return The join step name after the split, otherwise null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'WorkflowEngineMocksBTest.SkipParallelSplitStep') {
        return 'WorkflowEngineMocksATest.SkipParallelJoinStep';
      }
      return null;
    }
  }

  /**
   * @description Parallel branch step that fails, acting as the poison branch in
   * a skip-parallel scenario.
   */
  public class SkipParallelB implements WorkflowStep {
    /**
     * @description Fails to poison its parallel branch.
     * @param ctx The durable per-step execution context.
     * @return A failed StepResult.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('Parallel Poison Step');
    }
  }

  /**
   * @description Join step that combines the outputs of the parallel branches
   * into a single result.
   */
  public class SkipParallelJoinStep implements WorkflowStep {
    /**
     * @description Reads the branch outputs from the join input and completes with
     * a combined value.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult carrying the joined branch outputs.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> outputs = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.inputJson
      );
      String outA = (String) outputs.get(
        'WorkflowEngineMocksBTest.SkipParallelA'
      );
      Map<String, Object> outBMap = (Map<String, Object>) outputs.get(
        'WorkflowEngineMocksATest.SkipParallelB'
      );
      String valB = (String) outBMap.get('val');
      return StepResult.complete(null, 'Join_' + outA + '_' + valB);
    }
  }

  /**
   * @description Split step that fans out into three parallel branches, used to
   * test three-way parallel skip/join behaviour.
   */
  public class SkipThreeParallelSplitStep implements WorkflowStep {
    /**
     * @description Splits into the A, B, and C parallel branch steps.
     * @param ctx The durable per-step execution context.
     * @return A split StepResult naming the three parallel branch steps.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowEngineMocksBTest.SkipParallelA',
          'WorkflowEngineMocksATest.SkipParallelB',
          'WorkflowEngineMocksATest.SkipParallelC'
        },
        null
      );
    }
  }

  /**
   * @description Parallel branch step that fails or completes depending on the
   * failParallelC flag, used to toggle a poison branch on and off.
   */
  public class SkipParallelC implements WorkflowStep {
    /**
     * @description Fails when failParallelC is set; otherwise completes with a
     * fixed output.
     * @param ctx The durable per-step execution context.
     * @return A failed result while poisoned, otherwise a completed result.
     */
    public StepResult execute(StepContext ctx) {
      if (WorkflowEngineMocksATest.failParallelC) {
        return StepResult.fail('Parallel Poison Step C');
      }
      return StepResult.complete(null, 'OutputC');
    }
  }

  /**
   * @description Join step for the three-way parallel scenario that completes
   * with a fixed marker.
   */
  public class SkipParallelJoinStep3 implements WorkflowStep {
    /**
     * @description Completes with a fixed Join3 marker.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult carrying 'Join3'.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Join3');
    }
  }

  /**
   * @description Split step that fans into two compensatable branches, used to
   * test compensation of parallel branches.
   */
  public class CompensatableParallelSplitStep implements WorkflowStep {
    /**
     * @description Splits into the compensatable parallel A and B branch steps.
     * @param ctx The durable per-step execution context.
     * @return A split StepResult naming the two parallel branch steps.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowEngineMocksATest.CompensatableParallelA',
          'WorkflowEngineMocksATest.CompensatableParallelB'
        },
        null
      );
    }
  }

  /**
   * @description Parallel branch step that completes with output A.
   */
  public class CompensatableParallelA implements WorkflowStep {
    /**
     * @description Completes with a fixed OutputA value.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult carrying 'OutputA'.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'OutputA');
    }
  }

  /**
   * @description Compensatable parallel branch step that completes with output B
   * and defines its compensation.
   */
  public class CompensatableParallelB implements WorkflowStep, CompensatableStep {
    /**
     * @description Completes with a fixed OutputB value.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult carrying 'OutputB'.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'OutputB');
    }
    /**
     * @description Completes the compensation for branch B.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult carrying 'CompensatedB'.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, 'CompensatedB');
    }
  }

  /**
   * @description Single-step definition used to test breadcrumb/log capture during
   * step execution.
   */
  public class BreadcrumbWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single breadcrumb step.
     * @return The list containing the sole step name.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.BreadcrumbStep' };
    }
    /**
     * @description Names the breadcrumb step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.BreadcrumbStep';
    }
    /**
     * @description Terminal single-step workflow with no successor.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Single-step definition used to test rollback behaviour.
   */
  public class RollbackWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single rollback step.
     * @return The list containing the sole step name.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.RollbackStep' };
    }
    /**
     * @description Names the rollback step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.RollbackStep';
    }
    /**
     * @description Terminal single-step workflow with no successor.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Step that logs each attempt and retries until the third attempt,
   * used to verify retry breadcrumbs are preserved across attempts.
   */
  public class RetryBreadcrumbStep implements WorkflowStep {
    /**
     * @description Logs the current attempt and retries under a bounded policy
     * until the third attempt, then completes.
     * @param ctx The durable per-step execution context.
     * @return A retry result before the third attempt, otherwise a completed
     * result.
     */
    public StepResult execute(StepContext ctx) {
      ctx.log(
        StepContext.Level.INFO,
        'Attempt ' + WorkflowEngineMocksBTest.retryBreadcrumbAttempt
      );
      if (WorkflowEngineMocksBTest.retryBreadcrumbAttempt < 3) {
        WorkflowEngineMocksBTest.retryBreadcrumbAttempt++;
        RetryPolicy policy = new RetryPolicy(1, (Double) 1.0, 5);
        return StepResult.retry(policy);
      }
      return StepResult.complete(null, 'Success');
    }
  }

  /**
   * @description Error-routing handler step that records the failed step name,
   * error message, and attempt count exposed on the context, used to assert error
   * metadata reaches the handler.
   */
  public class NormalHandlerStep implements WorkflowStep {
    /**
     * @description Records the routed error context (failed step, error message,
     * attempt count) and completes.
     * @param ctx The durable per-step execution context carrying error metadata.
     * @return A completed StepResult marking the handler done.
     */
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksBTest.routedStepsRun.add('NormalHandlerStep');
      WorkflowEngineMocksBTest.routedStepContextData.put(
        'failedStepName',
        ctx.failedStepName
      );
      WorkflowEngineMocksBTest.routedStepContextData.put(
        'errorMessage',
        ctx.errorMessage
      );
      WorkflowEngineMocksBTest.routedStepContextData.put(
        'attemptCount',
        ctx.attemptCount
      );
      return StepResult.complete(null, 'HandlerComplete');
    }
  }

  /**
   * @description Compensatable forward step that records both its forward run and
   * its compensation, used to verify forward-then-compensate ordering.
   */
  public class CompensatableForwardStep2 implements CompensatableStep {
    /**
     * @description Records the forward run and completes.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult carrying the step-2 output.
     */
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksBTest.routedStepsRun.add('CompensatableForwardStep2');
      return StepResult.complete(null, 'Step2Output');
    }
    /**
     * @description Records the compensation run and completes.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult marking compensation done.
     */
    public StepResult compensate(StepContext ctx) {
      WorkflowEngineMocksBTest.compensationsRun.add(
        'CompensatableForwardStep2_Compensate'
      );
      return StepResult.complete(null, 'Compensate2Complete');
    }
  }

  /**
   * @description Error-routing workflow that routes a failed explicit-fail step to
   * a handler step, used to test forward error routing.
   */
  public class FailingHandlerWorkflow implements ErrorRoutingWorkflow {
    /**
     * @description Declares the explicit-fail step and its handler step.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.ExplicitFailStep',
        'WorkflowEngineMocksBTest.FailingHandlerStep'
      };
    }
    /**
     * @description Names the explicit-fail step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.ExplicitFailStep';
    }
    /**
     * @description Terminal on normal completion; routing occurs only via
     * getErrorStep.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null on normal completion.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    /**
     * @description Routes a failed explicit-fail step to the failing-handler step.
     * @param failedStepName The name of the step that failed.
     * @param error The error describing the failure.
     * @return The handler step name, or null when unhandled.
     */
    public String getErrorStep(String failedStepName, StepError error) {
      if (failedStepName == 'WorkflowEngineMocksBTest.ExplicitFailStep') {
        return 'WorkflowEngineMocksBTest.FailingHandlerStep';
      }
      return null;
    }
  }

  /**
   * @description Split step that fans into a failing step and a sibling step, used
   * to test error routing from within a parallel branch.
   */
  public class ParallelSpawnStep implements WorkflowStep {
    /**
     * @description Splits into an explicit-fail step and a sibling step.
     * @param ctx The durable per-step execution context.
     * @return A split StepResult naming the failing and sibling branch steps.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowEngineMocksBTest.ExplicitFailStep',
          'WorkflowEngineMocksATest.SiblingStep'
        },
        null
      );
    }
  }

  /**
   * @description Sibling parallel branch step that completes successfully
   * alongside a failing branch.
   */
  public class SiblingStep implements WorkflowStep {
    /**
     * @description Completes with a fixed sibling marker.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult carrying 'SiblingComplete'.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'SiblingComplete');
    }
  }

  /**
   * @description Error-routing workflow with a parallel spawn whose failing branch
   * routes to a handler, used to test error routing across parallel branches.
   */
  public class ParallelErrorRoutedWorkflow implements ErrorRoutingWorkflow {
    /**
     * @description Declares the spawn, failing, sibling, and handler steps.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.ParallelSpawnStep',
        'WorkflowEngineMocksBTest.ExplicitFailStep',
        'WorkflowEngineMocksATest.SiblingStep',
        'WorkflowEngineMocksATest.NormalHandlerStep'
      };
    }
    /**
     * @description Names the parallel spawn step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.ParallelSpawnStep';
    }
    /**
     * @description Terminal on normal completion; routing occurs only via
     * getErrorStep.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null on normal completion.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    /**
     * @description Routes the failed explicit-fail branch to the normal handler
     * step.
     * @param failedStepName The name of the step that failed.
     * @param error The error describing the failure.
     * @return The handler step name, or null when unhandled.
     */
    public String getErrorStep(String failedStepName, StepError error) {
      if (failedStepName == 'WorkflowEngineMocksBTest.ExplicitFailStep') {
        return 'WorkflowEngineMocksATest.NormalHandlerStep';
      }
      return null;
    }
  }

  /**
   * @description Error-routing workflow that routes a retry-exhausted failure to a
   * handler, used to test error routing after retries are exhausted.
   */
  public class RetryExhaustedErrorRoutedWorkflow implements ErrorRoutingWorkflow {
    /**
     * @description Declares the retry-exhausted failure step and its handler step.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.RetryExhaustedFailureStep',
        'WorkflowEngineMocksATest.NormalHandlerStep'
      };
    }
    /**
     * @description Names the retry-exhausted failure step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.RetryExhaustedFailureStep';
    }
    /**
     * @description Terminal on normal completion; routing occurs only via
     * getErrorStep.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null on normal completion.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    /**
     * @description Routes the retry-exhausted failure step to the normal handler
     * step.
     * @param failedStepName The name of the step that failed.
     * @param error The error describing the failure.
     * @return The handler step name, or null when unhandled.
     */
    public String getErrorStep(String failedStepName, StepError error) {
      if (
        failedStepName == 'WorkflowEngineMocksBTest.RetryExhaustedFailureStep'
      ) {
        return 'WorkflowEngineMocksATest.NormalHandlerStep';
      }
      return null;
    }
  }

  /**
   * @description Error-routing workflow used to test rollback of stale parallel
   * signals when a branch fails and routes to a handler.
   */
  public class StaleSignalRollbackWorkflow implements ErrorRoutingWorkflow {
    /**
     * @description Declares the stale spawn, failing, stale-sibling, and handler
     * steps.
     * @return The ordered list of fully-qualified step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.StaleSpawnStep',
        'WorkflowEngineMocksBTest.ExplicitFailStep',
        'WorkflowEngineMocksBTest.StaleSignalSiblingStep',
        'WorkflowEngineMocksATest.NormalHandlerStep'
      };
    }
    /**
     * @description Names the stale spawn step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.StaleSpawnStep';
    }
    /**
     * @description Terminal on normal completion; routing occurs only via
     * getErrorStep.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null on normal completion.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    /**
     * @description Routes the failed explicit-fail branch to the normal handler
     * step.
     * @param failedStepName The name of the step that failed.
     * @param error The error describing the failure.
     * @return The handler step name, or null when unhandled.
     */
    public String getErrorStep(String failedStepName, StepError error) {
      if (failedStepName == 'WorkflowEngineMocksBTest.ExplicitFailStep') {
        return 'WorkflowEngineMocksATest.NormalHandlerStep';
      }
      return null;
    }
  }

  /**
   * @description Step that completes normally but declares a step timeout, used to
   * test timeout configuration and enforcement.
   */
  public class TimeoutFailureStep implements WorkflowStep, TimeoutConfigurable {
    /**
     * @description Completes with a fixed marker.
     * @param ctx The durable per-step execution context.
     * @return A completed StepResult carrying 'TimeoutDone'.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'TimeoutDone');
    }
    /**
     * @description Declares this step's timeout budget in seconds.
     * @return The step timeout of 10 seconds.
     */
    public Integer getTimeoutSeconds() {
      return 10;
    }
  }

  /**
   * @description Error-routing workflow with a single step and no error routing,
   * used as a baseline routing definition.
   */
  public class PureRoutingWorkflow implements ErrorRoutingWorkflow {
    /**
     * @description Declares the single handler step.
     * @return The list containing the sole step name.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.NormalHandlerStep' };
    }
    /**
     * @description Names the handler step as the entry point.
     * @return The fully-qualified initial step name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.NormalHandlerStep';
    }
    /**
     * @description Terminal single-step workflow with no successor.
     * @param currentStepName The step that just completed.
     * @param stepResult The result of the completed step.
     * @return Always null, ending the workflow.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    /**
     * @description Declares no error routing for this workflow.
     * @param failedStepName The name of the step that failed.
     * @param error The error describing the failure.
     * @return Always null, indicating no error handler.
     */
    public String getErrorStep(String failedStepName, StepError error) {
      return null;
    }
  }

  /**
   * @description CaptureProducer that produces a constant true value, used with
   * ctx.once to test effectively-once capture of a computed value.
   */
  public class YieldedProducer implements CaptureProducer {
    /**
     * @description Produces the value captured once by ctx.once.
     * @return The constant Boolean true.
     */
    public Object produce() {
      return true;
    }
  }

  /**
   * @description Error-routing handler step that sleeps on its first run and, on
   * resume, records the routed error context, used to test yielding within an
   * error handler with once-only capture.
   */
  public class YieldingHandlerStep implements WorkflowStep {
    /**
     * @description On the first run captures a value once and sleeps; on resume
     * records the routed error context and completes.
     * @param ctx The durable per-step execution context carrying error metadata.
     * @return A sleep result on the first run, otherwise a completed result.
     */
    public StepResult execute(StepContext ctx) {
      if (!WorkflowEngineMocksBTest.yieldingHandlerFirstRunDone) {
        WorkflowEngineMocksBTest.yieldingHandlerFirstRunDone = true;
        ctx.once('hasYielded', new WorkflowEngineMocksATest.YieldedProducer());
        return StepResult.sleep(10, 'YieldingHandlerStep');
      }
      WorkflowEngineMocksBTest.routedStepsRun.add('YieldingHandlerStep');
      WorkflowEngineMocksBTest.routedStepContextData.put(
        'failedStepName',
        ctx.failedStepName
      );
      WorkflowEngineMocksBTest.routedStepContextData.put(
        'errorMessage',
        ctx.errorMessage
      );
      WorkflowEngineMocksBTest.routedStepContextData.put(
        'attemptCount',
        ctx.attemptCount
      );
      return StepResult.complete(null, 'HandlerDone');
    }
  }
}
