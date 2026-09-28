/**
 * @description Tests for the {@link WorkflowArchive} facade: config, sink
 * selection and the operator read API.
 */
@IsTest
private class WorkflowArchiveTest {
  @IsTest
  static void archivalIsOffByDefault() {
    System.assertEquals(
      false,
      WorkflowArchive.isEnabled(),
      'Archival is opt-in'
    );
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
  static void archiveAfterDaysDefaultsTo30() {
    System.assertEquals(
      30,
      WorkflowArchive.archiveAfterDays(),
      'Default archive age'
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
