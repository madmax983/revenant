/**
 * @description Tests for the targeted instance purge (issue #142).
 * Written first (RED). They fail on code that has no purge API.
 *
 * Scenarios:
 *  1. Purge removes the instance and all satellites. Zero orphans.
 *  2. Only terminal statuses pass. Each terminal status passes.
 *  3. A mixed set purges what passes and reports each skip.
 *  4. Bad input throws. An empty set does nothing.
 *  5. A child outside the set blocks the parent. includeRelated adds it.
 *  6. An active related instance blocks the purge.
 *  7. Chains: truncation of old generations passes. A gap is refused.
 *  8. A rejected member rejects its group.
 *  9. The file cap defers a group. It never splits a group.
 * 10. A family over the ceiling is refused.
 * 11. A second purge of the same Id reports NOT_FOUND.
 */
@IsTest
private class WorkflowInstancePurgeTest {
  private static final String WF = 'WorkflowEngineTest.HappyWorkflow';

  private static Workflow_Instance__c newInstance(String status, String key) {
    return new Workflow_Instance__c(
      Workflow_Name__c = WF,
      Status__c = status,
      Correlation_Key__c = key
    );
  }

  private static Workflow_Instance__c insertInstance(
    String status,
    String key
  ) {
    Workflow_Instance__c inst = newInstance(status, key);
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

  private static Boolean exists(Id instanceId) {
    return [
        SELECT COUNT()
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ] == 1;
  }

  private static Set<Id> remainingDocs(Set<Id> docIds) {
    return new Map<Id, ContentDocument>(
        [SELECT Id FROM ContentDocument WHERE Id IN :docIds]
      )
      .keySet();
  }

  // 1 ─────────────────────────────────────────────────────────────────────
  @IsTest
  static void purgeRemovesInstanceAndAllSatellites() {
    Workflow_Instance__c target = insertInstance('Completed', 'purge-1');
    Workflow_Instance__c other = insertInstance('Completed', 'purge-keep');

    Workflow_Step_Execution__c step = new Workflow_Step_Execution__c(
      Workflow_Instance__c = target.Id,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Completed',
      Retry_Count__c = 0
    );
    insert step;
    Workflow_Search_Attribute__c attr = new Workflow_Search_Attribute__c(
      Workflow_Instance__c = target.Id,
      Key__c = 'k',
      Value__c = 'v',
      Key_Value__c = 'k=v'
    );
    insert attr;
    Workflow_Signal__c sig = new Workflow_Signal__c(
      Workflow_Instance__c = target.Id,
      Signal_Name__c = 'Go',
      Status__c = 'Consumed'
    );
    insert sig;

    Workflow_Schedule__c sched = new Workflow_Schedule__c(
      Name = 'PurgeSched',
      Workflow_Name__c = WF,
      Cron_Expression__c = '0 2 * * *',
      Correlation_Key_Prefix__c = 'PurgeSchedKey',
      Enabled__c = false
    );
    insert sched;
    Workflow_Log__c instanceLog = new Workflow_Log__c(
      Workflow_Instance__c = target.Id,
      Level__c = 'Error',
      Log_Type__c = 'StepError',
      Message__c = 'boom'
    );
    Workflow_Log__c scheduleLog = new Workflow_Log__c(
      Workflow_Instance__c = target.Id,
      Schedule__c = sched.Id,
      Level__c = 'Info',
      Log_Type__c = 'ScheduleFire',
      Outcome__c = 'Started'
    );
    insert new List<Workflow_Log__c>{ instanceLog, scheduleLog };

    Id privateDoc = insertFile('Input_Private', new List<Id>{ target.Id });
    Id sharedDoc = insertFile(
      'Output_Shared',
      new List<Id>{ target.Id, other.Id }
    );
    Id userDoc = insertFile('MyContract', new List<Id>{ target.Id });

    Test.startTest();
    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      target.Id
    );
    Test.stopTest();

    Assert.areEqual(1, result.purgedCount, 'one instance purged');
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.PURGED,
      result.outcomeOf(target.Id),
      'target purged'
    );
    Assert.areEqual(1, result.deletedSignalCount, 'one signal');
    Assert.areEqual(1, result.deletedLogCount, 'one instance log');
    Assert.areEqual(1, result.deletedFileCount, 'one private engine file');

