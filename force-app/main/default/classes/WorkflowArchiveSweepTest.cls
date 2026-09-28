/**
 * @description Tests for the bounds of {@link WorkflowArchiveSweep}: batch
 * size, step rows and skipped instances.
 */
@IsTest
private class WorkflowArchiveSweepTest {
  private static WorkflowArchiveSweep.Params params(Integer batchSize) {
    WorkflowArchiveSweep.Params p = new WorkflowArchiveSweep.Params();
    p.ageDays = 30;
    p.batchSize = batchSize;
    return p;
  }

  private static Boolean exists(Id instanceId) {
    return [SELECT COUNT() FROM Workflow_Instance__c WHERE Id = :instanceId] >
      0;
  }

  @IsTest
  static void instanceOverStepBoundIsSkippedAndKept() {
    WorkflowArchiveSweep.maxStepRows = 2;
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    Workflow_Instance__c big = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'big',
      50
    );
    WorkflowArchiveTestSink.insertSteps(
      big.Id,
      new List<String>{ 'A', 'B', 'C' }
    );
    Workflow_Instance__c small = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'small',
      40
    );
    WorkflowArchiveTestSink.insertSteps(small.Id, new List<String>{ 'A' });
    WorkflowArchiveSweep.Params p = params(20);

    WorkflowArchiveSweep.BatchResult first = WorkflowArchiveSweep.runBatch(
      p,
      sink
    );

    System.assertEquals(1, first.purgedCount, 'Small archived');
    System.assertEquals(
      new List<Id>{ big.Id },
      first.skippedInstanceIds,
      'Big is named'
    );
    System.assertEquals(false, first.hasMore, 'Both handled');
    System.assertEquals(small.Id, first.cursorId, 'Cursor after both');
    System.assertEquals(true, exists(big.Id), 'Big stays in primary');
    System.assertEquals(null, sink.store.get(big.Id), 'Big not archived');
    System.assertEquals(false, exists(small.Id), 'Small purged');
  }

  @IsTest
  static void stepBudgetCutsTheBatch() {
    WorkflowArchiveSweep.maxStepRows = 2;
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    Workflow_Instance__c a = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'a',
      50
    );
    WorkflowArchiveTestSink.insertSteps(a.Id, new List<String>{ 'A', 'B' });
    Workflow_Instance__c b = WorkflowArchiveTestSink.insertInstance(
      'Failed',
      'b',
      40
    );
    WorkflowArchiveTestSink.insertSteps(b.Id, new List<String>{ 'A' });

    WorkflowArchiveSweep.BatchResult result = WorkflowArchiveSweep.runBatch(
      params(20),
      sink
    );

    System.assertEquals(1, result.purgedCount, 'Budget holds one');
    System.assertEquals(true, result.hasMore, 'More remain');
    System.assertEquals(false, exists(a.Id), 'Oldest first');
    System.assertEquals(true, exists(b.Id), 'Next batch');
  }

  @IsTest
  static void archiveBatchIsClampedTo20() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    List<Workflow_Instance__c> rows = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < 21; i++) {
      rows.add(
        new Workflow_Instance__c(
          Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
          Status__c = 'Completed',
          Correlation_Key__c = 'k' + i
        )
      );
    }
    insert rows;
    for (Workflow_Instance__c inst : rows) {
      Test.setCreatedDate(inst.Id, Datetime.now().addDays(-40));
    }

    WorkflowArchiveSweep.BatchResult result = WorkflowArchiveSweep.runBatch(
      params(200),
      sink
    );

    System.assertEquals(
      WorkflowArchiveSweep.MAX_ARCHIVE_BATCH_SIZE,
      result.purgedCount,
      'At most 20 with archival'
    );
    System.assertEquals(true, result.hasMore, 'One remains');
    System.assertEquals(20, sink.store.size(), 'Archived what it purged');

    // All rows share one CreatedDate, so the cursor must order by Id too.
    WorkflowArchiveSweep.Params next = params(200);
    WorkflowArchiveSweep.resumeAt(
      next,
      result.cursorCreatedDate,
      result.cursorId
    );
    WorkflowArchiveSweep.BatchResult last = WorkflowArchiveSweep.runBatch(
      next,
      sink
    );
    System.assertEquals(1, last.purgedCount, 'The last one');
    System.assertEquals(21, sink.store.size(), 'All archived');
  }

  @IsTest
  static void continuedAsNewIsArchived() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    Workflow_Instance__c inst = WorkflowArchiveTestSink.insertInstance(
      'ContinuedAsNew',
      'can',
      40
    );

    WorkflowArchiveSweep.runBatch(params(20), sink);

    System.assertEquals(
      'ContinuedAsNew',
      sink.store.get(inst.Id).status,
      'Archived'
    );
  }

  @IsTest
  static void archiveWorkflowReportsSkipsAndCursor() {
    WorkflowArchiveSweep.maxStepRows = 1;
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    WorkflowArchive.configure(true, sink);
    Workflow_Instance__c big = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'big',
      40
    );
    WorkflowArchiveTestSink.insertSteps(big.Id, new List<String>{ 'A', 'B' });
    StepContext ctx = new StepContextTestBuilder()
      .workflowName('ArchiveWorkflow')
      .stepName('ArchiveWorkflow.ArchiveOldInstancesStep')
      .workflowInputJson('{"archiveAfterDays":30}')
      .build();

    StepResult result = new ArchiveWorkflow.ArchiveOldInstancesStep()
      .execute(ctx);

    System.assertEquals(
      StepResult.ActionType.COMPLETE,
      result.directive().action,
      'The skip is behind the cursor, so the run ends'
    );
    ArchiveWorkflow.ArchiveState state = (ArchiveWorkflow.ArchiveState) JSON.deserialize(
      result.directive().outputJson,
      ArchiveWorkflow.ArchiveState.class
    );
    System.assertEquals(
      new List<Id>{ big.Id },
      state.skippedInstanceIds,
      'Output names the skip'
    );
    System.assertEquals(big.Id, state.cursorId, 'Cursor moved past it');
    System.assertEquals(true, exists(big.Id), 'Kept in primary');
  }

  @IsTest
  static void skippedInstancesCannotBlockNewerOnes() {
    WorkflowArchiveSweep.maxStepRows = 1;
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    Workflow_Instance__c big = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'big',
      50
    );
    WorkflowArchiveTestSink.insertSteps(big.Id, new List<String>{ 'A', 'B' });
    Workflow_Instance__c small = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'small',
      40
    );
    // The report is already full, as after 2000 skips.
    List<Id> skipped = new List<Id>();
    for (Integer i = 0; i < WorkflowArchiveSweep.MAX_SKIPPED_IDS; i++) {
      skipped.add(TestIdFactory.generate(Workflow_Instance__c.SObjectType));
    }
    WorkflowArchiveSweep.Params p = params(1);

    WorkflowArchiveSweep.BatchResult first = WorkflowArchiveSweep.runBatch(
      p,
      sink
    );
    WorkflowArchiveSweep.reportSkips(first, skipped);
    WorkflowArchiveSweep.resumeAt(p, first.cursorCreatedDate, first.cursorId);
    WorkflowArchiveSweep.BatchResult second = WorkflowArchiveSweep.runBatch(
      p,
      sink
    );

    System.assertEquals(0, first.purgedCount, 'Big skipped');
    System.assertEquals(true, first.hasMore, 'Batch was full');
    System.assertEquals(
      WorkflowArchiveSweep.MAX_SKIPPED_IDS,
      skipped.size(),
      'Report stays capped'
    );
    System.assertEquals(1, second.purgedCount, 'Cursor reaches small');
    System.assertEquals(false, exists(small.Id), 'Small purged');
    System.assertEquals(true, exists(big.Id), 'Big kept');
  }

  @IsTest
  static void instanceOverHeapLimitIsSkippedAndKept() {
    WorkflowArchiveSweep.instanceHeapLimit = 1;
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    Workflow_Instance__c big = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'big',
      40
    );

    WorkflowArchiveSweep.BatchResult batch = WorkflowArchiveSweep.runBatch(
      params(20),
      sink
    );

    System.assertEquals(0, batch.purgedCount, 'Nothing purged');
    System.assertEquals(
      new List<Id>{ big.Id },
      batch.skippedInstanceIds,
      'Named as skipped'
    );
    System.assertEquals(true, exists(big.Id), 'Kept in primary');
    System.assertEquals(0, sink.writeCalls, 'Nothing written');
  }
}
