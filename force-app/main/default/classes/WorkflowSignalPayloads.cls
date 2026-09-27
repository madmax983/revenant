/**
 * @description Encodes and offloads `Workflow_Signal__c.Payload__c` values.
 * Signal rows get the encoded payload inline when the engine builds them.
 * Just before the insert, {@link #offloadOversized} moves large encoded
 * payloads to files in bulk. This runs after in-batch dedup, so an in-batch
 * duplicate makes no file. The DML cost does not grow with the row count.
 */
public inherited sharing class WorkflowSignalPayloads {
  private static final Integer INLINE_LIMIT = 100000;
  // Engine child-completion signals carry the child's stored output.
  private static final Set<String> STORED_FORM_PREFIXES = new Set<String>{
    'ChildCompleted:',
    'ChildFailed:'
  };

  /**
   * @description Encodes a signal payload for storage. A child-completion
   * signal keeps the stored form that the engine sent. All other payloads are
   * external input, so they are always encoded.
   * @param signalName the signal name
   * @param payload the signal payload
   * @return the stored form
   */
  public static String encode(String signalName, String payload) {
    if (isChildOutcome(signalName)) {
      return WorkflowPayloadCodecs.encodeStored(
        payload,
        CodecContext.PayloadKind.SIGNAL_PAYLOAD
      );
    }
    return WorkflowPayloadCodecs.encode(
      payload,
      CodecContext.PayloadKind.SIGNAL_PAYLOAD
    );
  }

  /**
   * @description Moves encoded payloads that are too large for the field to
   * `ContentVersion` files, with one insert per object type. Rows without a
   * target instance stay inline. The identity codec never offloads, so legacy
   * behavior does not change.
   * @param rows the signal rows to insert next (Payload__c changes in place)
   */
  public static void offloadOversized(List<Workflow_Signal__c> rows) {
    List<Workflow_Signal__c> targets = new List<Workflow_Signal__c>();
    for (Workflow_Signal__c row : rows) {
      if (
        row.Workflow_Instance__c != null &&
        row.Payload__c != null &&
        row.Payload__c.length() > INLINE_LIMIT
      ) {
        targets.add(row);
      }
    }
    if (targets.isEmpty() || WorkflowPayloadCodecs.isIdentity()) {
      return;
    }
    List<ContentVersion> files = insertFiles(targets);
    Map<Id, Id> docByFile = new Map<Id, Id>();
    for (ContentVersion cv : [
      SELECT Id, ContentDocumentId
      FROM ContentVersion
      WHERE Id IN :files
      WITH SYSTEM_MODE
    ]) {
      docByFile.put(cv.Id, cv.ContentDocumentId);
    }
    List<ContentDocumentLink> links = new List<ContentDocumentLink>();
    for (Integer i = 0; i < targets.size(); i++) {
      Id docId = docByFile.get(files[i].Id);
      links.add(
        new ContentDocumentLink(
          ContentDocumentId = docId,
          LinkedEntityId = targets[i].Workflow_Instance__c,
          ShareType = 'V',
          Visibility = 'InternalUsers'
        )
      );
      targets[i].Payload__c = JSON.serialize(
        new Map<String, String>{ '$attachmentId' => docId }
      );
    }
    insertLinks(links);
  }

  private static Boolean isChildOutcome(String signalName) {
    for (String prefix : STORED_FORM_PREFIXES) {
      if (signalName != null && signalName.startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }

  private static List<ContentVersion> insertFiles(
    List<Workflow_Signal__c> targets
  ) {
    List<ContentVersion> files = new List<ContentVersion>();
    for (Workflow_Signal__c row : targets) {
      String title =
        'Signal_' +
        String.valueOf(row.Signal_Name__c).replaceAll('[^a-zA-Z0-9]', '_');
      files.add(
        new ContentVersion(
          Title = title,
          PathOnClient = title + '.json',
          VersionData = Blob.valueOf(row.Payload__c)
        )
      );
    }
    Database.insert(files, true, AccessLevel.SYSTEM_MODE);
    return files;
  }

  // Same visibility rule as WorkflowPayloadOffload: retry a rejected link with
  // AllUsers visibility.
  private static void insertLinks(List<ContentDocumentLink> links) {
    Database.SaveResult[] results = Database.insert(
      links,
      false,
      AccessLevel.SYSTEM_MODE
    );
    List<ContentDocumentLink> retry = new List<ContentDocumentLink>();
    for (Integer i = 0; i < results.size(); i++) {
      if (!results[i].isSuccess()) {
        ContentDocumentLink link = links[i].clone(false, true);
        link.Visibility = 'AllUsers';
        retry.add(link);
      }
    }
    if (!retry.isEmpty()) {
      Database.insert(retry, true, AccessLevel.SYSTEM_MODE);
    }
  }
}
