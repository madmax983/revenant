@IsTest
public class WorkflowEngineTestMocksA {
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
        'WorkflowEngineTestMocksB.LargeParallelSplitStep',
        'WorkflowEngineTestMocksA.LargeOutputStep',
        'WorkflowEngineTestMocksA.ParallelStep2',
        'WorkflowEngineTestMocksB.LargeParallelJoinStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksB.LargeParallelSplitStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      if (
        currentStepName == 'WorkflowEngineTestMocksB.LargeParallelSplitStep'
      ) {
        return 'WorkflowEngineTestMocksB.LargeParallelJoinStep';
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
      return new List<String>{ 'WorkflowEngineTestMocksA.LargePayloadStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksA.LargePayloadStep';
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
      return new List<String>{ 'WorkflowEngineTestMocksA.CrashingStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksA.CrashingStep';
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
      return new List<String>{ 'WorkflowEngineTestMocksB.FailingStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksB.FailingStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class ApprovalWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTestMocksA.ApprovalStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksA.ApprovalStep';
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
        'WorkflowEngineTestMocksB.SleepingStep',
        'WorkflowEngineTestMocksB.AfterSleepStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksB.SleepingStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineTestMocksB.SleepingStep') {
        return 'WorkflowEngineTestMocksB.AfterSleepStep';
      }
      return null;
    }
  }

  public class ParentWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTestMocksB.ParentStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksB.ParentStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class ChildWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTestMocksA.ChildStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksA.ChildStep';
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
          'WorkflowEngineTestMocksA.ParallelStep1',
          'WorkflowEngineTestMocksA.ParallelStep2'
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
      if (WorkflowEngineTestMocksA.compensationShouldFail) {
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
      return new List<String>{ 'WorkflowEngineTestMocksA.Stage_Compensate' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksA.Stage_Compensate';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null; // terminal
    }
  }

  public class MockQueueable implements Queueable {
    public void execute(QueueableContext ctx) {
      System.attachFinalizer(
        new WorkflowEngineTestMocksB.MockQueueableFinalizer()
      );
      return;
    }
  }

  public class PreviousRunAtWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTestMocksB.PreviousRunAtCaptureStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksB.PreviousRunAtCaptureStep';
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
      return new List<String>{ 'WorkflowEngineTestMocksB.TimeoutContinueStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksB.TimeoutContinueStep';
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
      return new List<String>{ 'WorkflowEngineTestMocksA.NotARealStep' };
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
      return StepResult.waitForApproval(
        'TimedApproval',
        'Manager',
        60,
        'WorkflowEngineTestMocksB.ApprovalTimeoutFallbackStep'
      );
    }
  }

  public class RetryExposeStep implements WorkflowStep, RetryConfigurable {
    public StepResult execute(StepContext ctx) {
      WorkflowEngineTestMocksA.observedAttemptStates.add(
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
        'WorkflowEngineTestMocksB.CompensatableRetryStep',
        'WorkflowEngineTestMocksA.AlwaysFailStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksB.CompensatableRetryStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (
        currentStepName == 'WorkflowEngineTestMocksB.CompensatableRetryStep'
      ) {
        return 'WorkflowEngineTestMocksA.AlwaysFailStep';
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
      return new List<String>{ 'WorkflowEngineTestMocksB.LoopExposeStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksB.LoopExposeStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return stepResult.nextStepName;
    }
  }

  public class ProgressWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTestMocksB.ProgressStep1',
        'WorkflowEngineTestMocksA.ProgressStep2'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksB.ProgressStep1';
    }
    public String getNextStep(String currentStepName, StepResult sr) {
      if (currentStepName == 'WorkflowEngineTestMocksB.ProgressStep1') {
        if (sr.action == StepResult.ActionType.YIELD) {
          return 'WorkflowEngineTestMocksB.ProgressStep1';
        }
        return 'WorkflowEngineTestMocksA.ProgressStep2';
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
        'WorkflowEngineTestMocksB.SkipParallelSplitStep',
        'WorkflowEngineTestMocksB.SkipParallelA',
        'WorkflowEngineTestMocksA.SkipParallelB',
        'WorkflowEngineTestMocksA.SkipParallelJoinStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksB.SkipParallelSplitStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'WorkflowEngineTestMocksB.SkipParallelSplitStep') {
        return 'WorkflowEngineTestMocksA.SkipParallelJoinStep';
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
        'WorkflowEngineTestMocksB.SkipParallelA'
      );
      Map<String, Object> outBMap = (Map<String, Object>) outputs.get(
        'WorkflowEngineTestMocksA.SkipParallelB'
      );
      String valB = (String) outBMap.get('val');
      return StepResult.complete(null, 'Join_' + outA + '_' + valB);
    }
  }

  public class SkipThreeParallelSplitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowEngineTestMocksB.SkipParallelA',
          'WorkflowEngineTestMocksA.SkipParallelB',
          'WorkflowEngineTestMocksA.SkipParallelC'
        },
        null
      );
    }
  }

  public class SkipParallelC implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (WorkflowEngineTestMocksA.failParallelC) {
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
          'WorkflowEngineTestMocksA.CompensatableParallelA',
          'WorkflowEngineTestMocksA.CompensatableParallelB'
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
      return new List<String>{ 'WorkflowEngineTestMocksB.BreadcrumbStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksB.BreadcrumbStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class RollbackWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTestMocksB.RollbackStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksB.RollbackStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class RetryBreadcrumbStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      ctx.log(
        StepContext.Level.INFO,
        'Attempt ' + WorkflowEngineTestMocksB.retryBreadcrumbAttempt
      );
      if (WorkflowEngineTestMocksB.retryBreadcrumbAttempt < 3) {
        WorkflowEngineTestMocksB.retryBreadcrumbAttempt++;
        RetryPolicy policy = new RetryPolicy(1, (Double) 1.0, 5);
        return StepResult.retry(policy);
      }
      return StepResult.complete(null, 'Success');
    }
  }

  public class NormalHandlerStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      WorkflowEngineTestMocksB.routedStepsRun.add('NormalHandlerStep');
      WorkflowEngineTestMocksB.routedStepContextData.put(
        'failedStepName',
        ctx.failedStepName
      );
      WorkflowEngineTestMocksB.routedStepContextData.put(
        'errorMessage',
        ctx.errorMessage
      );
      WorkflowEngineTestMocksB.routedStepContextData.put(
        'attemptCount',
        ctx.attemptCount
      );
      return StepResult.complete(null, 'HandlerComplete');
    }
  }

  public class CompensatableForwardStep2 implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      WorkflowEngineTestMocksB.routedStepsRun.add('CompensatableForwardStep2');
      return StepResult.complete(null, 'Step2Output');
    }
    public StepResult compensate(StepContext ctx) {
      WorkflowEngineTestMocksB.compensationsRun.add(
        'CompensatableForwardStep2_Compensate'
      );
      return StepResult.complete(null, 'Compensate2Complete');
    }
  }

  public class FailingHandlerWorkflow implements ErrorRoutingWorkflow {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTestMocksB.ExplicitFailStep',
        'WorkflowEngineTestMocksB.FailingHandlerStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksB.ExplicitFailStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    public String getErrorStep(String failedStepName, StepError error) {
      if (failedStepName == 'WorkflowEngineTestMocksB.ExplicitFailStep') {
        return 'WorkflowEngineTestMocksB.FailingHandlerStep';
      }
      return null;
    }
  }

  public class ParallelSpawnStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowEngineTestMocksB.ExplicitFailStep',
          'WorkflowEngineTestMocksA.SiblingStep'
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
        'WorkflowEngineTestMocksA.ParallelSpawnStep',
        'WorkflowEngineTestMocksB.ExplicitFailStep',
        'WorkflowEngineTestMocksA.SiblingStep',
        'WorkflowEngineTestMocksA.NormalHandlerStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksA.ParallelSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    public String getErrorStep(String failedStepName, StepError error) {
      if (failedStepName == 'WorkflowEngineTestMocksB.ExplicitFailStep') {
        return 'WorkflowEngineTestMocksA.NormalHandlerStep';
      }
      return null;
    }
  }

  public class RetryExhaustedErrorRoutedWorkflow implements ErrorRoutingWorkflow {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTestMocksB.RetryExhaustedFailureStep',
        'WorkflowEngineTestMocksA.NormalHandlerStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksB.RetryExhaustedFailureStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    public String getErrorStep(String failedStepName, StepError error) {
      if (
        failedStepName == 'WorkflowEngineTestMocksB.RetryExhaustedFailureStep'
      ) {
        return 'WorkflowEngineTestMocksA.NormalHandlerStep';
      }
      return null;
    }
  }

  public class StaleSignalRollbackWorkflow implements ErrorRoutingWorkflow {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTestMocksB.StaleSpawnStep',
        'WorkflowEngineTestMocksB.ExplicitFailStep',
        'WorkflowEngineTestMocksB.StaleSignalSiblingStep',
        'WorkflowEngineTestMocksA.NormalHandlerStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksB.StaleSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
    public String getErrorStep(String failedStepName, StepError error) {
      if (failedStepName == 'WorkflowEngineTestMocksB.ExplicitFailStep') {
        return 'WorkflowEngineTestMocksA.NormalHandlerStep';
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
      return new List<String>{ 'WorkflowEngineTestMocksA.NormalHandlerStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTestMocksA.NormalHandlerStep';
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
      if (!WorkflowEngineTestMocksB.yieldingHandlerFirstRunDone) {
        WorkflowEngineTestMocksB.yieldingHandlerFirstRunDone = true;
        ctx.once('hasYielded', new WorkflowEngineTestMocksA.YieldedProducer());
        return StepResult.sleep(10, 'YieldingHandlerStep');
      }
      WorkflowEngineTestMocksB.routedStepsRun.add('YieldingHandlerStep');
      WorkflowEngineTestMocksB.routedStepContextData.put(
        'failedStepName',
        ctx.failedStepName
      );
      WorkflowEngineTestMocksB.routedStepContextData.put(
        'errorMessage',
        ctx.errorMessage
      );
      WorkflowEngineTestMocksB.routedStepContextData.put(
        'attemptCount',
        ctx.attemptCount
      );
      return StepResult.complete(null, 'HandlerDone');
    }
  }
}
