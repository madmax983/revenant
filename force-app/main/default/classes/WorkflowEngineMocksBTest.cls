@IsTest
public class WorkflowEngineMocksBTest {
  public static List<Map<String, Object>> compensationObservedStates = new List<Map<String, Object>>();
  public static List<Map<String, Object>> loopObservedStates = new List<Map<String, Object>>();
  public static Integer loopCounter = 0;
  public static Integer retryBreadcrumbAttempt = 1;
  public static List<String> routedStepsRun = new List<String>();
  public static Map<String, Object> routedStepContextData = new Map<String, Object>();
  public static List<String> compensationsRun = new List<String>();
  public static Boolean yieldingHandlerFirstRunDone = false;

  /**
   * @description Single-step mock workflow whose only step performs a direct HTTP callout; used to exercise callout handling.
   */
  public class CalloutWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.DirectCalloutStep' };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.DirectCalloutStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param result The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  /**
   * @description Mock step that performs a direct outbound HTTP GET callout and completes with the response body.
   */
  public class DirectCalloutStep implements WorkflowStep {
    /**
     * @description Performs a direct outbound HTTP GET callout and completes the step with the response body.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      HttpRequest req = new HttpRequest();
      req.setEndpoint('https://api.example.com/test');
      req.setMethod('GET');
      Http h = new Http();
      HttpResponse res = h.send(req);
      return StepResult.complete(null, res.getBody());
    }
  }

  /**
   * @description Mock step that fans out into two parallel branches, including a large-output step, to test parallel splits with large payloads.
   */
  public class LargeParallelSplitStep implements WorkflowStep {
    /**
     * @description Splits execution into two parallel branches, including a large-output step, sharing a branch input.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowEngineMocksATest.LargeOutputStep',
          'WorkflowEngineMocksATest.ParallelStep2'
        },
        'BranchInput'
      );
    }
  }

  /**
   * @description Mock join step that aggregates parallel branches and asserts the large (~110k char) branch output survived aggregation.
   */
  public class LargeParallelJoinStep implements WorkflowStep {
    /**
     * @description Aggregates the parallel branches and asserts the large (~110k char) branch output survived aggregation before completing.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.inputJson
      );
      String val1 = (String) input.get(
        'WorkflowEngineMocksATest.LargeOutputStep'
      );
      System.assertNotEquals(null, val1);
      System.assertEquals(110000, val1.length());
      return StepResult.complete(null, 'OK');
    }
  }

  /**
   * @description Single-step mock workflow driving a cooperatively yielding step.
   */
  public class YieldingWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.YieldingStep' };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.YieldingStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param stepResult The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Mock step that processes work in chunks across durable yields, persisting progress in step state until all items are handled.
   */
  public class YieldingStep implements WorkflowStep {
    /**
     * @description Processes work in chunks across durable yields, persisting progress in step state until all items are handled, then completes.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksATest.YieldingChunkState state;
      if (ctx.stepStateJson != null) {
        state = (WorkflowEngineMocksATest.YieldingChunkState) JSON.deserialize(
          ctx.stepStateJson,
          WorkflowEngineMocksATest.YieldingChunkState.class
        );
      } else {
        state = new WorkflowEngineMocksATest.YieldingChunkState();
        state.processed = 0;
        state.total = 3;
      }

      if (state.processed < state.total) {
        state.processed += 1;
        return StepResult.yield(JSON.serialize(state));
      }
      return StepResult.complete(null, 'Done_' + state.processed);
    }
  }

  /**
   * @description Mock step that requests retries until a test flag flips it to succeed; exercises retry-then-succeed.
   */
  public class FailingStep implements WorkflowStep {
    /**
     * @description Requests a retry until a test flag flips the step to succeed, exercising retry-then-succeed behavior.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      if (WorkflowEngineMocksATest.shouldSucceedOnFailingStep) {
        return StepResult.complete(null, 'SuccessAfterRetry');
      }
      RetryPolicy policy = new RetryPolicy();
      policy.maximumAttempts = 1;
      return StepResult.retry(policy);
    }
  }

  /**
   * @description Single-step mock workflow used to exercise step timeout handling.
   */
  public class TimeoutWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.TimeoutStep' };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineTest.TimeoutStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param stepResult The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Single-step mock workflow driving a retrying step.
   */
  public class RetryingWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.RetryingStep' };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.RetryingStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param stepResult The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Single-step mock workflow used to test signal delivery to a waiting step.
   */
  public class SignaledWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.SignaledStep' };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.SignaledStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param stepResult The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Single-step mock workflow driving a step configured with a custom retry policy.
   */
  public class CustomRetryWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.CustomRetryStep' };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.CustomRetryStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param stepResult The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Mock step that always requests a retry using an explicit backoff policy to verify custom retry scheduling.
   */
  public class CustomRetryStep implements WorkflowStep {
    /**
     * @description Always requests a retry using an explicit backoff policy (2s initial, 3.0 coefficient, 3 attempts) to verify custom retry scheduling.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      // Initial = 2s, backoff coefficient = 3.0, max attempts = 3
      RetryPolicy policy = new RetryPolicy(2, (Double) 3.0, 3);
      return StepResult.retry(policy);
    }
  }

  /**
   * @description Mock step that durably sleeps on first run and, once resumed, transitions to the after-sleep step.
   */
  public class SleepingStep implements WorkflowStep {
    /**
     * @description Sleeps on first execution and, once resumed, completes and transitions to the after-sleep step.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      if (ctx.stepStateJson != null) {
        return StepResult.complete(
          'WorkflowEngineMocksBTest.AfterSleepStep',
          ctx.stepStateJson
        );
      }
      return StepResult.sleep(10).withStepState('resumed_state');
    }
  }

  /**
   * @description Mock step that consumes the payload carried through the preceding durable sleep and completes.
   */
  public class AfterSleepStep implements WorkflowStep {
    /**
     * @description Consumes the payload carried through the preceding durable sleep and completes.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      String payload = (String) JSON.deserialize(
        ctx.previousStepOutput,
        String.class
      );
      return StepResult.complete(null, 'Done_' + payload);
    }
  }

  /**
   * @description Mock step that starts a child workflow and completes with the child's result once the child-completed signal is received; exercises parent/child orchestration.
   */
  public class ParentStep implements WorkflowStep {
    /**
     * @description Starts a child workflow and, once the child-completed signal is received, consumes it and completes with the child's result.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      List<Workflow_Signal__c> signals = [
        SELECT Payload__c
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :ctx.workflowInstanceId
          AND Signal_Name__c = 'ChildCompleted:SubKey'
          AND Status__c = 'Received'
        LIMIT 1
      ];
      if (!signals.isEmpty()) {
        signals[0].Status__c = 'Consumed';
        update signals[0];
        String childResult = (String) JSON.deserialize(
          signals[0].Payload__c,
          String.class
        );
        return StepResult.complete(null, 'ParentResult_' + childResult);
      }
      return StepResult.startChild(
        'WorkflowEngineMocksATest.ChildWorkflow',
        'SubKey',
        'ChildInput'
      );
    }
  }

  /**
   * @description Fan-out/fan-in mock workflow that splits into parallel branches and then joins them.
   */
  public class ParallelWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.SplitStep',
        'WorkflowEngineMocksATest.ParallelStep1',
        'WorkflowEngineMocksATest.ParallelStep2',
        'WorkflowEngineMocksBTest.JoinStep'
      };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.SplitStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param stepResult The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineMocksATest.SplitStep') {
        return 'WorkflowEngineMocksBTest.JoinStep';
      }
      return null;
    }
  }

