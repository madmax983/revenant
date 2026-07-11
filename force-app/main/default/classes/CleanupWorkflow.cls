/**
 * @description System workflow definition that purges old, terminal workflow
 * instances and their engine-owned ContentDocuments in bounded, resumable batches.
 */
public inherited sharing class CleanupWorkflow implements WorkflowDefinition {
  // Title prefixes that mark a ContentDocument as engine-owned and therefore safe to
  // purge. User-uploaded files (no matching prefix) are never deleted. Declared on the
  // top-level class because Apex forbids static members on inner classes; the inner
  // PurgeOldInstancesStep references it by simple name.
  private static final Set<String> ALLOWED_PREFIXES = new Set<String>{
    'Input_',
    'Output_',
    'State_',
    'Resume_',
    'ContinueInput_',
    'Captures_',
    'VerificationPayload'
  };

  /**
   * @description Returns the ordered list of step names that make up this workflow.
   * @return A single-element list naming the purge step.
   */
  public List<String> getSteps() {
    return new List<String>{ 'CleanupWorkflow.PurgeOldInstancesStep' };
  }

  /**
   * @description Returns the name of the step the engine executes first.
   * @return The name of the purge step.
   */
  public String getInitialStep() {
    return 'CleanupWorkflow.PurgeOldInstancesStep';
  }

  /**
   * @description Computes the next step to run after the given step completes.
   * @param currentStepName The name of the step that just completed.
   * @param result The result of the completed step.
   * @return Always null, since this is a single-step workflow.
   */
  public String getNextStep(String currentStepName, StepResult result) {
    return null; // Single step workflow
  }

  /**
   * @description Durable step state tracking how many instances have been purged
   * across resumed batches of the purge run.
   */
  public class PurgeState {
    public Integer deletedCount;
  }

  // Parsed, validated input parameters for a purge run.
  private class PurgeParams {
    public Integer retentionDays = 30;
    public Integer batchSize = 200;
  }

  // Accumulated set of instances/documents selected for deletion this transaction.
  private class PurgeChunk {
    public List<Workflow_Instance__c> instancesToPurge = new List<Workflow_Instance__c>();
    public Set<Id> instanceIdsToPurge = new Set<Id>();
    public Set<Id> finalDocIdsToDelete = new Set<Id>();
  }

  // The document lookups needed to decide, per candidate instance, which files are
  // engine-owned and unshared and therefore safe to delete.
  private class DocIndex {
    public Map<Id, List<Id>> instanceToDocIds = new Map<Id, List<Id>>();
    public Set<Id> allDocIds = new Set<Id>();
    public Map<Id, ContentDocument> docMap = new Map<Id, ContentDocument>();
    public Map<Id, List<ContentDocumentLink>> docToLinksMap = new Map<Id, List<ContentDocumentLink>>();
  }

  // inherited sharing: the step runs in the engine's (caller's) context. Every SOQL
  // uses WITH SYSTEM_MODE and every DML uses `as system`, so record access is already
  // elevated deliberately where the purge needs it; the explicit keyword just satisfies
  // the sharing-declaration requirement without widening or narrowing that behavior.
  /**
   * @description The single durable step that selects terminal instances past their
   * retention window, deletes their engine-owned unshared documents, removes the
   * instances and their signals, and yields to continue when more remain.
   */
  public inherited sharing class PurgeOldInstancesStep implements WorkflowStep {
    /**
     * @description Executes one bounded purge batch, deleting qualified documents and
     * instances and yielding if further candidates remain.
     * @param ctx The durable step context supplying workflow input and step state.
     * @return A yield result if more candidates remain, otherwise a complete result.
     */
    public StepResult execute(StepContext ctx) {
      PurgeParams params = parseParams(ctx.workflowInputJson);

      // Clamp batchSize to a maximum of 50
      Integer clampedBatchSize = Math.min(params.batchSize, 50);
      DateTime threshold = DateTime.now().addDays(-params.retentionDays);

      List<Workflow_Instance__c> candidateInstances = queryCandidates(
        threshold,
        clampedBatchSize
      );

      PurgeState state = loadState(ctx.stepStateJson);

      if (candidateInstances.isEmpty()) {
        return StepResult.complete(null, state);
      }

      // 1-3. Map documents to candidate instances, select those documents, and query
      //    all their links so we can verify a file is not shared elsewhere before
      //    deleting it (prevents data loss).
      DocIndex docIndex = buildDocIndex(candidateInstances);

      // 4. Build chunk of instances to process in this transaction, bounding file
      //    deletes to 100 max.
      PurgeChunk chunk = buildPurgeChunk(candidateInstances, docIndex);

      // 5. Delete qualified documents
      deleteQualifiedDocs(chunk.finalDocIdsToDelete);

      // 6. Delete associated signal records before deleting instances.
      applyInstanceDeletion(chunk, state);

      // Check if we still have remaining candidate instances that weren't processed in
      // this batch due to the limit, or if we fetched a full batch which implies there
      // could be more in the database.
      Boolean hasMore =
        (candidateInstances.size() > chunk.instancesToPurge.size()) ||
        (candidateInstances.size() == clampedBatchSize);
      if (hasMore) {
        return StepResult.yield(JSON.serialize(state));
      }

      return StepResult.complete(null, state);
    }

    // ── Input parsing ──────────────────────────────────────────────────────────
    private PurgeParams parseParams(String inputJson) {
      PurgeParams params = new PurgeParams();
      if (String.isBlank(inputJson)) {
        return params;
      }
      Map<String, Object> input = deserializeInput(inputJson);
      if (input.containsKey('retentionDays')) {
        params.retentionDays = parseRetentionDays(input.get('retentionDays'));
      }
      if (input.containsKey('batchSize')) {
        params.batchSize = parseBatchSize(input.get('batchSize'));
      }
      return params;
    }

    private Map<String, Object> deserializeInput(String inputJson) {
      try {
        return (Map<String, Object>) JSON.deserializeUntyped(inputJson);
      } catch (Exception ex) {
        throw new WorkflowEngine.WorkflowException(
          'Malformed JSON in workflow input: ' + ex.getMessage()
        );
      }
    }

    private Integer parseRetentionDays(Object raw) {
      Integer value = toInt(raw, 'retentionDays');
      if (value < 0) {
        throw new WorkflowEngine.WorkflowException(
          'retentionDays parameter cannot be negative'
        );
      }
      return value;
    }

    private Integer parseBatchSize(Object raw) {
      Integer value = toInt(raw, 'batchSize');
      if (value <= 0) {
        throw new WorkflowEngine.WorkflowException(
          'batchSize parameter must be greater than zero'
        );
      }
      return value;
    }

    private Integer toInt(Object raw, String label) {
      try {
        return Integer.valueOf(raw);
      } catch (Exception ex) {
        throw new WorkflowEngine.WorkflowException(
          'Invalid ' + label + ' parameter type: ' + ex.getMessage()
        );
      }
    }

    // ── State + candidate selection ──────────────────────────────────────────────
    private PurgeState loadState(String stepStateJson) {
      PurgeState state = new PurgeState();
      state.deletedCount = 0;
      if (String.isNotBlank(stepStateJson)) {
        state = (PurgeState) JSON.deserialize(stepStateJson, PurgeState.class);
      }
      return state;
    }

    private List<Workflow_Instance__c> queryCandidates(
      DateTime threshold,
      Integer clampedBatchSize
    ) {
      return [
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
    }

    // ── Document mapping ─────────────────────────────────────────────────────────
    // Maps candidate instances to their documents, then loads those documents and every
    // link on them so sharing can be checked before deletion.
    private DocIndex buildDocIndex(
      List<Workflow_Instance__c> candidateInstances
    ) {
      DocIndex idx = new DocIndex();

      Set<Id> candidateInstanceIds = new Set<Id>();
      for (Workflow_Instance__c inst : candidateInstances) {
        candidateInstanceIds.add(inst.Id);
      }

      for (ContentDocumentLink link : [
        SELECT ContentDocumentId, LinkedEntityId
        FROM ContentDocumentLink
        WHERE LinkedEntityId IN :candidateInstanceIds
        WITH SYSTEM_MODE
      ]) {
        if (!idx.instanceToDocIds.containsKey(link.LinkedEntityId)) {
          idx.instanceToDocIds.put(link.LinkedEntityId, new List<Id>());
        }
        idx.instanceToDocIds.get(link.LinkedEntityId)
          .add(link.ContentDocumentId);
        idx.allDocIds.add(link.ContentDocumentId);
      }

      loadDocs(idx);
      loadDocLinks(idx);
      return idx;
    }

    private void loadDocs(DocIndex idx) {
      if (idx.allDocIds.isEmpty()) {
        return;
      }
      for (ContentDocument doc : [
        SELECT Id, Title
        FROM ContentDocument
        WHERE Id IN :idx.allDocIds
        WITH SYSTEM_MODE
      ]) {
        idx.docMap.put(doc.Id, doc);
      }
    }

    private void loadDocLinks(DocIndex idx) {
      if (idx.allDocIds.isEmpty()) {
        return;
      }
      for (ContentDocumentLink cdl : [
        SELECT ContentDocumentId, LinkedEntityId
        FROM ContentDocumentLink
        WHERE ContentDocumentId IN :idx.allDocIds
        WITH SYSTEM_MODE
      ]) {
        if (!idx.docToLinksMap.containsKey(cdl.ContentDocumentId)) {
          idx.docToLinksMap.put(
            cdl.ContentDocumentId,
            new List<ContentDocumentLink>()
          );
        }
        idx.docToLinksMap.get(cdl.ContentDocumentId).add(cdl);
      }
    }

    // ── Purge-chunk selection ────────────────────────────────────────────────────
    private PurgeChunk buildPurgeChunk(
      List<Workflow_Instance__c> candidateInstances,
      DocIndex idx
    ) {
      PurgeChunk chunk = new PurgeChunk();

      for (Workflow_Instance__c inst : candidateInstances) {
        List<Id> docIds = idx.instanceToDocIds.get(inst.Id);
        Integer docCount = (docIds != null) ? docIds.size() : 0;

        // Bounded processing: if processing this instance would exceed our soft
        // transaction cap of 100 deleted documents, defer it to the next yield chunk.
        // The first instance is allowed to exceed this soft cap to guarantee forward
        // progress.
        if (
          !chunk.instancesToPurge.isEmpty() &&
          (chunk.finalDocIdsToDelete.size() + docCount) > 100
        ) {
          break;
        }

        chunk.instancesToPurge.add(inst);
        chunk.instanceIdsToPurge.add(inst.Id);

        collectDeletableDocs(docIds, idx, chunk);
      }

      return chunk;
    }

    private void collectDeletableDocs(
      List<Id> docIds,
      DocIndex idx,
      PurgeChunk chunk
    ) {
      if (docIds == null) {
        return;
      }
      for (Id docId : docIds) {
        ContentDocument doc = idx.docMap.get(docId);
        if (doc == null) {
          continue;
        }
        // A. Title/Prefix Check — never delete user files
        if (!isEngineOwned(doc)) {
          continue;
        }
        // B. Shared Link Check — skip files still shared outside this purge batch
        if (
          !isSharedElsewhere(docId, idx.docToLinksMap, chunk.instanceIdsToPurge)
        ) {
          chunk.finalDocIdsToDelete.add(docId);
        }
      }
    }

    private Boolean isEngineOwned(ContentDocument doc) {
      for (String prefix : ALLOWED_PREFIXES) {
        if (doc.Title != null && doc.Title.startsWith(prefix)) {
          return true;
        }
      }
      return false;
    }

    private Boolean isSharedElsewhere(
      Id docId,
      Map<Id, List<ContentDocumentLink>> docToLinksMap,
      Set<Id> instanceIdsToPurge
    ) {
      List<ContentDocumentLink> cdls = docToLinksMap.get(docId);
      if (cdls == null) {
        return false;
      }
      for (ContentDocumentLink cdl : cdls) {
        Id linkedId = cdl.LinkedEntityId;
        String sObjType = linkedId.getSObjectType()
          .getDescribe(SObjectDescribeOptions.DEFERRED)
          .getName();
        // Ignore the default User link created on file upload
        if (sObjType == 'User') {
          continue;
        }
        // Shared if linked to any record other than a Workflow_Instance__c that is
        // also being deleted in this batch.
        if (
          sObjType != 'Workflow_Instance__c' ||
          !instanceIdsToPurge.contains(linkedId)
        ) {
          return true;
        }
      }
      return false;
    }

    // ── Deletion ─────────────────────────────────────────────────────────────────
    private void deleteQualifiedDocs(Set<Id> finalDocIdsToDelete) {
      if (finalDocIdsToDelete.isEmpty()) {
        return;
      }
      List<ContentDocument> docsToDelete = [
        SELECT Id
        FROM ContentDocument
        WHERE Id IN :finalDocIdsToDelete
        WITH SYSTEM_MODE
      ];
      delete as system docsToDelete;
    }

    private void applyInstanceDeletion(PurgeChunk chunk, PurgeState state) {
      if (chunk.instancesToPurge.isEmpty()) {
        return;
      }
      // Workflow_Signal__c.Workflow_Instance__c is a Lookup with SetNull (not a
      // cascade-delete MasterDetail), so signals must be deleted explicitly first.
      List<Workflow_Signal__c> signalsToDelete = [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c IN :chunk.instanceIdsToPurge
        WITH SYSTEM_MODE
      ];
      if (!signalsToDelete.isEmpty()) {
        delete as system signalsToDelete;
      }
      delete as system chunk.instancesToPurge;
      state.deletedCount += chunk.instancesToPurge.size();
    }
  }
}
