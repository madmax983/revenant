public inherited sharing class CleanupWorkflow implements WorkflowDefinition {
  public String getInitialStep() {
    return 'CleanupWorkflow.PurgeOldInstancesStep';
  }

  public String getNextStep(String currentStepName, StepResult result) {
    return null; // Single step workflow
  }

  public class PurgeState {
    public Integer deletedCount;
  }

  public class PurgeOldInstancesStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Parse input parameters
      Integer retentionDays = 30;
      Integer batchSize = 200;
      if (String.isNotBlank(ctx.workflowInputJson)) {
        try {
          Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(
            ctx.workflowInputJson
          );
          if (input.containsKey('retentionDays')) {
            retentionDays = Integer.valueOf(input.get('retentionDays'));
          }
          if (input.containsKey('batchSize')) {
            batchSize = Integer.valueOf(input.get('batchSize'));
          }
        } catch (Exception ex) {
          // fallback to defaults
        }
      }

      DateTime threshold = DateTime.now().addDays(-retentionDays);

      // Query old terminal instances
      List<Workflow_Instance__c> oldInstances = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE
          Status__c IN (
            'Completed',
            'Failed',
            'Compensated',
            'Cancelled',
            'ContinuedAsNew'
          )
          AND CreatedDate < :threshold
        WITH SYSTEM_MODE
        LIMIT :batchSize
      ];

      PurgeState state = new PurgeState();
      if (String.isNotBlank(ctx.stepStateJson)) {
        state = (PurgeState) JSON.deserialize(
          ctx.stepStateJson,
          PurgeState.class
        );
      } else {
        state.deletedCount = 0;
      }

      if (oldInstances.isEmpty()) {
        return StepResult.complete(null, state);
      }

      // Clean up associated file attachments (ContentDocument records) to prevent storage leaks
      Set<Id> oldInstanceIds = new Set<Id>();
      for (Workflow_Instance__c inst : oldInstances) {
        oldInstanceIds.add(inst.Id);
      }
      List<ContentDocumentLink> links = [
        SELECT ContentDocumentId
        FROM ContentDocumentLink
        WHERE LinkedEntityId IN :oldInstanceIds
        WITH SYSTEM_MODE
      ];
      if (!links.isEmpty()) {
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink link : links) {
          docIds.add(link.ContentDocumentId);
        }
        // Delete ContentDocument records, which deletes file versions and links
        List<ContentDocument> docsToDelete = [
          SELECT Id
          FROM ContentDocument
          WHERE Id IN :docIds
          WITH SYSTEM_MODE
        ];
        delete as system docsToDelete;
      }

      // Perform delete (Master-Detail cascade deletes all steps and signals automatically)
      delete as system oldInstances;
      state.deletedCount += oldInstances.size();

      // Yield to process next batch with fresh limits
      return StepResult.yield(JSON.serialize(state));
    }
  }
}
