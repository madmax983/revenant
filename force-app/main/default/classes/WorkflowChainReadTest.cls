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

  private static WorkflowEngine.ChainRequest byId(
    Id instanceId,
    Integer pageSize,
    String cursor
  ) {
    WorkflowEngine.ChainRequest req = new WorkflowEngine.ChainRequest();
    req.instanceId = instanceId;
    req.pageSize = pageSize;
    req.cursor = cursor;
    return req;
  }

  private static WorkflowEngine.ChainRequest byKey(
    String key,
    Integer pageSize,
    String cursor
  ) {
    WorkflowEngine.ChainRequest req = new WorkflowEngine.ChainRequest();
    req.correlationKey = key;
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

  // Base64 JSON cursor with one field changed from a valid payload.
  private static String cursorWith(Id rowId, String field, Object value) {
    Map<String, Object> payload = new Map<String, Object>{
      'v' => 1,
      'a' => String.valueOf(rowId),
      'c' => Datetime.now().getTime(),
      'i' => String.valueOf(rowId),
      'g' => 1
    };
    payload.put(field, value);
    return EncodingUtil.base64Encode(Blob.valueOf(JSON.serialize(payload)));
  }

  private static Integer queriesFor(WorkflowEngine.ChainRequest req) {
    Integer q0 = Limits.getQueries();
    WorkflowChainRead.getChain(req);
    return Limits.getQueries() - q0;
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
      Assert.areEqual(gens[1].Id, live.previousInstanceId);
      Assert.isNotNull(live.startedAt);

      WorkflowEngine.ChainGeneration first = page.entries[2];
      Assert.areEqual(1, first.generation);
      Assert.areEqual('ContinuedAsNew', first.status);
      Assert.areEqual('ContinuedAsNew', first.outcome);
      Assert.isFalse(first.isTerminal, 'Same terminal set as getStatus');
      Assert.isNotNull(first.endedAt, 'Terminal_At__c is set on hand-off');
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

      List<Id> idHandles = new List<Id>{
        gens[0].Id,
        gens[1].Id,
        gens[3].Id,
        Id.valueOf(String.valueOf(gens[2].Id).left(15))
      };
      for (Id handle : idHandles) {
        WorkflowEngine.ChainPage page = WorkflowChainRead.getChain(handle);
        Assert.areEqual(expected, ids(page), 'Same chain from ' + handle);
        Assert.areEqual(4, page.totalCount, 'Same total from ' + handle);
        Assert.areEqual(4, page.entries[0].generation);
      }
      for (
        String key : new List<String>{
          'daemon',
          'DAEMON',
          ' daemon ',
          'daemon_run2',
          'daemon_run4'
        }
      ) {
        WorkflowEngine.ChainPage page = WorkflowChainRead.getChain(key);
        Assert.areEqual(expected, ids(page), 'Same chain from ' + key);
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
      // Space the rows so the order does not depend on Id order.
      Datetime base = Datetime.now().addHours(-1);
      Test.setCreatedDate(run1, base);
      Test.setCreatedDate(run2, base.addMinutes(1));
      Test.setCreatedDate(run3, base.addMinutes(2));

      List<Id> expected = new List<Id>{ run3, run2, run1 };
      for (Id handle : expected) {
        Assert.areEqual(
          expected,
          ids(WorkflowChainRead.getChain(handle)),
          'Same chain from ' + handle
        );
      }
      for (String key : new List<String>{ 'ChainDaemon', 'ChainDaemon_run2' }) {
        Assert.areEqual(
          expected,
          ids(WorkflowChainRead.getChain(key)),
          'Same chain from ' + key
        );
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
  static void compensationSuccessorIsAGeneration() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('undo', 2, 'Completed');
      // Same shape as WorkflowCompensation.buildCompensatingInstance.
      Workflow_Instance__c undo = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'Compensating',
        Correlation_Key__c = 'undo_run2',
        Root_Correlation_Key__c = 'undo',
        Previous_Instance__c = gens[1].Id
      );
      Database.insert(undo, AccessLevel.SYSTEM_MODE);
      Test.setCreatedDate(undo.Id, Datetime.now());

      WorkflowEngine.ChainPage page = WorkflowChainRead.getChain(gens[0].Id);

      Assert.areEqual(
        new List<Id>{ undo.Id, gens[1].Id, gens[0].Id },
        ids(page)
      );
      Assert.areEqual('Compensating', page.entries[0].status);
      Assert.areEqual(3, page.entries[0].generation);
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

  @IsTest
  static void windowWithNoStartInScopeHasNoLowerBound() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('orphan', 3);
      // The first generation moves out of scope.
      gens[0].Correlation_Key__c = 'moved';
      gens[0].Root_Correlation_Key__c = 'moved';
      Database.update(gens[0], AccessLevel.SYSTEM_MODE);

      WorkflowEngine.ChainPage page = WorkflowChainRead.getChain(gens[2].Id);

      Assert.areEqual(new List<Id>{ gens[2].Id, gens[1].Id }, ids(page));
      Assert.areEqual(2, page.totalCount);
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
      Assert.areEqual(1, queriesFor(byKey('solo', null, null)), 'By key');
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

  @IsTest
  static void cursorOnSingleGenerationGivesEmptyPage() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c solo = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'Completed',
        Correlation_Key__c = 'solo-cursor'
      );
      Database.insert(solo, AccessLevel.SYSTEM_MODE);
      solo = [
        SELECT Id, CreatedDate
        FROM Workflow_Instance__c
        WHERE Id = :solo.Id
      ];
      String cursor = WorkflowChainCursor.encode(solo.Id, solo, 1);

      WorkflowEngine.ChainPage page = WorkflowChainRead.getChain(
        byId(solo.Id, 2, cursor)
      );

      Assert.areEqual(0, page.entries.size());
      Assert.areEqual(1, page.totalCount);
      Assert.isFalse(page.hasMore);
    }
  }

  // ─── paging and bounds ───────────────────────────────────────────────────

  @IsTest
  static void pagesWithCursorWithoutGapsOrDuplicates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('paged', 5);

      WorkflowEngine.ChainPage p1 = WorkflowChainRead.getChain(
        byKey('paged', 2, null)
      );
      Assert.areEqual(new List<Id>{ gens[4].Id, gens[3].Id }, ids(p1));
      Assert.areEqual(5, p1.entries[0].generation);
      Assert.areEqual(4, p1.entries[1].generation);
      Assert.areEqual(5, p1.totalCount, 'Total is the whole chain');
      Assert.isTrue(p1.hasMore);
      Assert.areEqual(2, p1.pageSize);

      WorkflowEngine.ChainPage p2 = WorkflowChainRead.getChain(
        byKey('paged', 2, p1.nextCursor)
      );
      Assert.areEqual(new List<Id>{ gens[2].Id, gens[1].Id }, ids(p2));
      Assert.areEqual(3, p2.entries[0].generation);
      Assert.areEqual(2, p2.entries[1].generation);
      Assert.areEqual(5, p2.totalCount);
      Assert.isTrue(p2.hasMore);

      WorkflowEngine.ChainPage p3 = WorkflowChainRead.getChain(
        byId(gens[4].Id, 2, p2.nextCursor)
      );
      Assert.areEqual(new List<Id>{ gens[0].Id }, ids(p3));
      Assert.areEqual(1, p3.entries[0].generation);
      Assert.isFalse(p3.hasMore);
      Assert.isNull(p3.nextCursor);
    }
  }

  @IsTest
  static void fullPageWithNoMoreRowsHasNoCursor() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('full', 2);

      WorkflowEngine.ChainPage page = WorkflowChainRead.getChain(
        byId(gens[1].Id, 2, null)
      );

      Assert.areEqual(2, page.entries.size());
      Assert.isFalse(page.hasMore);
      Assert.isNull(page.nextCursor);
    }
  }

  @IsTest
  static void cursorKeepsTheChainWhenTheKeyIsUsedAgain() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> first = chain('again', 3, 'Completed');
      WorkflowEngine.ChainPage p1 = WorkflowChainRead.getChain(
        byKey('again', 2, null)
      );
      Assert.areEqual(new List<Id>{ first[2].Id, first[1].Id }, ids(p1));

      chain('again', 2, 'Running');
      WorkflowEngine.ChainPage p2 = WorkflowChainRead.getChain(
        byKey('again', 2, p1.nextCursor)
      );

      Assert.areEqual(new List<Id>{ first[0].Id }, ids(p2));
      Assert.areEqual(1, p2.entries[0].generation);
      Assert.areEqual(3, p2.totalCount, 'Total of the first chain');
    }
  }

  @IsTest
  static void queryCountIsConstantAndExact() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> shortChain = chain('short', 3);
      List<Workflow_Instance__c> longChain = chain('long', 30);

      Integer shortMiddle = queriesFor(byId(shortChain[1].Id, 2, null));
      Integer longMiddle = queriesFor(byId(longChain[10].Id, 2, null));
      Assert.areEqual(
        5,
        shortMiddle,
        'Middle: anchor, start, end, count, page'
      );
      Assert.areEqual(shortMiddle, longMiddle, 'Constant SOQL');
      Assert.areEqual(
        4,
        queriesFor(byId(longChain[29].Id, 2, null)),
        'Live: no end query'
      );
      Assert.areEqual(
        4,
        queriesFor(byKey('long', 2, null)),
        'Key gives the live row'
      );
      Assert.areEqual(
        4,
        queriesFor(byId(longChain[0].Id, 2, null)),
        'First: no start query'
      );

      WorkflowEngine.ChainPage page = WorkflowChainRead.getChain(
        byId(longChain[10].Id, 2, null)
      );
      Assert.areEqual(30, page.totalCount);
      Assert.areEqual(2, page.entries.size());
    }
  }

  @IsTest
  static void cappedTotalIsFlaggedAndHidesGenerationNumber() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('huge', 5);
      WorkflowChainRead.countCap = 3;

      WorkflowEngine.ChainPage page = WorkflowChainRead.getChain('huge');
      Assert.isTrue(page.isTotalCapped);
      Assert.areEqual(3, page.totalCount, 'The total is a lower bound');
      Assert.areEqual(5, page.entries.size(), 'The page is not capped');
      Assert.isNull(page.entries[0].generation, 'Number is not known');

      WorkflowEngine.ChainPage p1 = WorkflowChainRead.getChain(
        byKey('huge', 2, null)
      );
      WorkflowEngine.ChainPage p2 = WorkflowChainRead.getChain(
        byKey('huge', 2, p1.nextCursor)
      );
      WorkflowEngine.ChainPage p3 = WorkflowChainRead.getChain(
        byKey('huge', 2, p2.nextCursor)
      );
      List<Id> all = ids(p1);
      all.addAll(ids(p2));
      all.addAll(ids(p3));
      Assert.areEqual(newestFirst(gens), all, 'No gap, no duplicate');
      Assert.isNull(p2.entries[0].generation);
      Assert.isNull(p3.entries[0].generation);
      Assert.isFalse(p3.hasMore);
    }
  }

  @IsTest
  static void pageSizeIsDefaultedClampedAndValidated() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      chain('sized', 2);

      Assert.areEqual(
        WorkflowChainRead.DEFAULT_PAGE_SIZE,
        WorkflowChainRead.getChain(byKey('sized', null, null)).pageSize
      );
      Assert.areEqual(
        WorkflowChainRead.MAX_PAGE_SIZE,
        WorkflowChainRead.getChain(byKey('sized', 100000, null)).pageSize
      );
      Assert.areEqual(200, WorkflowChainRead.MAX_PAGE_SIZE);
      for (Integer bad : new List<Integer>{ 0, -1 }) {
        try {
          WorkflowChainRead.getChain(byKey('sized', bad, null));
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
      List<Workflow_Instance__c> gens = chain('cursor', 2);
      Id rowId = gens[0].Id;
      List<String> bad = new List<String>{
        'not-a-cursor',
        EncodingUtil.base64Encode(Blob.valueOf('v1|1|2|3')),
        cursorWith(rowId, 'v', 2),
        cursorWith(rowId, 'i', UserInfo.getUserId()),
        cursorWith(rowId, 'a', 'nope'),
        cursorWith(rowId, 'g', 0),
        cursorWith(rowId, 'c', -1),
        cursorWith(rowId, 'c', null)
      };
      for (String value : bad) {
        try {
          WorkflowChainRead.getChain(byKey('cursor', 2, value));
          Assert.fail('Expected WorkflowException for ' + value);
        } catch (WorkflowEngine.WorkflowException e) {
          Assert.isTrue(e.getMessage().contains('cursor'), e.getMessage());
        }
      }
      Assert.isNotNull(
        WorkflowChainRead.getChain(
          byKey('cursor', 2, cursorWith(rowId, 'g', null))
        ),
        'A null generation is valid'
      );
    }
  }

  // ─── input ───────────────────────────────────────────────────────────────

  @IsTest
  static void unknownOrBlankInputReturnsNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.isNull(WorkflowChainRead.getChain('no-such-key'));
      Assert.isNull(WorkflowChainRead.getChain(unknownInstanceId()));
      Assert.isNull(WorkflowChainRead.getChain(UserInfo.getUserId()));
      Assert.isNull(WorkflowChainRead.getChain(''));
      Assert.isNull(WorkflowChainRead.getChain((String) null));
      Assert.isNull(WorkflowChainRead.getChain((Id) null));
      Assert.isNull(
        WorkflowChainRead.getChain((WorkflowEngine.ChainRequest) null)
      );
      Assert.isNull(
        WorkflowChainRead.getChain(new WorkflowEngine.ChainRequest())
      );
    }
  }

  @IsTest
  static void idShapedKeyResolvesAsKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // A key that looks like an instance Id is still a key.
      String idShapedKey = String.valueOf(unknownInstanceId()).left(15);
      Workflow_Instance__c inst = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'Running',
        Correlation_Key__c = idShapedKey
      );
      Database.insert(inst, AccessLevel.SYSTEM_MODE);

      Assert.areEqual(
        new List<Id>{ inst.Id },
        ids(WorkflowChainRead.getChain(idShapedKey))
      );
    }
  }

  @IsTest
  static void idAndKeyTogetherThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('both', 2);
      WorkflowEngine.ChainRequest req = byId(gens[0].Id, null, null);
      req.correlationKey = 'both';
      try {
        WorkflowChainRead.getChain(req);
        Assert.fail('Expected WorkflowException');
      } catch (WorkflowEngine.WorkflowException e) {
        Assert.isTrue(e.getMessage().contains('not both'), e.getMessage());
      }
    }
  }

  // ─── read-only ───────────────────────────────────────────────────────────

  @IsTest
  static void readChangesNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> gens = chain('readonly', 3);
      Workflow_Instance__c solo = new Workflow_Instance__c(
        Workflow_Name__c = WF,
        Status__c = 'Completed',
        Correlation_Key__c = 'readonly-solo'
      );
      Database.insert(solo, AccessLevel.SYSTEM_MODE);
      Map<Id, Workflow_Instance__c> before = new Map<Id, Workflow_Instance__c>(
        [
          SELECT Id, Status__c, Previous_Instance__c, SystemModstamp
          FROM Workflow_Instance__c
        ]
      );
      Integer stepRows = [SELECT COUNT() FROM Workflow_Step_Execution__c];

      Integer dml0 = Limits.getDmlStatements();
      Integer rows0 = Limits.getDmlRows();
      Integer jobs0 = Limits.getQueueableJobs();
      Integer futures0 = Limits.getFutureCalls();
      Integer events0 = Limits.getPublishImmediateDML();
      WorkflowEngine.ChainPage p1 = WorkflowChainRead.getChain(
        byId(gens[1].Id, 2, null)
      );
      WorkflowChainRead.getChain(byId(gens[1].Id, 2, p1.nextCursor));
      WorkflowChainRead.getChain(solo.Id);
      WorkflowChainRead.getChain('readonly');

      Assert.areEqual(dml0, Limits.getDmlStatements(), 'No DML');
      Assert.areEqual(rows0, Limits.getDmlRows(), 'No DML rows');
      Assert.areEqual(jobs0, Limits.getQueueableJobs(), 'No enqueue');
      Assert.areEqual(futures0, Limits.getFutureCalls(), 'No future call');
      Assert.areEqual(events0, Limits.getPublishImmediateDML(), 'No event');
      for (Workflow_Instance__c row : [
        SELECT Id, Status__c, Previous_Instance__c, SystemModstamp
        FROM Workflow_Instance__c
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
