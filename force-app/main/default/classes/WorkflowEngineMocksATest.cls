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

  public class MockCalloutResponse implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setHeader('Content-Type', 'application/json');
      res.setBody('{"status":"success"}');
      res.setStatusCode(200);
      return res;
    }
  }

  public class LargeParallelWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.LargeParallelSplitStep',
        'WorkflowEngineMocksATest.LargeOutputStep',
        'WorkflowEngineMocksATest.ParallelStep2',
        'WorkflowEngineMocksBTest.LargeParallelJoinStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.LargeParallelSplitStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      if (
        currentStepName == 'WorkflowEngineMocksBTest.LargeParallelSplitStep'
      ) {
        return 'WorkflowEngineMocksBTest.LargeParallelJoinStep';
      }
      return null;
    }
  }

  public class LargeOutputStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String largeStr = 'a'.repeat(110000);
      return StepResult.complete(null, largeStr);
    }
  }

  public class LargePayloadWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.LargePayloadStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.LargePayloadStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class LargePayloadStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      System.assertNotEquals(null, ctx.workflowInputJson);
      System.assert(ctx.workflowInputJson.length() > 100000);
      return StepResult.complete(null, 'B'.repeat(110000));
    }
  }

  public class YieldingChunkState {
    public Integer processed;
    public Integer total;
  }

  public class CrashingWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.CrashingStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.CrashingStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class CrashingStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      throw new IllegalArgumentException('Simulated Crash');
    }
  }

  public class FailingWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.FailingStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.FailingStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class ApprovalWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.ApprovalStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.ApprovalStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class ApprovalStep implements WorkflowStep {
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

  public class RetryingStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.retry(5);
    }
  }

  public class SignaledStep implements WorkflowStep {
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

  public class SleepingWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.SleepingStep',
        'WorkflowEngineMocksBTest.AfterSleepStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.SleepingStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineMocksBTest.SleepingStep') {
        return 'WorkflowEngineMocksBTest.AfterSleepStep';
      }
      return null;
    }
  }

  public class ParentWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.ParentStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.ParentStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class ChildWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.ChildStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.ChildStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class ChildStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String input = (String) JSON.deserialize(ctx.inputJson, String.class);
      return StepResult.complete(null, input + '_ChildDone');
    }
  }

  public class SplitStep implements WorkflowStep {
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

  public class ParallelStep1 implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String input = (String) JSON.deserialize(ctx.inputJson, String.class);
      return StepResult.complete(null, input + '_P1Done');
    }
  }

  public class ParallelStep2 implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String input = (String) JSON.deserialize(ctx.inputJson, String.class);
      return StepResult.complete(null, input + '_P2Done');
    }
  }

  public class CompensatableFailingStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
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

  public class CompOkMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(204);
      res.setBody('');
      return res;
    }
  }

  public class Stage_Compensate implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (!ctx.hasSignal('Go')) {
        return StepResult.suspend();
      }
      return StepResult.complete(null, 'done');
    }
  }

  public class SuffixForwardWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.Stage_Compensate' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.Stage_Compensate';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null; // terminal
    }
  }

  public class MockQueueable implements Queueable {
    public void execute(QueueableContext ctx) {
      System.attachFinalizer(
        new WorkflowEngineMocksBTest.MockQueueableFinalizer()
      );
      return;
    }
  }

  public class PreviousRunAtWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.PreviousRunAtCaptureStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.PreviousRunAtCaptureStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class IncrementCounterStep implements WorkflowStep {
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

  public class TimeoutContinueWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.TimeoutContinueStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.TimeoutContinueStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class NotARealStep {
    public String label() {
      return 'not a step';
    }
  }

  public class MalformedValidatorWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.NotARealStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.HappyStep1'; // not contained in getSteps()
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return 'WorkflowEngineTest.NoSuchStep'; // dangling, undeclared successor
    }
  }

  public class TimedApprovalStep implements WorkflowStep {
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

  public class RetryExposeStep implements WorkflowStep, RetryConfigurable {
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

    public RetryPolicy getRetryPolicy() {
      return new RetryPolicy(1, (Double) 1.0, 3);
    }
  }

  public class CompensatableRetryWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.CompensatableRetryStep',
        'WorkflowEngineMocksATest.AlwaysFailStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.CompensatableRetryStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (
        currentStepName == 'WorkflowEngineMocksBTest.CompensatableRetryStep'
      ) {
        return 'WorkflowEngineMocksATest.AlwaysFailStep';
      }
      return null;
    }
  }

  public class AlwaysFailStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('Forced fail to trigger compensation');
    }
  }

  public class LoopExposeWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.LoopExposeStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.LoopExposeStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return stepResult.nextStepName;
    }
  }

  public class ProgressWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.ProgressStep1',
        'WorkflowEngineMocksATest.ProgressStep2'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.ProgressStep1';
    }
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

  public class ProgressStep2 implements WorkflowStep {
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

  public class SkipTestStep1 implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'InputToTwo');
    }
  }

  public class SkipTestStep2 implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('Poison step: failed permanently');
    }
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, 'CompensatedTwo');
    }
  }

  public class SkipParallelWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.SkipParallelSplitStep',
        'WorkflowEngineMocksBTest.SkipParallelA',
        'WorkflowEngineMocksATest.SkipParallelB',
        'WorkflowEngineMocksATest.SkipParallelJoinStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.SkipParallelSplitStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'WorkflowEngineMocksBTest.SkipParallelSplitStep') {
        return 'WorkflowEngineMocksATest.SkipParallelJoinStep';
      }
      return null;
    }
  }

  public class SkipParallelB implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('Parallel Poison Step');
    }
  }

  public class SkipParallelJoinStep implements WorkflowStep {
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

  public class SkipThreeParallelSplitStep implements WorkflowStep {
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

  public class SkipParallelC implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (WorkflowEngineMocksATest.failParallelC) {
        return StepResult.fail('Parallel Poison Step C');
      }
      return StepResult.complete(null, 'OutputC');
    }
  }

  public class SkipParallelJoinStep3 implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Join3');
    }
  }

  public class CompensatableParallelSplitStep implements WorkflowStep {
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

  public class CompensatableParallelA implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'OutputA');
    }
  }

  public class CompensatableParallelB implements WorkflowStep, CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'OutputB');
    }
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, 'CompensatedB');
    }
  }

  public class BreadcrumbWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.BreadcrumbStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.BreadcrumbStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class RollbackWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksBTest.RollbackStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.RollbackStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class RetryBreadcrumbStep implements WorkflowStep {
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

  public class NormalHandlerStep implements WorkflowStep {
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

  public class CompensatableForwardStep2 implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      WorkflowEngineMocksBTest.routedStepsRun.add('CompensatableForwardStep2');
      return StepResult.complete(null, 'Step2Output');
    }
    public StepResult compensate(StepContext ctx) {
      WorkflowEngineMocksBTest.compensationsRun.add(
        'CompensatableForwardStep2_Compensate'
      );
      return StepResult.complete(null, 'Compensate2Complete');
    }
  }

  public class FailingHandlerWorkflow implements ErrorRoutingWorkflow {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.ExplicitFailStep',
        'WorkflowEngineMocksBTest.FailingHandlerStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.ExplicitFailStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    public String getErrorStep(String failedStepName, StepError error) {
      if (failedStepName == 'WorkflowEngineMocksBTest.ExplicitFailStep') {
        return 'WorkflowEngineMocksBTest.FailingHandlerStep';
      }
      return null;
    }
  }

  public class ParallelSpawnStep implements WorkflowStep {
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

  public class SiblingStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'SiblingComplete');
    }
  }

  public class ParallelErrorRoutedWorkflow implements ErrorRoutingWorkflow {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksATest.ParallelSpawnStep',
        'WorkflowEngineMocksBTest.ExplicitFailStep',
        'WorkflowEngineMocksATest.SiblingStep',
        'WorkflowEngineMocksATest.NormalHandlerStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.ParallelSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    public String getErrorStep(String failedStepName, StepError error) {
      if (failedStepName == 'WorkflowEngineMocksBTest.ExplicitFailStep') {
        return 'WorkflowEngineMocksATest.NormalHandlerStep';
      }
      return null;
    }
  }

  public class RetryExhaustedErrorRoutedWorkflow implements ErrorRoutingWorkflow {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.RetryExhaustedFailureStep',
        'WorkflowEngineMocksATest.NormalHandlerStep'
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
        return 'WorkflowEngineMocksATest.NormalHandlerStep';
      }
      return null;
    }
  }

  public class StaleSignalRollbackWorkflow implements ErrorRoutingWorkflow {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineMocksBTest.StaleSpawnStep',
        'WorkflowEngineMocksBTest.ExplicitFailStep',
        'WorkflowEngineMocksBTest.StaleSignalSiblingStep',
        'WorkflowEngineMocksATest.NormalHandlerStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksBTest.StaleSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    public String getErrorStep(String failedStepName, StepError error) {
      if (failedStepName == 'WorkflowEngineMocksBTest.ExplicitFailStep') {
        return 'WorkflowEngineMocksATest.NormalHandlerStep';
      }
      return null;
    }
  }

  public class TimeoutFailureStep implements WorkflowStep, TimeoutConfigurable {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'TimeoutDone');
    }
    public Integer getTimeoutSeconds() {
      return 10;
    }
  }

  public class PureRoutingWorkflow implements ErrorRoutingWorkflow {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineMocksATest.NormalHandlerStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineMocksATest.NormalHandlerStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    public String getErrorStep(String failedStepName, StepError error) {
      return null;
    }
  }

  public class YieldedProducer implements CaptureProducer {
    public Object produce() {
      return true;
    }
  }

  public class YieldingHandlerStep implements WorkflowStep {
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
