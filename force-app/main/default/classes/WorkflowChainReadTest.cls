@IsTest
private class WorkflowChainReadTest {
  private static final String WF = 'WorkflowChainReadTest.StubWorkflow';

  // ─── helpers ─────────────────────────────────────────────────────────────

  // Each chain starts one hour after the chain before it.
  private static Datetime nextBase = Datetime.now().addDays(-2);

  // Inserts a linked chain. Keys: root, root_run2, ... The last row gets
  // lastStatus; the others get ContinuedAsNew. CreatedDate goes up one minute
  // for each generation.
  private static List<Workflow_Instance__c> chain(
    String root,
    Integer size,
    String lastStatus
  ) {
    Datetime base = nextBase;
    nextBase = nextBase.addHours(1);
    List<Workflow_Instance__c> gens = new List<Workflow_Instance__c>();
    for (Integer i = 1; i <= size; i++) {
      gens.add(
        new Workflow_Instance__c(
          Workflow_Name__c = WF,
          Status__c = i == size ? lastStatus : 'ContinuedAsNew',
          Correlation_Key__c = i == 1 ? root : root + '_run' + i,
          Root_Correlation_Key__c = root
        )
      );
    }
    Database.insert(gens, AccessLevel.SYSTEM_MODE);
    for (Integer i = 1; i < size; i++) {
      gens[i].Previous_Instance__c = gens[i - 1].Id;
    }
    Database.update(gens, AccessLevel.SYSTEM_MODE);
    for (Integer i = 0; i < size; i++) {
      Test.setCreatedDate(gens[i].Id, base.addMinutes(i));
    }
    return gens;
  }

  private static List<Workflow_Instance__c> chain(String root, Integer size) {
    return chain(root, size, 'Running');
  }

  private static List<Id> ids(WorkflowEngine.ChainPage page) {
    List<Id> out = new List<Id>();
    for (WorkflowEngine.ChainGeneration g : page.entries) {
      out.add(g.instanceId);
    }
    return out;
  }

  // Ids of the rows, newest first.
  private static List<Id> newestFirst(List<Workflow_Instance__c> gens) {
    List<Id> out = new List<Id>();
    for (Integer i = gens.size() - 1; i >= 0; i--) {
      out.add(gens[i].Id);
    }
    return out;
  }

  private static WorkflowEngine.ChainRequest request(
    String keyOrId,
    Integer pageSize,
    String cursor
  ) {
    WorkflowEngine.ChainRequest req = new WorkflowEngine.ChainRequest();
    req.keyOrId = keyOrId;
    req.pageSize = pageSize;
    req.cursor = cursor;
    return req;
  }

  private static Id unknownInstanceId() {
    return (Id) (Workflow_Instance__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix() + '000000000001');
  }

  // ─── shape and order ─────────────────────────────────────────────────────

  @IsTest
  static void returnsGenerationsNewestFirstWithFields() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('poller', 3);

      WorkflowEngine.ChainPage page = WorkflowChainRead.getChain('poller');

      Assert.areEqual(newestFirst(gens), ids(page), 'Newest first');
      Assert.areEqual(3, page.totalCount);
      Assert.isFalse(page.isTotalCapped);
      Assert.isFalse(page.hasMore);
      Assert.isNull(page.nextCursor);
      Assert.areEqual(WorkflowChainRead.DEFAULT_PAGE_SIZE, page.pageSize);
      Assert.areEqual('poller', page.rootCorrelationKey);

      WorkflowEngine.ChainGeneration live = page.entries[0];
      Assert.areEqual(3, live.generation);
      Assert.areEqual('Running', live.status);
      Assert.areEqual('poller_run3', live.correlationKey);
      Assert.areEqual(WF, live.definitionName);
      Assert.isNotNull(live.instanceName, 'Auto-number name');
      Assert.isFalse(live.isTerminal);
      Assert.isNull(live.outcome, 'A live generation has no outcome');
      Assert.isNull(live.endedAt);
      Assert.isNull(live.continuedAt);
      Assert.areEqual(gens[1].Id, live.previousInstanceId);
      Assert.isNotNull(live.startedAt);

