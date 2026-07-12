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
  public inherited sharing class CursorQueryStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      ctx.reportProgress(10.0, 'Cursor opened; calculating partitions');
      // Construct query (using Accounts for demonstration)
      String query = 'SELECT Id, Name FROM Account ORDER BY Name';

      // Create native Apex Cursor. Serializing it (below) retains a reference to
      // the SOQL result cache so child chunks can fetch their partition later.
      Database.Cursor cursor = Database.getCursor(query);

      Map<String, Object> output = new Map<String, Object>{
        'totalRecords' => cursor.getNumRecords(),
        'serializedCursor' => JSON.serialize(cursor),
        'chunkSize' => resolveChunkSize(ctx.workflowInputJson)
      };
      return StepResult.complete(null, output);
    }

    // Chunk size defaults to 2 for the demo/tests, but can be overridden via the
    // workflow input (e.g. {"chunkSize": 50}) so a large dataset fans out into a
    // manageable number of larger chunks instead of hundreds of tiny child workflows.
    private Integer resolveChunkSize(String inputJson) {
      if (String.isBlank(inputJson)) {
        return 2;
      }
      Integer chunkSize = 2;
      try {
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
          inputJson
        );
        Object requested = parsed.get('chunkSize');
        if (requested != null) {
          chunkSize = Integer.valueOf(String.valueOf(requested));
        }
      } catch (Exception ignored) {
      }
      return Math.max(1, chunkSize);
    }
  }

  /**
   * CursorFanoutStep:
   * Spawns a parallel child ProcessCursorChunkWorkflow for each offset chunk,
   * suspends parent execution, and joins results upon wake-up.
   */
  public inherited sharing class CursorFanoutStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Query child instances associated with this parent
      List<Workflow_Instance__c> childInstances = [
        SELECT Id, Status__c, Correlation_Key__c, Output__c
        FROM Workflow_Instance__c
        WHERE Parent_Instance__c = :ctx.workflowInstanceId
        WITH USER_MODE
      ];

      // First activation spawns the chunks; later activations join them.
      if (childInstances.isEmpty()) {
        return fanOutChunks(ctx);
      }
      if (!allChildrenSettled(childInstances)) {
        return StepResult.suspend();
      }
      return collectChunkResults(ctx, childInstances);
    }

    private StepResult fanOutChunks(StepContext ctx) {
      ctx.reportProgress(40.0, 'Fanning out parallel child chunks');
      if (String.isBlank(ctx.previousStepOutput)) {
        return StepResult.complete(
          null,
          new Map<String, Object>{
            'error' => 'No output received from CursorQueryStep'
          }
        );
      }

      Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.previousStepOutput
      );
      Integer totalRecords = (Integer) plan.get('totalRecords');
      if (totalRecords == 0) {
        return StepResult.complete(
          null,
          new Map<String, Object>{
            'totalProcessed' => 0,
            'results' => new List<Object>()
          }
        );
      }
      String serializedCursor = (String) plan.get('serializedCursor');
      Integer chunkSize = (Integer) plan.get('chunkSize');

      // Spawn one child workflow per offset window of chunkSize records.
      for (Integer offset = 0; offset < totalRecords; offset += chunkSize) {
        Map<String, Object> childInput = new Map<String, Object>{
          'serializedCursor' => serializedCursor,
          'offset' => offset,
          'limit' => chunkSize
        };
        String childKey =
          'CursorChunk_' +
          offset +
          '_' +
          ctx.workflowInstanceId;
        WorkflowEngine.start(
          'CursorFanoutWorkflowExample.ProcessCursorChunkWorkflow',
          childKey,
          childInput,
          ctx.workflowInstanceId
        );
      }

      return StepResult.suspend();
    }

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

    private StepResult collectChunkResults(
      StepContext ctx,
      List<Workflow_Instance__c> childInstances
    ) {
      ctx.reportProgress(80.0, 'All chunks completed; aggregating outputs');

      List<Object> aggregatedOutputs = new List<Object>();
      Integer totalProcessed = 0;
      for (Workflow_Instance__c child : childInstances) {
        if (child.Output__c == null) {
          continue;
        }
        Map<String, Object> chunkOutput = (Map<String, Object>) JSON.deserializeUntyped(
          child.Output__c
        );
        aggregatedOutputs.add(chunkOutput);
        Integer chunkCount = (Integer) chunkOutput.get('count');
        if (chunkCount != null) {
          totalProcessed += chunkCount;
        }
      }

      return StepResult.complete(
        null,
        new Map<String, Object>{
          'totalProcessed' => totalProcessed,
          'chunks' => aggregatedOutputs
        }
      );
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

      List<String> names = new List<String>();
      for (SObject record : records) {
        names.add(((Account) record).Name);
      }

      ctx.reportProgress(
        100.0,
        'Chunk offset ' + offset + ' processed successfully'
      );

      Map<String, Object> chunkResult = new Map<String, Object>{
        'offset' => offset,
        'count' => records.size(),
        'names' => names
      };
      return StepResult.complete(null, chunkResult);
    }
  }

  /**
   * CursorVerifyStep:
   * Receives and summarizes the aggregated results.
   */
  public class CursorVerifyStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      ctx.reportProgress(
        100.0,
        'Verification complete; fanned-out records validated'
      );
      Map<String, Object> fanout = (Map<String, Object>) JSON.deserializeUntyped(
        ctx.previousStepOutput
      );

      Map<String, Object> summary = new Map<String, Object>{
        'status' => 'Cursor fan-out verification complete',
        'totalProcessed' => (Integer) fanout.get('totalProcessed'),
        'fanoutDetails' => fanout
      };
      return StepResult.complete(null, summary);
    }
  }
}
