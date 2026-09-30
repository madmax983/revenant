/**
 * @description Tests for the targeted instance purge (issue #142).
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
 * 12. Review cases: Failed parent, rollbacks, link and row bounds,
 *     satellite pages, messages, overlapping families, status guard.
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
      Assert.isTrue(r.message.startsWith('The status is '), r.message);
      Assert.isTrue(r.message.contains('Cancel it'), 'actionable message');
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
    Workflow_Step_Execution__c childStep = new Workflow_Step_Execution__c(
      Workflow_Instance__c = child.Id,
      Step_Name__c = 'WorkflowEngineTest.HappyStep1',
      Status__c = 'Failed',
      Retry_Count__c = 0
    );
    insert childStep;
    Workflow_Log__c childLog = new Workflow_Log__c(
      Workflow_Instance__c = child.Id,
      Level__c = 'Error'
    );
    insert childLog;
    Id grandchildDoc = insertFile('Input_Grand', new List<Id>{ grandchild.Id });

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>{ parent.Id },
      true
    );

    Assert.areEqual(3, result.purgedCount, 'family purged');
    // Residual scan of the related instances: zero orphans.
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Workflow_Step_Execution__c WHERE Id = :childStep.Id],
      'related step row cascades'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Workflow_Log__c WHERE Id = :childLog.Id],
      'related log deleted'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Workflow_Signal__c WHERE Id = :childSignal.Id],
      'related signal deleted'
    );
    Assert.isTrue(
      remainingDocs(new Set<Id>{ grandchildDoc }).isEmpty(),
      'related engine file deleted'
    );
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

  // 12 ────────────────────────────────────────────────────────────────────
  @IsTest
  static void failedParentBlocksChild() {
    Workflow_Instance__c parent = insertInstance('Failed', 'fp-parent');
    Workflow_Instance__c child = newInstance('Completed', 'fp-child');
    child.Parent_Instance__c = parent.Id;
    insert child;

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      child.Id
    );

    WorkflowInstancePurge.InstanceResult r = result.get(child.Id);
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_RELATED_ACTIVE,
      r.outcome,
      'a Failed parent can be retried and read its children'
    );
    Assert.isTrue(r.message.contains(parent.Id + ' (Failed)'), r.message);
    Assert.isTrue(exists(child.Id), 'child kept');

    WorkflowInstancePurge.PurgeResult both = WorkflowInstancePurge.purge(
      new Set<Id>{ parent.Id, child.Id }
    );
    Assert.areEqual(2, both.purgedCount, 'parent and child go together');
  }

  @IsTest
  static void compensatedTargetAndItsRollback() {
    Workflow_Instance__c target = insertInstance('Completed', 'comp-target');
    Workflow_Instance__c rollbackRun = newInstance('Compensated', 'comp-roll');
    rollbackRun.Previous_Instance__c = target.Id;
    insert rollbackRun;

    WorkflowInstancePurge.PurgeResult alone = WorkflowInstancePurge.purge(
      rollbackRun.Id
    );
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_RELATED,
      alone.outcomeOf(rollbackRun.Id),
      'the rollback needs its target'
    );

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      target.Id
    );
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.PURGED,
      result.outcomeOf(target.Id),
      'a finished rollback does not block its target'
    );
    Workflow_Instance__c kept = [
      SELECT Previous_Instance__c
      FROM Workflow_Instance__c
      WHERE Id = :rollbackRun.Id
    ];
    Assert.isNull(kept.Previous_Instance__c, 'link cleared');
  }

  @IsTest
  static void stalledRollbackBlocksItsTarget() {
    Workflow_Instance__c target = insertInstance('Completed', 'stall-target');
    Workflow_Instance__c rollbackRun = newInstance(
      'CompensationFailed',
      'stall-roll'
    );
    rollbackRun.Previous_Instance__c = target.Id;
    insert rollbackRun;

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      target.Id
    );

    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_RELATED_ACTIVE,
      result.outcomeOf(target.Id),
      'a stalled rollback still reads its target'
    );
  }

  @IsTest
  static void runningChildOutsideSetIsActive() {
    Workflow_Instance__c parent = insertInstance('Completed', 'rc-parent');
    Workflow_Instance__c child = newInstance('Running', 'rc-child');
    child.Parent_Instance__c = parent.Id;
    insert child;

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      parent.Id
    );

    WorkflowInstancePurge.InstanceResult r = result.get(parent.Id);
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_RELATED_ACTIVE,
      r.outcome,
      'the advice to set includeRelated would not help'
    );
    Assert.isTrue(r.message.contains(child.Id + ' (Running)'), r.message);
  }

  @IsTest
  static void activeGroupMateRejectsRequestedId() {
    List<Workflow_Instance__c> chain = insertChain(
      new List<String>{ 'ContinuedAsNew', 'ContinuedAsNew', 'Running' }
    );

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>{ chain[0].Id },
      true
    );

    WorkflowInstancePurge.InstanceResult r = result.get(chain[0].Id);
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_RELATED_ACTIVE,
      r.outcome,
      'the running generation blocks the family'
    );
    Assert.isTrue(r.message.contains(chain[2].Id), 'names the cause');
    Assert.isTrue(r.message.contains('Running'), 'gives the reason');
    Assert.areEqual(0, result.purgedCount, 'nothing purged');
  }

  @IsTest
  static void linkDepthBound() {
    WorkflowInstancePurge.maxLinkRounds = 1;
    List<Workflow_Instance__c> shortChain = insertChain(
      new List<String>{ 'ContinuedAsNew', 'Completed' }
    );

    // One link level fits the bound exactly.
    WorkflowInstancePurge.PurgeResult fits = WorkflowInstancePurge.purge(
      new Set<Id>{ shortChain[1].Id },
      true
    );
    Assert.areEqual(2, fits.purgedCount, 'depth equal to the bound passes');

    List<Workflow_Instance__c> longChain = insertChain(
      new List<String>{ 'ContinuedAsNew', 'ContinuedAsNew', 'Completed' }
    );
    WorkflowInstancePurge.PurgeResult deep = WorkflowInstancePurge.purge(
      new Set<Id>{ longChain[2].Id },
      true
    );
    WorkflowInstancePurge.InstanceResult r = deep.get(longChain[2].Id);
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_TOO_LARGE,
      r.outcome,
      'depth over the bound is refused'
    );
    Assert.isTrue(r.message.contains('includeRelated'), 'gives advice');
    Assert.areEqual(
      3,
      [SELECT COUNT() FROM Workflow_Instance__c],
      'long chain kept'
    );
  }

  @IsTest
  static void familyRowBound() {
    WorkflowInstancePurge.maxRelatedRows = 1;
    Workflow_Instance__c parent = insertInstance('Completed', 'rows-parent');
    List<Workflow_Instance__c> children = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < 2; i++) {
      Workflow_Instance__c c = newInstance('Completed', 'rows-child-' + i);
      c.Parent_Instance__c = parent.Id;
      children.add(c);
    }
    insert children;

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>{ parent.Id },
      true
    );

    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_TOO_LARGE,
      result.outcomeOf(parent.Id),
      'a cut family read is refused'
    );
  }

  @IsTest
  static void cutLinkCheckDefersOnlyUnknownGroups() {
    WorkflowInstancePurge.maxRelatedRows = 1;
    Workflow_Instance__c parent = insertInstance('Completed', 'cut-parent');
    List<Workflow_Instance__c> children = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < 2; i++) {
      Workflow_Instance__c c = newInstance('Completed', 'cut-child-' + i);
      c.Parent_Instance__c = parent.Id;
      children.add(c);
    }
    insert children;
    Workflow_Instance__c plain = insertInstance('Completed', 'cut-plain');

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>{ parent.Id, plain.Id }
    );

    Assert.areEqual(
      WorkflowInstancePurge.Outcome.REJECTED_RELATED,
      result.outcomeOf(parent.Id),
      'a known dangling child still rejects'
    );
    WorkflowInstancePurge.InstanceResult r = result.get(plain.Id);
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.DEFERRED,
      r.outcome,
      'an unchecked group waits, it is not rejected'
    );
    Assert.isTrue(r.message.contains('fewer Ids'), r.message);
    Assert.isTrue(exists(plain.Id), 'plain kept');
  }

  @IsTest
  static void instanceCountDefersSecondFamily() {
    List<Workflow_Instance__c> parents = new List<Workflow_Instance__c>{
      newInstance('Completed', 'fam-a'),
      newInstance('Completed', 'fam-b')
    };
    insert parents;
    List<Workflow_Instance__c> children = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c p : parents) {
      for (Integer i = 0; i < 29; i++) {
        Workflow_Instance__c c = newInstance(
          'Completed',
          p.Correlation_Key__c + '-' + i
        );
        c.Parent_Instance__c = p.Id;
        children.add(c);
      }
    }
    insert children;

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Map<Id, Workflow_Instance__c>(parents).keySet(),
      true
    );

    Assert.areEqual(30, result.purgedCount, 'one family of 30 fits');
    Integer deferred = 0;
    for (Workflow_Instance__c p : parents) {
      if (result.outcomeOf(p.Id) == WorkflowInstancePurge.Outcome.DEFERRED) {
        deferred++;
      }
    }
    Assert.areEqual(1, deferred, 'the other family waits');
    Assert.areEqual(
      30,
      [SELECT COUNT() FROM Workflow_Instance__c],
      'deferred family kept'
    );
  }

  @IsTest
  static void satellitePagesDeferThenFinish() {
    WorkflowInstanceTeardown.maxSatelliteRows = 1;
    Workflow_Instance__c inst = insertInstance('Completed', 'pages');
    insert new List<Workflow_Log__c>{
      new Workflow_Log__c(Workflow_Instance__c = inst.Id, Level__c = 'Info'),
      new Workflow_Log__c(Workflow_Instance__c = inst.Id, Level__c = 'Info')
    };
    Id doc = insertFile('Output_Pages', new List<Id>{ inst.Id });

    WorkflowInstancePurge.PurgeResult first = WorkflowInstancePurge.purge(
      inst.Id
    );

    WorkflowInstancePurge.InstanceResult r = first.get(inst.Id);
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.DEFERRED,
      r.outcome,
      'not purged while logs remain'
    );
    Assert.isTrue(r.message.contains('again'), r.message);
    Assert.areEqual(0, first.purgedCount, 'no instance deleted');
    Assert.areEqual(1, first.deletedLogCount, 'one page of logs');
    Assert.areEqual(0, first.deletedFileCount, 'no file deleted yet');
    Assert.isTrue(exists(inst.Id), 'instance kept');
    Assert.isFalse(
      remainingDocs(new Set<Id>{ doc }).isEmpty(),
      'a kept instance keeps its payload file'
    );

    WorkflowInstancePurge.PurgeResult second = WorkflowInstancePurge.purge(
      inst.Id
    );
    Assert.areEqual(
      WorkflowInstancePurge.Outcome.PURGED,
      second.outcomeOf(inst.Id),
      'second call finishes'
    );
    Assert.areEqual(1, second.deletedFileCount, 'file goes with the instance');
  }

  @IsTest
  static void manyDanglingChildrenAreSummarized() {
    Workflow_Instance__c parent = insertInstance('Completed', 'many-parent');
    List<Workflow_Instance__c> children = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < 7; i++) {
      Workflow_Instance__c c = newInstance('Completed', 'many-child-' + i);
      c.Parent_Instance__c = parent.Id;
      children.add(c);
    }
    insert children;

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      parent.Id
    );

    Assert.isTrue(
      result.get(parent.Id).message.contains('and 2 more'),
      result.get(parent.Id).message
    );
  }

  @IsTest
  static void overlappingFamiliesReportEachIdOnce() {
    List<Workflow_Instance__c> chain = insertChain(
      new List<String>{ 'ContinuedAsNew', 'ContinuedAsNew', 'Completed' }
    );

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      new Set<Id>{ chain[0].Id, chain[2].Id },
      true
    );

    Assert.areEqual(3, result.purgedCount, 'one family, three rows');
    Assert.areEqual(3, result.results.size(), 'no duplicate rows');
    Assert.isTrue(result.get(chain[0].Id).requested, 'requested');
    Assert.isTrue(result.get(chain[2].Id).requested, 'requested');
    Assert.isFalse(result.get(chain[1].Id).requested, 'added');
  }

  @IsTest
  static void fileLinkedToAnotherRecordIsKept() {
    Workflow_Instance__c inst = insertInstance('Completed', 'other-link');
    Workflow_Schedule__c sched = new Workflow_Schedule__c(
      Name = 'LinkSched',
      Workflow_Name__c = WF,
      Cron_Expression__c = '0 2 * * *',
      Correlation_Key_Prefix__c = 'LinkSchedKey',
      Enabled__c = false
    );
    insert sched;
    Id doc = insertFile('Input_Linked', new List<Id>{ inst.Id, sched.Id });

    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(
      inst.Id
    );

    Assert.areEqual(1, result.purgedCount, 'instance purged');
    Assert.areEqual(0, result.deletedFileCount, 'no file deleted');
    Assert.isFalse(
      remainingDocs(new Set<Id>{ doc }).isEmpty(),
      'file linked to another record stays'
    );
  }

  @IsTest
  static void onlyTerminalPicklistValuesArePurgeable() {
    Set<String> purgeable = new Set<String>();
    for (
      Schema.PicklistEntry e : Workflow_Instance__c.Status__c.getDescribe()
        .getPicklistValues()
    ) {
      if (WorkflowInstanceTeardown.isPurgeable(e.getValue())) {
        purgeable.add(e.getValue());
      }
    }
    Assert.areEqual(
      new Set<String>{
        'Completed',
        'Failed',
        'Compensated',
        'Cancelled',
        'ContinuedAsNew'
      },
      purgeable,
      'the delete gate holds only terminal statuses'
    );
    Set<String> copy = WorkflowInstanceTeardown.purgeableStatuses();
    copy.add('Running');
    Assert.isFalse(
      WorkflowInstanceTeardown.isPurgeable('Running'),
      'a change to the copy does not change the gate'
    );
  }

  // Success metric: 50 instances and 100 files in one call, zero orphans.
  @IsTest
  static void fiftyInstancesAndHundredFilesInOneCall() {
    List<Workflow_Instance__c> rows = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < WorkflowInstancePurge.MAX_INSTANCES_PER_CALL; i++) {
      rows.add(newInstance('Completed', 'bulk-' + i));
    }
    insert rows;
    List<Workflow_Signal__c> signals = new List<Workflow_Signal__c>();
    List<Workflow_Log__c> logs = new List<Workflow_Log__c>();
    List<ContentVersion> versions = new List<ContentVersion>();
    for (Workflow_Instance__c inst : rows) {
      signals.add(
        new Workflow_Signal__c(
          Workflow_Instance__c = inst.Id,
          Signal_Name__c = 'Go',
          Status__c = 'Consumed'
        )
      );
      logs.add(
        new Workflow_Log__c(Workflow_Instance__c = inst.Id, Level__c = 'Info')
      );
      for (String prefix : new List<String>{ 'Input_', 'Output_' }) {
        versions.add(
          new ContentVersion(
            Title = prefix + inst.Correlation_Key__c,
            PathOnClient = prefix + inst.Correlation_Key__c + '.json',
            VersionData = Blob.valueOf('{}'),
            Description = inst.Id
          )
        );
      }
    }
    insert signals;
    insert logs;
    insert versions;
    List<ContentDocumentLink> links = new List<ContentDocumentLink>();
    Set<Id> docIds = new Set<Id>();
    for (ContentVersion cv : [
      SELECT ContentDocumentId, Description
      FROM ContentVersion
      WHERE Id IN :versions
    ]) {
      docIds.add(cv.ContentDocumentId);
      links.add(
        new ContentDocumentLink(
          ContentDocumentId = cv.ContentDocumentId,
          LinkedEntityId = cv.Description,
          ShareType = 'V',
          Visibility = 'AllUsers'
        )
      );
    }
    insert links;
    Set<Id> ids = new Map<Id, Workflow_Instance__c>(rows).keySet();

    Test.startTest();
    Integer queriesBefore = Limits.getQueries();
    Integer dmlBefore = Limits.getDmlStatements();
    WorkflowInstancePurge.PurgeResult result = WorkflowInstancePurge.purge(ids);
    Integer queries = Limits.getQueries() - queriesBefore;
    Integer dml = Limits.getDmlStatements() - dmlBefore;
    Test.stopTest();

    Assert.areEqual(50, result.purgedCount, 'all 50 purged');
    Assert.areEqual(50, result.deletedSignalCount, 'all signals');
    Assert.areEqual(50, result.deletedLogCount, 'all logs');
    Assert.areEqual(100, result.deletedFileCount, 'all 100 files');
    Assert.isTrue(queries <= 9, 'SOQL bound: ' + queries);
    Assert.isTrue(dml <= 5, 'DML bound: ' + dml);
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Workflow_Instance__c WHERE Id IN :ids],
      'no instance remains'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Workflow_Signal__c WHERE Id IN :signals],
      'no signal remains'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Workflow_Log__c WHERE Id IN :logs],
      'no log remains'
    );
    Assert.isTrue(remainingDocs(docIds).isEmpty(), 'no engine file remains');
  }
}
