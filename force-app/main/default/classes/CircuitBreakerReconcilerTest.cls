/**
 * Tests for the half-open sweep order and bounds (issue #236).
 * Due rows must not wait behind Open rows that are not due.
 */
@IsTest
private class CircuitBreakerReconcilerTest {
  // Open duration 30 s: a row opened 60 s ago is due.
  private static final Integer SHORT_SECONDS = 30;
  // Open duration 3600 s: a row opened 600 s ago is not due.
  private static final Integer LONG_SECONDS = 3600;

  private static Circuit_Breaker_Config__mdt cfg(
    String developerName,
    Integer openSeconds
  ) {
    return (Circuit_Breaker_Config__mdt) JSON.deserialize(
      '{"DeveloperName":"' +
        developerName +
        '","Failure_Threshold__c":1,"Rolling_Window_Seconds__c":60' +
        ',"Open_Duration_Seconds__c":' +
        openSeconds +
        ',"Half_Open_Probe_Count__c":1}',
      Circuit_Breaker_Config__mdt.class
    );
  }

  // Adds a config and returns an Open row (not inserted).
  private static Circuit_Breaker_State__c openRow(
    String key,
    Integer openSeconds,
    Integer openedSecondsAgo
  ) {
    CircuitBreakerGate.mockConfigs.put(key, cfg(key, openSeconds));
    return new Circuit_Breaker_State__c(
      Dependency_Key__c = key,
      Status__c = 'Open',
      Failure_Count__c = 1,
      Half_Open_Probes_Admitted__c = 0,
      Opened_At__c = Datetime.now().addSeconds(-openedSecondsAgo)
    );
  }

  private static String statusOf(String key) {
    return [
      SELECT Status__c
      FROM Circuit_Breaker_State__c
      WHERE Dependency_Key__c = :key
    ]
    .Status__c;
  }

