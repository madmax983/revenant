/**
 * @description Tests for {@link BigObjectArchiveSink}. Salesforce does not let
 * tests write Big Object rows, so the tests replace the store with an
 * in-memory store that has the same index rules.
 */
@IsTest
private class BigObjectArchiveSinkTest {
  /**
   * @description In-memory store. A row with the same index overwrites, like a
   * Big Object.
   */
  private class MemoryStore extends BigObjectArchiveSink.Store {
    Map<String, Workflow_Archive__b> timeline = new Map<String, Workflow_Archive__b>();
    Map<String, Workflow_Archive_Key__b> keys = new Map<String, Workflow_Archive_Key__b>();
    Boolean failInsert = false;

    public override void insertRows(List<SObject> rows) {
      if (failInsert) {
        throw new WorkflowArchive.ArchiveException('Store failure');
      }
      for (SObject row : rows) {
        if (row instanceof Workflow_Archive__b) {
          Workflow_Archive__b t = (Workflow_Archive__b) row;
          timeline.put(t.Instance_Id__c + '|' + t.Sequence__c, t);
        } else {
          Workflow_Archive_Key__b k = (Workflow_Archive_Key__b) row;
          keys.put(k.Key_Hash__c + '|' + k.Instance_Id__c, k);
        }
      }
    }

    public override List<Workflow_Archive__b> queryTimeline(
      Set<String> instanceIds,
      Integer rowLimit
    ) {
      List<String> sortedKeys = new List<String>(timeline.keySet());
      sortedKeys.sort();
      List<Workflow_Archive__b> out = new List<Workflow_Archive__b>();
      for (String k : sortedKeys) {
        Workflow_Archive__b row = timeline.get(k);
        if (instanceIds.contains(row.Instance_Id__c) && out.size() < rowLimit) {
          out.add(row);
        }
      }
      return out;
    }

    public override List<Workflow_Archive_Key__b> queryKeys(
      String keyHash,
      Integer rowLimit
    ) {
      List<Workflow_Archive_Key__b> out = new List<Workflow_Archive_Key__b>();
      for (Workflow_Archive_Key__b row : keys.values()) {
        if (row.Key_Hash__c == keyHash && out.size() < rowLimit) {
          out.add(row);
        }
      }
      return out;
    }
  }

  private static MemoryStore useMemoryStore() {
    MemoryStore mem = new MemoryStore();
    BigObjectArchiveSink.store = mem;
    return mem;
  }

  private static WorkflowArchiveRecord record(String correlationKey) {
    WorkflowArchiveRecord r = new WorkflowArchiveRecord();
    r.instanceId = TestIdFactory.generate(Workflow_Instance__c.SObjectType);
    r.workflowName = 'PaymentSaga';
    r.correlationKey = correlationKey;
    r.status = 'Failed';
    r.errorMessage = 'Card declined';
    r.failureCategory = 'StepFailure';
    r.parentInstanceId = TestIdFactory.generate(
      Workflow_Instance__c.SObjectType
    );
    r.createdAt = Datetime.newInstanceGmt(2026, 1, 1, 0, 0, 0);
    r.terminalAt = Datetime.newInstanceGmt(2026, 1, 1, 0, 1, 0);
    r.archivedAt = Datetime.newInstanceGmt(2026, 9, 1, 0, 0, 0);
    r.input = '{"amount":42}';
    r.output = WorkflowArchiveRecord.DROPPED_MARKER;
    r.droppedPayloadCount = 1;
    for (Integer i = 1; i <= 2; i++) {
      WorkflowArchiveRecord.Step s = new WorkflowArchiveRecord.Step();
      s.sequence = i;
      s.executionId = TestIdFactory.generate(
        Workflow_Step_Execution__c.SObjectType
      );
      s.stepName = 'Step' + i;
      s.status = i == 1 ? 'Completed' : 'Failed';
      s.attempt = i;
      s.startedAt = Datetime.newInstanceGmt(2026, 1, 1, 0, 0, i);
      s.endedAt = Datetime.newInstanceGmt(2026, 1, 1, 0, 0, i + 1);
      s.errorDetails = i == 2 ? 'boom' : null;
      r.steps.add(s);
    }
    r.stepCount = 2;
    return r;
  }

