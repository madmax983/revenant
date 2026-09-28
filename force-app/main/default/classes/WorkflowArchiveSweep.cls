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
 *
 * Archive bounds for each batch: at most 20 instances and 500 step rows. A
 * new instance starts only below a sixth of the heap. The first instance
 * always goes, so the sweep moves forward. An instance with more than 500
 * step rows, or whose copy alone passes a quarter of the heap, is not
 * archived and not purged. The batch result names it, and the next batches
 * skip it.
 */
public inherited sharing class WorkflowArchiveSweep {
  /** @description Maximum instances in one batch without archival. */
  public static final Integer MAX_BATCH_SIZE = 50;
  /** @description Maximum instances in one batch with archival (heap bound). */
  public static final Integer MAX_ARCHIVE_BATCH_SIZE = 20;
  /** @description Maximum step rows in one archive batch and one instance. */
  public static final Integer MAX_ARCHIVE_STEP_ROWS = 500;
  /** @description Maximum Ids that a run keeps as skipped. */
  public static final Integer MAX_SKIPPED_IDS = 2000;

  @TestVisible
  private static Integer maxStepRows = MAX_ARCHIVE_STEP_ROWS;
  // Null means a quarter of the heap limit.
  @TestVisible
  private static Integer instanceHeapLimit;

  /**
   * @description Parsed sweep input.
   */
  public class Params {
    /** @description Minimum instance age in days. */
    public Integer ageDays;
    /** @description Requested batch size. */
    public Integer batchSize;
    /** @description Instances that earlier batches skipped. */
    public Set<Id> excludeIds = new Set<Id>();
  }

  /**
   * @description Result of one batch.
   */
  public class BatchResult {
    /** @description Number of instances purged in this batch. */
    public Integer purgedCount = 0;
    /** @description True when more candidates can remain. */
    public Boolean hasMore = false;
    /** @description Instances too large to archive. Kept in primary storage. */
    public List<Id> skippedInstanceIds = new List<Id>();
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
      limitSize,
      p.excludeIds
    );
    if (candidates.isEmpty()) {
      return result;
    }
    CleanupDocumentPurger.PurgeChunk chunk;
    if (sink == null) {
      chunk = CleanupDocumentPurger.planChunk(candidates);
    } else {
      Map<Id, WorkflowArchiveRecord> records = snapshotWithinBounds(
        candidates,
        result
      );
      chunk = CleanupDocumentPurger.planChunk(
        selectInOrder(candidates, records.keySet())
      );
      List<WorkflowArchiveRecord> toWrite = new List<WorkflowArchiveRecord>();
      for (Workflow_Instance__c inst : chunk.instancesToPurge) {
        toWrite.add(records.get(inst.Id));
      }
      if (!toWrite.isEmpty()) {
        sink.write(toWrite);
      }
    }
    CleanupDocumentPurger.deleteDocuments(chunk);
    deleteInstances(chunk);
    result.purgedCount = chunk.instancesToPurge.size();
    // More can remain when this batch did not take every candidate, or when
    // the query filled the batch. A batch that only found known skips stops.
    result.hasMore =
      (result.purgedCount > 0 || !result.skippedInstanceIds.isEmpty()) &&
      (candidates.size() > result.purgedCount ||
      candidates.size() == limitSize);
    return result;
  }

  /**
   * @description Adds a batch's skipped Ids to the run's exclude set, up to
   * {@link #MAX_SKIPPED_IDS}.
   * @param p the run input
   * @param batch the batch result
   * @param skipped the run's skipped Ids, updated in place
   * @return true when the run must yield for another batch. A batch that
   *         purged nothing and recorded no new skip ends the run, so a full
   *         skip list cannot loop.
   */
  public static Boolean recordSkips(
    Params p,
    BatchResult batch,
    List<Id> skipped
  ) {
    Integer added = 0;
    for (Id instanceId : batch.skippedInstanceIds) {
      if (skipped.size() >= MAX_SKIPPED_IDS) {
        break;
      }
      skipped.add(instanceId);
      p.excludeIds.add(instanceId);
      added++;
    }
    return batch.hasMore && (batch.purgedCount > 0 || added > 0);
  }

  // Copies candidates in order until a bound is hit. The first archivable
  // candidate always goes. An instance over the step bound, or one that alone
  // passes the instance heap limit, is skipped.
  private static Map<Id, WorkflowArchiveRecord> snapshotWithinBounds(
    List<Workflow_Instance__c> candidates,
    BatchResult result
  ) {
    Map<Id, WorkflowArchiveRecord> records = new Map<Id, WorkflowArchiveRecord>();
    Integer batchHeap = Limits.getLimitHeapSize() / 6;
    Integer instanceHeap = instanceHeapLimit != null
      ? instanceHeapLimit
      : Limits.getLimitHeapSize() / 4;
    Integer stepsUsed = 0;
    for (Workflow_Instance__c inst : candidates) {
      Integer steps = WorkflowArchiveSnapshot.countSteps(
        inst.Id,
        maxStepRows + 1
      );
      if (steps > maxStepRows) {
        result.skippedInstanceIds.add(inst.Id);
        continue;
      }
      if (
        !records.isEmpty() &&
        (stepsUsed + steps > maxStepRows ||
        Limits.getHeapSize() > batchHeap)
      ) {
        break;
      }
      try {
        List<WorkflowArchiveRecord> built = WorkflowArchiveSnapshot.build(
          new Set<Id>{ inst.Id },
          instanceHeap
        );
        if (!built.isEmpty()) {
          records.put(inst.Id, built[0]);
          stepsUsed += steps;
        }
      } catch (WorkflowArchiveSnapshot.TooLargeException e) {
        if (!records.isEmpty()) {
          // Too large next to others. The next batch tries it alone.
          break;
        }
        result.skippedInstanceIds.add(inst.Id);
      }
    }
    return records;
  }

  private static List<Workflow_Instance__c> selectInOrder(
    List<Workflow_Instance__c> candidates,
    Set<Id> ids
  ) {
    List<Workflow_Instance__c> out = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c inst : candidates) {
      if (ids.contains(inst.Id)) {
        out.add(inst);
      }
    }
    return out;
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
    Integer limitSize,
    Set<Id> excludeIds
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
        AND Id NOT IN :excludeIds
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
