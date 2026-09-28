/**
 * @description Tests for {@link WorkflowArchiveSnapshot}: the read-only copy of
 * primary rows into archive records.
 */
@IsTest
private class WorkflowArchiveSnapshotTest {
  @IsTest
  static void buildCopiesOutcomeAndTimelineLikeGetHistory() {
    Workflow_Instance__c parent = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'parent-1',
      40
    );
    Workflow_Instance__c inst = WorkflowArchiveTestSink.insertInstance(
      'Failed',
      'order-1',
      40
    );
    inst.Parent_Instance__c = parent.Id;
    inst.Failure_Category__c = 'STEP_EXCEPTION';
    update inst;
    List<Workflow_Step_Execution__c> steps = WorkflowArchiveTestSink.insertSteps(
      inst.Id,
      new List<String>{ 'ChargeCard', 'ChargeCard_Compensate' }
    );
    steps[0].Status__c = 'Failed';
    steps[0].Retry_Count__c = 2;
    steps[0].Error_Details__c = 'Stack trace';
    update steps[0];

    WorkflowEngine.StepHistory live = WorkflowHistoryRead.getHistory(inst.Id);

    Test.startTest();
    List<WorkflowArchiveRecord> records = WorkflowArchiveSnapshot.build(
      new Set<Id>{ inst.Id }
    );
    Test.stopTest();

    System.assertEquals(1, records.size(), 'One record per instance');
    WorkflowArchiveRecord r = records[0];
    System.assertEquals(inst.Id, r.instanceId, 'Instance Id');
    System.assertEquals('order-1', r.correlationKey, 'Correlation key');
    System.assertEquals(
      'WorkflowEngineTest.HappyWorkflow',
      r.workflowName,
      'Workflow name'
    );
    System.assertEquals('STEP_EXCEPTION', r.failureCategory, 'Category');
    System.assertEquals(parent.Id, r.parentInstanceId, 'Parent');
    Workflow_Instance__c stored = [
      SELECT CreatedDate, Terminal_At__c
      FROM Workflow_Instance__c
      WHERE Id = :inst.Id
    ];
    System.assertEquals(stored.CreatedDate, r.createdAt, 'Created time');
    System.assertEquals(stored.Terminal_At__c, r.terminalAt, 'Terminal time');
    System.assertEquals('Failed', r.status, 'Status');
    System.assertEquals('Card declined', r.errorMessage, 'Error message');
    System.assertEquals('{"amount":42}', r.input, 'Input stored form');
    System.assertEquals('{"chargeId":"ch_1"}', r.output, 'Output stored form');
    System.assertNotEquals(null, r.archivedAt, 'Archive time');
    System.assertEquals(2, r.stepCount, 'Step count');
    System.assertEquals(0, r.droppedPayloadCount, 'Nothing dropped');