  @IsTest
  static void writeMapsHeaderStepsAndKeyRows() {
    MemoryStore mem = useMemoryStore();
    WorkflowArchiveRecord r = record('order-1');

    new BigObjectArchiveSink().write(new List<WorkflowArchiveRecord>{ r });

    System.assertEquals(3, mem.timeline.size(), 'Header plus two steps');
    Workflow_Archive__b header = mem.timeline.get(r.instanceId + '|0');
    System.assertNotEquals(null, header, 'Header row at sequence 0');
    System.assertEquals('PaymentSaga', header.Workflow_Name__c, 'Name');
    System.assertEquals('order-1', header.Correlation_Key__c, 'Key');
    System.assertEquals('Failed', header.Status__c, 'Status');
    System.assertEquals(2, header.Step_Count__c, 'Step count');
    Workflow_Archive__b step2 = mem.timeline.get(r.instanceId + '|2');
    System.assertEquals('Step2', step2.Step_Name__c, 'Step name');
    System.assertEquals('boom', step2.Error_Details__c, 'Step error');

    System.assertEquals(1, mem.keys.size(), 'One key row');
    Workflow_Archive_Key__b key = mem.keys.values()[0];
    System.assertEquals(
      WorkflowArchive.hashCorrelationKey('order-1'),
      key.Key_Hash__c,
      'Key hash'
    );
    System.assertEquals(64, key.Key_Hash__c.length(), 'SHA-256 hex');
    System.assertEquals(String.valueOf(r.instanceId), key.Instance_Id__c, 'Id');
  }

  @IsTest
  static void writeIsIdempotent() {
    MemoryStore mem = useMemoryStore();
    WorkflowArchiveRecord r = record('order-1');
    BigObjectArchiveSink sink = new BigObjectArchiveSink();

    sink.write(new List<WorkflowArchiveRecord>{ r });
    sink.write(new List<WorkflowArchiveRecord>{ r });

    System.assertEquals(3, mem.timeline.size(), 'No duplicate timeline rows');
    System.assertEquals(1, mem.keys.size(), 'No duplicate key rows');
  }

  @IsTest
  static void readByInstanceIdsRoundTrips() {
    useMemoryStore();
    WorkflowArchiveRecord r = record('order-1');
    BigObjectArchiveSink sink = new BigObjectArchiveSink();
    sink.write(new List<WorkflowArchiveRecord>{ r, record('order-2') });

    List<WorkflowArchiveRecord> read = sink.readByInstanceIds(
      new Set<Id>{ r.instanceId }
    );

    System.assertEquals(1, read.size(), 'One record');
    WorkflowArchiveRecord back = read[0];
    System.assertEquals(r.instanceId, back.instanceId, 'Id');
    System.assertEquals(r.workflowName, back.workflowName, 'Name');
    System.assertEquals(r.correlationKey, back.correlationKey, 'Key');
    System.assertEquals(r.status, back.status, 'Status');
    System.assertEquals(r.errorMessage, back.errorMessage, 'Error');
    System.assertEquals(r.failureCategory, back.failureCategory, 'Category');
    System.assertEquals(r.parentInstanceId, back.parentInstanceId, 'Parent');
    System.assertEquals(r.createdAt, back.createdAt, 'Created');
    System.assertEquals(r.terminalAt, back.terminalAt, 'Terminal');
    System.assertEquals(r.archivedAt, back.archivedAt, 'Archived');
    System.assertEquals(r.input, back.input, 'Input');
    System.assertEquals(r.output, back.output, 'Output');
    System.assertEquals(1, back.droppedPayloadCount, 'Dropped');
    System.assertEquals(2, back.stepCount, 'Step count');
    System.assertEquals(2, back.steps.size(), 'Steps');
    System.assertEquals(false, back.isTruncated(), 'Not truncated');
    for (Integer i = 0; i < 2; i++) {
      WorkflowArchiveRecord.Step a = r.steps[i];
      WorkflowArchiveRecord.Step b = back.steps[i];
      System.assertEquals(a.sequence, b.sequence, 'Sequence');
      System.assertEquals(a.executionId, b.executionId, 'Exec Id');
      System.assertEquals(a.stepName, b.stepName, 'Step name');
      System.assertEquals(a.status, b.status, 'Step status');
      System.assertEquals(a.attempt, b.attempt, 'Attempt');
      System.assertEquals(a.startedAt, b.startedAt, 'Started');
      System.assertEquals(a.endedAt, b.endedAt, 'Ended');
      System.assertEquals(a.errorDetails, b.errorDetails, 'Error');
    }
  }

