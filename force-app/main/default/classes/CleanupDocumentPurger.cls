/**
 * @description Document ownership and purge helper for CleanupWorkflow. Given the
 * candidate workflow instances selected for a purge batch, it indexes their
 * ContentDocuments and links, decides which files are engine-owned and unshared and
 * therefore safe to delete, and returns the bounded chunk of instances (and their
 * ids). {@link #planChunk} does SOQL only, so the archive can copy the chunk
 * before {@link #deleteDocuments} deletes the files. Used by
 * {@link WorkflowArchiveSweep} and {@link WorkflowInstancePurge}.
 * {@link #planGroups} keeps a group of related instances in one chunk.
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

  /** @description Soft cap of linked files in one chunk. */
  public static final Integer MAX_DOCS_PER_CHUNK = 100;
  // Tests lower the cap to exercise the deferral path with few files.
  @TestVisible
  private static Integer maxDocsPerChunk = MAX_DOCS_PER_CHUNK;

  /**
   * @description Selects the bounded chunk of instances to purge and their
   * engine-owned unshared documents. SOQL only: it deletes nothing, so the
   * archive can copy the chunk first.
   * @param candidateInstances The terminal instances selected for this batch.
   * @return The bounded chunk. Its documents are not deleted yet.
   */
  public static PurgeChunk planChunk(
    List<Workflow_Instance__c> candidateInstances
  ) {
    List<List<Workflow_Instance__c>> groups = new List<List<Workflow_Instance__c>>();
    for (Workflow_Instance__c inst : candidateInstances) {
      groups.add(new List<Workflow_Instance__c>{ inst });
    }
    return planGroups(groups);
  }

  /**
   * @description Selects whole groups in order until the file cap is full.
   * The first group always goes, so the purge moves forward. A group never
   * splits. SOQL only.
   * @param groups The groups of instances, in purge order.
   * @return The bounded chunk. Its documents are not deleted yet.
   */
  public static PurgeChunk planGroups(List<List<Workflow_Instance__c>> groups) {
    List<Workflow_Instance__c> all = new List<Workflow_Instance__c>();
    for (List<Workflow_Instance__c> grp : groups) {
      all.addAll(grp);
    }
    // 1-3. Map documents to candidate instances, select those documents, and query
    //    all their links so we can verify a file is not shared elsewhere before
    //    deleting it (prevents data loss).
    DocIndex docIndex = buildDocIndex(all);

    // 4. Build chunk of instances to process in this transaction, bounding file
    //    deletes to the cap.
    return buildPurgeChunk(groups, docIndex);
  }

  /**
   * @description Deletes the documents that {@link #planChunk} selected.
   * @param chunk The planned chunk.
   * @return The number of deleted documents.
   */
  public static Integer deleteDocuments(PurgeChunk chunk) {
    // 5. Delete qualified documents
    return deleteQualifiedDocs(chunk.finalDocIdsToDelete);
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
    // An empty IN set on ContentDocumentLink fails on the platform.
    if (candidateInstanceIds.isEmpty()) {
      return idx;
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
      SELECT Id, Title, OwnerId
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
   * @description Selects the bounded chunk of groups to purge this transaction and
   * collects their deletable documents, capping deletes at the file cap (the first
   * group may exceed the cap to guarantee forward progress).
   * @param groups The groups eligible for purge, in order.
   * @param idx The document index for the candidate instances.
   * @return The bounded chunk of instances and the documents selected for deletion.
   */
  private static PurgeChunk buildPurgeChunk(
    List<List<Workflow_Instance__c>> groups,
    DocIndex idx
  ) {
    PurgeChunk chunk = new PurgeChunk();

    for (List<Workflow_Instance__c> grp : groups) {
      Integer docCount = 0;
      for (Workflow_Instance__c inst : grp) {
        List<Id> docIds = idx.instanceToDocIds.get(inst.Id);
        docCount += (docIds != null) ? docIds.size() : 0;
      }

      // Bounded processing: if this group would exceed the soft cap of deleted
      // documents, defer it and the rest to the next chunk. The first group is
      // allowed to exceed this soft cap to guarantee forward progress.
      if (
        !chunk.instancesToPurge.isEmpty() &&
        (chunk.finalDocIdsToDelete.size() + docCount) > maxDocsPerChunk
      ) {
        break;
      }

      // Add the whole group first, so a file linked only inside the group
      // counts as not shared.
      for (Workflow_Instance__c inst : grp) {
        chunk.instancesToPurge.add(inst);
        chunk.instanceIdsToPurge.add(inst.Id);
      }
      for (Workflow_Instance__c inst : grp) {
        collectDeletableDocs(idx.instanceToDocIds.get(inst.Id), idx, chunk);
      }
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
        !isSharedElsewhere(doc, idx.docToLinksMap, chunk.instanceIdsToPurge)
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
   * Workflow_Instance__c being deleted in this batch. Only the owner's User link is
   * ignored. A link to any other User is a share, so the file stays.
   * @param doc The document to evaluate.
   * @param docToLinksMap The map of document id to its content document links.
   * @param instanceIdsToPurge The instance ids being deleted in this batch.
   * @return True if the document is shared elsewhere and must not be deleted.
   */
  private static Boolean isSharedElsewhere(
    ContentDocument doc,
    Map<Id, List<ContentDocumentLink>> docToLinksMap,
    Set<Id> instanceIdsToPurge
  ) {
    List<ContentDocumentLink> cdls = docToLinksMap.get(doc.Id);
    if (cdls == null) {
      return false;
    }
    for (ContentDocumentLink cdl : cdls) {
      Id linkedId = cdl.LinkedEntityId;
      String sObjType = linkedId.getSObjectType()
        .getDescribe(SObjectDescribeOptions.DEFERRED)
        .getName();
      // Ignore the owner link created on file upload.
      if (sObjType == 'User' && linkedId == doc.OwnerId) {
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
   * @return The number of deleted documents.
   */
  private static Integer deleteQualifiedDocs(Set<Id> finalDocIdsToDelete) {
    if (finalDocIdsToDelete.isEmpty()) {
      return 0;
    }
    List<ContentDocument> docsToDelete = [
      SELECT Id
      FROM ContentDocument
      WHERE Id IN :finalDocIdsToDelete
      WITH SYSTEM_MODE
    ];
    if (!docsToDelete.isEmpty()) {
      delete as system docsToDelete;
    }
    return docsToDelete.size();
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
