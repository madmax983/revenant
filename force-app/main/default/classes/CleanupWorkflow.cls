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
        Map<String, Object> input;
        try {
          input = (Map<String, Object>) JSON.deserializeUntyped(ctx.workflowInputJson);
        } catch (Exception ex) {
          throw new WorkflowEngine.WorkflowException('Malformed JSON in workflow input: ' + ex.getMessage());
        }

        if (input.containsKey('retentionDays')) {
          try {
            retentionDays = Integer.valueOf(input.get('retentionDays'));
          } catch (Exception ex) {
            throw new WorkflowEngine.WorkflowException('Invalid retentionDays parameter type: ' + ex.getMessage());
          }
        }

        if (input.containsKey('batchSize')) {
          try {
            batchSize = Integer.valueOf(input.get('batchSize'));
          } catch (Exception ex) {
            throw new WorkflowEngine.WorkflowException('Invalid batchSize parameter type: ' + ex.getMessage());
          }
          if (batchSize <= 0) {
            throw new WorkflowEngine.WorkflowException('batchSize parameter must be greater than zero');
          }
        }
      }

      // Clamp batchSize to a maximum of 50
      Integer clampedBatchSize = Math.min(batchSize, 50);
      DateTime threshold = DateTime.now().addDays(-retentionDays);

      // Query candidate old terminal instances
      List<Workflow_Instance__c> candidateInstances = [
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
        LIMIT :clampedBatchSize
      ];

      PurgeState state = new PurgeState();
      state.deletedCount = 0;
      if (String.isNotBlank(ctx.stepStateJson)) {
        state = (PurgeState) JSON.deserialize(
          ctx.stepStateJson,
          PurgeState.class
        );
      }

      if (candidateInstances.isEmpty()) {
        return StepResult.complete(null, state);
      }

      // 1. Map documents to candidate instances to limit queries
      Set<Id> candidateInstanceIds = new Set<Id>();
      for (Workflow_Instance__c inst : candidateInstances) {
        candidateInstanceIds.add(inst.Id);
      }

      List<ContentDocumentLink> links = [
        SELECT ContentDocumentId, LinkedEntityId
        FROM ContentDocumentLink
        WHERE LinkedEntityId IN :candidateInstanceIds
        WITH SYSTEM_MODE
      ];

      Map<Id, List<Id>> instanceToDocIdsMap = new Map<Id, List<Id>>();
      Set<Id> allDocIds = new Set<Id>();
      for (ContentDocumentLink link : links) {
        if (!instanceToDocIdsMap.containsKey(link.LinkedEntityId)) {
          instanceToDocIdsMap.put(link.LinkedEntityId, new List<Id>());
        }
        instanceToDocIdsMap.get(link.LinkedEntityId).add(link.ContentDocumentId);
        allDocIds.add(link.ContentDocumentId);
      }

      // 2. Select documents and perform prefix check to prevent data loss
      Map<Id, ContentDocument> docMap = new Map<Id, ContentDocument>();
      if (!allDocIds.isEmpty()) {
        List<ContentDocument> docs = [
          SELECT Id, Title
          FROM ContentDocument
          WHERE Id IN :allDocIds
          WITH SYSTEM_MODE
        ];
        for (ContentDocument doc : docs) {
          docMap.put(doc.Id, doc);
        }
      }

      Set<String> allowedPrefixes = new Set<String>{
        'Input_',
        'Output_',
        'State_',
        'Resume_',
        'ContinueInput_',
        'VerificationPayload'
      };

      // 3. Query all links for candidate documents to verify they are not shared elsewhere
      Map<Id, List<ContentDocumentLink>> docToLinksMap = new Map<Id, List<ContentDocumentLink>>();
      if (!allDocIds.isEmpty()) {
        List<ContentDocumentLink> docLinks = [
          SELECT ContentDocumentId, LinkedEntityId
          FROM ContentDocumentLink
          WHERE ContentDocumentId IN :allDocIds
          WITH SYSTEM_MODE
        ];
        for (ContentDocumentLink cdl : docLinks) {
          if (!docToLinksMap.containsKey(cdl.ContentDocumentId)) {
            docToLinksMap.put(cdl.ContentDocumentId, new List<ContentDocumentLink>());
          }
          docToLinksMap.get(cdl.ContentDocumentId).add(cdl);
        }
      }

      // 4. Build chunk of instances to process in this transaction, bounding file deletes to 100 max
      List<Workflow_Instance__c> instancesToPurge = new List<Workflow_Instance__c>();
      Set<Id> instanceIdsToPurge = new Set<Id>();
      Set<Id> finalDocIdsToDelete = new Set<Id>();

      for (Workflow_Instance__c inst : candidateInstances) {
        List<Id> docIds = instanceToDocIdsMap.get(inst.Id);
        Integer docCount = (docIds != null) ? docIds.size() : 0;

        // Bounded processing: if processing this instance would exceed our transaction cap of 100 deleted documents,
        // we defer it to the next yield chunk.
        if (!finalDocIdsToDelete.isEmpty() && (finalDocIdsToDelete.size() + docCount) > 100) {
          break;
        }

        instancesToPurge.add(inst);
        instanceIdsToPurge.add(inst.Id);

        if (docIds != null) {
          for (Id docId : docIds) {
            ContentDocument doc = docMap.get(docId);
            if (doc == null) {
              continue;
            }

            // A. Title/Prefix Check
            Boolean isEngineOwned = false;
            for (String prefix : allowedPrefixes) {
              if (doc.Title != null && doc.Title.startsWith(prefix)) {
                isEngineOwned = true;
                break;
              }
            }

            if (!isEngineOwned) {
              continue; // Do not delete user files
            }

            // B. Shared Link Check (check if shared outside this batch of purged instances)
            Boolean isSharedElsewhere = false;
            List<ContentDocumentLink> cdls = docToLinksMap.get(docId);
            if (cdls != null) {
              for (ContentDocumentLink cdl : cdls) {
                Id linkedId = cdl.LinkedEntityId;
                String sObjType = linkedId.getSObjectType().getDescribe().getName();
                // Ignore the default User link created on file upload
                if (sObjType == 'User') {
                  continue;
                }
                // If it is linked to any record other than a Workflow_Instance__c that is also being deleted in this batch:
                if (sObjType != 'Workflow_Instance__c' || !instanceIdsToPurge.contains(linkedId)) {
                  isSharedElsewhere = true;
                  break;
                }
              }
            }

            if (!isSharedElsewhere) {
              finalDocIdsToDelete.add(docId);
            }
          }
        }
      }

      // 5. Delete qualified documents
      if (!finalDocIdsToDelete.isEmpty()) {
        List<ContentDocument> docsToDelete = [
          SELECT Id
          FROM ContentDocument
          WHERE Id IN :finalDocIdsToDelete
          WITH SYSTEM_MODE
        ];
        delete as system docsToDelete;
      }

      // 6. Delete the instances (cascade deletes steps and signals)
      if (!instancesToPurge.isEmpty()) {
        delete as system instancesToPurge;
        state.deletedCount += instancesToPurge.size();
      }

      // Check if we still have remaining candidate instances that weren't processed in this batch due to the limit
      Boolean hasMore = candidateInstances.size() > instancesToPurge.size();
      if (hasMore) {
        return StepResult.yield(JSON.serialize(state));
      }

      return StepResult.yield(JSON.serialize(state));
    }
  }
}