  @IsTest
  static void testDueRowFlipsBehindFullBatchOfRowsNotDue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerReconciler.sweepBatchSize = 2;
      insert new List<Circuit_Breaker_State__c>{
        openRow('NotDueA', LONG_SECONDS, 600),
        openRow('NotDueB', LONG_SECONDS, 600),
        openRow('Due', SHORT_SECONDS, 60)
      };
      Test.startTest();
      CircuitBreakerGate.sweepHalfOpen();
      Test.stopTest();
      System.assertEquals(
        'HalfOpen',
        statusOf('Due'),
        'A due row flips when rows that are not due fill the batch'
      );
      System.assertEquals('Open', statusOf('NotDueA'), 'Not due: stays Open');
      System.assertEquals('Open', statusOf('NotDueB'), 'Not due: stays Open');
    }
  }

  @IsTest
  static void testDueRowFlipsBehindFullBatchOfRowsWithNoConfig() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerReconciler.sweepBatchSize = 2;
      // An open duration of 0 is not valid, so the key has no config.
      insert new List<Circuit_Breaker_State__c>{
        openRow('NoConfigA', 0, 600),
        openRow('NoConfigB', 0, 600),
        openRow('Due', SHORT_SECONDS, 60)
      };
      Test.startTest();
      CircuitBreakerGate.sweepHalfOpen();
      Test.stopTest();
      System.assertEquals(
        'HalfOpen',
        statusOf('Due'),
        'A due row flips when rows with no config fill the batch'
      );
      System.assertEquals('Open', statusOf('NoConfigA'), 'No config: no flip');
      System.assertEquals('Open', statusOf('NoConfigB'), 'No config: no flip');
    }
  }

  @IsTest
  static void testNullOpenedAtIsFirstAndDue() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerReconciler.sweepBatchSize = 1;
      Circuit_Breaker_State__c noTime = openRow('NoTime', LONG_SECONDS, 0);
      noTime.Opened_At__c = null;
      insert new List<Circuit_Breaker_State__c>{
        openRow('Due', SHORT_SECONDS, 60),
        noTime
      };
      Test.startTest();
      CircuitBreakerGate.sweepHalfOpen();
      Test.stopTest();
      System.assertEquals(
        'HalfOpen',
        statusOf('NoTime'),
        'A null Opened_At__c sorts first and is due'
      );
      System.assertEquals(
        'Open',
        statusOf('Due'),
        'The batch of 1 is full, so this row waits'
      );
    }
  }

  @IsTest
  static void testBatchFlipsOldestDueRowsFirst() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerReconciler.sweepBatchSize = 2;
      // Insert the newest row first, so Id order is not Opened_At__c order.
      insert new List<Circuit_Breaker_State__c>{
        openRow('DueNew', SHORT_SECONDS, 60),
        openRow('DueMid', SHORT_SECONDS, 120),
        openRow('DueOld', SHORT_SECONDS, 180)
      };
      Test.startTest();
      CircuitBreakerGate.sweepHalfOpen();
      Test.stopTest();
      System.assertEquals('HalfOpen', statusOf('DueOld'), 'Oldest: flips');
      System.assertEquals('HalfOpen', statusOf('DueMid'), 'Second: flips');
      System.assertEquals(
        'Open',
        statusOf('DueNew'),
        'The newest due row waits for the next heartbeat'
      );
    }
  }

  @IsTest
  static void testNoDueRowUsesOneQuery() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert openRow('NotDue', LONG_SECONDS, 600);
      Test.startTest();
      Integer q0 = Limits.getQueries();
      Integer d0 = Limits.getDmlStatements();
      CircuitBreakerGate.sweepHalfOpen();
      System.assertEquals(
        q0 + 1,
        Limits.getQueries(),
        'No due row: one find query only'
      );
      System.assertEquals(d0, Limits.getDmlStatements(), 'No due row: 0 DML');
      Test.stopTest();
      System.assertEquals('Open', statusOf('NotDue'), 'Not due: stays Open');
    }
  }

  @IsTest
  static void testDueRowUsesFindAndLockQueries() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert openRow('Due', SHORT_SECONDS, 60);
      Test.startTest();
      Integer q0 = Limits.getQueries();
      CircuitBreakerGate.sweepHalfOpen();
      System.assertEquals(
        q0 + 2,
        Limits.getQueries(),
        'Due row: one find query and one lock query'
      );
      Test.stopTest();
      System.assertEquals('HalfOpen', statusOf('Due'), 'Due: flips');
    }
  }

  @IsTest
  static void testLockSkipsRowThatIsNoLongerOpen() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Circuit_Breaker_State__c row = openRow('Moved', SHORT_SECONDS, 60);
      row.Status__c = 'HalfOpen';
      insert row;
      Test.startTest();
      List<Circuit_Breaker_State__c> locked = CircuitBreakerReconciler.lockDueRows(
        new List<Id>{ row.Id },
        Datetime.now(),
        CircuitBreakerGate.mockConfigs
      );
      Test.stopTest();
      System.assert(locked.isEmpty(), 'A row that is not Open is not returned');
    }
  }

  @IsTest
  static void testLockSkipsRowThatOpenedAgain() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Circuit_Breaker_State__c reopened = openRow('Reopened', SHORT_SECONDS, 0);
      Circuit_Breaker_State__c due = openRow('Due', SHORT_SECONDS, 60);
      insert new List<Circuit_Breaker_State__c>{ reopened, due };
      Test.startTest();
      List<Circuit_Breaker_State__c> locked = CircuitBreakerReconciler.lockDueRows(
        new List<Id>{ reopened.Id, due.Id },
        Datetime.now(),
        CircuitBreakerGate.mockConfigs
      );
      Test.stopTest();
      System.assertEquals(1, locked.size(), 'Only the due row is returned');
      System.assertEquals(due.Id, locked[0].Id, 'The due row is returned');
    }
  }

  @IsTest
  static void testDueRowAfterScanWindowStaysOpen() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      CircuitBreakerReconciler.sweepScanLimit = 2;
      insert new List<Circuit_Breaker_State__c>{
        openRow('NotDueA', LONG_SECONDS, 600),
        openRow('NotDueB', LONG_SECONDS, 600),
        openRow('Due', SHORT_SECONDS, 60)
      };
      Test.startTest();
      CircuitBreakerGate.sweepHalfOpen();
      Test.stopTest();
      System.assertEquals(
        'Open',
        statusOf('Due'),
        'The scan window is the bound: a row after it waits'
      );
    }
  }
}
