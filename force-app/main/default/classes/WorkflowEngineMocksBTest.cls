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

  public class CalloutWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.DirectCalloutStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.DirectCalloutStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  public class DirectCalloutStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      HttpRequest req = new HttpRequest();
      req.setEndpoint('https://api.example.com/test');
      req.setMethod('GET');
      Http h = new Http();
      HttpResponse res = h.send(req);
      return StepResult.complete(null, res.getBody());
    }
  }

  public class LargeParallelSplitStep implements WorkflowStep {
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

  public class LargeParallelJoinStep implements WorkflowStep {
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

  public class YieldingWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.YieldingStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.YieldingStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class YieldingStep implements WorkflowStep {
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

  public class FailingStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (WorkflowEngineMocksATest.shouldSucceedOnFailingStep) {
        return StepResult.complete(null, 'SuccessAfterRetry');
      }
      RetryPolicy policy = new RetryPolicy();
      policy.maximumAttempts = 1;
      return StepResult.retry(policy);
    }
  }

  public class TimeoutWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.TimeoutStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.TimeoutStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class RetryingWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.RetryingStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.RetryingStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class SignaledWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.SignaledStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.SignaledStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class CustomRetryWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.CustomRetryStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.CustomRetryStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class CustomRetryStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Initial = 2s, backoff coefficient = 3.0, max attempts = 3
      RetryPolicy policy = new RetryPolicy(2, (Double) 3.0, 3);
      return StepResult.retry(policy);
    }
  }

  public class SleepingStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (ctx.stepStateJson != null) {
        return StepResult.complete(
          'WorkflowEngineMocksBTest.AfterSleepStep',
          ctx.stepStateJson
        );
      }
      return StepResult.sleep(10, 'resumed_state');
    }
  }

  public class AfterSleepStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String payload = (String) JSON.deserialize(
        ctx.previousStepOutput,
        String.class
      );
      return StepResult.complete(null, 'Done_' + payload);
    }
  }

  public class ParentStep implements WorkflowStep {
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

  public class ParallelWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.SplitStep',
        'WorkflowEngineMocksATest.ParallelStep1',
        'WorkflowEngineMocksATest.ParallelStep2',
        'WorkflowEngineMocksBTest.JoinStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.SplitStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineMocksATest.SplitStep') {
        return 'WorkflowEngineMocksBTest.JoinStep';
      }
      return null;
    }
  }

  public class JoinStep implements WorkflowStep {
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

  public class PreviousRunAtCompensatableStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    public StepResult compensate(StepContext ctx) {
      WorkflowEngineMocksATest.capturedCompensatePreviousRunAt = ctx.previousRunAt;
      WorkflowEngineMocksATest.compensatePreviousRunAtCaptured = true;
      return StepResult.complete(null, 'Compensated');
    }
  }

  public class CalloutCompensationStep implements CompensatableStep, CalloutStep, TimeoutConfigurable {
    public Integer getTimeoutSeconds() {
      return 60;
    }
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    public StepResult compensate(StepContext ctx) {
      ctx.getSignal('CompSig');
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

  public class SignalWaitCompensationStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    public StepResult compensate(StepContext ctx) {
      if (!ctx.hasSignal('Rollback')) {
        return StepResult.suspend();
      }
      return StepResult.complete(null, 'CompensatedAfterSignal');
    }
  }

  public class MockQueueableFinalizer implements System.Finalizer {
    public void execute(System.FinalizerContext fctx) {
      return;
    }
  }

  public class DaemonWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.IncrementCounterStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.IncrementCounterStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class PreviousRunAtCaptureStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (ctx.previousRunAt == null) {
        return StepResult.continueAsNew(null);
      }
      return StepResult.complete(null, ctx.previousRunAt.getTime());
    }
  }

  public class TimeoutContinueStep implements WorkflowStep, TimeoutConfigurable {
    public Integer getTimeoutSeconds() {
      return 60;
    }
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

  public class CompensatableCrashStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    public StepResult compensate(StepContext ctx) {
      throw new WorkflowEngine.WorkflowException(
        'Compensation crash simulation'
      );
    }
  }

  public class CompensatableCancelWordStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    public StepResult compensate(StepContext ctx) {
      if (WorkflowEngineMocksATest.cancelWordCompensationShouldFail) {
        throw new WorkflowEngine.WorkflowException(
          'OrderCancelledException: the order was Cancelled upstream'
        );
      }
      return StepResult.complete(null, 'Reversed');
    }
  }

  public class TimedApprovalWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.TimedApprovalStep',
        'WorkflowEngineMocksBTest.ApprovalTimeoutFallbackStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.TimedApprovalStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class ApprovalTimeoutFallbackStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'approval_timedout');
    }
  }

  public class RetryExposeWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.RetryExposeStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.RetryExposeStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class DynamicRetryWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.DynamicRetryStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.DynamicRetryStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class DynamicRetryStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksATest.dynamicObservedStates.add(
        new Map<String, Object>{
          'attempt' => ctx.attempt,
          'maxAttempts' => ctx.maxAttempts,
          'isFinalAttempt' => ctx.isFinalAttempt()
        }
      );
      if (ctx.attempt >= 3) {
        return StepResult.complete(null, 'DynamicComplete');
      }
      return StepResult.retry(new RetryPolicy(1, (Double) 1.0, 3));
    }
  }

  public class CompensatableRetryStep implements CompensatableStep, RetryConfigurable {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }

    public StepResult compensate(StepContext ctx) {
      WorkflowEngineMocksBTest.compensationObservedStates.add(
        new Map<String, Object>{
          'attempt' => ctx.attempt,
          'maxAttempts' => ctx.maxAttempts,
          'isFinalAttempt' => ctx.isFinalAttempt()
        }
      );
      if (ctx.isFinalAttempt()) {
        return StepResult.complete(null, 'Compensated');
      }
      return StepResult.retry(getRetryPolicy());
    }

    public RetryPolicy getRetryPolicy() {
      return new RetryPolicy(1, (Double) 1.0, 2);
    }
  }

  public class LoopExposeStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksBTest.loopObservedStates.add(
        new Map<String, Object>{
          'attempt' => ctx.attempt,
          'maxAttempts' => ctx.maxAttempts
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

  public class ProgressStep1 implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (String.isBlank(ctx.stepStateJson)) {
        ctx.reportProgress(20.0, 'Step 1: Yielding first');
        return StepResult.yield('{"yieldedOnce": true}');
      }
      ctx.reportProgress(50.0, 'Step 1: Done');
      return StepResult.complete(
        'WorkflowEngineMocksATest.ProgressStep2',
        'Output1'
      );
    }
  }

  public class SkipTestWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.SkipTestStep1',
        'WorkflowEngineMocksATest.SkipTestStep2',
        'WorkflowEngineMocksBTest.SkipTestStep3'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.SkipTestStep1';
    }
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

  public class SkipTestStep3 implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Map<String, Object> outputMap = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.previousStepOutput
      );
      String val = (String) outputMap.get('overrideVal');
      return StepResult.complete(null, 'StepThreeReceived_' + val);
    }
  }

  public class SkipParallelSplitStep implements WorkflowStep {
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

  public class SkipParallelA implements WorkflowStep, TimeoutConfigurable {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'OutputA');
    }
    public Integer getTimeoutSeconds() {
      return 60;
    }
  }

  public class TerminalSkipWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.TerminalSkipStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.TerminalSkipStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  public class TerminalSkipStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('Poison terminal step');
    }
  }

  public class SkipThreeParallelWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.SkipThreeParallelSplitStep',
        'WorkflowEngineMocksBTest.SkipParallelA',
        'WorkflowEngineMocksATest.SkipParallelB',
        'WorkflowEngineMocksATest.SkipParallelC',
        'WorkflowEngineMocksATest.SkipParallelJoinStep3'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.SkipThreeParallelSplitStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      if (
        currentStepName == 'WorkflowEngineMocksATest.SkipThreeParallelSplitStep'
      ) {
        return 'WorkflowEngineMocksATest.SkipParallelJoinStep3';
      }
      return null;
    }
  }

  public class CompensatableParallelWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.CompensatableParallelSplitStep',
        'WorkflowEngineMocksATest.CompensatableParallelA',
        'WorkflowEngineMocksATest.CompensatableParallelB',
        'WorkflowEngineMocksBTest.CompensatableParallelJoinStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.CompensatableParallelSplitStep';
    }
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

  public class CompensatableParallelJoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'JoinDone');
    }
  }

  public class BreadcrumbStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      ctx.log(
        StepContext.Level.INFO,
        'Step 1 execution started',
        new Map<String, Object>{ 'status' => 'init' }
      );
      ctx.log(StepContext.Level.WARN, 'Step 1 warning encountered');
      return StepResult.complete(null, 'Success');
    }
  }

  public class RollbackStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      ctx.log(StepContext.Level.INFO, 'This should not be saved');
      throw new WorkflowEngine.WorkflowException('Simulated Failure');
    }
  }

  public class RetryBreadcrumbWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.RetryBreadcrumbStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.RetryBreadcrumbStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  public class CrashStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      throw new IllegalArgumentException('Crash in execution');
    }
  }

  public class ExplicitFailStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('Explicit business failure');
    }
  }

  public class RetryThenFailStep implements WorkflowStep, RetryConfigurable {
    public StepResult execute(StepContext ctx) {
      if (ctx.attempt >= 2) {
        return StepResult.fail('Failed after retry');
      }
      return StepResult.retry(getRetryPolicy());
    }
    public RetryPolicy getRetryPolicy() {
      return new RetryPolicy(1, (Double) 1.0, 2);
    }
  }

  public class FailingHandlerStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksBTest.routedStepsRun.add('FailingHandlerStep');
      return StepResult.fail('Handler itself failed');
    }
  }

  public class CompensatableForwardStep1 implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksBTest.routedStepsRun.add('CompensatableForwardStep1');
      return StepResult.complete(null, 'Step1Output');
    }
    public StepResult compensate(StepContext ctx) {
      WorkflowEngineMocksBTest.compensationsRun.add(
        'CompensatableForwardStep1_Compensate'
      );
      return StepResult.complete(null, 'Compensate1Complete');
    }
  }

  public class ErrorRoutedWorkflow implements ErrorRoutingWorkflow {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.CrashStep',
        'WorkflowEngineMocksBTest.ExplicitFailStep',
        'WorkflowEngineMocksBTest.RetryThenFailStep',
        'WorkflowEngineMocksATest.NormalHandlerStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.CrashStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
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

  public class CompensatableErrorRoutedWorkflow implements ErrorRoutingWorkflow {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.CompensatableForwardStep1',
        'WorkflowEngineMocksBTest.ExplicitFailStep',
        'WorkflowEngineMocksATest.NormalHandlerStep',
        'WorkflowEngineMocksATest.CompensatableForwardStep2'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.CompensatableForwardStep1';
    }
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
    public String getErrorStep(String failedStepName, StepError error) {
      if (failedStepName == 'WorkflowEngineMocksBTest.ExplicitFailStep') {
        return 'WorkflowEngineMocksATest.NormalHandlerStep';
      }
      return null;
    }
  }

  public class RetryExhaustedFailureStep implements WorkflowStep, RetryConfigurable {
    public StepResult execute(StepContext ctx) {
      return StepResult.retry(getRetryPolicy());
    }
    public RetryPolicy getRetryPolicy() {
      return new RetryPolicy(1, (Double) 1.0, 1);
    }
  }

  public class StaleSpawnStep implements WorkflowStep {
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

  public class StaleSignalSiblingStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      ctx.getSignals('TestSignal');
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

  public class TimeoutErrorRoutedWorkflow implements ErrorRoutingWorkflow {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.TimeoutFailureStep',
        'WorkflowEngineMocksATest.NormalHandlerStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.TimeoutFailureStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    public String getErrorStep(String failedStepName, StepError error) {
      if (failedStepName == 'WorkflowEngineMocksATest.TimeoutFailureStep') {
        return 'WorkflowEngineMocksATest.NormalHandlerStep';
      }
      return null;
    }
  }

  public class YieldingHandlerWorkflow implements ErrorRoutingWorkflow {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.RetryExhaustedFailureStep',
        'WorkflowEngineMocksATest.YieldingHandlerStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.RetryExhaustedFailureStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    public String getErrorStep(String failedStepName, StepError error) {
      if (
        failedStepName == 'WorkflowEngineMocksBTest.RetryExhaustedFailureStep'
      ) {
        return 'WorkflowEngineMocksATest.YieldingHandlerStep';
      }
      return null;
    }
  }

  public class RetryableHandlerWorkflow implements ErrorRoutingWorkflow {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.RetryExhaustedFailureStep',
        'WorkflowEngineMocksBTest.RetryableHandlerStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.RetryExhaustedFailureStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    public String getErrorStep(String failedStepName, StepError error) {
      if (
        failedStepName == 'WorkflowEngineMocksBTest.RetryExhaustedFailureStep'
      ) {
        return 'WorkflowEngineMocksBTest.RetryableHandlerStep';
      }
      return null;
    }
  }

  public class RetryableHandlerStep implements WorkflowStep, RetryConfigurable {
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksBTest.routedStepsRun.add('RetryableHandlerStep');
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
    public RetryPolicy getRetryPolicy() {
      return new RetryPolicy(5, (Double) 1.0, 3);
    }
  }
}
