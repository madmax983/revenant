@isTest
public class WorkflowEngineTest {
  public static Boolean failParallelC = true;
  // ==========================================
  // MOCK WORKFLOWS & STEPS FOR TESTING
  // ==========================================

  public class HappyWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.HappyStep1',
        'WorkflowEngineTest.HappyStep2'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.HappyStep1';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineTest.HappyStep1') {
        return 'WorkflowEngineTest.HappyStep2';
      }
      return null;
    }
  }

  public class HappyStep1 implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete('WorkflowEngineTest.HappyStep2', 'Output1');
    }
  }

  public class HappyStep2 implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String input = (String) JSON.deserialize(
        ctx.previousStepOutput,
        String.class
      );
      return StepResult.complete(null, input + '_Output2');
    }
  }

  public class MockCalloutResponse implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setHeader('Content-Type', 'application/json');
      res.setBody('{"status":"success"}');
      res.setStatusCode(200);
      return res;
    }
  }

  public class CalloutWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.DirectCalloutStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.DirectCalloutStep';
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

  public class LargeParallelWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.LargeParallelSplitStep',
        'WorkflowEngineTest.LargeOutputStep',
        'WorkflowEngineTest.ParallelStep2',
        'WorkflowEngineTest.LargeParallelJoinStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.LargeParallelSplitStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'WorkflowEngineTest.LargeParallelSplitStep') {
        return 'WorkflowEngineTest.LargeParallelJoinStep';
      }
      return null;
    }
  }

  public class LargeParallelSplitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowEngineTest.LargeOutputStep',
          'WorkflowEngineTest.ParallelStep2'
        },
        'BranchInput'
      );
    }
  }

  public class LargeOutputStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String largeStr = 'a'.repeat(110000);
      return StepResult.complete(null, largeStr);
    }
  }

  public class LargeParallelJoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.inputJson
      );
      String val1 = (String) input.get('WorkflowEngineTest.LargeOutputStep');
      System.assertNotEquals(null, val1);
      System.assertEquals(110000, val1.length());
      return StepResult.complete(null, 'OK');
    }
  }

  public class LargePayloadWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.LargePayloadStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.LargePayloadStep';
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

  public class YieldingWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.YieldingStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.YieldingStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class YieldingChunkState {
    public Integer processed;
    public Integer total;
  }

  public class YieldingStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      YieldingChunkState state;
      if (ctx.stepStateJson != null) {
        state = (YieldingChunkState) JSON.deserialize(
          ctx.stepStateJson,
          YieldingChunkState.class
        );
      } else {
        state = new YieldingChunkState();
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

  public class SuspendingWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.SuspendingStep',
        'WorkflowEngineTest.AfterSuspendStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.SuspendingStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineTest.SuspendingStep') {
        return 'WorkflowEngineTest.AfterSuspendStep';
      }
      return null;
    }
  }

  public class SuspendingStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (ctx.stepStateJson != null) {
        return StepResult.complete(
          'WorkflowEngineTest.AfterSuspendStep',
          ctx.stepStateJson
        );
      }
      return StepResult.suspend();
    }
  }

  public class AfterSuspendStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      String payload = (String) JSON.deserialize(
        ctx.previousStepOutput,
        String.class
      );
      return StepResult.complete(null, 'Resumed_' + payload);
    }
  }

  public class CrashingWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.CrashingStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.CrashingStep';
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
      return new List<String>{ 'WorkflowEngineTest.FailingStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.FailingStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public static Boolean shouldSucceedOnFailingStep = false;

  public class FailingStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (shouldSucceedOnFailingStep) {
        return StepResult.complete(null, 'SuccessAfterRetry');
      }
      RetryPolicy policy = new RetryPolicy();
      policy.maximumAttempts = 1;
      return StepResult.retry(policy);
    }
  }

  public class ApprovalWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.ApprovalStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.ApprovalStep';
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

  public class TimeoutStep implements WorkflowStep, TimeoutConfigurable {
    public Integer getTimeoutSeconds() {
      return 60;
    }
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'TimeoutComplete');
    }
  }

  public class RetryingWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.RetryingStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.RetryingStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class RetryingStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.retry(5);
    }
  }

  public class SignaledWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.SignaledStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.SignaledStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
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

  public class CustomRetryWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.CustomRetryStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.CustomRetryStep';
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

  public class SleepingWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.SleepingStep',
        'WorkflowEngineTest.AfterSleepStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.SleepingStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineTest.SleepingStep') {
        return 'WorkflowEngineTest.AfterSleepStep';
      }
      return null;
    }
  }

  public class SleepingStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (ctx.stepStateJson != null) {
        return StepResult.complete(
          'WorkflowEngineTest.AfterSleepStep',
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

  public class ParentWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.ParentStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.ParentStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
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
        'WorkflowEngineTest.ChildWorkflow',
        'SubKey',
        'ChildInput'
      );
    }
  }

  public class ChildWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.ChildStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.ChildStep';
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

  // ==========================================
  // TEST METHODS
  // ==========================================

  @isTest
  static void testHappyPath() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'HappyKey',
      'StartVal'
    );
    Test.stopTest(); // Runs HappyStep1 synchronously

    // Manually execute second step HappyStep2 synchronously
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c inst = [
      SELECT Status__c, Output__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assertEquals('"Output1_Output2"', inst.Output__c);
    System.assertEquals(null, inst.Current_Step__c);

    List<Workflow_Step_Execution__c> steps = [
      SELECT Step_Name__c, Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      ORDER BY CreatedDate ASC
    ];
    System.assertEquals(2, steps.size());
    System.assertEquals('WorkflowEngineTest.HappyStep1', steps[0].Step_Name__c);
    System.assertEquals('Completed', steps[0].Status__c);
    System.assertEquals('WorkflowEngineTest.HappyStep2', steps[1].Step_Name__c);
    System.assertEquals('Completed', steps[1].Status__c);
  }

  @isTest
  static void testYieldingPath() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.YieldingWorkflow',
      'YieldKey',
      null
    );
    Test.stopTest(); // Runs initial step execution (which yields first time)

    Workflow_Instance__c inst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Running', inst.Status__c);

    List<Workflow_Step_Execution__c> steps = [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
    ];
    System.assertEquals(1, steps.size());
    System.assertEquals('Running', steps[0].Status__c);
    System.assert(steps[0].Output__c.contains('"processed":1'));

    // Manually run orchestrator for second yield (processed = 2)
    new WorkflowOrchestrator(instanceId).execute(null);
    steps = [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
    ];
    System.assert(steps[0].Output__c.contains('"processed":2'));

    // Manually run orchestrator for third yield (processed = 3)
    new WorkflowOrchestrator(instanceId).execute(null);
    steps = [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
    ];
    System.assert(steps[0].Output__c.contains('"processed":3'));

    // Manually run orchestrator for final complete
    new WorkflowOrchestrator(instanceId).execute(null);

    inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assertEquals('"Done_3"', inst.Output__c);
  }

  @isTest
  static void testSuspensionAndResume() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SuspendingWorkflow',
      'SuspendKey',
      null
    );
    Test.stopTest(); // Enqueues and executes SuspendingStep which suspends

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', inst.Status__c);
    System.assertEquals(
      'WorkflowEngineTest.SuspendingStep',
      inst.Current_Step__c
    );

    // Resume using Platform Event
    Workflow_Event__e event = new Workflow_Event__e(
      Workflow_Instance_Id__c = 'SuspendKey',
      Event_Type__c = 'RESUME',
      Payload__c = 'EventData'
    );

    EventBus.publish(event);
    Test.getEventBus().deliver(); // Trigger executes resume() synchronously

    // Manually run orchestrator to execute the next step (resumed SuspendingStep)
    new WorkflowOrchestrator(instanceId).execute(null);

    // Manually run orchestrator again to execute the subsequent AfterSuspendStep
    new WorkflowOrchestrator(instanceId).execute(null);

    inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assertEquals('"Resumed_EventData"', inst.Output__c);
  }

  @isTest
  static void testSignals() {
    // Start a workflow that blocks on a signal
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SignaledWorkflow',
      'SignalKey',
      null
    );
    Test.stopTest(); // Runs SignaledStep which suspends waiting for 'PaymentReceived'

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', inst.Status__c);
    System.assertEquals(
      'WorkflowEngineTest.SignaledStep',
      inst.Current_Step__c
    );

    // Send a signal via Platform Event using Event_Type__c = 'SIGNAL:PaymentReceived'
    Workflow_Event__e event = new Workflow_Event__e(
      Workflow_Instance_Id__c = 'SignalKey',
      Event_Type__c = 'SIGNAL:PaymentReceived',
      Payload__c = '{"amount": 150}'
    );

    EventBus.publish(event);
    Test.getEventBus().deliver(); // Trigger runs, inserts Workflow_Signal__c, sets workflow to Running

    // Verify the signal was recorded
    Workflow_Signal__c sig = [
      SELECT Signal_Name__c, Payload__c, Status__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :instanceId
      LIMIT 1
    ];
    System.assertEquals('PaymentReceived', sig.Signal_Name__c);
    System.assertEquals('{"amount": 150}', sig.Payload__c);
    System.assertEquals('Received', sig.Status__c);

    // Manually execute the orchestrator to run the step again with the signal now populated
    new WorkflowOrchestrator(instanceId).execute(null);

    // Verify that the step completed and consumed the signal
    inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assertEquals('"Paid_{\\"amount\\": 150}"', inst.Output__c);

    sig = [SELECT Status__c FROM Workflow_Signal__c WHERE Id = :sig.Id];
    System.assertEquals('Consumed', sig.Status__c);
  }

  @isTest
  static void testCustomRetryPolicy() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.CustomRetryWorkflow',
      'RetryKey',
      null
    );
    Test.stopTest(); // Runs CustomRetryStep once synchronously, which fails and triggers first retry (attempts=1, delay=2s)

    Workflow_Step_Execution__c step = [
      SELECT Status__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      LIMIT 1
    ];
    System.assertEquals('Retrying', step.Status__c);
    System.assertEquals(1, step.Retry_Count__c);

    // Run second attempt manually
    WorkflowEngine.runStep(instanceId); // CustomRetryStep runs, returns retry, triggers second retry (attempts=2, delay=6s)

    step = [
      SELECT Status__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      LIMIT 1
    ];
    System.assertEquals('Retrying', step.Status__c);
    System.assertEquals(2, step.Retry_Count__c);

    // Run third attempt manually (should exceed maximum attempts of 3)
    WorkflowEngine.runStep(instanceId); // CustomRetryStep runs, returns retry, attempts=3 >= maximumAttempts(3) -> transitions to Failed

    step = [
      SELECT Status__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      LIMIT 1
    ];
    System.assertEquals('Failed', step.Status__c);
    System.assertEquals(3, step.Retry_Count__c);

    Workflow_Instance__c inst = [
      SELECT Status__c, Error_Message__c, Failure_Category__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', inst.Status__c);
    System.assert(inst.Error_Message__c.contains('Max retries exceeded'));
    System.assertEquals('RETRIES_EXHAUSTED', inst.Failure_Category__c);
  }

  @isTest
  static void testCrashAndFinalizer() {
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.CrashingWorkflow',
      'CrashKey',
      null
    );

    Workflow_Instance__c inst = [
      SELECT Id, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    inst.Current_Step__c = 'WorkflowEngineTest.CrashingStep';
    update inst;

    Boolean threw = false;
    Test.startTest();
    try {
      WorkflowEngine.runStep(instanceId);
    } catch (Exception ex) {
      threw = true;
      // Simulate Transaction Finalizer rescue operation
      WorkflowEngine.handleCrash(instanceId, ex);
    }
    Test.stopTest();

    System.assert(threw, 'Should have thrown exception');

    inst = [
      SELECT Status__c, Error_Message__c, Failure_Category__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', inst.Status__c);
    System.assert(inst.Error_Message__c.contains('Simulated Crash'));
    System.assertEquals('STEP_EXCEPTION', inst.Failure_Category__c);

    Workflow_Step_Execution__c step = [
      SELECT Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      LIMIT 1
    ];
    System.assertEquals('Failed', step.Status__c);
    System.assert(step.Error_Details__c.contains('Simulated Crash'));
  }

  @isTest
  static void testSleepingWorkflow() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SleepingWorkflow',
      'SleepKey',
      null
    );
    Test.stopTest(); // Runs SleepingStep once synchronously, which requests sleep

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', inst.Status__c);
    System.assertEquals(
      'WorkflowEngineTest.SleepingStep',
      inst.Current_Step__c
    );

    Workflow_Step_Execution__c step = [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      LIMIT 1
    ];
    System.assertEquals('Pending', step.Status__c);
    System.assertEquals('resumed_state', step.Output__c);

    // Manually call runStep to simulate the timer firing and enqueuing execution
    WorkflowEngine.runStep(instanceId); // SleepingStep runs again, sees stepStateJson != null, completes.

    // Manually execute second step (AfterSleepStep) synchronously
    new WorkflowOrchestrator(instanceId).execute(null);

    inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assertEquals('"Done_resumed_state"', inst.Output__c);
  }

  @isTest
  static void testParentChildWorkflow() {
    Test.startTest();
    Id parentId = WorkflowEngine.start(
      'WorkflowEngineTest.ParentWorkflow',
      'ParentKey',
      null
    );
    Test.stopTest(); // Executes ParentStep once, starts child, and suspends parent

    Workflow_Instance__c parentInst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    System.assertEquals('Suspended', parentInst.Status__c);

    Workflow_Step_Execution__c parentStep = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :parentId
        AND Step_Name__c = 'WorkflowEngineTest.ParentStep'
      LIMIT 1
    ];
    System.assertNotEquals(null, parentStep.Output__c);
    Map<String, Object> childInfo = (Map<String, Object>) JSON.deserializeUntyped(
      parentStep.Output__c
    );
    System.assertEquals(
      'WorkflowEngineTest.ChildWorkflow',
      childInfo.get('childWorkflowName')
    );
    System.assertEquals('SubKey', childInfo.get('childCorrelationKey'));

    Workflow_Instance__c childInst = [
      SELECT
        Id,
        Status__c,
        Parent_Instance__c,
        Correlation_Key__c,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :parentId
      LIMIT 1
    ];
    System.assertEquals('SubKey', childInst.Correlation_Key__c);
    System.assertEquals('Pending', childInst.Status__c);
    System.assertEquals(
      parentId,
      childInst.Causation_Id__c,
      'Child must have parent Id as Causation_Id__c'
    );

    WorkflowEngine.WorkflowStatus status = WorkflowEngine.getStatus(
      childInst.Id
    );
    System.assertEquals(
      parentId,
      status.causationId,
      'WorkflowStatus must return parent Id as causationId'
    );

    // Execute child workflow synchronously
    new WorkflowOrchestrator(childInst.Id).execute(null); // ChildStep completes, triggers child completion event

    // Deliver Platform Event (ChildCompleted) to parent
    Test.getEventBus().deliver(); // Parent becomes Running, enqueues orchestrator

    // Manually run orchestrator for parent to consume child output signal and complete
    new WorkflowOrchestrator(parentId).execute(null);

    parentInst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    System.assertEquals('Completed', parentInst.Status__c);
    System.assertEquals(
      '"ParentResult_ChildInput_ChildDone"',
      parentInst.Output__c
    );
  }

  @isTest
  static void testRetryWorkflow() {
    // Start the workflow that will fail
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.FailingWorkflow',
      'FailingKey',
      null
    );

    // Execute failing step manually. It will request a retry and hit maxAttempts = 1, resulting in Failure.
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c inst = [
      SELECT Status__c, Error_Message__c, Current_Step__c, Failure_Category__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', inst.Status__c, 'Should be failed');
    System.assertNotEquals(null, inst.Error_Message__c);
    System.assertEquals('RETRIES_EXHAUSTED', inst.Failure_Category__c);

    Workflow_Step_Execution__c stepExec = [
      SELECT Status__c, Retry_Count__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = :inst.Current_Step__c
      LIMIT 1
    ];
    System.assertEquals('Failed', stepExec.Status__c);

    // Now, trigger the retry! Change mock state to succeed
    WorkflowEngineTest.shouldSucceedOnFailingStep = true;

    Test.startTest();
    WorkflowEngine.retryWorkflow(instanceId);
    // This will run the Orchestrator synchronously in Test context
    Test.stopTest();

    Workflow_Instance__c retriedInst = [
      SELECT Status__c, Error_Message__c, Failure_Category__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'Completed',
      retriedInst.Status__c,
      'Should complete successfully now'
    );
    System.assertEquals(null, retriedInst.Error_Message__c);
    System.assertEquals(null, retriedInst.Failure_Category__c);
  }

  @isTest
  static void testWorkflowTimeout() {
    // Start a workflow instance
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.TimeoutWorkflow',
      'TimeoutKey',
      null
    );

    // Assert a step execution record is created when started
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    // In the test context, because it ran manually, it completed successfully (since execute is synchronous).
    // Let's now simulate a timeout by changing status back to Running and manually executing the timeout job!
    inst.Status__c = 'Running';
    inst.Current_Step__c = 'WorkflowEngineTest.TimeoutStep';
    update inst;

    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.TimeoutStep'
      LIMIT 1
    ];
    System.assert(!stepExecs.isEmpty());
    Workflow_Step_Execution__c stepExec = stepExecs[0];
    stepExec.Status__c = 'Running';
    stepExec.Timeout_At__c = DateTime.now().addSeconds(-10);
    update as system stepExec;

    Test.startTest();
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    // Check if both records are marked Failed
    Workflow_Instance__c timedOutInst = [
      SELECT Status__c, Error_Message__c, Failure_Category__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', timedOutInst.Status__c);
    System.assertEquals(
      'Failed at step WorkflowEngineTest.TimeoutStep: Step execution timed out.',
      timedOutInst.Error_Message__c
    );
    System.assertEquals('TIMEOUT', timedOutInst.Failure_Category__c);

    Workflow_Step_Execution__c timedOutStep = [
      SELECT Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepExec.Id
    ];
    System.assertEquals('Failed', timedOutStep.Status__c);
    System.assertEquals(
      'Step execution timed out.',
      timedOutStep.Error_Details__c
    );
  }

  @isTest
  static void testWorkflowApproval() {
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.ApprovalWorkflow',
      'ApprovalKey',
      null
    );

    // Execute initial step. It will return waitForApproval and suspend.
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', inst.Status__c);
    System.assertEquals(
      'WorkflowEngineTest.ApprovalStep',
      inst.Current_Step__c
    );

    Workflow_Step_Execution__c stepExec = [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.ApprovalStep'
      LIMIT 1
    ];
    System.assertEquals('Pending', stepExec.Status__c);
    System.assert(stepExec.Output__c.contains('"waitingForApproval":true'));
    System.assert(
      stepExec.Output__c.contains('"approvalKey":"ExpenseApproval"')
    );
    System.assert(stepExec.Output__c.contains('"approvalRole":"Manager"'));

    // Signal the approval
    Test.startTest();
    WorkflowEngine.signal(
      'ApprovalKey',
      'Approve:ExpenseApproval',
      '{"approved":true,"comments":"Approved","approver":"test@example.com"}'
    );
    Test.stopTest();

    // Platform Event delivery wakes up the parent orchestrator synchronously in test
    Test.getEventBus().deliver();

    // Run orchestrator to consume signal and complete step
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c completedInst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', completedInst.Status__c);
    System.assertEquals('"Approved"', completedInst.Output__c);
  }

  public class ParallelWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.SplitStep',
        'WorkflowEngineTest.ParallelStep1',
        'WorkflowEngineTest.ParallelStep2',
        'WorkflowEngineTest.JoinStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.SplitStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineTest.SplitStep') {
        return 'WorkflowEngineTest.JoinStep';
      }
      return null;
    }
  }

  public class SplitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowEngineTest.ParallelStep1',
          'WorkflowEngineTest.ParallelStep2'
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

  public class JoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Map<String, Object> inputMap = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.inputJson
      );
      String out1 = (String) inputMap.get('WorkflowEngineTest.ParallelStep1');
      String out2 = (String) inputMap.get('WorkflowEngineTest.ParallelStep2');
      return StepResult.complete(null, out1 + '+' + out2);
    }
  }

  @isTest
  static void testParallelExecution() {
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.ParallelWorkflow',
      'ParallelKey',
      null
    );

    // Run initial SplitStep
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Running', inst.Status__c);
    System.assertEquals(
      'WorkflowEngineTest.ParallelStep1,WorkflowEngineTest.ParallelStep2',
      inst.Current_Step__c
    );

    // Run ParallelStep1 manually
    new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.ParallelStep1')
      .execute(null);

    // Verify workflow is still running and waiting for ParallelStep2
    inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Running', inst.Status__c);

    // Run ParallelStep2 manually
    new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.ParallelStep2')
      .execute(null);

    // Run JoinStep manually
    new WorkflowOrchestrator(instanceId).execute(null);

    // Verify JoinStep has executed and completed the workflow
    inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assertEquals(
      '"BranchInput_P1Done+BranchInput_P2Done"',
      inst.Output__c
    );
  }

  public class CompensatableHappyStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, 'Compensated');
    }
  }

  public static Boolean compensationShouldFail = false;

  public class CompensatableFailingStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    public StepResult compensate(StepContext ctx) {
      if (compensationShouldFail) {
        RetryPolicy policy = new RetryPolicy();
        policy.maximumAttempts = 2;
        policy.initialIntervalSeconds = 1;
        policy.backoffCoefficient = 2.0;
        return StepResult.retry(policy);
      }
      return StepResult.complete(null, 'CompensatedFailing');
    }
  }

  public class NonCompensatableStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
  }

  // Captures the previousRunAt the engine exposes inside compensate(), so a test
  // can assert the forward-context continuation metadata is threaded into the
  // compensation context too (parity), not silently null.
  public static Datetime capturedCompensatePreviousRunAt = null;
  public static Boolean compensatePreviousRunAtCaptured = false;

  public class PreviousRunAtCompensatableStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    public StepResult compensate(StepContext ctx) {
      capturedCompensatePreviousRunAt = ctx.previousRunAt;
      compensatePreviousRunAtCaptured = true;
      return StepResult.complete(null, 'Compensated');
    }
  }

  @isTest
  static void testCompensationFlow() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Compensating',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{
          'WorkflowEngineTest.NonCompensatableStep',
          'WorkflowEngineTest.CompensatableHappyStep'
        }
      ),
      Input__c = '{"test": true}'
    );
    insert inst;

    Workflow_Step_Execution__c origExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep',
      Status__c = 'Completed',
      Input__c = '{"stepInput": 1}',
      Output__c = '{"stepOutput": 2}'
    );
    insert origExec;

    Test.startTest();
    WorkflowEngine.runStep(inst.Id, null); // Runs CompensatableHappyStep
    WorkflowEngine.runStep(inst.Id, null); // Runs NonCompensatableStep (skipped)
    WorkflowEngine.runStep(inst.Id, null); // Stack empty -> transition status to Compensated
    Test.stopTest();

    Workflow_Instance__c completedInst = [
      SELECT Status__c, Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('Compensated', completedInst.Status__c);

    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Step_Name__c, Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :inst.Id
      ORDER BY CreatedDate ASC, Id ASC
    ];
    System.assertEquals(3, stepExecs.size());
    System.assertEquals(
      'WorkflowEngineTest.CompensatableHappyStep_Compensate',
      stepExecs[1].Step_Name__c
    );
    System.assertEquals('Compensated', stepExecs[1].Status__c);
    System.assertEquals('"Compensated"', stepExecs[1].Output__c);

    System.assertEquals(
      'WorkflowEngineTest.NonCompensatableStep_Compensate',
      stepExecs[2].Step_Name__c
    );
    System.assertEquals('Compensated', stepExecs[2].Status__c);
  }

  // Parity: the continuation cursor available to execute() must also be visible
  // to compensate(), so a compensation never sees a surprising null where the
  // forward path saw a value. (It must not be USED to scope what to undo -- that
  // comes from the recorded step input/output -- but it must be present.)
  @isTest
  static void testCompensationContextCarriesPreviousRunAt() {
    WorkflowEngine.disableQueueableInTest = true;
    capturedCompensatePreviousRunAt = null;
    compensatePreviousRunAtCaptured = false;

    Datetime priorRun = Datetime.newInstanceGmt(2026, 1, 2, 3, 4, 5);
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Compensating',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.PreviousRunAtCompensatableStep' }
      ),
      Input__c = '{"test": true}',
      Previous_Run_At__c = priorRun
    );
    insert inst;

    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.PreviousRunAtCompensatableStep',
      Status__c = 'Completed',
      Input__c = '{"stepInput": 1}',
      Output__c = '{"stepOutput": 2}'
    );

    Test.startTest();
    WorkflowEngine.runStep(inst.Id, null); // runs *_Compensate
    Test.stopTest();

    System.assert(
      compensatePreviousRunAtCaptured,
      'compensate() should have been invoked'
    );
    System.assertEquals(
      priorRun,
      capturedCompensatePreviousRunAt,
      'compensate() must observe the instance Previous_Run_At__c, not null'
    );
  }

  // A compensation that reads a signal then makes a synchronous, payload-driven
  // callout. Also CalloutStep + TimeoutConfigurable: the engine must defer the
  // pre-compensation timeout DML so the callout in compensate() stays legal.
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

  public class CompOkMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(204);
      res.setBody('');
      return res;
    }
  }

  @isTest
  static void testCalloutCompensationWithTimeoutDoesNotHitUncommittedWork() {
    Test.setMock(HttpCalloutMock.class, new CompOkMock());
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Compensating',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CalloutCompensationStep' }
      ),
      Input__c = '{"test": true}'
    );
    insert inst;

    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.CalloutCompensationStep',
      Status__c = 'Completed',
      Output__c = '{}'
    );

    Test.startTest();
    WorkflowEngine.runStep(inst.Id, null); // runs CalloutCompensationStep_Compensate
    Test.stopTest();

    Workflow_Step_Execution__c compExec = [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :inst.Id
        AND Step_Name__c = 'WorkflowEngineTest.CalloutCompensationStep_Compensate'
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    System.assertEquals(
      'Compensated',
      compExec.Status__c,
      'A CalloutStep+TimeoutConfigurable compensation must complete its synchronous callout without an uncommitted-work exception'
    );
    System.assert(
      compExec.Output__c != null && compExec.Output__c.contains('204'),
      'compensation callout response should be recorded, got: ' +
      compExec.Output__c
    );
  }

  // #793: a CalloutStep compensation that SUSPENDED waiting on a signal and is
  // then resumed must still make its payload-driven callout. On resume runStep
  // re-asserts the compensating status from Suspended -> Compensating; committing
  // that DML before compensate() (as it used to) would make the callout illegal
  // with an uncommitted-work exception. The engine now defers the status DML for a
  // CalloutStep compensation, so the synchronous callout stays legal.
  @isTest
  static void testSignalResumedCalloutCompensationDefersStatusDml() {
    Test.setMock(HttpCalloutMock.class, new CompOkMock());
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CalloutCompensationStep' }
      ),
      Input__c = '{"test": true}'
    );
    insert inst;

    // The forward step completed (so it is on the stack), then the compensation
    // step that suspended waiting for the signal: its '_Compensate' execution is
    // the latest row and still Pending, which is how runStep detects that this
    // Suspended instance is actually mid-rollback.
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.CalloutCompensationStep',
      Status__c = 'Completed',
      Output__c = '{}'
    );
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.CalloutCompensationStep_Compensate',
      Status__c = 'Pending'
    );

    // The signal that resumes the suspended compensation step.
    insert new Workflow_Signal__c(
      Workflow_Instance__c = inst.Id,
      Signal_Name__c = 'CompSig',
      Payload__c = 'go',
      Status__c = 'Received'
    );

    Test.startTest();
    WorkflowEngine.runStep(inst.Id, null); // resumes CalloutCompensationStep_Compensate
    Test.stopTest();

    Workflow_Step_Execution__c compExec = [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :inst.Id
        AND Step_Name__c = 'WorkflowEngineTest.CalloutCompensationStep_Compensate'
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    System.assertEquals(
      'Compensated',
      compExec.Status__c,
      'A signal-resumed CalloutStep compensation must complete its callout; the Suspended->Compensating status DML must be deferred past compensate()'
    );
    System.assert(
      compExec.Output__c != null && compExec.Output__c.contains('204'),
      'compensation callout response should be recorded, got: ' +
      compExec.Output__c
    );
  }

  // #3229: a non-cancel signal that arrives while the instance is mid-rollback
  // (Compensating) must be stored for the compensation step to read, not rejected
  // as "no active workflow" the way the lookup used to do.
  @isTest
  static void testSignalStoredWhileCompensating() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Compensating',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CalloutCompensationStep' }
      ),
      Input__c = '{}'
    );
    insert inst;

    // No startTest/stopTest: enqueueResume queues an orchestrator that does not
    // execute during the test, so this isolates signal()'s store-vs-reject choice.
    WorkflowEngine.signal(inst.Id, 'CompSig', '{"ok":true}');

    List<Workflow_Signal__c> sigs = [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :inst.Id AND Signal_Name__c = 'CompSig'
    ];
    System.assertEquals(
      1,
      sigs.size(),
      'A signal sent while Compensating must be stored for the compensation step, not rejected as no-active-workflow'
    );
  }

  // A normal FORWARD step whose class name happens to end in '_Compensate'. It
  // suspends until signaled, exercising the signal-resumed (Suspended->Running)
  // path where the compensation-suffix heuristic must not misfire.
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
      return new List<String>{ 'WorkflowEngineTest.Stage_Compensate' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.Stage_Compensate';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null; // terminal
    }
  }

  @isTest
  static void testForwardStepNamedCompensateNotMisroutedAsCompensation() {
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SuffixForwardWorkflow',
      'SuffixKey',
      null
    );
    // First run: forward step suspends waiting for 'Go'. It must NOT be treated
    // as a compensation despite its '_Compensate' suffix (empty stack).
    new WorkflowOrchestrator(instanceId).execute(null);
    WorkflowEngine.signal('SuffixKey', 'Go', '{}');
    // Resume: signal() flipped the instance to Running. The suffix heuristic must
    // still route forward (no matching compensation stack), not to compensation.
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c inst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'Completed',
      inst.Status__c,
      'A forward step named *_Compensate with no compensation stack must resume forward, not be marked Compensated'
    );
  }

  // A compensation that waits for a signal before rolling back.
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

  @isTest
  static void testSignalDrivenCompensationResumes() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Compensating',
      Correlation_Key__c = 'CompKey',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.SignalWaitCompensationStep' }
      ),
      Input__c = '{"test": true}'
    );
    insert inst;
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.SignalWaitCompensationStep',
      Status__c = 'Completed',
      Output__c = '{}'
    );

    // First run: compensate() suspends waiting for the Rollback signal.
    WorkflowEngine.runStep(inst.Id, null);
    System.assertEquals(
      'Suspended',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id]
      .Status__c,
      'Compensation should suspend until the signal arrives'
    );

    // Signal arrives: signal() flips the instance to Running and enqueues a resume.
    WorkflowEngine.signal('CompKey', 'Rollback', '{}');

    // Resume run: must route back into compensation (not the forward path) and finish.
    WorkflowEngine.runStep(inst.Id, null);

    System.assertEquals(
      'Compensated',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id]
      .Status__c,
      'A signal-driven compensation must resume and complete, not stay stuck Running'
    );
    Workflow_Step_Execution__c compExec = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :inst.Id
        AND Step_Name__c = 'WorkflowEngineTest.SignalWaitCompensationStep_Compensate'
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    System.assertEquals('Compensated', compExec.Status__c);
  }

  @isTest
  static void testCompensationFailureAndRetry() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Compensating',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableFailingStep' }
      ),
      Input__c = '{"test": true}'
    );
    insert inst;

    WorkflowEngineTest.compensationShouldFail = true;

    Test.startTest();
    // First execution - should result in RETRY and schedule a retry job
    WorkflowEngine.runStep(inst.Id, null);

    // Find step execution and manually simulate retry attempts
    List<Workflow_Step_Execution__c> execs = [
      SELECT Id, Status__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :inst.Id
        AND Step_Name__c = 'WorkflowEngineTest.CompensatableFailingStep_Compensate'
    ];
    System.assertEquals(1, execs.size());
    System.assertEquals('Retrying', execs[0].Status__c);
    System.assertEquals(1, execs[0].Retry_Count__c);

    // Run second time - should exceed maximum attempts (maximumAttempts = 2) and fail
    WorkflowEngine.runStep(inst.Id, null);
    Test.stopTest();

    Workflow_Instance__c failedInst = [
      SELECT
        Status__c,
        Error_Message__c,
        Sleep_Until__c,
        Async_Job_Id__c,
        Failure_Category__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    // Exhausting the RetryPolicy budget yields the recoverable "rollback incomplete"
    // condition, NOT a generic terminal Failed.
    System.assertEquals('CompensationFailed', failedInst.Status__c);
    System.assert(
      failedInst.Error_Message__c.contains('failed after max retries')
    );
    System.assertEquals('COMPENSATION_FAILED', failedInst.Failure_Category__c);
    // The elapsed retry deadline must be cleared so the watchdog cannot prematurely
    // wake a remaining SUSPEND/approval gate once the rollback is resumed.
    System.assertEquals(null, failedInst.Sleep_Until__c);
    System.assertEquals(null, failedInst.Async_Job_Id__c);

    Workflow_Step_Execution__c failedExec = [
      SELECT Status__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :execs[0].Id
    ];
    System.assertEquals('Failed', failedExec.Status__c);
    System.assertEquals(2, failedExec.Retry_Count__c);

    // Now resume the stalled rollback from exactly the failed compensation point.
    WorkflowEngineTest.compensationShouldFail = false;

    WorkflowEngine.resumeCompensation(inst.Id);
    WorkflowEngine.runStep(inst.Id, null); // Runs the fresh compensation attempt (completes)
    WorkflowEngine.runStep(inst.Id, null); // Stack empty -> transition status to Compensated

    Workflow_Instance__c retriedInst = [
      SELECT Status__c, Error_Message__c, Failure_Category__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('Compensated', retriedInst.Status__c);
    System.assertEquals(null, retriedInst.Failure_Category__c);

    // Append-only: the original failed attempt's record is preserved untouched.
    Workflow_Step_Execution__c preservedFailedExec = [
      SELECT Status__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :execs[0].Id
    ];
    System.assertEquals('Failed', preservedFailedExec.Status__c);
    System.assertEquals(2, preservedFailedExec.Retry_Count__c);

    // A fresh, successful compensation attempt was appended for the same step.
    List<Workflow_Step_Execution__c> compAttempts = [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :inst.Id
        AND Step_Name__c = 'WorkflowEngineTest.CompensatableFailingStep_Compensate'
      ORDER BY CreatedDate ASC, Id ASC
    ];
    System.assertEquals(
      2,
      compAttempts.size(),
      'Failed attempt preserved alongside the successful resume attempt'
    );
    Workflow_Step_Execution__c successfulAttempt = compAttempts[
      compAttempts.size() - 1
    ];
    System.assertEquals('Compensated', successfulAttempt.Status__c);
    System.assertEquals('"CompensatedFailing"', successfulAttempt.Output__c);
  }

  @isTest
  static void testCancelWorkflowActiveNoCompensations() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SuspendingWorkflow',
      'CancelKey1',
      null
    );
    Test.stopTest(); // Executes initial step and suspends

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', inst.Status__c);
    System.assertEquals(
      'WorkflowEngineTest.SuspendingStep',
      inst.Current_Step__c
    );

    WorkflowEngine.cancel(instanceId, false);

    inst = [
      SELECT Status__c, Current_Step__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Cancelled', inst.Status__c);
    System.assertEquals('Cancelled by user.', inst.Error_Message__c);

    List<Workflow_Step_Execution__c> steps = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
    ];
    System.assert(!steps.isEmpty());
    for (Workflow_Step_Execution__c s : steps) {
      System.assertEquals('Cancelled', s.Status__c);
    }
  }

  @isTest
  static void testCancelWorkflowActiveWithCompensations() {
    WorkflowEngine.disableQueueableInTest = true;

    // Use SagaWorkflowExample for saga stack building
    Id instanceId = WorkflowEngine.start(
      'SagaWorkflowExample.SagaWorkflow',
      'CancelKey2',
      null
    );

    // Run first step (ChargeCreditCardStep) to push to stack
    WorkflowEngine.runStep(instanceId, null);

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c, Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'SagaWorkflowExample.ProvisionServiceStep',
      inst.Current_Step__c
    );
    System.assert(
      inst.Compensation_Stack__c.contains(
        'SagaWorkflowExample.ChargeCreditCardStep'
      )
    );

    Test.startTest();
    // Cancel with compensations
    WorkflowEngine.cancel(instanceId, true);

    // Assert status is now Cancelling
    inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Cancelling', inst.Status__c);

    // Execute the compensation step (pops ChargeCreditCardStep)
    WorkflowEngine.runStep(instanceId, null);

    // Finish compensation loop
    WorkflowEngine.runStep(instanceId, null);
    Test.stopTest();

    inst = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId];
    System.assertEquals('Cancelled', inst.Status__c);
  }

  @isTest
  static void testCancelWorkflowSleeping() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SleepingWorkflow',
      'CancelKey3',
      null
    );
    Test.stopTest(); // Runs the queueable and puts the workflow to Sleep (Suspended)

    Workflow_Instance__c inst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', inst.Status__c);

    // Cancel sleeping workflow
    WorkflowEngine.cancel(instanceId, false);

    inst = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId];
    System.assertEquals('Cancelled', inst.Status__c);
  }

  @isTest
  static void testCancelWorkflowParentChild() {
    WorkflowEngine.disableQueueableInTest = true;
    Id parentId = WorkflowEngine.start(
      'WorkflowEngineTest.ParentWorkflow',
      'CancelParent',
      null
    );

    // Execute parent, which starts child and suspends
    WorkflowEngine.runStep(parentId, null);

    Workflow_Instance__c childInst = [
      SELECT Id, Status__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :parentId
      LIMIT 1
    ];
    System.assertEquals('Pending', childInst.Status__c);

    Test.startTest();
    // Cancel parent, should recursively cancel child
    WorkflowEngine.cancel(parentId, false);
    Test.stopTest();

    Workflow_Instance__c parent = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    childInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :childInst.Id
    ];

    System.assertEquals('Cancelled', parent.Status__c);
    System.assertEquals('Cancelled', childInst.Status__c);
  }

  @isTest
  static void testCancelWorkflowViaSignal() {
    WorkflowEngine.disableQueueableInTest = true;
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'CancelSignalKey',
      null
    );

    Test.startTest();
    // Signal cancellation
    WorkflowEngine.signal(
      'CancelSignalKey',
      'Cancel',
      '{"runCompensations": false}'
    );
    Test.stopTest();

    Workflow_Instance__c inst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Cancelled', inst.Status__c);
  }

  public class MockQueueable implements Queueable {
    public void execute(QueueableContext ctx) {
    }
  }

  @isTest
  static void testStepContextShouldYield() {
    StepContext ctx = new StepContext(
      null,
      'TestWorkflow',
      'TestStep',
      null,
      null,
      null,
      null
    );
    // Under normal test conditions, limit usage is low, so shouldYield should return false
    System.assertEquals(false, ctx.shouldYield());
  }

  @isTest
  static void testTriggerQueueableThrottling() {
    // Create 55 distinct workflow instances
    List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < 55; i++) {
      instances.add(
        new Workflow_Instance__c(
          Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
          Status__c = 'Running',
          Current_Step__c = 'WorkflowEngineTest.HappyStep1'
        )
      );
    }
    insert instances;

    List<Workflow_Event__e> events = new List<Workflow_Event__e>();
    for (Integer i = 0; i < 55; i++) {
      events.add(
        new Workflow_Event__e(
          Workflow_Instance_Id__c = instances[i].Id,
          Event_Type__c = 'RUN_STEP',
          Payload__c = 'WorkflowEngineTest.HappyStep1'
        )
      );
    }

    Test.startTest();
    List<Database.SaveResult> srs = EventBus.publish(events);
    for (Database.SaveResult sr : srs) {
      System.assert(sr.isSuccess());
    }
    Test.stopTest();
  }

  @isTest
  static void testCorrelationKeyValidation() {
    String longKey = 'A'.repeat(201);
    try {
      WorkflowEngine.start('WorkflowEngineTest.HappyWorkflow', longKey, null);
      System.assert(
        false,
        'Should have thrown exception for long correlation key'
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      System.assert(
        ex.getMessage()
          .contains('Correlation key length cannot exceed 200 characters')
      );
    }

    try {
      WorkflowEngine.start('WorkflowEngineTest.HappyWorkflow', null, null);
      System.assert(
        false,
        'Should have thrown exception for null correlation key'
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      System.assert(ex.getMessage().contains('Correlation key is required'));
    }

    try {
      WorkflowEngine.start('WorkflowEngineTest.HappyWorkflow', '', null);
      System.assert(
        false,
        'Should have thrown exception for empty correlation key'
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      System.assert(ex.getMessage().contains('Correlation key is required'));
    }
  }

  @isTest
  static void testLargePayloadFileOffloading() {
    String largeInput = 'A'.repeat(110000);

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.LargePayloadWorkflow',
      'LargePayloadKey',
      largeInput
    );
    Test.stopTest(); // Executes first step LargePayloadStep

    // Query the instance in database
    Workflow_Instance__c inst = [
      SELECT Input__c, Output__c, Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);

    // Assert that the input is stored as attachment marker
    System.assert(
      inst.Input__c.startsWith('{"$attachmentId":'),
      'Input__c should be stored as attachment marker but got: ' + inst.Input__c
    );
    System.assert(
      inst.Output__c.startsWith('{"$attachmentId":'),
      'Output__c should be stored as attachment marker but got: ' +
      inst.Output__c
    );

    // Assert ContentVersion records exist
    List<ContentDocumentLink> links = [
      SELECT ContentDocumentId
      FROM ContentDocumentLink
      WHERE LinkedEntityId = :instanceId
    ];
    System.assertEquals(
      3,
      links.size(),
      'Should have created 3 file links (one for Input, one for Step Output, and one for Final Output)'
    );

    // Fetch details via dashboard controller and verify transparent resolution
    Map<String, Object> details = WorkflowDashboardController.getInstanceDetails(
      instanceId
    );
    Workflow_Instance__c detailedInst = (Workflow_Instance__c) details.get(
      'instance'
    );
    System.assertEquals(
      50015,
      detailedInst.Input__c.length(),
      'Input should resolve to truncated length due to dashboard cap'
    );
    System.assert(
      detailedInst.Input__c.endsWith('... (truncated)'),
      'Input should be truncated'
    );
    System.assertEquals(
      50015,
      detailedInst.Output__c.length(),
      'Output should resolve to truncated length due to dashboard cap'
    );
    System.assert(
      detailedInst.Output__c.endsWith('... (truncated)'),
      'Output should be truncated'
    );

    // Run Cleanup/Purge step on this instance
    CleanupWorkflow.PurgeOldInstancesStep purgeStep = new CleanupWorkflow.PurgeOldInstancesStep();

    StepContext purgeCtx = new StepContext(
      null,
      'CleanupWorkflow',
      'CleanupWorkflow.PurgeOldInstancesStep',
      null,
      null,
      null,
      '{"retentionDays":0,"batchSize":100}',
      1
    );

    // Execute purge
    StepResult purgeResult = purgeStep.execute(purgeCtx);
    System.assertEquals(StepResult.ActionType.COMPLETE, purgeResult.action);

    // Verify ContentDocument links and files are deleted
    List<ContentDocumentLink> remainingLinks = [
      SELECT ContentDocumentId
      FROM ContentDocumentLink
      WHERE LinkedEntityId = :instanceId
    ];
    System.assertEquals(
      0,
      remainingLinks.size(),
      'All links should be deleted'
    );

    List<Workflow_Instance__c> remainingInstances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      0,
      remainingInstances.size(),
      'Workflow instance should be deleted'
    );
  }

  public class DaemonWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.IncrementCounterStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.IncrementCounterStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class PreviousRunAtWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.PreviousRunAtCaptureStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.PreviousRunAtCaptureStep';
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

  @isTest
  static void testContinueAsNew() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.DaemonWorkflow',
      'DaemonKey',
      0
    );
    new WorkflowOrchestrator(instanceId).execute(null); // Runs the first execution run (counter 0 -> continueAsNew 1)

    // Manual triggers for execution runs 2 and 3

    // Query Run 1
    Workflow_Instance__c run1 = [
      SELECT Status__c, Correlation_Key__c, Input__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('ContinuedAsNew', run1.Status__c);
    System.assertEquals('DaemonKey', run1.Correlation_Key__c);

    // Find and run Run 2
    Workflow_Instance__c run2 = [
      SELECT
        Id,
        Status__c,
        Correlation_Key__c,
        Input__c,
        Previous_Instance__c,
        Previous_Run_At__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :run1.Id
    ];
    System.assertEquals('Pending', run2.Status__c);
    System.assertEquals('DaemonKey_run2', run2.Correlation_Key__c);
    System.assertEquals('1', run2.Input__c);
    System.assertNotEquals(
      null,
      run2.Previous_Run_At__c,
      'Successor instance must carry the predecessor run timestamp'
    );

    // Execute Run 2 (counter 1 -> continueAsNew 2)
    new WorkflowOrchestrator(run2.Id).execute(null);

    run2 = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :run2.Id];
    System.assertEquals('ContinuedAsNew', run2.Status__c);

    // Find and run Run 3
    Workflow_Instance__c run3 = [
      SELECT Id, Status__c, Correlation_Key__c, Input__c, Previous_Instance__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :run2.Id
    ];
    System.assertEquals('Pending', run3.Status__c);
    System.assertEquals('DaemonKey_run3', run3.Correlation_Key__c);
    System.assertEquals('2', run3.Input__c);

    // Execute Run 3 (counter 2 -> complete 3)
    new WorkflowOrchestrator(run3.Id).execute(null);

    run3 = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :run3.Id
    ];
    System.assertEquals('Completed', run3.Status__c);
    System.assertEquals('3', run3.Output__c);
  }

  @isTest
  static void testStepNameValidation() {
    WorkflowEngine.disableQueueableInTest = true;
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'ValidationKey',
      null
    );

    // Let's run a step but supply an invalid step name
    try {
      WorkflowEngine.runStep(instanceId, 'InvalidStepName');
      System.assert(false, 'Should have failed step validation');
    } catch (WorkflowEngine.WorkflowException ex) {
      System.assert(
        ex.getMessage().contains('is not the active/expected step'),
        'Error should be about invalid step: ' + ex.getMessage()
      );
    }
  }

  @isTest
  static void testParallelRecovery() {
    WorkflowEngine.disableQueueableInTest = true;
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.ParallelWorkflow',
      'ParallelRecoveryKey',
      null
    );

    // Execute initial split step to spawn parallel branches
    WorkflowEngine.runStep(instanceId, null);

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'WorkflowEngineTest.ParallelStep1,WorkflowEngineTest.ParallelStep2',
      inst.Current_Step__c
    );

    // Make ParallelStep2 succeed
    WorkflowEngine.runStep(instanceId, 'WorkflowEngineTest.ParallelStep2');

    // Verify ParallelStep2 is Completed
    Workflow_Step_Execution__c step2Exec = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.ParallelStep2'
      LIMIT 1
    ];
    System.assertEquals('Completed', step2Exec.Status__c);

    // Now simulate a crash on ParallelStep1
    WorkflowEngine.handleCrash(
      instanceId,
      'WorkflowEngineTest.ParallelStep1',
      new WorkflowEngine.WorkflowException('Parallel step 1 crashed')
    );

    // Verify instance and ParallelStep1 are Failed
    inst = [
      SELECT Status__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', inst.Status__c);
    System.assert(inst.Error_Message__c.contains('ParallelStep1'));

    Workflow_Step_Execution__c step1Exec = [
      SELECT Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.ParallelStep1'
      LIMIT 1
    ];
    System.assertEquals('Failed', step1Exec.Status__c);
    System.assert(
      step1Exec.Error_Details__c.contains('Parallel step 1 crashed')
    );

    // Retry the workflow - should only reset ParallelStep1 and spawn orchestrator for it
    WorkflowEngine.retryWorkflow(instanceId);

    step1Exec = [
      SELECT Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.ParallelStep1'
      LIMIT 1
    ];
    System.assertEquals('Pending', step1Exec.Status__c);
    System.assertEquals(null, step1Exec.Error_Details__c);

    // ParallelStep2 should remain Completed
    step2Exec = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.ParallelStep2'
      LIMIT 1
    ];
    System.assertEquals('Completed', step2Exec.Status__c);
  }

  @isTest
  static void testCorrelationKeyReuse() {
    WorkflowEngine.disableQueueableInTest = true;
    // Disable the dedup window so a completed key may be reused (legacy reuse)
    WorkflowEngine.dedupWindowMinutes = 0;

    // Run first instance to completion
    Id instanceId1 = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'SharedKey',
      null
    );
    WorkflowEngine.runStep(instanceId1, null);
    WorkflowEngine.runStep(instanceId1, null);

    Workflow_Instance__c inst1 = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId1
    ];
    System.assertEquals('Completed', inst1.Status__c);

    // Start a second instance with the same correlation key - should create a
    // new instance because the first one is terminal and the window is disabled.
    Test.startTest();
    Id instanceId2 = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'SharedKey',
      null
    );
    Test.stopTest();

    System.assertNotEquals(
      instanceId1,
      instanceId2,
      'With the dedup window disabled, a terminal key starts a new instance'
    );
    Workflow_Instance__c inst2 = [
      SELECT Status__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId2
    ];
    System.assertEquals('SharedKey', inst2.Correlation_Key__c);
  }

  @isTest
  static void testDirectCalloutStep() {
    Test.setMock(HttpCalloutMock.class, new MockCalloutResponse());

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.CalloutWorkflow',
      'CalloutKey',
      null
    );
    Test.stopTest();

    Workflow_Instance__c inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assertEquals(
      '{"status":"success"}',
      (String) JSON.deserialize(
        WorkflowEngine.resolvePayload(inst.Output__c),
        String.class
      )
    );
  }

  @isTest
  static void testWatchdogLifecycle() {
    WorkflowEngine.disableQueueableInTest = true;

    // TimeoutStep has timeout of 30 seconds
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.TimeoutWorkflow',
      'TimeoutWatchdogKey',
      null
    );

    // Verify watchdog was scheduled in DB
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Timeout_At__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.TimeoutStep'
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    System.assertEquals(1, stepExecs.size());
    System.assertNotEquals(
      null,
      stepExecs[0].Timeout_At__c,
      'Watchdog timeout should be set on step execution'
    );

    // Verify watchdog was scheduled in CronTriggers
    String cleanStepName = 'WorkflowEngineTest_TimeoutStep';
    String jobName = 'Timeout_' + instanceId + '_' + cleanStepName;
    List<CronTrigger> triggers = [
      SELECT Id, State
      FROM CronTrigger
      WHERE CronJobDetail.Name = :jobName
    ];
    System.assertEquals(
      1,
      triggers.size(),
      'A dynamic CronTrigger should be scheduled'
    );

    // Execute the step. It should clear the timeout in DB.
    Test.startTest();
    WorkflowEngine.runStep(instanceId, null);
    Test.stopTest();

    stepExecs = [
      SELECT Timeout_At__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.TimeoutStep'
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    System.assertEquals(1, stepExecs.size());
    System.assertEquals('Completed', stepExecs[0].Status__c);
    System.assertEquals(
      null,
      stepExecs[0].Timeout_At__c,
      'Watchdog timeout should be cleared upon successful step completion'
    );

    // Verify watchdog CronTrigger was canceled/aborted
    triggers = [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name = :jobName
    ];
    System.assertEquals(
      0,
      triggers.size(),
      'Watchdog CronTrigger should be aborted upon successful step completion'
    );
  }

  @isTest
  static void testLargeParallelOutputJoin() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.LargeParallelWorkflow',
      'LargeParallelKey',
      null
    );

    // Run SplitStep
    WorkflowEngine.runStep(instanceId, null);

    // Run LargeOutputStep and ParallelStep2
    WorkflowEngine.runStep(instanceId, 'WorkflowEngineTest.LargeOutputStep');
    WorkflowEngine.runStep(instanceId, 'WorkflowEngineTest.ParallelStep2');

    Workflow_Instance__c instBefore = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.debug(
      '--- TEST BEFORE JOIN: Status=' +
        instBefore.Status__c +
        ', CurrentStep=' +
        instBefore.Current_Step__c
    );

    List<Workflow_Step_Execution__c> stepsBefore = [
      SELECT Step_Name__c, Status__c, Input__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
    ];
    for (Workflow_Step_Execution__c s : stepsBefore) {
      System.debug(
        '--- STEP BEFORE JOIN: Name=' +
          s.Step_Name__c +
          ', Status=' +
          s.Status__c +
          ', InputLength=' +
          (s.Input__c != null ? s.Input__c.length() : 0)
      );
    }

    // Run JoinStep manually
    try {
      new WorkflowOrchestrator(instanceId).execute(null);
    } catch (Exception ex) {
      System.debug(
        '--- JOIN EXECUTION CRASHED: ' +
          ex.getMessage() +
          '\n' +
          ex.getStackTraceString()
      );
      throw ex;
    }

    Workflow_Instance__c instAfter = [
      SELECT Status__c, Current_Step__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.debug(
      '--- TEST AFTER JOIN: Status=' +
        instAfter.Status__c +
        ', CurrentStep=' +
        instAfter.Current_Step__c +
        ', Error=' +
        instAfter.Error_Message__c
    );

    List<Workflow_Step_Execution__c> stepsAfter = [
      SELECT Step_Name__c, Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
    ];
    for (Workflow_Step_Execution__c s : stepsAfter) {
      System.debug(
        '--- STEP AFTER JOIN: Name=' +
          s.Step_Name__c +
          ', Status=' +
          s.Status__c +
          ', Error=' +
          s.Error_Details__c
      );
    }

    System.assertEquals('Completed', instAfter.Status__c);
  }

  @isTest
  static void testRetryWorkflowNullCurrentStep() {
    WorkflowEngine.disableQueueableInTest = true;

    // Construct and insert the instance manually to avoid enqueuing
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Failed',
      Current_Step__c = null,
      Correlation_Key__c = 'NullStepKey'
    );
    insert inst;
    Id instanceId = inst.Id;

    // Run retry. It should not throw NullPointerException
    Test.startTest();
    WorkflowEngine.retryWorkflow(instanceId);
    Test.stopTest();

    inst = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Running', inst.Status__c);
    System.assertEquals('WorkflowEngineTest.HappyStep1', inst.Current_Step__c);
  }

  @isTest
  static void testActiveCorrelationKeyUniqueness() {
    WorkflowEngine.disableQueueableInTest = true;
    // Active-only dedup scope (preserves the legacy uniqueness window)
    WorkflowEngine.dedupWindowMinutes = 0;

    // Start a first instance - should succeed
    Id instanceId1 = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'UniqueActiveKey',
      null
    );

    // Get-or-start: a second start with the same active key returns the
    // existing instance Id instead of throwing or creating a duplicate.
    Id deduped = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'UniqueActiveKey',
      null
    );
    System.assertEquals(
      instanceId1,
      deduped,
      'Active duplicate must resolve to the existing instance, not throw'
    );
    Integer activeCount = [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = 'UniqueActiveKey'
    ];
    System.assertEquals(
      1,
      activeCount,
      'Only one instance should exist while the key is active'
    );

    // Run first instance to completion (terminal)
    WorkflowEngine.runStep(instanceId1, null);
    WorkflowEngine.runStep(instanceId1, null);

    // With the window disabled (active-only), a new instance is created
    // because the first one is terminal.
    Id instanceId2 = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'UniqueActiveKey',
      null
    );
    System.assertNotEquals(null, instanceId2);
    System.assertNotEquals(
      instanceId1,
      instanceId2,
      'With window disabled, a terminal key starts a fresh instance'
    );
  }

  @isTest
  static void testSignalByIdShapedKey() {
    WorkflowEngine.disableQueueableInTest = true;

    // Start an instance with correlation key 'UniqueSignalKey'
    Id instanceId1 = WorkflowEngine.start(
      'WorkflowEngineTest.SignaledWorkflow',
      'UniqueSignalKey',
      null
    );

    // Start a second instance whose correlation key is the string representation of instanceId1's ID!
    String idKey = String.valueOf(instanceId1);
    Id instanceId2 = WorkflowEngine.start(
      'WorkflowEngineTest.SignaledWorkflow',
      idKey,
      null
    );

    // Run the initial step to transition both instances to Suspended
    WorkflowEngine.runStep(instanceId1, null);
    WorkflowEngine.runStep(instanceId2, null);

    // Send a signal using keyOrId = instanceId1. Since keyOrId casts to ID, it should hit instanceId1, NOT instanceId2 (even though instanceId2's correlation key equals instanceId1's ID string!)
    WorkflowEngine.signal(idKey, 'PaymentReceived', '100');

    // Verify instanceId1 received the signal and changed to Running (resumed)
    Workflow_Instance__c inst1 = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId1
    ];
    System.assertEquals(
      'Running',
      inst1.Status__c,
      'Instance 1 should have been resumed'
    );

    // Verify instanceId2 did NOT receive the signal (still Suspended)
    Workflow_Instance__c inst2 = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId2
    ];
    System.assertEquals(
      'Suspended',
      inst2.Status__c,
      'Instance 2 should not have been resumed'
    );
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

  public class TimeoutContinueWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.TimeoutContinueStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.TimeoutContinueStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  @isTest
  static void testContinueAsNewSuccessorWatchdog() {
    WorkflowEngine.disableQueueableInTest = true;

    // Start workflow that continues as new to same workflow definition
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.TimeoutContinueWorkflow',
      'StarterKey',
      null
    );

    // Run the step, which continues as new
    WorkflowEngine.runStep(instanceId, null);

    // Find the successor run
    Workflow_Instance__c successor = [
      SELECT Id, Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :instanceId
      LIMIT 1
    ];
    System.assertEquals(
      'WorkflowEngineTest.TimeoutContinueStep',
      successor.Current_Step__c
    );

    // Verify watchdog job was scheduled for the successor instance's initial step
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Timeout_At__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :successor.Id
        AND Step_Name__c = :successor.Current_Step__c
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    System.assertEquals(1, stepExecs.size());
    System.assertNotEquals(
      null,
      stepExecs[0].Timeout_At__c,
      'Watchdog timeout should be set on successor initial step'
    );
  }

  @isTest
  static void testContentVersionVisibility() {
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'PayloadVisibilityKey',
      null
    );

    // Save a large payload which offloads to ContentVersion
    String largeStr = 'x'.repeat(110000);
    String marker = WorkflowEngine.savePayloadIfNeeded(
      instanceId,
      largeStr,
      'TestPayload'
    );
    System.assert(marker.contains('$attachmentId'));

    // Extract the docId
    Map<String, Object> markerMap = (Map<String, Object>) JSON.deserializeUntyped(
      marker
    );
    Id docId = (Id) markerMap.get('$attachmentId');

    // Query ContentDocumentLink to verify Visibility is set to 'InternalUsers'
    ContentDocumentLink link = [
      SELECT Visibility
      FROM ContentDocumentLink
      WHERE ContentDocumentId = :docId AND LinkedEntityId = :instanceId
      LIMIT 1
    ];
    // Verify visibility is either InternalUsers (if Communities enabled) or AllUsers (if disabled)
    System.assert(
      link.Visibility == 'InternalUsers' || link.Visibility == 'AllUsers',
      'Invalid visibility: ' + link.Visibility
    );
  }

  // Mock class for compensation crash
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

  // Compensation that fails (the first time) with an error whose text merely contains the
  // word "Cancelled" — e.g. an upstream OrderCancelledException — without being an actual
  // user cancellation. Used to prove the engine-owned 'Cancelled by user' marker is what
  // drives the cancel phase, not arbitrary error text.
  public static Boolean cancelWordCompensationShouldFail = false;

  public class CompensatableCancelWordStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }
    public StepResult compensate(StepContext ctx) {
      if (cancelWordCompensationShouldFail) {
        throw new WorkflowEngine.WorkflowException(
          'OrderCancelledException: the order was Cancelled upstream'
        );
      }
      return StepResult.complete(null, 'Reversed');
    }
  }

  @isTest
  static void testWatchdogRaceAndStatuses() {
    WorkflowEngine.disableQueueableInTest = true;
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'RaceKey',
      null
    );

    // Let's create a completed step execution
    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Completed'
    );
    insert stepExec;

    // Transition instance status to Completed
    Workflow_Instance__c inst = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    inst.Status__c = 'Completed';
    update inst;

    // If watchdog runs on a completed instance, it should exit without error or changes
    stepExec.Timeout_At__c = DateTime.now().addSeconds(-10);
    update as system stepExec;

    Test.startTest();
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    // Check that step remains Completed
    Workflow_Step_Execution__c checkStep = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepExec.Id
    ];
    System.assertEquals('Completed', checkStep.Status__c);
  }

  @isTest
  static void testPreStartTimeout() {
    WorkflowEngine.disableQueueableInTest = true;
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'PreStartTimeoutKey',
      null
    );

    // Let's manually create a Pending step execution
    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Pending'
    );
    insert stepExec;

    // We make instance Running
    Workflow_Instance__c inst = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    inst.Status__c = 'Running';
    inst.Current_Step__c = 'WorkflowEngineTest.HappyStep1';
    update inst;

    stepExec.Timeout_At__c = DateTime.now().addSeconds(-10);
    update as system stepExec;

    // Run the watchdog
    Test.startTest();
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    // Verify step execution is marked Failed with 'Step execution timed out before starting.'
    Workflow_Step_Execution__c timedOutStep = [
      SELECT Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepExec.Id
    ];
    System.assertEquals('Failed', timedOutStep.Status__c);
    System.assertEquals(
      'Step execution timed out before starting.',
      timedOutStep.Error_Details__c
    );

    // Verify workflow instance transitions to Failed
    Workflow_Instance__c timedOutInst = [
      SELECT Status__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', timedOutInst.Status__c);
    System.assert(
      timedOutInst.Error_Message__c.contains(
        'Step execution timed out before starting.'
      )
    );
  }

  @isTest
  static void testCompensationTimeout() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Compensating',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
      ),
      Input__c = '{"test": true}'
    );
    insert inst;

    Workflow_Step_Execution__c compExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate',
      Status__c = 'Running'
    );
    insert compExec;

    compExec.Timeout_At__c = DateTime.now().addSeconds(-10);
    update as system compExec;

    // Run the watchdog for the compensation step
    Test.startTest();
    WorkflowEngine.processWatchdogHeartbeat();
    Test.stopTest();

    // Verify step execution status is Failed
    Workflow_Step_Execution__c timedOutStep = [
      SELECT Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :compExec.Id
    ];
    System.assertEquals('Failed', timedOutStep.Status__c);

    // Verify instance status transitions to Failed and does not get stuck in Compensating
    Workflow_Instance__c timedOutInst = [
      SELECT
        Status__c,
        Error_Message__c,
        Compensation_Stack__c,
        Failure_Category__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('CompensationFailed', timedOutInst.Status__c);
    System.assert(timedOutInst.Error_Message__c.contains('timed out'));
    System.assertEquals(
      'COMPENSATION_FAILED',
      timedOutInst.Failure_Category__c
    );
    // Compensation stack should NOT be popped
    List<String> stack = (List<String>) JSON.deserialize(
      timedOutInst.Compensation_Stack__c,
      List<String>.class
    );
    System.assertEquals(1, stack.size());
    System.assertEquals('WorkflowEngineTest.CompensatableHappyStep', stack[0]);
  }

  @isTest
  static void testCompensationFailureRollback() {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Compensating',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableCrashStep' }
      ),
      Input__c = '{"test": true}'
    );
    insert inst;

    // Run the step compensation (will crash because of the mock class)
    Test.startTest();
    WorkflowEngine.runStep(inst.Id, null);
    Test.stopTest();

    // Verify instance transitions to Failed and does not pop the stack
    Workflow_Instance__c failedInst = [
      SELECT
        Status__c,
        Error_Message__c,
        Compensation_Stack__c,
        Failure_Category__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('CompensationFailed', failedInst.Status__c);
    System.assert(
      failedInst.Error_Message__c.contains('Compensation crash simulation')
    );
    System.assertEquals('COMPENSATION_FAILED', failedInst.Failure_Category__c);

    List<String> stack = (List<String>) JSON.deserialize(
      failedInst.Compensation_Stack__c,
      List<String>.class
    );
    System.assertEquals(1, stack.size());
    System.assertEquals('WorkflowEngineTest.CompensatableCrashStep', stack[0]);
  }

  @isTest
  static void testStalledCancellationResumesToCancelled() {
    // A user-cancelled rollback that stalls must remember it was cancel-driven, so
    // that resuming it terminates as 'Cancelled' (not 'Compensated').
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Cancelling',
      Error_Message__c = 'Cancelled by user. Compensating.',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableFailingStep' }
      ),
      Input__c = '{"test": true}'
    );
    insert inst;

    WorkflowEngineTest.compensationShouldFail = true;

    Test.startTest();
    WorkflowEngine.runStep(inst.Id, null); // RETRY (attempt 1)
    WorkflowEngine.runStep(inst.Id, null); // exhausts retries -> stalls

    Workflow_Instance__c stalled = [
      SELECT Status__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('CompensationFailed', stalled.Status__c);
    // The cancel-driven phase marker must survive the stall.
    System.assert(
      stalled.Error_Message__c.contains('Cancelled'),
      'Stalled cancel rollback must retain its Cancelled marker: ' +
      stalled.Error_Message__c
    );

    // The transient failure clears; the operator resumes the rollback.
    WorkflowEngineTest.compensationShouldFail = false;
    WorkflowEngine.resumeCompensation(inst.Id);

    // The resumed rollback must remain cancel-driven, with the 'Cancelled' marker
    // intact so that a suspend (RETRY/SLEEP) before the stack drains still restores
    // the phase as 'Cancelling' rather than 'Compensating'.
    Workflow_Instance__c resumed = [
      SELECT Status__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('Cancelling', resumed.Status__c);
    System.assert(
      resumed.Error_Message__c != null &&
      resumed.Error_Message__c.contains('Cancelled'),
      'Resumed cancel rollback must retain the Cancelled phase marker: ' +
      resumed.Error_Message__c
    );

    WorkflowEngine.runStep(inst.Id, null); // compensate succeeds -> stack drains
    Test.stopTest();

    Workflow_Instance__c finalInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      'Cancelled',
      finalInst.Status__c,
      'A resumed cancel-driven rollback must terminate as Cancelled, not Compensated'
    );
  }

  @isTest
  static void testStalledRollbackReservesCorrelationKey() {
    // A stalled rollback still has un-reversed side effects, so its correlation key
    // must stay reserved: starting a second workflow with the same key must be blocked.
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'CompensationFailed',
      Correlation_Key__c = 'StalledReservedKey',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
      ),
      Error_Message__c = 'Rollback incomplete: ...'
    );
    insert inst;

    // The trigger should keep the active key reserved for the stalled saga.
    Workflow_Instance__c reloaded = [
      SELECT Active_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      'StalledReservedKey',
      reloaded.Active_Correlation_Key__c,
      'CompensationFailed must retain its active correlation key'
    );

    Test.startTest();
    // Get-or-start: because CompensationFailed is an active status, a second start
    // with the same key must dedup to the stalled instance rather than create a
    // duplicate active workflow while side effects are still un-reversed.
    Id deduped = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'StalledReservedKey',
      null
    );
    Test.stopTest();

    System.assertEquals(
      inst.Id,
      deduped,
      'A start colliding with a stalled rollback must resolve to the stalled instance'
    );
    Integer activeCount = [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = 'StalledReservedKey'
    ];
    System.assertEquals(
      1,
      activeCount,
      'No duplicate instance may be created while the rollback is stalled'
    );
  }

  @isTest
  static void testCancelTreeResumesStalledChildRollback() {
    // Cancelling a parent tree with runCompensations=true must reach a stalled
    // (CompensationFailed) child and resume its rollback, draining it to Cancelled.
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Instance__c parent = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running',
      Current_Step__c = 'WorkflowEngineTest.HappyStep1',
      Correlation_Key__c = 'ParentCancelKey'
    );
    insert parent;

    Workflow_Instance__c child = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'CompensationFailed',
      Parent_Instance__c = parent.Id,
      Correlation_Key__c = 'ChildStalledKey',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
      ),
      Error_Message__c = 'Rollback incomplete: ...'
    );
    insert child;
    // The preserved (failed) compensation attempt that left the child stalled.
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = child.Id,
      Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate',
      Status__c = 'Failed'
    );

    Test.startTest();
    WorkflowEngine.cancel(parent.Id, true);

    // The stalled child must now be resumed under the cancel phase.
    Workflow_Instance__c resumedChild = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :child.Id
    ];
    System.assertEquals('Cancelling', resumedChild.Status__c);

    // Drive the resumed child rollback to completion.
    WorkflowEngine.runStep(child.Id, null); // compensate succeeds -> stack drains
    Test.stopTest();

    Workflow_Instance__c finalChild = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :child.Id
    ];
    System.assertEquals(
      'Cancelled',
      finalChild.Status__c,
      'Stalled child rollback should finish as Cancelled when its tree is cancelled'
    );
  }

  @isTest
  static void testCancelTreeForcesStalledChildTerminalWithoutCompensations() {
    // Cancelling with runCompensations=false must force a stalled child terminal
    // (Cancelled), releasing its correlation key rather than leaving it orphaned.
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Instance__c parent = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running',
      Current_Step__c = 'WorkflowEngineTest.HappyStep1',
      Correlation_Key__c = 'ParentCancelKey2'
    );
    insert parent;

    Workflow_Instance__c child = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'CompensationFailed',
      Parent_Instance__c = parent.Id,
      Correlation_Key__c = 'ChildStalledKey2',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
      ),
      Error_Message__c = 'Rollback incomplete: ...'
    );
    insert child;

    Test.startTest();
    WorkflowEngine.cancel(parent.Id, false);
    Test.stopTest();

    Workflow_Instance__c finalChild = [
      SELECT Status__c, Active_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :child.Id
    ];
    System.assertEquals(
      'Cancelled',
      finalChild.Status__c,
      'Stalled child should be forced terminal when cancelling without compensations'
    );
    System.assertEquals(
      null,
      finalChild.Active_Correlation_Key__c,
      'A terminal Cancelled child must release its reserved correlation key'
    );
  }

  @isTest
  static void testCancelSignalReachesStalledRollback() {
    // A Cancel signal must reach a stalled rollback (CompensationFailed); a non-cancel
    // signal to the same instance must still be rejected as "no active workflow".
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'CompensationFailed',
      Correlation_Key__c = 'SignalStalledKey',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
      ),
      Error_Message__c = 'Rollback incomplete: ...'
    );
    insert inst;

    Test.startTest();
    // A non-cancel signal to a stalled (CompensationFailed) instance must be
    // captured as Unrouted rather than thrown — the rollback is not an active
    // forward-signal target, but the signal is preserved for later re-delivery.
    WorkflowEngine.signal('SignalStalledKey', 'SomethingElse', null);
    List<Workflow_Signal__c> captured = [
      SELECT Status__c, Correlation_Key__c
      FROM Workflow_Signal__c
      WHERE Correlation_Key__c = 'SignalStalledKey'
    ];
    System.assertEquals(
      1,
      captured.size(),
      'Non-cancel signal to a stalled rollback must be captured as Unrouted'
    );
    System.assertEquals('Unrouted', captured[0].Status__c);

    // A Cancel signal (without compensations) must reach it and force it terminal.
    WorkflowEngine.signal(
      'SignalStalledKey',
      'CancelWorkflow',
      '{"runCompensations":false}'
    );
    Test.stopTest();

    Workflow_Instance__c cancelled = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      'Cancelled',
      cancelled.Status__c,
      'A Cancel signal must drive a stalled rollback to a terminal state'
    );
  }

  @isTest
  static void testFailureRollbackErrorContainingCancelledStillCompensates() {
    // A failure-driven rollback whose compensation error text merely contains the word
    // "Cancelled" must NOT be mistaken for a user cancellation on resume: it must finish
    // 'Compensated', not 'Cancelled'.
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Compensating',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableCancelWordStep' }
      ),
      Input__c = '{"test": true}'
    );
    insert inst;

    WorkflowEngineTest.cancelWordCompensationShouldFail = true;

    Test.startTest();
    WorkflowEngine.runStep(inst.Id, null); // compensate throws -> stalls

    Workflow_Instance__c stalled = [
      SELECT Status__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('CompensationFailed', stalled.Status__c);
    // The error text contains "Cancelled" but not the engine-owned cancel marker.
    System.assert(
      stalled.Error_Message__c.contains('Cancelled'),
      'Sanity: stalled error contains the word Cancelled'
    );
    System.assert(
      !stalled.Error_Message__c.contains('Cancelled by user'),
      'This is a failure-driven rollback, not a user cancellation'
    );

    WorkflowEngineTest.cancelWordCompensationShouldFail = false;
    WorkflowEngine.resumeCompensation(inst.Id);

    Workflow_Instance__c resumed = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      'Compensating',
      resumed.Status__c,
      'Resume must treat this as a compensation, not a cancellation'
    );

    WorkflowEngine.runStep(inst.Id, null); // compensate succeeds -> stack drains
    Test.stopTest();

    Workflow_Instance__c finalInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      'Compensated',
      finalInst.Status__c,
      'A failure-driven rollback must finish Compensated even when its error text contains "Cancelled"'
    );
  }

  @isTest
  static void testResumeSeedsFromCompensationCheckpoint() {
    // A resumed rollback must continue from the failed compensation's saved checkpoint
    // (YIELD progress stored in its Output__c) rather than restarting from the forward
    // execution output, so partial rollback work is not re-run.
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'CompensationFailed',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
      ),
      Error_Message__c = 'Rollback incomplete: ...'
    );
    insert inst;
    // Forward execution output = the initial undo context.
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep',
      Status__c = 'Completed',
      Output__c = '{"forward":"output"}'
    );
    // A failed compensation attempt that had checkpointed progress via YIELD.
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate',
      Status__c = 'Failed',
      Output__c = '{"checkpoint":"progress"}'
    );

    Test.startTest();
    WorkflowEngine.resumeCompensation(inst.Id);
    Test.stopTest();

    List<Workflow_Step_Execution__c> attempts = [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :inst.Id
        AND Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate'
      ORDER BY CreatedDate ASC, Id ASC
    ];
    System.assertEquals(
      2,
      attempts.size(),
      'A fresh attempt is appended alongside the preserved failed one'
    );
    Workflow_Step_Execution__c fresh = attempts[attempts.size() - 1];
    System.assertEquals('Pending', fresh.Status__c);
    System.assert(
      fresh.Output__c != null && fresh.Output__c.contains('checkpoint'),
      'Resume attempt must be seeded from the compensation checkpoint, got: ' +
      fresh.Output__c
    );
  }

  @isTest
  static void testCompensationCrashViaFinalizerRecordsCompensationStep() {
    // A finalizer-style crash during compensation (no stepName) must be recorded against
    // the top-of-stack _Compensate step, not the stale forward Current_Step__c, so the
    // append-only audit trail and resume path stay correct.
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Compensating',
      Current_Step__c = 'WorkflowEngineTest.HappyStep1', // stale forward step
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
      ),
      Input__c = '{"test": true}'
    );
    insert inst;
    // The pre-created pending compensation log (as preCreateFirstCompensationStep makes).
    Workflow_Step_Execution__c compLog = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate',
      Status__c = 'Pending',
      Retry_Count__c = 0
    );
    insert compLog;

    Test.startTest();
    WorkflowEngine.handleCrash(
      inst.Id,
      new WorkflowEngine.WorkflowException('Governor limit during compensation')
    );

    // The crash is recorded against the compensation step, not the stale forward step.
    Workflow_Step_Execution__c crashedComp = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :compLog.Id
    ];
    System.assertEquals('Failed', crashedComp.Status__c);

    Integer forwardFailures = [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :inst.Id
        AND Step_Name__c = 'WorkflowEngineTest.HappyStep1'
        AND Status__c = 'Failed'
    ];
    System.assertEquals(
      0,
      forwardFailures,
      'A compensation crash must not create a spurious forward-step failure'
    );

    Workflow_Instance__c stalled = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('CompensationFailed', stalled.Status__c);

    // Resume appends a fresh attempt (append-only) and completes the rollback.
    WorkflowEngine.resumeCompensation(inst.Id);
    WorkflowEngine.runStep(inst.Id, null);
    Test.stopTest();

    Workflow_Instance__c finalInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('Compensated', finalInst.Status__c);

    List<Workflow_Step_Execution__c> compAttempts = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :inst.Id
        AND Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate'
      ORDER BY CreatedDate ASC, Id ASC
    ];
    System.assertEquals(
      2,
      compAttempts.size(),
      'The failed attempt is preserved alongside the successful resume attempt'
    );
    System.assertEquals('Failed', compAttempts[0].Status__c);
    System.assertEquals(
      'Compensated',
      compAttempts[compAttempts.size() - 1].Status__c
    );
  }

  @isTest
  static void testCrashCreatedCompensationRowSeededFromOwnForwardStep() {
    // A finalizer crash that has to CREATE the top-of-stack compensation log must seed it
    // from that step's own forward execution, not the latest completed step overall (which,
    // after earlier compensations popped, belongs to an already-reversed step).
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Compensating',
      Current_Step__c = 'WorkflowEngineTest.HappyStep1',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
      ),
      Input__c = '{"wf":"input"}'
    );
    insert inst;

    // The remaining stack entry's forward execution (the correct undo context).
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep',
      Status__c = 'Completed',
      Input__c = '{"a":"in"}',
      Output__c = '{"a":"out"}'
    );
    // A later-completed forward step that was already compensated/popped — this is the
    // "latest completed overall" row the old code would have wrongly seeded from.
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Completed',
      Output__c = '{"b":"out"}'
    );

    Test.startTest();
    WorkflowEngine.handleCrash(
      inst.Id,
      new WorkflowEngine.WorkflowException('Crash before comp row created')
    );
    Test.stopTest();

    Workflow_Step_Execution__c createdComp = [
      SELECT Status__c, Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :inst.Id
        AND Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate'
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    System.assertEquals('Failed', createdComp.Status__c);
    System.assertEquals(
      '{"a":"in"}',
      createdComp.Input__c,
      'Crash-created comp row must seed from its own forward step, not the latest completed overall'
    );
    System.assertEquals('{"a":"out"}', createdComp.Output__c);
  }

  @isTest
  static void testSuspendedCompensationCrashRecordsCompensationStep() {
    // A sleeping/approval-gated compensation: the engine parked the saga as Suspended
    // while a _Compensate step waited (SLEEP/SUSPEND/WAIT_FOR_APPROVAL), then resumed it
    // via WorkflowOrchestrator(instanceId) with no stepName. runStep flips Suspended back
    // to Compensating in-transaction, but a crash rolls that flip back, so the finalizer's
    // handleCrash sees status 'Suspended' with a blank stepName. It must still record the
    // crash against the top-of-stack _Compensate step (not the stale forward step) and
    // park the saga as recoverable CompensationFailed.
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended', // rolled back from Compensating by the crash
      Current_Step__c = 'WorkflowEngineTest.HappyStep1', // stale forward step
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
      ),
      Input__c = '{"test": true}'
    );
    insert inst;
    // The suspended _Compensate attempt (Pending, as the SLEEP/approval branch leaves it).
    // It is the latest step execution, which is how handleCrash detects mid-rollback.
    Workflow_Step_Execution__c compLog = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate',
      Status__c = 'Pending',
      Retry_Count__c = 0
    );
    insert compLog;

    Test.startTest();
    WorkflowEngine.handleCrash(
      inst.Id,
      new WorkflowEngine.WorkflowException(
        'Crash resuming sleeping compensation'
      )
    );

    Workflow_Step_Execution__c crashedComp = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :compLog.Id
    ];
    System.assertEquals('Failed', crashedComp.Status__c);

    Integer forwardFailures = [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :inst.Id
        AND Step_Name__c = 'WorkflowEngineTest.HappyStep1'
        AND Status__c = 'Failed'
    ];
    System.assertEquals(
      0,
      forwardFailures,
      'A suspended-compensation crash must not create a spurious forward-step failure'
    );

    Workflow_Instance__c stalled = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('CompensationFailed', stalled.Status__c);

    WorkflowEngine.resumeCompensation(inst.Id);
    WorkflowEngine.runStep(inst.Id, null);
    Test.stopTest();

    Workflow_Instance__c finalInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('Compensated', finalInst.Status__c);

    List<Workflow_Step_Execution__c> compAttempts = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :inst.Id
        AND Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate'
      ORDER BY CreatedDate ASC, Id ASC
    ];
    System.assertEquals(
      2,
      compAttempts.size(),
      'The failed suspended attempt is preserved alongside the successful resume attempt'
    );
    System.assertEquals('Failed', compAttempts[0].Status__c);
  }

  @isTest
  static void testSuspendedCancelCompensationCrashStaysOnCancelPath() {
    // A cancel-driven rollback whose compensation was sleeping/approval-gated (Suspended)
    // when the crash hit. The persisted status is 'Suspended' (the in-transaction flip to
    // 'Cancelling' rolled back), but the engine-owned 'Cancelled by user' marker survives
    // in Error_Message__c. handleCrash must keep the saga on the cancel path so it ends
    // 'Cancelled' rather than 'Compensated' after resume.
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Error_Message__c = 'Cancelled by user. Compensating.',
      Current_Step__c = 'WorkflowEngineTest.HappyStep1',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
      ),
      Input__c = '{"test": true}'
    );
    insert inst;
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep_Compensate',
      Status__c = 'Pending',
      Retry_Count__c = 0
    );

    Test.startTest();
    WorkflowEngine.handleCrash(
      inst.Id,
      new WorkflowEngine.WorkflowException(
        'Crash resuming sleeping cancel compensation'
      )
    );

    Workflow_Instance__c stalled = [
      SELECT Status__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals('CompensationFailed', stalled.Status__c);
    System.assert(
      stalled.Error_Message__c.contains('Cancelled by user'),
      'The cancel marker must survive the suspended-compensation crash'
    );

    WorkflowEngine.resumeCompensation(inst.Id);
    WorkflowEngine.runStep(inst.Id, null);
    Test.stopTest();

    Workflow_Instance__c finalInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      'Cancelled',
      finalInst.Status__c,
      'A cancel-driven rollback that crashed mid-sleep must finish Cancelled, not Compensated'
    );
  }

  @isTest
  static void testBulkStart() {
    List<WorkflowEngine.StartRequest> requests = new List<WorkflowEngine.StartRequest>();
    for (Integer i = 0; i < 5; i++) {
      requests.add(
        new WorkflowEngine.StartRequest(
          'WorkflowEngineTest.HappyWorkflow',
          'BulkKey_' + i,
          'StartVal_' + i
        )
      );
    }

    Test.startTest();
    List<Id> instanceIds = WorkflowEngine.start(requests);
    Test.stopTest(); // Runs HappyStep1 for all of them synchronously

    System.assertEquals(5, instanceIds.size());
    List<Workflow_Instance__c> instances = [
      SELECT Id, Status__c, Correlation_Key__c, Input__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id IN :instanceIds
    ];
    System.assertEquals(5, instances.size());
    for (Workflow_Instance__c inst : instances) {
      System.assertEquals('Running', inst.Status__c);
      System.assert(inst.Correlation_Key__c.startsWith('BulkKey_'));
      System.assertEquals(
        'WorkflowEngineTest.HappyStep2',
        inst.Current_Step__c
      );
    }
  }

  @isTest
  static void testBulkResume() {
    // 1. Create suspended workflow instances
    List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < 5; i++) {
      instances.add(
        new Workflow_Instance__c(
          Workflow_Name__c = 'WorkflowEngineTest.SuspendingWorkflow',
          Status__c = 'Suspended',
          Correlation_Key__c = 'BulkResumeKey_' + i,
          Current_Step__c = 'WorkflowEngineTest.SuspendingStep'
        )
      );
    }
    insert instances;

    // Insert active step executions for them
    List<Workflow_Step_Execution__c> stepExecs = new List<Workflow_Step_Execution__c>();
    for (Workflow_Instance__c inst : instances) {
      stepExecs.add(
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst.Id,
          Step_Name__c = 'WorkflowEngineTest.SuspendingStep',
          Status__c = 'Pending',
          Retry_Count__c = 0
        )
      );
    }
    insert stepExecs;

    // 2. Publish RESUME events
    List<Workflow_Event__e> events = new List<Workflow_Event__e>();
    for (Integer i = 0; i < 5; i++) {
      events.add(
        new Workflow_Event__e(
          Workflow_Instance_Id__c = 'BulkResumeKey_' + i,
          Event_Type__c = 'RESUME',
          Payload__c = 'ResumeData_' + i
        )
      );
    }

    Test.startTest();
    EventBus.publish(events);
    Test.getEventBus().deliver(); // Executes WorkflowEventTrigger which resumes all in bulk
    Test.stopTest();

    List<Workflow_Instance__c> updatedInstances = [
      SELECT Id, Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id IN :instances
    ];
    for (Workflow_Instance__c inst : updatedInstances) {
      System.assertEquals('Running', inst.Status__c);
      System.assertEquals(
        'WorkflowEngineTest.AfterSuspendStep',
        inst.Current_Step__c
      );
    }
  }

  @isTest
  static void testBulkSignal() {
    // 1. Start workflows that block on signals
    List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < 5; i++) {
      instances.add(
        new Workflow_Instance__c(
          Workflow_Name__c = 'WorkflowEngineTest.SignaledWorkflow',
          Status__c = 'Suspended',
          Correlation_Key__c = 'BulkSignalKey_' + i,
          Current_Step__c = 'WorkflowEngineTest.SignaledStep'
        )
      );
    }
    insert instances;

    // 2. Send SIGNAL platform events
    List<Workflow_Event__e> events = new List<Workflow_Event__e>();
    for (Integer i = 0; i < 5; i++) {
      events.add(
        new Workflow_Event__e(
          Workflow_Instance_Id__c = 'BulkSignalKey_' + i,
          Event_Type__c = 'SIGNAL:PaymentReceived',
          Payload__c = '{"amount": ' + (100 + i) + '}'
        )
      );
    }

    Test.startTest();
    EventBus.publish(events);
    Test.getEventBus().deliver(); // Trigger runs, inserts Workflow_Signal__c in bulk, sets to Running
    Test.stopTest();

    List<Workflow_Signal__c> signals = [
      SELECT Id, Signal_Name__c, Payload__c, Status__c, Workflow_Instance__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c IN :instances
    ];
    System.assertEquals(5, signals.size());
    for (Workflow_Signal__c sig : signals) {
      System.assertEquals('PaymentReceived', sig.Signal_Name__c);
      System.assertEquals('Consumed', sig.Status__c);
    }
  }

  // ==========================================
  // OUTBOUND Workflow_Lifecycle__e EVENT (issue #14)
  // ==========================================

  @isTest
  static void testLifecycleEventOnCompletion() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'LifecycleHappyKey',
      'StartVal'
    );
    Test.stopTest(); // Runs HappyStep1 synchronously

    // Execute the second/terminal step synchronously
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c inst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);

    // Exactly one lifecycle event, describing the successful terminal outcome.
    System.assertEquals(
      1,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'A completed workflow publishes exactly one lifecycle event'
    );
    Workflow_Lifecycle__e evt = WorkflowLifecyclePublisher.publishedEvents[0];
    System.assertEquals(instanceId, evt.Workflow_Instance_Id__c);
    System.assertEquals('Completed', evt.Status__c);
    System.assertEquals(true, evt.Is_Success__c);
    System.assertEquals('LifecycleHappyKey', evt.Correlation_Key__c);
    System.assertEquals(
      'LifecycleHappyKey',
      evt.Root_Correlation_Key__c,
      'Root key equals the correlation key for a non-continue-as-new workflow'
    );
    System.assertEquals(
      'WorkflowEngineTest.HappyWorkflow',
      evt.Workflow_Name__c
    );
    System.assertNotEquals(
      null,
      evt.Terminal_At__c,
      'The event carries a terminal transition timestamp for retry-aware dedupe'
    );
  }

  @isTest
  static void testLifecycleEventOnFailure() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.CustomRetryWorkflow',
      'LifecycleRetryKey',
      null
    );
    Test.stopTest(); // First attempt -> Retrying

    WorkflowEngine.runStep(instanceId); // Second attempt -> Retrying
    WorkflowEngine.runStep(instanceId); // Third attempt -> exceeds max -> Failed

    Workflow_Instance__c inst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', inst.Status__c);

    System.assertEquals(
      1,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'A failed workflow publishes exactly one lifecycle event'
    );
    Workflow_Lifecycle__e evt = WorkflowLifecyclePublisher.publishedEvents[0];
    System.assertEquals('Failed', evt.Status__c);
    System.assertEquals(false, evt.Is_Success__c);
    System.assertNotEquals(
      null,
      evt.Failure_Detail__c,
      'Failure detail is sourced from Error_Message__c'
    );
    System.assert(
      evt.Failure_Detail__c.contains('Max retries exceeded'),
      'Failure detail carries the engine error message'
    );
  }

  @isTest
  static void testLifecycleExactlyOnceForContinueAsNewChain() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.DaemonWorkflow',
      'LifecycleDaemonKey',
      0
    );
    // Run 1: counter 0 -> ContinuedAsNew (no event)
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c run2 = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :instanceId
    ];
    // Run 2: counter 1 -> ContinuedAsNew (no event)
    new WorkflowOrchestrator(run2.Id).execute(null);

    Workflow_Instance__c run3 = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :run2.Id
    ];
    // Run 3: counter 2 -> Completed (exactly one event for the whole chain)
    new WorkflowOrchestrator(run3.Id).execute(null);

    System.assertEquals(
      'Completed',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :run3.Id].Status__c
    );

    System.assertEquals(
      1,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'A ContinuedAsNew chain emits exactly one terminal event — on the final successor only'
    );
    Workflow_Lifecycle__e evt = WorkflowLifecyclePublisher.publishedEvents[0];
    System.assertEquals(
      run3.Id,
      evt.Workflow_Instance_Id__c,
      'The single event references the final successor instance'
    );
    System.assertEquals('Completed', evt.Status__c);
    System.assertEquals(true, evt.Is_Success__c);
    // The successor's own key was rewritten (DaemonKey_run3), but the chain root
    // key stays the original start key so the launcher can correlate the event.
    System.assertEquals(
      'LifecycleDaemonKey_run3',
      evt.Correlation_Key__c,
      'The event carries the final successor key'
    );
    System.assertEquals(
      'LifecycleDaemonKey',
      evt.Root_Correlation_Key__c,
      'The event carries the stable chain root key from the original start request'
    );
  }

  @isTest
  static void testLifecycleEventOnCancellation() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SignaledWorkflow',
      'LifecycleCancelKey',
      null
    );
    Test.stopTest(); // Runs SignaledStep which suspends awaiting a signal

    WorkflowEngine.cancel(instanceId, false); // No compensations -> Cancelled

    Workflow_Instance__c inst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Cancelled', inst.Status__c);

    System.assertEquals(
      1,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'A cancelled workflow publishes exactly one lifecycle event'
    );
    Workflow_Lifecycle__e evt = WorkflowLifecyclePublisher.publishedEvents[0];
    System.assertEquals('Cancelled', evt.Status__c);
    System.assertEquals(false, evt.Is_Success__c);
    System.assertEquals(
      'WorkflowEngineTest.SignaledWorkflow',
      evt.Workflow_Name__c,
      'Cancellation event carries the workflow name (query was widened for it)'
    );
  }

  @isTest
  static void testLifecycleToggleDisablesEmission() {
    WorkflowEngine.publishLifecycleEvents = false;

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'LifecycleToggleKey',
      'StartVal'
    );
    Test.stopTest();
    new WorkflowOrchestrator(instanceId).execute(null);

    System.assertEquals(
      'Completed',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
      .Status__c,
      'Disabling the toggle does not affect the terminal transition itself'
    );
    System.assertEquals(
      0,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'No lifecycle event is published when the operator toggle is off'
    );
  }

  @isTest
  static void testLifecyclePublishFailureDoesNotBreakTransition() {
    WorkflowLifecyclePublisher.throwTestException = true;

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'LifecycleIsolationKey',
      'StartVal'
    );
    Test.stopTest();
    // Terminal transition runs through the (failing) publish site and must survive.
    new WorkflowOrchestrator(instanceId).execute(null);

    System.assertEquals(
      'Completed',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
      .Status__c,
      'A publish failure is swallowed and never rolls back the terminal write'
    );
    System.assertEquals(
      0,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'The simulated publish failure recorded no delivered event'
    );
  }

  @isTest
  static void testLifecycleEventOnCompensationDrain() {
    // Regression: the compensation drain re-queries the instance, and the
    // terminal publish must carry Correlation_Key__c (was dropped from that
    // re-query, which would have thrown an unqueried-field exception and rolled
    // back the Compensated write).
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Correlation_Key__c = 'LifecycleCompKey',
      Status__c = 'Compensating',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
      ),
      Input__c = '{"test": true}'
    );
    insert inst;

    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep',
      Status__c = 'Completed',
      Input__c = '{"stepInput": 1}',
      Output__c = '{"stepOutput": 2}'
    );

    Test.startTest();
    WorkflowEngine.runStep(inst.Id, null); // Compensate step
    WorkflowEngine.runStep(inst.Id, null); // Stack drained -> Compensated + publish
    Test.stopTest();

    System.assertEquals(
      'Compensated',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id]
      .Status__c,
      'Compensation drain reaches the terminal state (no publish-induced rollback)'
    );
    System.assertEquals(
      1,
      WorkflowLifecyclePublisher.publishedEvents.size(),
      'Compensation drain publishes exactly one lifecycle event'
    );
    Workflow_Lifecycle__e evt = WorkflowLifecyclePublisher.publishedEvents[0];
    System.assertEquals('Compensated', evt.Status__c);
    System.assertEquals(false, evt.Is_Success__c);
    System.assertEquals(
      'LifecycleCompKey',
      evt.Correlation_Key__c,
      'The event carries the correlation key from the widened re-query'
    );
  }

  @isTest
  static void testLifecycleEventsOnParentChildCancelTree() {
    // The cancel tree publishes one bulk batch after every node is cancelled, so
    // the best-effort publish never starves a later child cancellation of DML.
    WorkflowEngine.disableQueueableInTest = true;
    Id parentId = WorkflowEngine.start(
      'WorkflowEngineTest.ParentWorkflow',
      'CancelTreeParent',
      null
    );
    WorkflowEngine.runStep(parentId, null); // parent starts child, suspends

    Workflow_Instance__c childInst = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :parentId
      LIMIT 1
    ];

    Test.startTest();
    WorkflowEngine.cancel(parentId, false); // cancels parent + child, then bulk-publishes
    Test.stopTest();

    System.assertEquals(
      'Cancelled',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :parentId]
      .Status__c
    );
    System.assertEquals(
      'Cancelled',
      [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :childInst.Id]
      .Status__c
    );

    // One lifecycle event per terminally-cancelled node, emitted as a single bulk
    // batch after the whole tree was cancelled.
    Set<Id> eventInstanceIds = new Set<Id>();
    for (
      Workflow_Lifecycle__e evt : WorkflowLifecyclePublisher.publishedEvents
    ) {
      System.assertEquals('Cancelled', evt.Status__c);
      System.assertEquals(false, evt.Is_Success__c);
      eventInstanceIds.add((Id) evt.Workflow_Instance_Id__c);
    }
    System.assertEquals(
      new Set<Id>{ parentId, childInst.Id },
      eventInstanceIds,
      'Both the parent and child cancellations emit exactly one lifecycle event'
    );
  }

  @isTest
  static void testPreviousRunAtFlowsThroughContinueAsNew() {
    WorkflowEngine.disableQueueableInTest = true;

    Id run1Id = WorkflowEngine.start(
      'WorkflowEngineTest.PreviousRunAtWorkflow',
      'PreviousRunAtKey',
      null
    );
    new WorkflowOrchestrator(run1Id).execute(null);

    Workflow_Instance__c run1 = [
      SELECT Status__c, Previous_Run_At__c
      FROM Workflow_Instance__c
      WHERE Id = :run1Id
    ];
    System.assertEquals('ContinuedAsNew', run1.Status__c);
    System.assertEquals(
      null,
      run1.Previous_Run_At__c,
      'First instance must not have Previous_Run_At__c set'
    );

    Workflow_Instance__c run2 = [
      SELECT Id, Previous_Run_At__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :run1Id
    ];
    System.assertNotEquals(
      null,
      run2.Previous_Run_At__c,
      'Continuation instance must have Previous_Run_At__c set'
    );

    new WorkflowOrchestrator(run2.Id).execute(null);

    Workflow_Instance__c run2Final = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :run2.Id
    ];
    System.assertEquals('Completed', run2Final.Status__c);
    Long outputTime = Long.valueOf(run2Final.Output__c);
    Long fieldTime = run2.Previous_Run_At__c.getTime();
    System.assertEquals(
      fieldTime,
      outputTime,
      'StepContext.previousRunAt must equal Previous_Run_At__c on the instance'
    );
  }

  // ── Unrouted-signal capture & re-delivery tests ────────────────────────────

  @isTest
  static void testUnroutedSignalCaptured_singleMethod() {
    // Sending a signal when no active instance matches must create an Unrouted
    // Workflow_Signal__c row instead of throwing.
    WorkflowEngine.disableQueueableInTest = true;

    Test.startTest();
    WorkflowEngine.signal('NoSuchKey-Single', 'WakeUp', '{"x":1}');
    Test.stopTest();

    List<Workflow_Signal__c> captured = [
      SELECT
        Id,
        Status__c,
        Correlation_Key__c,
        Signal_Name__c,
        Payload__c,
        Workflow_Instance__c
      FROM Workflow_Signal__c
      WHERE Correlation_Key__c = 'NoSuchKey-Single'
    ];
    System.assertEquals(
      1,
      captured.size(),
      'Unmatched signal must be captured as one row'
    );
    System.assertEquals(
      'Unrouted',
      captured[0].Status__c,
      'Captured signal must have Unrouted status'
    );
    System.assertEquals('WakeUp', captured[0].Signal_Name__c);
    System.assertEquals('{"x":1}', captured[0].Payload__c);
    System.assertEquals(
      null,
      captured[0].Workflow_Instance__c,
      'Unrouted signal must have no parent instance'
    );

    List<Workflow_Step_Execution__c> steps = [
      SELECT Id
      FROM Workflow_Step_Execution__c
    ];
    System.assertEquals(
      0,
      steps.size(),
      'Signal capture must never write step-execution rows'
    );
  }

  @isTest
  static void testUnroutedSignalCaptured_bulkMethod() {
    WorkflowEngine.disableQueueableInTest = true;

    List<WorkflowEngine.SignalRequest> reqs = new List<WorkflowEngine.SignalRequest>{
      new WorkflowEngine.SignalRequest('BulkKey-A', 'Ping', null),
      new WorkflowEngine.SignalRequest('BulkKey-B', 'Pong', '{"y":2}')
    };

    Test.startTest();
    WorkflowEngine.signal(reqs);
    Test.stopTest();

    List<Workflow_Signal__c> captured = [
      SELECT Id, Status__c, Correlation_Key__c, Signal_Name__c
      FROM Workflow_Signal__c
      WHERE Correlation_Key__c IN ('BulkKey-A', 'BulkKey-B')
      ORDER BY Correlation_Key__c ASC
    ];
    System.assertEquals(
      2,
      captured.size(),
      'Both unmatched bulk signals must be captured'
    );
    System.assertEquals('Unrouted', captured[0].Status__c);
    System.assertEquals('Unrouted', captured[1].Status__c);
    System.assertEquals('BulkKey-A', captured[0].Correlation_Key__c);
    System.assertEquals('BulkKey-B', captured[1].Correlation_Key__c);
  }

  @isTest
  static void testUnroutedSignalIdempotent_sameDedupKey() {
    // The same signal delivered N times with the same dedupKey must produce
    // exactly one Unrouted row (at-least-once idempotency).
    WorkflowEngine.disableQueueableInTest = true;

    String dedupKey = 'idempotency-test-uuid-001';

    Test.startTest();
    WorkflowEngine.signal(
      new List<WorkflowEngine.SignalRequest>{
        new WorkflowEngine.SignalRequest(
          'IdempKey',
          'Arrive',
          '{"n":1}',
          dedupKey
        )
      }
    );
    WorkflowEngine.signal(
      new List<WorkflowEngine.SignalRequest>{
        new WorkflowEngine.SignalRequest(
          'IdempKey',
          'Arrive',
          '{"n":1}',
          dedupKey
        )
      }
    );
    WorkflowEngine.signal(
      new List<WorkflowEngine.SignalRequest>{
        new WorkflowEngine.SignalRequest(
          'IdempKey',
          'Arrive',
          '{"n":1}',
          dedupKey
        )
      }
    );
    Test.stopTest();

    List<Workflow_Signal__c> captured = [
      SELECT Id, Signal_Key__c
      FROM Workflow_Signal__c
      WHERE Correlation_Key__c = 'IdempKey'
    ];
    System.assertEquals(
      1,
      captured.size(),
      'N deliveries with the same dedupKey must produce exactly one captured row'
    );
    System.assertEquals(dedupKey, captured[0].Signal_Key__c);
  }

  @isTest
  static void testRedeliverCapturedSignal_wakesInstance() {
    // Re-delivering a captured signal to a now-waiting instance must wake it
    // and transition the captured row to Received with the instance FK set.
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Signal__c sig = new Workflow_Signal__c(
      Correlation_Key__c = 'Redeliver-Key',
      Signal_Name__c = 'WakeMe',
      Payload__c = null,
      Status__c = 'Unrouted'
    );
    insert sig;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'Redeliver-Key'
    );
    insert inst;

    Test.startTest();
    Boolean matched = WorkflowEngine.redeliverCapturedSignal(sig.Id);
    Test.stopTest();

    System.assertEquals(
      true,
      matched,
      'Re-delivery must return true when a match is found'
    );

    Workflow_Signal__c reloaded = [
      SELECT Id, Status__c, Workflow_Instance__c
      FROM Workflow_Signal__c
      WHERE Id = :sig.Id
    ];
    System.assertEquals(
      'Received',
      reloaded.Status__c,
      'Re-delivered signal must have Received status'
    );
    System.assertEquals(
      inst.Id,
      reloaded.Workflow_Instance__c,
      'Re-delivered signal must be parented to the matched instance'
    );

    Workflow_Instance__c reloadedInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      'Running',
      reloadedInst.Status__c,
      'Suspended instance must be set to Running on re-delivery'
    );
  }

  @isTest
  static void testRedeliverCapturedSignal_noopWhenUnmatched() {
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Signal__c sig = new Workflow_Signal__c(
      Correlation_Key__c = 'Still-No-Match',
      Signal_Name__c = 'Orphan',
      Payload__c = null,
      Status__c = 'Unrouted'
    );
    insert sig;

    Test.startTest();
    Boolean matched = WorkflowEngine.redeliverCapturedSignal(sig.Id);
    Test.stopTest();

    System.assertEquals(
      false,
      matched,
      'Re-delivery must return false when no active instance exists'
    );

    Workflow_Signal__c reloaded = [
      SELECT Status__c, Workflow_Instance__c
      FROM Workflow_Signal__c
      WHERE Id = :sig.Id
    ];
    System.assertEquals(
      'Unrouted',
      reloaded.Status__c,
      'Unmatched re-delivery must leave the row Unrouted'
    );
    System.assertEquals(null, reloaded.Workflow_Instance__c);
  }

  @isTest
  static void testUnroutedCancelSignalStillThrows() {
    // An unmatched Cancel signal must NOT be captured — it must still throw,
    // since re-delivering a cancel to a future instance would be incorrect.
    WorkflowEngine.disableQueueableInTest = true;

    Boolean threw = false;
    Test.startTest();
    try {
      WorkflowEngine.signal('NonExistentCancel', 'CancelWorkflow', null);
    } catch (WorkflowEngine.WorkflowException ex) {
      threw = true;
    }
    Test.stopTest();

    System.assert(
      threw,
      'An unmatched Cancel signal must still throw, not be captured'
    );

    List<Workflow_Signal__c> captured = [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE Correlation_Key__c = 'NonExistentCancel'
    ];
    System.assertEquals(
      0,
      captured.size(),
      'No Unrouted row must be created for an unmatched Cancel'
    );
  }

  @isTest
  static void testMatchedSignalBehaviorUnchanged() {
    // Signals that DO match an active instance must still follow the existing
    // path: Received status, parent FK set, instance woken — no regression.
    WorkflowEngine.disableQueueableInTest = true;

    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Correlation_Key__c = 'MatchedSignalKey'
    );
    insert inst;

    Test.startTest();
    WorkflowEngine.signal('MatchedSignalKey', 'Resume', '{"data":"go"}');
    Test.stopTest();

    List<Workflow_Signal__c> signals = [
      SELECT Status__c, Workflow_Instance__c, Signal_Name__c
      FROM Workflow_Signal__c
      WHERE Workflow_Instance__c = :inst.Id
    ];
    System.assertEquals(
      1,
      signals.size(),
      'Matched signal must produce exactly one Workflow_Signal__c row'
    );
    System.assertEquals(
      'Received',
      signals[0].Status__c,
      'Matched signal must have Received status (not Unrouted)'
    );
    System.assertEquals(inst.Id, signals[0].Workflow_Instance__c);

    Workflow_Instance__c reloaded = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(
      'Running',
      reloaded.Status__c,
      'Matched suspended instance must be woken to Running'
    );

    List<Workflow_Step_Execution__c> steps = [
      SELECT Id
      FROM Workflow_Step_Execution__c
    ];
    System.assertEquals(
      0,
      steps.size(),
      'Signal delivery must not write step-execution rows'
    );
  }

  // ==========================================
  // WorkflowValidator coverage (issue #23)
  // ==========================================

  // A class that is not a WorkflowStep, used to prove the validator rejects a
  // declared step name that resolves to a non-step class.
  public class NotARealStep {
    public String label() {
      return 'not a step';
    }
  }

  // Deliberately malformed DAG: bad initial step (not declared), a declared
  // step that is not a WorkflowStep, and a dangling getNextStep successor.
  public class MalformedValidatorWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.NotARealStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.HappyStep1'; // not contained in getSteps()
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return 'WorkflowEngineTest.NoSuchStep'; // dangling, undeclared successor
    }
  }

  @isTest
  static void testWorkflowValidatorReportsMalformedDag() {
    // A deliberately malformed definition is reported with every structural
    // defect, and a well-formed one (HappyWorkflow) passes clean.
    WorkflowValidator.ValidationResult bad = WorkflowValidator.validate(
      'WorkflowEngineTest.MalformedValidatorWorkflow'
    );
    System.assertEquals(false, bad.isValid(), 'Malformed DAG must be invalid');
    System.assert(
      bad.hasDefect(WorkflowValidator.INITIAL_STEP_NOT_DECLARED),
      'bad initial step not reported: ' + bad.getMessages()
    );
    System.assert(
      bad.hasDefect(WorkflowValidator.STEP_NOT_WORKFLOWSTEP),
      'non-WorkflowStep class not reported: ' + bad.getMessages()
    );
    System.assert(
      bad.hasDefect(WorkflowValidator.DANGLING_SUCCESSOR),
      'dangling successor not reported: ' + bad.getMessages()
    );

    WorkflowValidator.ValidationResult good = WorkflowValidator.validate(
      'WorkflowEngineTest.HappyWorkflow'
    );
    System.assertEquals(
      true,
      good.isValid(),
      'Well-formed HappyWorkflow should pass clean: ' + good.getMessages()
    );
  }

  // ==========================================
  // TIMED WAIT — MOCK WORKFLOWS & STEPS (Issue #35)
  // ==========================================

  public class TimedSuspendWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.TimedSuspendStep',
        'WorkflowEngineTest.TimeoutFallbackStep',
        'WorkflowEngineTest.AfterTimedSignalStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.TimedSuspendStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineTest.TimedSuspendStep') {
        return 'WorkflowEngineTest.AfterTimedSignalStep';
      }
      return null;
    }
  }

  public class TimedSuspendStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      List<Workflow_Signal__c> signals = [
        SELECT Id, Signal_Name__c, Payload__c
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :ctx.workflowInstanceId
          AND Signal_Name__c = 'Resume'
          AND Status__c = 'Received'
        LIMIT 1
      ];
      if (!signals.isEmpty()) {
        Workflow_Signal__c sig = signals[0];
        sig.Status__c = 'Consumed';
        update sig;
        return StepResult.complete(
          'WorkflowEngineTest.AfterTimedSignalStep',
          'signaled'
        );
      }
      return StepResult.suspend(60, 'WorkflowEngineTest.TimeoutFallbackStep');
    }
  }

  // Flag to record whether isTimeoutResume() was true when fallback ran
  public static Boolean capturedIsTimeoutResume = null;

  public class TimeoutFallbackStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      WorkflowEngineTest.capturedIsTimeoutResume = ctx.isTimeoutResume();
      return StepResult.complete(null, 'timedout');
    }
  }

  public class AfterTimedSignalStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'signaled');
    }
  }

  // Timed approval variant
  public class TimedApprovalWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.TimedApprovalStep',
        'WorkflowEngineTest.ApprovalTimeoutFallbackStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.TimedApprovalStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
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
        'WorkflowEngineTest.ApprovalTimeoutFallbackStep'
      );
    }
  }

  public class ApprovalTimeoutFallbackStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'approval_timedout');
    }
  }

  // ==========================================
  // TIMED WAIT — TESTS (Issue #35)
  // ==========================================

  @isTest
  static void testTimedSuspend_TimeoutWins() {
    WorkflowEngine.disableQueueableInTest = true;
    capturedIsTimeoutResume = null;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.TimedSuspendWorkflow',
      'TimedSuspendKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);

    // Assert the timed suspend armed the timer
    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', inst.Status__c, 'Should be Suspended');
    System.assertEquals(
      'WorkflowEngineTest.TimedSuspendStep',
      inst.Current_Step__c
    );
    System.assertNotEquals(null, inst.Sleep_Until__c, 'Timer should be armed');

    // Capture the wait step exec id and assert $timeoutStep is persisted
    Workflow_Step_Execution__c waitExec = [
      SELECT Id, Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.TimedSuspendStep'
      LIMIT 1
    ];
    System.assertEquals('Pending', waitExec.Status__c);
    System.assert(
      waitExec.Output__c != null &&
        waitExec.Output__c.contains('"$timeoutStep"') &&
        waitExec.Output__c.contains('WorkflowEngineTest.TimeoutFallbackStep'),
      'Output should contain $timeoutStep: ' + waitExec.Output__c
    );
    Id waitExecId = waitExec.Id;
    String waitExecOutput = waitExec.Output__c;

    // Simulate the deadline firing
    inst.Sleep_Until__c = DateTime.now().addSeconds(-10);
    update as system inst;

    // Run the watchdog
    WorkflowEngine.processWatchdogHeartbeat();

    // Assert routing: Current_Step__c advanced to the fallback
    inst = [
      SELECT Status__c, Current_Step__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'Running',
      inst.Status__c,
      'Should be Running after timeout'
    );
    System.assertEquals(
      'WorkflowEngineTest.TimeoutFallbackStep',
      inst.Current_Step__c,
      'Should route to timeout fallback step'
    );
    System.assertEquals(null, inst.Sleep_Until__c, 'Timer should be disarmed');

    // Assert a NEW Pending step exec was created for the fallback
    List<Workflow_Step_Execution__c> fallbackExecs = [
      SELECT Id, Status__c, Input__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.TimeoutFallbackStep'
    ];
    System.assertEquals(
      1,
      fallbackExecs.size(),
      'Should have exactly one fallback exec'
    );
    System.assertEquals('Pending', fallbackExecs[0].Status__c);

    // Assert the original wait exec is UNMUTATED (append-only)
    Workflow_Step_Execution__c unchangedWaitExec = [
      SELECT Id, Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :waitExecId
    ];
    System.assertEquals(
      'Pending',
      unchangedWaitExec.Status__c,
      'Wait exec must remain Pending (append-only)'
    );
    System.assertEquals(
      waitExecOutput,
      unchangedWaitExec.Output__c,
      'Wait exec Output must be unmutated'
    );

    // Run the fallback step
    new WorkflowOrchestrator(instanceId).execute(null);

    inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assertEquals('"timedout"', inst.Output__c);

    // Assert isTimeoutResume() was true in the fallback step
    System.assertEquals(
      true,
      capturedIsTimeoutResume,
      'isTimeoutResume() must be true in the fallback step'
    );

    // Assert $timeoutResume was stripped from ctx.inputJson (not visible to step author)
    Workflow_Step_Execution__c fallbackExec = [
      SELECT Input__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :fallbackExecs[0].Id
    ];
    System.assert(
      fallbackExec.Input__c == null ||
      !fallbackExec.Input__c.contains('$timeoutResume'),
      'Engine marker $timeoutResume should not be visible in stored Input: ' +
      fallbackExec.Input__c
    );
  }

  @isTest
  static void testTimedSuspend_SignalWins() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.TimedSuspendWorkflow',
      'TimedSuspendSignalKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);

    // Verify timer was armed
    Workflow_Instance__c inst = [
      SELECT Status__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', inst.Status__c);
    System.assertNotEquals(null, inst.Sleep_Until__c, 'Timer should be armed');

    // Send the winning signal (single-instance signal path)
    WorkflowEngine.signal('TimedSuspendSignalKey', 'Resume', '{}');

    // Assert signal disarmed the timer
    inst = [
      SELECT Status__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'Running',
      inst.Status__c,
      'Should be Running after signal'
    );
    System.assertEquals(
      null,
      inst.Sleep_Until__c,
      'Signal win must disarm the timer (Sleep_Until__c must be null)'
    );

    // Run the resumed step
    new WorkflowOrchestrator(instanceId).execute(null);

    // Assert advanced to AfterTimedSignalStep and completed
    new WorkflowOrchestrator(instanceId).execute(null);

    inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assertEquals('"signaled"', inst.Output__c);

    // Assert no fallback step exec was ever created
    List<Workflow_Step_Execution__c> fallbackExecs = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.TimeoutFallbackStep'
    ];
    System.assertEquals(
      0,
      fallbackExecs.size(),
      'No fallback exec should exist when signal wins'
    );

    // Run the watchdog — confirm it does NOT mis-route (timer is cleared)
    WorkflowEngine.processWatchdogHeartbeat();

    List<Workflow_Step_Execution__c> fallbackExecsAfterWatchdog = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.TimeoutFallbackStep'
    ];
    System.assertEquals(
      0,
      fallbackExecsAfterWatchdog.size(),
      'Watchdog must not create fallback exec after signal wins'
    );
  }

  @isTest
  static void testTimedSuspend_LateSignalAfterTimeout_IsNoOp() {
    WorkflowEngine.disableQueueableInTest = true;
    capturedIsTimeoutResume = null;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.TimedSuspendWorkflow',
      'TimedSuspendLateKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);

    // Force timeout to fire
    Workflow_Instance__c inst = [
      SELECT Id, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    inst.Sleep_Until__c = DateTime.now().addSeconds(-10);
    update as system inst;
    WorkflowEngine.processWatchdogHeartbeat();

    // Run the fallback step to terminal
    new WorkflowOrchestrator(instanceId).execute(null);

    inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assertEquals('"timedout"', inst.Output__c);

    // Deliver the late signal — should be a no-op (captured as Unrouted)
    WorkflowEngine.signal('TimedSuspendLateKey', 'Resume', '{}');

    // Instance must not change
    inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'Completed',
      inst.Status__c,
      'Instance must stay Completed after late signal'
    );
    System.assertEquals('"timedout"', inst.Output__c);

    // The late signal is captured as Unrouted. An Unrouted capture has no active
    // instance to link to, so it is keyed by Correlation_Key__c with a null
    // Workflow_Instance__c — query by the correlation key, not the instance id.
    List<Workflow_Signal__c> unroutedSignals = [
      SELECT Status__c
      FROM Workflow_Signal__c
      WHERE
        Correlation_Key__c = 'TimedSuspendLateKey'
        AND Signal_Name__c = 'Resume'
        AND Status__c = 'Unrouted'
    ];
    System.assertEquals(
      1,
      unroutedSignals.size(),
      'Late signal should be captured as Unrouted'
    );
  }

  @isTest
  static void testTimedWait_BackCompat_UntimedOverloadsUnchanged() {
    WorkflowEngine.disableQueueableInTest = true;

    // Untimed suspend should leave Sleep_Until__c null
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SuspendingWorkflow',
      'BackCompatSuspendKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c inst = [
      SELECT Status__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', inst.Status__c);
    System.assertEquals(
      null,
      inst.Sleep_Until__c,
      'Untimed suspend must NOT arm a timer'
    );

    // Untimed waitForApproval should leave Sleep_Until__c null
    Id approvalInstanceId = WorkflowEngine.start(
      'WorkflowEngineTest.ApprovalWorkflow',
      'BackCompatApprovalKey',
      null
    );
    new WorkflowOrchestrator(approvalInstanceId).execute(null);

    Workflow_Instance__c approvalInst = [
      SELECT Status__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :approvalInstanceId
    ];
    System.assertEquals('Suspended', approvalInst.Status__c);
    System.assertEquals(
      null,
      approvalInst.Sleep_Until__c,
      'Untimed waitForApproval must NOT arm a timer'
    );
  }

  @isTest
  static void testTimedApproval_TimeoutWins() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.TimedApprovalWorkflow',
      'TimedApprovalKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c inst = [
      SELECT Status__c, Current_Step__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', inst.Status__c);
    System.assertNotEquals(
      null,
      inst.Sleep_Until__c,
      'Timed approval should arm a timer'
    );

    // Verify approval state JSON includes both existing keys and $timeoutStep
    Workflow_Step_Execution__c waitExec = [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.TimedApprovalStep'
      LIMIT 1
    ];
    System.assertEquals('Pending', waitExec.Status__c);
    System.assert(
      waitExec.Output__c.contains('"waitingForApproval":true'),
      'Should retain waitingForApproval key'
    );
    System.assert(
      waitExec.Output__c.contains('"approvalKey":"TimedApproval"'),
      'Should retain approvalKey'
    );
    System.assert(
      waitExec.Output__c.contains('"approvalRole":"Manager"'),
      'Should retain approvalRole'
    );
    System.assert(
      waitExec.Output__c.contains('"$timeoutStep"') &&
      waitExec.Output__c.contains(
        'WorkflowEngineTest.ApprovalTimeoutFallbackStep'
      ),
      'Should contain $timeoutStep: ' + waitExec.Output__c
    );

    // Fire the deadline
    inst.Sleep_Until__c = DateTime.now().addSeconds(-10);
    update as system inst;
    WorkflowEngine.processWatchdogHeartbeat();

    inst = [
      SELECT Status__c, Current_Step__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Running', inst.Status__c);
    System.assertEquals(
      'WorkflowEngineTest.ApprovalTimeoutFallbackStep',
      inst.Current_Step__c
    );
    System.assertEquals(null, inst.Sleep_Until__c);

    // Run the fallback step to completion
    new WorkflowOrchestrator(instanceId).execute(null);

    inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assertEquals('"approval_timedout"', inst.Output__c);
  }

  @isTest
  static void testTimedSuspend_ManualResumeDisarmsTimer() {
    // A manual resumeInstance() of an armed timed-wait must disarm Sleep_Until__c
    // (issue #35) so the watchdog does not later mis-route to the fallback step.
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.TimedSuspendWorkflow',
      'TimedSuspendResumeKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);

    // Timer is armed by the timed suspend
    Workflow_Instance__c inst = [
      SELECT Status__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Suspended', inst.Status__c);
    System.assertNotEquals(null, inst.Sleep_Until__c, 'Timer should be armed');

    // Manual resume (not via signal) must disarm the timer
    WorkflowEngine.resumeInstance(instanceId, '{}');

    inst = [
      SELECT Status__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'Running',
      inst.Status__c,
      'Should be Running after resume'
    );
    System.assertEquals(
      null,
      inst.Sleep_Until__c,
      'Manual resume must disarm the timed-wait timer (Sleep_Until__c must be null)'
    );

    // Watchdog must not mis-route to the fallback after a manual resume disarm
    WorkflowEngine.processWatchdogHeartbeat();
    List<Workflow_Step_Execution__c> fallbackExecs = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.TimeoutFallbackStep'
    ];
    System.assertEquals(
      0,
      fallbackExecs.size(),
      'Watchdog must not create a fallback exec after a manual resume wins'
    );
  }

  @isTest
  static void testManualCompensationValidation() {
    // 1. Create a non-completed instance and check it fails validation
    Workflow_Instance__c inst1 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Running'
    );
    insert inst1;

    try {
      WorkflowEngine.compensate(inst1.Id);
      System.assert(
        false,
        'Should have thrown exception for non-completed status'
      );
    } catch (Exception ex) {
      System.assert(
        ex.getMessage().contains('Only Completed'),
        'Expected "Only Completed" error message: ' + ex.getMessage()
      );
    }

    // 2. Create a completed instance without compensation stack
    Workflow_Instance__c inst2 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Completed',
      Compensation_Stack__c = null
    );
    insert inst2;

    try {
      WorkflowEngine.compensate(inst2.Id);
      System.assert(false, 'Should have thrown exception for missing stack');
    } catch (Exception ex) {
      System.assert(
        ex.getMessage().contains('No compensation stack found'),
        'Expected "No compensation stack found" error message: ' +
        ex.getMessage()
      );
    }
  }

  @isTest
  static void testManualCompensationHappyPath() {
    WorkflowEngine.disableQueueableInTest = true;

    // Create a target Completed workflow instance with compensation stack
    Workflow_Instance__c target = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Completed',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{
          'WorkflowEngineTest.NonCompensatableStep',
          'WorkflowEngineTest.CompensatableHappyStep'
        }
      ),
      Correlation_Key__c = 'TestKey_Comp',
      Input__c = '{"key": "val"}'
    );
    insert target;

    // Create the original completed step execution for the compensatable step so the compensation context can resolve it
    Workflow_Step_Execution__c origExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = target.Id,
      Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep',
      Status__c = 'Completed',
      Input__c = '{"stepInput": 1}',
      Output__c = '{"stepOutput": 2}'
    );
    insert origExec;

    Test.startTest();
    Id compensatingId = WorkflowEngine.compensate(target.Id);
    Test.stopTest();

    System.assertNotEquals(
      null,
      compensatingId,
      'Compensating run ID should be returned'
    );

    // Verify original target instance is linked to the new compensating instance
    Workflow_Instance__c targetReload = [
      SELECT Compensated_By__c, Status__c
      FROM Workflow_Instance__c
      WHERE Id = :target.Id
    ];
    System.assertEquals(
      compensatingId,
      targetReload.Compensated_By__c,
      'Compensated_By__c should link to compensating run'
    );
    System.assertEquals(
      'Completed',
      targetReload.Status__c,
      'Original instance status must stay Completed'
    );

    // Verify the new compensating instance details
    Workflow_Instance__c compInst = [
      SELECT
        Status__c,
        Previous_Instance__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Id = :compensatingId
    ];
    System.assertEquals(
      'Compensating',
      compInst.Status__c,
      'New run status must start as Compensating'
    );
    System.assertEquals(
      target.Id,
      compInst.Previous_Instance__c,
      'Previous_Instance__c should link to the original target run'
    );
    System.assertEquals(
      target.Correlation_Key__c,
      compInst.Correlation_Key__c,
      'Correlation key should carry forward'
    );
    System.assertEquals(
      target.Correlation_Key__c,
      compInst.Root_Correlation_Key__c,
      'Root correlation key should carry forward'
    );
    System.assertEquals(
      target.Compensation_Stack__c,
      compInst.Compensation_Stack__c,
      'Compensation stack should be copied'
    );

    // Drive the compensation execution
    WorkflowEngine.runStep(compensatingId, null); // Runs CompensatableHappyStep
    WorkflowEngine.runStep(compensatingId, null); // Runs NonCompensatableStep (skipped)
    WorkflowEngine.runStep(compensatingId, null); // Stack empty -> transition status to Compensated

    compInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :compensatingId
    ];
    System.assertEquals(
      'Compensated',
      compInst.Status__c,
      'Spawned compensating run should end in Compensated status'
    );

    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Step_Name__c, Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :compensatingId
      ORDER BY CreatedDate ASC, Id ASC
    ];
    System.assertEquals(
      2,
      stepExecs.size(),
      'Should have created step execution logs on compensating run'
    );
    System.assertEquals(
      'WorkflowEngineTest.CompensatableHappyStep_Compensate',
      stepExecs[0].Step_Name__c
    );
    System.assertEquals('Compensated', stepExecs[0].Status__c);
    System.assertEquals('"Compensated"', stepExecs[0].Output__c);
  }

  // ==========================================
  // RETRY ATTEMPT EXPOSE TESTS
  // ==========================================

  public static List<Map<String, Object>> observedAttemptStates = new List<Map<String, Object>>();

  public class RetryExposeWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.RetryExposeStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.RetryExposeStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class RetryExposeStep implements WorkflowStep, RetryConfigurable {
    public StepResult execute(StepContext ctx) {
      observedAttemptStates.add(
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

  public static List<Map<String, Object>> dynamicObservedStates = new List<Map<String, Object>>();

  public class DynamicRetryWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.DynamicRetryStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.DynamicRetryStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class DynamicRetryStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      dynamicObservedStates.add(
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

  public static List<Map<String, Object>> compensationObservedStates = new List<Map<String, Object>>();

  public class CompensatableRetryWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.CompensatableRetryStep',
        'WorkflowEngineTest.AlwaysFailStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.CompensatableRetryStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'WorkflowEngineTest.CompensatableRetryStep') {
        return 'WorkflowEngineTest.AlwaysFailStep';
      }
      return null;
    }
  }

  public class CompensatableRetryStep implements CompensatableStep, RetryConfigurable {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'Success');
    }

    public StepResult compensate(StepContext ctx) {
      compensationObservedStates.add(
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

  public class AlwaysFailStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.fail('Forced fail to trigger compensation');
    }
  }

  public static List<Map<String, Object>> loopObservedStates = new List<Map<String, Object>>();
  public static Integer loopCounter = 0;

  public class LoopExposeWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.LoopExposeStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.LoopExposeStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return stepResult.nextStepName;
    }
  }

  public class LoopExposeStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      loopObservedStates.add(
        new Map<String, Object>{
          'attempt' => ctx.attempt,
          'maxAttempts' => ctx.maxAttempts
        }
      );
      loopCounter++;
      if (loopCounter == 1) {
        return StepResult.retry(new RetryPolicy(1, (Double) 1.0, 2));
      } else if (loopCounter == 2) {
        return StepResult.complete(
          'WorkflowEngineTest.LoopExposeStep',
          'TransitionSelf'
        );
      }
      return StepResult.complete(null, 'LoopFinished');
    }
  }

  @isTest
  static void testRetryAttemptProgressionAndFallback() {
    observedAttemptStates.clear();
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.RetryExposeWorkflow',
      'ExposeKey',
      null
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);
    System.assertEquals(3, observedAttemptStates.size());

    // Attempt 1
    System.assertEquals(1, observedAttemptStates[0].get('attempt'));
    System.assertEquals(3, observedAttemptStates[0].get('maxAttempts'));
    System.assertEquals(false, observedAttemptStates[0].get('isFinalAttempt'));

    // Attempt 2
    System.assertEquals(2, observedAttemptStates[1].get('attempt'));
    System.assertEquals(3, observedAttemptStates[1].get('maxAttempts'));
    System.assertEquals(false, observedAttemptStates[1].get('isFinalAttempt'));

    // Attempt 3 (Final attempt)
    System.assertEquals(3, observedAttemptStates[2].get('attempt'));
    System.assertEquals(3, observedAttemptStates[2].get('maxAttempts'));
    System.assertEquals(true, observedAttemptStates[2].get('isFinalAttempt'));

    // Verify persisted Retry Count agrees (2 retries performed before completing)
    Workflow_Step_Execution__c step = [
      SELECT Retry_Count__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      LIMIT 1
    ];
    System.assertEquals('Completed', step.Status__c);
    System.assertEquals(
      2,
      step.Retry_Count__c,
      'Persisted Retry Count must be 2 (0-based retry count)'
    );
  }

  @isTest
  static void testDynamicRetryAttemptProgression() {
    dynamicObservedStates.clear();
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.DynamicRetryWorkflow',
      'DynamicKey',
      null
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);
    System.assertEquals(3, dynamicObservedStates.size());

    // Attempt 1 (No policy resolved yet -> defaults to 1)
    System.assertEquals(1, dynamicObservedStates[0].get('attempt'));
    System.assertEquals(1, dynamicObservedStates[0].get('maxAttempts'));

    // Attempt 2 (Policy was resolved on attempt 1 -> loaded from Captured_Values__c)
    System.assertEquals(2, dynamicObservedStates[1].get('attempt'));
    System.assertEquals(3, dynamicObservedStates[1].get('maxAttempts'));

    // Attempt 3 (Policy was resolved on attempt 2 -> loaded from Captured_Values__c)
    System.assertEquals(3, dynamicObservedStates[2].get('attempt'));
    System.assertEquals(3, dynamicObservedStates[2].get('maxAttempts'));
  }

  @isTest
  static void testCompensationRetryAttemptProgression() {
    compensationObservedStates.clear();
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.CompensatableRetryWorkflow',
      'CompensateRetryKey',
      null
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('Compensated', result.status);
    System.assertEquals(2, compensationObservedStates.size());

    // Compensation Attempt 1
    System.assertEquals(1, compensationObservedStates[0].get('attempt'));
    System.assertEquals(2, compensationObservedStates[0].get('maxAttempts'));
    System.assertEquals(
      false,
      compensationObservedStates[0].get('isFinalAttempt')
    );

    // Compensation Attempt 2 (Final attempt)
    System.assertEquals(2, compensationObservedStates[1].get('attempt'));
    System.assertEquals(2, compensationObservedStates[1].get('maxAttempts'));
    System.assertEquals(
      true,
      compensationObservedStates[1].get('isFinalAttempt')
    );
  }

  @isTest
  static void testRetryAttemptResetOnFreshVisit() {
    loopObservedStates.clear();
    loopCounter = 0;
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.LoopExposeWorkflow',
      'LoopKey',
      null
    );
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);
    System.assertEquals(3, loopObservedStates.size());

    // First visit: attempt 1
    System.assertEquals(1, loopObservedStates[0].get('attempt'));

    // First visit: attempt 2 (retry)
    System.assertEquals(2, loopObservedStates[1].get('attempt'));

    // Second visit: resets to attempt 1
    System.assertEquals(1, loopObservedStates[2].get('attempt'));
  }

  public class ProgressWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.ProgressStep1',
        'WorkflowEngineTest.ProgressStep2'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.ProgressStep1';
    }
    public String getNextStep(String currentStepName, StepResult sr) {
      if (currentStepName == 'WorkflowEngineTest.ProgressStep1') {
        if (sr.action == StepResult.ActionType.YIELD) {
          return 'WorkflowEngineTest.ProgressStep1';
        }
        return 'WorkflowEngineTest.ProgressStep2';
      }
      return null;
    }
  }

  public class ProgressStep1 implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (String.isBlank(ctx.stepStateJson)) {
        ctx.reportProgress(20.0, 'Step 1: Yielding first');
        return StepResult.yield('{"yieldedOnce": true}');
      }
      ctx.reportProgress(50.0, 'Step 1: Done');
      return StepResult.complete('WorkflowEngineTest.ProgressStep2', 'Output1');
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

  @isTest
  static void testProgressReportingEndToEnd() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.ProgressWorkflow',
      'ProgressKey',
      'InitialInput'
    );

    // 1. Run first step execution -> Should Yield and save progress (20%, Step 1: Yielding first)
    new WorkflowOrchestrator(instanceId).execute(null);
    Workflow_Instance__c inst1 = [
      SELECT Status__c, Progress__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Running', inst1.Status__c);
    System.assertNotEquals(null, inst1.Progress__c);
    Map<String, Object> progress1 = (Map<String, Object>) JSON.deserializeUntyped(
      inst1.Progress__c
    );
    System.assertEquals(20.0, (Decimal) progress1.get('percentComplete'));
    System.assertEquals(
      'Step 1: Yielding first',
      (String) progress1.get('message')
    );

    // 2. Run next step execution -> Should Complete Step 1 and update progress (50%, Step 1: Done)
    new WorkflowOrchestrator(instanceId).execute(null);
    Workflow_Instance__c inst2 = [
      SELECT Status__c, Progress__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Running', inst2.Status__c);
    Map<String, Object> progress2 = (Map<String, Object>) JSON.deserializeUntyped(
      inst2.Progress__c
    );
    System.assertEquals(50.0, (Decimal) progress2.get('percentComplete'));
    System.assertEquals('Step 1: Done', (String) progress2.get('message'));

    // 3. Run Step 2 execution -> Should ContinueAsNew and set progress (stage: Step 2 final, percent: 90%)
    new WorkflowOrchestrator(instanceId).execute(null);
    Workflow_Instance__c inst3 = [
      SELECT Status__c, Progress__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('ContinuedAsNew', inst3.Status__c);
    Map<String, Object> progress3 = (Map<String, Object>) JSON.deserializeUntyped(
      inst3.Progress__c
    );
    System.assertEquals(90.0, (Decimal) progress3.get('percent'));
    System.assertEquals('Step 2 final', (String) progress3.get('stage'));

    // Find successor run and verify progress carried forward
    Workflow_Instance__c successor = [
      SELECT Id, Status__c, Progress__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :instanceId
    ];
    System.assertEquals('Pending', successor.Status__c);
    System.assertNotEquals(null, successor.Progress__c);
    Map<String, Object> progressSucc = (Map<String, Object>) JSON.deserializeUntyped(
      successor.Progress__c
    );
    System.assertEquals(90.0, (Decimal) progressSucc.get('percent'));

    // 4. Run successor (first run) -> runs ProgressStep1 (first yield)
    new WorkflowOrchestrator(successor.Id).execute(null);
    Workflow_Instance__c finalInst1 = [
      SELECT Status__c, Progress__c
      FROM Workflow_Instance__c
      WHERE Id = :successor.Id
    ];
    System.assertEquals('Running', finalInst1.Status__c);
    Map<String, Object> progressFinal1 = (Map<String, Object>) JSON.deserializeUntyped(
      finalInst1.Progress__c
    );
    System.assertEquals(20.0, (Decimal) progressFinal1.get('percentComplete'));

    // 5. Run successor (second run) -> completes ProgressStep1
    new WorkflowOrchestrator(successor.Id).execute(null);
    Workflow_Instance__c finalInst2 = [
      SELECT Status__c, Progress__c
      FROM Workflow_Instance__c
      WHERE Id = :successor.Id
    ];
    System.assertEquals('Running', finalInst2.Status__c);
    Map<String, Object> progressFinal2 = (Map<String, Object>) JSON.deserializeUntyped(
      finalInst2.Progress__c
    );
    System.assertEquals(50.0, (Decimal) progressFinal2.get('percentComplete'));

    // 6. Run successor (third run) -> runs ProgressStep2 and completes
    new WorkflowOrchestrator(successor.Id).execute(null);
    Workflow_Instance__c finalInst = [
      SELECT Status__c, Progress__c
      FROM Workflow_Instance__c
      WHERE Id = :successor.Id
    ];
    System.assertEquals('Completed', finalInst.Status__c);
    Map<String, Object> progressFinal = (Map<String, Object>) JSON.deserializeUntyped(
      finalInst.Progress__c
    );
    System.assertEquals(100.0, (Decimal) progressFinal.get('percentComplete'));
    System.assertEquals(
      'Workflow Complete',
      (String) progressFinal.get('message')
    );
  }

  @isTest
  static void testTelemetryCapturedOnTransitions() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'TelemetryKey',
      'InitialInput'
    );

    new WorkflowOrchestrator(instanceId).execute(null);

    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Status__c, CPU_Time_Ms__c, SOQL_Query_Count__c, Heap_Size_Bytes__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      ORDER BY CreatedDate ASC
    ];

    System.assert(!stepExecs.isEmpty(), 'Should have recorded step executions');
    for (Workflow_Step_Execution__c step : stepExecs) {
      if (step.Status__c == 'Completed') {
        System.assertNotEquals(
          null,
          step.CPU_Time_Ms__c,
          'CPU time telemetry should be captured'
        );
        System.assertNotEquals(
          null,
          step.SOQL_Query_Count__c,
          'SOQL queries telemetry should be captured'
        );
        System.assertNotEquals(
          null,
          step.Heap_Size_Bytes__c,
          'Heap size telemetry should be captured'
        );
        System.assert(
          step.CPU_Time_Ms__c >= 0,
          'CPU time should be non-negative'
        );
        System.assert(
          step.SOQL_Query_Count__c >= 0,
          'SOQL query count should be non-negative'
        );
        System.assert(
          step.Heap_Size_Bytes__c >= 0,
          'Heap size should be non-negative'
        );
      }
    }
  }

  @isTest
  static void testTelemetryOnPendingAndCrash() {
    WorkflowEngine.disableQueueableInTest = true;

    // Start a sleeping workflow to verify telemetry is populated on Pending status (sleep/suspension)
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SleepingWorkflow',
      'TelemetrySleepKey',
      'InitialInput'
    );
    new WorkflowOrchestrator(instanceId).execute(null);

    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Status__c, CPU_Time_Ms__c, SOQL_Query_Count__c, Heap_Size_Bytes__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
      ORDER BY CreatedDate ASC
    ];
    System.assert(!stepExecs.isEmpty(), 'Should have recorded step executions');
    Boolean foundPending = false;
    for (Workflow_Step_Execution__c step : stepExecs) {
      if (step.Status__c == 'Pending') {
        foundPending = true;
        System.assertNotEquals(
          null,
          step.CPU_Time_Ms__c,
          'CPU time telemetry should be captured on Pending/sleep status'
        );
        System.assertNotEquals(
          null,
          step.SOQL_Query_Count__c,
          'SOQL queries telemetry should be captured on Pending/sleep status'
        );
        System.assertNotEquals(
          null,
          step.Heap_Size_Bytes__c,
          'Heap size telemetry should be captured on Pending/sleep status'
        );
      }
    }
    System.assert(
      foundPending,
      'Should have found a Pending step execution for sleep'
    );

    // Trigger handleCrash to verify telemetry is cleared/skipped during crashes
    WorkflowEngine.handleCrash(
      instanceId,
      'WorkflowEngineTest.SleepingStep',
      new WorkflowEngine.WorkflowException('Test Exception')
    );
    List<Workflow_Step_Execution__c> crashedExecs = [
      SELECT Status__c, CPU_Time_Ms__c, SOQL_Query_Count__c, Heap_Size_Bytes__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Failed'
      ORDER BY CreatedDate DESC
      LIMIT 1
    ];
    System.assert(
      !crashedExecs.isEmpty(),
      'Should have recorded failed step execution from handleCrash'
    );
    Workflow_Step_Execution__c failedStep = crashedExecs[0];
    System.assertEquals(
      null,
      failedStep.CPU_Time_Ms__c,
      'CPU time telemetry should be null on crash'
    );
    System.assertEquals(
      null,
      failedStep.SOQL_Query_Count__c,
      'SOQL queries telemetry should be null on crash'
    );
    System.assertEquals(
      null,
      failedStep.Heap_Size_Bytes__c,
      'Heap size telemetry should be null on crash'
    );
  }

  @isTest
  static void testParentChildWorkflowReentrancy() {
    WorkflowEngine.disableQueueableInTest = true;

    Id parentId = WorkflowEngine.start(
      'WorkflowEngineTest.ParentWorkflow',
      'ParentKey_Reentry',
      null
    );
    // Runs ParentStep once: returns startChild which sets status to Suspended and calls startChildWorkflow
    new WorkflowOrchestrator(parentId).execute(null);

    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :parentId
      ],
      'Exactly one child must exist after the first launcher run'
    );

    // Now, run the parent step again (re-entrant hop)
    // ParentStep will run execute() again. Since no ChildCompleted:SubKey signal exists,
    // it will call StepResult.startChild() again with correlationKey = 'SubKey'.
    // The engine must handle this idempotently (return early from startChildWorkflow, no exception, no duplicate child).
    try {
      new WorkflowOrchestrator(parentId).execute(null);
    } catch (Exception ex) {
      System.assert(
        false,
        'Should not throw an exception on re-entrant startChild: ' +
        ex.getMessage()
      );
    }

    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :parentId
      ],
      'Re-entry must NOT start a duplicate child'
    );

    Workflow_Instance__c parentInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    System.assertEquals(
      'Suspended',
      parentInst.Status__c,
      'Parent must remain Suspended'
    );

    // Set parent instance status to Failed so its automatically-triggered post-test queueable runs as a no-op
    update as system new Workflow_Instance__c(
      Id = parentId,
      Status__c = 'Failed'
    );
  }

  @isTest
  static void testParentChildWorkflowForeignCollision() {
    WorkflowEngine.disableQueueableInTest = true;

    Id parentIdA = WorkflowEngine.start(
      'WorkflowEngineTest.ParentWorkflow',
      'ParentKey_A',
      null
    );
    new WorkflowOrchestrator(parentIdA).execute(null);

    Id parentIdB = WorkflowEngine.start(
      'WorkflowEngineTest.ParentWorkflow',
      'ParentKey_B',
      null
    );

    // Executing ParentStep for parentIdB will return StepResult.startChild with key 'SubKey'.
    // Since 'SubKey' is already active and belongs to parentIdA, this must throw a WorkflowException.
    try {
      new WorkflowOrchestrator(parentIdB).execute(null);
      System.assert(
        false,
        'Should have thrown WorkflowException on foreign correlation key collision'
      );
    } catch (WorkflowEngine.WorkflowException ex) {
      System.assert(
        ex.getMessage()
          .contains(
            'An active workflow already exists with correlation key: SubKey'
          ),
        'Expected duplicate correlation key message, got: ' + ex.getMessage()
      );
    } catch (Exception ex) {
      System.assert(
        false,
        'Expected WorkflowException, got: ' +
          ex.getTypeName() +
          ': ' +
          ex.getMessage()
      );
    }

    // Set parent instances status to Failed so their automatically-triggered post-test queueables run as no-ops
    update as system new List<Workflow_Instance__c>{
      new Workflow_Instance__c(Id = parentIdA, Status__c = 'Failed'),
      new Workflow_Instance__c(Id = parentIdB, Status__c = 'Failed')
    };
  }

  @isTest
  static void testParentChildWorkflowReentrancyWithPausedChild() {
    WorkflowEngine.disableQueueableInTest = true;

    Id parentId = WorkflowEngine.start(
      'WorkflowEngineTest.ParentWorkflow',
      'ParentKey_Reentry_Paused',
      null
    );
    new WorkflowOrchestrator(parentId).execute(null);

    // Locate child and pause it manually
    Workflow_Instance__c child = [
      SELECT Id, Status__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :parentId
      LIMIT 1
    ];
    child.Status__c = 'Paused';
    update as system child;

    // Execute parent re-entrant hop
    try {
      new WorkflowOrchestrator(parentId).execute(null);
    } catch (Exception ex) {
      System.assert(
        false,
        'Should not throw on re-entrant startChild with paused child: ' +
        ex.getMessage()
      );
    }

    // Verify parent remains Suspended
    Workflow_Instance__c parentInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    System.assertEquals('Suspended', parentInst.Status__c);

    // Set parent instance status to Failed so its automatically-triggered post-test queueable runs as a no-op
    update as system new Workflow_Instance__c(
      Id = parentId,
      Status__c = 'Failed'
    );
  }

  // ==========================================
  // RESUME PAST STEP TEST CLASSES
  // ==========================================

  public class SkipTestWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.SkipTestStep1',
        'WorkflowEngineTest.SkipTestStep2',
        'WorkflowEngineTest.SkipTestStep3'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.SkipTestStep1';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'WorkflowEngineTest.SkipTestStep1') {
        return 'WorkflowEngineTest.SkipTestStep2';
      }
      if (currentStepName == 'WorkflowEngineTest.SkipTestStep2') {
        return 'WorkflowEngineTest.SkipTestStep3';
      }
      return null;
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

  public class SkipTestStep3 implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Map<String, Object> outputMap = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.previousStepOutput
      );
      String val = (String) outputMap.get('overrideVal');
      return StepResult.complete(null, 'StepThreeReceived_' + val);
    }
  }

  public class SkipParallelWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.SkipParallelSplitStep',
        'WorkflowEngineTest.SkipParallelA',
        'WorkflowEngineTest.SkipParallelB',
        'WorkflowEngineTest.SkipParallelJoinStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.SkipParallelSplitStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'WorkflowEngineTest.SkipParallelSplitStep') {
        return 'WorkflowEngineTest.SkipParallelJoinStep';
      }
      return null;
    }
  }

  public class SkipParallelSplitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowEngineTest.SkipParallelA',
          'WorkflowEngineTest.SkipParallelB'
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
      String outA = (String) outputs.get('WorkflowEngineTest.SkipParallelA');
      Map<String, Object> outBMap = (Map<String, Object>) outputs.get(
        'WorkflowEngineTest.SkipParallelB'
      );
      String valB = (String) outBMap.get('val');
      return StepResult.complete(null, 'Join_' + outA + '_' + valB);
    }
  }

  @isTest
  static void testResumePastStepSuccess() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SkipTestWorkflow',
      'SkipSerialKey',
      'InitialInput'
    );

    // 1. Run step 1 (SkipTestStep1) -> should complete and transition current step to SkipTestStep2
    new WorkflowOrchestrator(instanceId).execute(null);
    Workflow_Instance__c inst1 = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Running', inst1.Status__c);
    System.assertEquals(
      'WorkflowEngineTest.SkipTestStep2',
      inst1.Current_Step__c
    );

    // 2. Run step 2 (SkipTestStep2) -> throws exception, transitions instance to Failed
    new WorkflowOrchestrator(instanceId).execute(null);
    Workflow_Instance__c inst2 = [
      SELECT Status__c, Current_Step__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', inst2.Status__c);
    System.assertEquals(
      'WorkflowEngineTest.SkipTestStep2',
      inst2.Current_Step__c
    );

    // 3. Skip Step 2 by supplying JSON output output
    Test.startTest();
    WorkflowEngine.resumePastStep(
      instanceId,
      'WorkflowEngineTest.SkipTestStep2',
      '{"overrideVal": "skippedOutput"}'
    );
    Test.stopTest();

    // 4. Verify step 2 execution is recorded as OperatorSkipped
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.SkipTestStep2'
      ORDER BY CreatedDate DESC, Id DESC
    ];
    // There should be 2 execs: the failed one and the OperatorSkipped one
    System.assertEquals(2, stepExecs.size());
    System.assertEquals('OperatorSkipped', stepExecs[0].Status__c);
    System.assertEquals(
      '{"overrideVal": "skippedOutput"}',
      stepExecs[0].Output__c
    );

    // Verify operator intervention log was recorded
    List<Workflow_Log__c> logs = [
      SELECT Log_Type__c, Message__c
      FROM Workflow_Log__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Log_Type__c = 'OperatorIntervention'
    ];
    System.assertEquals(1, logs.size());
    System.assert(
      logs[0]
        .Message__c.contains('skipped step WorkflowEngineTest.SkipTestStep2')
    );

    // 5. Run next step execution (should resume from SkipTestStep3 because WorkflowEngine.resumePastStep enqueued it)
    Workflow_Instance__c finalInst = [
      SELECT Status__c, Output__c, Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', finalInst.Status__c);
    System.assertEquals(
      '"StepThreeReceived_skippedOutput"',
      finalInst.Output__c
    );

    // Check that the skipped step was NOT added to the compensation stack
    Boolean isStackEmpty =
      String.isBlank(finalInst.Compensation_Stack__c) ||
      ((List<String>) JSON.deserialize(
          finalInst.Compensation_Stack__c,
          List<String>.class
        ))
        .isEmpty();
    System.assert(
      isStackEmpty,
      'Compensation stack should be empty because SkipTestStep2 was skipped'
    );
  }

  @isTest
  static void testResumePastStepParallelSuccess() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SkipParallelWorkflow',
      'SkipParallelKey',
      'InitialInput'
    );

    // 1. Run split step (SkipParallelSplitStep) -> should create parallel executions
    new WorkflowOrchestrator(instanceId).execute(null);
    Workflow_Instance__c inst1 = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Running', inst1.Status__c);
    System.assert(
      inst1.Current_Step__c.contains('WorkflowEngineTest.SkipParallelA')
    );
    System.assert(
      inst1.Current_Step__c.contains('WorkflowEngineTest.SkipParallelB')
    );

    // 2. Run ParallelA -> completes successfully
    new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.SkipParallelA')
      .execute(null);

    // 3. Run ParallelB -> fails and fails the workflow instance
    new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.SkipParallelB')
      .execute(null);

    Workflow_Instance__c inst2 = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', inst2.Status__c);

    // 4. Resume past ParallelB
    Test.startTest();
    WorkflowEngine.resumePastStep(
      instanceId,
      'WorkflowEngineTest.SkipParallelB',
      '{"val": "skippedParallelB"}'
    );
    Test.stopTest();

    // 5. Verify workflow finishes successfully after join step runs
    Workflow_Instance__c finalInst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', finalInst.Status__c);
    System.assertEquals('"Join_OutputA_skippedParallelB"', finalInst.Output__c);
  }

  @isTest
  static void testResumePastStepParallelPreservesSleeping() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SkipParallelWorkflow',
      'SkipParallelSleepKey',
      'InitialInput'
    );

    // 1. Run split step (SkipParallelSplitStep) -> should create parallel executions
    new WorkflowOrchestrator(instanceId).execute(null);

    // 2. Put SkipParallelA in a Pending state simulation
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Status__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.SkipParallelA'
    ];
    System.assertEquals(1, stepExecs.size());
    stepExecs[0].Status__c = 'Pending';
    stepExecs[0].Retry_Count__c = 3;
    stepExecs[0].CPU_Time_Ms__c = 1;
    update stepExecs[0];

    // 3. Run ParallelB -> fails and fails the workflow instance
    new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.SkipParallelB')
      .execute(null);

    Workflow_Instance__c inst2 = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', inst2.Status__c);

    // Count existing queueable jobs
    Integer jobsBefore = [
      SELECT COUNT()
      FROM AsyncApexJob
      WHERE JobType = 'Queueable'
    ];

    // 4. Resume past ParallelB
    Test.startTest();
    WorkflowEngine.resumePastStep(
      instanceId,
      'WorkflowEngineTest.SkipParallelB',
      '{"val": "skippedParallelB"}'
    );
    Test.stopTest();

    // Verify that SkipParallelA's execution remains Pending and was NOT reset (retry count is still 3, not reset to 0)
    Workflow_Step_Execution__c stepAAfter = [
      SELECT Status__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepExecs[0].Id
    ];
    System.assertEquals('Pending', stepAAfter.Status__c);
    System.assertEquals(3, stepAAfter.Retry_Count__c);

    // Verify that the parent instance transitioned to Suspended (since branch A is still parked)
    Workflow_Instance__c instAfter = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'Suspended',
      instAfter.Status__c,
      'Parent instance should stay Suspended when a sibling branch is parked'
    );

    // Verify that NO new job was enqueued
    Integer jobsAfter = [
      SELECT COUNT()
      FROM AsyncApexJob
      WHERE JobType = 'Queueable'
    ];
    System.assertEquals(
      jobsBefore,
      jobsAfter,
      'No new queueable jobs should have been enqueued for the sleeping branch'
    );
  }

  @isTest
  static void testResumePastStepParallelSignalSkippedIsNoop() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SkipParallelWorkflow',
      'SkipParallelSignalKey',
      'InitialInput'
    );

    // 1. Run split step (SkipParallelSplitStep) -> should create parallel executions
    new WorkflowOrchestrator(instanceId).execute(null);

    // 2. Run ParallelB -> fails and fails the workflow instance
    new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.SkipParallelB')
      .execute(null);

    // 3. Resume past ParallelB (sets it to OperatorSkipped)
    WorkflowEngine.resumePastStep(
      instanceId,
      'WorkflowEngineTest.SkipParallelB',
      '{"val": "skippedParallelB"}'
    );

    // 4. Try executing runStep directly on the skipped step ParallelB (simulating a signal or duplicate orchestrator run)
    WorkflowEngine.runStep(instanceId, 'WorkflowEngineTest.SkipParallelB');

    // Verify status remains OperatorSkipped
    List<Workflow_Step_Execution__c> stepsAfter = [
      SELECT Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.SkipParallelB'
      ORDER BY CreatedDate DESC, Id DESC
    ];
    System.assertEquals(
      'OperatorSkipped',
      stepsAfter[0].Status__c,
      'Bypassed step should not be re-run'
    );
  }

  @isTest
  static void testResumePastStepCaseInsensitivity() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SkipTestWorkflow',
      'SkipCaseInsensitivityKey',
      'InitialInput'
    );

    // 1. Run step 1 (SkipTestStep1) -> should complete and transition current step to SkipTestStep2
    new WorkflowOrchestrator(instanceId).execute(null);

    // 2. Run step 2 (SkipTestStep2) -> throws exception, transitions instance to Failed
    new WorkflowOrchestrator(instanceId).execute(null);
    Workflow_Instance__c inst2 = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', inst2.Status__c);
    System.assertEquals(
      'WorkflowEngineTest.SkipTestStep2',
      inst2.Current_Step__c
    );

    // 3. Skip Step 2 by supplying JSON output with lowercase casing
    Test.startTest();
    WorkflowEngine.resumePastStep(
      instanceId,
      'workflowenginetest.skipteststep2',
      '{"overrideVal": "skippedOutput"}'
    );
    Test.stopTest();

    // 4. Verify step 2 execution is recorded as OperatorSkipped (using exact casing)
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.SkipTestStep2'
      ORDER BY CreatedDate DESC, Id DESC
    ];
    System.assertEquals(2, stepExecs.size());
    System.assertEquals('OperatorSkipped', stepExecs[0].Status__c);

    // 5. Run next step execution (should resume and complete)
    Workflow_Instance__c finalInst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', finalInst.Status__c);
  }

  @isTest
  static void testResumePastStepParallelReParksParkedBranches() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SkipThreeParallelWorkflow',
      'SkipThreeParallelSignalKey',
      'InitialInput'
    );

    // 1. Run split step (SkipThreeParallelSplitStep) -> should create parallel executions
    new WorkflowOrchestrator(instanceId).execute(null);

    // 2. Put SkipParallelA in a Pending state simulation (parked)
    List<Workflow_Step_Execution__c> stepExecsA = [
      SELECT Id, Status__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.SkipParallelA'
    ];
    stepExecsA[0].Status__c = 'Pending';
    stepExecsA[0].CPU_Time_Ms__c = 1;
    update stepExecsA[0];

    // 3. Run ParallelB -> fails and fails the workflow instance
    new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.SkipParallelB')
      .execute(null);

    // 4. Run ParallelC -> fails as well
    new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.SkipParallelC')
      .execute(null);

    // Verify parent is Failed
    Workflow_Instance__c instFailed = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', instFailed.Status__c);

    // 5. Resume past ParallelB
    WorkflowEngine.resumePastStep(
      instanceId,
      'WorkflowEngineTest.SkipParallelB',
      '{"val": "skippedParallelB"}'
    );

    // 6. Sibling C was reset and is now Pending. We set failParallelC to false and run it manually.
    WorkflowEngineTest.failParallelC = false;
    new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.SkipParallelC')
      .execute(null);

    // 7. Verify that parent is set back to Suspended because A is still parked
    Workflow_Instance__c instFinal = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'Suspended',
      instFinal.Status__c,
      'Parent should be Suspended since A is still parked'
    );
  }

  @isTest
  static void testResumePastStepParallelEnqueuesUndrivenPendingSibling() {
    WorkflowEngine.disableQueueableInTest = false;
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SkipThreeParallelWorkflow',
      'SkipThreeParallelSignalKey2',
      'InitialInput'
    );
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Run split step (SkipThreeParallelSplitStep) -> should create parallel executions
    new WorkflowOrchestrator(instanceId).execute(null);

    // Sibling A is left as Pending (undriven, CPU_Time_Ms__c is null).
    // Sibling B fails and fails the workflow instance.
    new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.SkipParallelB')
      .execute(null);

    // Verify parent is Failed
    Workflow_Instance__c instFailed = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', instFailed.Status__c);

    // 2. Resume past ParallelB.
    // Since A is Pending but has never run (CPU_Time_Ms__c is null), it is NOT treated as parked.
    // So the parent should become 'Running' (not 'Suspended').
    // And A should be enqueued to run.
    WorkflowEngineTest.failParallelC = false;

    // Both A and C will be reset/enqueued in memory or as no-ops since disableQueueableInTest is true.
    // We run them manually to drive their execution synchronously.
    WorkflowEngine.resumePastStep(
      instanceId,
      'WorkflowEngineTest.SkipParallelB',
      '{"val": "skippedParallelB"}'
    );

    // Run branch A and branch C manually. Wrap C in startTest/stopTest to execute the enqueued Join step.
    new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.SkipParallelA')
      .execute(null);
    Test.startTest();
    new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.SkipParallelC')
      .execute(null);
    Test.stopTest();

    // Verify parent is Completed (since all A, B, C completed/skipped)
    Workflow_Instance__c instFinal = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', instFinal.Status__c);
  }

  @isTest
  static void testResumePastStepRestampsTerminalTime() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.TerminalSkipWorkflow',
      'TerminalSkipKey',
      'InitialInput'
    );

    // 1. Run the only step -> fails and transitions instance to Failed
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c instFailed = [
      SELECT Status__c, Terminal_At__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', instFailed.Status__c);
    System.assertNotEquals(null, instFailed.Terminal_At__c);

    // Manually push Terminal_At__c back by 10 minutes so we can distinguish a new stamp
    Datetime tenMinutesAgo = Datetime.now().addMinutes(-10);
    instFailed.Terminal_At__c = tenMinutesAgo;
    update as system instFailed;

    // Verify it was updated in the DB
    Workflow_Instance__c instPreSkip = [
      SELECT Terminal_At__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(tenMinutesAgo, instPreSkip.Terminal_At__c);

    // 2. Skip the terminal step. This will transition status to 'Completed'.
    Test.startTest();
    WorkflowEngine.resumePastStep(
      instanceId,
      'WorkflowEngineTest.TerminalSkipStep',
      '{"overrideVal": "skippedOutput"}'
    );
    Test.stopTest();

    // 3. Verify that the parent instance transitioned to Completed and Terminal_At__c was restamped with the new time
    Workflow_Instance__c instFinal = [
      SELECT Status__c, Terminal_At__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', instFinal.Status__c);
    System.assertNotEquals(null, instFinal.Terminal_At__c);
    System.assert(
      instFinal.Terminal_At__c > tenMinutesAgo,
      'Terminal_At__c should have been restamped to a fresh value'
    );
  }

  @isTest
  static void testResumePastStepParallelPreservesRetrying() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SkipParallelWorkflow',
      'SkipParallelRetryingKey',
      'InitialInput'
    );

    // 1. Run split step (SkipParallelSplitStep) -> should create parallel executions
    new WorkflowOrchestrator(instanceId).execute(null);

    // 2. Put SkipParallelA in a Retrying state simulation (representing a retry backoff)
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Status__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.SkipParallelA'
    ];
    System.assertEquals(1, stepExecs.size());
    stepExecs[0].Status__c = 'Retrying';
    stepExecs[0].Retry_Count__c = 1;
    stepExecs[0].CPU_Time_Ms__c = 10;
    update stepExecs[0];

    // 3. Run ParallelB -> fails and fails the workflow instance
    new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.SkipParallelB')
      .execute(null);

    Workflow_Instance__c inst2 = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Failed', inst2.Status__c);

    // Count existing queueable jobs
    Integer jobsBefore = [
      SELECT COUNT()
      FROM AsyncApexJob
      WHERE JobType = 'Queueable'
    ];

    // 4. Resume past ParallelB
    Test.startTest();
    WorkflowEngine.resumePastStep(
      instanceId,
      'WorkflowEngineTest.SkipParallelB',
      '{"val": "skippedParallelB"}'
    );
    Test.stopTest();

    // Verify that SkipParallelA's execution remains Retrying and was NOT reset (retry count is still 1)
    Workflow_Step_Execution__c stepAAfter = [
      SELECT Status__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :stepExecs[0].Id
    ];
    System.assertEquals('Retrying', stepAAfter.Status__c);
    System.assertEquals(1, stepAAfter.Retry_Count__c);

    // Verify that the parent instance transitioned to Suspended (since branch A is in Retrying state, which counts as parked)
    Workflow_Instance__c instAfter = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'Suspended',
      instAfter.Status__c,
      'Parent instance should stay Suspended when a sibling branch is retrying'
    );

    // Verify that NO new job was enqueued
    Integer jobsAfter = [
      SELECT COUNT()
      FROM AsyncApexJob
      WHERE JobType = 'Queueable'
    ];
    System.assertEquals(
      jobsBefore,
      jobsAfter,
      'No new queueable jobs should have been enqueued for the retrying branch'
    );
  }

  @isTest
  static void testResumePastStepDynamicNextThrowsException() {
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Insert a Failed instance of LoopExposeWorkflow
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.LoopExposeWorkflow',
      Status__c = 'Failed',
      Current_Step__c = 'WorkflowEngineTest.LoopExposeStep',
      Correlation_Key__c = 'dynamic-skip-1'
    );
    insert inst;

    // 2. Insert a Failed step execution for LoopExposeStep
    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'WorkflowEngineTest.LoopExposeStep',
      Status__c = 'Failed',
      Retry_Count__c = 0
    );
    insert stepExec;

    // 3. Try to skip the step
    try {
      WorkflowEngine.resumePastStep(
        inst.Id,
        'WorkflowEngineTest.LoopExposeStep',
        '{}'
      );
      System.assert(false, 'Should have thrown a WorkflowException');
    } catch (WorkflowEngine.WorkflowException ex) {
      System.assertEquals(
        'Skip is not supported for dynamic-next step definitions.',
        ex.getMessage()
      );
    }
  }

  @isTest
  static void testResumePastStepRearmsPendingSiblingTimeout() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.SkipThreeParallelWorkflow',
      'SkipThreeParallelSignalKey3',
      'InitialInput'
    );

    // 1. Run split step -> creates parallel executions A, B, C.
    new WorkflowOrchestrator(instanceId).execute(null);

    // 2. Fetch the initial pending Sibling A step execution.
    Workflow_Step_Execution__c sibA = [
      SELECT Id, Timeout_At__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.SkipParallelA'
      LIMIT 1
    ];
    System.assertNotEquals(
      null,
      sibA.Timeout_At__c,
      'Sibling A should have an initial timeout set'
    );

    // Artificially modify Timeout_At__c to be in the past to simulate delay/stale timeout.
    Datetime pastTime = Datetime.now().addMinutes(-10);
    sibA.Timeout_At__c = pastTime;
    update sibA;

    // Fail Sibling B to fail the workflow instance.
    new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.SkipParallelB')
      .execute(null);

    // 3. Resume past ParallelB (the skip).
    WorkflowEngine.resumePastStep(
      instanceId,
      'WorkflowEngineTest.SkipParallelB',
      '{"val": "skippedParallelB"}'
    );

    // 4. Fetch Sibling A again to verify Timeout_At__c was re-armed (set to a future time, i.e., > pastTime)
    Workflow_Step_Execution__c sibAAfter = [
      SELECT Timeout_At__c
      FROM Workflow_Step_Execution__c
      WHERE Id = :sibA.Id
    ];
    System.assertNotEquals(
      null,
      sibAAfter.Timeout_At__c,
      'Sibling A should have its timeout set'
    );
    System.assert(
      sibAAfter.Timeout_At__c > pastTime,
      'Sibling A timeout should have been re-armed/advanced: ' +
      sibAAfter.Timeout_At__c
    );
  }

  public class TerminalSkipWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.TerminalSkipStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.TerminalSkipStep';
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
        'WorkflowEngineTest.SkipThreeParallelSplitStep',
        'WorkflowEngineTest.SkipParallelA',
        'WorkflowEngineTest.SkipParallelB',
        'WorkflowEngineTest.SkipParallelC',
        'WorkflowEngineTest.SkipParallelJoinStep3'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.SkipThreeParallelSplitStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'WorkflowEngineTest.SkipThreeParallelSplitStep') {
        return 'WorkflowEngineTest.SkipParallelJoinStep3';
      }
      return null;
    }
  }

  public class SkipThreeParallelSplitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowEngineTest.SkipParallelA',
          'WorkflowEngineTest.SkipParallelB',
          'WorkflowEngineTest.SkipParallelC'
        },
        null
      );
    }
  }

  public class SkipParallelC implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (WorkflowEngineTest.failParallelC) {
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

  @isTest
  static void testRunStepParallelReparksWithAlreadyRunningSibling() {
    WorkflowEngine.disableQueueableInTest = true;

    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.CompensatableParallelWorkflow',
      'CompensatableParallelSignalKey',
      'InitialInput'
    );

    // 1. Run split step -> creates parallel executions A and B
    new WorkflowOrchestrator(instanceId).execute(null);

    // 2. Put A in a Pending state simulation with CPU_Time_Ms__c = 10.0 (representing a parked branch)
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Status__c, CPU_Time_Ms__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.CompensatableParallelA'
      LIMIT 1
    ];
    System.assertEquals(1, stepExecs.size());
    stepExecs[0].Status__c = 'Pending';
    stepExecs[0].CPU_Time_Ms__c = 10.0;
    update stepExecs;

    // 3. Mark the parent instance as Running to simulate that Sibling B is already running (or transaction entered in Running state)
    Workflow_Instance__c inst = [
      SELECT Id, Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    inst.Status__c = 'Running';
    update inst;

    // 4. Run Sibling B (which is CompensatableParallelB).
    // Because it is compensatable, it will execute `update as system instance;` during compensation-stack update.
    // At the end, in the `if (!allDone)` block, it should repark the instance as 'Suspended' since Sibling A is parked.
    new WorkflowOrchestrator(
        instanceId,
        'WorkflowEngineTest.CompensatableParallelB'
      )
      .execute(null);

    // 5. Verify the parent instance was correctly updated to 'Suspended'
    Workflow_Instance__c instAfter = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals(
      'Suspended',
      instAfter.Status__c,
      'Parent instance should be Suspended since Sibling A is parked'
    );
  }

  public class CompensatableParallelWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineTest.CompensatableParallelSplitStep',
        'WorkflowEngineTest.CompensatableParallelA',
        'WorkflowEngineTest.CompensatableParallelB',
        'WorkflowEngineTest.CompensatableParallelJoinStep'
      };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.CompensatableParallelSplitStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      if (
        currentStepName == 'WorkflowEngineTest.CompensatableParallelSplitStep'
      ) {
        return 'WorkflowEngineTest.CompensatableParallelJoinStep';
      }
      return null;
    }
  }

  public class CompensatableParallelSplitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.split(
        new List<String>{
          'WorkflowEngineTest.CompensatableParallelA',
          'WorkflowEngineTest.CompensatableParallelB'
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

  public class CompensatableParallelJoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'JoinDone');
    }
  }

  // ==========================================
  // STEP BREADCRUMB MOCK CLASSES & TESTS
  // ==========================================

  public class BreadcrumbWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.BreadcrumbStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.BreadcrumbStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
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

  public class RollbackWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.RollbackStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.RollbackStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class RollbackStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      ctx.log(StepContext.Level.INFO, 'This should not be saved');
      throw new WorkflowEngine.WorkflowException('Simulated Failure');
    }
  }

  public static Integer retryBreadcrumbAttempt = 1;

  public class RetryBreadcrumbWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineTest.RetryBreadcrumbStep' };
    }
    public String getInitialStep() {
      return 'WorkflowEngineTest.RetryBreadcrumbStep';
    }
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  public class RetryBreadcrumbStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      ctx.log(
        StepContext.Level.INFO,
        'Attempt ' + WorkflowEngineTest.retryBreadcrumbAttempt
      );
      if (WorkflowEngineTest.retryBreadcrumbAttempt < 3) {
        WorkflowEngineTest.retryBreadcrumbAttempt++;
        RetryPolicy policy = new RetryPolicy(1, (Double) 1.0, 5);
        return StepResult.retry(policy);
      }
      return StepResult.complete(null, 'Success');
    }
  }

  @isTest
  static void testStepBreadcrumbsPersisted() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.BreadcrumbWorkflow',
      'BreadcrumbKey',
      null
    );
    Test.stopTest(); // runs BreadcrumbStep synchronously

    List<Workflow_Log__c> logs = [
      SELECT
        Log_Type__c,
        Level__c,
        Message__c,
        Correlation_Key__c,
        Workflow_Instance__c,
        Workflow_Name__c
      FROM Workflow_Log__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Log_Type__c = :StepContext.LOG_TYPE_BREADCRUMB
      ORDER BY Fire_Time__c ASC, Id ASC
    ];

    Workflow_Step_Execution__c stepExec = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'WorkflowEngineTest.BreadcrumbStep'
      LIMIT 1
    ];

    System.assertEquals(2, logs.size(), 'Should have saved 2 breadcrumbs');

    System.assertEquals(StepContext.LOG_TYPE_BREADCRUMB, logs[0].Log_Type__c);
    System.assertEquals('INFO', logs[0].Level__c);
    System.assert(
      logs[0].Message__c.contains('Step 1 execution started'),
      'Message mismatch: ' + logs[0].Message__c
    );
    System.assert(
      logs[0].Message__c.contains('"status":"init"'),
      'Message mismatch: ' + logs[0].Message__c
    );
    System.assertEquals(stepExec.Id, logs[0].Correlation_Key__c);

    System.assertEquals(StepContext.LOG_TYPE_BREADCRUMB, logs[1].Log_Type__c);
    System.assertEquals('WARN', logs[1].Level__c);
    System.assertEquals('Step 1 warning encountered', logs[1].Message__c);
    System.assertEquals(stepExec.Id, logs[1].Correlation_Key__c);
  }

  @isTest
  static void testStepBreadcrumbsRollbackOnFailure() {
    WorkflowEngine.disableQueueableInTest = true;
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.RollbackWorkflow',
      'RollbackKey',
      null
    );

    Savepoint sp = Database.setSavepoint();
    try {
      new WorkflowOrchestrator(instanceId).execute(null);
      System.assert(false, 'Should have thrown an exception');
    } catch (Exception ex) {
      Database.rollback(sp);
      System.assert(
        ex.getMessage().contains('Simulated Failure') ||
        ex.getMessage().contains('terminated, cancelled'),
        'Exception mismatch: ' + ex.getMessage()
      );
    }

    List<Workflow_Log__c> logs = [
      SELECT Log_Type__c, Level__c, Message__c
      FROM Workflow_Log__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Log_Type__c = :StepContext.LOG_TYPE_BREADCRUMB
    ];
    System.assertEquals(
      0,
      logs.size(),
      'Should not have saved any breadcrumbs because of rollback'
    );
  }

  @isTest
  static void testStepBreadcrumbsEffectivelyOnceOnRetry() {
    WorkflowEngineTest.retryBreadcrumbAttempt = 1;

    Test.startTest();
    Id instanceId = WorkflowEngine.start(
      'WorkflowEngineTest.RetryBreadcrumbWorkflow',
      'RetryBreadcrumbKey',
      null
    );
    Test.stopTest(); // Runs Attempt 1, returns retry (Retry_Count__c = 1)

    // Attempt 2
    WorkflowEngine.runStep(instanceId); // Runs Attempt 2, returns retry (Retry_Count__c = 2)

    // Attempt 3
    WorkflowEngine.runStep(instanceId); // Runs Attempt 3, completes successfully!

    List<Workflow_Log__c> logs = [
      SELECT Log_Type__c, Level__c, Message__c, Correlation_Key__c
      FROM Workflow_Log__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Log_Type__c = :StepContext.LOG_TYPE_BREADCRUMB
      ORDER BY CreatedDate ASC, Id ASC
    ];

    System.assertEquals(
      3,
      logs.size(),
      'Should have saved exactly 3 breadcrumbs'
    );
    System.assertEquals('Attempt 1', logs[0].Message__c);
    System.assertEquals('Attempt 2', logs[1].Message__c);
    System.assertEquals('Attempt 3', logs[2].Message__c);
  }

  @isTest
  static void testCausationIdPersistenceAndLineage() {
    WorkflowEngine.disableQueueableInTest = true;

    // Start A (root) with a causation ID
    WorkflowEngine.StartRequest reqA = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.HappyWorkflow',
      'CausationKeyA',
      null
    );
    reqA.causationId = 'root-causation-trace-123';

    Test.startTest();
    WorkflowEngine.StartResult resultA = WorkflowEngine.startOrGet(
      new List<WorkflowEngine.StartRequest>{ reqA }
    )[0];
    System.assertEquals(true, resultA.isNew);

    Workflow_Instance__c instA = [
      SELECT Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :resultA.instanceId
    ];
    System.assertEquals(
      'root-causation-trace-123',
      instA.Causation_Id__c,
      'Causation ID must be persisted'
    );

    // Test getStatus read API
    WorkflowEngine.WorkflowStatus statusA = WorkflowEngine.getStatus(
      resultA.instanceId
    );
    System.assertEquals(
      'root-causation-trace-123',
      statusA.causationId,
      'Status DTO must expose causationId'
    );

    // Start B (downstream) using A as cause
    WorkflowEngine.StartRequest reqB = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.HappyWorkflow',
      'CausationKeyB',
      null
    );
    reqB.causationId = resultA.instanceId;
    WorkflowEngine.StartResult resultB = WorkflowEngine.startOrGet(
      new List<WorkflowEngine.StartRequest>{ reqB }
    )[0];

    // Start C (downstream) using B as cause
    WorkflowEngine.StartRequest reqC = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.HappyWorkflow',
      'CausationKeyC',
      null
    );
    reqC.causationId = resultB.instanceId;
    WorkflowEngine.StartResult resultC = WorkflowEngine.startOrGet(
      new List<WorkflowEngine.StartRequest>{ reqC }
    )[0];

    // Verify lineage walk: C -> B -> A
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      resultC.instanceId
    );
    System.assertNotEquals(null, lineage);
    System.assertEquals(3, lineage.size(), 'Lineage size mismatch');
    System.assertEquals(resultC.instanceId, lineage[0].instanceId);
    System.assertEquals(resultB.instanceId, lineage[1].instanceId);
    System.assertEquals(resultA.instanceId, lineage[2].instanceId);

    Test.stopTest();
  }

  @isTest
  static void testCausationIdInheritedOnContinueAsNew() {
    WorkflowEngine.disableQueueableInTest = true;

    // Start with a causation ID
    WorkflowEngine.StartRequest req = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.DaemonWorkflow',
      'CausationDaemonKey',
      0
    );
    req.causationId = 'trace-456';

    Id instanceId = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ req }
      )[0]
      .instanceId;
    new WorkflowOrchestrator(instanceId).execute(null); // Runs the first execution run -> continueAsNew

    // Find Run 2
    Workflow_Instance__c run2 = [
      SELECT Id, Status__c, Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :instanceId
    ];
    System.assertEquals('Pending', run2.Status__c);
    System.assertEquals(
      'trace-456',
      run2.Causation_Id__c,
      'Successor must inherit causation ID'
    );
  }

  @isTest
  static void testCausationIdParentFallback() {
    WorkflowEngine.disableQueueableInTest = true;

    // Start Parent
    Id parentId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'ParentKey',
      null
    );

    // Start Child under Parent
    Id childId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'ChildKey',
      null,
      parentId
    );

    Workflow_Instance__c child = [
      SELECT Causation_Id__c, Parent_Instance__c
      FROM Workflow_Instance__c
      WHERE Id = :childId
    ];
    System.assertEquals(
      parentId,
      child.Causation_Id__c,
      'Causation ID must fallback to Parent Instance ID on build'
    );

    // Verify lineage walk follows Parent_Instance__c fallback even if Causation_Id__c was blank (test by manually nulling it)
    child.Causation_Id__c = null;
    update child;

    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      childId
    );
    System.assertEquals(2, lineage.size());
    System.assertEquals(childId, lineage[0].instanceId);
    System.assertEquals(parentId, lineage[1].instanceId);
  }

  @isTest
  static void testCausationIdReusedKeyTimeBound() {
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Create original parent
    Id originalParentId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'ReusedKey',
      null
    );

    // Start Child using correlation key of parent
    WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.HappyWorkflow',
      'ChildKeyReused',
      null
    );
    childReq.causationId = 'key:ReusedKey';
    Id childId = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ childReq }
      )[0]
      .instanceId;

    // 2. Create a new, later run with the same correlation key
    // Since Correlation_Key__c unique index prevents multiple active runs, we make the original parent complete first.
    Workflow_Instance__c origParent = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :originalParentId
    ];
    origParent.Status__c = 'Completed';
    update origParent;
    origParent.Terminal_At__c = DateTime.now().addDays(-2);
    update origParent;

    Id newerParentId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'ReusedKey',
      null
    );

    // Explicitly set CreatedDates to bound them
    Test.setCreatedDate(originalParentId, DateTime.now().addMinutes(-10));
    Test.setCreatedDate(childId, DateTime.now().addMinutes(-5));
    Test.setCreatedDate(newerParentId, DateTime.now());

    // Update child's Causation_Id__c timestamp to match its mocked CreatedDate
    Workflow_Instance__c childInst = [
      SELECT Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :childId
    ];
    childInst.Causation_Id__c =
      'key:ReusedKey::ts::' +
      String.valueOf(DateTime.now().addMinutes(-5).getTime());
    update childInst;

    // Assert that getCausationLineage on child resolves to originalParentId (older) and NOT newerParentId (newer)
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      childId
    );
    System.assertEquals(2, lineage.size());
    System.assertEquals(childId, lineage[0].instanceId);
    System.assertEquals(
      originalParentId,
      lineage[1].instanceId,
      'Must resolve to the parent that existed at child creation time'
    );
  }

  @isTest
  static void testCausationIdInheritedOnContinueAsNewFallback() {
    WorkflowEngine.disableQueueableInTest = true;

    // Start Parent
    Id parentId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'ParentKey',
      null
    );

    // Start Child under Parent with blank causationId (so it has only Parent_Instance__c)
    WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.DaemonWorkflow',
      'ChildDaemonKey',
      0,
      parentId
    );
    Id childId = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ childReq }
      )[0]
      .instanceId;

    // Verify child has blank Causation_Id__c but non-blank Parent_Instance__c
    Workflow_Instance__c child = [
      SELECT Causation_Id__c, Parent_Instance__c
      FROM Workflow_Instance__c
      WHERE Id = :childId
    ];
    child.Causation_Id__c = null;
    update child;

    // Execute run -> triggers continueAsNew
    new WorkflowOrchestrator(childId).execute(null);

    // Find Run 2 of Child (the successor)
    Workflow_Instance__c run2 = [
      SELECT Id, Status__c, Causation_Id__c, Previous_Instance__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :childId
    ];
    // successor must inherit parentId as causationId since predecessor's Causation_Id__c was blank but Parent_Instance__c was parentId
    System.assertEquals(
      parentId,
      run2.Causation_Id__c,
      'Successor must inherit parentId as causationId'
    );

    // Verify lineage walk from Run 2 correctly resolves to Parent
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      run2.Id
    );
    System.assertEquals(2, lineage.size());
    System.assertEquals(run2.Id, lineage[0].instanceId);
    System.assertEquals(parentId, lineage[1].instanceId);
  }

  @isTest
  static void testCausationLineageCarriesTerminalOutputs() {
    WorkflowEngine.disableQueueableInTest = true;

    // Start Parent
    Id parentId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'ParentKey',
      '{"val": "ParentInput"}'
    );

    // Complete the Parent by executing it
    new WorkflowOrchestrator(parentId).execute(null);
    new WorkflowOrchestrator(parentId).execute(null);

    // Verify it is completed and has output
    Workflow_Instance__c parent = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    System.assertEquals('Completed', parent.Status__c);
    System.assertNotEquals(null, parent.Output__c);

    // Start Child under Parent
    Id childId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'ChildKey',
      null,
      parentId
    );

    // Get causation lineage on Child
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      childId
    );
    System.assertEquals(2, lineage.size());
    System.assertEquals(childId, lineage[0].instanceId);
    System.assertEquals(parentId, lineage[1].instanceId);

    // Verify parent's output in the lineage matches the actual output
    System.assertNotEquals(null, lineage[1].output);
    System.assertNotEquals('', lineage[1].output);
    System.assertEquals(
      parent.Output__c,
      lineage[1].output,
      'Terminal lineage entries must carry rehydrated output'
    );
  }

  @isTest
  static void testCausationIdReusedKeySelfExclusion() {
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Create original parent
    Id originalParentId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'ReusedKeySame',
      null
    );

    // Make the original parent complete first to release the Active_Correlation_Key__c
    Workflow_Instance__c origParent = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :originalParentId
    ];
    origParent.Status__c = 'Completed';
    update origParent;
    origParent.Terminal_At__c = DateTime.now().addDays(-2);
    update origParent;

    // 2. Start a downstream/child workflow with the SAME correlation key, caused by the parent key
    WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.HappyWorkflow',
      'ReusedKeySame',
      null
    );
    childReq.causationId = 'key:ReusedKeySame';
    Id childId = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ childReq }
      )[0]
      .instanceId;

    // Set CreatedDates so child is newer
    Test.setCreatedDate(originalParentId, DateTime.now().addMinutes(-10));
    Test.setCreatedDate(childId, DateTime.now());

    // Get causation lineage on Child. It should NOT resolve to itself, but correctly walk up to originalParentId.
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      childId
    );
    System.assertEquals(2, lineage.size(), 'Must walk up to parent');
    System.assertEquals(childId, lineage[0].instanceId);
    System.assertEquals(
      originalParentId,
      lineage[1].instanceId,
      'Must resolve to the parent and not self'
    );
  }

  @isTest
  static void testManualCompensationLineageAndParentIsolation() {
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Start Parent
    Id parentId = WorkflowEngine.start(
      'WorkflowEngineTest.ParentWorkflow',
      'ParentKey',
      null
    );

    // Execute ParentStep once to spawn child and suspend parent
    new WorkflowOrchestrator(parentId).execute(null);

    // Find the spawned child
    Workflow_Instance__c child = [
      SELECT
        Id,
        Status__c,
        Parent_Instance__c,
        Correlation_Key__c,
        Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Parent_Instance__c = :parentId
      LIMIT 1
    ];
    Id childId = child.Id;

    System.assertEquals('Pending', child.Status__c);
    System.assertEquals(parentId, child.Parent_Instance__c);
    System.assertEquals(parentId, child.Causation_Id__c);

    // Complete the Child by running it
    new WorkflowOrchestrator(childId).execute(null);

    // Verify Child completed
    child = [
      SELECT Status__c, Compensation_Stack__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :childId
    ];
    System.assertEquals('Completed', child.Status__c);

    // Manually stamp compensation stack on completed child so it can be compensated
    child.Compensation_Stack__c = JSON.serialize(
      new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
    );
    update child;

    // Set up a mock completed step execution so compensation has something to run
    Workflow_Step_Execution__c origExec = new Workflow_Step_Execution__c(
      Workflow_Instance__c = childId,
      Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep',
      Status__c = 'Completed',
      Input__c = '"Input"',
      Output__c = '"Output"'
    );
    insert origExec;

    // 3. Compensate the completed child
    Id compensatingId = WorkflowEngine.compensate(childId);
    System.assertNotEquals(null, compensatingId);

    // Verify the compensating run has NO Parent_Instance__c but DOES have Causation_Id__c!
    Workflow_Instance__c compInst = [
      SELECT Status__c, Parent_Instance__c, Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :compensatingId
    ];
    System.assertEquals(
      null,
      compInst.Parent_Instance__c,
      'Must NOT set Parent_Instance__c on manual compensation run'
    );
    System.assertEquals(
      parentId,
      compInst.Causation_Id__c,
      'Must preserve Causation_Id__c'
    );

    // Verify lineage walk from the compensating run successfully reaches the parent
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      compensatingId
    );
    System.assertEquals(2, lineage.size());
    System.assertEquals(compensatingId, lineage[0].instanceId);
    System.assertEquals(parentId, lineage[1].instanceId);

    // Parent is currently Suspended (waiting for child completions). Verify this.
    Workflow_Instance__c parentReload = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    System.assertEquals('Suspended', parentReload.Status__c);

    // 4. Drive the compensating run to completion
    new WorkflowOrchestrator(compensatingId).execute(null);

    // Verify compensating run is Compensated
    compInst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :compensatingId
    ];
    System.assertEquals('Compensated', compInst.Status__c);

    // Verify Parent is STILL Suspended (its state was NOT corrupted/altered by notifications from the compensating run)
    parentReload = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :parentId
    ];
    System.assertEquals(
      'Suspended',
      parentReload.Status__c,
      'Parent must remain Suspended; compensation run completion must be isolated'
    );
  }

  @isTest
  static void testCausationIdLooksLikeIdFallback() {
    WorkflowEngine.disableQueueableInTest = true;

    // Get key prefix for Workflow_Instance__c (usually 'a01' or 'a00')
    String prefix = Workflow_Instance__c.SObjectType.getDescribe()
      .getKeyPrefix();
    // Pad to 15 characters to make it look like a valid Salesforce ID
    String lookalikeId = prefix + '000000000000';

    // 1. Create parent with this lookalike correlation key
    Id parentId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      lookalikeId,
      null
    );

    // 2. Start child caused by the lookalike correlation key
    WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.HappyWorkflow',
      'ChildKey',
      null
    );
    childReq.causationId = 'key:' + lookalikeId;
    Id childId = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ childReq }
      )[0]
      .instanceId;

    // Get causation lineage on Child.
    // Even though lookalikeId is a valid ID syntax, it does not exist in the database,
    // so getCausationLineage should fall back to key-based query and resolve to parentId.
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      childId
    );
    System.assertEquals(
      2,
      lineage.size(),
      'Must walk up to parent via fallback key lookup'
    );
    System.assertEquals(childId, lineage[0].instanceId);
    System.assertEquals(parentId, lineage[1].instanceId);
  }

  @isTest
  static void testCausationIdInheritedOnContinueAsNewReusedKeyTimeBound() {
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Create original parent
    Id originalParentId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'ParentKeyReused',
      null
    );

    // Make original parent complete to release the key
    Workflow_Instance__c origParent = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :originalParentId
    ];
    origParent.Status__c = 'Completed';
    update origParent;
    origParent.Terminal_At__c = DateTime.now().addDays(-2);
    update origParent;

    // 2. Start Child caused by 'ParentKeyReused'
    WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.DaemonWorkflow',
      'ChildDaemonKey',
      (Object) 0
    );
    childReq.causationId = 'key:ParentKeyReused';
    Id childId = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ childReq }
      )[0]
      .instanceId;

    // Execute run -> triggers continueAsNew, spawning successor
    new WorkflowOrchestrator(childId).execute(null);

    // Find Run 2 of Child (successor)
    Workflow_Instance__c run2 = [
      SELECT Id, Status__c, Causation_Id__c, Previous_Instance__c
      FROM Workflow_Instance__c
      WHERE Previous_Instance__c = :childId
    ];
    System.assert(run2.Causation_Id__c.startsWith('key:ParentKeyReused'));

    // 3. Create a NEW parent run with the same key AFTER the child was created
    Id newerParentId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'ParentKeyReused',
      null
    );

    // Explicitly set CreatedDates to order them:
    // originalParent (10 mins ago) -> child/predecessor (5 mins ago) -> newParent (now) -> run2 (now + 1 min)
    Test.setCreatedDate(originalParentId, DateTime.now().addMinutes(-10));
    Test.setCreatedDate(childId, DateTime.now().addMinutes(-5));
    Test.setCreatedDate(newerParentId, DateTime.now());
    Test.setCreatedDate(run2.Id, DateTime.now().addMinutes(1));

    // Update run2's Causation_Id__c timestamp to match predecessor's mocked CreatedDate
    run2.Causation_Id__c =
      'key:ParentKeyReused::ts::' +
      String.valueOf(DateTime.now().addMinutes(-5).getTime());
    update run2;

    // Get causation lineage on successor (run2).
    // Because lineage lookup bounds key resolution by the earliest predecessor creation time (5 mins ago),
    // it should resolve to originalParentId (10 mins ago) and NOT newerParentId (now).
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      run2.Id
    );
    System.assertEquals(
      2,
      lineage.size(),
      'Lineage walk must resolve to the original parent'
    );
    System.assertEquals(run2.Id, lineage[0].instanceId);
    System.assertEquals(
      originalParentId,
      lineage[1].instanceId,
      'Must resolve to original parent and not newer parent with reused key'
    );
  }

  @isTest
  static void testCausationIdInheritedOnContinueAsNewReusedKeyTimeBoundCapped() {
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Create a chain of 7 instances linked by Previous_Instance__c
    List<Workflow_Instance__c> chain = new List<Workflow_Instance__c>();
    Id prevId = null;
    for (Integer i = 0; i < 7; i++) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Correlation_Key__c = 'ChainKey-' + i,
        Causation_Id__c = 'ParentKey',
        Previous_Instance__c = prevId
      );
      insert inst;
      prevId = inst.Id;
      chain.add(inst);
    }

    // Run getCausationLineage on the last item.
    // It should not throw any exceptions (governor limits) and should complete successfully.
    Test.startTest();
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      chain[6].Id
    );
    Test.stopTest();

    System.assertNotEquals(
      null,
      lineage,
      'Lineage must be returned successfully'
    );
  }

  @isTest
  static void testCausationIdInheritedOnContinueAsNewReusedKeyTimeBoundLongChain() {
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Create original parent
    Id originalParentId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'ParentKeyReusedLong',
      null
    );

    // Make original parent complete to release the key
    Workflow_Instance__c origParent = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :originalParentId
    ];
    origParent.Status__c = 'Completed';
    update origParent;
    origParent.Terminal_At__c = DateTime.now().addDays(-2);
    update origParent;

    // 2. Create a chain of 8 continue-as-new instances caused by 'ParentKeyReusedLong'
    List<Workflow_Instance__c> chain = new List<Workflow_Instance__c>();
    Id prevId = null;
    for (Integer i = 0; i < 8; i++) {
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
        Correlation_Key__c = 'ChainDaemonKey-' + i,
        Causation_Id__c = 'key:ParentKeyReusedLong::ts::' +
          String.valueOf(DateTime.now().addMinutes(-5).getTime()),
        Previous_Instance__c = prevId
      );
      insert inst;
      prevId = inst.Id;
      chain.add(inst);
    }

    // 3. Create a NEW parent run with the same key AFTER the child was created
    Id newerParentId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'ParentKeyReusedLong',
      null
    );

    // Explicitly set CreatedDates to order them:
    // originalParent (10 mins ago) -> first run (5 mins ago) -> newParent (now) -> last run (now + 1 min)
    Test.setCreatedDate(originalParentId, DateTime.now().addMinutes(-10));
    Test.setCreatedDate(chain[0].Id, DateTime.now().addMinutes(-5));
    Test.setCreatedDate(newerParentId, DateTime.now());
    Test.setCreatedDate(chain[7].Id, DateTime.now().addMinutes(1));

    // Get causation lineage on the last run of the chain.
    // Because we bulk-query 5 levels at a time, we will successfully walk back all 8 levels to the first run (5 mins ago),
    // and correctly resolve to originalParentId (10 mins ago) instead of newerParentId (now).
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      chain[7].Id
    );
    System.assertEquals(
      2,
      lineage.size(),
      'Lineage walk must resolve to the original parent'
    );
    System.assertEquals(chain[7].Id, lineage[0].instanceId);
    System.assertEquals(
      originalParentId,
      lineage[1].instanceId,
      'Must resolve to original parent and not newer parent with reused key'
    );
  }

  @isTest
  static void testCausationIdTimestampPropagationAndLineage() {
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Start a parent workflow
    Id parentId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'MyRealParentKey',
      null
    );

    // 2. Start a child with a key-based causation ID
    WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.HappyWorkflow',
      'MyChildKey',
      null
    );
    childReq.causationId = 'key:MyRealParentKey';
    Id childId = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ childReq }
      )[0]
      .instanceId;

    // Verify child instance contains the causationId with the timestamp
    Workflow_Instance__c childInst = [
      SELECT Causation_Id__c, CreatedDate
      FROM Workflow_Instance__c
      WHERE Id = :childId
    ];
    System.assert(
      childInst.Causation_Id__c.startsWith('key:MyRealParentKey::ts::')
    );

    // 3. Resolve lineage and verify it correctly parses and matches to parentId,
    // and returns the clean causationId in the DTO.
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      childId
    );
    System.assertEquals(2, lineage.size());
    System.assertEquals(parentId, lineage[1].instanceId);
    System.assertEquals('key:MyRealParentKey', lineage[0].causationId);
  }

  @isTest
  static void testCausationIdWithHashInKey() {
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Start a parent workflow with a key containing '#'
    Id parentId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'order#123',
      null
    );

    // 2. Start a child with a key-based causation ID referencing 'order#123'
    WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.HappyWorkflow',
      'MyChildKeyHash',
      null
    );
    childReq.causationId = 'key:order#123';
    Id childId = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ childReq }
      )[0]
      .instanceId;

    // Verify child instance contains the causationId with the timestamp appended after order#123
    Workflow_Instance__c childInst = [
      SELECT Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :childId
    ];
    System.assert(childInst.Causation_Id__c.startsWith('key:order#123::ts::'));

    // 3. Resolve lineage and verify it correctly parses 'order#123' (preserving the '#' character) and resolves to parentId
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      childId
    );
    System.assertEquals(2, lineage.size());
    System.assertEquals(parentId, lineage[1].instanceId);
    System.assertEquals('key:order#123', lineage[0].causationId);
  }

  @isTest
  static void testCausationIdBulkStartRaceCondition() {
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Prepare a bulk start request containing both parent and child
    WorkflowEngine.StartRequest parentReq = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.HappyWorkflow',
      'BulkParentKey',
      null
    );

    WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.HappyWorkflow',
      'BulkChildKey',
      null
    );
    childReq.causationId = 'key:BulkParentKey';

    // Start both workflows in the same bulk transaction
    List<WorkflowEngine.StartResult> results = WorkflowEngine.startOrGet(
      new List<WorkflowEngine.StartRequest>{ parentReq, childReq }
    );
    Id parentId = results[0].instanceId;
    Id childId = results[1].instanceId;

    // Simulate bulk CreatedDate behavior by mocking parent's CreatedDate to be slightly AFTER the pre-insert timestamp.
    // We update parent's CreatedDate to be now, and set child's timestamp suffix to be 2 seconds ago.
    Workflow_Instance__c childInst = [
      SELECT Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :childId
    ];
    childInst.Causation_Id__c =
      'key:BulkParentKey::ts::' +
      String.valueOf(DateTime.now().addSeconds(-2).getTime());
    update childInst;

    Test.setCreatedDate(parentId, DateTime.now());
    Test.setCreatedDate(childId, DateTime.now());

    // Resolve lineage. Even though the parent's mocked CreatedDate (now) is 2 seconds after the child's
    // causation timestamp (2 seconds ago), the 5-second buffer ensures the parent is correctly resolved.
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      childId
    );
    System.assertEquals(2, lineage.size());
    System.assertEquals(parentId, lineage[1].instanceId);
  }

  @isTest
  static void testCausationIdResolveThroughChainRoot() {
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Insert parent run 1 (stale ContinuedAsNew)
    Workflow_Instance__c run1 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Correlation_Key__c = 'ParentKeyRoot',
      Root_Correlation_Key__c = 'ParentKeyRoot',
      Status__c = 'ContinuedAsNew'
    );
    insert run1;
    Test.setCreatedDate(run1.Id, DateTime.now().addMinutes(-10));

    // 2. Insert parent run 2 (live completed successor)
    Workflow_Instance__c run2 = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Correlation_Key__c = 'ParentKeyRoot-1',
      Root_Correlation_Key__c = 'ParentKeyRoot',
      Previous_Instance__c = run1.Id,
      Status__c = 'Completed'
    );
    insert run2;
    Test.setCreatedDate(run2.Id, DateTime.now().addMinutes(-5));

    // 3. Start a child caused by the root key 'ParentKeyRoot'
    WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.HappyWorkflow',
      'ChildKey',
      null
    );
    childReq.causationId = 'key:ParentKeyRoot';
    Id childId = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ childReq }
      )[0]
      .instanceId;
    Test.setCreatedDate(childId, DateTime.now());

    // Resolve lineage. It should trace back to the terminal successor (run2) and NOT the stale predecessor (run1)
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      childId
    );
    System.assertEquals(2, lineage.size());
    System.assertEquals(run2.Id, lineage[1].instanceId);
    System.assertEquals('key:ParentKeyRoot', lineage[0].causationId);
  }

  @isTest
  static void testCausationIdWithNumericHashSuffixInKey() {
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Start a parent workflow with a key containing '#' followed by 13 digits
    Id parentId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'order#1234567890123',
      null
    );

    // 2. Start a child with a key-based causation ID referencing 'order#1234567890123'
    WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.HappyWorkflow',
      'MyChildKeyNumericHash',
      null
    );
    childReq.causationId = 'key:order#1234567890123';
    Id childId = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ childReq }
      )[0]
      .instanceId;

    // Verify child instance contains the causationId with the ::ts:: suffix appended after the full key
    Workflow_Instance__c childInst = [
      SELECT Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :childId
    ];
    System.assert(
      childInst.Causation_Id__c.startsWith('key:order#1234567890123::ts::')
    );

    // 3. Resolve lineage and verify it correctly parses 'order#1234567890123' (preserving the '#' and 13 digits) and resolves to parentId
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      childId
    );
    System.assertEquals(2, lineage.size());
    System.assertEquals(parentId, lineage[1].instanceId);
    System.assertEquals('key:order#1234567890123', lineage[0].causationId);
  }

  @isTest
  static void testCausationIdWithDelimiterInKey() {
    WorkflowEngine.disableQueueableInTest = true;

    // 1. Start a parent workflow with a key containing '::ts::'
    Id parentId = WorkflowEngine.start(
      'WorkflowEngineTest.HappyWorkflow',
      'order::ts::prod',
      null
    );

    // 2. Start a child with a key-based causation ID referencing 'order::ts::prod'
    WorkflowEngine.StartRequest childReq = new WorkflowEngine.StartRequest(
      'WorkflowEngineTest.HappyWorkflow',
      'MyChildKeyDelimiter',
      null
    );
    childReq.causationId = 'key:order::ts::prod';
    Id childId = WorkflowEngine.startOrGet(
        new List<WorkflowEngine.StartRequest>{ childReq }
      )[0]
      .instanceId;

    // Verify child instance contains the causationId with the ::ts:: suffix appended after the full key
    Workflow_Instance__c childInst = [
      SELECT Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Id = :childId
    ];
    System.assert(
      childInst.Causation_Id__c.startsWith('key:order::ts::prod::ts::')
    );

    // 3. Resolve lineage and verify it correctly parses 'order::ts::prod' (preserving the '::ts::prod' prefix) and resolves to parentId
    List<WorkflowEngine.WorkflowStatus> lineage = WorkflowEngine.getCausationLineage(
      childId
    );
    System.assertEquals(2, lineage.size());
    System.assertEquals(parentId, lineage[1].instanceId);
    System.assertEquals('key:order::ts::prod', lineage[0].causationId);
  }
}