  /**
   * @description Mock join step that aggregates the two parallel branch outputs into a single combined result.
   */
  public class JoinStep implements WorkflowStep {
    /**
     * @description Aggregates the two parallel branch outputs into a single combined result.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> inputMap = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.inputJson
      );
      String out1 = (String) inputMap.get(
        'WorkflowEngineMocksATest.ParallelStep1'
      );
      String out2 = (String) inputMap.get(
        'WorkflowEngineMocksATest.ParallelStep2'
      );
      return StepResult.complete(null, out1 + '+' + out2);
    }
  }

  /**
   * @description Compensatable mock step used to verify that previousRunAt is exposed to compensation during rollback.
   */
  public class PreviousRunAtCompensatableStep implements CompensatableStep {
    /**
     * @description Completes successfully so its compensation can later capture previousRunAt.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    /**
     * @description Captures ctx.previousRunAt during rollback to verify it is exposed to compensation, then completes.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of compensation.
     */
    public StepResult compensate(StepContext ctx) {
      WorkflowEngineMocksATest.capturedCompensatePreviousRunAt = ctx.previousRunAt;
      WorkflowEngineMocksATest.compensatePreviousRunAtCaptured = true;
      return StepResult.complete(null, 'Compensated');
    }
  }

  /**
   * @description Compensatable mock step whose compensation issues a rollback HTTP callout under a timeout budget.
   */
  public class CalloutCompensationStep implements CompensatableStep, CalloutStep, TimeoutConfigurable {
    /**
     * @description Returns this step's execution timeout budget in seconds.
     * @return The timeout budget in seconds.
     */
    public Integer getTimeoutSeconds() {
      return 60;
    }
    /**
     * @description Completes successfully so its callout-based compensation can be exercised.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    /**
     * @description Issues a rollback HTTP callout during compensation and completes with its status code.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of compensation.
     */
    public StepResult compensate(StepContext ctx) {
      ctx.signals().getSignal('CompSig');
      HttpRequest req = new HttpRequest();
      req.setEndpoint('https://example.com/rollback');
      req.setMethod('POST');
      HttpResponse res = new Http().send(req);
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'status' => res.getStatusCode() }
      );
    }
  }

