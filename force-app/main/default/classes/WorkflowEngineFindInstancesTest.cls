@IsTest
private class WorkflowEngineFindInstancesTest {
  // ─── helpers ─────────────────────────────────────────────────────────────

  private static final String DEF_A = 'WorkflowEngineFindInstancesTest.DefinitionA';
  private static final String DEF_B = 'WorkflowEngineFindInstancesTest.DefinitionB';

  // Inserts a workflow instance and returns it. All DML runs in system mode so the
  // test never depends on the running user's object/field permissions.
  private static Workflow_Instance__c newInstance(
    String definitionName,
    String correlationKey,
    String status
  ) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = definitionName,
      Status__c = status,
      Correlation_Key__c = correlationKey
    );
    Database.insert(inst, AccessLevel.SYSTEM_MODE);
    return inst;
  }

  // Builds a criteria with an explicit page size (helper keeps tests terse).
  private static WorkflowEngine.InstanceCriteria criteriaFor(
    String definitionName,
    Integer pageSize
  ) {
    WorkflowEngine.InstanceCriteria c = new WorkflowEngine.InstanceCriteria();
    c.definitionName = definitionName;
    c.pageSize = pageSize;
    return c;
  }

  // ─── filter by definitionName ─────────────────────────────────────────────

  @IsTest
  static void testFilterByDefinitionName() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      newInstance(DEF_A, 'a-1', 'Running');
      newInstance(DEF_A, 'a-2', 'Completed');
      newInstance(DEF_B, 'b-1', 'Running');

      Test.startTest();
      WorkflowEngine.InstancePage page = WorkflowInstanceQuery.findInstances(
        criteriaFor(DEF_A, null)
      );
      Test.stopTest();

      System.assertEquals(
        2,
        page.entries.size(),
        'Only DefinitionA rows match'
      );
      for (WorkflowEngine.WorkflowInstanceSummary s : page.entries) {
        System.assertEquals(
          DEF_A,
          s.definitionName,
          'Every returned row is DefinitionA'
        );
      }
      System.assertEquals(false, page.hasMore, 'Single page fits the default');
      System.assertEquals(null, page.nextCursor, 'Last page has null cursor');
    }
  }

  // ─── filter by status set ─────────────────────────────────────────────────

  @IsTest
  static void testFilterByStatusSet() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      newInstance(DEF_A, 'r-1', 'Running');
      newInstance(DEF_A, 'f-1', 'Failed');
      newInstance(DEF_A, 'c-1', 'Completed');

      WorkflowEngine.InstanceCriteria c = criteriaFor(DEF_A, null);
      c.statuses = new Set<String>{ 'Running', 'Failed' };

      Test.startTest();
      WorkflowEngine.InstancePage page = WorkflowInstanceQuery.findInstances(c);
      Test.stopTest();

      System.assertEquals(
        2,
        page.entries.size(),
        'Only Running + Failed match the status set'
      );
      Set<String> statuses = new Set<String>();
      for (WorkflowEngine.WorkflowInstanceSummary s : page.entries) {
        statuses.add(s.status);
      }
      System.assertEquals(
        new Set<String>{ 'Running', 'Failed' },
        statuses,
        'Completed is excluded by the status filter'
      );
    }
  }

  // ─── created-time window ──────────────────────────────────────────────────

  @IsTest
  static void testCreatedWindow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c older = newInstance(DEF_A, 'old', 'Running');
      Workflow_Instance__c newer = newInstance(DEF_A, 'new', 'Running');
      Test.setCreatedDate(older.Id, Datetime.now().addDays(-10));
      Test.setCreatedDate(newer.Id, Datetime.now().addDays(-1));

      WorkflowEngine.InstanceCriteria c = criteriaFor(DEF_A, null);
      c.createdAfter = Datetime.now().addDays(-5);
      c.createdBefore = Datetime.now();

      Test.startTest();
      WorkflowEngine.InstancePage page = WorkflowInstanceQuery.findInstances(c);
      Test.stopTest();

      System.assertEquals(
        1,
        page.entries.size(),
        'Only the instance created inside the window matches'
      );
      System.assertEquals(
        'new',
        page.entries[0].correlationKey,
        'The 1-day-old instance is inside the 5-day window'
      );
    }
  }

  // ─── modified-time window ─────────────────────────────────────────────────

  @IsTest
  static void testModifiedWindow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      newInstance(DEF_A, 'm-1', 'Running');
      newInstance(DEF_A, 'm-2', 'Running');

      // LastModifiedDate is set on insert and cannot be back-dated in a test, so a
      // window bracketing "now" matches all just-inserted rows, and a window that
      // ends in the past matches none — enough to prove the predicate wiring.
      WorkflowEngine.InstanceCriteria matchAll = criteriaFor(DEF_A, null);
      matchAll.modifiedAfter = Datetime.now().addMinutes(-5);
      matchAll.modifiedBefore = Datetime.now().addMinutes(5);

      WorkflowEngine.InstanceCriteria matchNone = criteriaFor(DEF_A, null);
      matchNone.modifiedBefore = Datetime.now().addYears(-1);

      Test.startTest();
      WorkflowEngine.InstancePage all = WorkflowInstanceQuery.findInstances(
        matchAll
      );
      WorkflowEngine.InstancePage none = WorkflowInstanceQuery.findInstances(
        matchNone
      );
      Test.stopTest();

      System.assertEquals(
        2,
        all.entries.size(),
        'Window bracketing now matches both just-modified rows'
      );
      System.assertEquals(
        0,
        none.entries.size(),
        'Window ending a year ago matches nothing'
      );
    }
  }

  // ─── combined criteria ────────────────────────────────────────────────────

  @IsTest
  static void testCombinedCriteria() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c hit = newInstance(DEF_A, 'hit', 'Running');
      newInstance(DEF_A, 'wrong-status', 'Completed');
      newInstance(DEF_B, 'wrong-def', 'Running');
      Workflow_Instance__c outOfWindow = newInstance(DEF_A, 'old', 'Running');
      Test.setCreatedDate(outOfWindow.Id, Datetime.now().addDays(-30));

      WorkflowEngine.InstanceCriteria c = criteriaFor(DEF_A, null);
      c.statuses = new Set<String>{ 'Running' };
      c.createdAfter = Datetime.now().addDays(-2);

      Test.startTest();
      WorkflowEngine.InstancePage page = WorkflowInstanceQuery.findInstances(c);
      Test.stopTest();

      System.assertEquals(
        1,
        page.entries.size(),
        'Only the row matching all three predicates is returned'
      );
      System.assertEquals(
        hit.Id,
        page.entries[0].instanceId,
        'The combined-criteria winner is the expected instance'
      );
    }
  }

  // ─── empty result ─────────────────────────────────────────────────────────

  @IsTest
  static void testEmptyResult() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      newInstance(DEF_A, 'a-1', 'Running');

      Test.startTest();
      WorkflowEngine.InstancePage page = WorkflowInstanceQuery.findInstances(
        criteriaFor('Nonexistent.Definition', null)
      );
      Test.stopTest();

      System.assertEquals(
        0,
        page.entries.size(),
        'No matches -> empty entries'
      );
      System.assertEquals(false, page.hasMore, 'Empty page has no more pages');
      System.assertEquals(null, page.nextCursor, 'Empty page has null cursor');
    }
  }

  // ─── null criteria matches all, first page ────────────────────────────────

  @IsTest
  static void testNullCriteriaMatchesAll() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      newInstance(DEF_A, 'a-1', 'Running');
      newInstance(DEF_B, 'b-1', 'Completed');

      Test.startTest();
      WorkflowEngine.InstancePage page = WorkflowInstanceQuery.findInstances(
        null
      );
      Test.stopTest();

      System.assertEquals(
        2,
        page.entries.size(),
        'Null criteria matches every instance'
      );
      System.assertEquals(
        WorkflowInstanceQuery.DEFAULT_PAGE_SIZE,
        page.pageSize,
        'Null criteria uses the default page size'
      );
    }
  }

  // ─── pagination across multiple pages (deep-page correctness) ─────────────

  @IsTest
  static void testPaginationAcrossPages() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Five instances with strictly distinct, descending CreatedDates so the
      // newest-first ordering is deterministic (t-10 newest ... t-50 oldest).
      List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>();
      for (Integer i = 1; i <= 5; i++) {
        insts.add(newInstance(DEF_A, 'p-' + i, 'Running'));
      }
      Test.setCreatedDate(insts[0].Id, Datetime.now().addMinutes(-10));
      Test.setCreatedDate(insts[1].Id, Datetime.now().addMinutes(-20));
      Test.setCreatedDate(insts[2].Id, Datetime.now().addMinutes(-30));
      Test.setCreatedDate(insts[3].Id, Datetime.now().addMinutes(-40));
      Test.setCreatedDate(insts[4].Id, Datetime.now().addMinutes(-50));

      Test.startTest();
      // Page size 2 over 5 rows -> pages of 2, 2, 1.
      List<Id> walked = new List<Id>();
      List<Datetime> createdSeq = new List<Datetime>();
      String cursor = null;
      Integer pages = 0;
      WorkflowEngine.InstancePage page;
      do {
        WorkflowEngine.InstanceCriteria c = criteriaFor(DEF_A, 2);
        c.cursor = cursor;
        page = WorkflowInstanceQuery.findInstances(c);
        for (WorkflowEngine.WorkflowInstanceSummary s : page.entries) {
          walked.add(s.instanceId);
          createdSeq.add(s.createdAt);
        }
        cursor = page.nextCursor;
        pages++;
      } while (page.hasMore && pages < 10);
      Test.stopTest();

      System.assertEquals(
        3,
        pages,
        'Five rows at pageSize 2 span exactly 3 pages'
      );
      System.assertEquals(
        null,
        page.nextCursor,
        'The final page has a null cursor'
      );
      System.assertEquals(
        false,
        page.hasMore,
        'The final page reports no more pages'
      );
      System.assertEquals(5, walked.size(), 'Every row is visited once');
      System.assertEquals(
        5,
        new Set<Id>(walked).size(),
        'No duplicates and no gaps across pages'
      );
      // Ordering is strictly newest-first and monotonically non-increasing.
      System.assertEquals(
        insts[0].Id,
        walked[0],
        'Newest (t-10) instance comes first'
      );
      System.assertEquals(
        insts[4].Id,
        walked[4],
        'Oldest (t-50) instance comes last'
      );
      for (Integer i = 1; i < createdSeq.size(); i++) {
        System.assert(
          createdSeq[i] <= createdSeq[i - 1],
          'CreatedDate is non-increasing across the walk (stable ordering)'
        );
      }
    }
  }

  // ─── page-size default + ceiling clamp ────────────────────────────────────

  @IsTest
  static void testPageSizeDefaultAndClamp() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      newInstance(DEF_A, 'a-1', 'Running');

      Test.startTest();
      // Null -> default.
      WorkflowEngine.InstancePage def = WorkflowInstanceQuery.findInstances(
        criteriaFor(DEF_A, null)
      );
      // Above the cap -> clamped to MAX_PAGE_SIZE (no throw).
      WorkflowEngine.InstancePage clamped = WorkflowInstanceQuery.findInstances(
        criteriaFor(DEF_A, WorkflowInstanceQuery.MAX_PAGE_SIZE + 500)
      );
      Test.stopTest();

      System.assertEquals(
        WorkflowInstanceQuery.DEFAULT_PAGE_SIZE,
        def.pageSize,
        'Null pageSize resolves to the default'
      );
      System.assertEquals(
        WorkflowInstanceQuery.MAX_PAGE_SIZE,
        clamped.pageSize,
        'Over-cap pageSize is clamped to MAX_PAGE_SIZE'
      );
    }
  }

  // ─── page-size non-positive throws ────────────────────────────────────────

  @IsTest
  static void testPageSizeNonPositiveThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Boolean threw = false;
      try {
        WorkflowInstanceQuery.findInstances(criteriaFor(DEF_A, 0));
      } catch (WorkflowEngine.WorkflowException ex) {
        threw = true;
        System.assert(
          ex.getMessage()
            .contains(String.valueOf(WorkflowInstanceQuery.MAX_PAGE_SIZE)),
          'Message names the cap: ' + ex.getMessage()
        );
      }
      System.assertEquals(
        true,
        threw,
        'A non-positive pageSize throws WorkflowEngine.WorkflowException'
      );
    }
  }

  // ─── invalid / garbage cursor throws ──────────────────────────────────────

  @IsTest
  static void testInvalidCursorThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.InstanceCriteria c = criteriaFor(DEF_A, null);
      c.cursor = 'not-a-valid-cursor';

      Boolean threw = false;
      try {
        WorkflowInstanceQuery.findInstances(c);
      } catch (WorkflowEngine.WorkflowException ex) {
        threw = true;
        System.assert(
          ex.getMessage().contains('cursor'),
          'Message explains the cursor is invalid: ' + ex.getMessage()
        );
      }
      System.assertEquals(
        true,
        threw,
        'A garbage cursor throws WorkflowEngine.WorkflowException'
      );
    }
  }

  // ─── cursor round-trips verbatim ──────────────────────────────────────────

  @IsTest
  static void testCursorRoundTripsVerbatim() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      newInstance(DEF_A, 'a-1', 'Running');
      newInstance(DEF_A, 'a-2', 'Running');
      newInstance(DEF_A, 'a-3', 'Running');

      Test.startTest();
      WorkflowEngine.InstancePage first = WorkflowInstanceQuery.findInstances(
        criteriaFor(DEF_A, 1)
      );
      System.assertEquals(1, first.entries.size(), 'First page holds one row');
      System.assertNotEquals(
        null,
        first.nextCursor,
        'A further page yields a non-null cursor'
      );

      // Passing the opaque cursor back verbatim advances to the next row.
      WorkflowEngine.InstanceCriteria second = criteriaFor(DEF_A, 1);
      second.cursor = first.nextCursor;
      WorkflowEngine.InstancePage page2 = WorkflowInstanceQuery.findInstances(
        second
      );
      Test.stopTest();

      System.assertEquals(1, page2.entries.size(), 'Second page holds one row');
      System.assertNotEquals(
        first.entries[0].instanceId,
        page2.entries[0].instanceId,
        'The cursor advanced past the first page row (no overlap)'
      );
    }
  }

  // ─── ContinueAsNew stance (consistent with getStatus) ─────────────────────

  @IsTest
  static void testContinuedAsNewStance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      newInstance(DEF_A, 'live', 'Running');
      Workflow_Instance__c handoff = newInstance(
        DEF_A,
        'chain',
        'ContinuedAsNew'
      );

      // Default (no status filter) enumerates the ContinuedAsNew row as its own
      // row, and it is NOT terminal (consistent with getStatus's hand-off stance).
      WorkflowEngine.InstancePage all = WorkflowInstanceQuery.findInstances(
        criteriaFor(DEF_A, null)
      );
      WorkflowEngine.WorkflowInstanceSummary handoffSummary = null;
      for (WorkflowEngine.WorkflowInstanceSummary s : all.entries) {
        if (s.instanceId == handoff.Id) {
          handoffSummary = s;
        }
      }
      System.assertNotEquals(
        null,
        handoffSummary,
        'Default enumeration includes the ContinuedAsNew predecessor row'
      );
      System.assertEquals(
        false,
        handoffSummary.isTerminal,
        'ContinuedAsNew is a non-terminal hand-off (matches getStatus)'
      );

      // A status filter that includes ContinuedAsNew returns it...
      WorkflowEngine.InstanceCriteria includeCan = criteriaFor(DEF_A, null);
      includeCan.statuses = new Set<String>{ 'ContinuedAsNew' };
      WorkflowEngine.InstancePage canOnly = WorkflowInstanceQuery.findInstances(
        includeCan
      );
      System.assertEquals(
        1,
        canOnly.entries.size(),
        'Filtering to ContinuedAsNew returns the hand-off row'
      );

      // ...and a terminal-status filter that omits it excludes it.
      WorkflowEngine.InstanceCriteria terminalOnly = criteriaFor(DEF_A, null);
      terminalOnly.statuses = new Set<String>{ 'Completed', 'Failed' };
      WorkflowEngine.InstancePage none = WorkflowInstanceQuery.findInstances(
        terminalOnly
      );
      System.assertEquals(
        0,
        none.entries.size(),
        'A status filter without ContinuedAsNew excludes the hand-off row'
      );
    }
  }

  // ─── honest SOQL profile: exactly one query per call ──────────────────────

  @IsTest
  static void testHonestSoqlProfile() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      for (Integer i = 0; i < 5; i++) {
        newInstance(DEF_A, 'q-' + i, 'Running');
      }

      Test.startTest();
      // A fully-loaded criteria (every filter set) still costs exactly one query.
      WorkflowEngine.InstanceCriteria c = criteriaFor(DEF_A, 2);
      c.statuses = new Set<String>{ 'Running', 'Failed' };
      c.createdAfter = Datetime.now().addDays(-1);
      c.createdBefore = Datetime.now().addDays(1);
      c.modifiedAfter = Datetime.now().addDays(-1);
      c.modifiedBefore = Datetime.now().addDays(1);

      Integer before = Limits.getQueries();
      WorkflowEngine.InstancePage page = WorkflowInstanceQuery.findInstances(c);
      Integer used = Limits.getQueries() - before;
      Test.stopTest();

      System.assertEquals(
        1,
        used,
        'findInstances issues exactly one SOQL query regardless of filters/paging'
      );
      System.assertEquals(2, page.entries.size(), 'Page honors the page size');
      System.assertEquals(
        true,
        page.hasMore,
        'More pages remain after page one'
      );
    }
  }
}
