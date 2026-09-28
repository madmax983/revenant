/**
 * @description One bounded batch of the terminal-instance sweep, shared by
 * {@link CleanupWorkflow} and {@link ArchiveWorkflow}.
 *
 * Order in each batch:
 * 1. Select the chunk (SOQL only).
 * 2. When a sink is given, copy the chunk and call `sink.write`. There is no
 *    DML before this call, so a sink in a `CalloutStep` can call out.
 * 3. Delete engine files, signals and instances. Step rows go with the
 *    instance (master-detail).
 *
 * If `write` throws, step 3 does not run. A retry writes the same records
 * again. The sink contract makes that safe.
 */
public inherited sharing class WorkflowArchiveSweep {
  /** @description Maximum instances in one batch without archival. */
  public static final Integer MAX_BATCH_SIZE = 50;
  /** @description Maximum instances in one batch with archival (heap bound). */
  public static final Integer MAX_ARCHIVE_BATCH_SIZE = 20;
  /** @description Maximum step rows in one archive batch (heap and row bound). */
  public static final Integer MAX_ARCHIVE_STEP_ROWS = 1000;

  /**
   * @description Parsed sweep input.
   */
  public class Params {
    /** @description Minimum instance age in days. */
    public Integer ageDays;
    /** @description Requested batch size. */
    public Integer batchSize;
  }

  /**
   * @description Result of one batch.
   */
  public class BatchResult {
    /** @description Number of instances purged in this batch. */
    public Integer purgedCount = 0;
    /** @description True when more candidates can remain. */
    public Boolean hasMore = false;
  }

  /**
   * @description Parses sweep input JSON.
   * @param inputJson the workflow input, or blank
   * @param ageKey the input key of the age, for example `retentionDays`
   * @param defaultAge the age when the input has none
   * @param defaultBatch the batch size when the input has none
   * @return the parsed input
   * @throws WorkflowEngine.WorkflowException for bad input
   */
  public static Params parseParams(
    String inputJson,
    String ageKey,
    Integer defaultAge,
    Integer defaultBatch
  ) {
    Params p = new Params();
    p.ageDays = defaultAge;
    p.batchSize = defaultBatch;
    if (String.isBlank(inputJson)) {
      return p;
    }
    Map<String, Object> input = deserializeInput(inputJson);
    if (input.containsKey(ageKey)) {
      p.ageDays = toInt(input.get(ageKey), ageKey);
      if (p.ageDays < 0) {
        throw new WorkflowEngine.WorkflowException(
          ageKey + ' parameter cannot be negative'
        );
      }
    }
    if (input.containsKey('batchSize')) {
      p.batchSize = toInt(input.get('batchSize'), 'batchSize');
      if (p.batchSize <= 0) {
        throw new WorkflowEngine.WorkflowException(
          'batchSize parameter must be greater than zero'
        );
      }
    }
    return p;
  }

  /**
   * @description Runs one batch: select, archive when a sink is given, purge.
   * @param p the parsed input
   * @param sink the archive sink, or null to purge without archive
   * @return the batch result
   */
  public static BatchResult runBatch(Params p, WorkflowArchiveSink sink) {
    Integer limitSize = Math.min(
      p.batchSize,
      sink == null ? MAX_BATCH_SIZE : MAX_ARCHIVE_BATCH_SIZE
    );
    BatchResult result = new BatchResult();
    List<Workflow_Instance__c> candidates = queryCandidates(
      Datetime.now().addDays(-p.ageDays),
      limitSize
    );
    if (candidates.isEmpty()) {
      return result;
    }
    List<Workflow_Instance__c> fitted = sink == null
      ? candidates
      : WorkflowArchiveSnapshot.fitToStepBudget(
          candidates,
          MAX_ARCHIVE_STEP_ROWS
        );
    CleanupDocumentPurger.PurgeChunk chunk = CleanupDocumentPurger.planChunk(
      fitted
    );
    if (sink != null) {
      sink.write(WorkflowArchiveSnapshot.build(chunk.instanceIdsToPurge));
    }
    CleanupDocumentPurger.deleteDocuments(chunk);
    deleteInstances(chunk);
    result.purgedCount = chunk.instancesToPurge.size();
    // More can remain when this batch did not take every candidate, or when
    // the query filled the batch.
    result.hasMore =
      candidates.size() > chunk.instancesToPurge.size() ||
      candidates.size() == limitSize;
    return result;
  }

  private static Map<String, Object> deserializeInput(String inputJson) {
    try {
      return (Map<String, Object>) JSON.deserializeUntyped(inputJson);
    } catch (Exception ex) {
      throw new WorkflowEngine.WorkflowException(
        'Malformed JSON in workflow input: ' + ex.getMessage()
      );
    }
  }

  private static Integer toInt(Object raw, String label) {
    try {
      return Integer.valueOf(raw);
    } catch (Exception ex) {
      throw new WorkflowEngine.WorkflowException(
        'Invalid ' + label + ' parameter type: ' + ex.getMessage()
      );
    }
  }

  private static List<Workflow_Instance__c> queryCandidates(
    Datetime threshold,
    Integer limitSize
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
      ORDER BY CreatedDate ASC
      LIMIT :limitSize
    ];
  }

  private static void deleteInstances(CleanupDocumentPurger.PurgeChunk chunk) {
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
  }
}