  /**
   * @description Compensatable mock step whose compensation suspends until a Rollback signal arrives.
   */
  public class SignalWaitCompensationStep implements CompensatableStep {
    /**
     * @description Completes successfully so its signal-gated compensation can be exercised.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    /**
     * @description Suspends compensation until a Rollback signal arrives, then completes.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of compensation.
     */
    public StepResult compensate(StepContext ctx) {
      if (!ctx.signals().hasSignal('Rollback')) {
        return StepResult.suspend();
      }
      return StepResult.complete(null, 'CompensatedAfterSignal');
    }
  }

  /**
   * @description No-op System.Finalizer test double used where a finalizer instance is required.
   */
  public class MockQueueableFinalizer implements System.Finalizer {
    /**
     * @description No-op finalizer body that satisfies the System.Finalizer interface without performing any post-transaction work.
     * @param fctx The finalizer context supplied by the platform runtime.
     */
    public void execute(System.FinalizerContext fctx) {
      return;
    }
  }

  /**
   * @description Single-step daemon-style mock workflow that increments a counter each run.
   */
  public class DaemonWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.IncrementCounterStep'
      };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.IncrementCounterStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param stepResult The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Mock step that continues as new to obtain a previousRunAt timestamp, verifying it is preserved across continuations.
   */
  public class PreviousRunAtCaptureStep implements WorkflowStep {
    /**
     * @description Continues as new once to obtain a previousRunAt timestamp, then completes returning it, verifying it is preserved across continuations.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      if (ctx.previousRunAt == null) {
        return StepResult.continueAsNew(null);
      }
      return StepResult.complete(null, ctx.previousRunAt.getTime());
    }
  }

  /**
   * @description Mock step that continues as new into a successor instance, exercising continue-as-new under a timeout budget.
   */
  public class TimeoutContinueStep implements WorkflowStep, TimeoutConfigurable {
    /**
     * @description Returns this step's execution timeout budget in seconds.
     * @return The timeout budget in seconds.
     */
    public Integer getTimeoutSeconds() {
      return 60;
    }
    /**
     * @description Continues as new into a successor instance, completing only once the successor input is present.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      if (
        ctx.workflowInputJson != null &&
        ctx.workflowInputJson.contains('successor')
      ) {
        return StepResult.complete(null, 'SuccessorFinished');
      }
      return StepResult.continueAsNew('successor', 'SuccessorKey');
    }
  }

  /**
   * @description Compensatable mock step that throws during compensation to simulate a compensation crash.
   */
  public class CompensatableCrashStep implements CompensatableStep {
    /**
     * @description Completes successfully so its compensation crash can be exercised.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    /**
     * @description Throws during compensation to simulate a compensation crash.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of compensation.
     */
    public StepResult compensate(StepContext ctx) {
      throw new WorkflowEngine.WorkflowException(
        'Compensation crash simulation'
      );
    }
  }

