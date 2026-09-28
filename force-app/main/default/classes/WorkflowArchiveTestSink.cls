/**
 * @description In-memory {@link WorkflowArchiveSink} and test data helpers for
 * the archive tests. It keeps one record for each instance Id, so a second
 * write overwrites.
 */
@IsTest
public class WorkflowArchiveTestSink implements WorkflowArchiveSink {
  /** @description Archived records by instance Id. */
  public Map<Id, WorkflowArchiveRecord> store = new Map<Id, WorkflowArchiveRecord>();
  /** @description Number of `write` calls. */
  public Integer writeCalls = 0;
  /** @description When true, `write` throws and stores nothing. */
  public Boolean failWrites = false;
  /** @description DML statements used before the first `write` call. */
  public Integer dmlBeforeFirstWrite;
  /**
   * @description When true, `write` makes one HTTP callout first. A callout
   * after uncommitted DML throws, so it proves the sweep order. Set a mock.
   */
  public Boolean calloutOnWrite = false;

  /**
   * @description Stores the records, or throws when `failWrites` is true.
   * @param records the records to store
   */
  public void write(List<WorkflowArchiveRecord> records) {
    if (dmlBeforeFirstWrite == null) {
      dmlBeforeFirstWrite = Limits.getDmlStatements();
    }
    writeCalls++;
    if (calloutOnWrite) {
      HttpRequest req = new HttpRequest();
      req.setEndpoint('https://archive.example.com/put');
      req.setMethod('PUT');
      req.setBody(String.valueOf(records.size()));
      new Http().send(req);
    }
    if (failWrites) {
      throw new WorkflowArchive.ArchiveException('Test sink write failure');
    }
    for (WorkflowArchiveRecord r : records) {
      store.put(r.instanceId, r);
    }
  }

  /**
   * @description Reads records by instance Id.
   * @param instanceIds the instance Ids
   * @return the stored records
   */
  public List<WorkflowArchiveRecord> readByInstanceIds(Set<Id> instanceIds) {
    List<WorkflowArchiveRecord> out = new List<WorkflowArchiveRecord>();
    for (Id instanceId : instanceIds) {
      if (store.containsKey(instanceId)) {
        out.add(store.get(instanceId));
      }
    }
    return out;
  }

  /**
   * @description Reads records by exact correlation key.
   * @param correlationKey the correlation key
   * @return the matching records
   */
  public List<WorkflowArchiveRecord> readByCorrelationKey(
    String correlationKey
  ) {
    List<WorkflowArchiveRecord> out = new List<WorkflowArchiveRecord>();
    for (WorkflowArchiveRecord r : store.values()) {
      if (correlationKey.equalsIgnoreCase(r.correlationKey)) {
        out.add(r);
      }
    }
    return out;
  }

  /**
   * @description Inserts a terminal instance with an age in days.
   * @param status the instance status
   * @param correlationKey the correlation key
   * @param ageDays the age in days
   * @return the instance
   */
  public static Workflow_Instance__c insertInstance(
    String status,
    String correlationKey,
    Integer ageDays
  ) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = status,
      Correlation_Key__c = correlationKey,
      Input__c = '{"amount":42}',
      Output__c = '{"chargeId":"ch_1"}',
      Error_Message__c = status == 'Failed' ? 'Card declined' : null
    );
    insert inst;
    Test.setCreatedDate(inst.Id, Datetime.now().addDays(-ageDays));
    return inst;
  }

  /**
   * @description Inserts step rows for an instance, in order.
   * @param instanceId the instance Id
   * @param stepNames the step names, in execution order
   * @return the step rows
   */
  public static List<Workflow_Step_Execution__c> insertSteps(
    Id instanceId,
    List<String> stepNames
  ) {
    List<Workflow_Step_Execution__c> rows = new List<Workflow_Step_Execution__c>();
    for (String stepName : stepNames) {
      rows.add(
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = instanceId,
          Step_Name__c = stepName,
          Status__c = 'Completed',
          Retry_Count__c = 0
        )
      );
    }
    insert rows;
    return rows;
  }
}
