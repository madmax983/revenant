public with sharing class WorkflowEngine {
    
    public class WorkflowException extends Exception {}

    /**
     * Starts a new durable workflow instance.
     */
    public static Id start(String workflowName, String correlationKey, Object input) {
        // Enforce uniqueness of active correlation keys if provided
        if (String.isNotBlank(correlationKey)) {
            List<Workflow_Instance__c> existing = [
                SELECT Id FROM Workflow_Instance__c 
                WHERE Correlation_Key__c = :correlationKey 
                AND Status__c IN ('Pending', 'Running', 'Suspended')
                LIMIT 1
            ];
            if (!existing.isEmpty()) {
                throw new WorkflowException('An active workflow already exists with correlation key: ' + correlationKey);
            }
        }

        Workflow_Instance__c instance = new Workflow_Instance__c();
        instance.Workflow_Name__c = workflowName;
        instance.Status__c = 'Pending';
        instance.Correlation_Key__c = correlationKey;
        instance.Input__c = (input != null) ? JSON.serialize(input) : null;
        
        insert instance;

        // Enqueue the first step execution
        System.enqueueJob(new WorkflowOrchestrator(instance.Id));
        return instance.Id;
    }

    /**
     * Resumes a suspended workflow matching the correlation key.
     */
    public static void resume(String correlationKey, String payload) {
        List<Workflow_Instance__c> instances = [
            SELECT Id, Workflow_Name__c, Current_Step__c FROM Workflow_Instance__c 
            WHERE Correlation_Key__c = :correlationKey 
            AND Status__c = 'Suspended'
            LIMIT 1
            FOR UPDATE
        ];

        if (instances.isEmpty()) {
            throw new WorkflowException('No suspended workflow found with correlation key: ' + correlationKey);
        }

        Workflow_Instance__c instance = instances[0];
        instance.Status__c = 'Running';
        update instance;

        // If there is an active step, we can store the resume payload in its step execution record
        if (String.isNotBlank(instance.Current_Step__c)) {
            List<Workflow_Step_Execution__c> activeSteps = [
                SELECT Id, Output__c FROM Workflow_Step_Execution__c
                WHERE Workflow_Instance__c = :instance.Id
                AND Step_Name__c = :instance.Current_Step__c
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (!activeSteps.isEmpty()) {
                Workflow_Step_Execution__c stepExec = activeSteps[0];
                stepExec.Status__c = 'Running';
                stepExec.Output__c = payload; // The resume payload is passed as the step's "state/output"
                update stepExec;
            }
        }

        System.enqueueJob(new WorkflowOrchestrator(instance.Id));
    }

    /**
     * Executes the active step for a workflow instance. Designed to run in a Queueable context.
     */
    public static void runStep(Id instanceId) {
        // 1. Lock and fetch instance state
        List<Workflow_Instance__c> instances = [
            SELECT Id, Workflow_Name__c, Status__c, Current_Step__c, Input__c, Correlation_Key__c 
            FROM Workflow_Instance__c 
            WHERE Id = :instanceId 
            LIMIT 1
            FOR UPDATE
        ];

        if (instances.isEmpty()) {
            throw new WorkflowException('Workflow instance not found: ' + instanceId);
        }

        Workflow_Instance__c instance = instances[0];
        if (instance.Status__c == 'Completed' || instance.Status__c == 'Failed') {
            return; // Already finished
        }

        // 2. Initialize initial step if this is the start
        if (String.isBlank(instance.Current_Step__c)) {
            Type wflowType = Type.forName(instance.Workflow_Name__c);
            if (wflowType == null) {
                throw new WorkflowException('Could not resolve workflow definition class: ' + instance.Workflow_Name__c);
            }
            WorkflowDefinition def = (WorkflowDefinition)wflowType.newInstance();
            instance.Current_Step__c = def.getInitialStep();
            instance.Status__c = 'Running';
            update instance;
        }

        // 3. Retrieve or create Step Execution log
        List<Workflow_Step_Execution__c> stepExecs = [
            SELECT Id, Status__c, Input__c, Output__c, Retry_Count__c
            FROM Workflow_Step_Execution__c
            WHERE Workflow_Instance__c = :instanceId
            AND Step_Name__c = :instance.Current_Step__c
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        Workflow_Step_Execution__c stepExec;
        if (stepExecs.isEmpty()) {
            stepExec = new Workflow_Step_Execution__c();
            stepExec.Workflow_Instance__c = instanceId;
            stepExec.Step_Name__c = instance.Current_Step__c;
            stepExec.Status__c = 'Running';
            stepExec.Retry_Count__c = 0;
            
            // Get previous step's output to feed as input
            List<Workflow_Step_Execution__c> completedSteps = [
                SELECT Output__c FROM Workflow_Step_Execution__c
                WHERE Workflow_Instance__c = :instanceId
                AND Status__c = 'Completed'
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            stepExec.Input__c = !completedSteps.isEmpty() ? completedSteps[0].Output__c : instance.Input__c;
            insert stepExec;
        } else {
            stepExec = stepExecs[0];
            if (stepExec.Status__c == 'Completed') {
                throw new WorkflowException('Current step ' + instance.Current_Step__c + ' is already completed.');
            }
            stepExec.Status__c = 'Running';
            update stepExec;
        }

        // 4. Resolve previous step output & step state (for yielded/resumed executions)
        String prevOutput = null;
        List<Workflow_Step_Execution__c> lastCompleted = [
            SELECT Output__c FROM Workflow_Step_Execution__c
            WHERE Workflow_Instance__c = :instanceId
            AND Status__c = 'Completed'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!lastCompleted.isEmpty()) {
            prevOutput = lastCompleted[0].Output__c;
        }

        // 5. Invoke Step Execution
        Type stepType = Type.forName(instance.Current_Step__c);
        if (stepType == null) {
            throw new WorkflowException('Could not resolve class for step: ' + instance.Current_Step__c);
        }
        WorkflowStep stepInstance = (WorkflowStep)stepType.newInstance();
        
        StepContext context = new StepContext(
            instanceId,
            instance.Workflow_Name__c,
            instance.Current_Step__c,
            instance.Input__c,
            prevOutput,
            stepExec.Output__c // If yielded or resumed, output field holds the intermediate state
        );

        StepResult result = stepInstance.execute(context);

        // 6. Handle Step Outcome
        handleStepResult(instance, stepExec, result);
    }

    private static void handleStepResult(Workflow_Instance__c instance, Workflow_Step_Execution__c stepExec, StepResult result) {
        if (result.action == StepResult.ActionType.COMPLETE) {
            // Step is complete. Store output.
            stepExec.Status__c = 'Completed';
            stepExec.Output__c = result.outputJson;
            update stepExec;

            // Determine next step
            Type wflowType = Type.forName(instance.Workflow_Name__c);
            WorkflowDefinition def = (WorkflowDefinition)wflowType.newInstance();
            String nextStepName = def.getNextStep(instance.Current_Step__c, result);

            if (String.isBlank(nextStepName)) {
                // Workflow is finished
                instance.Status__c = 'Completed';
                instance.Output__c = result.outputJson;
                instance.Current_Step__c = null;
                update instance;
            } else {
                // Advance to next step
                instance.Current_Step__c = nextStepName;
                update instance;
                if (!Test.isRunningTest()) {
                    System.enqueueJob(new WorkflowOrchestrator(instance.Id));
                }
            }
            
        } else if (result.action == StepResult.ActionType.YIELD) {
            // Step yielded (e.g. Apex Cursor chunk). Save state to Output and run again in a new transaction.
            stepExec.Status__c = 'Running';
            stepExec.Output__c = result.stepStateJson;
            update stepExec;

            if (!Test.isRunningTest()) {
                System.enqueueJob(new WorkflowOrchestrator(instance.Id));
            }

        } else if (result.action == StepResult.ActionType.SUSPEND) {
            // Step suspended (waiting for external signal). Save state and mark instance.
            stepExec.Status__c = 'Pending';
            update stepExec;

            instance.Status__c = 'Suspended';
            update instance;

        } else if (result.action == StepResult.ActionType.RETRY) {
            // Step requested retry
            stepExec.Retry_Count__c += 1;
            
            // Get or default retry policy
            RetryPolicy policy = (result.retryPolicy != null) 
                ? result.retryPolicy 
                : new RetryPolicy();
            
            if (stepExec.Retry_Count__c >= policy.maximumAttempts) {
                stepExec.Status__c = 'Failed';
                stepExec.Error_Details__c = 'Max retries (' + policy.maximumAttempts + ') exceeded.';
                update stepExec;

                instance.Status__c = 'Failed';
                instance.Error_Message__c = 'Step ' + instance.Current_Step__c + ' failed after max retries.';
                update instance;
            } else {
                stepExec.Status__c = 'Retrying';
                update stepExec;
                
                // Calculate exponential backoff
                // delay = initialInterval * (coefficient ^ (retryCount - 1))
                Double backoff = Math.pow((Double)policy.backoffCoefficient, (Double)(stepExec.Retry_Count__c - 1));
                Integer delay = (Integer)(policy.initialIntervalSeconds * backoff);
                
                // Cap the backoff delay to 24 hours (86400 seconds) for sanity
                delay = Math.min(delay, 86400);
                
                scheduleRetry(instance.Id, delay);
            }
        }
    }

    /**
     * Rescues a workflow when the host transaction fails or hits governor limits.
     * Invoked from a System.Finalizer.
     */
    public static void handleCrash(Id instanceId, Exception ex) {
        // Run as separate DML transaction to ensure it's written even if parent rolled back
        List<Workflow_Instance__c> instances = [
            SELECT Id, Current_Step__c FROM Workflow_Instance__c 
            WHERE Id = :instanceId 
            LIMIT 1
            FOR UPDATE
        ];

        if (instances.isEmpty()) {
            return;
        }

        Workflow_Instance__c instance = instances[0];
        instance.Status__c = 'Failed';
        instance.Error_Message__c = 'Transaction crashed: ' + (ex != null ? ex.getMessage() + '\n' + ex.getStackTraceString() : 'Unknown governor limit / crash');
        update instance;

        if (String.isNotBlank(instance.Current_Step__c)) {
            List<Workflow_Step_Execution__c> stepExecs = [
                SELECT Id FROM Workflow_Step_Execution__c
                WHERE Workflow_Instance__c = :instanceId
                AND Step_Name__c = :instance.Current_Step__c
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (!stepExecs.isEmpty()) {
                Workflow_Step_Execution__c stepExec = stepExecs[0];
                stepExec.Status__c = 'Failed';
                stepExec.Error_Details__c = (ex != null ? ex.getMessage() + '\n' + ex.getStackTraceString() : 'Unknown governor limit / crash');
                update stepExec;
            }
        }
    }

    private static void scheduleRetry(Id instanceId, Integer delaySeconds) {
        // Enqueue delayed execution via Scheduled Apex
        WorkflowRetryJob job = new WorkflowRetryJob(instanceId);
        Datetime runTime = Datetime.now().addSeconds(delaySeconds);
        String cronStr = runTime.second() + ' ' + runTime.minute() + ' ' + runTime.hour() + ' ' + runTime.day() + ' ' + runTime.month() + ' ? ' + runTime.year();
        System.schedule('WorkflowRetry_' + instanceId + '_' + runTime.getTime(), cronStr, job);
    }

    /**
     * Sends an external signal to a workflow instance by correlation key.
     */
    public static void signal(String correlationKey, String signalName, String payload) {
        List<Workflow_Instance__c> instances = [
            SELECT Id, Status__c FROM Workflow_Instance__c 
            WHERE Correlation_Key__c = :correlationKey 
            AND Status__c IN ('Pending', 'Running', 'Suspended')
            LIMIT 1
            FOR UPDATE
        ];

        if (instances.isEmpty()) {
            throw new WorkflowException('No active workflow found with correlation key: ' + correlationKey);
        }

        Workflow_Instance__c instance = instances[0];

        // Insert the signal record
        Workflow_Signal__c sig = new Workflow_Signal__c();
        sig.Workflow_Instance__c = instance.Id;
        sig.Signal_Name__c = signalName;
        sig.Payload__c = payload;
        sig.Status__c = 'Received';
        insert sig;

        // If the workflow is suspended, resume it
        if (instance.Status__c == 'Suspended') {
            instance.Status__c = 'Running';
            update instance;

            // Enqueue orchestrator to run the step again
            System.enqueueJob(new WorkflowOrchestrator(instance.Id));
        }
    }
}