    System.assertEquals(live.entries.size(), r.steps.size(), 'Same steps');
    for (Integer i = 0; i < live.entries.size(); i++) {
      WorkflowEngine.StepHistoryEntry e = live.entries[i];
      WorkflowArchiveRecord.Step s = r.steps[i];
      System.assertEquals(i + 1, s.sequence, 'Sequence starts at 1');
      System.assertEquals(e.executionId, s.executionId, 'Execution Id');
      System.assertEquals(e.stepName, s.stepName, 'Step name');
      System.assertEquals(e.status, s.status, 'Step status');
      System.assertEquals(e.attempt, s.attempt, 'Attempt');
      System.assertEquals(e.startedAt, s.startedAt, 'Started at');
      System.assertEquals(e.endedAt, s.endedAt, 'Ended at');
      System.assertEquals(e.totalDurationMs, s.totalDurationMs(), 'Duration');
      System.assertEquals(e.isCompensation, s.isCompensation(), 'Comp flag');
    }
    System.assertEquals('Stack trace', r.steps[0].errorDetails, 'Error text');
    System.assertEquals(false, r.isTruncated(), 'Complete timeline');
  }

  @IsTest
  static void buildDoesNoDml() {
    Workflow_Instance__c inst = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'k',
      40
    );
    List<Workflow_Step_Execution__c> steps = WorkflowArchiveTestSink.insertSteps(
      inst.Id,
      new List<String>{ 'A' }
    );
    Datetime before = [
      SELECT LastModifiedDate
      FROM Workflow_Step_Execution__c
      WHERE Id = :steps[0].Id
    ]
    .LastModifiedDate;

    Test.startTest();
    Integer dmlBefore = Limits.getDmlStatements();
    WorkflowArchiveSnapshot.build(new Set<Id>{ inst.Id });
    Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
    Test.stopTest();

    System.assertEquals(0, dmlUsed, 'Snapshot must not do DML');
    System.assertEquals(
      before,
      [
        SELECT LastModifiedDate
        FROM Workflow_Step_Execution__c
        WHERE Id = :steps[0].Id
      ]
      .LastModifiedDate,
      'Step row must not change'
    );
  }

  @IsTest
  static void buildDropsOffloadedPayloadsWithMarker() {
    Workflow_Instance__c inst = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'k',
      40
    );
    inst.Output__c = '{"$attachmentId":"069000000000001AAA"}';
    update inst;
    List<Workflow_Step_Execution__c> steps = WorkflowArchiveTestSink.insertSteps(
      inst.Id,
      new List<String>{ 'A' }
    );
    steps[0].Error_Details__c = '{"$attachmentId":"069000000000002AAA"}';
    update steps[0];

    List<WorkflowArchiveRecord> records = WorkflowArchiveSnapshot.build(
      new Set<Id>{ inst.Id }
    );

    System.assertEquals(
      WorkflowArchiveRecord.DROPPED_MARKER,
      records[0].output,
      'Offloaded output becomes the marker'
    );
    System.assertEquals(
      WorkflowArchiveRecord.DROPPED_MARKER,
      records[0].steps[0].errorDetails,
      'Offloaded error becomes the marker'
    );
    System.assertEquals(
      '{"amount":42}',
      records[0].input,
      'Inline input is kept'
    );
    System.assertEquals(2, records[0].droppedPayloadCount, 'Two dropped');
  }

  @IsTest
  static void buildDropsOffloadedFailureDataButKeepsReason() {
    Workflow_Instance__c inst = WorkflowArchiveTestSink.insertInstance(
      'Failed',
      'k',
      40
    );
    List<Workflow_Step_Execution__c> steps = WorkflowArchiveTestSink.insertSteps(
      inst.Id,
      new List<String>{ 'A', 'B' }
    );
    steps[0]
      .Error_Details__c = 'Card declined\nfailureData: {"$attachmentId":"069000000000003AAA"}';
    steps[1].Error_Details__c = 'Plain error\nfailureData: {"code":7}';
    update steps;

    WorkflowArchiveRecord r = WorkflowArchiveSnapshot.build(
      new Set<Id>{ inst.Id }
    )[0];

    System.assertEquals(
      'Card declined\nfailureData: ' + WorkflowArchiveRecord.DROPPED_MARKER,
      r.steps[0].errorDetails,
      'Reason kept, offloaded data dropped'
    );
    System.assertEquals(
      'Plain error\nfailureData: {"code":7}',
      r.steps[1].errorDetails,
      'Inline failure data kept'
    );
    System.assertEquals(1, r.droppedPayloadCount, 'One drop counted');
  }

  @IsTest
  static void droppedMarkerKeepsErrorDetailsInsideTheField() {
    String sep = '\nfailureData: ';
    String marker = '{"$attachmentId":"069000000000004AAA"}';
    String full =
      'x'.repeat(131072 - sep.length() - marker.length()) +
      sep +
      marker;
    String replaced = WorkflowFailureDetails.replaceOffloadedData(
      full,
      WorkflowArchiveRecord.DROPPED_MARKER
    );
    System.assertEquals(131072, replaced.length(), 'Fits the field');
    System.assert(
      replaced.endsWith(sep + WorkflowArchiveRecord.DROPPED_MARKER),
      'Marker kept'
    );
    System.assertEquals(
      null,
      WorkflowFailureDetails.replaceOffloadedData('plain', 'm'),
      'No offloaded data'
    );
  }

  @IsTest
  static void buildReturnsEmptyForNoIds() {
    System.assertEquals(
      0,
      WorkflowArchiveSnapshot.build(new Set<Id>()).size(),
      'No Ids, no records'
    );
    System.assertEquals(
      0,
      WorkflowArchiveSnapshot.build(null).size(),
      'Null Ids, no records'
    );
  }

  @IsTest
  static void countStepsStopsAtCap() {
    Workflow_Instance__c inst = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'k',
      40
    );
    WorkflowArchiveTestSink.insertSteps(
      inst.Id,
      new List<String>{ 'A', 'B', 'C' }
    );
    System.assertEquals(
      3,
      WorkflowArchiveSnapshot.countSteps(inst.Id, 10),
      'All'
    );
    System.assertEquals(
      2,
      WorkflowArchiveSnapshot.countSteps(inst.Id, 2),
      'Cap'
    );
  }

  @IsTest
  static void errorDetailsLoadInChunksAndKeepOrder() {
    Workflow_Instance__c inst = WorkflowArchiveTestSink.insertInstance(
      'Failed',
      'k',
      40
    );
    List<String> names = new List<String>();
    for (Integer i = 0; i < WorkflowArchiveSnapshot.ERROR_CHUNK_ROWS + 3; i++) {
      names.add('S' + i);
    }
    List<Workflow_Step_Execution__c> steps = WorkflowArchiveTestSink.insertSteps(
      inst.Id,
      names
    );
    for (Integer i = 0; i < steps.size(); i++) {
      steps[i].Error_Details__c = 'error ' + i;
    }
    update steps;

    WorkflowArchiveRecord r = WorkflowArchiveSnapshot.build(
      new Set<Id>{ inst.Id }
    )[0];

    System.assertEquals(names.size(), r.steps.size(), 'All steps');
    for (Integer i = 0; i < r.steps.size(); i++) {
      System.assertEquals('S' + i, r.steps[i].stepName, 'Order');
      System.assertEquals('error ' + i, r.steps[i].errorDetails, 'Error text');
    }
  }

  @IsTest
  static void buildStopsAtHeapLimit() {
    Workflow_Instance__c inst = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'k',
      40
    );
    Boolean threw = false;
    try {
      WorkflowArchiveSnapshot.build(new Set<Id>{ inst.Id }, 1);
    } catch (WorkflowArchiveSnapshot.TooLargeException e) {
      threw = true;
    }
    System.assert(threw, 'A copy over the heap limit stops');
  }
}
