/**
 * @description Tests for the archive tier in {@link CleanupWorkflow}. With
 * archival on, cleanup archives before it purges. With archival off, it
 * purges as before.
 */
@IsTest
private class CleanupWorkflowArchiveTest {
  private static StepResult runCleanup() {
    StepContext ctx = new StepContextTestBuilder()
      .workflowName('CleanupWorkflow')
      .stepName('CleanupWorkflow.PurgeOldInstancesStep')
      .workflowInputJson('{"retentionDays":30}')
      .build();
    return new CleanupWorkflow.PurgeOldInstancesStep().execute(ctx);
  }

  private static Boolean exists(Id instanceId) {
    return [SELECT COUNT() FROM Workflow_Instance__c WHERE Id = :instanceId] >
      0;
  }

  @IsTest
  static void archivalOnArchivesBeforePurge() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    WorkflowArchive.configure(true, sink);
    Workflow_Instance__c done = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'order-1',
      40
    );
    WorkflowArchiveTestSink.insertSteps(done.Id, new List<String>{ 'A', 'B' });

    StepResult result = runCleanup();

    System.assertEquals(
      StepResult.ActionType.COMPLETE,
      result.directive().action,
      'Done'
    );
    System.assertEquals(false, exists(done.Id), 'Purged');
    System.assertEquals(2, sink.store.get(done.Id).steps.size(), 'Archived');
    CleanupWorkflow.PurgeState state = (CleanupWorkflow.PurgeState) JSON.deserialize(
      result.directive().outputJson,
      CleanupWorkflow.PurgeState.class
    );
    System.assertEquals(1, state.deletedCount, 'Count unchanged in meaning');
  }

  @IsTest
  static void archivalOnSinkFailureDeletesNothing() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    sink.failWrites = true;
    WorkflowArchive.configure(true, sink);
    Workflow_Instance__c done = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'order-1',
      40
    );

    Boolean threw = false;
    try {
      runCleanup();
    } catch (WorkflowArchive.ArchiveException e) {
      threw = true;
    }

    System.assert(threw, 'Sink failure fails the cleanup step');
    System.assertEquals(true, exists(done.Id), 'Nothing purged');
  }

  @IsTest
  static void archivalOffPurgesWithoutArchive() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    WorkflowArchive.configure(false, sink);
    Workflow_Instance__c done = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'order-1',
      40
    );

    runCleanup();

    System.assertEquals(false, exists(done.Id), 'Purged as before');
    System.assertEquals(0, sink.writeCalls, 'Sink not called');
  }
}