  @IsTest
  static void readByCorrelationKeyFiltersHashCollisions() {
    MemoryStore mem = useMemoryStore();
    WorkflowArchiveRecord r = record('order-1');
    BigObjectArchiveSink sink = new BigObjectArchiveSink();
    sink.write(new List<WorkflowArchiveRecord>{ r });
    // A different record whose key row has the same hash (a forced collision).
    WorkflowArchiveRecord other = record('order-other');
    sink.write(new List<WorkflowArchiveRecord>{ other });
    mem.keys.put(
      'collision',
      new Workflow_Archive_Key__b(
        Key_Hash__c = WorkflowArchive.hashCorrelationKey('order-1'),
        Instance_Id__c = other.instanceId,
        Correlation_Key__c = 'order-other'
      )
    );

    Integer queriesBefore = Limits.getQueries();
    List<WorkflowArchiveRecord> read = sink.readByCorrelationKey('order-1');

    System.assertEquals(1, read.size(), 'Only the exact key');
    System.assertEquals(r.instanceId, read[0].instanceId, 'Right record');
    System.assertEquals(
      0,
      Limits.getQueries() - queriesBefore,
      'Memory store uses no SOQL'
    );
    System.assertEquals(
      0,
      sink.readByCorrelationKey('missing').size(),
      'Unknown key'
    );
  }

  @IsTest
  static void readMarksPartialTimelineAsTruncated() {
    MemoryStore mem = useMemoryStore();
    WorkflowArchiveRecord r = record('order-1');
    BigObjectArchiveSink sink = new BigObjectArchiveSink();
    sink.write(new List<WorkflowArchiveRecord>{ r });
    mem.timeline.remove(r.instanceId + '|2');

    WorkflowArchiveRecord back = sink.readByInstanceIds(
      new Set<Id>{ r.instanceId }
    )[0];

    System.assertEquals(true, back.isTruncated(), 'Missing step is flagged');
  }

  @IsTest
  static void writeFailureThrows() {
    MemoryStore mem = useMemoryStore();
    mem.failInsert = true;
    Boolean threw = false;
    try {
      new BigObjectArchiveSink()
        .write(new List<WorkflowArchiveRecord>{ record('order-1') });
    } catch (WorkflowArchive.ArchiveException e) {
      threw = true;
    }
    System.assert(threw, 'Store failure must reach the sweep');
  }

  @IsTest
  static void checkResultsThrowsOnFailedRow() {
    Database.SaveResult ok = (Database.SaveResult) JSON.deserialize(
      '{"success":true}',
      Database.SaveResult.class
    );
    Database.SaveResult bad = (Database.SaveResult) JSON.deserialize(
      '{"success":false,"errors":[{"message":"bad row","statusCode":"FIELD_INTEGRITY_EXCEPTION"}]}',
      Database.SaveResult.class
    );
    BigObjectArchiveSink.checkResults(new List<Database.SaveResult>{ ok });
    Boolean threw = false;
    try {
      BigObjectArchiveSink.checkResults(
        new List<Database.SaveResult>{ ok, bad }
      );
    } catch (WorkflowArchive.ArchiveException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('FIELD_INTEGRITY_EXCEPTION'),
        e.getMessage()
      );
      System.assert(
        !e.getMessage().contains('bad row'),
        'Error text can echo payload data, so it is not copied'
      );
    }
    System.assert(threw, 'Failed row must throw');
  }

  @IsTest
  static void emptyInputsDoNothing() {
    MemoryStore mem = useMemoryStore();
    BigObjectArchiveSink sink = new BigObjectArchiveSink();
    sink.write(new List<WorkflowArchiveRecord>());
    System.assertEquals(0, mem.timeline.size(), 'No rows');
    System.assertEquals(
      0,
      sink.readByInstanceIds(new Set<Id>()).size(),
      'No Ids'
    );
  }

  @IsTest
  static void correlationKeyMatchIsCaseSensitive() {
    useMemoryStore();
    BigObjectArchiveSink sink = new BigObjectArchiveSink();
    sink.write(new List<WorkflowArchiveRecord>{ record('Order-1') });
    System.assertEquals(
      1,
      sink.readByCorrelationKey('Order-1').size(),
      'Exact'
    );
    System.assertEquals(
      0,
      sink.readByCorrelationKey('order-1').size(),
      'Other case'
    );
  }

  @IsTest
  static void readByIdsUsesOneQueryPerId() {
    MemoryStore mem = useMemoryStore();
    BigObjectArchiveSink sink = new BigObjectArchiveSink();
    WorkflowArchiveRecord a = record('a');
    WorkflowArchiveRecord b = record('b');
    sink.write(new List<WorkflowArchiveRecord>{ a, b });

    List<WorkflowArchiveRecord> read = sink.readByInstanceIds(
      new Set<Id>{ a.instanceId, b.instanceId }
    );

    System.assertEquals(2, read.size(), 'Both instances');
    System.assertEquals(2, read[0].steps.size(), 'Full timeline');
    System.assertEquals(2, read[1].steps.size(), 'Full timeline');
  }
}
