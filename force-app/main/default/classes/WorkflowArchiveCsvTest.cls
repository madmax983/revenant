/**
 * @description Tests for {@link WorkflowArchiveCsv}: the CSV form of an archive
 * record.
 */
@IsTest
private class WorkflowArchiveCsvTest {
  private static WorkflowArchiveRecord sampleRecord() {
    WorkflowArchiveRecord r = new WorkflowArchiveRecord();
    r.instanceId = TestIdFactory.generate(Workflow_Instance__c.SObjectType);
    r.workflowName = 'PaymentSaga';
    r.correlationKey = 'order,"42"\nline2';
    r.status = 'Compensated';
    r.errorMessage = null;
    r.failureCategory = 'StepFailure';
    r.parentInstanceId = null;
    r.createdAt = Datetime.newInstanceGmt(2026, 1, 2, 3, 4, 5);
    r.terminalAt = Datetime.newInstanceGmt(2026, 1, 2, 3, 5, 6);
    r.archivedAt = Datetime.newInstanceGmt(2026, 9, 1, 0, 0, 0);
    r.input = '{"a":"x,y"}';
    r.output = '';
    r.droppedPayloadCount = 1;
    WorkflowArchiveRecord.Step s = new WorkflowArchiveRecord.Step();
    s.sequence = 1;
    s.executionId = TestIdFactory.generate(
      Workflow_Step_Execution__c.SObjectType
    );
    s.stepName = 'Charge';
    s.status = 'Failed';
    s.attempt = 3;
    s.startedAt = Datetime.newInstanceGmt(2026, 1, 2, 3, 4, 5);
    s.endedAt = Datetime.newInstanceGmt(2026, 1, 2, 3, 4, 6);
    s.errorDetails = 'line1\r\nline2 "quoted"';
    r.steps.add(s);
    r.stepCount = 1;
    return r;
  }

  @IsTest
  static void roundTripKeepsEveryField() {
    WorkflowArchiveRecord r = sampleRecord();

    WorkflowArchiveRecord back = WorkflowArchiveCsv.fromCsv(
      WorkflowArchiveCsv.toCsv(r)
    );

    System.assertEquals(r.instanceId, back.instanceId, 'instanceId');
    System.assertEquals(r.workflowName, back.workflowName, 'workflowName');
    System.assertEquals(r.correlationKey, back.correlationKey, 'key');
    System.assertEquals(r.status, back.status, 'status');
    System.assertEquals(null, back.errorMessage, 'null stays null');
    System.assertEquals(r.failureCategory, back.failureCategory, 'category');
    System.assertEquals(null, back.parentInstanceId, 'parent');
    System.assertEquals(r.createdAt, back.createdAt, 'createdAt');
    System.assertEquals(r.terminalAt, back.terminalAt, 'terminalAt');
    System.assertEquals(r.archivedAt, back.archivedAt, 'archivedAt');
    System.assertEquals(r.input, back.input, 'input');
    System.assertEquals(null, back.output, 'blank reads as null');
    System.assertEquals(1, back.droppedPayloadCount, 'dropped');
    System.assertEquals(1, back.stepCount, 'stepCount');
    System.assertEquals(1, back.steps.size(), 'steps');
    WorkflowArchiveRecord.Step s = back.steps[0];
    System.assertEquals(1, s.sequence, 'sequence');
    System.assertEquals(r.steps[0].executionId, s.executionId, 'execId');
    System.assertEquals('Charge', s.stepName, 'stepName');
    System.assertEquals('Failed', s.status, 'step status');
    System.assertEquals(3, s.attempt, 'attempt');
    System.assertEquals(r.steps[0].startedAt, s.startedAt, 'startedAt');
    System.assertEquals(r.steps[0].endedAt, s.endedAt, 'endedAt');
    System.assertEquals(r.steps[0].errorDetails, s.errorDetails, 'error');
  }

  @IsTest
  static void csvHasHeaderAndOneRowPerLine() {
    String csv = WorkflowArchiveCsv.toCsv(sampleRecord());
    System.assert(
      csv.startsWith(WorkflowArchiveCsv.HEADER),
      'First line is the header'
    );
    List<List<String>> rows = WorkflowArchiveCsv.parse(csv);
    System.assertEquals(3, rows.size(), 'Header, instance row, step row');
    System.assertEquals('instance', rows[1][0], 'Instance row type');
    System.assertEquals('step', rows[2][0], 'Step row type');
  }

  @IsTest
  static void parseHandlesQuotesCommasAndNewlines() {
    List<List<String>> rows = WorkflowArchiveCsv.parse(
      'a,"b,c","d""e","f\ng"\r\n1,,3,\n'
    );
    System.assertEquals(2, rows.size(), 'Two rows');
    System.assertEquals(
      new List<String>{ 'a', 'b,c', 'd"e', 'f\ng' },
      rows[0],
      'Quoted fields'
    );
    System.assertEquals(
      new List<String>{ '1', '', '3', '' },
      rows[1],
      'Empty fields'
    );
  }

  @IsTest
  static void fromCsvRejectsBadInput() {
    String badId =
      WorkflowArchiveCsv.HEADER +
      '\ninstance,0,secret-payload' +
      ','.repeat(16) +
      '\n';
    for (String bad : new List<String>{ null, '', 'x,y\n', 'a,"open', badId }) {
      Boolean threw = false;
      try {
        WorkflowArchiveCsv.fromCsv(bad);
      } catch (WorkflowArchive.ArchiveException e) {
        threw = true;
        System.assert(
          !e.getMessage().contains('secret-payload'),
          'The error must not echo the bad value'
        );
      }
      System.assert(threw, 'Bad CSV must throw: ' + bad);
    }
  }

  @IsTest
  static void formulaLikeValuesArePrefixedAndRoundTrip() {
    WorkflowArchiveRecord r = sampleRecord();
    r.workflowName = '=HYPERLINK("x")';
    r.status = '-1';
    r.errorMessage = '\'quoted';
    r.input = '@SUM(A1)';

    String csv = WorkflowArchiveCsv.toCsv(r);
    List<String> row = WorkflowArchiveCsv.parse(csv)[1];
    System.assertEquals('\'=HYPERLINK("x")', row[4], 'Formula prefixed');
    System.assertEquals('\'-1', row[6], 'Minus prefixed');

    WorkflowArchiveRecord back = WorkflowArchiveCsv.fromCsv(csv);
    System.assertEquals(r.workflowName, back.workflowName, 'Round trip =');
    System.assertEquals(r.status, back.status, 'Round trip -');
    System.assertEquals(r.errorMessage, back.errorMessage, 'Round trip quote');
    System.assertEquals(r.input, back.input, 'Round trip @');
  }
}
