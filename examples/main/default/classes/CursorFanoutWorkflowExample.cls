public inherited sharing class CursorFanoutWorkflowExample {
  // ==========================================
  // Parent Workflow Definition
  // ==========================================
  public class CursorFanoutWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'CursorFanoutWorkflowExample.CursorQueryStep',
        'CursorFanoutWorkflowExample.CursorFanoutStep',
        'CursorFanoutWorkflowExample.CursorVerifyStep'
      };
    }

    public String getInitialStep() {
      return 'CursorFanoutWorkflowExample.CursorQueryStep';
    }

    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'CursorFanoutWorkflowExample.CursorQueryStep') {
        return 'CursorFanoutWorkflowExample.CursorFanoutStep';
      }
      if (currentStepName == 'CursorFanoutWorkflowExample.CursorFanoutStep') {
        return 'CursorFanoutWorkflowExample.CursorVerifyStep';
      }
      return null; // Complete
    }
  }

  // ==========================================
  // Child Workflow Definition
  // ==========================================
  public class ProcessCursorChunkWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'CursorFanoutWorkflowExample.ProcessCursorChunkStep'
      };
    }

    public String getInitialStep() {
      return 'CursorFanoutWorkflowExample.ProcessCursorChunkStep';
    }

    public String getNextStep(String currentStepName, StepResult result) {
      return null; // Complete
    }
  }

  // ==========================================
  // Step Implementations
  // ==========================================

  /**
   * CursorQueryStep:
   * Initializes a Database.Cursor, queries the total records,
   * and serializes the cursor pointer so it can be distributed.
   */
  public class CursorQueryStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Construct query (using Accounts for demonstration)
      String query = 'SELECT Id, Name FROM Account ORDER BY Name';

      // Create native Apex Cursor
      Database.Cursor cursor = Database.getCursor(query);
      Integer totalRecords = cursor.getNumRecords();

      // Serialize the cursor pointer (retains reference to SOQL cache)
      String serializedCursor = JSON.serialize(cursor);

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
          // Malformed input — keep the default chunk size.
        }
      }
      if (chunkSize < 1) {
        chunkSize = 1;
      }

      Map<String, Object> output = new Map<String, Object>{
        'totalRecords' => totalRecords,
        'serializedCursor' => serializedCursor,
        'chunkSize' => chunkSize
      };
      return StepResult.complete(null, output);
    }
  }

  /**
   * CursorFanoutStep:
   * Spawns a parallel child ProcessCursorChunkWorkflow for each offset chunk,
   * suspends parent execution, and joins results upon wake-up.
   */
  public class CursorFanoutStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Query child instances associated with this parent
      List<Workflow_Instance__c> childInstances = [
        SELECT Id, Status__c, Correlation_Key__c, Output__c
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :ctx.workflowInstanceId
      ];

      // First run: spawn chunks
      if (childInstances.isEmpty()) {
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

        // Spawn child workflows in increments of chunkSize
        for (Integer offset = 0; offset < totalRecords; offset += chunkSize) {
          // Create child workflow input
          Map<String, Object> childInput = new Map<String, Object>{
            'serializedCursor' => serializedCursor,
            'offset' => offset,
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
            'CursorFanoutWorkflowExample.ProcessCursorChunkWorkflow',
            childKey,
            childInput,
            ctx.workflowInstanceId
          );
        }

        return StepResult.suspend();
      }

      // Check if all children have finished
      Boolean allCompleted = true;
      for (Workflow_Instance__c child : childInstances) {
        if (child.Status__c != 'Completed' && child.Status__c != 'Failed') {
          allCompleted = false;
          break;
        }
      }

      if (!allCompleted) {
        return StepResult.suspend();
      }

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
   * ProcessCursorChunkStep (Child Step):
   * Deserializes the Database.Cursor and fetches records for the allocated chunk.
   */
  public class ProcessCursorChunkStep implements WorkflowStep {
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
      Integer offset = (Integer) input.get('offset');
      Integer limitSize = (Integer) input.get('limit');

      // Deserialize the cursor to restore connection to SOQL result set
      Database.Cursor cursor = (Database.Cursor) JSON.deserialize(
        serializedCursor,
        Database.Cursor.class
      );

      // Guard against fetching beyond bounds (since fetch throws an exception if we exceed numRecords)
      Integer numRecords = cursor.getNumRecords();
      Integer fetchCount = limitSize;
      if (offset + fetchCount > numRecords) {
        fetchCount = numRecords - offset;
      }

      // Fetch records for our offset partition
      List<SObject> records = cursor.fetch(offset, fetchCount);

      List<String> accountNames = new List<String>();
      for (SObject sobj : records) {
        Account acc = (Account) sobj;
        accountNames.add(acc.Name);
      }

      Map<String, Object> result = new Map<String, Object>{
        'offset' => offset,
        'count' => records.size(),
        'names' => accountNames
      };
      return StepResult.complete(null, result);
    }
  }

  /**
   * CursorVerifyStep:
   * Receives and summarizes the aggregated results.
   */
  public class CursorVerifyStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
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