      WorkflowEngine.ChainGeneration first = page.entries[2];
      Assert.areEqual(1, first.generation);
      Assert.areEqual('ContinuedAsNew', first.status);
      Assert.areEqual('ContinuedAsNew', first.outcome);
      Assert.isFalse(first.isTerminal, 'Same terminal set as getStatus');
      Assert.isNotNull(first.endedAt, 'Terminal_At__c is set on hand-off');
      Assert.areEqual(first.endedAt, first.continuedAt);
      Assert.isNull(first.previousInstanceId);
      Assert.isTrue(first.startedAt < live.startedAt);
    }
  }

  @IsTest
  static void terminalGenerationCarriesOutcomeAndFailure() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('failing', 2, 'Failed');
      gens[1].Failure_Category__c = 'TIMEOUT';
      gens[1].Error_Message__c = 'Step timed out';
      Database.update(gens[1], AccessLevel.SYSTEM_MODE);

      WorkflowEngine.ChainGeneration last = WorkflowChainRead.getChain(
          gens[0].Id
        )
        .entries[0];

      Assert.areEqual('Failed', last.outcome);
      Assert.isTrue(last.isTerminal);
      Assert.isNotNull(last.endedAt);
      Assert.isNull(last.continuedAt, 'Only a hand-off has continuedAt');
      Assert.areEqual('TIMEOUT', last.failureCategory);
      Assert.areEqual('Step timed out', last.errorMessage);
    }
  }

  // ─── any member resolves the same chain ─────────────────────────────────

  @IsTest
  static void anyMemberResolvesSameChain() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('daemon', 4);
      List<Id> expected = newestFirst(gens);

      List<String> handles = new List<String>{
        'daemon',
        'DAEMON',
        'daemon_run2',
        'daemon_run4',
        gens[0].Id,
        gens[2].Id,
        gens[3].Id,
        String.valueOf(gens[1].Id).left(15)
      };
      for (String handle : handles) {
        WorkflowEngine.ChainPage page = WorkflowChainRead.getChain(handle);
        Assert.areEqual(expected, ids(page), 'Same chain from ' + handle);
        Assert.areEqual(4, page.totalCount, 'Same total from ' + handle);
        Assert.areEqual(4, page.entries[0].generation);
      }
    }
  }

  @IsTest
  static void resolvesEngineBuiltChainFromEachMember() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id run1 = WorkflowEngine.start(
        'WorkflowEngineMocksBTest.DaemonWorkflow',
        'ChainDaemon',
        0
      );
      new WorkflowOrchestrator(run1).execute(null);
      Id run2 = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :run1
      ]
      .Id;
      new WorkflowOrchestrator(run2).execute(null);
      Id run3 = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE Previous_Instance__c = :run2
      ]
      .Id;
      new WorkflowOrchestrator(run3).execute(null);

      List<Id> expected = new List<Id>{ run3, run2, run1 };
      for (
        String handle : new List<String>{
          'ChainDaemon',
          'ChainDaemon_run2',
          run1,
          run2,
          run3
        }
      ) {
        WorkflowEngine.ChainPage page = WorkflowChainRead.getChain(handle);
        Assert.areEqual(expected, ids(page), 'Same chain from ' + handle);
      }
      WorkflowEngine.ChainPage page = WorkflowChainRead.getChain(run2);
      Assert.areEqual('Completed', page.entries[0].outcome);
      Assert.areEqual('ContinuedAsNew', page.entries[1].outcome);
      Assert.areEqual(1, page.entries[2].generation);
    }
  }

  // ─── membership edges ────────────────────────────────────────────────────

  @IsTest
  static void independentRunWithSameKeyIsSeparateChain() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> older = chain('reused', 2, 'Completed');
      List<Workflow_Instance__c> newer = chain('reused', 3, 'Running');

      Assert.areEqual(
        newestFirst(older),
        ids(WorkflowChainRead.getChain(older[1].Id)),
        'Older chain stops before the new first generation'
      );
      Assert.areEqual(
        newestFirst(older),
        ids(WorkflowChainRead.getChain(older[0].Id))
      );
      Assert.areEqual(
        newestFirst(newer),
        ids(WorkflowChainRead.getChain(newer[0].Id)),
        'Newer chain starts at its own first generation'
      );
      Assert.areEqual(
        newestFirst(newer),
        ids(WorkflowChainRead.getChain('reused')),
        'The key resolves to the newest chain'
      );
      Assert.areEqual(3, WorkflowChainRead.getChain(newer[1].Id).totalCount);
    }
  }

  @IsTest
  static void otherWorkflowWithSameRootIsExcluded() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('shared', 2);
      Workflow_Instance__c other = new Workflow_Instance__c(
        Workflow_Name__c = 'WorkflowChainReadTest.OtherWorkflow',
        Status__c = 'Completed',
        Correlation_Key__c = 'shared_other',
        Root_Correlation_Key__c = 'shared',
        Previous_Instance__c = gens[1].Id
      );
      Database.insert(other, AccessLevel.SYSTEM_MODE);

      Assert.areEqual(
        newestFirst(gens),
        ids(WorkflowChainRead.getChain(gens[0].Id))
      );
    }
  }

  @IsTest
  static void legacyBlankRootPredecessorIsInChain() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('legacy', 2);
      gens[0].Root_Correlation_Key__c = null;
      Database.update(gens[0], AccessLevel.SYSTEM_MODE);

      Assert.areEqual(
        newestFirst(gens),
        ids(WorkflowChainRead.getChain(gens[1].Id))
      );
      Assert.areEqual(
        newestFirst(gens),
        ids(WorkflowChainRead.getChain(gens[0].Id))
      );
    }
  }

  // ─── single generation ───────────────────────────────────────────────────

  @IsTest
  static void singleGenerationReturnsOneEntryInOneQuery() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c solo = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'Completed',
        Correlation_Key__c = 'solo'
      );
      Database.insert(solo, AccessLevel.SYSTEM_MODE);

      Integer q0 = Limits.getQueries();
      WorkflowEngine.ChainPage page = WorkflowChainRead.getChain(solo.Id);
      Integer used = Limits.getQueries() - q0;

      Assert.areEqual(1, used, 'A single generation costs one query');
      Assert.areEqual(new List<Id>{ solo.Id }, ids(page));
      Assert.areEqual(1, page.totalCount);
      Assert.areEqual(1, page.entries[0].generation);
      Assert.areEqual('Completed', page.entries[0].outcome);
      Assert.isFalse(page.hasMore);
    }
  }

  @IsTest
  static void blankKeyInstanceReturnsOneEntry() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c keyless = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'Running'
      );
      Database.insert(keyless, AccessLevel.SYSTEM_MODE);

      WorkflowEngine.ChainPage page = WorkflowChainRead.getChain(keyless.Id);

      Assert.areEqual(new List<Id>{ keyless.Id }, ids(page));
      Assert.isNull(page.rootCorrelationKey);
    }
  }

  // ─── paging and bounds ───────────────────────────────────────────────────

  @IsTest
  static void pagesWithCursorWithoutGapsOrDuplicates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('paged', 5);

      WorkflowEngine.ChainPage p1 = WorkflowChainRead.getChain(
        request('paged', 2, null)
      );
      Assert.areEqual(new List<Id>{ gens[4].Id, gens[3].Id }, ids(p1));
      Assert.areEqual(5, p1.entries[0].generation);
      Assert.areEqual(4, p1.entries[1].generation);
      Assert.areEqual(5, p1.totalCount, 'Total is the whole chain');
      Assert.isTrue(p1.hasMore);
      Assert.areEqual(2, p1.pageSize);

      WorkflowEngine.ChainPage p2 = WorkflowChainRead.getChain(
        request('paged', 2, p1.nextCursor)
      );
      Assert.areEqual(new List<Id>{ gens[2].Id, gens[1].Id }, ids(p2));
      Assert.areEqual(3, p2.entries[0].generation);
      Assert.areEqual(2, p2.entries[1].generation);
      Assert.areEqual(5, p2.totalCount);
      Assert.isTrue(p2.hasMore);

      WorkflowEngine.ChainPage p3 = WorkflowChainRead.getChain(
        request(gens[4].Id, 2, p2.nextCursor)
      );
      Assert.areEqual(new List<Id>{ gens[0].Id }, ids(p3));
      Assert.areEqual(1, p3.entries[0].generation);
      Assert.isFalse(p3.hasMore);
      Assert.isNull(p3.nextCursor);
    }
  }

  @IsTest
  static void queryCountDoesNotGrowWithChainLength() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> shortChain = chain('short', 3);
      List<Workflow_Instance__c> longChain = chain('long', 30);

      Integer q0 = Limits.getQueries();
      WorkflowChainRead.getChain(request(shortChain[1].Id, 2, null));
      Integer shortCost = Limits.getQueries() - q0;

      Integer q1 = Limits.getQueries();
      WorkflowEngine.ChainPage page = WorkflowChainRead.getChain(
        request(longChain[10].Id, 2, null)
      );
      Integer longCost = Limits.getQueries() - q1;

      Assert.areEqual(shortCost, longCost, 'Constant SOQL');
      Assert.isTrue(longCost <= 6, 'Max 6 queries, was ' + longCost);
      Assert.areEqual(30, page.totalCount);
      Assert.areEqual(2, page.entries.size());
    }
  }

  @IsTest
  static void cappedTotalIsFlaggedAndHidesGenerationNumber() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      chain('huge', 5);
      WorkflowChainRead.countCap = 3;

      WorkflowEngine.ChainPage page = WorkflowChainRead.getChain('huge');

      Assert.isTrue(page.isTotalCapped);
      Assert.areEqual(3, page.totalCount, 'The total is a lower bound');
      Assert.areEqual(5, page.entries.size(), 'The page is not capped');
      Assert.isNull(page.entries[0].generation, 'Number is not known');
    }
  }

  @IsTest
  static void pageSizeIsDefaultedClampedAndValidated() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      chain('sized', 2);

      Assert.areEqual(
        WorkflowChainRead.MAX_PAGE_SIZE,
        WorkflowChainRead.getChain(request('sized', 100000, null)).pageSize
      );
      Assert.areEqual(200, WorkflowChainRead.MAX_PAGE_SIZE);
      for (Integer bad : new List<Integer>{ 0, -1 }) {
        try {
          WorkflowChainRead.getChain(request('sized', bad, null));
          Assert.fail('Expected WorkflowException for ' + bad);
        } catch (WorkflowEngine.WorkflowException e) {
          Assert.isTrue(e.getMessage().contains('pageSize'), e.getMessage());
        }
      }
    }
  }

  @IsTest
  static void malformedCursorThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      chain('cursor', 2);
      for (
        String bad : new List<String>{
          'not-a-cursor',
          EncodingUtil.base64Encode(Blob.valueOf('v1|x|y|z')),
          EncodingUtil.base64Encode(Blob.valueOf('v9|1|a0G000000000001|1'))
        }
      ) {
        try {
          WorkflowChainRead.getChain(request('cursor', 2, bad));
          Assert.fail('Expected WorkflowException for ' + bad);
        } catch (WorkflowEngine.WorkflowException e) {
          Assert.isTrue(e.getMessage().contains('cursor'), e.getMessage());
        }
      }
    }
  }

  // ─── unknown input ───────────────────────────────────────────────────────

  @IsTest
  static void unknownOrBlankInputReturnsNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.isNull(WorkflowChainRead.getChain('no-such-key'));
      Assert.isNull(WorkflowChainRead.getChain(unknownInstanceId()));
      Assert.isNull(WorkflowChainRead.getChain(''));
      Assert.isNull(WorkflowChainRead.getChain((String) null));
      Assert.isNull(
        WorkflowChainRead.getChain((WorkflowEngine.ChainRequest) null)
      );
    }
  }

  // ─── read-only ───────────────────────────────────────────────────────────

  @IsTest
  static void readChangesNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('readonly', 3);
      Map<Id, Workflow_Instance__c> before = new Map<Id, Workflow_Instance__c>(
        [
          SELECT Id, Status__c, Previous_Instance__c, SystemModstamp
          FROM Workflow_Instance__c
          WHERE Id IN :gens
        ]
      );
      Integer stepRows = [SELECT COUNT() FROM Workflow_Step_Execution__c];

      Integer dml0 = Limits.getDmlStatements();
      Integer jobs0 = Limits.getQueueableJobs();
      Integer events0 = Limits.getPublishImmediateDML();
      WorkflowChainRead.getChain(request(gens[1].Id, 2, null));

      Assert.areEqual(dml0, Limits.getDmlStatements(), 'No DML');
      Assert.areEqual(jobs0, Limits.getQueueableJobs(), 'No enqueue');
      Assert.areEqual(events0, Limits.getPublishImmediateDML(), 'No event');
      for (Workflow_Instance__c row : [
        SELECT Id, Status__c, Previous_Instance__c, SystemModstamp
        FROM Workflow_Instance__c
        WHERE Id IN :gens
      ]) {
        Workflow_Instance__c old = before.get(row.Id);
        Assert.areEqual(old.Status__c, row.Status__c);
        Assert.areEqual(old.Previous_Instance__c, row.Previous_Instance__c);
        Assert.areEqual(old.SystemModstamp, row.SystemModstamp);
      }
      Assert.areEqual(
        stepRows,
        [SELECT COUNT() FROM Workflow_Step_Execution__c]
      );
    }
  }
}
