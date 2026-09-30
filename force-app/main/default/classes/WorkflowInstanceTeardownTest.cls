/**
 * @description Tests for {@link WorkflowInstanceTeardown} and the group
 * planning of {@link CleanupDocumentPurger} (issue #142).
 */
@IsTest
private class WorkflowInstanceTeardownTest {
  private static Workflow_Instance__c insertInstance(String key) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Completed',
      Correlation_Key__c = key
    );
    insert inst;
    return inst;
  }

  private static Id insertFile(String title, List<Id> linkedIds) {
    ContentVersion cv = new ContentVersion(
      Title = title,
      PathOnClient = title + '.json',
      VersionData = Blob.valueOf('{}')
    );
    insert cv;
    Id docId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
    ]
    .ContentDocumentId;
    List<ContentDocumentLink> links = new List<ContentDocumentLink>();
    for (Id linkedId : linkedIds) {
      links.add(
        new ContentDocumentLink(
          ContentDocumentId = docId,
          LinkedEntityId = linkedId,
          ShareType = 'V',
          Visibility = 'AllUsers'
        )
      );
    }
    insert links;
    return docId;
  }

  @IsTest
  static void runCountsEachDeletedRecord() {
    Workflow_Instance__c a = insertInstance('td-a');
    Workflow_Instance__c b = insertInstance('td-b');
    insert new List<Workflow_Signal__c>{
      new Workflow_Signal__c(
        Workflow_Instance__c = a.Id,
        Signal_Name__c = 'Go',
        Status__c = 'Consumed'
      ),
      new Workflow_Signal__c(
        Workflow_Instance__c = b.Id,
        Signal_Name__c = 'Go',
        Status__c = 'Consumed'
      )
    };
    insert new List<Workflow_Log__c>{
      new Workflow_Log__c(Workflow_Instance__c = a.Id, Level__c = 'Info'),
      new Workflow_Log__c(Workflow_Instance__c = b.Id, Level__c = 'Info'),
      new Workflow_Log__c(Workflow_Instance__c = b.Id, Level__c = 'Info')
    };
    insertFile('Input_A', new List<Id>{ a.Id });
    insertFile('Output_B', new List<Id>{ b.Id });

    CleanupDocumentPurger.PurgeChunk chunk = CleanupDocumentPurger.planChunk(
      new List<Workflow_Instance__c>{ a, b }
    );
    WorkflowInstanceTeardown.Counts counts = WorkflowInstanceTeardown.run(
      chunk
    );

    System.assertEquals(2, counts.instances, 'instances');
    System.assertEquals(2, counts.signals, 'signals');
    System.assertEquals(3, counts.logs, 'logs');
    System.assertEquals(2, counts.files, 'files');
    System.assertEquals(true, counts.complete, 'complete');
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Workflow_Instance__c],
      'no instance remains'
    );
  }

  @IsTest
  static void runWithNothingDoesNothing() {
    WorkflowInstanceTeardown.Counts none = WorkflowInstanceTeardown.run(null);
    WorkflowInstanceTeardown.Counts empty = WorkflowInstanceTeardown.run(
      new CleanupDocumentPurger.PurgeChunk()
    );

    System.assertEquals(0, none.instances, 'null chunk');
    System.assertEquals(true, none.complete, 'null chunk is complete');
    System.assertEquals(0, empty.instances, 'empty chunk');
  }

  @IsTest
  static void fileSharedInsideAGroupIsDeleted() {
    Workflow_Instance__c a = insertInstance('grp-a');
    Workflow_Instance__c b = insertInstance('grp-b');
    Id doc = insertFile('State_Group', new List<Id>{ a.Id, b.Id });

    // Alone, a does not own the file: b still links to it.
    CleanupDocumentPurger.PurgeChunk alone = CleanupDocumentPurger.planChunk(
      new List<Workflow_Instance__c>{ a }
    );
    System.assert(
      !alone.finalDocIdsToDelete.contains(doc),
      'shared with an instance outside the chunk'
    );

    CleanupDocumentPurger.PurgeChunk grouped = CleanupDocumentPurger.planGroups(
      new List<List<Workflow_Instance__c>>{
        new List<Workflow_Instance__c>{ a, b }
      }
    );
    System.assert(
      grouped.finalDocIdsToDelete.contains(doc),
      'linked only inside the group'
    );
  }

  @IsTest
  static void firstGroupGoesWholeAndNextGroupWaits() {
    CleanupDocumentPurger.maxDocsPerChunk = 1;
    Workflow_Instance__c a = insertInstance('cap-a');
    Workflow_Instance__c b = insertInstance('cap-b');
    Workflow_Instance__c c = insertInstance('cap-c');
    insertFile('Input_A', new List<Id>{ a.Id });
    insertFile('Input_B', new List<Id>{ b.Id });
    insertFile('Input_C', new List<Id>{ c.Id });

    CleanupDocumentPurger.PurgeChunk chunk = CleanupDocumentPurger.planGroups(
      new List<List<Workflow_Instance__c>>{
        new List<Workflow_Instance__c>{ a, b },
        new List<Workflow_Instance__c>{ c }
      }
    );

    System.assertEquals(
      new Set<Id>{ a.Id, b.Id },
      chunk.instanceIdsToPurge,
      'first group whole, over the cap'
    );
    System.assertEquals(2, chunk.finalDocIdsToDelete.size(), 'two files');
  }
}
