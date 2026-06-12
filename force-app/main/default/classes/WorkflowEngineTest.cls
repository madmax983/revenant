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
        System.assert(inst.Error_Message__c.contains('failed after max retries'));
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
}
