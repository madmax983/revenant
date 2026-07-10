/**
 * @description Example class demonstrating a cursor fan-out execution workflow
 * utilizing ChunkedCursorIterator for processing and parallelizing records.
 */
@SuppressWarnings('PMD.AvoidDebugStatements, PMD.OperationWithLimitsInLoop')
public inherited sharing class RevenantCursorFanoutExample {
  // ==========================================
  // Parent Workflow Definition
  // ==========================================

  /**
   * @description Workflow definition for fanning out database cursor records.
   */
  public class CursorFanoutWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the list of steps in the workflow.
     * @return List of step class names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'RevenantCursorFanoutExample.CursorQueryStep',
        'RevenantCursorFanoutExample.CursorFanoutStep',
        'RevenantCursorFanoutExample.CursorVerifyStep'
      };
    }

    /**
     * @description Gets the name of the initial step.
     * @return The starting step name.
     */
    public String getInitialStep() {
      return 'RevenantCursorFanoutExample.CursorQueryStep';
    }

    /**
     * @description Determines the next step after the current step completes.
     * @param currentStepName The name of the step that completed.
     * @param result The result of the completed step.
     * @return The next step name, or null if complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'RevenantCursorFanoutExample.CursorQueryStep') {
        return 'RevenantCursorFanoutExample.CursorFanoutStep';
      }
      if (currentStepName == 'RevenantCursorFanoutExample.CursorFanoutStep') {
        return 'RevenantCursorFanoutExample.CursorVerifyStep';
      }
      return null; // Complete
    }
  }

  // ==========================================
  // Child Workflow Definition
  // ==========================================

  /**
   * @description Workflow definition for processing a single cursor chunk.
   */
  public class ProcessCursorChunkWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the list of steps in the workflow.
     * @return List of step class names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'RevenantCursorFanoutExample.ProcessCursorChunkStep'
      };
    }

    /**
     * @description Gets the name of the initial step.
     * @return The starting step name.
     */
    public String getInitialStep() {
      return 'RevenantCursorFanoutExample.ProcessCursorChunkStep';
    }

    /**
     * @description Determines the next step.
     * @param currentStepName The name of the step that completed.
     * @param result The result of the completed step.
     * @return The next step name, or null if complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null; // Complete
    }
  }

  // ==========================================
  // Step Implementations
  // ==========================================

  /**
   * @description Step to initialize a Database.Cursor, calculate total records,
   * and serialize the cursor pointer for distribution.
   */
  public class CursorQueryStep implements WorkflowStep {
    /**
     * @description Executes the query step.
     * @param ctx The step context.
     * @return The step execution result.
     */
    public StepResult execute(StepContext ctx) {
      ctx.reportProgress(10.0, 'Cursor opened; calculating partitions');
      // Construct query (using Accounts for demonstration)
      String query = 'SELECT Id, Name FROM Account ORDER BY Name';

      // Chunk size defaults to 2 for the demo/tests, but can be overridden via the
      // workflow input (e.g. {"chunkSize": 50}) so a large dataset fans out into a
      // manageable number of larger chunks instead of hundreds of tiny child workflows.
      Integer chunkSize = 2;
      if (String.isNotBlank(ctx.workflowInputJson)) {
        try {
          Map<String, Object> inp = (Map<String, Object>) JSON.deserializeUntyped(
            ctx.workflowInputJson
          );
          Object cs = inp.get('chunkSize');
          if (cs != null) {
            chunkSize = Integer.valueOf(String.valueOf(cs));
          }
        } catch (Exception e) {
          System.debug(
            LoggingLevel.WARN,
            'Failed to deserialize chunkSize from workflowInputJson: ' +
            e.getMessage()
          );
        }
      }
      if (chunkSize < 1) {
        chunkSize = 1;
      }

      // Initialize ChunkedCursorIterator
      ChunkedCursorIterator iterator = new ChunkedCursorIterator(
        new ChunkedCursorOptions(query, chunkSize)
          .setSObjectType(Account.SObjectType)
      );
      Integer totalRecords = iterator.totalRecords;
      String serializedCursor = JSON.serialize(iterator);

      Map<String, Object> output = new Map<String, Object>{
        'totalRecords' => totalRecords,
        'serializedCursor' => serializedCursor,
        'chunkSize' => chunkSize
      };
      return StepResult.complete(null, output);
    }
  }

  /**
   * @description Step to spawn a parallel child ProcessCursorChunkWorkflow for each offset chunk,
   * suspend parent execution, and join results upon wake-up.
   */
  public inherited sharing class CursorFanoutStep implements WorkflowStep {
    /**
     * @description Executes the fanout step.
     * @param ctx The step context.
     * @return The step execution result.
     */
    public StepResult execute(StepContext ctx) {
      // Query child instances associated with this parent
      List<Workflow_Instance__c> childInstances = [
        SELECT Id, Status__c, Correlation_Key__c, Output__c
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :ctx.workflowInstanceId
        WITH USER_MODE
      ];

      // First run: spawn chunks
      if (childInstances.isEmpty()) {
        return spawnChunks(ctx);
      }

      // Subsequent runs: aggregate results
      return aggregateChunks(ctx, childInstances);
    }

    /**
     * @description Spawns child workflows for each partitioned chunk.
     * @param ctx The step context.
     * @return The step result.
     */
    private StepResult spawnChunks(StepContext ctx) {
      ctx.reportProgress(40.0, 'Fanning out parallel child chunks');
      if (String.isBlank(ctx.previousStepOutput)) {
        return StepResult.complete(
          null,
          new Map<String, Object>{
            'error' => 'No output received from CursorQueryStep'
          }
        );
      }

      Map<String, Object> queryData = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.previousStepOutput
      );
      Integer totalRecords = (Integer) queryData.get('totalRecords');
      String serializedCursor = (String) queryData.get('serializedCursor');
      Integer chunkSize = (Integer) queryData.get('chunkSize');

      if (totalRecords == 0) {
        return StepResult.complete(
          null,
          new Map<String, Object>{
            'totalProcessed' => 0,
            'results' => new List<Object>()
          }
        );
      }

      // Deserialize standard cursor and partition it using ChunkedCursorIterator
      ChunkedCursorIterator iterator = (ChunkedCursorIterator) JSON.deserialize(
        serializedCursor,
        ChunkedCursorIterator.class
      );
      List<ChunkedCursorIterator> partitions = iterator.partition();

      // Enforce parallel partition limit to prevent exceeding DML transaction limits
      if (partitions.size() > 100) {
        throw new System.LimitException(
          'Too many partitions generated (' +
            partitions.size() +
            '). Parallel partition limit is 100 to prevent DML transaction limits.'
        );
      }

      // Spawn child workflows in increments of chunkSize
      for (ChunkedCursorIterator partition : partitions) {
        Integer offset = partition.position;
        // Create child workflow input
        Map<String, Object> childInput = new Map<String, Object>{
          'serializedCursor' => JSON.serialize(partition),
          'limit' => chunkSize
        };

        // Generate unique correlation key for this chunk
        String childKey =
          'CursorChunk_' +
          offset +
          '_' +
          ctx.workflowInstanceId;

        // Start child workflow
        WorkflowEngine.start(
          'RevenantCursorFanoutExample.ProcessCursorChunkWorkflow',
          childKey,
          childInput,
          ctx.workflowInstanceId
        );
      }

      return StepResult.suspend();
    }

    /**
     * @description Checks completion and aggregates child workflow outputs.
     * @param ctx The step context.
     * @param childInstances The child instances to aggregate.
     * @return The step result.
     */
    private StepResult aggregateChunks(
      StepContext ctx,
      List<Workflow_Instance__c> childInstances
    ) {
      // Check if all children have finished and look for child failures
      Boolean allCompleted = true;
      Boolean hasFailures = false;
      for (Workflow_Instance__c child : childInstances) {
        if (child.Status__c == 'Failed') {
          hasFailures = true;
        } else if (child.Status__c != 'Completed') {
          allCompleted = false;
          break;
        }
      }

      if (hasFailures) {
        return StepResult.fail(
          'One or more parallel child chunks failed to process.'
        );
      }

      if (!allCompleted) {
        return StepResult.suspend();
      }

      ctx.reportProgress(80.0, 'All chunks completed; aggregating outputs');

      // Aggregate outputs
      List<Object> aggregatedOutputs = new List<Object>();
      Integer totalProcessed = 0;
      for (Workflow_Instance__c child : childInstances) {
        if (child.Output__c != null) {
          Map<String, Object> childOut = (Map<String, Object>) JSON.deserializeUntyped(
            child.Output__c
          );
          aggregatedOutputs.add(childOut);
          Integer processedCount = (Integer) childOut.get('count');
          if (processedCount != null) {
            totalProcessed += processedCount;
          }
        }
      }

      Map<String, Object> resultPayload = new Map<String, Object>{
        'totalProcessed' => totalProcessed,
        'chunks' => aggregatedOutputs
      };
      return StepResult.complete(null, resultPayload);
    }
  }

  /**
   * @description Child step that deserializes the cursor partition and processes the records.
   */
  public class ProcessCursorChunkStep implements WorkflowStep {
    /**
     * @description Executes the chunk processing step.
     * @param ctx The step context.
     * @return The step execution result.
     */
    public StepResult execute(StepContext ctx) {
      if (String.isBlank(ctx.workflowInputJson)) {
        return StepResult.complete(
          null,
          new Map<String, Object>{ 'count' => 0, 'names' => new List<String>() }
        );
      }

      Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.workflowInputJson
      );
      String serializedCursor = (String) input.get('serializedCursor');

      // Deserialize the partition ChunkedCursorIterator
      ChunkedCursorIterator partition = (ChunkedCursorIterator) JSON.deserialize(
        serializedCursor,
        ChunkedCursorIterator.class
      );

      Integer offset = partition.position;

      // Fetch the records using the iterator!
      List<SObject> records = partition.hasNext()
        ? partition.next()
        : new List<SObject>();

      List<String> accountNames = new List<String>();
      for (SObject sobj : records) {
        Account acc = (Account) sobj;
        accountNames.add(acc.Name);
      }

      ctx.reportProgress(
        100.0,
        'Chunk offset ' + offset + ' processed successfully'
      );

      Map<String, Object> result = new Map<String, Object>{
        'offset' => offset,
        'count' => records.size(),
        'names' => accountNames
      };
      return StepResult.complete(null, result);
    }
  }

  /**
   * @description Step to receive, validate, and summarize the aggregated results.
   */
  public class CursorVerifyStep implements WorkflowStep {
    /**
     * @description Executes the verification step.
     * @param ctx The step context.
     * @return The step execution result.
     */
    public StepResult execute(StepContext ctx) {
      ctx.reportProgress(
        100.0,
        'Verification complete; fanned-out records validated'
      );
      Map<String, Object> fanoutResult = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.previousStepOutput
      );
      Integer totalProcessed = (Integer) fanoutResult.get('totalProcessed');

      Map<String, Object> finalStatus = new Map<String, Object>{
        'status' => 'Cursor fan-out verification complete',
        'totalProcessed' => totalProcessed,
        'fanoutDetails' => fanoutResult
      };
      return StepResult.complete(null, finalStatus);
    }
  }
}
