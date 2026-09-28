/**
 * @description {@link WorkflowArchiveSink} that stores one CSV file
 * (`ContentVersion`) for each archived instance. Files use file storage, not
 * data storage. The format is {@link WorkflowArchiveCsv}.
 *
 * Title: `WorkflowArchive_<instanceId>_<correlationKey>`, cut to 255
 * characters. The read methods find files by title. A correlation key read
 * also compares the full key in the file.
 *
 * The file is not linked to the instance, so the purge does not delete it.
 * The sweep user owns the file. A reader needs access to the file, for
 * example "Query All Files", or a library share.
 *
 * Write is idempotent: it skips an instance that already has a file.
 */
public inherited sharing class CsvArchiveSink implements WorkflowArchiveSink {
  /** @description Title prefix of every archive file. */
  public static final String TITLE_PREFIX = 'WorkflowArchive_';
  private static final Integer TITLE_MAX = 255;
  private static final Integer ID_LENGTH = 18;

  /**
   * @description Stores one CSV file for each record that has no file yet.
   * @param records the records to store
   */
  public void write(List<WorkflowArchiveRecord> records) {
    Map<String, WorkflowArchiveRecord> byTitle = new Map<String, WorkflowArchiveRecord>();
    for (WorkflowArchiveRecord r : records) {
      byTitle.put(titleFor(r.instanceId, r.correlationKey), r);
    }
    if (byTitle.isEmpty()) {
      return;
    }
    Set<String> titles = byTitle.keySet();
    for (ContentVersion existing : [
      SELECT Title
      FROM ContentVersion
      WHERE Title IN :titles AND IsLatest = TRUE
      WITH SYSTEM_MODE
    ]) {
      byTitle.remove(existing.Title);
    }
    List<ContentVersion> files = new List<ContentVersion>();
    for (String title : byTitle.keySet()) {
      files.add(
        new ContentVersion(
          Title = title,
          PathOnClient = title + '.csv',
          VersionData = Blob.valueOf(
            WorkflowArchiveCsv.toCsv(byTitle.get(title))
          )
        )
      );
    }
    if (!files.isEmpty()) {
      insert as system files;
    }
  }

  /**
   * @description Reads archive files by instance Id.
   * @param instanceIds the instance Ids
   * @return one record for each archived Id
   */
  public List<WorkflowArchiveRecord> readByInstanceIds(Set<Id> instanceIds) {
    List<WorkflowArchiveRecord> out = new List<WorkflowArchiveRecord>();
    if (instanceIds == null || instanceIds.isEmpty()) {
      return out;
    }
    List<String> patterns = new List<String>();
    for (Id instanceId : instanceIds) {
      patterns.add(escapeLike(TITLE_PREFIX + instanceId + '_') + '%');
    }
    Set<Id> seen = new Set<Id>();
    for (ContentVersion file : [
      SELECT VersionData
      FROM ContentVersion
      WHERE Title LIKE :patterns AND IsLatest = TRUE
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC
      LIMIT :WorkflowArchive.MAX_READ_RECORDS
    ]) {
      WorkflowArchiveRecord r = WorkflowArchiveCsv.fromCsv(
        file.VersionData.toString()
      );
      if (instanceIds.contains(r.instanceId) && seen.add(r.instanceId)) {
        out.add(r);
      }
    }
    return out;
  }

  /**
   * @description Reads archive files by exact correlation key.
   * @param correlationKey the correlation key
   * @return the matching records
   */
  public List<WorkflowArchiveRecord> readByCorrelationKey(
    String correlationKey
  ) {
    List<WorkflowArchiveRecord> out = new List<WorkflowArchiveRecord>();
    if (String.isBlank(correlationKey)) {
      return out;
    }
    // One `_` matches any one character, so 18 of them match any Id.
    String pattern =
      escapeLike(TITLE_PREFIX) +
      '_'.repeat(ID_LENGTH) +
      escapeLike('_' + titleKey(correlationKey));
    for (ContentVersion file : [
      SELECT VersionData
      FROM ContentVersion
      WHERE Title LIKE :pattern AND IsLatest = TRUE
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC
      LIMIT :WorkflowArchive.MAX_READ_RECORDS
    ]) {
      WorkflowArchiveRecord r = WorkflowArchiveCsv.fromCsv(
        file.VersionData.toString()
      );
      if (r.correlationKey == correlationKey) {
        out.add(r);
      }
    }
    return out;
  }

  /**
   * @description Returns the file title for an instance.
   * @param instanceId the instance Id
   * @param correlationKey the correlation key
   * @return the title, at most 255 characters
   */
  @TestVisible
  private static String titleFor(Id instanceId, String correlationKey) {
    return TITLE_PREFIX + instanceId + '_' + titleKey(correlationKey);
  }

  private static String titleKey(String correlationKey) {
    Integer room = TITLE_MAX - TITLE_PREFIX.length() - ID_LENGTH - 1;
    return correlationKey == null ? '' : correlationKey.left(room);
  }

  // SOQL LIKE: `\` escapes `%`, `_` and itself.
  private static String escapeLike(String value) {
    return value.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_');
  }
}