  /**
   * @description Compensatable mock step that reverses or throws a cancel-worded exception during compensation depending on a test flag.
   */
  public class CompensatableCancelWordStep implements CompensatableStep {
    /**
     * @description Completes successfully so its cancel-worded compensation failure can be exercised.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    /**
     * @description Reverses the step, or throws a cancel-worded exception when the test flag is set, to exercise compensation failure matching.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of compensation.
     */
    public StepResult compensate(StepContext ctx) {
      if (WorkflowEngineMocksATest.cancelWordCompensationShouldFail) {
        throw new WorkflowEngine.WorkflowException(
          'OrderCancelledException: the order was Cancelled upstream'
        );
      }
      return StepResult.complete(null, 'Reversed');
    }
  }

  /**
   * @description Mock approval workflow pairing a timed approval step with a timeout fallback step.
   */
  public class TimedApprovalWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.TimedApprovalStep',
        'WorkflowEngineMocksBTest.ApprovalTimeoutFallbackStep'
      };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.TimedApprovalStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param stepResult The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Mock step that completes with an approval-timed-out result; the fallback taken when approval times out.
   */
  public class ApprovalTimeoutFallbackStep implements WorkflowStep {
    /**
     * @description Completes with an approval-timed-out result as the fallback when approval times out.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'approval_timedout');
    }
  }

  /**
   * @description Single-step mock workflow that exposes retry state to its step.
   */
  public class RetryExposeWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.RetryExposeStep' };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.RetryExposeStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param stepResult The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Single-step mock workflow driving a dynamically retrying step.
   */
  public class DynamicRetryWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.DynamicRetryStep' };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.DynamicRetryStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param stepResult The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  /**
   * @description Mock step that records attempt/maxAttempts/isFinalAttempt each run and completes on the third attempt; verifies dynamic retry-state exposure.
   */
  public class DynamicRetryStep implements WorkflowStep {
    /**
     * @description Records attempt, maxAttempts, and isFinalAttempt each run and completes on the third attempt.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksATest.dynamicObservedStates.add(
        new Map<String, Object>{
          'attempt' => ctx.attempt,
          'maxAttempts' => ctx.retry().maxAttempts,
          'isFinalAttempt' => ctx.isFinalAttempt()
        }
      );
      if (ctx.attempt >= 3) {
        return StepResult.complete(null, 'DynamicComplete');
      }
      return StepResult.retry(new RetryPolicy(1, (Double) 1.0, 3));
    }
  }

  /**
   * @description Compensatable mock step that retries its compensation up to policy, recording retry state; exercises compensation retries.
   */
  public class CompensatableRetryStep implements CompensatableStep, RetryConfigurable {
    /**
     * @description Completes successfully so that its compensation retries can later be exercised.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }

    /**
     * @description Records retry state and retries compensation until the final attempt, then completes.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of compensation.
     */
    public StepResult compensate(StepContext ctx) {
      WorkflowEngineMocksBTest.compensationObservedStates.add(
        new Map<String, Object>{
          'attempt' => ctx.attempt,
          'maxAttempts' => ctx.retry().maxAttempts,
          'isFinalAttempt' => ctx.isFinalAttempt()
        }
      );
      if (ctx.isFinalAttempt()) {
        return StepResult.complete(null, 'Compensated');
      }
      return StepResult.retry(getRetryPolicy());
    }

    /**
     * @description Returns the retry policy governing this step's attempts.
     * @return The configured retry policy.
     */
    public RetryPolicy getRetryPolicy() {
      return new RetryPolicy(1, (Double) 1.0, 2);
    }
  }

