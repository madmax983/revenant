/**
 * @description Tests for WorkflowMetricsCollector (issue #127): the bounded
 * aggregate queries of the engine-health snapshot.
 */
@IsTest
private class WorkflowMetricsCollectorTest {
  private static Integer keySeq = 0;

  private static Workflow_Instance__c seed(String workflowName, String status) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = workflowName,
      Correlation_Key__c = 'MetricsKey_' + (keySeq++),
      Status__c = status
    );
    insert inst;
    return inst;
  }

  private static void seedMany(String workflowName, String status, Integer n) {
    List<Workflow_Instance__c> rows = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < n; i++) {
      rows.add(
        new Workflow_Instance__c(
          Workflow_Name__c = workflowName,
          Correlation_Key__c = 'MetricsKey_' + (keySeq++),
          Status__c = status
        )
      );
    }
    insert rows;
  }

  // Sets Terminal_At__c on a terminal row. The trigger keeps the value
  // because the row is already terminal.
  private static void setTerminalAt(Workflow_Instance__c inst, Datetime at) {
    update new Workflow_Instance__c(Id = inst.Id, Terminal_At__c = at);
  }

  private static Map<String, WorkflowMetricsSnapshot.DefinitionMetrics> byName(
    WorkflowMetricsCollector.Result result
  ) {
    Map<String, WorkflowMetricsSnapshot.DefinitionMetrics> m = new Map<String, WorkflowMetricsSnapshot.DefinitionMetrics>();
    for (WorkflowMetricsSnapshot.DefinitionMetrics row : result.rows) {
      m.put(row.workflowName, row);
    }
    return m;
  }

  @IsTest
  static void countsEachActiveStatus() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      seed('Acme.A', 'Pending');
      seedMany('Acme.A', 'Running', 2);
      seed('Acme.A', 'Suspended');
      seed('Acme.A', 'Paused');
      seed('Acme.A', 'DefinitionChanged');
      seed('Acme.A', 'Cancelling');
      seed('Acme.A', 'Compensating');
      seed('Acme.A', 'CompensationFailed');
      seed('Acme.A', 'ContinuedAsNew');
      seed('Acme.B', 'Running');
      Datetime now = System.now();

      WorkflowMetricsCollector.Result result = WorkflowMetricsCollector.collect(
        now.addHours(-1),
        now.addMinutes(1)
      );

      Map<String, WorkflowMetricsSnapshot.DefinitionMetrics> m = byName(result);
      WorkflowMetricsSnapshot.DefinitionMetrics a = m.get('Acme.A');
      Assert.areEqual(1, a.pending);
      Assert.areEqual(2, a.running);
      Assert.areEqual(1, a.suspended);
      Assert.areEqual(1, a.paused);
      Assert.areEqual(1, a.definitionChanged);
      Assert.areEqual(1, a.cancelling);
      Assert.areEqual(1, a.compensating);
      Assert.areEqual(1, a.compensationFailed);
      Assert.areEqual(1, m.get('Acme.B').running);
      Assert.isFalse(result.truncated);
      Assert.areEqual(2, result.rows.size());
      Assert.areEqual('Acme.A', result.rows[0].workflowName, 'Sorted by name');
      Assert.areEqual('Acme.B', result.rows[1].workflowName);
    }
  }

  @IsTest
  static void countsTerminalRowsInWindowOnly() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime windowStart = Datetime.newInstanceGmt(2026, 9, 28, 10, 0, 0);
      Datetime snapshotAt = windowStart.addMinutes(10);
      setTerminalAt(seed('Acme.A', 'Failed'), windowStart); // excluded
      setTerminalAt(seed('Acme.A', 'Failed'), windowStart.addSeconds(1));
      setTerminalAt(seed('Acme.A', 'Failed'), snapshotAt);
      setTerminalAt(seed('Acme.A', 'Failed'), snapshotAt.addSeconds(1)); // excluded
      setTerminalAt(seed('Acme.A', 'Compensated'), snapshotAt);
      setTerminalAt(seed('Acme.A', 'Cancelled'), snapshotAt);
      setTerminalAt(seed('Acme.A', 'Completed'), snapshotAt);
      setTerminalAt(seed('Acme.A', 'ContinuedAsNew'), snapshotAt); // not counted

      WorkflowMetricsSnapshot.DefinitionMetrics a = byName(
          WorkflowMetricsCollector.collect(windowStart, snapshotAt)
        )
        .get('Acme.A');

      Assert.areEqual(2, a.failedInWindow, 'Window is (start, end]');
      Assert.areEqual(1, a.compensatedInWindow);
      Assert.areEqual(1, a.cancelledInWindow);
      Assert.areEqual(1, a.completedInWindow);
      Assert.areEqual(0, a.running);
      Assert.isNull(a.oldestActiveAgeSeconds, 'No active row, no age');
    }
  }

  @IsTest
  static void oldestAgeForEachDefinition() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime t0 = Datetime.newInstanceGmt(2026, 1, 1, 10, 0, 0);
      Test.setCreatedDate(seed('Acme.A', 'Running').Id, t0);
      Test.setCreatedDate(seed('Acme.A', 'Suspended').Id, t0.addMinutes(10));
      Test.setCreatedDate(seed('Acme.B', 'Running').Id, t0.addMinutes(30));
      Test.setCreatedDate(seed('Acme.C', 'Completed').Id, t0.addMinutes(-30));
      Datetime snapshotAt = t0.addHours(1);

      Map<String, WorkflowMetricsSnapshot.DefinitionMetrics> m = byName(
        WorkflowMetricsCollector.collect(snapshotAt.addMinutes(-10), snapshotAt)
      );

      Assert.areEqual(3600L, m.get('Acme.A').oldestActiveAgeSeconds);
      Assert.areEqual(1800L, m.get('Acme.B').oldestActiveAgeSeconds);
      Assert.isFalse(
        m.containsKey('Acme.C'),
        'A definition with no active row and no row in the window is absent'
      );
    }
  }

  @IsTest
  static void ageScanCapTruncates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime t0 = Datetime.newInstanceGmt(2026, 1, 1, 10, 0, 0);
      Test.setCreatedDate(seed('Acme.A', 'Running').Id, t0);
      Test.setCreatedDate(seed('Acme.B', 'Running').Id, t0.addMinutes(5));
      WorkflowMetricsCollector.ageScanRowCap = 1;

      WorkflowMetricsCollector.Result result = WorkflowMetricsCollector.collect(
        t0,
        t0.addHours(1)
      );

      Map<String, WorkflowMetricsSnapshot.DefinitionMetrics> m = byName(result);
      Assert.areEqual(3600L, m.get('Acme.A').oldestActiveAgeSeconds);
      Assert.isNull(m.get('Acme.B').oldestActiveAgeSeconds);
      Assert.areEqual(1, m.get('Acme.B').running, 'Counts stay exact');
      Assert.isTrue(result.truncated);
      Assert.isFalse(result.notes.isEmpty(), 'Truncation has a note');
    }
  }

  @IsTest
  static void groupCapTruncates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      seed('Acme.A', 'Running');
      seed('Acme.B', 'Running');
      WorkflowMetricsCollector.groupRowCap = 1;
      Datetime now = System.now();

      WorkflowMetricsCollector.Result result = WorkflowMetricsCollector.collect(
        now.addHours(-1),
        now.addMinutes(1)
      );

      Map<String, WorkflowMetricsSnapshot.DefinitionMetrics> m = byName(result);
      Assert.isTrue(m.containsKey('Acme.A'));
      Assert.isFalse(m.containsKey('Acme.B'), 'Group over the cap dropped');
      Assert.isTrue(result.truncated);
      Assert.isFalse(result.notes.isEmpty());
    }
  }

  @IsTest
  static void windowGroupCapTruncates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = System.now();
      seed('Acme.A', 'Failed');
      seed('Acme.B', 'Failed');
      WorkflowMetricsCollector.groupRowCap = 1;

      WorkflowMetricsCollector.Result result = WorkflowMetricsCollector.collect(
        now.addHours(-1),
        now.addMinutes(1)
      );

      Map<String, WorkflowMetricsSnapshot.DefinitionMetrics> m = byName(result);
      Assert.areEqual(1, m.get('Acme.A').failedInWindow);
      Assert.isFalse(m.containsKey('Acme.B'), 'Group over the cap dropped');
      Assert.isTrue(result.truncated);
      Assert.isTrue(result.notes[0].contains('window'));
    }
  }

  // Contract: an InWindow count reads the current row. A failed instance
  // that runs again before the snapshot is active, not failed.
  @IsTest
  static void restartedInstanceLeavesTheWindowCount() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = System.now();
      Workflow_Instance__c inst = seed('Acme.A', 'Failed');
      update new Workflow_Instance__c(Id = inst.Id, Status__c = 'Running');

      WorkflowMetricsSnapshot.DefinitionMetrics a = byName(
          WorkflowMetricsCollector.collect(now.addHours(-1), now.addMinutes(1))
        )
        .get('Acme.A');

      Assert.areEqual(0, a.failedInWindow);
      Assert.areEqual(1, a.running);
    }
  }

  @IsTest
  static void defaultGroupCapFitsTheAggregateLimit() {
    Assert.isTrue(
      WorkflowMetricsCollector.groupRowCap + 1 <= 2000,
      'An aggregate query can return not more than 2,000 rows'
    );
  }

  @IsTest
  static void windowOnlyNameHasNoAgeAndNoTruncation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = System.now();
      seed('Acme.A', 'Running');
      seed('Acme.B', 'Failed');

      WorkflowMetricsCollector.Result result = WorkflowMetricsCollector.collect(
        now.addHours(-1),
        now.addMinutes(1)
      );

      Map<String, WorkflowMetricsSnapshot.DefinitionMetrics> m = byName(result);
      Assert.isNotNull(m.get('Acme.A').oldestActiveAgeSeconds);
      Assert.isNull(m.get('Acme.B').oldestActiveAgeSeconds);
      Assert.isFalse(result.truncated, 'No active row is not a truncation');
    }
  }

  @IsTest
  static void queryCountIsConstant() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = System.now();
      seed('Acme.A', 'Running');
      // Load the WorkflowEngine config query before the measure.
      Assert.isNotNull(WorkflowEngine.ACTIVE_STATUSES);

      Integer q0 = Limits.getQueries();
      WorkflowMetricsCollector.collect(now.addHours(-1), now.addMinutes(1));
      Integer small = Limits.getQueries() - q0;

      for (Integer i = 0; i < 10; i++) {
        seed('Acme.Wf' + i, 'Running');
        seed('Acme.Wf' + i, 'Suspended');
        setTerminalAt(seed('Acme.Wf' + i, 'Failed'), now);
      }
      q0 = Limits.getQueries();
      WorkflowMetricsCollector.collect(now.addHours(-1), now.addMinutes(1));
      Integer large = Limits.getQueries() - q0;

      Assert.areEqual(3, small, 'Three queries for each snapshot');
      Assert.areEqual(small, large, 'Query count does not grow');
    }
  }

  // Salesforce: COUNT(field) with GROUP BY uses one query row for each
  // group. This test measures it.
  @IsTest
  static void groupedCountUsesOneRowPerGroup() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      seedMany('Acme.A', 'Running', 50);

      Integer rows0 = Limits.getQueryRows();
      List<AggregateResult> groups = WorkflowMetricsCollector.queryActiveCounts();
      Integer rowsUsed = Limits.getQueryRows() - rows0;

      Assert.areEqual(1, groups.size());
      Assert.areEqual(1, rowsUsed, '50 rows in one group use one query row');
    }
  }

  @IsTest
  static void lowQueryBudgetSkips() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      seed('Acme.A', 'Running');
      WorkflowMetricsCollector.forceQueryBudgetExhausted = true;
      Datetime now = System.now();

      Integer q0 = Limits.getQueries();
      WorkflowMetricsCollector.Result result = WorkflowMetricsCollector.collect(
        now.addHours(-1),
        now
      );

      Assert.isNull(result, 'No snapshot when the query budget is low');
      Assert.areEqual(0, Limits.getQueries() - q0);
    }
  }
}
