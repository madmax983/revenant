public inherited sharing class BatchFanoutWorkflowExample {

    // ==========================================
    // Parent Workflow Definition
    // ==========================================
    public class BatchFanoutWorkflow implements WorkflowDefinition {
        public List<String> getSteps() {
            return new List<String>{
                'BatchFanoutWorkflowExample.FetchRecordsStep',
                'BatchFanoutWorkflowExample.FanoutStep',
                'BatchFanoutWorkflowExample.VerifyBatchStep'
            };
        }

        public String getInitialStep() {
            return 'BatchFanoutWorkflowExample.FetchRecordsStep';
        }

        public String getNextStep(String currentStepName, StepResult result) {
            if (currentStepName == 'BatchFanoutWorkflowExample.FetchRecordsStep') {
                return 'BatchFanoutWorkflowExample.FanoutStep';
            }
            if (currentStepName == 'BatchFanoutWorkflowExample.FanoutStep') {
                return 'BatchFanoutWorkflowExample.VerifyBatchStep';
            }
            return null; // Complete
        }
    }

    // ==========================================
    // Child Workflow Definition
    // ==========================================
    public class ProcessRecordWorkflow implements WorkflowDefinition {
        public List<String> getSteps() {
            return new List<String>{
                'BatchFanoutWorkflowExample.ProcessAccountStep'
            };
        }

        public String getInitialStep() {
            return 'BatchFanoutWorkflowExample.ProcessAccountStep';
        }

        public String getNextStep(String currentStepName, StepResult result) {
            return null; // Complete
        }
    }

    // ==========================================
    // Step Implementations
    // ==========================================

    /**
     * FetchRecordsStep:
     * Simply returns a mock list of record data (e.g. Account names/IDs) 
     * to simulate querying records from the database.
     */
    public class FetchRecordsStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            List<Account> accounts = [SELECT Id, Name FROM Account WITH SYSTEM_MODE ORDER BY CreatedDate DESC LIMIT 100];
            List<Map<String, Object>> records = new List<Map<String, Object>>();
            for (Account acc : accounts) {
                records.add(new Map<String, Object>{'id' => (String)acc.Id, 'name' => acc.Name});
            }
            // Fallback to mock data if none exist (for backward compatibility / safety)
            if (records.isEmpty()) {
                records.add(new Map<String, Object>{'id' => '001_mock_1', 'name' => 'Acme Corp'});
                records.add(new Map<String, Object>{'id' => '001_mock_2', 'name' => 'Stark Industries'});
                records.add(new Map<String, Object>{'id' => '001_mock_3', 'name' => 'Wayne Enterprises'});
            }
            return StepResult.complete(null, records);
        }
    }

    /**
     * FanoutStep:
     * 1. Launches a child ProcessRecordWorkflow for each fetched record.
     * 2. Yields/suspends waiting for completion signals.
     * 3. Aggregates results once all child completed signals are received.
     */
    public class FanoutStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            // 1. Parse accounts from previous step output
            if (String.isBlank(ctx.previousStepOutput)) {
                return StepResult.complete(null, new Map<String, Object>{'error' => 'No record list returned from FetchRecordsStep'});
            }
            List<Object> accountsList = (List<Object>)JSON.deserializeUntyped(ctx.previousStepOutput);

            // 2. Resolve offset from stepStateJson
            Integer offset = 0;
            if (String.isNotBlank(ctx.stepStateJson)) {
                try {
                    Map<String, Object> stateMap = (Map<String, Object>)JSON.deserializeUntyped(ctx.stepStateJson);
                    if (stateMap.containsKey('offset')) {
                        offset = ((Decimal)stateMap.get('offset')).intValue();
                    }
                } catch (Exception ex) {
                    // fallback
                }
            }

            // 3. Spawn child workflows in chunks if they have not been spawned yet
            List<Workflow_Instance__c> childInstances = [
                SELECT Id, Status__c, Correlation_Key__c, Output__c
                FROM Workflow_Instance__c
                WHERE Parent_Instance__c = :ctx.workflowInstanceId
                WITH SYSTEM_MODE
            ];

            Boolean needsSpawning = (offset < accountsList.size()) && (offset > 0 || childInstances.isEmpty());
            if (needsSpawning) {
                Boolean yielded = false;
                for (Integer i = offset; i < accountsList.size(); i++) {
                    if (ctx.shouldYield()) {
                        offset = i;
                        yielded = true;
                        break;
                    }
                    
                    Object accObj = accountsList[i];
                    Map<String, Object> acc = (Map<String, Object>)accObj;
                    String accId = (String)acc.get('id');
                    
                    // Generate unique child correlation key
                    String childKey = 'Process_' + accId + '_' + ctx.workflowInstanceId;
                    
                    // Start child workflow dynamically
                    WorkflowEngine.start(
                        'BatchFanoutWorkflowExample.ProcessRecordWorkflow', 
                        childKey, 
                        acc, 
                        ctx.workflowInstanceId
                    );
                }

                if (yielded) {
                    // Return YIELD to resume spawning in the next transaction
                    Map<String, Object> nextState = new Map<String, Object>{ 'offset' => offset };
                    return StepResult.yield(JSON.serialize(nextState));
                }

                // Query child instances again after spawning to get the latest list for checking completion
                childInstances = [
                    SELECT Id, Status__c, Correlation_Key__c, Output__c
                    FROM Workflow_Instance__c
                    WHERE Parent_Instance__c = :ctx.workflowInstanceId
                    WITH SYSTEM_MODE
                ];
            }

            Boolean allCompleted = true;
            for (Workflow_Instance__c child : childInstances) {
                if (child.Status__c != 'Completed' && child.Status__c != 'Failed') {
                    allCompleted = false;
                    break;
                }
            }

            if (!allCompleted) {
                // Not all child workflows have completed yet, suspend parent
                return StepResult.suspend();
            }

            // 5. Once all are completed, aggregate their outputs
            Map<String, Object> aggregatedResults = new Map<String, Object>();
            for (Workflow_Instance__c child : childInstances) {
                Object childOut = child.Output__c != null ? JSON.deserializeUntyped(child.Output__c) : null;
                aggregatedResults.put(child.Correlation_Key__c, childOut);
            }

            return StepResult.complete(null, aggregatedResults);
        }
    }

    /**
     * ProcessAccountStep (Child Step):
     * Simulates performing audit logic on the account and returning results.
     */
    public class ProcessAccountStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            if (String.isBlank(ctx.workflowInputJson)) {
                return StepResult.complete(null, new Map<String, Object>{'status' => 'Skipped', 'reason' => 'No input'});
            }
            Map<String, Object> acc = (Map<String, Object>)JSON.deserializeUntyped(ctx.workflowInputJson);
            String accId = (String)acc.get('id');
            String accName = (String)acc.get('name');
            
            String status = 'Audited';
            String note = 'Audited by Revenant Workflow at ' + DateTime.now();
            
            if (accId.startsWith('001') && accId.length() >= 15) {
                // Real Account - Perform DML transaction
                Account a = new Account(Id = (Id)accId, Description = note);
                update as system a;
                status = 'Audited & Updated';
            }
            
            Map<String, Object> auditResult = new Map<String, Object>{
                'status' => status,
                'timestamp' => DateTime.now().getTime(),
                'score' => 95,
                'accountId' => accId,
                'accountName' => accName
            };
            return StepResult.complete(null, auditResult);
        }
    }

    /**
     * VerifyBatchStep:
     * Receives the aggregated output map and prints out the final status.
     */
    public class VerifyBatchStep implements WorkflowStep {
        public StepResult execute(StepContext ctx) {
            Map<String, Object> aggregated = (Map<String, Object>)JSON.deserializeUntyped(ctx.previousStepOutput);
            
            Map<String, Object> finalResult = new Map<String, Object>{
                'totalProcessed' => aggregated.size(),
                'status' => 'Batch completed successfully',
                'details' => aggregated
            };
            return StepResult.complete(null, finalResult);
        }
    }
}
