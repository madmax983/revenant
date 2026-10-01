/**
 * @description Tests for the heap budget of the attachment reads (issue #261).
 * The detail view reads attachment bodies in chunks and keeps the display text.
 */
@IsTest
private class WorkflowPayloadBudgetTest {
  private static Workflow_Instance__c seed(Integer count, Integer size) {
    List<ContentVersion> versions = new List<ContentVersion>();
    for (Integer i = 0; i < count; i++) {
      versions.add(
        new ContentVersion(
          Title = 'Body' + i,
          PathOnClient = 'body' + i + '.json',
          VersionData = Blob.valueOf('X'.repeat(size))
        )
      );
    }
    insert versions;
    Set<Id> versionIds = new Map<Id, ContentVersion>(versions).keySet();
    List<Id> docIds = new List<Id>();
    for (ContentVersion cv : [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id IN :versionIds
      ORDER BY CreatedDate ASC, Id ASC
    ]) {
      docIds.add(cv.ContentDocumentId);
    }
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'Budget.Workflow',
      Status__c = 'Running'
    );
    insert inst;
    List<ContentDocumentLink> links = new List<ContentDocumentLink>();
    List<Workflow_Step_Execution__c> steps = new List<Workflow_Step_Execution__c>();
    for (Id docId : docIds) {
      links.add(
        new ContentDocumentLink(
          ContentDocumentId = docId,
          LinkedEntityId = inst.Id,
          ShareType = 'V'
        )
      );
      steps.add(
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = inst.Id,
          Step_Name__c = 'Big.Step',
          Status__c = 'Completed',
          Output__c = '{"$attachmentId":"' + docId + '"}'
        )
      );
    }
    insert links;
    insert steps;
    return inst;
  }

  private static Workflow_Instance__c seedAndLoad(Integer count, Integer size) {
    Id instanceId = seed(count, size).Id;
    return [
      SELECT Id, Input__c, Output__c, Progress__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
  }

  private static List<Workflow_Step_Execution__c> stepsOf(Id instanceId) {
    return [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId
    ];
  }

  @IsTest
  static void bodiesAreResolvedWithinTheBudget() {
    Workflow_Instance__c inst = seedAndLoad(3, 100);
    List<Workflow_Step_Execution__c> steps = stepsOf(inst.Id);

    WorkflowPayloadService.resolvePayloadsInBulk(inst, steps);

    for (Workflow_Step_Execution__c step : steps) {
      Assert.areEqual('X'.repeat(100), step.Output__c, 'The body is shown');
    }
  }

  @IsTest
  static void largeBodyShowsTheDisplayTextAndALink() {
    Workflow_Instance__c inst = seedAndLoad(1, 60000);
    List<Workflow_Step_Execution__c> steps = stepsOf(inst.Id);

    Map<String, Object> files = WorkflowPayloadService.resolvePayloadsInBulk(
      inst,
      steps
    );

    Assert.areEqual(
      50000 + '... (truncated)'.length(),
      steps[0].Output__c.length(),
      'The text is cut'
    );
    Map<String, Object> file = (Map<String, Object>) files.get(
      'step.' + steps[0].Id + '.Output'
    );
    Assert.areEqual(60000, file.get('fullLength'), 'The link has the length');
  }

  @IsTest
  static void readStopsAtTheHeapBudget() {
    Workflow_Instance__c inst = seedAndLoad(12, 100);
    List<Workflow_Step_Execution__c> steps = stepsOf(inst.Id);
    WorkflowPayloadService.attachmentHeapBudget = 1;

    WorkflowPayloadService.resolvePayloadsInBulk(inst, steps);

    Integer resolved = 0;
    for (Workflow_Step_Execution__c step : steps) {
      if (step.Output__c == 'X'.repeat(100)) {
        resolved++;
      } else {
        Assert.isTrue(
          step.Output__c.startsWith('{"$attachmentId":'),
          'An unread body shows its marker'
        );
      }
    }
    Assert.areEqual(5, resolved, 'One chunk is read');
  }

  @IsTest
  static void bodyAboveTheBatchSizeIsNotRead() {
    Workflow_Instance__c inst = seedAndLoad(3, 1000);
    List<Workflow_Step_Execution__c> steps = stepsOf(inst.Id);
    WorkflowPayloadService.attachmentBatchBytes = 999;

    WorkflowPayloadService.resolvePayloadsInBulk(inst, steps);

    for (Workflow_Step_Execution__c step : steps) {
      Assert.isTrue(
        step.Output__c.startsWith('{"$attachmentId":'),
        'A large body shows its marker'
      );
    }
  }

  @IsTest
  static void batchesHoldAtMostTheBatchBytes() {
    Workflow_Instance__c inst = seedAndLoad(4, 1000);
    List<Workflow_Step_Execution__c> steps = stepsOf(inst.Id);
    WorkflowPayloadService.attachmentBatchBytes = 2500;

    Integer before = Limits.getQueries();
    WorkflowPayloadService.resolvePayloadsInBulk(inst, steps);
    Integer used = Limits.getQueries() - before;

    for (Workflow_Step_Execution__c step : steps) {
      Assert.areEqual('X'.repeat(1000), step.Output__c, 'All are read');
    }
    // Links, sizes, and two batches of two bodies.
    Assert.areEqual(4, used, 'Two bodies in each batch');
  }

  @IsTest
  static void readStopsWhenTheQueriesRunLow() {
    Workflow_Instance__c inst = seedAndLoad(12, 100);
    List<Workflow_Step_Execution__c> steps = stepsOf(inst.Id);
    WorkflowPayloadService.queryReserve = Limits.getLimitQueries();

    WorkflowPayloadService.resolvePayloadsInBulk(inst, steps);

    Integer resolved = 0;
    for (Workflow_Step_Execution__c step : steps) {
      if (step.Output__c == 'X'.repeat(100)) {
        resolved++;
      }
    }
    Assert.areEqual(5, resolved, 'Only the first batch is read');
  }
}