  /**
   * @description Mock step that drives a self-transition loop by retrying then transitioning to itself, recording attempt state.
   */
  public class LoopExposeStep implements WorkflowStep {
    /**
     * @description Retries then transitions to itself, recording attempt state, to drive a self-transition loop.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksBTest.loopObservedStates.add(
        new Map<String, Object>{
          'attempt' => ctx.attempt,
          'maxAttempts' => ctx.retry().maxAttempts
        }
      );
      WorkflowEngineMocksBTest.loopCounter++;
      if (WorkflowEngineMocksBTest.loopCounter == 1) {
        return StepResult.retry(new RetryPolicy(1, (Double) 1.0, 2));
      } else if (WorkflowEngineMocksBTest.loopCounter == 2) {
        return StepResult.complete(
          'WorkflowEngineMocksBTest.LoopExposeStep',
          'TransitionSelf'
        );
      }
      return StepResult.complete(null, 'LoopFinished');
    }
  }

  /**
   * @description Mock step that reports progress and yields once, then reports completion progress and transitions onward.
   */
  public class ProgressStep1 implements WorkflowStep {
    /**
     * @description Reports progress and yields once, then reports completion progress and transitions to the next progress step.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      if (String.isBlank(ctx.stepStateJson)) {
        ctx.progress().reportProgress(20.0, 'Step 1: Yielding first');
        return StepResult.yield('{"yieldedOnce": true}');
      }
      ctx.progress().reportProgress(50.0, 'Step 1: Done');
      return StepResult.complete(
        'WorkflowEngineMocksATest.ProgressStep2',
        'Output1'
      );
    }
  }

  /**
   * @description Three-step linear mock workflow used to exercise skip semantics.
   */
  public class SkipTestWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.SkipTestStep1',
        'WorkflowEngineMocksATest.SkipTestStep2',
        'WorkflowEngineMocksBTest.SkipTestStep3'
      };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.SkipTestStep1';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param result The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'WorkflowEngineMocksATest.SkipTestStep1') {
        return 'WorkflowEngineMocksATest.SkipTestStep2';
      }
      if (currentStepName == 'WorkflowEngineMocksATest.SkipTestStep2') {
        return 'WorkflowEngineMocksBTest.SkipTestStep3';
      }
      return null;
    }
  }

  /**
   * @description Terminal mock step of the skip test that reads an overridden value from the prior step's output.
   */
  public class SkipTestStep3 implements WorkflowStep {
    /**
     * @description Reads the overridden value from the prior step's output and completes.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> outputMap = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.previousStepOutput
      );
      String val = (String) outputMap.get('overrideVal');
      return StepResult.complete(null, 'StepThreeReceived_' + val);
    }
  }

  /**
   * @description Mock step that splits into two parallel branches to exercise skip semantics within a parallel region.
   */
  public class SkipParallelSplitStep implements WorkflowStep {
    /**
     * @description Splits into two parallel branches to exercise skip semantics within a parallel region.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowEngineMocksBTest.SkipParallelA',
          'WorkflowEngineMocksATest.SkipParallelB'
        },
        null
      );
    }
  }

  /**
   * @description Mock parallel branch step that completes with a fixed output under a timeout budget.
   */
  public class SkipParallelA implements WorkflowStep, TimeoutConfigurable {
    /**
     * @description Completes with a fixed output as one branch of a parallel region.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'OutputA');
    }
    /**
     * @description Returns this step's execution timeout budget in seconds.
     * @return The timeout budget in seconds.
     */
    public Integer getTimeoutSeconds() {
      return 60;
    }
  }

  /**
   * @description Single-step mock workflow whose step is a poison/terminal failure.
   */
  public class TerminalSkipWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.TerminalSkipStep' };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.TerminalSkipStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param result The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  /**
   * @description Mock step that fails hard to simulate a poison terminal step.
   */
  public class TerminalSkipStep implements WorkflowStep {
    /**
     * @description Fails hard to simulate a poison terminal step.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('Poison terminal step');
    }
  }

  /**
   * @description Fan-out mock workflow with three parallel branches and a join, used for skip testing.
   */
  public class SkipThreeParallelWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.SkipThreeParallelSplitStep',
        'WorkflowEngineMocksBTest.SkipParallelA',
        'WorkflowEngineMocksATest.SkipParallelB',
        'WorkflowEngineMocksATest.SkipParallelC',
        'WorkflowEngineMocksATest.SkipParallelJoinStep3'
      };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.SkipThreeParallelSplitStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param result The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (
        currentStepName == 'WorkflowEngineMocksATest.SkipThreeParallelSplitStep'
      ) {
        return 'WorkflowEngineMocksATest.SkipParallelJoinStep3';
      }
      return null;
    }
  }

