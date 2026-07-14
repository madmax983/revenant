/**
 * @description Document ownership and purge helper for CleanupWorkflow. Given the
 * candidate workflow instances selected for a purge batch, it indexes their
 * ContentDocuments and links, decides which files are engine-owned and unshared and
 * therefore safe to delete, deletes those files, and returns the bounded chunk of
 * instances (and their ids) for the caller to finish deleting. Extracted from
 * CleanupWorkflow.PurgeOldInstancesStep to keep that step within complexity limits.
 */
public inherited sharing class CleanupDocumentPurger {
  // Title prefixes that mark a ContentDocument as engine-owned and therefore safe to
  // purge. User-uploaded files (no matching prefix) are never deleted. Declared here
  // because Apex forbids static members on inner classes and isEngineOwned is the only
  // consumer; it references this by simple name.
  /**
   * @description Title prefixes that identify a ContentDocument as engine-owned and
   * therefore eligible for purge. Files whose title matches no prefix are never deleted.
   */
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
   * @description Indexes the documents of the candidate instances, selects the bounded
   * chunk of instances to purge along with their engine-owned unshared documents, and
   * deletes those documents. The returned chunk carries the instances and instance ids
   * for the caller to finish deleting the associated signals and instances.
   * @param candidateInstances The terminal instances selected for this purge batch.
   * @return The bounded chunk of instances to purge; its qualified documents have
   * already been deleted.
   */
  public static PurgeChunk purgeInstanceDocuments(
    List<Workflow_Instance__c> candidateInstances
  ) {
    // 1-3. Map documents to candidate instances, select those documents, and query
    //    all their links so we can verify a file is not shared elsewhere before
    //    deleting it (prevents data loss).
    DocIndex docIndex = buildDocIndex(candidateInstances);

    // 4. Build chunk of instances to process in this transaction, bounding file
    //    deletes to 100 max.
    PurgeChunk chunk = buildPurgeChunk(candidateInstances, docIndex);

    // 5. Delete qualified documents
    deleteQualifiedDocs(chunk.finalDocIdsToDelete);

    return chunk;
  }

  // ── Document mapping ─────────────────────────────────────────────────────────
  // Maps candidate instances to their documents, then loads those documents and every
  // link on them so sharing can be checked before deletion.
  /**
   * @description Maps each candidate instance to its documents, then loads those
   * documents and every link on them so sharing can be checked before deletion.
   * @param candidateInstances The instances whose documents should be indexed.
   * @return The populated document index.
   */
  private static DocIndex buildDocIndex(
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
      idx.instanceToDocIds.get(link.LinkedEntityId).add(link.ContentDocumentId);
      idx.allDocIds.add(link.ContentDocumentId);
    }

    loadDocs(idx);
    loadDocLinks(idx);
    return idx;
  }

  /**
   * @description Loads the ContentDocument records for every id in the index.
   * @param idx The document index to populate with document records.
   */
  private static void loadDocs(DocIndex idx) {
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

  /**
   * @description Loads every ContentDocumentLink for the indexed documents so sharing
   * can be evaluated before deletion.
   * @param idx The document index to populate with document links.
   */
  private static void loadDocLinks(DocIndex idx) {
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
  /**
   * @description Selects the bounded chunk of instances to purge this transaction and
   * collects their deletable documents, capping deletes at 100 documents (the first
   * instance may exceed the cap to guarantee forward progress).
   * @param candidateInstances The instances eligible for purge.
   * @param idx The document index for the candidate instances.
   * @return The bounded chunk of instances and the documents selected for deletion.
   */
  private static PurgeChunk buildPurgeChunk(
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

  /**
   * @description Adds each engine-owned, unshared document of an instance to the
   * chunk's deletion set.
   * @param docIds The document ids linked to the instance being processed.
   * @param idx The document index supplying document records and links.
   * @param chunk The chunk accumulating documents to delete.
   */
  private static void collectDeletableDocs(
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

  /**
   * @description Determines whether a document is engine-owned based on its title
   * prefix.
   * @param doc The document to evaluate.
   * @return True if the document title starts with an allowed engine prefix.
   */
  private static Boolean isEngineOwned(ContentDocument doc) {
    for (String prefix : ALLOWED_PREFIXES) {
      if (doc.Title != null && doc.Title.startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }

  /**
   * @description Determines whether a document is shared with any record other than a
   * Workflow_Instance__c being deleted in this batch (the default User link is ignored).
   * @param docId The id of the document to evaluate.
   * @param docToLinksMap The map of document id to its content document links.
   * @param instanceIdsToPurge The instance ids being deleted in this batch.
   * @return True if the document is shared elsewhere and must not be deleted.
   */
  private static Boolean isSharedElsewhere(
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
  /**
   * @description Deletes the qualified documents selected for purge.
   * @param finalDocIdsToDelete The ids of the documents to delete.
   */
  private static void deleteQualifiedDocs(Set<Id> finalDocIdsToDelete) {
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

  // The document lookups needed to decide, per candidate instance, which files are
  // engine-owned and unshared and therefore safe to delete.
  /**
   * @description The document lookups needed to decide, per candidate instance, which
   * files are engine-owned and unshared and therefore safe to delete.
   */
  private class DocIndex {
    /**
     * @description Map of candidate instance id to the ids of its linked documents.
     */
    public Map<Id, List<Id>> instanceToDocIds = new Map<Id, List<Id>>();
    /**
     * @description The union of all document ids linked to the candidate instances.
     */
    public Set<Id> allDocIds = new Set<Id>();
    /**
     * @description Map of document id to its loaded ContentDocument record.
     */
    public Map<Id, ContentDocument> docMap = new Map<Id, ContentDocument>();
    /**
     * @description Map of document id to all of its ContentDocumentLink records.
     */
    public Map<Id, List<ContentDocumentLink>> docToLinksMap = new Map<Id, List<ContentDocumentLink>>();
  }

  // Accumulated set of instances/documents selected for deletion this transaction.
  /**
   * @description Accumulated set of instances/documents selected for deletion this
   * transaction.
   */
  public class PurgeChunk {
    /**
     * @description The instances selected for deletion in this transaction.
     */
    public List<Workflow_Instance__c> instancesToPurge = new List<Workflow_Instance__c>();
    /**
     * @description The ids of the instances selected for deletion in this transaction.
     */
    public Set<Id> instanceIdsToPurge = new Set<Id>();
    /**
     * @description The ids of the documents qualified for deletion in this transaction.
     */
    public Set<Id> finalDocIdsToDelete = new Set<Id>();
  }
}
