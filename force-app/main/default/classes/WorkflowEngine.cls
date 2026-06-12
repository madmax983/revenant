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
                ORDER BY CreatedDate DESC, Id DESC
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
        runStep(instanceId, null);
    }

    public static void runStep(Id instanceId, String stepName) {
        // 1. Lock and fetch instance state
        List<Workflow_Instance__c> instances = [
            SELECT Id, Workflow_Name__c, Status__c, Current_Step__c, Input__c, Correlation_Key__c, Parent_Instance__c 
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
        } else if (instance.Status__c == 'Suspended' || instance.Status__c == 'Pending') {
            instance.Status__c = 'Running';
            update instance;
        }

        // Determine step name to execute
        String activeStepName = String.isNotBlank(stepName) ? stepName : instance.Current_Step__c;

        // 3. Retrieve or create Step Execution log
        List<Workflow_Step_Execution__c> stepExecs = [
            SELECT Id, Status__c, Input__c, Output__c, Retry_Count__c
            FROM Workflow_Step_Execution__c
            WHERE Workflow_Instance__c = :instanceId
            AND Step_Name__c = :activeStepName
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];

        Workflow_Step_Execution__c stepExec;
        if (stepExecs.isEmpty()) {
            stepExec = new Workflow_Step_Execution__c();
            stepExec.Workflow_Instance__c = instanceId;
            stepExec.Step_Name__c = activeStepName;
            stepExec.Status__c = 'Running';
            stepExec.Retry_Count__c = 0;
            
            // Get previous step's output to feed as input
            List<Workflow_Step_Execution__c> completedSteps = [
                SELECT Output__c FROM Workflow_Step_Execution__c
                WHERE Workflow_Instance__c = :instanceId
                AND Status__c = 'Completed'
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT 1
            ];
            stepExec.Input__c = !completedSteps.isEmpty() ? completedSteps[0].Output__c : instance.Input__c;
            insert stepExec;
        } else {
            stepExec = stepExecs[0];
            if (stepExec.Status__c == 'Completed') {
                throw new WorkflowException('Current step ' + activeStepName + ' is already completed.');
            }
            stepExec.Status__c = 'Running';
            update stepExec;
        }

        // 4. Resolve previous step output & step state (for yielded/resumed executions)
        String prevOutput = null;
        List<Workflow_Step_Execution__c> lastCompleted;
        if (String.isNotBlank(stepName) && String.isNotBlank(instance.Current_Step__c) && instance.Current_Step__c.contains(',')) {
            List<String> activeParallelSteps = instance.Current_Step__c.split(',');
            lastCompleted = [
                SELECT Output__c FROM Workflow_Step_Execution__c
                WHERE Workflow_Instance__c = :instanceId
                AND Status__c = 'Completed'
                AND Step_Name__c NOT IN :activeParallelSteps
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT 1
            ];
        } else {
            lastCompleted = [
                SELECT Output__c FROM Workflow_Step_Execution__c
                WHERE Workflow_Instance__c = :instanceId
                AND Status__c = 'Completed'
                AND Step_Name__c != :activeStepName
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT 1
            ];
        }
        if (!lastCompleted.isEmpty()) {
            prevOutput = lastCompleted[0].Output__c;
        }

        // 5. Invoke Step Execution
        Type stepType = Type.forName(activeStepName);
        if (stepType == null) {
            throw new WorkflowException('Could not resolve class for step: ' + activeStepName);
        }
        WorkflowStep stepInstance = (WorkflowStep)stepType.newInstance();
        
        StepContext context = new StepContext(
            instanceId,
            instance.Workflow_Name__c,
            activeStepName,
            stepExec.Input__c,
            prevOutput,
            stepExec.Output__c,
            instance.Input__c
        );

        // Determine step timeout if configured
        Integer timeoutSeconds = null;
        if (stepInstance instanceof TimeoutConfigurable) {
            timeoutSeconds = ((TimeoutConfigurable)stepInstance).getTimeoutSeconds();
        }

        // Schedule timeout watch job if configured
        if (timeoutSeconds != null && timeoutSeconds > 0) {
            WorkflowTimeoutJob job = new WorkflowTimeoutJob(instanceId, activeStepName);
            Datetime runTime = Datetime.now().addSeconds(timeoutSeconds);
            String cronStr = runTime.second() + ' ' + runTime.minute() + ' ' + runTime.hour() + ' ' + runTime.day() + ' ' + runTime.month() + ' ? ' + runTime.year();
            String cleanStepName = activeStepName.replaceAll('[^a-zA-Z0-9]', '_');
            String jobName = 'Timeout_' + instanceId + '_' + cleanStepName;
            System.schedule(jobName, cronStr, job);
        }

        StepResult result;
        try {
            result = stepInstance.execute(context);
        } finally {
            // Cancel timeout watch job if it hasn't run yet
            if (timeoutSeconds != null && timeoutSeconds > 0) {
                cancelTimeoutJob(instanceId, activeStepName);
            }
        }

        // 6. Handle Step Outcome
        handleStepResult(instance, stepExec, result);
    }

    private static void handleStepResult(Workflow_Instance__c instance, Workflow_Step_Execution__c stepExec, StepResult result) {
        // Re-query to avoid overwriting a timeout or finalizer crash status
        Workflow_Instance__c freshInstance = [
            SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instance.Id
        ];
        if (freshInstance.Status__c == 'Failed') {
            throw new WorkflowException('Workflow execution was terminated (e.g. timed out or crashed).');
        }

        if (result.action == StepResult.ActionType.COMPLETE) {
            // Step is complete. Store output.
            stepExec.Status__c = 'Completed';
            stepExec.Output__c = result.outputJson;
            update stepExec;

            Boolean isParallel = String.isNotBlank(instance.Current_Step__c) && instance.Current_Step__c.contains(',');
            if (isParallel) {
                List<String> activeParallelSteps = instance.Current_Step__c.split(',');
                List<Workflow_Step_Execution__c> parallelExecs = [
                    SELECT Step_Name__c, Status__c, Output__c 
                    FROM Workflow_Step_Execution__c 
                    WHERE Workflow_Instance__c = :instance.Id 
                    AND Step_Name__c IN :activeParallelSteps
                ];
                
                Boolean allDone = true;
                for (String ps : activeParallelSteps) {
                    Boolean found = false;
                    for (Workflow_Step_Execution__c pe : parallelExecs) {
                        if (pe.Step_Name__c == ps && pe.Status__c == 'Completed') {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        allDone = false;
                        break;
                    }
                }

                if (allDone) {
                    // All parallel steps completed. Proceed to Join step.
                    List<Workflow_Step_Execution__c> spawningSteps = [
                        SELECT Step_Name__c, Output__c 
                        FROM Workflow_Step_Execution__c
                        WHERE Workflow_Instance__c = :instance.Id
                        AND Status__c = 'Completed'
                        AND Step_Name__c NOT IN :activeParallelSteps
                        ORDER BY CreatedDate DESC, Id DESC
                        LIMIT 1
                    ];

                    Type wflowType = Type.forName(instance.Workflow_Name__c);
                    WorkflowDefinition def = (WorkflowDefinition)wflowType.newInstance();
                    
                    String spawningStepName = !spawningSteps.isEmpty() ? spawningSteps[0].Step_Name__c : '';
                    StepResult mockResult = StepResult.complete(null, !spawningSteps.isEmpty() ? spawningSteps[0].Output__c : null);
                    String nextStepName = def.getNextStep(spawningStepName, mockResult);

                    Map<String, Object> joinInput = new Map<String, Object>();
                    for (Workflow_Step_Execution__c pe : parallelExecs) {
                        Object outputVal = null;
                        if (String.isNotBlank(pe.Output__c)) {
                            try {
                                outputVal = JSON.deserializeUntyped(pe.Output__c);
                            } catch (Exception ex) {
                                outputVal = pe.Output__c;
                            }
                        }
                        joinInput.put(pe.Step_Name__c, outputVal);
                    }
                    String joinInputJson = JSON.serialize(joinInput);

                    if (String.isNotBlank(nextStepName)) {
                        Workflow_Step_Execution__c joinStepExec = new Workflow_Step_Execution__c();
                        joinStepExec.Workflow_Instance__c = instance.Id;
                        joinStepExec.Step_Name__c = nextStepName;
                        joinStepExec.Status__c = 'Pending';
                        joinStepExec.Input__c = joinInputJson;
                        joinStepExec.Retry_Count__c = 0;
                        insert joinStepExec;

                        instance.Current_Step__c = nextStepName;
                        update instance;

                        if (!Test.isRunningTest()) {
                            System.enqueueJob(new WorkflowOrchestrator(instance.Id));
                        }
                    } else {
                        instance.Status__c = 'Completed';
                        instance.Output__c = joinInputJson;
                        instance.Current_Step__c = null;
                        update instance;

                        notifyParentCompletion(instance);
                    }
                }
            } else {
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

                    // Notify parent completion if this is a child workflow
                    notifyParentCompletion(instance);
                } else {
                    // Advance to next step
                    instance.Current_Step__c = nextStepName;
                    update instance;
                    if (!Test.isRunningTest()) {
                        System.enqueueJob(new WorkflowOrchestrator(instance.Id));
                    }
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

        } else if (result.action == StepResult.ActionType.SLEEP) {
            // Step requested sleep
            stepExec.Status__c = 'Pending';
            stepExec.Output__c = result.stepStateJson;
            update stepExec;

            instance.Status__c = 'Suspended';
            update instance;

            scheduleSleepResume(instance.Id, result.sleepDurationSeconds);

        } else if (result.action == StepResult.ActionType.START_CHILD) {
            // Step requested child workflow
            stepExec.Status__c = 'Pending';
            update stepExec;

            instance.Status__c = 'Suspended';
            update instance;

            startChildWorkflow(instance.Id, result.childWorkflowName, result.childCorrelationKey, result.childInputJson);

        } else if (result.action == StepResult.ActionType.WAIT_FOR_APPROVAL) {
            stepExec.Status__c = 'Pending';
            Map<String, Object> state = new Map<String, Object>{
                'waitingForApproval' => true,
                'approvalKey' => result.approvalKey,
                'approvalRole' => result.approvalRole
            };
            stepExec.Output__c = JSON.serialize(state);
            update stepExec;

            instance.Status__c = 'Suspended';
            update instance;

        } else if (result.action == StepResult.ActionType.SPLIT) {
            stepExec.Status__c = 'Completed';
            stepExec.Output__c = result.parallelInputJson != null ? result.parallelInputJson : result.outputJson;
            update stepExec;

            String parallelStepsStr = String.join(result.parallelStepNames, ',');
            instance.Current_Step__c = parallelStepsStr;
            instance.Status__c = 'Running';
            update instance;

            List<Workflow_Step_Execution__c> parallelExecs = new List<Workflow_Step_Execution__c>();
            for (String ps : result.parallelStepNames) {
                Workflow_Step_Execution__c pe = new Workflow_Step_Execution__c();
                pe.Workflow_Instance__c = instance.Id;
                pe.Step_Name__c = ps;
                pe.Status__c = 'Pending';
                pe.Input__c = result.parallelInputJson != null ? result.parallelInputJson : stepExec.Output__c;
                pe.Retry_Count__c = 0;
                parallelExecs.add(pe);
            }
            insert parallelExecs;

            for (String ps : result.parallelStepNames) {
                if (!Test.isRunningTest()) {
                    System.enqueueJob(new WorkflowOrchestrator(instance.Id, ps));
                }
            }

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
                ORDER BY CreatedDate DESC, Id DESC
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

    private static void scheduleSleepResume(Id instanceId, Integer delaySeconds) {
        // Enqueue sleep resumption via Scheduled Apex using WorkflowSleepJob
        WorkflowSleepJob job = new WorkflowSleepJob(instanceId);
        Datetime runTime = Datetime.now().addSeconds(delaySeconds);
        String cronStr = runTime.second() + ' ' + runTime.minute() + ' ' + runTime.hour() + ' ' + runTime.day() + ' ' + runTime.month() + ' ? ' + runTime.year();
        System.schedule('WorkflowSleep_' + instanceId + '_' + runTime.getTime(), cronStr, job);
    }

    private static void startChildWorkflow(Id parentId, String workflowName, String correlationKey, String inputJson) {
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
        instance.Input__c = inputJson;
        instance.Parent_Instance__c = parentId;
        
        insert instance;
        
        if (!Test.isRunningTest()) {
            System.enqueueJob(new WorkflowOrchestrator(instance.Id));
        }
    }

    private static void notifyParentCompletion(Workflow_Instance__c childInstance) {
        if (childInstance.Parent_Instance__c != null) {
            Workflow_Instance__c parent = [
                SELECT Correlation_Key__c FROM Workflow_Instance__c 
                WHERE Id = :childInstance.Parent_Instance__c
            ];
            
            String targetKey = String.isNotBlank(parent.Correlation_Key__c) 
                ? parent.Correlation_Key__c 
                : parent.Id;
            
            String signalName = 'ChildCompleted';
            if (String.isNotBlank(childInstance.Correlation_Key__c)) {
                signalName += ':' + childInstance.Correlation_Key__c;
            } else {
                signalName += ':' + childInstance.Id;
            }
            
            Workflow_Event__e event = new Workflow_Event__e(
                Workflow_Instance_Id__c = targetKey,
                Event_Type__c = 'SIGNAL:' + signalName,
                Payload__c = childInstance.Output__c
            );
            EventBus.publish(event);
        }
    }

    /**
     * Sends an external signal to a workflow instance by correlation key or instance ID.
     */
    public static void signal(String keyOrId, String signalName, String payload) {
        Boolean isId = false;
        Id targetId;
        try {
            targetId = (Id)keyOrId;
            isId = true;
        } catch (Exception ex) {
            // Not a valid ID
        }

        List<Workflow_Instance__c> instances;
        if (isId) {
            instances = [
                SELECT Id, Status__c FROM Workflow_Instance__c 
                WHERE (Correlation_Key__c = :keyOrId OR Id = :targetId)
                AND Status__c IN ('Pending', 'Running', 'Suspended')
                LIMIT 1
                FOR UPDATE
            ];
        } else {
            instances = [
                SELECT Id, Status__c FROM Workflow_Instance__c 
                WHERE Correlation_Key__c = :keyOrId 
                AND Status__c IN ('Pending', 'Running', 'Suspended')
                LIMIT 1
                FOR UPDATE
            ];
        }

        if (instances.isEmpty()) {
            throw new WorkflowException('No active workflow found with key or ID: ' + keyOrId);
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

    /**
     * Resumes a failed workflow instance from the step where it failed, resetting its state and retry counter.
     */
    public static void retryWorkflow(Id instanceId) {
        List<Workflow_Instance__c> instances = [
            SELECT Id, Status__c, Current_Step__c, Error_Message__c 
            FROM Workflow_Instance__c 
            WHERE Id = :instanceId 
            LIMIT 1
            FOR UPDATE
        ];
        if (instances.isEmpty()) {
            throw new WorkflowException('Workflow instance not found: ' + instanceId);
        }
        Workflow_Instance__c instance = instances[0];
        if (instance.Status__c != 'Failed') {
            throw new WorkflowException('Workflow instance is not in Failed status. Current status: ' + instance.Status__c);
        }

        // Reset the failed step's execution status to let it execute again
        if (String.isNotBlank(instance.Current_Step__c)) {
            List<Workflow_Step_Execution__c> stepExecs = [
                SELECT Id, Status__c, Retry_Count__c, Error_Details__c 
                FROM Workflow_Step_Execution__c
                WHERE Workflow_Instance__c = :instanceId
                AND Step_Name__c = :instance.Current_Step__c
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT 1
            ];
            if (!stepExecs.isEmpty()) {
                Workflow_Step_Execution__c stepExec = stepExecs[0];
                stepExec.Status__c = 'Pending';
                stepExec.Retry_Count__c = 0; // reset retry counter
                stepExec.Error_Details__c = null;
                update stepExec;
            }
        }

        // Reset the instance status to Running and clear error messages
        instance.Status__c = 'Running';
        instance.Error_Message__c = null;
        update instance;

        // Enqueue the orchestrator to resume execution
        System.enqueueJob(new WorkflowOrchestrator(instanceId));
    }

    private static void cancelTimeoutJob(Id instanceId, String stepName) {
        String cleanStepName = stepName.replaceAll('[^a-zA-Z0-9]', '_');
        String jobName = 'Timeout_' + instanceId + '_' + cleanStepName;
        List<CronTrigger> triggers = [
            SELECT Id FROM CronTrigger 
            WHERE CronJobDetail.Name = :jobName
        ];
        for (CronTrigger triggerJob : triggers) {
            try {
                System.abortJob(triggerJob.Id);
            } catch (Exception e) {
                // ignore if already executed/aborted
            }
        }
    }
}