    // Residual scan: zero orphans.
    Assert.isFalse(exists(target.Id), 'instance deleted');
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Workflow_Step_Execution__c WHERE Id = :step.Id],
      'step row cascades'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Workflow_Search_Attribute__c WHERE Id = :attr.Id],
      'attribute cascades'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Workflow_Signal__c WHERE Id = :sig.Id],
      'signal deleted'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Workflow_Log__c WHERE Id = :instanceLog.Id],
      'instance log deleted'
    );
    Set<Id> docs = remainingDocs(new Set<Id>{ privateDoc, sharedDoc, userDoc });
    Assert.isFalse(docs.contains(privateDoc), 'private engine file deleted');
    Assert.isTrue(docs.contains(sharedDoc), 'shared file kept');
    Assert.isTrue(docs.contains(userDoc), 'user file kept');

    // The schedule owns its fire log. The platform clears the lookup.
    Workflow_Log__c keptLog = [
      SELECT Workflow_Instance__c
      FROM Workflow_Log__c
      WHERE Id = :scheduleLog.Id
    ];
    Assert.isNull(keptLog.Workflow_Instance__c, 'fire log unlinked');
    Assert.isTrue(exists(other.Id), 'other instance kept');
  }

  // 2 ─────────────────────────────────────────────────────────────────────
  @IsTest
  static void everyTerminalStatusPasses() {
    List<Workflow_Instance__c> rows = new List<Workflow_Instance__c>();
    for (
      String status : new List<String>{
        'Completed',
        'Failed',
        'Compensated',
        'Cancelled',
        'ContinuedAsNew'
      }
    ) {
      rows.add(newInstance(status, 'term-' + status));
    }
    insert rows;
    Set<Id> ids = new Map<Id, Workflow_Instance__c>(rows).keySet();

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(ids);

    Assert.areEqual(5, result.purgedCount, 'all terminal rows purged');
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Id IN :ids],
      'none remain'
    );
  }

  @IsTest
  static void nonTerminalStatusIsRefused() {
    List<Workflow_Instance__c> rows = new List<Workflow_Instance__c>();
    for (
      String status : new List<String>{
        'Pending',
        'Running',
        'Suspended',
        'Paused',
        'Held',
        'Compensating',
        'Cancelling',
        'CompensationFailed',
        'DefinitionChanged'
      }
    ) {
      rows.add(newInstance(status, 'active-' + status));
    }
    insert rows;
    Set<Id> ids = new Map<Id, Workflow_Instance__c>(rows).keySet();

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(ids);

    Assert.areEqual(0, result.purgedCount, 'nothing purged');
    for (Id instanceId : ids) {
      WorkflowInstancePurge.InstanceResult r = result.get(instanceId);
      Assert.areEqual(
        WorkflowInstancePurge.Outcome.REJECTED_NOT_TERMINAL,
        r.outcome,
        'refused: ' + instanceId
      );
      Assert.isTrue(r.message.contains('terminal'), 'actionable message');
    }
    Assert.areEqual(
      9,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Id IN :ids],
      'all remain'
    );
  }

  // 3 ─────────────────────────────────────────────────────────────────────
  @IsTest
  static void mixedSetSkipsAndReports() {
    Workflow_Instance__c done = insertInstance('Completed', 'mix-done');
    Workflow_Instance__c running = insertInstance('Running', 'mix-run');
    Workflow_Instance__c gone = insertInstance('Completed', 'mix-gone');
    Id goneId = gone.Id;
    delete gone;
    Id wrongType = UserInfo.getUserId();

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>{ done.Id, running.Id, goneId, wrongType }
    );

    Assert.areEqual(
      WorkflowInstancePurge.Outcome.PURGED,
      result.outcomeOf(done.Id),
      'terminal purged'
    );
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_NOT_TERMINAL,
      result.outcomeOf(running.Id),
      'running refused'
    );
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.NOT_FOUND,
      result.outcomeOf(goneId),
      'deleted Id not found'
    );
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.NOT_FOUND,
      result.outcomeOf(wrongType),
      'other object Id not found'
    );
    Assert.areEqual(4, result.results.size(), 'one row per requested Id');
    Assert.isTrue(exists(running.Id), 'running kept');
  }

  // 4 ─────────────────────────────────────────────────────────────────────
  @IsTest
  static void badInputThrows() {
    List<Set<Id>> badInputs = new List<Set<Id>>{ null, new Set<Id>{ null } };
    for (Set<Id> input : badInputs) {
      try {
        WorkflowInstancePurge.purge(input);
        Assert.fail('expected an exception for ' + input);
      } catch (WorkflowEngine.WorkflowException e) {
        Assert.isTrue(e.getMessage().contains('null'), e.getMessage());
      }
    }
    try {
      WorkflowInstancePurge.purge((Id) null);
      Assert.fail('expected an exception for a null Id');
    } catch (WorkflowEngine.WorkflowException e) {
      Assert.isTrue(e.getMessage().contains('null'), e.getMessage());
    }
  }

  @IsTest
  static void overCeilingThrows() {
    List<Workflow_Instance__c> rows = new List<Workflow_Instance__c>();
    for (
      Integer i = 0; i <= WorkflowInstancePurge.MAX_INSTANCES_PER_CALL; i++
    ) {
      rows.add(newInstance('Completed', 'ceil-' + i));
    }
    insert rows;
    try {
      WorkflowInstancePurge.purge(
        new Map<Id, Workflow_Instance__c>(rows).keySet()
      );
      Assert.fail('expected an exception over the ceiling');
    } catch (WorkflowEngine.WorkflowException e) {
      Assert.isTrue(
        e.getMessage()
          .contains(
            String.valueOf(WorkflowInstancePurge.MAX_INSTANCES_PER_CALL)
          ),
        e.getMessage()
      );
    }
    Assert.areEqual(
      rows.size(),
      [SELECT COUNT() FROM Workflow_Instance__c],
      'nothing deleted'
    );
  }

  @IsTest
  static void emptySetDoesNothing() {
    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>()
    );
    Assert.areEqual(0, result.purgedCount, 'nothing purged');
    Assert.isTrue(result.results.isEmpty(), 'no rows');
  }

  // 5 ─────────────────────────────────────────────────────────────────────
  @IsTest
  static void childOutsideSetBlocksParent() {
    Workflow_Instance__c parent = insertInstance('Completed', 'fam-parent');
    Workflow_Instance__c child = newInstance('Completed', 'fam-child');
    child.Parent_Instance__c = parent.Id;
    insert child;

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      parent.Id
    );

    WorkflowInstancePurge.InstanceResult r = result.get(parent.Id);
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_RELATED,
      r.outcome,
      'child blocks parent'
    );
    Assert.isTrue(r.message.contains(child.Id), 'names the child');
    Assert.isTrue(r.message.contains('includeRelated'), 'names the flag');
    Assert.isTrue(exists(parent.Id) && exists(child.Id), 'both kept');
  }

  @IsTest
  static void includeRelatedPurgesChildrenAndReportsThem() {
    Workflow_Instance__c parent = insertInstance('Completed', 'fam-parent');
    Workflow_Instance__c child = newInstance('Failed', 'fam-child');
    child.Parent_Instance__c = parent.Id;
    insert child;
    Workflow_Instance__c grandchild = newInstance('Cancelled', 'fam-grand');
    grandchild.Parent_Instance__c = child.Id;
    insert grandchild;
    Workflow_Signal__c childSignal = new Workflow_Signal__c(
      Workflow_Instance__c = grandchild.Id,
      Signal_Name__c = 'Go',
      Status__c = 'Received'
    );
    insert childSignal;

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>{ parent.Id },
      true
    );

    Assert.areEqual(3, result.purgedCount, 'family purged');
    WorkflowInstancePurge.InstanceResult childRow = result.get(child.Id);
    Assert.isNotNull(childRow, 'related Id reported');
    Assert.isFalse(childRow.requested, 'added by includeRelated');
    Assert.isTrue(result.get(parent.Id).requested, 'requested Id');
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.PURGED,
      result.outcomeOf(grandchild.Id),
      'grandchild purged'
    );
    Assert.areEqual(1, result.deletedSignalCount, 'grandchild signal');
    Assert.isFalse(exists(grandchild.Id), 'grandchild deleted');
  }

  // 6 ─────────────────────────────────────────────────────────────────────
  @IsTest
  static void activeChildBlocksIncludeRelated() {
    Workflow_Instance__c parent = insertInstance('Completed', 'act-parent');
    Workflow_Instance__c child = newInstance('Running', 'act-child');
    child.Parent_Instance__c = parent.Id;
    insert child;

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>{ parent.Id },
      true
    );

    WorkflowInstancePurge.InstanceResult r = result.get(parent.Id);
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_RELATED_ACTIVE,
      r.outcome,
      'active child blocks'
    );
    Assert.isTrue(r.message.contains(child.Id), 'names the child');
    Assert.isNull(result.get(child.Id), 'untouched Id not reported');
    Assert.isTrue(exists(parent.Id) && exists(child.Id), 'both kept');
  }

  @IsTest
  static void activeParentBlocksChild() {
    Workflow_Instance__c parent = insertInstance('Suspended', 'ap-parent');
    Workflow_Instance__c child = newInstance('Completed', 'ap-child');
    child.Parent_Instance__c = parent.Id;
    insert child;

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      child.Id
    );

    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_RELATED_ACTIVE,
      result.outcomeOf(child.Id),
      'active parent still reads its children'
    );
    Assert.isTrue(exists(child.Id), 'child kept');
  }

  @IsTest
  static void terminalParentAllowsChild() {
    Workflow_Instance__c parent = insertInstance('Completed', 'tp-parent');
    Workflow_Instance__c child = newInstance('Completed', 'tp-child');
    child.Parent_Instance__c = parent.Id;
    insert child;

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      child.Id
    );

    Assert.areEqual(
      WorkflowInstancePurge.Outcome.PURGED,
      result.outcomeOf(child.Id),
      'child purged'
    );
    Assert.isTrue(exists(parent.Id), 'parent is never added');
  }

  // 7 ─────────────────────────────────────────────────────────────────────
  private static List<Workflow_Instance__c> insertChain(List<String> statuses) {
    List<Workflow_Instance__c> chain = new List<Workflow_Instance__c>();
    Id previous = null;
    Integer i = 0;
    for (String status : statuses) {
      Workflow_Instance__c gen = newInstance(status, 'chain-' + i++);
      gen.Root_Correlation_Key__c = 'chain';
      gen.Previous_Instance__c = previous;
      insert gen;
      chain.add(gen);
      previous = gen.Id;
    }
    return chain;
  }

  @IsTest
  static void chainGapIsRefused() {
    List<Workflow_Instance__c> chain = insertChain(
      new List<String>{ 'ContinuedAsNew', 'ContinuedAsNew', 'Completed' }
    );

    WorkflowInstancePurge.PurgeResult middle = WorkflowInstancePurge.purge(
      chain[1].Id
    );
    WorkflowInstancePurge.PurgeResult newest = WorkflowInstancePurge.purge(
      chain[2].Id
    );

    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_RELATED,
      middle.outcomeOf(chain[1].Id),
      'middle generation leaves a gap'
    );
    Assert.isTrue(
      middle.get(chain[1].Id).message.contains(chain[0].Id),
      'names the predecessor'
    );
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_RELATED,
      newest.outcomeOf(chain[2].Id),
      'newest generation leaves a predecessor with no successor'
    );
    Assert.areEqual(
      3,
      [SELECT COUNT() FROM Workflow_Instance__c],
      'chain kept'
    );
  }

  @IsTest
  static void chainTruncationFromOldestPasses() {
    List<Workflow_Instance__c> chain = insertChain(
      new List<String>{ 'ContinuedAsNew', 'ContinuedAsNew', 'Completed' }
    );

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>{ chain[0].Id, chain[1].Id }
    );

    Assert.areEqual(2, result.purgedCount, 'two oldest purged');
    Workflow_Instance__c head = [
      SELECT Previous_Instance__c
      FROM Workflow_Instance__c
      WHERE Id = :chain[2].Id
    ];
    Assert.isNull(head.Previous_Instance__c, 'newest is the new head');
  }

  @IsTest
  static void activeSuccessorBlocksTruncation() {
    List<Workflow_Instance__c> chain = insertChain(
      new List<String>{ 'ContinuedAsNew', 'Running' }
    );

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      chain[0].Id
    );

    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_RELATED_ACTIVE,
      result.outcomeOf(chain[0].Id),
      'a running successor (or rollback) still reads its predecessor'
    );
    Assert.isTrue(exists(chain[0].Id), 'predecessor kept');
  }

  @IsTest
  static void includeRelatedPurgesWholeChain() {
    List<Workflow_Instance__c> chain = insertChain(
      new List<String>{ 'ContinuedAsNew', 'ContinuedAsNew', 'Completed' }
    );

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>{ chain[1].Id },
      true
    );

    Assert.areEqual(3, result.purgedCount, 'all generations purged');
    Assert.isFalse(result.get(chain[0].Id).requested, 'older added');
    Assert.isFalse(result.get(chain[2].Id).requested, 'newer added');
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Workflow_Instance__c],
      'no generation remains'
    );
  }

  // 8 ─────────────────────────────────────────────────────────────────────
  @IsTest
  static void rejectedMemberRejectsItsGroup() {
    List<Workflow_Instance__c> chain = insertChain(
      new List<String>{ 'ContinuedAsNew', 'ContinuedAsNew', 'Completed' }
    );
    Workflow_Instance__c child = newInstance('Completed', 'grp-child');
    child.Parent_Instance__c = chain[1].Id;
    insert child;

    // chain[1] has a child outside the set. chain[2] alone would leave
    // chain[1] with no successor, so the group goes or stays as one.
    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>{ chain[1].Id, chain[2].Id }
    );

    Assert.areEqual(0, result.purgedCount, 'group kept');
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_RELATED,
      result.outcomeOf(chain[2].Id),
      'group member rejected too'
    );
    Assert.isTrue(
      result.get(chain[2].Id).message.contains(chain[1].Id),
      'names the rejected member'
    );
  }

  // 9 ─────────────────────────────────────────────────────────────────────
  @IsTest
  static void fileCapDefersNextGroup() {
    Workflow_Instance__c first = insertInstance('Completed', 'cap-1');
    Workflow_Instance__c second = insertInstance('Completed', 'cap-2');
    Id firstDoc = insertFile('Input_1', new List<Id>{ first.Id });
    Id secondDoc = insertFile('Input_2', new List<Id>{ second.Id });
    CleanupDocumentPurger.maxDocsPerChunk = 1;

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>{ first.Id, second.Id }
    );

    Assert.areEqual(1, result.purgedCount, 'one instance fits the cap');
    Id deferredId = result.outcomeOf(first.Id) ==
      WorkflowInstancePurge.Outcome.PURGED
      ? second.Id
      : first.Id;
    WorkflowInstancePurge.InstanceResult deferred = result.get(deferredId);
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.DEFERRED,
      deferred.outcome,
      'other instance deferred'
    );
    Assert.isTrue(deferred.message.contains('again'), 'says call again');
    Assert.isTrue(exists(deferredId), 'deferred instance kept');
    Assert.areEqual(
      1,
      remainingDocs(new Set<Id>{ firstDoc, secondDoc }).size(),
      'deferred file kept'
    );

    WorkflowInstancePurge.PurgeResult again = WorkflowInstancePurge.purge(
      deferredId
    );
    Assert.areEqual(1, again.purgedCount, 'second call purges it');
  }

  @IsTest
  static void fileCapNeverSplitsAGroup() {
    Workflow_Instance__c parent = insertInstance('Completed', 'split-p');
    Workflow_Instance__c child = newInstance('Completed', 'split-c');
    child.Parent_Instance__c = parent.Id;
    insert child;
    insertFile('Input_P', new List<Id>{ parent.Id });
    insertFile('Input_C', new List<Id>{ child.Id });
    CleanupDocumentPurger.maxDocsPerChunk = 1;

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>{ parent.Id },
      true
    );

    // The first group always goes whole, so the purge moves forward.
    Assert.areEqual(2, result.purgedCount, 'whole group purged');
    Assert.areEqual(2, result.deletedFileCount, 'both files deleted');
  }

  @IsTest
  static void fileSharedInsideTheSetIsDeleted() {
    Workflow_Instance__c a = insertInstance('Completed', 'share-a');
    Workflow_Instance__c b = insertInstance('Failed', 'share-b');
    Id doc = insertFile('State_Shared', new List<Id>{ a.Id, b.Id });

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>{ a.Id, b.Id }
    );

    Assert.areEqual(2, result.purgedCount, 'both purged');
    Assert.isTrue(
      remainingDocs(new Set<Id>{ doc }).isEmpty(),
      'file linked only to purged instances deleted'
    );
  }

  // 10 ────────────────────────────────────────────────────────────────────
  @IsTest
  static void familyOverCeilingIsRefused() {
    Workflow_Instance__c parent = insertInstance('Completed', 'big-parent');
    List<Workflow_Instance__c> children = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < WorkflowInstancePurge.MAX_INSTANCES_PER_CALL; i++) {
      Workflow_Instance__c c = newInstance('Completed', 'big-child-' + i);
      c.Parent_Instance__c = parent.Id;
      children.add(c);
    }
    insert children;

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>{ parent.Id },
      true
    );

    WorkflowInstancePurge.InstanceResult r = result.get(parent.Id);
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_TOO_LARGE,
      r.outcome,
      'family of 51 refused'
    );
    Assert.isTrue(
      r.message.contains(
        String.valueOf(WorkflowInstancePurge.MAX_INSTANCES_PER_CALL)
      ),
      'names the ceiling'
    );
    Assert.areEqual(
      51,
      [SELECT COUNT() FROM Workflow_Instance__c],
      'nothing deleted'
    );
  }

  // 11 ────────────────────────────────────────────────────────────────────
  @IsTest
  static void secondPurgeReportsNotFound() {
    Workflow_Instance__c inst = insertInstance('Completed', 'twice');

    WorkflowInstancePurge.purge(inst.Id);
    WorkflowInstancePurge.PurgeResult again = WorkflowInstancePurge.purge(
      inst.Id
    );

    Assert.areEqual(
      WorkflowInstancePurge.Outcome.NOT_FOUND,
      again.outcomeOf(inst.Id),
      'already purged'
    );
    Assert.areEqual(0, again.purgedCount, 'nothing purged');
  }
}
