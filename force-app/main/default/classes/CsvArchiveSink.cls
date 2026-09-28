/**
 * @description {@link WorkflowArchiveSink} that stores one CSV file
 * (`ContentVersion`) for each archived instance. Files use file storage, not
 * data storage. The format is {@link WorkflowArchiveCsv}.
 *
 * The sink marks each file with `Revenant_Archive_Instance_Id__c` and
 * `Revenant_Archive_Key_Hash__c`. It finds files only by these fields. No
 * permission set grants access to them, so a user cannot plant a file that
 * the sink trusts. The title (`WorkflowArchive_<instanceId>_<key>`) is for
 * people only.
 *
 * The file is not linked to the instance, so the purge does not delete it.
 * When the org has a library with the API name `Revenant_Archive`, the sink
 * puts each file in it. Library members can then read the archive. Without
 * the library, only the sweep user and users with "Query All Files" see the
 * files. Run the sweep as one dedicated integration user.
 *
 * The sink reads only the marked version. A later version that a user
 * uploads has no mark, so it cannot change the archive.
 *
 * Write is idempotent: it skips an instance that already has a marked file.
 */
public inherited sharing class CsvArchiveSink implements WorkflowArchiveSink {
  /** @description Title prefix of every archive file. */
  public static final String TITLE_PREFIX = 'WorkflowArchive_';
  /** @description API name of the optional archive library. */
  public static final String LIBRARY_NAME = 'Revenant_Archive';
  private static final Integer TITLE_MAX = 255;

  /**
   * @description Stores one CSV file for each record that has no file yet.
   * @param records the records to store
   */
  public void write(List<WorkflowArchiveRecord> records) {
    Map<String, WorkflowArchiveRecord> byId = new Map<String, WorkflowArchiveRecord>();
    for (WorkflowArchiveRecord r : records) {
      byId.put(String.valueOf(r.instanceId), r);
    }
    if (byId.isEmpty()) {
      return;
    }
    Set<String> ids = byId.keySet();
    for (ContentVersion existing : [
      SELECT Revenant_Archive_Instance_Id__c
      FROM ContentVersion
      WHERE Revenant_Archive_Instance_Id__c IN :ids
      WITH SYSTEM_MODE
    ]) {
      byId.remove(existing.Revenant_Archive_Instance_Id__c);
    }
    List<ContentVersion> files = new List<ContentVersion>();
    Id library = byId.isEmpty() ? null : libraryId();
    for (WorkflowArchiveRecord r : byId.values()) {
      String title = titleFor(r.instanceId, r.correlationKey);
      files.add(
        new ContentVersion(
          Title = title,
          PathOnClient = title + '.csv',
          VersionData = Blob.valueOf(WorkflowArchiveCsv.toCsv(r)),
          FirstPublishLocationId = library,
          Revenant_Archive_Instance_Id__c = r.instanceId,
          Revenant_Archive_Key_Hash__c = WorkflowArchive.hashCorrelationKey(
            r.correlationKey
          )
        )
      );
    }
    if (!files.isEmpty()) {
      insert as system files;
    }
  }

  /**
   * @description Reads archive files by instance Id. One SOQL query for the
   * marks, then one for each file, so the heap holds one file at a time.
   * @param instanceIds the instance Ids
   * @return one record for each archived Id
   */
  public List<WorkflowArchiveRecord> readByInstanceIds(Set<Id> instanceIds) {
    List<WorkflowArchiveRecord> out = new List<WorkflowArchiveRecord>();
    if (instanceIds == null || instanceIds.isEmpty()) {
      return out;
    }
    Set<String> ids = new Set<String>();
    for (Id instanceId : instanceIds) {
      ids.add(String.valueOf(instanceId));
    }
    // The first marked file of each instance wins.
    Map<String, Id> fileByInstance = new Map<String, Id>();
    for (ContentVersion file : [
      SELECT Id, Revenant_Archive_Instance_Id__c
      FROM ContentVersion
      WHERE Revenant_Archive_Instance_Id__c IN :ids
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
    ]) {
      if (!fileByInstance.containsKey(file.Revenant_Archive_Instance_Id__c)) {
        fileByInstance.put(file.Revenant_Archive_Instance_Id__c, file.Id);
      }
    }
    for (Id fileId : fileByInstance.values()) {
      out.add(load(fileId));
    }
    return out;
  }

  /**
   * @description Reads archive files by exact correlation key.
   * @param correlationKey the correlation key
   * @return the matching records, at most
   *         {@link WorkflowArchive#MAX_READ_RECORDS}
   */
  public List<WorkflowArchiveRecord> readByCorrelationKey(
    String correlationKey
  ) {
    List<WorkflowArchiveRecord> out = new List<WorkflowArchiveRecord>();
    if (String.isBlank(correlationKey)) {
      return out;
    }
    String keyHash = WorkflowArchive.hashCorrelationKey(correlationKey);
    for (ContentVersion file : [
      SELECT Id
      FROM ContentVersion
      WHERE Revenant_Archive_Key_Hash__c = :keyHash
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT :WorkflowArchive.MAX_READ_RECORDS
    ]) {
      WorkflowArchiveRecord r = load(file.Id);
      // The hash can collide. The full key cannot.
      // Apex `==` ignores case. `equals` does not.
      if (correlationKey.equals(r.correlationKey)) {
        out.add(r);
      }
    }
    return out;
  }

  private static WorkflowArchiveRecord load(Id fileId) {
    ContentVersion file = [
      SELECT VersionData
      FROM ContentVersion
      WHERE Id = :fileId
      WITH SYSTEM_MODE
    ];
    return WorkflowArchiveCsv.fromCsv(file.VersionData.toString());
  }

  /**
   * @description Returns the Id of the `Revenant_Archive` library, or null.
   * @return the library Id, or null when the org has no such library
   */
  @TestVisible
  private static Id libraryId() {
    List<ContentWorkspace> libraries = [
      SELECT Id
      FROM ContentWorkspace
      WHERE DeveloperName = :LIBRARY_NAME
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return libraries.isEmpty() ? null : libraries[0].Id;
  }

  /**
   * @description Returns the file title for an instance.
   * @param instanceId the instance Id
   * @param correlationKey the correlation key
   * @return the title, at most 255 characters
   */
  @TestVisible
  private static String titleFor(Id instanceId, String correlationKey) {
    String title = TITLE_PREFIX + instanceId + '_';
    return title +
      (correlationKey == null
        ? ''
        : correlationKey.left(TITLE_MAX - title.length()));
  }
}
