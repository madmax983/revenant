/**
 * @description Default {@link WorkflowArchiveSink}. It stores history in Big
 * Objects, which do not use data storage.
 *
 * - `Workflow_Archive__b`, index (`Instance_Id__c`, `Sequence__c`): row 0 is
 *   the instance, rows 1 and up are the steps.
 * - `Workflow_Archive_Key__b`, index (`Key_Hash__c`, `Instance_Id__c`): the
 *   correlation key index. A Big Object index holds at most 100 text
 *   characters, so it uses the SHA-256 hex of the key. Readers compare the
 *   full key.
 *
 * `insertImmediate` overwrites a row with the same index, so write is
 * idempotent. It commits at once, also when the transaction rolls back later.
 *
 * Tests cannot write Big Objects. Tests replace {@link Store}.
 */
public inherited sharing class BigObjectArchiveSink implements WorkflowArchiveSink {
  /** @description Maximum timeline rows read for one instance. */
  public static final Integer MAX_READ_ROWS_PER_INSTANCE =
    WorkflowArchiveSweep.MAX_ARCHIVE_STEP_ROWS + 1;

  @TestVisible
  private static Store store = new Store();

  /**
   * @description Big Object access. Tests replace it with an in-memory store.
   */
  public virtual class Store {
    /**
     * @description Inserts Big Object rows. Throws when a row fails.
     * @param rows the rows, all of one type
     */
    public virtual void insertRows(List<SObject> rows) {
      checkResults(Database.insertImmediate(rows));
    }

    /**
     * @description Reads timeline rows in index order.
     * @param instanceIds the instance Ids
     * @param rowLimit the maximum number of rows
     * @return the rows
     */
    @SuppressWarnings(
      'PMD.ApexCRUDViolation'
    ) // Big Object SOQL has no CRUD or FLS
    public virtual List<Workflow_Archive__b> queryTimeline(
      Set<String> instanceIds,
      Integer rowLimit
    ) {
      // Big Object SOQL: filter on the leading index field only.
      return [
        SELECT
          Instance_Id__c,
          Sequence__c,
          Workflow_Name__c,
          Correlation_Key__c,
          Status__c,
          Error_Message__c,
          Failure_Category__c,
          Parent_Instance_Id__c,
          Created_At__c,
          Ended_At__c,
          Archived_At__c,
          Input__c,
          Output__c,
          Dropped_Payload_Count__c,
          Step_Count__c,
          Execution_Id__c,
          Step_Name__c,
          Attempt__c,
          Error_Details__c
        FROM Workflow_Archive__b
        WHERE Instance_Id__c IN :instanceIds
        LIMIT :rowLimit
      ];
    }

    /**
     * @description Reads correlation key index rows.
     * @param keyHash the SHA-256 hex of the key
     * @param rowLimit the maximum number of rows
     * @return the rows
     */
    @SuppressWarnings(
      'PMD.ApexCRUDViolation'
    ) // Big Object SOQL has no CRUD or FLS
    public virtual List<Workflow_Archive_Key__b> queryKeys(
      String keyHash,
      Integer rowLimit
    ) {
      return [
        SELECT Key_Hash__c, Instance_Id__c, Correlation_Key__c
        FROM Workflow_Archive_Key__b
        WHERE Key_Hash__c = :keyHash
        LIMIT :rowLimit
      ];
    }
  }

  /**
   * @description Writes timeline rows, then key rows. Throws when a row fails.
   * @param records the records to store
   */
  public void write(List<WorkflowArchiveRecord> records) {
    if (records == null || records.isEmpty()) {
      return;
    }
    List<Workflow_Archive__b> timeline = new List<Workflow_Archive__b>();
    List<Workflow_Archive_Key__b> keys = new List<Workflow_Archive_Key__b>();
    for (WorkflowArchiveRecord r : records) {
      timeline.add(headerRow(r));
      for (WorkflowArchiveRecord.Step s : r.steps) {
        timeline.add(stepRow(r.instanceId, s));
      }
      keys.add(
        new Workflow_Archive_Key__b(
          Key_Hash__c = WorkflowArchive.hashCorrelationKey(r.correlationKey),
          Instance_Id__c = r.instanceId,
          Correlation_Key__c = r.correlationKey
        )
      );
    }
    try {
      store.insertRows(timeline);
      store.insertRows(keys);
    } catch (WorkflowArchive.ArchiveException e) {
      throw e;
    } catch (Exception e) {
      throw new WorkflowArchive.ArchiveException(
        'Big Object archive write failed: ' + e.getTypeName()
      );
    }
  }

  /**
   * @description Reads archived records by instance Id. One SOQL query for
   * each Id, so a large timeline cannot hide another instance.
   * @param instanceIds the instance Ids
   * @return one record for each archived Id
   */
  public List<WorkflowArchiveRecord> readByInstanceIds(Set<Id> instanceIds) {
    List<WorkflowArchiveRecord> out = new List<WorkflowArchiveRecord>();
    if (instanceIds == null) {
      return out;
    }
    for (Id instanceId : instanceIds) {
      out.addAll(
        toRecords(
          store.queryTimeline(
            new Set<String>{ String.valueOf(instanceId) },
            MAX_READ_ROWS_PER_INSTANCE
          )
        )
      );
    }
    return out;
  }

  /**
   * @description Reads archived records by correlation key (case does not
   * matter). One SOQL
   * query for the key index, then one for each match.
   * @param correlationKey the correlation key
   * @return the matching records
   */
  public List<WorkflowArchiveRecord> readByCorrelationKey(
    String correlationKey
  ) {
    Set<Id> ids = new Set<Id>();
    for (
      Workflow_Archive_Key__b row : store.queryKeys(
        WorkflowArchive.hashCorrelationKey(correlationKey),
        WorkflowArchive.MAX_READ_RECORDS
      )
    ) {
      // Correlation_Key__c is not case-sensitive. The hash is lower-case.
      if (correlationKey.equalsIgnoreCase(row.Correlation_Key__c)) {
        ids.add(Id.valueOf(row.Instance_Id__c));
      }
    }
    return readByInstanceIds(ids);
  }

  /**
   * @description Throws when a Big Object row was not stored.
   * @param results the insert results
   */
  @TestVisible
  private static void checkResults(List<Database.SaveResult> results) {
    for (Database.SaveResult result : results) {
      if (!result.isSuccess()) {
        // Status codes only: an error message can echo payload text.
        List<String> codes = new List<String>();
        for (Database.Error err : result.getErrors()) {
          codes.add(String.valueOf(err.getStatusCode()));
        }
        throw new WorkflowArchive.ArchiveException(
          'Big Object archive row failed: ' + String.join(codes, '; ')
        );
      }
    }
  }

  private static Workflow_Archive__b headerRow(WorkflowArchiveRecord r) {
    return new Workflow_Archive__b(
      Instance_Id__c = r.instanceId,
      Sequence__c = 0,
      Workflow_Name__c = r.workflowName,
      Correlation_Key__c = r.correlationKey,
      Status__c = r.status,
      Error_Message__c = r.errorMessage,
      Failure_Category__c = r.failureCategory,
      Parent_Instance_Id__c = r.parentInstanceId,
      Created_At__c = r.createdAt,
      Ended_At__c = r.terminalAt,
      Archived_At__c = r.archivedAt,
      Input__c = r.input,
      Output__c = r.output,
      Dropped_Payload_Count__c = r.droppedPayloadCount,
      Step_Count__c = r.stepCount
    );
  }

  private static Workflow_Archive__b stepRow(
    Id instanceId,
    WorkflowArchiveRecord.Step s
  ) {
    return new Workflow_Archive__b(
      Instance_Id__c = instanceId,
      Sequence__c = s.sequence,
      Execution_Id__c = s.executionId,
      Step_Name__c = s.stepName,
      Status__c = s.status,
      Attempt__c = s.attempt,
      Created_At__c = s.startedAt,
      Ended_At__c = s.endedAt,
      Error_Details__c = s.errorDetails
    );
  }

  // Groups rows by instance. Row 0 makes the record. Other rows are steps.
  private static List<WorkflowArchiveRecord> toRecords(
    List<Workflow_Archive__b> rows
  ) {
    Map<String, WorkflowArchiveRecord> byId = new Map<String, WorkflowArchiveRecord>();
    Map<String, List<Workflow_Archive__b>> stepsById = new Map<String, List<Workflow_Archive__b>>();
    for (Workflow_Archive__b row : rows) {
      if (row.Sequence__c == 0) {
        byId.put(row.Instance_Id__c, fromHeader(row));
      } else {
        if (!stepsById.containsKey(row.Instance_Id__c)) {
          stepsById.put(row.Instance_Id__c, new List<Workflow_Archive__b>());
        }
        stepsById.get(row.Instance_Id__c).add(row);
      }
    }
    for (String instanceId : byId.keySet()) {
      WorkflowArchiveRecord r = byId.get(instanceId);
      List<Workflow_Archive__b> stepRows = stepsById.get(instanceId);
      if (stepRows == null) {
        continue;
      }
      Map<Integer, WorkflowArchiveRecord.Step> bySequence = new Map<Integer, WorkflowArchiveRecord.Step>();
      for (Workflow_Archive__b row : stepRows) {
        bySequence.put(row.Sequence__c.intValue(), fromStepRow(row));
      }
      List<Integer> order = new List<Integer>(bySequence.keySet());
      order.sort();
      for (Integer seq : order) {
        r.steps.add(bySequence.get(seq));
      }
    }
    return byId.values();
  }

  private static WorkflowArchiveRecord fromHeader(Workflow_Archive__b row) {
    WorkflowArchiveRecord r = new WorkflowArchiveRecord();
    r.instanceId = Id.valueOf(row.Instance_Id__c);
    r.workflowName = row.Workflow_Name__c;
    r.correlationKey = row.Correlation_Key__c;
    r.status = row.Status__c;
    r.errorMessage = row.Error_Message__c;
    r.failureCategory = row.Failure_Category__c;
    r.parentInstanceId = String.isBlank(row.Parent_Instance_Id__c)
      ? null
      : Id.valueOf(row.Parent_Instance_Id__c);
    r.createdAt = row.Created_At__c;
    r.terminalAt = row.Ended_At__c;
    r.archivedAt = row.Archived_At__c;
    r.input = row.Input__c;
    r.output = row.Output__c;
    r.droppedPayloadCount = toInt(row.Dropped_Payload_Count__c);
    r.stepCount = toInt(row.Step_Count__c);
    return r;
  }

  private static WorkflowArchiveRecord.Step fromStepRow(
    Workflow_Archive__b row
  ) {
    WorkflowArchiveRecord.Step s = new WorkflowArchiveRecord.Step();
    s.sequence = row.Sequence__c.intValue();
    s.executionId = String.isBlank(row.Execution_Id__c)
      ? null
      : Id.valueOf(row.Execution_Id__c);
    s.stepName = row.Step_Name__c;
    s.status = row.Status__c;
    s.attempt = toInt(row.Attempt__c);
    s.startedAt = row.Created_At__c;
    s.endedAt = row.Ended_At__c;
    s.errorDetails = row.Error_Details__c;
    return s;
  }

  private static Integer toInt(Decimal value) {
    return value == null ? 0 : value.intValue();
  }
}
