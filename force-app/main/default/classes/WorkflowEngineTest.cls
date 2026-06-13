@isTest
public class WorkflowEngineTest {

    // ==========================================
    // MOCK WORKFLOWS & STEPS FOR TESTING
    // ==========================================
    
    public class HappyWorkflow implements WorkflowDefinition {
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
            String input = (String)JSON.deserialize(ctx.previousStepOutput, String.class);
            return StepResult.complete(null, input + '_Output2');
        }
    }

    public class YieldingWorkflow implements WorkflowDefinition {
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
                state = (YieldingChunkState)JSON.deserialize(ctx.stepStateJson, YieldingChunkState.class);
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
                return StepResult.complete('WorkflowEngineTest.AfterSuspendStep', ctx.stepStateJson);
            }
            return StepResult.suspend();
        }
    }

    public class AfterSuspendStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            String payload = (String)JSON.deserialize(ctx.previousStepOutput, String.class);
            return StepResult.complete(null, 'Resumed_' + payload);
        }
    }

    public class CrashingWorkflow implements WorkflowDefinition {
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
                SELECT Id, Signal_Name__c, Payload__c FROM Workflow_Signal__c
                WHERE Workflow_Instance__c = :ctx.workflowInstanceId
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
                SELECT Id, Payload__c FROM Workflow_Signal__c
                WHERE Workflow_Instance__c = :ctx.workflowInstanceId
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
            RetryPolicy policy = new RetryPolicy(2, (Double)3.0, 3);
            return StepResult.retry(policy);
        }
    }

    public class SleepingWorkflow implements WorkflowDefinition {
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
                return StepResult.complete('WorkflowEngineTest.AfterSleepStep', ctx.stepStateJson);
            }
            return StepResult.sleep(10, 'resumed_state');
        }
    }

    public class AfterSleepStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            String payload = (String)JSON.deserialize(ctx.previousStepOutput, String.class);
            return StepResult.complete(null, 'Done_' + payload);
        }
    }

    public class ParentWorkflow implements WorkflowDefinition {
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
                SELECT Payload__c FROM Workflow_Signal__c
                WHERE Workflow_Instance__c = :ctx.workflowInstanceId
                AND Signal_Name__c = 'ChildCompleted:SubKey'
                AND Status__c = 'Received'
                LIMIT 1
            ];
            if (!signals.isEmpty()) {
                signals[0].Status__c = 'Consumed';
                update signals[0];
                String childResult = (String)JSON.deserialize(signals[0].Payload__c, String.class);
                return StepResult.complete(null, 'ParentResult_' + childResult);
            }
            return StepResult.startChild('WorkflowEngineTest.ChildWorkflow', 'SubKey', 'ChildInput');
        }
    }

    public class ChildWorkflow implements WorkflowDefinition {
        public String getInitialStep() {
            return 'WorkflowEngineTest.ChildStep';
        }
        public String getNextStep(String currentStepName, StepResult stepResult) {
            return null;
        }
    }

    public class ChildStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            String input = (String)JSON.deserialize(ctx.inputJson, String.class);
            return StepResult.complete(null, input + '_ChildDone');
        }
    }

    // ==========================================
    // TEST METHODS
    // ==========================================

    @isTest
    static void testHappyPath() {
        Test.startTest();
        Id instanceId = WorkflowEngine.start('WorkflowEngineTest.HappyWorkflow', 'HappyKey', 'StartVal');
        Test.stopTest(); // Runs HappyStep1 synchronously

        // Manually execute second step HappyStep2 synchronously
        new WorkflowOrchestrator(instanceId).execute(null);

        Workflow_Instance__c inst = [SELECT Status__c, Output__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Completed', inst.Status__c);
        System.assertEquals('"Output1_Output2"', inst.Output__c);
        System.assertEquals(null, inst.Current_Step__c);
        
        List<Workflow_Step_Execution__c> steps = [SELECT Step_Name__c, Status__c, Output__c FROM Workflow_Step_Execution__c WHERE Workflow_Instance__c = :instanceId ORDER BY CreatedDate ASC];
        System.assertEquals(2, steps.size());
        System.assertEquals('WorkflowEngineTest.HappyStep1', steps[0].Step_Name__c);
        System.assertEquals('Completed', steps[0].Status__c);
        System.assertEquals('WorkflowEngineTest.HappyStep2', steps[1].Step_Name__c);
        System.assertEquals('Completed', steps[1].Status__c);
    }

    @isTest
    static void testYieldingPath() {
        Test.startTest();
        Id instanceId = WorkflowEngine.start('WorkflowEngineTest.YieldingWorkflow', 'YieldKey', null);
        Test.stopTest(); // Runs initial step execution (which yields first time)

        Workflow_Instance__c inst = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Running', inst.Status__c);

        List<Workflow_Step_Execution__c> steps = [SELECT Status__c, Output__c FROM Workflow_Step_Execution__c WHERE Workflow_Instance__c = :instanceId];
        System.assertEquals(1, steps.size());
        System.assertEquals('Running', steps[0].Status__c);
        System.assert(steps[0].Output__c.contains('"processed":1'));

        // Manually run orchestrator for second yield (processed = 2)
        new WorkflowOrchestrator(instanceId).execute(null);
        steps = [SELECT Status__c, Output__c FROM Workflow_Step_Execution__c WHERE Workflow_Instance__c = :instanceId];
        System.assert(steps[0].Output__c.contains('"processed":2'));

        // Manually run orchestrator for third yield (processed = 3)
        new WorkflowOrchestrator(instanceId).execute(null);
        steps = [SELECT Status__c, Output__c FROM Workflow_Step_Execution__c WHERE Workflow_Instance__c = :instanceId];
        System.assert(steps[0].Output__c.contains('"processed":3'));

        // Manually run orchestrator for final complete
        new WorkflowOrchestrator(instanceId).execute(null);

        inst = [SELECT Status__c, Output__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Completed', inst.Status__c);
        System.assertEquals('"Done_3"', inst.Output__c);
    }

    @isTest
    static void testSuspensionAndResume() {
        Test.startTest();
        Id instanceId = WorkflowEngine.start('WorkflowEngineTest.SuspendingWorkflow', 'SuspendKey', null);
        Test.stopTest(); // Enqueues and executes SuspendingStep which suspends

        Workflow_Instance__c inst = [SELECT Status__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Suspended', inst.Status__c);
        System.assertEquals('WorkflowEngineTest.SuspendingStep', inst.Current_Step__c);

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

        inst = [SELECT Status__c, Output__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Completed', inst.Status__c);
        System.assertEquals('"Resumed_EventData"', inst.Output__c);
    }

    @isTest
    static void testSignals() {
        // Start a workflow that blocks on a signal
        Test.startTest();
        Id instanceId = WorkflowEngine.start('WorkflowEngineTest.SignaledWorkflow', 'SignalKey', null);
        Test.stopTest(); // Runs SignaledStep which suspends waiting for 'PaymentReceived'

        Workflow_Instance__c inst = [SELECT Status__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Suspended', inst.Status__c);
        System.assertEquals('WorkflowEngineTest.SignaledStep', inst.Current_Step__c);

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
            SELECT Signal_Name__c, Payload__c, Status__c FROM Workflow_Signal__c 
            WHERE Workflow_Instance__c = :instanceId
            LIMIT 1
        ];
        System.assertEquals('PaymentReceived', sig.Signal_Name__c);
        System.assertEquals('{"amount": 150}', sig.Payload__c);
        System.assertEquals('Received', sig.Status__c);

        // Manually execute the orchestrator to run the step again with the signal now populated
        new WorkflowOrchestrator(instanceId).execute(null);

        // Verify that the step completed and consumed the signal
        inst = [SELECT Status__c, Output__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Completed', inst.Status__c);
        System.assertEquals('"Paid_{\\"amount\\": 150}"', inst.Output__c);

        sig = [SELECT Status__c FROM Workflow_Signal__c WHERE Id = :sig.Id];
        System.assertEquals('Consumed', sig.Status__c);
    }

    @isTest
    static void testCustomRetryPolicy() {
        Test.startTest();
        Id instanceId = WorkflowEngine.start('WorkflowEngineTest.CustomRetryWorkflow', 'RetryKey', null);
        Test.stopTest(); // Runs CustomRetryStep once synchronously, which fails and triggers first retry (attempts=1, delay=2s)

        Workflow_Step_Execution__c step = [SELECT Status__c, Retry_Count__c FROM Workflow_Step_Execution__c WHERE Workflow_Instance__c = :instanceId LIMIT 1];
        System.assertEquals('Retrying', step.Status__c);
        System.assertEquals(1, step.Retry_Count__c);

        // Run second attempt manually
        WorkflowEngine.runStep(instanceId); // CustomRetryStep runs, returns retry, triggers second retry (attempts=2, delay=6s)
        
        step = [SELECT Status__c, Retry_Count__c FROM Workflow_Step_Execution__c WHERE Workflow_Instance__c = :instanceId LIMIT 1];
        System.assertEquals('Retrying', step.Status__c);
        System.assertEquals(2, step.Retry_Count__c);

        // Run third attempt manually (should exceed maximum attempts of 3)
        WorkflowEngine.runStep(instanceId); // CustomRetryStep runs, returns retry, attempts=3 >= maximumAttempts(3) -> transitions to Failed

        step = [SELECT Status__c, Retry_Count__c FROM Workflow_Step_Execution__c WHERE Workflow_Instance__c = :instanceId LIMIT 1];
        System.assertEquals('Failed', step.Status__c);
        System.assertEquals(3, step.Retry_Count__c);

        Workflow_Instance__c inst = [SELECT Status__c, Error_Message__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Failed', inst.Status__c);
        System.assert(inst.Error_Message__c.contains('Max retries exceeded'));
    }

    @isTest
    static void testCrashAndFinalizer() {
        Id instanceId = WorkflowEngine.start('WorkflowEngineTest.CrashingWorkflow', 'CrashKey', null);
        
        Workflow_Instance__c inst = [SELECT Id, Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
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
        
        inst = [SELECT Status__c, Error_Message__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Failed', inst.Status__c);
        System.assert(inst.Error_Message__c.contains('Simulated Crash'));
        
        Workflow_Step_Execution__c step = [SELECT Status__c, Error_Details__c FROM Workflow_Step_Execution__c WHERE Workflow_Instance__c = :instanceId LIMIT 1];
        System.assertEquals('Failed', step.Status__c);
        System.assert(step.Error_Details__c.contains('Simulated Crash'));
    }

    @isTest
    static void testSleepingWorkflow() {
        Test.startTest();
        Id instanceId = WorkflowEngine.start('WorkflowEngineTest.SleepingWorkflow', 'SleepKey', null);
        Test.stopTest(); // Runs SleepingStep once synchronously, which requests sleep

        Workflow_Instance__c inst = [SELECT Status__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Suspended', inst.Status__c);
        System.assertEquals('WorkflowEngineTest.SleepingStep', inst.Current_Step__c);

        Workflow_Step_Execution__c step = [SELECT Status__c, Output__c FROM Workflow_Step_Execution__c WHERE Workflow_Instance__c = :instanceId LIMIT 1];
        System.assertEquals('Pending', step.Status__c);
        System.assertEquals('resumed_state', step.Output__c);

        // Manually call runStep to simulate the timer firing and enqueuing execution
        WorkflowEngine.runStep(instanceId); // SleepingStep runs again, sees stepStateJson != null, completes.

        // Manually execute second step (AfterSleepStep) synchronously
        new WorkflowOrchestrator(instanceId).execute(null);

        inst = [SELECT Status__c, Output__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Completed', inst.Status__c);
        System.assertEquals('"Done_resumed_state"', inst.Output__c);
    }

    @isTest
    static void testParentChildWorkflow() {
        Test.startTest();
        Id parentId = WorkflowEngine.start('WorkflowEngineTest.ParentWorkflow', 'ParentKey', null);
        Test.stopTest(); // Executes ParentStep once, starts child, and suspends parent

        Workflow_Instance__c parentInst = [SELECT Status__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :parentId];
        System.assertEquals('Suspended', parentInst.Status__c);

        Workflow_Step_Execution__c parentStep = [
            SELECT Output__c 
            FROM Workflow_Step_Execution__c 
            WHERE Workflow_Instance__c = :parentId 
            AND Step_Name__c = 'WorkflowEngineTest.ParentStep'
            LIMIT 1
        ];
        System.assertNotEquals(null, parentStep.Output__c);
        Map<String, Object> childInfo = (Map<String, Object>)JSON.deserializeUntyped(parentStep.Output__c);
        System.assertEquals('WorkflowEngineTest.ChildWorkflow', childInfo.get('childWorkflowName'));
        System.assertEquals('SubKey', childInfo.get('childCorrelationKey'));

        Workflow_Instance__c childInst = [
            SELECT Id, Status__c, Parent_Instance__c, Correlation_Key__c 
            FROM Workflow_Instance__c 
            WHERE Parent_Instance__c = :parentId 
            LIMIT 1
        ];
        System.assertEquals('SubKey', childInst.Correlation_Key__c);
        System.assertEquals('Pending', childInst.Status__c);

        // Execute child workflow synchronously
        new WorkflowOrchestrator(childInst.Id).execute(null); // ChildStep completes, triggers child completion event

        // Deliver Platform Event (ChildCompleted) to parent
        Test.getEventBus().deliver(); // Parent becomes Running, enqueues orchestrator

        // Manually run orchestrator for parent to consume child output signal and complete
        new WorkflowOrchestrator(parentId).execute(null);

        parentInst = [SELECT Status__c, Output__c FROM Workflow_Instance__c WHERE Id = :parentId];
        System.assertEquals('Completed', parentInst.Status__c);
        System.assertEquals('"ParentResult_ChildInput_ChildDone"', parentInst.Output__c);
    }

    @isTest
    static void testRetryWorkflow() {
        // Start the workflow that will fail
        Id instanceId = WorkflowEngine.start('WorkflowEngineTest.FailingWorkflow', 'FailingKey', null);
        
        // Execute failing step manually. It will request a retry and hit maxAttempts = 1, resulting in Failure.
        new WorkflowOrchestrator(instanceId).execute(null);

        Workflow_Instance__c inst = [
            SELECT Status__c, Error_Message__c, Current_Step__c 
            FROM Workflow_Instance__c 
            WHERE Id = :instanceId
        ];
        System.assertEquals('Failed', inst.Status__c, 'Should be failed');
        System.assertNotEquals(null, inst.Error_Message__c);

        Workflow_Step_Execution__c stepExec = [
            SELECT Status__c, Retry_Count__c, Error_Details__c 
            FROM Workflow_Step_Execution__c 
            WHERE Workflow_Instance__c = :instanceId 
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
            SELECT Status__c, Error_Message__c 
            FROM Workflow_Instance__c 
            WHERE Id = :instanceId
        ];
        System.assertEquals('Completed', retriedInst.Status__c, 'Should complete successfully now');
        System.assertEquals(null, retriedInst.Error_Message__c);
    }

    @isTest
    static void testWorkflowTimeout() {
        // Start a workflow instance
        Id instanceId = WorkflowEngine.start('WorkflowEngineTest.TimeoutWorkflow', 'TimeoutKey', null);
        
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
            SELECT Id, Status__c FROM Workflow_Step_Execution__c 
            WHERE Workflow_Instance__c = :instanceId
            AND Step_Name__c = 'WorkflowEngineTest.TimeoutStep'
            LIMIT 1
        ];
        System.assert(!stepExecs.isEmpty());
        Workflow_Step_Execution__c stepExec = stepExecs[0];
        stepExec.Status__c = 'Running';
        update stepExec;

        // Manually run the timeout job
        Test.startTest();
        WorkflowTimeoutJob job = new WorkflowTimeoutJob(instanceId, 'WorkflowEngineTest.TimeoutStep');
        job.execute(null);
        Test.stopTest();

        // Check if both records are marked Failed
        Workflow_Instance__c timedOutInst = [
            SELECT Status__c, Error_Message__c 
            FROM Workflow_Instance__c 
            WHERE Id = :instanceId
        ];
        System.assertEquals('Failed', timedOutInst.Status__c);
        System.assertEquals('Step WorkflowEngineTest.TimeoutStep timed out.', timedOutInst.Error_Message__c);

        Workflow_Step_Execution__c timedOutStep = [
            SELECT Status__c, Error_Details__c 
            FROM Workflow_Step_Execution__c 
            WHERE Id = :stepExec.Id
        ];
        System.assertEquals('Failed', timedOutStep.Status__c);
        System.assertEquals('Step execution timed out.', timedOutStep.Error_Details__c);
    }

    @isTest
    static void testWorkflowApproval() {
        Id instanceId = WorkflowEngine.start('WorkflowEngineTest.ApprovalWorkflow', 'ApprovalKey', null);
        
        // Execute initial step. It will return waitForApproval and suspend.
        new WorkflowOrchestrator(instanceId).execute(null);

        Workflow_Instance__c inst = [
            SELECT Status__c, Current_Step__c 
            FROM Workflow_Instance__c 
            WHERE Id = :instanceId
        ];
        System.assertEquals('Suspended', inst.Status__c);
        System.assertEquals('WorkflowEngineTest.ApprovalStep', inst.Current_Step__c);

        Workflow_Step_Execution__c stepExec = [
            SELECT Status__c, Output__c 
            FROM Workflow_Step_Execution__c 
            WHERE Workflow_Instance__c = :instanceId
            AND Step_Name__c = 'WorkflowEngineTest.ApprovalStep'
            LIMIT 1
        ];
        System.assertEquals('Pending', stepExec.Status__c);
        System.assert(stepExec.Output__c.contains('"waitingForApproval":true'));
        System.assert(stepExec.Output__c.contains('"approvalKey":"ExpenseApproval"'));
        System.assert(stepExec.Output__c.contains('"approvalRole":"Manager"'));

        // Signal the approval
        Test.startTest();
        WorkflowEngine.signal('ApprovalKey', 'Approve:ExpenseApproval', '{"approved":true,"comments":"Approved","approver":"test@example.com"}');
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
            return StepResult.split(new List<String>{
                'WorkflowEngineTest.ParallelStep1',
                'WorkflowEngineTest.ParallelStep2'
            }, 'BranchInput');
        }
    }

    public class ParallelStep1 implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            String input = (String)JSON.deserialize(ctx.inputJson, String.class);
            return StepResult.complete(null, input + '_P1Done');
        }
    }

    public class ParallelStep2 implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            String input = (String)JSON.deserialize(ctx.inputJson, String.class);
            return StepResult.complete(null, input + '_P2Done');
        }
    }

    public class JoinStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            Map<String, Object> inputMap = (Map<String, Object>)JSON.deserializeUntyped(ctx.inputJson);
            String out1 = (String)inputMap.get('WorkflowEngineTest.ParallelStep1');
            String out2 = (String)inputMap.get('WorkflowEngineTest.ParallelStep2');
            return StepResult.complete(null, out1 + '+' + out2);
        }
    }

    @isTest
    static void testParallelExecution() {
        Id instanceId = WorkflowEngine.start('WorkflowEngineTest.ParallelWorkflow', 'ParallelKey', null);
        
        // Run initial SplitStep
        new WorkflowOrchestrator(instanceId).execute(null);

        Workflow_Instance__c inst = [
            SELECT Status__c, Current_Step__c 
            FROM Workflow_Instance__c 
            WHERE Id = :instanceId
        ];
        System.assertEquals('Running', inst.Status__c);
        System.assertEquals('WorkflowEngineTest.ParallelStep1,WorkflowEngineTest.ParallelStep2', inst.Current_Step__c);

        // Run ParallelStep1 manually
        new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.ParallelStep1').execute(null);

        // Verify workflow is still running and waiting for ParallelStep2
        inst = [SELECT Status__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Running', inst.Status__c);

        // Run ParallelStep2 manually
        new WorkflowOrchestrator(instanceId, 'WorkflowEngineTest.ParallelStep2').execute(null);

        // Run JoinStep manually
        new WorkflowOrchestrator(instanceId).execute(null);

        // Verify JoinStep has executed and completed the workflow
        inst = [SELECT Status__c, Output__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Completed', inst.Status__c);
        System.assertEquals('"BranchInput_P1Done+BranchInput_P2Done"', inst.Output__c);
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

    @isTest
    static void testCompensationFlow() {
        WorkflowEngine.disableQueueableInTest = true;
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Compensating',
            Compensation_Stack__c = JSON.serialize(new List<String>{
                'WorkflowEngineTest.NonCompensatableStep',
                'WorkflowEngineTest.CompensatableHappyStep'
            }),
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
        System.assertEquals('WorkflowEngineTest.CompensatableHappyStep_Compensate', stepExecs[1].Step_Name__c);
        System.assertEquals('Compensated', stepExecs[1].Status__c);
        System.assertEquals('"Compensated"', stepExecs[1].Output__c);

        System.assertEquals('WorkflowEngineTest.NonCompensatableStep_Compensate', stepExecs[2].Step_Name__c);
        System.assertEquals('Compensated', stepExecs[2].Status__c);
    }

    @isTest
    static void testCompensationFailureAndRetry() {
        WorkflowEngine.disableQueueableInTest = true;
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
            Status__c = 'Compensating',
            Compensation_Stack__c = JSON.serialize(new List<String>{
                'WorkflowEngineTest.CompensatableFailingStep'
            }),
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
            WHERE Workflow_Instance__c = :inst.Id
            AND Step_Name__c = 'WorkflowEngineTest.CompensatableFailingStep_Compensate'
        ];
        System.assertEquals(1, execs.size());
        System.assertEquals('Retrying', execs[0].Status__c);
        System.assertEquals(1, execs[0].Retry_Count__c);

        // Run second time - should exceed maximum attempts (maximumAttempts = 2) and fail
        WorkflowEngine.runStep(inst.Id, null);
        Test.stopTest();

        Workflow_Instance__c failedInst = [
            SELECT Status__c, Error_Message__c 
            FROM Workflow_Instance__c 
            WHERE Id = :inst.Id
        ];
        System.assertEquals('Failed', failedInst.Status__c);
        System.assert(failedInst.Error_Message__c.contains('failed after max retries'));

        Workflow_Step_Execution__c failedExec = [
            SELECT Status__c, Retry_Count__c 
            FROM Workflow_Step_Execution__c 
            WHERE Id = :execs[0].Id
        ];
        System.assertEquals('Failed', failedExec.Status__c);
        System.assertEquals(2, failedExec.Retry_Count__c);

        // Now test retryWorkflow on failed compensation!
        WorkflowEngineTest.compensationShouldFail = false;

        WorkflowEngine.retryWorkflow(inst.Id);
        WorkflowEngine.runStep(inst.Id, null); // Runs the compensation step (completes)
        WorkflowEngine.runStep(inst.Id, null); // Stack empty -> transition status to Compensated

        Workflow_Instance__c retriedInst = [
            SELECT Status__c, Error_Message__c 
            FROM Workflow_Instance__c 
            WHERE Id = :inst.Id
        ];
        System.assertEquals('Compensated', retriedInst.Status__c);

        Workflow_Step_Execution__c finalExec = [
            SELECT Status__c, Output__c 
            FROM Workflow_Step_Execution__c 
            WHERE Id = :execs[0].Id
        ];
        System.assertEquals('Compensated', finalExec.Status__c);
        System.assertEquals('"CompensatedFailing"', finalExec.Output__c);
    }

    @isTest
    static void testCancelWorkflowActiveNoCompensations() {
        Test.startTest();
        Id instanceId = WorkflowEngine.start('WorkflowEngineTest.SuspendingWorkflow', 'CancelKey1', null);
        Test.stopTest(); // Executes initial step and suspends
        
        Workflow_Instance__c inst = [SELECT Status__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Suspended', inst.Status__c);
        System.assertEquals('WorkflowEngineTest.SuspendingStep', inst.Current_Step__c);
        
        WorkflowEngine.cancel(instanceId, false);

        inst = [SELECT Status__c, Current_Step__c, Error_Message__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Cancelled', inst.Status__c);
        System.assertEquals('Cancelled by user.', inst.Error_Message__c);
        
        List<Workflow_Step_Execution__c> steps = [
            SELECT Status__c FROM Workflow_Step_Execution__c 
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
        Id instanceId = WorkflowEngine.start('SagaWorkflowExample.SagaWorkflow', 'CancelKey2', null);
        
        // Run first step (ChargeCreditCardStep) to push to stack
        WorkflowEngine.runStep(instanceId, null);
        
        Workflow_Instance__c inst = [SELECT Status__c, Current_Step__c, Compensation_Stack__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('SagaWorkflowExample.ProvisionServiceStep', inst.Current_Step__c);
        System.assert(inst.Compensation_Stack__c.contains('SagaWorkflowExample.ChargeCreditCardStep'));

        Test.startTest();
        // Cancel with compensations
        WorkflowEngine.cancel(instanceId, true);
        
        // Assert status is now Cancelling
        inst = [SELECT Status__c, Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
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
        Id instanceId = WorkflowEngine.start('WorkflowEngineTest.SleepingWorkflow', 'CancelKey3', null);
        Test.stopTest(); // Runs the queueable and puts the workflow to Sleep (Suspended)
        
        Workflow_Instance__c inst = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Suspended', inst.Status__c);

        // Cancel sleeping workflow
        WorkflowEngine.cancel(instanceId, false);

        inst = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Cancelled', inst.Status__c);
    }

    @isTest
    static void testCancelWorkflowParentChild() {
        WorkflowEngine.disableQueueableInTest = true;
        Id parentId = WorkflowEngine.start('WorkflowEngineTest.ParentWorkflow', 'CancelParent', null);
        
        // Execute parent, which starts child and suspends
        WorkflowEngine.runStep(parentId, null);
        
        Workflow_Instance__c childInst = [
            SELECT Id, Status__c FROM Workflow_Instance__c 
            WHERE Parent_Instance__c = :parentId 
            LIMIT 1
        ];
        System.assertEquals('Pending', childInst.Status__c);

        Test.startTest();
        // Cancel parent, should recursively cancel child
        WorkflowEngine.cancel(parentId, false);
        Test.stopTest();

        Workflow_Instance__c parent = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :parentId];
        childInst = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :childInst.Id];
        
        System.assertEquals('Cancelled', parent.Status__c);
        System.assertEquals('Cancelled', childInst.Status__c);
    }

    @isTest
    static void testCancelWorkflowViaSignal() {
        WorkflowEngine.disableQueueableInTest = true;
        Id instanceId = WorkflowEngine.start('WorkflowEngineTest.HappyWorkflow', 'CancelSignalKey', null);
        
        Test.startTest();
        // Signal cancellation
        WorkflowEngine.signal('CancelSignalKey', 'Cancel', '{"runCompensations": false}');
        Test.stopTest();

        Workflow_Instance__c inst = [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId];
        System.assertEquals('Cancelled', inst.Status__c);
    }
}
