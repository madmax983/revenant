@IsTest
private class WorkflowEngineGetHistoryTest {
  // ─── helpers ─────────────────────────────────────────────────────────────

  // Inserts a workflow instance and returns it. All DML runs in system mode so
  // the test never depends on the running user's object/field permissions.
  private static Workflow_Instance__c newInstance(String correlationKey) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineGetHistoryTest.StubWorkflow',
      Status__c = 'Running',
      Correlation_Key__c = correlationKey
    );
    Database.insert(inst, AccessLevel.SYSTEM_MODE);
    return inst;
  }

  // Builds (does not insert) a step-execution row for an instance. Retry count and
  // error text are set by the caller on the returned row when a test needs them.
  private static Workflow_Step_Execution__c step(
    Id instanceId,
    String stepName,
    String status
  ) {
    return new Workflow_Step_Execution__c(
      Workflow_Instance__c = instanceId,
      Step_Name__c = stepName,
      Status__c = status
    );
  }

  // A well-formed but non-existent Workflow_Instance__c Id.
  private static Id unknownInstanceId() {
    return (Id) (Workflow_Instance__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix() + '000000000001');
  }

  // A well-formed but non-existent Workflow_Step_Execution__c Id.
  private static Id unknownStepExecutionId() {
    return (Id) (Workflow_Step_Execution__c.SObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
      .getKeyPrefix() + '000000000001');
  }

  // ─── getHistory(Id) — ordering + field projection ─────────────────────────

  @IsTest
  static void testGetHistoryOrderedByExecution() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = newInstance('order-1');
      Workflow_Step_Execution__c s1 = step(inst.Id, 'StepOne', 'Completed');
      Workflow_Step_Execution__c s2 = step(inst.Id, 'StepTwo', 'Completed');
      s2.Retry_Count__c = 2;
      Workflow_Step_Execution__c s3 = step(inst.Id, 'StepThree', 'Running');
      Database.insert(
        new List<Workflow_Step_Execution__c>{ s1, s2, s3 },
        AccessLevel.SYSTEM_MODE
      );
      // Force ascending append order regardless of insert timing.
      Test.setCreatedDate(s1.Id, DateTime.now().addMinutes(-30));
      Test.setCreatedDate(s2.Id, DateTime.now().addMinutes(-20));
      Test.setCreatedDate(s3.Id, DateTime.now().addMinutes(-10));

      Test.startTest();
      WorkflowEngine.StepHistory history = WorkflowHistoryRead.getHistory(
        inst.Id
      );
      Test.stopTest();

      System.assertNotEquals(null, history, 'Known instance returns a wrapper');
      System.assertEquals(false, history.isTruncated, 'Not truncated');
      System.assertEquals(
        3,
        history.entries.size(),
        'All three steps returned'
      );
      System.assertEquals(
        3,
        history.totalCount,
        'totalCount equals entries.size() when untruncated'
      );
      System.assertEquals(
        'StepOne',
        history.entries[0].stepName,
        'First in append order'
      );
      System.assertEquals(
        'StepTwo',
        history.entries[1].stepName,
        'Second in append order'
      );
      System.assertEquals(
        'StepThree',
        history.entries[2].stepName,
        'Third in append order'
      );
      System.assertEquals(
        2,
        history.entries[1].attempt,
        'attempt maps to Retry_Count__c'
      );
      System.assertEquals(
        s1.Id,
        history.entries[0].executionId,
        'executionId maps to the row Id'
      );
      System.assertEquals(
        false,
        history.entries[0].isCompensation,
        'Forward step is not a compensation'
      );
    }
  }

  // ─── terminal vs in-flight timing ─────────────────────────────────────────

  @IsTest
  static void testGetHistoryTerminalAndInFlightTiming() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = newInstance('timing-1');
      Workflow_Step_Execution__c done = step(inst.Id, 'DoneStep', 'Completed');
      Workflow_Step_Execution__c running = step(
        inst.Id,
        'RunningStep',
        'Running'
      );
      Database.insert(
        new List<Workflow_Step_Execution__c>{ done, running },
        AccessLevel.SYSTEM_MODE
      );
      Test.setCreatedDate(done.Id, DateTime.now().addMinutes(-30));
      Test.setCreatedDate(running.Id, DateTime.now().addMinutes(-20));

      Test.startTest();
      WorkflowEngine.StepHistory history = WorkflowHistoryRead.getHistory(
        inst.Id
      );
      Test.stopTest();

      WorkflowEngine.StepHistoryEntry terminal = history.entries[0];
      System.assertNotEquals(
        null,
        terminal.startedAt,
        'startedAt always populated'
      );
      System.assertNotEquals(
        null,
        terminal.endedAt,
        'Terminal step has endedAt'
      );
      System.assertNotEquals(
        null,
        terminal.totalDurationMs,
        'Terminal step has totalDurationMs'
      );
      System.assert(
        terminal.totalDurationMs >= 0,
        'totalDurationMs is non-negative'
      );

      WorkflowEngine.StepHistoryEntry inFlight = history.entries[1];
      System.assertEquals(
        null,
        inFlight.endedAt,
        'In-flight step has null endedAt'
      );
      System.assertEquals(
        null,
        inFlight.totalDurationMs,
        'In-flight step has null totalDurationMs'
      );
    }
  }

  // ─── compensation flag + hasError + per-step error detail ──────────────────

  @IsTest
  static void testGetHistoryCompensationAndError() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = newInstance('comp-1');
      Workflow_Step_Execution__c forwardFail = step(
        inst.Id,
        'ChargeCard',
        'Failed'
      );
      forwardFail.Retry_Count__c = 3;
      forwardFail.Error_Details__c = 'Gateway timeout';
      Workflow_Step_Execution__c comp = step(
        inst.Id,
        'ChargeCard_Compensate',
        'Compensated'
      );
      Database.insert(
        new List<Workflow_Step_Execution__c>{ forwardFail, comp },
        AccessLevel.SYSTEM_MODE
      );
      Test.setCreatedDate(forwardFail.Id, DateTime.now().addMinutes(-30));
      Test.setCreatedDate(comp.Id, DateTime.now().addMinutes(-20));

      Test.startTest();
      WorkflowEngine.StepHistory history = WorkflowHistoryRead.getHistory(
        inst.Id
      );
      Test.stopTest();

      System.assertEquals(
        true,
        history.entries[0].hasError,
        'hasError is true when Error_Details__c is populated'
      );
      System.assertEquals(
        false,
        history.entries[0].isCompensation,
        'Forward execution is not a compensation'
      );
      System.assertEquals(
        true,
        history.entries[1].isCompensation,
        '_Compensate suffix marks a compensation execution'
      );
      System.assertEquals(
        false,
        history.entries[1].hasError,
        'No error on the successful compensation'
      );
      // The timeline never carries the error text; it is fetched per-step.
      System.assertEquals(
        'Gateway timeout',
        WorkflowHistoryRead.getStepError(history.entries[0].executionId),
        'getStepError returns the full stored detail'
      );
      System.assertEquals(
        null,
        WorkflowHistoryRead.getStepError(history.entries[1].executionId),
        'getStepError is null for an error-free row'
      );
      System.assertEquals(
        null,
        WorkflowHistoryRead.getStepError(unknownStepExecutionId()),
        'getStepError is null for an unknown Id'
      );
    }
  }

  // ─── hasError reflects populated detail, not status (retried-then-succeeded) ─

  @IsTest
  static void testGetHistoryHasErrorIndependentOfStatus() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = newInstance('retried-1');
      // The engine reuses one row across retries: a step that errored then retried
      // to success has a terminal-success status but still-populated error detail.
      Workflow_Step_Execution__c retried = step(
        inst.Id,
        'FlakyCallout',
        'Completed'
      );
      retried.Retry_Count__c = 2;
      retried.Error_Details__c = 'Transient 503 on attempt 1';
      Database.insert(retried, AccessLevel.SYSTEM_MODE);

      Test.startTest();
      WorkflowEngine.StepHistory history = WorkflowHistoryRead.getHistory(
        inst.Id
      );
      Test.stopTest();

      WorkflowEngine.StepHistoryEntry entry = history.entries[0];
      System.assertEquals('Completed', entry.status, 'Terminal-success status');
      System.assertEquals(
        true,
        entry.hasError,
        'hasError reflects populated Error_Details__c even on a succeeded retry'
      );
      System.assertEquals(
        'Transient 503 on attempt 1',
        WorkflowHistoryRead.getStepError(entry.executionId),
        'The retained error detail is still fetchable'
      );
    }
  }

  // ─── known instance with no steps → empty list (not null) ─────────────────

  @IsTest
  static void testGetHistoryKnownInstanceNoStepsIsEmpty() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = newInstance('empty-1');

      Test.startTest();
      WorkflowEngine.StepHistory history = WorkflowHistoryRead.getHistory(
        inst.Id
      );
      Test.stopTest();

      System.assertNotEquals(
        null,
        history,
        'Known instance never returns null'
      );
      System.assertEquals(0, history.entries.size(), 'Empty entries');
      System.assertEquals(false, history.isTruncated, 'Empty is not truncated');
    }
  }

  // ─── unknown / null Id → null ─────────────────────────────────────────────

  @IsTest
  static void testGetHistoryUnknownIdReturnsNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      WorkflowEngine.StepHistory history = WorkflowHistoryRead.getHistory(
        unknownInstanceId()
      );
      Test.stopTest();

      System.assertEquals(null, history, 'Unknown Id returns null');
    }
  }

  @IsTest
  static void testGetHistoryNullIdReturnsNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        null,
        WorkflowHistoryRead.getHistory((Id) null),
        'Null Id returns null'
      );
    }
  }

  // ─── truncation / row cap ─────────────────────────────────────────────────

  @IsTest
  static void testGetHistoryTruncatesAtRowCap() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = newInstance('trunc-1');
      Integer cap = WorkflowHistoryRead.MAX_HISTORY_ROWS;
      List<Workflow_Step_Execution__c> rows = new List<Workflow_Step_Execution__c>();
      for (Integer i = 0; i < cap + 5; i++) {
        rows.add(step(inst.Id, 'Step' + i, 'Completed'));
      }
      Database.insert(rows, AccessLevel.SYSTEM_MODE);

      Test.startTest();
      WorkflowEngine.StepHistory history = WorkflowHistoryRead.getHistory(
        inst.Id
      );
      Test.stopTest();

      System.assertEquals(
        cap,
        history.entries.size(),
        'Entries capped at MAX_HISTORY_ROWS'
      );
      System.assertEquals(
        true,
        history.isTruncated,
        'Over-cap history is flagged truncated'
      );
      System.assertEquals(
        cap + 5,
        history.totalCount,
        'Truncated totalCount reports the real total, not the capped size'
      );
    }
  }

  // ─── totalCount: untruncated stays at one SOQL; truncated reports real total ─

  @IsTest
  static void testGetHistoryTotalCount() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Integer cap = WorkflowHistoryRead.MAX_HISTORY_ROWS;

      // Untruncated instance: three steps.
      Workflow_Instance__c small = newInstance('total-small');
      Database.insert(
        new List<Workflow_Step_Execution__c>{
          step(small.Id, 'S1', 'Completed'),
          step(small.Id, 'S2', 'Completed'),
          step(small.Id, 'S3', 'Running')
        },
        AccessLevel.SYSTEM_MODE
      );

      // Truncated instance: cap + 5 steps.
      Workflow_Instance__c big = newInstance('total-big');
      List<Workflow_Step_Execution__c> bigRows = new List<Workflow_Step_Execution__c>();
      for (Integer i = 0; i < cap + 5; i++) {
        bigRows.add(step(big.Id, 'B' + i, 'Completed'));
      }
      Database.insert(bigRows, AccessLevel.SYSTEM_MODE);

      Test.startTest();
      // The untruncated single-instance read costs exactly two SOQL queries: the
      // row scan plus the bounded Id-only error probe (no COUNT, no existence
      // probe). The error probe is the heap-safety cost of not loading long-text.
      Integer before = Limits.getQueries();
      WorkflowEngine.StepHistory smallHistory = WorkflowHistoryRead.getHistory(
        small.Id
      );
      Integer used = Limits.getQueries() - before;
      WorkflowEngine.StepHistory bigHistory = WorkflowHistoryRead.getHistory(
        big.Id
      );
      Test.stopTest();

      System.assertEquals(
        2,
        used,
        'Untruncated single read costs scan + Id-only error probe'
      );
      System.assertEquals(false, smallHistory.isTruncated, 'small untruncated');
      System.assertEquals(
        smallHistory.entries.size(),
        smallHistory.totalCount,
        'Untruncated totalCount equals entries.size()'
      );
      System.assertEquals(3, smallHistory.totalCount, 'Real total is three');

      System.assertEquals(true, bigHistory.isTruncated, 'big truncated');
      System.assertEquals(
        cap,
        bigHistory.entries.size(),
        'Entries capped at MAX_HISTORY_ROWS'
      );
      System.assert(
        bigHistory.totalCount > cap,
        'Truncated totalCount exceeds the cap'
      );
      System.assertEquals(
        cap + 5,
        bigHistory.totalCount,
        'Truncated totalCount is the real total'
      );
    }
  }

  // ─── bulk map form ────────────────────────────────────────────────────────

  @IsTest
  static void testGetHistoryBulkMap() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c instA = newInstance('bulk-a');
      Workflow_Instance__c instB = newInstance('bulk-b');
      Workflow_Instance__c instEmpty = newInstance('bulk-empty');

      Workflow_Step_Execution__c a1 = step(instA.Id, 'A1', 'Completed');
      Workflow_Step_Execution__c a2 = step(instA.Id, 'A2', 'Running');
      Workflow_Step_Execution__c b1 = step(instB.Id, 'B1', 'Completed');
      Database.insert(
        new List<Workflow_Step_Execution__c>{ a1, a2, b1 },
        AccessLevel.SYSTEM_MODE
      );
      Test.setCreatedDate(a1.Id, DateTime.now().addMinutes(-30));
      Test.setCreatedDate(a2.Id, DateTime.now().addMinutes(-20));

      Id unknownId = unknownInstanceId();

      Test.startTest();
      Map<Id, WorkflowEngine.StepHistory> byId = WorkflowHistoryRead.getHistory(
        new List<Id>{ instA.Id, instB.Id, instEmpty.Id, unknownId }
      );
      Test.stopTest();

      System.assertEquals(3, byId.size(), 'Only known instances are keyed');
      System.assertEquals(
        false,
        byId.containsKey(unknownId),
        'Unknown Id is absent from the map'
      );
      System.assertEquals(
        2,
        byId.get(instA.Id).entries.size(),
        'Instance A has two steps'
      );
      System.assertEquals(
        'A1',
        byId.get(instA.Id).entries[0].stepName,
        'Instance A ordered by append'
      );
      System.assertEquals(
        1,
        byId.get(instB.Id).entries.size(),
        'Instance B has one step'
      );
      System.assert(
        byId.containsKey(instEmpty.Id),
        'Known-but-empty instance is present'
      );
      System.assertEquals(
        0,
        byId.get(instEmpty.Id).entries.size(),
        'Empty instance has empty entries'
      );
      System.assertEquals(
        0,
        byId.get(instEmpty.Id).totalCount,
        'Empty instance has totalCount 0'
      );
      System.assertEquals(
        false,
        byId.get(instEmpty.Id).isTruncated,
        'Genuinely empty instance is not truncated'
      );
    }
  }

  // ─── regression: bulk read never reports a step-bearing instance as empty ───

  @IsTest
  static void testGetHistoryBulkStarvedInstanceNotFalseEmpty() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Integer cap = WorkflowHistoryRead.MAX_HISTORY_ROWS;
      // Two Ids in the batch → scan budget = 2 * (cap + 1). A hot instance with
      // more than the whole budget consumes it entirely, starving the sibling.
      Integer budget = 2 * (cap + 1);

      // Insert the hot instance FIRST so it sorts first (lowest Id) and its rows
      // fill the shared scan budget before the sibling's are reached.
      Workflow_Instance__c hot = newInstance('starve-hot');
      List<Workflow_Step_Execution__c> hotRows = new List<Workflow_Step_Execution__c>();
      Integer hotTotal = budget + 5;
      for (Integer i = 0; i < hotTotal; i++) {
        hotRows.add(step(hot.Id, 'H' + i, 'Completed'));
      }
      Database.insert(hotRows, AccessLevel.SYSTEM_MODE);

      // A second, higher-Id instance with just a handful of steps.
      Workflow_Instance__c small = newInstance('starve-small');
      Database.insert(
        new List<Workflow_Step_Execution__c>{
          step(small.Id, 'S1', 'Completed'),
          step(small.Id, 'S2', 'Completed'),
          step(small.Id, 'S3', 'Running')
        },
        AccessLevel.SYSTEM_MODE
      );

      Test.startTest();
      Map<Id, WorkflowEngine.StepHistory> byId = WorkflowHistoryRead.getHistory(
        new List<Id>{ hot.Id, small.Id }
      );
      Test.stopTest();

      // The starved sibling must NOT be reported as empty: it is present,
      // truncated, and carries its REAL total (3), never 0.
      System.assert(
        byId.containsKey(small.Id),
        'Starved step-bearing instance is present in the map'
      );
      WorkflowEngine.StepHistory smallHistory = byId.get(small.Id);
      System.assertEquals(
        3,
        smallHistory.totalCount,
        'Starved instance reports its real step count, not 0'
      );
      System.assertEquals(
        true,
        smallHistory.isTruncated,
        'Starved instance is flagged truncated, not false-empty'
      );
      System.assert(
        smallHistory.entries.size() < smallHistory.totalCount,
        'Starved instance retrieved fewer entries than its real total'
      );

      // The hot instance is truncated with its real total and capped entries.
      WorkflowEngine.StepHistory hotHistory = byId.get(hot.Id);
      System.assertEquals(
        true,
        hotHistory.isTruncated,
        'Hot instance is truncated'
      );
      System.assertEquals(
        hotTotal,
        hotHistory.totalCount,
        'Hot instance reports its real total'
      );
      System.assertEquals(
        cap,
        hotHistory.entries.size(),
        'Hot instance entries capped at MAX_HISTORY_ROWS'
      );
    }
  }

  @IsTest
  static void testGetHistoryBulkEmptyInputReturnsEmptyMap() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        0,
        WorkflowHistoryRead.getHistory(new List<Id>()).size(),
        'Empty input yields empty map'
      );
      System.assertEquals(
        0,
        WorkflowHistoryRead.getHistory((List<Id>) null).size(),
        'Null input yields empty map'
      );
    }
  }

  // ─── pure row-budget sizing (covers the 50k-governor case unit-style) ───────
  // A real 50,000-row scan cannot be integration-tested — the 10,000-rows-per-
  // transaction DML governor blocks inserting that much data — so the headroom
  // arithmetic that prevents "Too many query rows" is verified directly on the
  // pure helper. The margin mirrors WorkflowHistoryRead.SCAN_ROW_SAFETY_MARGIN
  // (1000).

  @IsTest
  static void testResolveScanLimitDesiredWithinBudget() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Ample budget: the ideal (desired) row count is used unchanged.
      System.assertEquals(
        100,
        WorkflowHistoryRead.resolveScanLimit(100, 50000),
        'desired below budget is returned as-is'
      );
    }
  }

  @IsTest
  static void testResolveScanLimitDesiredExceedsBudget() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Ideal exceeds budget: clamp to HALF of (remaining - margin), reserving the
      // other half for the follow-up error probe — never the governor ceiling.
      // (50000 - 1000) / 2 = 24500.
      System.assertEquals(
        24500,
        WorkflowHistoryRead.resolveScanLimit(100000, 50000),
        'desired above budget clamps to half of (budget - margin)'
      );
      // Boundary: (2000 - 1000) / 2 = 500 exactly.
      System.assertEquals(
        500,
        WorkflowHistoryRead.resolveScanLimit(500, 2000),
        'scan takes at most half the remaining budget'
      );
    }
  }

  @IsTest
  static void testResolveScanLimitBudgetExhaustedReturnsZero() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Remaining budget already at/under the margin: skip the scan entirely.
      System.assertEquals(
        0,
        WorkflowHistoryRead.resolveScanLimit(500, 500),
        'tiny budget yields 0 (scan skipped)'
      );
      System.assertEquals(
        0,
        WorkflowHistoryRead.resolveScanLimit(500, 0),
        'no budget yields 0'
      );
      System.assertEquals(
        0,
        WorkflowHistoryRead.resolveScanLimit(500, -100),
        'negative budget yields 0'
      );
    }
  }
}
