/**
 * @description One bounded batch of the terminal-instance sweep, shared by
 * {@link CleanupWorkflow} and {@link ArchiveWorkflow}.
 *
 * Order in each batch:
 * 1. Select the chunk (SOQL only).
 * 2. When a sink is given, copy the chunk and call `sink.write`. There is no
 *    DML before this call, so a sink in a `CalloutStep` can call out.
 * 3. Delete engine files, signals, instance logs and instances through
 *    {@link WorkflowInstanceTeardown}. Step rows go with the instance
 *    (master-detail).
 *
 * If `write` throws, step 3 does not run. A retry writes the same records
 * again. The sink contract makes that safe.
 *
 * Archive bounds for each batch: at most 20 instances and 500 step rows. A
 * new instance starts only below a sixth of the heap. The first instance
 * always goes, so the sweep moves forward. An instance with more than 500
 * step rows, or whose copy alone passes a quarter of the heap, is not
 * archived and not purged. The batch result names it.
 *
 * With archival, a cursor (`CreatedDate`, `Id`) moves past the leading
 * candidates that the batch purged or skipped. The next batch starts after
 * the cursor, so skipped instances cannot block the sweep.
 */
public inherited sharing class WorkflowArchiveSweep {
  /** @description Maximum instances in one batch without archival. */
  public static final Integer MAX_BATCH_SIZE = 50;
  /** @description Maximum instances in one batch with archival (heap bound). */
  public static final Integer MAX_ARCHIVE_BATCH_SIZE = 20;
  /** @description Maximum step rows in one archive batch and one instance. */
  public static final Integer MAX_ARCHIVE_STEP_ROWS = 500;
  /** @description Maximum skipped Ids that a run reports. */
  public static final Integer MAX_SKIPPED_IDS = 2000;

  private static final Set<String> TERMINAL_STATUSES = WorkflowInstanceTeardown.PURGEABLE_STATUSES;

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
    /** @description Cursor: start after this creation time. Null: oldest. */
    public Datetime afterCreatedDate;
    /** @description Cursor: start after this Id at `afterCreatedDate`. */
    public Id afterId;
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
    /** @description Archive cursor after this batch, or null when it did not move. */
    public Datetime cursorCreatedDate;
    /** @description Archive cursor Id after this batch, or null. */
    public Id cursorId;
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
      p
    );
    if (candidates.isEmpty()) {
      return result;
    }
    CleanupDocumentPurger.PurgeChunk chunk;
    if (sink == null) {
      chunk = CleanupDocumentPurger.planChunk(candidates);
    } else {
      Set<Id> handled = new Set<Id>();
      Map<Id, WorkflowArchiveRecord> records = snapshotWithinBounds(
        candidates,
        result,
        handled
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
      handled.addAll(chunk.instanceIdsToPurge);
      purge(chunk, result);
      Integer done = moveCursor(candidates, handled, result);
      result.hasMore =
        done > 0 &&
        (candidates.size() > done ||
        candidates.size() == limitSize);
      return result;
    }
    purge(chunk, result);
    // More can remain when this batch did not take every candidate, or when
    // the query filled the batch.
    result.hasMore =
      candidates.size() > result.purgedCount ||
      candidates.size() == limitSize;
    return result;
  }

  private static void purge(
    CleanupDocumentPurger.PurgeChunk chunk,
    BatchResult result
  ) {
    result.purgedCount = WorkflowInstanceTeardown.run(chunk).instances;
  }

  // Moves the cursor past the leading candidates that are handled (purged,
  // skipped or gone). Returns how many it passed.
  private static Integer moveCursor(
    List<Workflow_Instance__c> candidates,
    Set<Id> handled,
    BatchResult result
  ) {
    Integer done = 0;
    for (Workflow_Instance__c inst : candidates) {
      if (!handled.contains(inst.Id)) {
        break;
      }
      result.cursorCreatedDate = inst.CreatedDate;
      result.cursorId = inst.Id;
      done++;
    }
    return done;
  }

  /**
   * @description Adds a batch's skipped Ids to the run report, up to
   * {@link #MAX_SKIPPED_IDS}. The report does not steer the sweep. The
   * cursor does.
   * @param batch the batch result
   * @param skipped the run's skipped Ids, updated in place
   */
  public static void reportSkips(BatchResult batch, List<Id> skipped) {
    for (Id instanceId : batch.skippedInstanceIds) {
      if (skipped.size() >= MAX_SKIPPED_IDS) {
        return;
      }
      skipped.add(instanceId);
    }
  }

  /**
   * @description Sets the cursor of the next batch from run state.
   * @param p the run input
   * @param createdDate the cursor time, or null
   * @param instanceId the cursor Id, or null
   */
  public static void resumeAt(Params p, Datetime createdDate, Id instanceId) {
    p.afterCreatedDate = createdDate;
    p.afterId = instanceId;
  }

  // Copies candidates in order until a bound is hit. The first archivable
  // candidate always goes. An instance over the step bound, or one that alone
  // passes the instance heap limit, is skipped.
  private static Map<Id, WorkflowArchiveRecord> snapshotWithinBounds(
    List<Workflow_Instance__c> candidates,
    BatchResult result,
    Set<Id> handled
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
        handled.add(inst.Id);
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
        if (built.isEmpty()) {
          // Deleted since the query. Nothing to archive.
          handled.add(inst.Id);
        } else {
          records.put(inst.Id, built[0]);
          stepsUsed += steps;
        }
      } catch (WorkflowArchiveSnapshot.TooLargeException e) {
        if (!records.isEmpty()) {
          // Too large next to others. The next batch tries it alone.
          break;
        }
        result.skippedInstanceIds.add(inst.Id);
        handled.add(inst.Id);
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
    Params p
  ) {
    Datetime afterDate = p.afterCreatedDate;
    Id afterId = p.afterId;
    if (afterDate == null || afterId == null) {
      return [
        SELECT Id, CreatedDate
        FROM Workflow_Instance__c
        WHERE Status__c IN :TERMINAL_STATUSES AND CreatedDate < :threshold
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC, Id ASC
        LIMIT :limitSize
      ];
    }
    return [
      SELECT Id, CreatedDate
      FROM Workflow_Instance__c
      WHERE
        Status__c IN :TERMINAL_STATUSES
        AND CreatedDate < :threshold
        AND (CreatedDate > :afterDate
        OR (CreatedDate = :afterDate
        AND Id > :afterId))
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT :limitSize
    ];
  }
}