  /**
   * @description Mock workflow of compensatable parallel branches that split and then join.
   */
  public class CompensatableParallelWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.CompensatableParallelSplitStep',
        'WorkflowEngineMocksATest.CompensatableParallelA',
        'WorkflowEngineMocksATest.CompensatableParallelB',
        'WorkflowEngineMocksBTest.CompensatableParallelJoinStep'
      };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.CompensatableParallelSplitStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param result The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (
        currentStepName ==
        'WorkflowEngineMocksATest.CompensatableParallelSplitStep'
      ) {
        return 'WorkflowEngineMocksBTest.CompensatableParallelJoinStep';
      }
      return null;
    }
  }

  /**
   * @description Mock join step that aggregates the compensatable parallel branches and completes.
   */
  public class CompensatableParallelJoinStep implements WorkflowStep {
    /**
     * @description Joins the compensatable parallel branches and completes.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'JoinDone');
    }
  }

  /**
   * @description Mock step that emits INFO and WARN breadcrumb log entries then completes; exercises durable step logging.
   */
  public class BreadcrumbStep implements WorkflowStep {
    /**
     * @description Emits INFO and WARN breadcrumb log entries then completes.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      ctx.logger()
        .log(
          StepContext.Level.INFO,
          'Step 1 execution started',
          new Map<String, Object>{ 'status' => 'init' }
        );
      ctx.logger().log(StepContext.Level.WARN, 'Step 1 warning encountered');
      return StepResult.complete(null, 'Success');
    }
  }

  /**
   * @description Mock step that logs then throws, verifying breadcrumbs are rolled back with the failed transaction.
   */
  public class RollbackStep implements WorkflowStep {
    /**
     * @description Logs a breadcrumb then throws, verifying breadcrumbs roll back with the failed transaction.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      ctx.logger().log(StepContext.Level.INFO, 'This should not be saved');
      throw new WorkflowEngine.WorkflowException('Simulated Failure');
    }
  }

  /**
   * @description Single-step mock workflow driving the retry-breadcrumb step.
   */
  public class RetryBreadcrumbWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.RetryBreadcrumbStep' };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.RetryBreadcrumbStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param result The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  /**
   * @description Mock step that throws an unhandled exception to simulate a crash during execution.
   */
  public class CrashStep implements WorkflowStep {
    /**
     * @description Throws an unhandled exception to simulate a crash during step execution.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      throw new IllegalArgumentException('Crash in execution');
    }
  }

  /**
   * @description Mock step that returns an explicit business-failure result.
   */
  public class ExplicitFailStep implements WorkflowStep {
    /**
     * @description Returns an explicit business-failure result.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('Explicit business failure');
    }
  }

  /**
   * @description Mock step that retries once and then fails; exercises retry-then-fail routing.
   */
  public class RetryThenFailStep implements WorkflowStep, RetryConfigurable {
    /**
     * @description Retries once and then fails, exercising retry-then-fail routing.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      if (ctx.attempt >= 2) {
        return StepResult.fail('Failed after retry');
      }
      return StepResult.retry(getRetryPolicy());
    }
    /**
     * @description Returns the retry policy governing this step's attempts.
     * @return The configured retry policy.
     */
    public RetryPolicy getRetryPolicy() {
      return new RetryPolicy(1, (Double) 1.0, 2);
    }
  }

  /**
   * @description Mock error-handler step that records it ran and then fails itself.
   */
  public class FailingHandlerStep implements WorkflowStep {
    /**
     * @description Records that it ran and then fails, simulating an error-handler step that itself fails.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksBTest.routedStepsRun.add('FailingHandlerStep');
      return StepResult.fail('Handler itself failed');
    }
  }

  /**
   * @description Compensatable mock step used in error-routing tests that records both its forward run and its rollback.
   */
  public class CompensatableForwardStep1 implements CompensatableStep {
    /**
     * @description Records that it ran and completes forward with its output.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksBTest.routedStepsRun.add('CompensatableForwardStep1');
      return StepResult.complete(null, 'Step1Output');
    }
    /**
     * @description Records its rollback and completes compensation.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of compensation.
     */
    public StepResult compensate(StepContext ctx) {
      WorkflowEngineMocksBTest.compensationsRun.add(
        'CompensatableForwardStep1_Compensate'
      );
      return StepResult.complete(null, 'Compensate1Complete');
    }
  }

