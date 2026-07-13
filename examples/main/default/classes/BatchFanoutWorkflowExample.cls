/**
 * @description Example that fans a batch of records out to one child workflow per record
 * and joins their results, demonstrating parent/child orchestration with yield-based
 * chunked spawning and completion aggregation.
 */
public inherited sharing class BatchFanoutWorkflowExample {
  // ==========================================
  // Parent Workflow Definition
  // ==========================================
  /**
   * @description Parent workflow that fetches records, fans them out to children, and
   * verifies the aggregated batch result.
   */
  public class BatchFanoutWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered step names of the parent workflow.
     * @return The list of fetch, fanout, and verify step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'BatchFanoutWorkflowExample.FetchRecordsStep',
        'BatchFanoutWorkflowExample.FanoutStep',
        'BatchFanoutWorkflowExample.VerifyBatchStep'
      };
    }

    /**
     * @description Returns the name of the first step to execute.
     * @return The name of the fetch records step.
     */
    public String getInitialStep() {
      return 'BatchFanoutWorkflowExample.FetchRecordsStep';
    }

    /**
     * @description Advances fetch to fanout, and fanout to verify; verify ends the workflow.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return The next step name, or null when the workflow is complete.
     */
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
  /**
   * @description Child workflow that processes a single record fanned out by the parent.
   */
  public class ProcessRecordWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the ordered step names of the child workflow.
     * @return A single-element list naming the process-account step.
     */
    public List<String> getSteps() {
      return new List<String>{
        'BatchFanoutWorkflowExample.ProcessAccountStep'
      };
    }

    /**
     * @description Returns the name of the first step to execute.
     * @return The name of the process-account step.
     */
    public String getInitialStep() {
      return 'BatchFanoutWorkflowExample.ProcessAccountStep';
    }

    /**
     * @description Computes the next step after the given step completes.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, since this is a single-step workflow.
     */
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
  public inherited sharing class FetchRecordsStep implements WorkflowStep {
    /**
     * @description Queries up to 100 Accounts (falling back to mock data when none exist)
     * and completes with the record list for the fanout step to process.
     * @param ctx The durable step context.
     * @return A complete result carrying the list of records.
     */
    public StepResult execute(StepContext ctx) {
      List<Account> accounts = [
        SELECT Id, Name
        FROM Account
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC
        LIMIT 100
      ];
      List<Map<String, Object>> records = new List<Map<String, Object>>();
      for (Account acc : accounts) {
        records.add(
          new Map<String, Object>{ 'id' => (String) acc.Id, 'name' => acc.Name }
        );
      }
      // Fallback to mock data if none exist (for backward compatibility / safety)
      if (records.isEmpty()) {
        records.add(
          new Map<String, Object>{ 'id' => '001_mock_1', 'name' => 'Acme Corp' }
        );
        records.add(
          new Map<String, Object>{
            'id' => '001_mock_2',
            'name' => 'Stark Industries'
          }
        );
        records.add(
          new Map<String, Object>{
            'id' => '001_mock_3',
            'name' => 'Wayne Enterprises'
          }
        );
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
  public inherited sharing class FanoutStep implements WorkflowStep {
    /**
     * @description Spawns one child workflow per record in yield-bounded chunks, suspends
     * until all children reach a terminal state, then aggregates their outputs.
     * @param ctx The durable step context supplying previous output, step state, and instance id.
     * @return A yield result while spawning, a suspend result while awaiting children, or a
     * complete result carrying the aggregated child outputs.
     */
    public StepResult execute(StepContext ctx) {
      // 1. Parse accounts from previous step output
      if (String.isBlank(ctx.previousStepOutput)) {
        return StepResult.complete(
          null,
          new Map<String, Object>{
            'error' => 'No record list returned from FetchRecordsStep'
          }
        );
      }
      List<Object> accountsList = (List<Object>) JSON.deserializeUntyped(
        ctx.previousStepOutput
      );

      // 2. Resolve offset from stepStateJson
      Integer offset = resolveOffset(ctx);

      // 3. Spawn child workflows in chunks if they have not been spawned yet
      List<Workflow_Instance__c> childInstances = queryChildInstances(
        ctx.workflowInstanceId
      );

      Boolean needsSpawning =
        (offset < accountsList.size()) &&
        (offset > 0 || childInstances.isEmpty());
      if (needsSpawning) {
        StepResult spawnOutcome = spawnChildren(
          ctx,
          accountsList,
          childInstances
        );
        if (spawnOutcome != null) {
          // Yielded mid-spawn: resume spawning in the next transaction.
          return spawnOutcome;
        }
        // Query child instances again after spawning to get the latest list for checking completion
        childInstances = queryChildInstances(ctx.workflowInstanceId);
      }

      if (!allChildrenSettled(childInstances)) {
        // Not all child workflows have completed yet, suspend parent
        return StepResult.suspend();
      }

      // 4. Once all are completed, aggregate their outputs
      return StepResult.complete(null, aggregateChildOutputs(childInstances));
    }

    // Reads the durable spawn offset from step state, defaulting to 0.
    private Integer resolveOffset(StepContext ctx) {
      Integer offset = 0;
      if (String.isBlank(ctx.stepStateJson)) {
        return offset;
      }
      try {
        Map<String, Object> stateMap = (Map<String, Object>) JSON.deserializeUntyped(
          ctx.stepStateJson
        );
        if (stateMap.containsKey('offset')) {
          offset = ((Decimal) stateMap.get('offset')).intValue();
        }
      } catch (Exception ignored) {
        // Leave offset at 0 on malformed state.
      }
      return offset;
    }

    // Loads the current child instances for this parent.
    private List<Workflow_Instance__c> queryChildInstances(
      Id parentInstanceId
    ) {
      return [
        SELECT Id, Status__c, Correlation_Key__c, Output__c
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :parentInstanceId
        WITH SYSTEM_MODE
      ];
    }

    // Spawns child workflows from the given offset. Returns a YIELD StepResult if
    // the transaction ran low on resources mid-spawn, or null once spawning finishes.
    private StepResult spawnChildren(
      StepContext ctx,
      List<Object> accountsList,
      List<Workflow_Instance__c> childInstances
    ) {
      // Resume point within accountsList, read back from durable step state.
      Integer offset = resolveOffset(ctx);

      // Build a set of already-spawned keys so the loop is idempotent on retry.
      // A yield-then-suspend sequence leaves a stale offset in stepExec.Output__c
      // that survives retryWorkflow, causing needsSpawning=true even when children
      // at those offsets already exist. Skipping existing keys prevents collisions.
      Set<String> spawnedChildKeys = collectSpawnedKeys(childInstances);

      for (Integer i = offset; i < accountsList.size(); i++) {
        if (ctx.shouldYield()) {
          // Return YIELD to resume spawning in the next transaction
          Map<String, Object> nextState = new Map<String, Object>{
            'offset' => i
          };
          return StepResult.yield(JSON.serialize(nextState));
        }

        Object accObj = accountsList[i];
        Map<String, Object> acc = (Map<String, Object>) accObj;
        String accId = (String) acc.get('id');

        // Generate unique child correlation key
        String childKey = 'Process_' + accId + '_' + ctx.workflowInstanceId;

        if (!spawnedChildKeys.contains(childKey)) {
          WorkflowEngine.start(
            new WorkflowEngine.StartRequest(
                'BatchFanoutWorkflowExample.ProcessRecordWorkflow',
                childKey,
                acc
              )
              .withParent(ctx.workflowInstanceId)
          );
        }
      }
      return null;
    }

    // Collects the correlation keys of children that already exist.
    private Set<String> collectSpawnedKeys(
      List<Workflow_Instance__c> childInstances
    ) {
      Set<String> spawnedChildKeys = new Set<String>();
      for (Workflow_Instance__c child : childInstances) {
        if (String.isNotBlank(child.Correlation_Key__c)) {
          spawnedChildKeys.add(child.Correlation_Key__c);
        }
      }
      return spawnedChildKeys;
    }

    // True when every child has reached a terminal (Completed/Failed) status.
    private Boolean allChildrenSettled(
      List<Workflow_Instance__c> childInstances
    ) {
      for (Workflow_Instance__c child : childInstances) {
        if (child.Status__c != 'Completed' && child.Status__c != 'Failed') {
          return false;
        }
      }
      return true;
    }

    // Aggregates each child's deserialized output keyed by correlation key.
    private Map<String, Object> aggregateChildOutputs(
      List<Workflow_Instance__c> childInstances
    ) {
      Map<String, Object> aggregatedResults = new Map<String, Object>();
      for (Workflow_Instance__c child : childInstances) {
        Object childOut = child.Output__c != null
          ? JSON.deserializeUntyped(child.Output__c)
          : null;
        aggregatedResults.put(child.Correlation_Key__c, childOut);
      }
      return aggregatedResults;
    }
  }

  /**
   * ProcessAccountStep (Child Step):
   * Simulates performing audit logic on the account and returning results.
   */
  public inherited sharing class ProcessAccountStep implements WorkflowStep {
    /**
     * @description Audits the input account, updating a real Account record when the id is a
     * genuine 15/18-char Id, and completes with the audit result.
     * @param ctx The durable step context supplying the child workflow input.
     * @return A complete result carrying the audit outcome.
     */
    public StepResult execute(StepContext ctx) {
      if (String.isBlank(ctx.workflowInputJson)) {
        return StepResult.complete(
          null,
          new Map<String, Object>{
            'status' => 'Skipped',
            'reason' => 'No input'
          }
        );
      }
      Map<String, Object> acc = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.workflowInputJson
      );
      String accId = (String) acc.get('id');
      String accName = (String) acc.get('name');

      String status = 'Audited';
      String note = 'Audited by Revenant Workflow at ' + DateTime.now();

      if (accId.startsWith('001') && accId.length() >= 15) {
        // Real Account - Perform DML transaction
        Account a = new Account(Id = (Id) accId, Description = note);
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
    /**
     * @description Reads the aggregated child outputs and completes with a final batch
     * summary of totals and details.
     * @param ctx The durable step context supplying the aggregated previous output.
     * @return A complete result carrying the final batch summary.
     */
    public StepResult execute(StepContext ctx) {
      Map<String, Object> aggregated = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.previousStepOutput
      );

      Map<String, Object> finalResult = new Map<String, Object>{
        'totalProcessed' => aggregated.size(),
        'status' => 'Batch completed successfully',
        'details' => aggregated
      };
      return StepResult.complete(null, finalResult);
    }
  }
}
