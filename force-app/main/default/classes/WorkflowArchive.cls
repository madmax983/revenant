/**
 * @description Operator API for archived workflow history, and the archive
 * config. Reads use the configured {@link WorkflowArchiveSink}. Reads work
 * also when archival is off, so old archives stay readable.
 *
 * Config (`Revenant_Config__mdt`, record `Default`):
 * - `Archive_Enabled__c`: opt-in switch. Off by default.
 * - `Archive_Sink__c`: sink class name. Blank selects
 *   {@link BigObjectArchiveSink}.
 * - `Archive_After_Days__c`: default age for `ArchiveWorkflow`. Blank is 30.
 *
 * Fail closed: when the config cannot be read, `isEnabled` throws. The sweep
 * then purges nothing. When the `Default` record does not exist, archival is
 * off.
 */
global inherited sharing class WorkflowArchive {
  /**
   * @description Blocks construction. Apex adds a global constructor when
   * a global class has none.
   */
  private WorkflowArchive() {
    // Static facade. No state.
  }

  /** @description Maximum number of records a correlation key read returns. */
  global static final Integer MAX_READ_RECORDS = 10;
  /** @description Default archive age in days. */
  public static final Integer DEFAULT_ARCHIVE_AFTER_DAYS = 30;

  private static Boolean loaded = false;
  private static Boolean configFailed = false;
  private static Boolean enabled = false;
  private static String sinkClass;
  private static Integer afterDays = DEFAULT_ARCHIVE_AFTER_DAYS;
  private static WorkflowArchiveSink activeSink;

  /**
   * @description Thrown for an archive config error, a sink error or bad
   * archive data. The sweep purges nothing after this error.
   */
  global class ArchiveException extends Exception {
  }

  /**
   * @description Returns true when archival is on.
   * @return true when the sweeps must archive before they purge
   * @throws ArchiveException when the config cannot be read
   */
  public static Boolean isEnabled() {
    load();
    return enabled;
  }

  /**
   * @description Returns the default archive age for `ArchiveWorkflow`.
   * @return the age in days
   */
  public static Integer archiveAfterDays() {
    load();
    return afterDays;
  }

  /**
   * @description Returns the configured sink.
   * @return the sink
   * @throws ArchiveException when the config or the sink class is not valid
   */
  public static WorkflowArchiveSink sink() {
    load();
    if (activeSink == null) {
      activeSink = resolve(sinkClass);
    }
    return activeSink;
  }

  /**
   * @description Returns the archived history of one instance. One sink read.
   * @param instanceId the instance Id
   * @return the record, or null when the instance is not archived
   * @throws ArchiveException when the config or the sink class is not valid
   */
  global static WorkflowArchiveRecord getArchivedHistory(Id instanceId) {
    if (instanceId == null) {
      return null;
    }
    List<WorkflowArchiveRecord> records = sink()
      .readByInstanceIds(new Set<Id>{ instanceId });
    return records.isEmpty() ? null : records[0];
  }

  /**
   * @description Returns the archived histories for a correlation key. One
   * sink read.
   * @param correlationKey the correlation key. Case does not matter, as in
   *        `Correlation_Key__c`.
   * @return the records, at most {@link #MAX_READ_RECORDS}
   * @throws ArchiveException when the config or the sink class is not valid
   */
  global static List<WorkflowArchiveRecord> findArchivedHistory(
    String correlationKey
  ) {
    List<WorkflowArchiveRecord> out = new List<WorkflowArchiveRecord>();
    if (String.isBlank(correlationKey)) {
      return out;
    }
    for (
      WorkflowArchiveRecord r : sink().readByCorrelationKey(correlationKey)
    ) {
      if (out.size() == MAX_READ_RECORDS) {
        break;
      }
      out.add(r);
    }
    return out;
  }

  /**
   * @description Returns the lookup hash of a correlation key. Sinks use it
   * where an index cannot hold the full key. `Correlation_Key__c` is not
   * case-sensitive, so the hash uses the lower-case key.
   * @param correlationKey the key. Null hashes as blank.
   * @return the SHA-256 hex, 64 characters. This algorithm is part of the
   * contract. Do not change it.
   */
  global static String hashCorrelationKey(String correlationKey) {
    return EncodingUtil.convertToHex(
      Crypto.generateDigest(
        'SHA-256',
        Blob.valueOf(correlationKey == null ? '' : correlationKey.toLowerCase())
      )
    );
  }

  /**
   * @description Makes a sink from a class name. Blank selects
   * {@link BigObjectArchiveSink}. The lookup uses {@link WorkflowTypeResolver},
   * so namespaced and subscriber classes resolve.
   * @param className the sink class name
   * @return the sink
   * @throws ArchiveException when the name is not a valid sink
   */
  @TestVisible
  private static WorkflowArchiveSink resolve(String className) {
    if (String.isBlank(className)) {
      return new BigObjectArchiveSink();
    }
    Type sinkType = WorkflowTypeResolver.resolve(className.trim());
    if (sinkType == null) {
      throw new ArchiveException('Archive sink class not found: ' + className);
    }
    if (!WorkflowArchiveSink.class.isAssignableFrom(sinkType)) {
      throw new ArchiveException(
        'Class does not implement WorkflowArchiveSink: ' + className
      );
    }
    try {
      return (WorkflowArchiveSink) sinkType.newInstance();
    } catch (Exception e) {
      throw new ArchiveException(
        'Archive sink class cannot be made: ' + className
      );
    }
  }

  /**
   * @description Sets the archive config for a test.
   * @param isOn true to turn archival on
   * @param testSink the sink to use
   */
  @TestVisible
  private static void configure(Boolean isOn, WorkflowArchiveSink testSink) {
    loaded = true;
    configFailed = false;
    enabled = isOn;
    activeSink = testSink;
  }

  /**
   * @description Makes the next config read fail, for a test.
   */
  @TestVisible
  private static void simulateConfigReadFailure() {
    loaded = true;
    configFailed = true;
  }

  private static void load() {
    if (!loaded) {
      readConfig();
      loaded = true;
    }
    if (configFailed) {
      throw new ArchiveException(
        'Revenant_Config__mdt could not be read. The archive sweep stops.'
      );
    }
  }

  private static void readConfig() {
    try {
      List<Revenant_Config__mdt> configs = [
        SELECT Archive_Enabled__c, Archive_Sink__c, Archive_After_Days__c
        FROM Revenant_Config__mdt
        WHERE DeveloperName = 'Default'
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      applyConfig(configs.isEmpty() ? null : configs[0]);
    } catch (Exception e) {
      configFailed = true;
    }
  }

  /**
   * @description Applies a config record. Null (no `Default` record) turns
   * archival off. A negative age uses the default.
   * @param cfg the config record, or null
   */
  @TestVisible
  private static void applyConfig(Revenant_Config__mdt cfg) {
    loaded = true;
    configFailed = false;
    activeSink = null;
    enabled = cfg != null && cfg.Archive_Enabled__c == true;
    sinkClass = cfg == null ? null : cfg.Archive_Sink__c;
    afterDays = DEFAULT_ARCHIVE_AFTER_DAYS;
    if (
      cfg != null &&
      cfg.Archive_After_Days__c != null &&
      cfg.Archive_After_Days__c >= 0
    ) {
      afterDays = cfg.Archive_After_Days__c.intValue();
    }
  }
}
