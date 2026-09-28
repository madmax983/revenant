/**
 * @description Tests for the Fleet Health summary (#111): WorkflowFleetHealthService and
 * WorkflowFleetHealthController.
 */
@IsTest
private class WorkflowFleetHealthServiceTest {
  // Current time with no milliseconds. The database keeps whole seconds.
  private static Datetime baseTime() {
    return Datetime.newInstance((System.now().getTime() / 1000) * 1000);
  }

  // Inserts one instance. Sets CreatedDate. For a terminal status, sets Terminal_At__c.
  private static Workflow_Instance__c seed(
    String workflowName,
    String status,
    Datetime createdAt,
    Datetime terminalAt
  ) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = workflowName,
      Status__c = status
    );
    insert inst;
    Test.setCreatedDate(inst.Id, createdAt);
    if (terminalAt != null) {
      // The status is already terminal, so the trigger keeps this value.
      inst.Terminal_At__c = terminalAt;
      update inst;
    }
    return inst;
  }

  private static Map<String, Object> findRow(
    Map<String, Object> result,
    String workflowName
  ) {
    for (Object o : (List<Object>) result.get('rows')) {
      Map<String, Object> row = (Map<String, Object>) o;
      if (row.get('workflowName') == workflowName) {
        return row;
      }
    }
    return null;
  }

  private static List<Object> rowsOf(Map<String, Object> result) {
    return (List<Object>) result.get('rows');
  }

  private static User insertStandardUser() {
    Profile stdProfile = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Standard User'
      LIMIT 1
    ];
    User stdUser = new User(
      Alias = 'fhusr',
      Email = 'fleethealth@testorg.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Testing',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = stdProfile.Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      UserName = 'stduser_fleethealth_test_' +
        DateTime.now().getTime() +
        '@testorg.com'
    );
    insert stdUser;
    return stdUser;
  }

  /**
   * @description AC2: each status goes into one bucket. Started is the sum.
   */
  @IsTest
  static void testStatusBuckets() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = baseTime();
      Set<String> terminal = new Set<String>{
        'Completed',
        'ContinuedAsNew',
        'Failed',
        'Compensated',
        'Cancelled'
      };
      List<String> statuses = new List<String>{
        'Completed',
        'ContinuedAsNew',
        'Failed',
        'CompensationFailed',
        'Compensated',
        'Cancelled',
        'Running',
        'Suspended',
        'Paused',
        'Compensating',
        'Cancelling',
        'Pending',
        'DefinitionChanged'
      };
      for (String s : statuses) {
        seed('FleetA', s, now, terminal.contains(s) ? now : null);
      }

      Test.startTest();
      Map<String, Object> result = WorkflowFleetHealthController.getFleetHealth(
        '24h'
      );
      Test.stopTest();

      Map<String, Object> row = findRow(result, 'FleetA');
      System.assertEquals(13, row.get('started'), 'Started counts all');
      System.assertEquals(
        2,
        row.get('completed'),
        'Completed and ContinuedAsNew'
      );
      System.assertEquals(
        4,
        row.get('failed'),
        'Failed, CompensationFailed, Compensated and Cancelled'
      );
      System.assertEquals(
        7,
        row.get('inFlight'),
        'Running, Suspended, Paused, Compensating, Cancelling, Pending, DefinitionChanged'
      );
      System.assertEquals(
        33.3,
        (Decimal) row.get('successRate'),
        'Rate is completed / (completed + failed)'
      );
    }
  }

  /**
   * @description AC1: one row for each definition with an instance started in the window.
   */
  @IsTest
  static void testOneRowPerDefinitionInWindow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = baseTime();
      seed('FleetIn', 'Running', now, null);
      seed('FleetIn', 'Completed', now, now);
      seed('FleetOld', 'Completed', now.addDays(-3), now.addDays(-3));

      Test.startTest();
      Map<String, Object> last24h = WorkflowFleetHealthController.getFleetHealth(
        '24h'
      );
      Map<String, Object> last7d = WorkflowFleetHealthController.getFleetHealth(
        '7d'
      );
      Test.stopTest();

      System.assertEquals(1, rowsOf(last24h).size(), 'Only FleetIn in 24h');
      System.assertEquals(2, findRow(last24h, 'FleetIn').get('started'));
      System.assertEquals(null, findRow(last24h, 'FleetOld'));
      System.assertEquals(2, rowsOf(last7d).size(), 'Both in 7d');
      System.assertEquals(1, findRow(last7d, 'FleetOld').get('started'));
    }
  }

  /**
   * @description AC1: the window keys map to hours. A blank or unknown key gives 24h.
   */
  @IsTest
  static void testWindowKeyMapping() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      System.assertEquals(
        1,
        WorkflowFleetHealthController.getFleetHealth('1h').get('windowHours')
      );
      System.assertEquals(
        24,
        WorkflowFleetHealthController.getFleetHealth('24h').get('windowHours')
      );
      System.assertEquals(
        168,
        WorkflowFleetHealthController.getFleetHealth('7d').get('windowHours')
      );
      Map<String, Object> blank = WorkflowFleetHealthController.getFleetHealth(
        null
      );
      Map<String, Object> bogus = WorkflowFleetHealthController.getFleetHealth(
        'bogus'
      );
      Test.stopTest();

      System.assertEquals(24, blank.get('windowHours'));
      System.assertEquals('24h', blank.get('windowKey'));
      System.assertEquals(24, bogus.get('windowHours'));
      System.assertEquals(0, rowsOf(blank).size(), 'No data gives no rows');
    }
  }

  /**
   * @description AC3: success rate per row. Lowest rate first. No rate goes last.
   */
  @IsTest
  static void testSuccessRateAndSortOrder() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = baseTime();
      for (Integer i = 0; i < 4; i++) {
        seed('RateEighty', 'Completed', now, now);
      }
      seed('RateEighty', 'Failed', now, now);
      seed('RateFull', 'Completed', now, now);
      seed('RateNone', 'Running', now, null);

      Test.startTest();
      Map<String, Object> result = WorkflowFleetHealthController.getFleetHealth(
        '24h'
      );
      Test.stopTest();

      List<Object> rows = rowsOf(result);
      System.assertEquals(3, rows.size());
      System.assertEquals(
        'RateEighty',
        ((Map<String, Object>) rows[0]).get('workflowName'),
        'Lowest rate first'
      );
      System.assertEquals(
        'RateFull',
        ((Map<String, Object>) rows[1]).get('workflowName')
      );
      System.assertEquals(
        'RateNone',
        ((Map<String, Object>) rows[2]).get('workflowName'),
        'No rate goes last'
      );
      System.assertEquals(
        80.0,
        (Decimal) findRow(result, 'RateEighty').get('successRate')
      );
      System.assertEquals(
        100.0,
        (Decimal) findRow(result, 'RateFull').get('successRate')
      );
      System.assertEquals(
        null,
        findRow(result, 'RateNone').get('successRate'),
        'No terminal instance gives no rate (no divide by zero)'
      );
    }
  }

  /**
   * @description AC4: average and maximum duration from CreatedDate to Terminal_At__c.
   * Active instances are not in the duration.
   */
  @IsTest
  static void testDurations() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = baseTime();
      seed('DurDef', 'Completed', now.addSeconds(-60), now);
      seed('DurDef', 'Failed', now.addSeconds(-120), now);
      seed('DurDef', 'Completed', now.addSeconds(-300), now);
      seed('DurDef', 'Running', now.addSeconds(-900), null);
      seed('DurDef', 'CompensationFailed', now.addSeconds(-900), null);

      Test.startTest();
      Map<String, Object> result = WorkflowFleetHealthController.getFleetHealth(
        '24h'
      );
      Test.stopTest();

      Map<String, Object> row = findRow(result, 'DurDef');
      System.assertEquals(
        160000L,
        (Long) row.get('avgDurationMs'),
        'Average of 60s, 120s and 300s'
      );
      System.assertEquals(300000L, (Long) row.get('maxDurationMs'));
      System.assertEquals(3, row.get('durationSampleSize'));
      System.assertEquals(false, row.get('durationSampled'));
      System.assertEquals(false, result.get('isSampled'));
      System.assertEquals(false, result.get('countsCapped'));
    }
  }

  /**
   * @description AC4 and AC6: the duration sample has a cap. Counts stay exact. All rows
   * show that the durations are sampled.
   */
  @IsTest
  static void testDurationSampleCap() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = baseTime();
      for (Integer i = 0; i < 3; i++) {
        seed('CapDef', 'Completed', now.addSeconds(-10), now);
      }
      seed('NoDurDef', 'Completed', now.addSeconds(-10), now.addSeconds(-5));
      WorkflowFleetHealthService.sampleCapOverride = 2;

      Test.startTest();
      Map<String, Object> result = WorkflowFleetHealthController.getFleetHealth(
        '24h'
      );
      Test.stopTest();

      System.assertEquals(true, result.get('isSampled'));
      System.assertEquals(2, result.get('sampleCap'));
      Map<String, Object> capRow = findRow(result, 'CapDef');
      System.assertEquals(3, capRow.get('completed'), 'Counts stay exact');
      System.assertEquals(2, capRow.get('durationSampleSize'));
      System.assertEquals(true, capRow.get('durationSampled'));
      System.assertEquals(10000L, (Long) capRow.get('avgDurationMs'));

      // The older terminal row is out of the sample.
      Map<String, Object> noDurRow = findRow(result, 'NoDurDef');
      System.assertEquals(0, noDurRow.get('durationSampleSize'));
      System.assertEquals(null, noDurRow.get('avgDurationMs'));
      System.assertEquals(null, noDurRow.get('maxDurationMs'));
      System.assertEquals(true, noDurRow.get('durationSampled'));
    }
  }

  /**
   * @description AC4: exactly cap terminal rows is a full sample, not a partial sample.
   */
  @IsTest
  static void testExactCapIsNotSampled() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = baseTime();
      seed('ExactDef', 'Completed', now.addSeconds(-10), now);
      seed('ExactDef', 'Failed', now.addSeconds(-20), now);
      WorkflowFleetHealthService.sampleCapOverride = 2;

      Test.startTest();
      Map<String, Object> result = WorkflowFleetHealthController.getFleetHealth(
        '24h'
      );
      Test.stopTest();

      System.assertEquals(false, result.get('isSampled'));
      Map<String, Object> row = findRow(result, 'ExactDef');
      System.assertEquals(2, row.get('durationSampleSize'));
      System.assertEquals(false, row.get('durationSampled'));
      System.assertEquals(20000L, (Long) row.get('maxDurationMs'));
    }
  }

  /**
   * @description AC1 and AC4: an instance that started before the window and got its
   * Terminal_At__c in the window gives a duration. The duration is not cut at the window.
   */
  @IsTest
  static void testDurationIncludesInstancesStartedBeforeWindow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = baseTime();
      seed('LongDef', 'Completed', now.addDays(-3), now);

      Test.startTest();
      Map<String, Object> result = WorkflowFleetHealthController.getFleetHealth(
        '24h'
      );
      Test.stopTest();

      Map<String, Object> row = findRow(result, 'LongDef');
      System.assertNotEquals(
        null,
        row,
        'The definition had an instance in the window'
      );
      System.assertEquals(
        0,
        row.get('started'),
        'It started before the window'
      );
      System.assertEquals(null, row.get('successRate'));
      Long threeDaysMs = 3L * 24 * 60 * 60 * 1000;
      System.assertEquals(threeDaysMs, (Long) row.get('avgDurationMs'));
      System.assertEquals(threeDaysMs, (Long) row.get('maxDurationMs'));
    }
  }

  /**
   * @description AC6: above the count cap, the counts use the newest instances and the
   * result shows countsCapped.
   */
  @IsTest
  static void testCountCapUsesNewestInstances() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = baseTime();
      for (Integer i = 1; i <= 3; i++) {
        seed('NewDef', 'Completed', now.addMinutes(-i), now);
      }
      for (Integer i = 10; i <= 13; i++) {
        seed('OldDef', 'Running', now.addMinutes(-i), null);
      }
      WorkflowFleetHealthService.countCapOverride = 5;

      Test.startTest();
      Map<String, Object> result = WorkflowFleetHealthController.getFleetHealth(
        '24h'
      );
      Test.stopTest();

      System.assertEquals(true, result.get('countsCapped'));
      System.assertEquals(5, result.get('countCap'));
      System.assertEquals(3, findRow(result, 'NewDef').get('started'));
      System.assertEquals(3, findRow(result, 'NewDef').get('completed'));
      System.assertEquals(2, findRow(result, 'OldDef').get('started'));
      System.assertEquals(2, findRow(result, 'OldDef').get('inFlight'));
    }
  }

  /**
   * @description AC2 and AC6: above the aggregate limit and under the count cap, the row
   * query gives the same exact counts as the aggregate query.
   */
  @IsTest
  static void testRowCountsMatchAggregateCounts() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = baseTime();
      seed('RowDef', 'Completed', now.addSeconds(-10), now);
      seed('RowDef', 'Failed', now.addSeconds(-10), now);
      seed('RowDef', 'Running', now, null);
      seed('OtherDef', 'Paused', now, null);

      Test.startTest();
      Map<String, Object> aggregate = WorkflowFleetHealthController.getFleetHealth(
        '24h'
      );
      WorkflowFleetHealthService.aggregateMaxOverride = 3;
      Map<String, Object> scanned = WorkflowFleetHealthController.getFleetHealth(
        '24h'
      );
      Test.stopTest();

      System.assertEquals(false, scanned.get('countsCapped'), 'Under the cap');
      for (String name : new List<String>{ 'RowDef', 'OtherDef' }) {
        Map<String, Object> a = findRow(aggregate, name);
        Map<String, Object> r = findRow(scanned, name);
        for (
          String key : new List<String>{
            'started',
            'completed',
            'failed',
            'inFlight',
            'successRate'
          }
        ) {
          System.assertEquals(a.get(key), r.get(key), name + ' ' + key);
        }
      }
      System.assertEquals(3, findRow(scanned, 'RowDef').get('started'));
    }
  }

  /**
   * @description AC1: names that differ only in case give one row, as SOQL GROUP BY does.
   */
  @IsTest
  static void testNameCaseGivesOneRow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = baseTime();
      seed('CaseDef', 'Completed', now.addSeconds(-10), now);
      seed('casedef', 'Running', now, null);

      Test.startTest();
      Map<String, Object> result = WorkflowFleetHealthController.getFleetHealth(
        '24h'
      );
      Test.stopTest();

      List<Object> rows = rowsOf(result);
      System.assertEquals(1, rows.size(), 'One row for one definition');
      System.assertEquals(2, ((Map<String, Object>) rows[0]).get('started'));
      System.assertEquals(
        1,
        ((Map<String, Object>) rows[0]).get('durationSampleSize')
      );
    }
  }

  /**
   * @description AC5: the summary does no DML and starts no job. Terminal_At__c and step
   * rows do not change.
   */
  @IsTest
  static void testReadOnly() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Datetime now = baseTime();
      Workflow_Instance__c done = seed(
        'ReadDef',
        'Completed',
        now.addSeconds(-30),
        now.addSeconds(-10)
      );
      Workflow_Instance__c running = seed('ReadDef', 'Running', now, null);
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = done.Id,
        Step_Name__c = 'ReadStep',
        Status__c = 'Completed'
      );
      Map<Id, Workflow_Instance__c> before = new Map<Id, Workflow_Instance__c>(
        [
          SELECT Id, Status__c, Terminal_At__c, SystemModstamp
          FROM Workflow_Instance__c
        ]
      );
      Workflow_Step_Execution__c stepBefore = [
        SELECT Id, SystemModstamp
        FROM Workflow_Step_Execution__c
        LIMIT 1
      ];

      Test.startTest();
      Integer dmlBefore = Limits.getDmlStatements();
      Integer jobsBefore = Limits.getQueueableJobs();
      Integer eventsBefore = Limits.getPublishImmediateDML();
      WorkflowFleetHealthController.getFleetHealth('24h');
      System.assertEquals(dmlBefore, Limits.getDmlStatements(), 'No DML');
      System.assertEquals(jobsBefore, Limits.getQueueableJobs(), 'No job');
      System.assertEquals(
        eventsBefore,
        Limits.getPublishImmediateDML(),
        'No event'
      );
      Test.stopTest();

      for (Workflow_Instance__c after : [
        SELECT Id, Status__c, Terminal_At__c, SystemModstamp
        FROM Workflow_Instance__c
      ]) {
        Workflow_Instance__c old = before.get(after.Id);
        System.assertEquals(old.Status__c, after.Status__c);
        System.assertEquals(old.Terminal_At__c, after.Terminal_At__c);
        System.assertEquals(old.SystemModstamp, after.SystemModstamp);
      }
      System.assertEquals(
        null,
        before.get(running.Id).Terminal_At__c,
        'The active row keeps a blank Terminal_At__c'
      );
      System.assertEquals(
        stepBefore.SystemModstamp,
        [
          SELECT SystemModstamp
          FROM Workflow_Step_Execution__c
          WHERE Id = :stepBefore.Id
        ]
        .SystemModstamp,
        'The step row does not change'
      );
    }
  }

  /**
   * @description AC6: three queries for each call. Query rows stay at or below the caps.
   * Above the count cap, the rows do not grow with volume. The checks are true if an
   * aggregate query uses one row for each group or one row for each record.
   */
  @IsTest
  static void testQueryCostIsBounded() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> batch = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 2; i++) {
        batch.add(
          new Workflow_Instance__c(
            Workflow_Name__c = 'CostDef',
            Status__c = 'Completed'
          )
        );
        batch.add(
          new Workflow_Instance__c(
            Workflow_Name__c = 'CostDef',
            Status__c = 'Running'
          )
        );
      }
      insert batch;
      WorkflowFleetHealthService.countCapOverride = 5;
      WorkflowFleetHealthService.sampleCapOverride = 3;
      // Probe (cap + 1) + counts (cap) + sample (cap + 1).
      Integer maxRows = (5 + 1) + 5 + (3 + 1);

      Test.startTest();
      // Cost of the gate alone, so that the check measures the summary only.
      Integer gateQueries = Limits.getQueries();
      Integer gateRows = Limits.getQueryRows();
      WorkflowDashboardSupport.checkAuthorization();
      gateQueries = Limits.getQueries() - gateQueries;
      gateRows = Limits.getQueryRows() - gateRows;

      // Under the count cap: 4 instances.
      Integer queries = Limits.getQueries();
      Integer rows = Limits.getQueryRows();
      Map<String, Object> small = WorkflowFleetHealthController.getFleetHealth(
        '24h'
      );
      Integer smallQueries = Limits.getQueries() - queries - gateQueries;
      Integer smallRows = Limits.getQueryRows() - rows - gateRows;

      // Above the count cap: 20 instances.
      List<Workflow_Instance__c> more = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 4; i++) {
        more.addAll(batch.deepClone(false, false, false));
      }
      insert more;
      queries = Limits.getQueries();
      rows = Limits.getQueryRows();
      Map<String, Object> big = WorkflowFleetHealthController.getFleetHealth(
        '24h'
      );
      Integer bigQueries = Limits.getQueries() - queries - gateQueries;
      Integer bigRows = Limits.getQueryRows() - rows - gateRows;

      // Double the volume: 40 instances.
      insert batch.deepClone(false, false, false);
      List<Workflow_Instance__c> evenMore = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 4; i++) {
        evenMore.addAll(batch.deepClone(false, false, false));
      }
      insert evenMore;
      queries = Limits.getQueries();
      rows = Limits.getQueryRows();
      WorkflowFleetHealthController.getFleetHealth('24h');
      Integer biggerQueries = Limits.getQueries() - queries - gateQueries;
      Integer biggerRows = Limits.getQueryRows() - rows - gateRows;
      Test.stopTest();

      System.assertEquals(false, small.get('countsCapped'));
      System.assertEquals(true, big.get('countsCapped'));
      System.assertEquals(3, smallQueries, 'Three queries for each call');
      System.assertEquals(3, bigQueries, 'Three queries above the cap');
      System.assertEquals(3, biggerQueries, 'Query count is constant');
      System.assert(smallRows <= maxRows, 'Rows used: ' + smallRows);
      System.assert(bigRows <= maxRows, 'Rows used: ' + bigRows);
      System.assertEquals(
        bigRows,
        biggerRows,
        'Above the cap, rows do not grow with volume'
      );
    }
  }

  /**
   * @description AC6: the controller uses the same view gate as the other panels.
   */
  @IsTest
  static void testUnauthorizedUserIsDenied() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      User stdUser = insertStandardUser();
      System.runAs(stdUser) {
        String panelMessage;
        try {
          WorkflowDashboardController.getConcurrencyStatus();
        } catch (AuraHandledException e) {
          panelMessage = e.getMessage();
        }
        try {
          WorkflowFleetHealthController.getFleetHealth('24h');
          System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
          System.assert(
            e.getMessage().contains('Unauthorized'),
            e.getMessage()
          );
          System.assertEquals(
            panelMessage,
            e.getMessage(),
            'The denial must match the other dashboard panels'
          );
        }
      }
    }
  }

  /**
   * @description Both dashboard permission sets grant the controller class.
   */
  @IsTest
  static void testPermissionSetsGrantController() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Set<String> granted = new Set<String>();
      for (SetupEntityAccess sea : [
        SELECT Parent.Name
        FROM SetupEntityAccess
        WHERE
          SetupEntityId IN (
            SELECT Id
            FROM ApexClass
            WHERE Name = 'WorkflowFleetHealthController'
          )
          AND Parent.Name IN ('Revenant_Operator', 'Revenant_Admin')
      ]) {
        granted.add(sea.Parent.Name);
      }
      System.assert(granted.contains('Revenant_Operator'), granted);
      System.assert(granted.contains('Revenant_Admin'), granted);
    }
  }
}
