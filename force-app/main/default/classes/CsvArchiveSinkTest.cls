/**
 * @description Tests for {@link CsvArchiveSink}: one CSV file for each archived
 * instance.
 */
@IsTest
private class CsvArchiveSinkTest {
  private static WorkflowArchiveRecord record(String correlationKey) {
    WorkflowArchiveRecord r = new WorkflowArchiveRecord();
    r.instanceId = TestIdFactory.generate(Workflow_Instance__c.SObjectType);
    r.workflowName = 'PaymentSaga';
    r.correlationKey = correlationKey;
    r.status = 'Completed';
    r.archivedAt = Datetime.now();
    WorkflowArchiveRecord.Step s = new WorkflowArchiveRecord.Step();
    s.sequence = 1;
    s.stepName = 'Charge';
    s.status = 'Completed';
    s.attempt = 0;
    r.steps.add(s);
    r.stepCount = 1;
    return r;
  }

  private static Integer archiveFileCount() {
    String pattern = CsvArchiveSink.TITLE_PREFIX + '%';
    return [
      SELECT COUNT()
      FROM ContentVersion
      WHERE Title LIKE :pattern AND IsLatest = TRUE
    ];
  }

  @IsTest
  static void writeStoresOneFilePerRecordAndReadsBack() {
    WorkflowArchiveRecord a = record('order-1');
    WorkflowArchiveRecord b = record('order-2');
    CsvArchiveSink sink = new CsvArchiveSink();

    Test.startTest();
    sink.write(new List<WorkflowArchiveRecord>{ a, b });
    Test.stopTest();

    System.assertEquals(2, archiveFileCount(), 'One file per record');
    List<WorkflowArchiveRecord> read = sink.readByInstanceIds(
      new Set<Id>{ a.instanceId }
    );
    System.assertEquals(1, read.size(), 'Read one by Id');
    System.assertEquals(a.instanceId, read[0].instanceId, 'Right record');
    System.assertEquals('Charge', read[0].steps[0].stepName, 'Timeline');
  }

  @IsTest
  static void writeIsIdempotent() {
    WorkflowArchiveRecord a = record('order-1');
    CsvArchiveSink sink = new CsvArchiveSink();

    sink.write(new List<WorkflowArchiveRecord>{ a });
    sink.write(new List<WorkflowArchiveRecord>{ a });

    System.assertEquals(1, archiveFileCount(), 'No duplicate file');
  }

  @IsTest
  static void writeDoesNotLinkFileToInstance() {
    Workflow_Instance__c inst = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'k',
      40
    );
    WorkflowArchiveRecord a = record('k');
    a.instanceId = inst.Id;

    new CsvArchiveSink().write(new List<WorkflowArchiveRecord>{ a });

    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM ContentDocumentLink
        WHERE LinkedEntityId = :inst.Id
      ],
      'Purge must not see the archive file'
    );
  }

  @IsTest
  static void readByCorrelationKeyMatchesExactKeyOnly() {
    WorkflowArchiveRecord exact = record('a_b%c');
    WorkflowArchiveRecord likeMatch = record('aXbYc');
    WorkflowArchiveRecord longKey = record('k'.repeat(250));
    CsvArchiveSink sink = new CsvArchiveSink();
    sink.write(new List<WorkflowArchiveRecord>{ exact, likeMatch, longKey });

    List<WorkflowArchiveRecord> read = sink.readByCorrelationKey('a_b%c');
    System.assertEquals(1, read.size(), 'Wildcards are escaped');
    System.assertEquals(exact.instanceId, read[0].instanceId, 'Exact key');

    read = sink.readByCorrelationKey('k'.repeat(250));
    System.assertEquals(1, read.size(), 'Long key found');
    System.assertEquals(longKey.instanceId, read[0].instanceId, 'Long key');

    System.assertEquals(
      0,
      sink.readByCorrelationKey('k'.repeat(249)).size(),
      'Prefix of a long key does not match'
    );
  }

  @IsTest
  static void plantedFileWithArchiveTitleIsNotTrusted() {
    WorkflowArchiveRecord a = record('order-1');
    // A user uploads a file with the archive title but without the mark.
    insert new ContentVersion(
      Title = CsvArchiveSink.titleFor(a.instanceId, a.correlationKey),
      PathOnClient = 'fake.csv',
      VersionData = Blob.valueOf('not an archive')
    );
    CsvArchiveSink sink = new CsvArchiveSink();

    sink.write(new List<WorkflowArchiveRecord>{ a });

    System.assertEquals(2, archiveFileCount(), 'Real archive still written');
    System.assertEquals(
      a.instanceId,
      sink.readByInstanceIds(new Set<Id>{ a.instanceId })[0].instanceId,
      'Read returns the real archive'
    );
    System.assertEquals(
      1,
      sink.readByCorrelationKey('order-1').size(),
      'Planted file is not read by key'
    );
  }

  @IsTest
  static void newVersionByUserDoesNotChangeArchive() {
    WorkflowArchiveRecord a = record('order-1');
    CsvArchiveSink sink = new CsvArchiveSink();
    sink.write(new List<WorkflowArchiveRecord>{ a });
    Id docId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Revenant_Archive_Instance_Id__c = :String.valueOf(a.instanceId)
    ]
    .ContentDocumentId;
    insert new ContentVersion(
      ContentDocumentId = docId,
      PathOnClient = 'edit.csv',
      VersionData = Blob.valueOf('tampered')
    );

    List<WorkflowArchiveRecord> read = sink.readByInstanceIds(
      new Set<Id>{ a.instanceId }
    );

    System.assertEquals(1, read.size(), 'Marked version is read');
    System.assertEquals('Charge', read[0].steps[0].stepName, 'Original');
  }

  @IsTest
  static void readUnknownReturnsEmpty() {
    CsvArchiveSink sink = new CsvArchiveSink();
    System.assertEquals(
      0,
      sink.readByInstanceIds(
          new Set<Id>{
            TestIdFactory.generate(Workflow_Instance__c.SObjectType)
          }
        )
        .size(),
      'Unknown Id'
    );
    System.assertEquals(
      0,
      sink.readByCorrelationKey('missing').size(),
      'Unknown key'
    );
  }

  @IsTest
  static void titleFitsTheFieldAndStartsWithTheId() {
    Id instanceId = TestIdFactory.generate(Workflow_Instance__c.SObjectType);
    String title = CsvArchiveSink.titleFor(instanceId, 'x'.repeat(300));
    System.assert(title.length() <= 255, 'Title fits 255 characters');
    System.assert(
      title.startsWith('WorkflowArchive_' + instanceId + '_'),
      'Title starts with the prefix and Id'
    );
  }

  @IsTest
  static void correlationKeyMatchIsCaseSensitive() {
    CsvArchiveSink sink = new CsvArchiveSink();
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
  static void readByIdsReturnsEveryArchivedId() {
    CsvArchiveSink sink = new CsvArchiveSink();
    List<WorkflowArchiveRecord> many = new List<WorkflowArchiveRecord>();
    Set<Id> ids = new Set<Id>();
    for (Integer i = 0; i < WorkflowArchive.MAX_READ_RECORDS + 2; i++) {
      WorkflowArchiveRecord r = record('k' + i);
      many.add(r);
      ids.add(r.instanceId);
    }
    sink.write(many);

    System.assertEquals(
      ids.size(),
      sink.readByInstanceIds(ids).size(),
      'No silent cut'
    );
  }

  @IsTest
  static void libraryIsOptional() {
    System.assertEquals(
      null,
      CsvArchiveSink.libraryId(),
      'A test org has no Revenant_Archive library'
    );
  }
}
