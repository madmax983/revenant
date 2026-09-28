/**
 * @description Tests for {@link ArchiveWorkflow}: archive before purge, in
 * bounded chunks.
 */
@IsTest
private class ArchiveWorkflowTest {
  private static StepResult runStep(String inputJson, String stateJson) {
    StepContext ctx = new StepContextTestBuilder()
      .workflowName('ArchiveWorkflow')
      .stepName('ArchiveWorkflow.ArchiveOldInstancesStep')
      .workflowInputJson(inputJson)
      .stepStateJson(stateJson)
      .build();
    return new ArchiveWorkflow.ArchiveOldInstancesStep().execute(ctx);
  }

  private static ArchiveWorkflow.ArchiveState stateOf(StepResult result) {
    String stateJson = result.directive().action == StepResult.ActionType.YIELD
      ? result.directive().stepStateJson
      : result.directive().outputJson;
    return (ArchiveWorkflow.ArchiveState) JSON.deserialize(
      stateJson,
      ArchiveWorkflow.ArchiveState.class
    );
  }

  private static Boolean exists(Id instanceId) {
    return [SELECT COUNT() FROM Workflow_Instance__c WHERE Id = :instanceId] >
      0;
  }

  @IsTest
  static void archivesThenPurgesOldTerminalInstances() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    WorkflowArchive.configure(true, sink);
    Workflow_Instance__c done = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'order-1',
      40
    );
    List<Workflow_Step_Execution__c> steps = WorkflowArchiveTestSink.insertSteps(
      done.Id,
      new List<String>{ 'Reserve', 'Charge' }
    );
    insert new Workflow_Signal__c(
      Workflow_Instance__c = done.Id,
      Signal_Name__c = 'Paid',
      Status__c = 'Consumed'
    );
    Workflow_Instance__c failed = WorkflowArchiveTestSink.insertInstance(
      'Failed',
      'order-2',
      35
    );
    Workflow_Instance__c recent = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'order-3',
      5
    );
    Workflow_Instance__c running = WorkflowArchiveTestSink.insertInstance(
      'Running',
      'order-4',
      40
    );

    Test.startTest();
    Integer dmlAtStart = Limits.getDmlStatements();
    StepResult result = runStep('{"archiveAfterDays":30}', null);
    Test.stopTest();

    System.assertEquals(
      StepResult.ActionType.COMPLETE,
      result.directive().action,
      'One chunk is enough'
    );
    System.assertEquals(2, stateOf(result).archivedCount, 'Two archived');
    System.assertEquals(
      dmlAtStart,
      sink.dmlBeforeFirstWrite,
      'No DML before write, so a sink can call out'
    );

    WorkflowArchiveRecord r = WorkflowArchive.getArchivedHistory(done.Id);
    System.assertNotEquals(null, r, 'Archived record is readable');
    System.assertEquals(2, r.steps.size(), 'Timeline archived');
    System.assertEquals(steps[0].Id, r.steps[0].executionId, 'Order kept');
    System.assertEquals('Charge', r.steps[1].stepName, 'Second step');
    System.assertEquals(
      1,
      WorkflowArchive.findArchivedHistory('order-2').size(),
      'Read by correlation key'
    );

    System.assertEquals(false, exists(done.Id), 'Archived row purged');
    System.assertEquals(false, exists(failed.Id), 'Archived row purged');
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :done.Id
      ],
      'Step rows purged'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Workflow_Signal__c WHERE Signal_Name__c = 'Paid'],
      'Signals purged'
    );
    System.assertEquals(true, exists(recent.Id), 'Recent row kept');
    System.assertEquals(true, exists(running.Id), 'Running row kept');
    System.assertEquals(null, sink.store.get(recent.Id), 'Recent not archived');
  }

  @IsTest
  static void sinkFailureDeletesNothing() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    sink.failWrites = true;
    WorkflowArchive.configure(true, sink);
    Workflow_Instance__c done = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'order-1',
      40
    );
    WorkflowArchiveTestSink.insertSteps(done.Id, new List<String>{ 'A' });

    Boolean threw = false;
    try {
      runStep('{"archiveAfterDays":30}', null);
    } catch (WorkflowArchive.ArchiveException e) {
      threw = true;
    }

    System.assert(threw, 'Sink failure fails the step');
    System.assertEquals(true, exists(done.Id), 'Nothing purged');
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :done.Id
      ],
      'Step rows kept'
    );
  }

  @IsTest
  static void yieldsAcrossBoundedChunks() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    WorkflowArchive.configure(true, sink);
    WorkflowArchiveTestSink.insertInstance('Completed', 'a', 40);
    WorkflowArchiveTestSink.insertInstance('Cancelled', 'b', 40);

    StepResult first = runStep('{"archiveAfterDays":30,"batchSize":1}', null);
    System.assertEquals(
      StepResult.ActionType.YIELD,
      first.directive().action,
      'More remain after chunk 1'
    );
    System.assertEquals(1, stateOf(first).archivedCount, 'Chunk 1 count');

    StepResult second = runStep(
      '{"archiveAfterDays":30,"batchSize":1}',
      first.directive().stepStateJson
    );
    StepResult third = runStep(
      '{"archiveAfterDays":30,"batchSize":1}',
      second.directive().stepStateJson
    );

    System.assertEquals(
      StepResult.ActionType.COMPLETE,
      third.directive().action,
      'Done after the last chunk'
    );
    System.assertEquals(2, stateOf(third).archivedCount, 'Total count');
    System.assertEquals(2, sink.store.size(), 'Both archived');
  }

  @IsTest
  static void rerunDoesNotDuplicate() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    WorkflowArchive.configure(true, sink);
    Workflow_Instance__c done = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'a',
      40
    );
    // An earlier run archived it, then failed before the purge.
    sink.write(WorkflowArchiveSnapshot.build(new Set<Id>{ done.Id }));

    StepResult result = runStep('{"archiveAfterDays":30}', null);
    StepResult again = runStep('{"archiveAfterDays":30}', null);

    System.assertEquals(1, sink.store.size(), 'One archive record');
    System.assertEquals(1, stateOf(result).archivedCount, 'Purged once');
    System.assertEquals(0, stateOf(again).archivedCount, 'Nothing left');
    System.assertEquals(false, exists(done.Id), 'Purged');
  }

  @IsTest
  static void disabledArchivalDoesNothing() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    WorkflowArchive.configure(false, sink);
    Workflow_Instance__c done = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'a',
      40
    );

    StepResult result = runStep('{"archiveAfterDays":30}', null);

    System.assertEquals(
      StepResult.ActionType.COMPLETE,
      result.directive().action,
      'Completes at once'
    );
    System.assertEquals(true, stateOf(result).archivalDisabled, 'Flagged');
    System.assertEquals(0, sink.writeCalls, 'No write');
    System.assertEquals(true, exists(done.Id), 'No purge');
  }

  @IsTest
  static void offloadedFileIsDroppedWithMarker() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    WorkflowArchive.configure(true, sink);
    Workflow_Instance__c done = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'a',
      40
    );
    ContentVersion cv = new ContentVersion(
      Title = 'Output_' + done.Id,
      PathOnClient = 'Output.json',
      VersionData = Blob.valueOf('{"big":true}')
    );
    insert cv;
    Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      ContentDocumentId = docId,
      LinkedEntityId = done.Id,
      ShareType = 'V',
      Visibility = 'AllUsers'
    );
    done.Output__c = '{"$attachmentId":"' + docId + '"}';
    update done;

    runStep('{"archiveAfterDays":30}', null);

    WorkflowArchiveRecord r = sink.store.get(done.Id);
    System.assertEquals(
      WorkflowArchiveRecord.DROPPED_MARKER,
      r.output,
      'Marker recorded'
    );
    System.assertEquals(1, r.droppedPayloadCount, 'Drop counted');
    System.assertEquals(
      0,
      [SELECT COUNT() FROM ContentDocument WHERE Id = :docId],
      'Engine file purged, as cleanup does'
    );
  }

  @IsTest
  static void defaultAgeComesFromConfig() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    WorkflowArchive.configure(true, sink);
    Workflow_Instance__c old = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'old',
      40
    );
    Workflow_Instance__c young = WorkflowArchiveTestSink.insertInstance(
      'Completed',
      'young',
      5
    );

    runStep(null, null);

    System.assertEquals(false, exists(old.Id), 'Older than 30 days');
    System.assertEquals(true, exists(young.Id), 'Younger than 30 days');
  }

  @IsTest
  static void badInputThrows() {
    WorkflowArchive.configure(true, new WorkflowArchiveTestSink());
    for (
      String bad : new List<String>{
        '{"archiveAfterDays":-1}',
        '{"batchSize":0}',
        '{"batchSize":"many"}',
        '{not json'
      }
    ) {
      Boolean threw = false;
      try {
        runStep(bad, null);
      } catch (WorkflowEngine.WorkflowException e) {
        threw = true;
      }
      System.assert(threw, 'Bad input must throw: ' + bad);
    }
  }

  @IsTest
  static void runsEndToEndThroughTheEngine() {
    WorkflowArchiveTestSink sink = new WorkflowArchiveTestSink();
    WorkflowArchive.configure(true, sink);
    Workflow_Instance__c done = WorkflowArchiveTestSink.insertInstance(
      'Compensated',
      'saga-1',
      40
    );
    WorkflowArchiveTestSink.insertSteps(
      done.Id,
      new List<String>{ 'Charge', 'Charge_Compensate' }
    );

    Test.startTest();
    Id runId = WorkflowEngine.start(
      'ArchiveWorkflow',
      'Archive_Run_1',
      new Map<String, Object>{ 'archiveAfterDays' => 30 }
    );
    Test.stopTest();

    Workflow_Instance__c run = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :runId
    ];
    System.assertEquals('Completed', run.Status__c, 'Sweep completed');
    System.assertEquals(false, exists(done.Id), 'Purged');
    WorkflowArchiveRecord r = sink.store.get(done.Id);
    System.assertEquals('Compensated', r.status, 'Outcome archived');
    System.assertEquals(true, r.steps[1].isCompensation(), 'Comp step');
  }

  @IsTest
  static void archiveWorkflowIsEngineInternal() {
    System.assertEquals(
      true,
      WorkflowPauseGate.isReserved('ArchiveWorkflow'),
      'The pause gate must not park the archive sweep'
    );
    ArchiveWorkflow def = new ArchiveWorkflow();
    System.assertEquals(
      'ArchiveWorkflow.ArchiveOldInstancesStep',
      def.getInitialStep(),
      'Initial step'
    );
    System.assertEquals(1, def.getSteps().size(), 'Single step');
    System.assertEquals(
      null,
      def.getNextStep(def.getInitialStep(), null),
      'End'
    );
    System.assert(
      new ArchiveWorkflow.ArchiveOldInstancesStep() instanceof CalloutStep,
      'A callout sink needs a CalloutStep'
    );
  }
}
