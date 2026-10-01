/**
 * @description Moves large stored payloads to `ContentVersion` files for many
 * rows at once. One call makes one file insert, one document query and one link
 * insert, whatever the row count. {@link WorkflowPayloadOffload#savePayloadIfNeeded}
 * calls it with one item. It does not encode: the caller passes the stored text.
 * All SOQL and DML run in system mode.
 */
public inherited sharing class WorkflowBulkOffload {
  private static final Integer INLINE_LIMIT = 100000;

  /** @description One stored value to check and, if too large, offload. */
  public class Item {
    /** @description Record the file links to. */
    public Id ownerId;
    /** @description Stored text to check. */
    public String text;
    /** @description Title and base file name. */
    public String title;

    /**
     * @description Builds an item.
     * @param ownerId Id of the record the file links to
     * @param text the stored text
     * @param title title and file name for the file
     */
    public Item(Id ownerId, String text, String title) {
      this.ownerId = ownerId;
      this.text = text;
      this.title = title;
    }
  }

  /**
   * @description Offloads each item whose text is longer than 100 000
   * characters. Other values stay as they are. A file has the offload flag and
   * a link to the owner.
   * @param items the items to check
   * @return for each item, in order: a `{"$attachmentId":...}` marker or the
   * original text
   */
  public static List<String> save(List<Item> items) {
    List<String> stored = new List<String>();
    List<Integer> largeIndexes = new List<Integer>();
    List<ContentVersion> files = new List<ContentVersion>();
    for (Integer i = 0; i < items.size(); i++) {
      Item item = items[i];
      stored.add(item.text);
      if (String.isNotBlank(item.text) && item.text.length() > INLINE_LIMIT) {
        largeIndexes.add(i);
        files.add(
          new ContentVersion(
            Title = item.title,
            PathOnClient = item.title + '.json',
            VersionData = Blob.valueOf(item.text),
            Revenant_Payload_Offload__c = true
          )
        );
      }
    }
    if (files.isEmpty()) {
      return stored;
    }
    Database.insert(files, true, AccessLevel.SYSTEM_MODE);
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
    for (Integer j = 0; j < largeIndexes.size(); j++) {
      Id docId = docByFile.get(files[j].Id);
      links.add(
        new ContentDocumentLink(
          ContentDocumentId = docId,
          LinkedEntityId = items[largeIndexes[j]].ownerId,
          ShareType = 'V',
          Visibility = 'InternalUsers'
        )
      );
      stored[largeIndexes[j]] = JSON.serialize(
        new Map<String, String>{ '$attachmentId' => docId }
      );
    }
    insertLinks(links);
    return stored;
  }

  /**
   * @description Inserts the links in one DML. A link that the default
   * visibility rejects is tried again with AllUsers visibility, in one more DML.
   * @param links the links to insert
   */
  public static void insertLinks(List<ContentDocumentLink> links) {
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