  /**
   * @description Error-routing mock workflow whose crashing and failing steps route to a normal handler step.
   */
  public class ErrorRoutedWorkflow implements ErrorRoutingWorkflow {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.CrashStep',
        'WorkflowEngineMocksBTest.ExplicitFailStep',
        'WorkflowEngineMocksBTest.RetryThenFailStep',
        'WorkflowEngineMocksATest.NormalHandlerStep'
      };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.CrashStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param stepResult The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    /**
     * @description Maps a failed step to the error-handling step that should run.
     * @param failedStepName The fully-qualified name of the step that failed.
     * @param error The captured error from the failed step.
     * @return The error-handling step's name, or null to propagate the failure.
     */
    public String getErrorStep(String failedStepName, StepError error) {
      if (
        failedStepName == 'WorkflowEngineMocksBTest.CrashStep' ||
        failedStepName == 'WorkflowEngineMocksBTest.ExplicitFailStep' ||
        failedStepName == 'WorkflowEngineMocksBTest.RetryThenFailStep'
      ) {
        return 'WorkflowEngineMocksATest.NormalHandlerStep';
      }
      return null;
    }
  }

  /**
   * @description Error-routing mock workflow mixing compensatable steps to verify routing together with compensation.
   */
  public class CompensatableErrorRoutedWorkflow implements ErrorRoutingWorkflow {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.CompensatableForwardStep1',
        'WorkflowEngineMocksBTest.ExplicitFailStep',
        'WorkflowEngineMocksATest.NormalHandlerStep',
        'WorkflowEngineMocksATest.CompensatableForwardStep2'
      };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.CompensatableForwardStep1';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param stepResult The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (
        currentStepName == 'WorkflowEngineMocksBTest.CompensatableForwardStep1'
      ) {
        return 'WorkflowEngineMocksBTest.ExplicitFailStep';
      }
      if (currentStepName == 'WorkflowEngineMocksATest.NormalHandlerStep') {
        return 'WorkflowEngineMocksATest.CompensatableForwardStep2';
      }
      return null;
    }
    /**
     * @description Maps a failed step to the error-handling step that should run.
     * @param failedStepName The fully-qualified name of the step that failed.
     * @param error The captured error from the failed step.
     * @return The error-handling step's name, or null to propagate the failure.
     */
    public String getErrorStep(String failedStepName, StepError error) {
      if (failedStepName == 'WorkflowEngineMocksBTest.ExplicitFailStep') {
        return 'WorkflowEngineMocksATest.NormalHandlerStep';
      }
      return null;
    }
  }

  /**
   * @description Mock step that retries under a single-attempt policy so retries exhaust and it fails.
   */
  public class RetryExhaustedFailureStep implements WorkflowStep, RetryConfigurable {
    /**
     * @description Requests a retry under a single-attempt policy so retries exhaust and the step fails.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.retry(getRetryPolicy());
    }
    /**
     * @description Returns the retry policy governing this step's attempts.
     * @return The configured retry policy.
     */
    public RetryPolicy getRetryPolicy() {
      return new RetryPolicy(1, (Double) 1.0, 1);
    }
  }

  /**
   * @description Mock step that splits into a failing branch and a sibling that mutates the instance, to exercise stale-state handling.
   */
  public class StaleSpawnStep implements WorkflowStep {
    /**
     * @description Splits into a failing branch and a sibling that mutates the instance, to exercise stale-state handling.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowEngineMocksBTest.ExplicitFailStep',
          'WorkflowEngineMocksBTest.StaleSignalSiblingStep'
        },
        null
      );
    }
  }

  /**
   * @description Mock step that consumes a signal and advances the instance's current step under a lock to simulate a stale concurrent update.
   */
  public class StaleSignalSiblingStep implements WorkflowStep {
    /**
     * @description Consumes a signal and advances the instance's current step under a row lock to simulate a stale concurrent update.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      ctx.signals().getSignals('TestSignal');
      Workflow_Instance__c inst = [
        SELECT Id, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :ctx.workflowInstanceId
        FOR UPDATE
      ];
      inst.Current_Step__c = 'WorkflowEngineMocksATest.NormalHandlerStep';
      update as system inst;
      return StepResult.complete(null, 'StaleComplete');
    }
  }

  /**
   * @description Error-routing mock workflow that routes a timed-out step to a normal handler.
   */
  public class TimeoutErrorRoutedWorkflow implements ErrorRoutingWorkflow {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.TimeoutFailureStep',
        'WorkflowEngineMocksATest.NormalHandlerStep'
      };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.TimeoutFailureStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param stepResult The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    /**
     * @description Maps a failed step to the error-handling step that should run.
     * @param failedStepName The fully-qualified name of the step that failed.
     * @param error The captured error from the failed step.
     * @return The error-handling step's name, or null to propagate the failure.
     */
    public String getErrorStep(String failedStepName, StepError error) {
      if (failedStepName == 'WorkflowEngineMocksATest.TimeoutFailureStep') {
        return 'WorkflowEngineMocksATest.NormalHandlerStep';
      }
      return null;
    }
  }

