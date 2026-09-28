/**
 * @description Tests for the {@link WorkflowArchive} facade: config, sink
 * selection and the operator read API.
 */
@IsTest
private class WorkflowArchiveTest {
  private static Revenant_Config__mdt config(String fieldsJson) {
    return (Revenant_Config__mdt) JSON.deserialize(
      fieldsJson,
      Revenant_Config__mdt.class
    );
  }

  @IsTest
  static void archivalIsOffWithoutConfigValues() {
    WorkflowArchive.applyConfig(config('{}'));
    System.assertEquals(false, WorkflowArchive.isEnabled(), 'Opt-in');
    System.assertEquals(30, WorkflowArchive.archiveAfterDays(), 'Default age');
    System.assert(
      WorkflowArchive.sink() instanceof BigObjectArchiveSink,
      'Default sink'
    );
  }

  @IsTest
  static void missingDefaultRecordTurnsArchivalOff() {
    WorkflowArchive.applyConfig(null);
    System.assertEquals(false, WorkflowArchive.isEnabled(), 'No record');
  }

  @IsTest
  static void configValuesAreRead() {
    WorkflowArchive.applyConfig(
      config(
        '{"Archive_Enabled__c":true,"Archive_Sink__c":"CsvArchiveSink","Archive_After_Days__c":90}'
      )
    );
    System.assertEquals(true, WorkflowArchive.isEnabled(), 'Enabled');
    System.assertEquals(90, WorkflowArchive.archiveAfterDays(), 'Age');
    System.assert(
      WorkflowArchive.sink() instanceof CsvArchiveSink,
      'Configured sink'
    );
  }

  @IsTest
  static void negativeAgeUsesDefault() {
    WorkflowArchive.applyConfig(config('{"Archive_After_Days__c":-5}'));
    System.assertEquals(30, WorkflowArchive.archiveAfterDays(), 'Default');
  }

  @IsTest
  static void realConfigReadDoesNotThrow() {
    // Reads the org record. Only the type of the answer is checked, so an
    // org that turns archival on does not break this test.
    System.assertNotEquals(null, WorkflowArchive.isEnabled(), 'Answer');
  }

  @IsTest
  static void blankSinkNameSelectsBigObjectSink() {
    System.assert(
      WorkflowArchive.resolve(null) instanceof BigObjectArchiveSink,
      'Null selects the Big Object sink'
    );
    System.assert(
      WorkflowArchive.resolve('  ') instanceof BigObjectArchiveSink,
      'Blank selects the Big Object sink'
    );
    System.assert(
      WorkflowArchive.resolve('CsvArchiveSink') instanceof CsvArchiveSink,
      'Class name selects that sink'
    );
  }

  @IsTest
  static void badSinkNameThrows() {
    for (
      String bad : new List<String>{ 'NoSuchArchiveSinkClass', 'StepResult' }
    ) {
      Boolean threw = false;
      try {
        WorkflowArchive.resolve(bad);
      } catch (WorkflowArchive.ArchiveException e) {
        threw = true;
      }
      System.assert(threw, 'Bad sink name must throw: ' + bad);
    }
  }

  @IsTest
  static void configReadFailureFailsClosed() {
    WorkflowArchive.simulateConfigReadFailure();
    Boolean threw = false;
    try {
      WorkflowArchive.isEnabled();
    } catch (WorkflowArchive.ArchiveException e) {
      threw = true;
    }
    System.assert(threw, 'A config read failure must not read as off');
  }

  @IsTest
  static void hashIsStableAndCaseSensitive() {
    String h = WorkflowArchive.hashCorrelationKey('Order-1');
    System.assertEquals(64, h.length(), 'SHA-256 hex');
    System.assertEquals(
      h,
      WorkflowArchive.hashCorrelationKey('Order-1'),
      'Stable'
    );
    System.assertNotEquals(
      h,
      WorkflowArchive.hashCorrelationKey('order-1'),
      'Case matters'
    );
  }

  @IsTest
  static void readApiUsesConfiguredSink() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    WorkflowArchive.configure(true, sink);
    WorkflowArchiveRecord r = new WorkflowArchiveRecord();
    r.instanceId = TestIdFactory.generate(Workflow_Instance__c.SObjectType);
    r.correlationKey = 'order-1';
    sink.write(new List<WorkflowArchiveRecord>{ r });

    System.assertEquals(
      r,
      WorkflowArchive.getArchivedHistory(r.instanceId),
      'Read by Id'
    );
    System.assertEquals(
      1,
      WorkflowArchive.findArchivedHistory('order-1').size(),
      'Read by key'
    );
    System.assertEquals(
      null,
      WorkflowArchive.getArchivedHistory(
        TestIdFactory.generate(Workflow_Instance__c.SObjectType)
      ),
      'Unknown Id'
    );
  }

  @IsTest
  static void readApiWorksWhenArchivalIsOff() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    WorkflowArchive.configure(false, sink);
    WorkflowArchiveRecord r = new WorkflowArchiveRecord();
    r.instanceId = TestIdFactory.generate(Workflow_Instance__c.SObjectType);
    sink.write(new List<WorkflowArchiveRecord>{ r });

    System.assertEquals(
      r,
      WorkflowArchive.getArchivedHistory(r.instanceId),
      'Old archives stay readable'
    );
  }

  @IsTest
  static void readApiRejectsBlankInput() {
    WorkflowArchive.configure(true, new WorkflowArchiveTestSink());
    System.assertEquals(
      null,
      WorkflowArchive.getArchivedHistory(null),
      'Null Id'
    );
    System.assertEquals(
      0,
      WorkflowArchive.findArchivedHistory(' ').size(),
      'Blank key'
    );
  }

  @IsTest
  static void findCapsResults() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    WorkflowArchive.configure(true, sink);
    List<WorkflowArchiveRecord> many = new List<WorkflowArchiveRecord>();
    for (Integer i = 0; i < WorkflowArchive.MAX_READ_RECORDS + 5; i++) {
      WorkflowArchiveRecord r = new WorkflowArchiveRecord();
      r.instanceId = TestIdFactory.generate(Workflow_Instance__c.SObjectType);
      r.correlationKey = 'same';
      many.add(r);
    }
    sink.write(many);

    System.assertEquals(
      WorkflowArchive.MAX_READ_RECORDS,
      WorkflowArchive.findArchivedHistory('same').size(),
      'Result count is capped'
    );
  }
}