  /**
   * @description Error-routing mock workflow whose error handler yields; verifies yielding handlers.
   */
  public class YieldingHandlerWorkflow implements ErrorRoutingWorkflow {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.RetryExhaustedFailureStep',
        'WorkflowEngineMocksATest.YieldingHandlerStep'
      };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.RetryExhaustedFailureStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param stepResult The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    /**
     * @description Maps a failed step to the error-handling step that should run.
     * @param failedStepName The fully-qualified name of the step that failed.
     * @param error The captured error from the failed step.
     * @return The error-handling step's name, or null to propagate the failure.
     */
    public String getErrorStep(String failedStepName, StepError error) {
      if (
        failedStepName == 'WorkflowEngineMocksBTest.RetryExhaustedFailureStep'
      ) {
        return 'WorkflowEngineMocksATest.YieldingHandlerStep';
      }
      return null;
    }
  }

  /**
   * @description Error-routing mock workflow whose error handler is itself retryable.
   */
  public class RetryableHandlerWorkflow implements ErrorRoutingWorkflow {
    /**
     * @description Returns the ordered list of fully-qualified step names comprising this workflow definition.
     * @return The list of step names in this workflow's DAG.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.RetryExhaustedFailureStep',
        'WorkflowEngineMocksBTest.RetryableHandlerStep'
      };
    }
    /**
     * @description Returns the fully-qualified name of the step where this workflow begins execution.
     * @return The initial step's fully-qualified name.
     */
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.RetryExhaustedFailureStep';
    }
    /**
     * @description Determines the next step to run after the given step completes.
     * @param currentStepName The fully-qualified name of the step that just completed.
     * @param stepResult The result returned by the completed step.
     * @return The next step's name, or null if the workflow is complete.
     */
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    /**
     * @description Maps a failed step to the error-handling step that should run.
     * @param failedStepName The fully-qualified name of the step that failed.
     * @param error The captured error from the failed step.
     * @return The error-handling step's name, or null to propagate the failure.
     */
    public String getErrorStep(String failedStepName, StepError error) {
      if (
        failedStepName == 'WorkflowEngineMocksBTest.RetryExhaustedFailureStep'
      ) {
        return 'WorkflowEngineMocksBTest.RetryableHandlerStep';
      }
      return null;
    }
  }

  /**
   * @description Mock retryable error-handler step that records the failed step's context (name, message, attempt count) and completes.
   */
  public class RetryableHandlerStep implements WorkflowStep, RetryConfigurable {
    /**
     * @description Records the failed step's context (name, message, attempt count) and completes, verifying error context is exposed to handlers.
     * @param ctx The durable per-step execution context.
     * @return The StepResult describing the outcome of this step.
     */
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksBTest.routedStepsRun.add('RetryableHandlerStep');
      WorkflowEngineMocksBTest.routedStepContextData.put(
        'failedStepName',
        ctx.retry().failedStepName
      );
      WorkflowEngineMocksBTest.routedStepContextData.put(
        'errorMessage',
        ctx.retry().errorMessage
      );
      WorkflowEngineMocksBTest.routedStepContextData.put(
        'attemptCount',
        ctx.retry().attemptCount
      );
      return StepResult.complete(null, 'HandlerDone');
    }
    /**
     * @description Returns the retry policy governing this step's attempts.
     * @return The configured retry policy.
     */
    public RetryPolicy getRetryPolicy() {
      return new RetryPolicy(5, (Double) 1.0, 3);
    }
  }
}
