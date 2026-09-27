/**
 * @description Tests for WorkflowRateLimitStatusService, the read service of the
 * System Doctor Rate Limits panel (#61). Pure tests use a fixed clock. Database tests
 * use RateLimiter.mockConfigs, so org CMDT records do not change the result.
 */
@IsTest
private class WorkflowRateLimitStatusServiceTest {
  private static final Long NOW_MS = 1790000000000L;

  private static Rate_Limit_Config__mdt config(
    String key,
    Decimal capacity,
    Decimal rate
  ) {
    return (Rate_Limit_Config__mdt) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'DeveloperName' => key,
          'Capacity__c' => capacity,
          'Refill_Rate_Per_Second__c' => rate
        }
      ),
      Rate_Limit_Config__mdt.class
    );
  }

  private static Rate_Limit_State__c state(
    String key,
    Decimal tokens,
    Long lastMs
  ) {
    return new Rate_Limit_State__c(
      Integration_Key__c = key,
      Tokens_Remaining__c = tokens,
      Last_Refill_Time_Ms__c = lastMs
    );
  }

  private static Map<String, Object> rowFor(
    List<Map<String, Object>> rows,
    String key
  ) {
    for (Map<String, Object> row : rows) {
      if (row.get('integrationKey') == key) {
        return row;
      }
    }
    System.assert(false, 'No row for ' + key);
    return null;
  }

  private static List<Map<String, Object>> build(
    Map<String, Rate_Limit_Config__mdt> configs,
    List<Rate_Limit_State__c> states
  ) {
    return WorkflowRateLimitStatusService.buildRows(configs, states, NOW_MS);
  }

  /**
   * @description AC2: the row shows the refilled value, not the stored value.
   */
  @IsTest
  static void testLiveRefillComputation() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Map<String, Object>> rows = build(
        new Map<String, Rate_Limit_Config__mdt>{
          'StripeApi' => config('StripeApi', 10, 2.0)
        },
        new List<Rate_Limit_State__c>{ state('StripeApi', 1.0, NOW_MS - 1000) }
      );
      Map<String, Object> row = rowFor(rows, 'StripeApi');
      System.assertEquals(
        3.0,
        (Decimal) row.get('availableTokens'),
        'Unexpected value of (Decimal) row.get(\'availableTokens\')'
      );
      System.assertEquals(
        'AVAILABLE',
        row.get('status'),
        'Unexpected value of row.get(\'status\')'
      );
      System.assertEquals(
        10.0,
        (Decimal) row.get('capacity'),
        'Unexpected value of (Decimal) row.get(\'capacity\')'
      );
      System.assertEquals(
        2.0,
        (Decimal) row.get('refillRatePerSecond'),
        'Unexpected value of (Decimal) row.get(\'refillRatePerSecond\')'
      );
      System.assertEquals(
        null,
        row.get('secondsUntilNextToken'),
        'Unexpected value of row.get(\'secondsUntilNextToken\')'
      );
    }
  }

  /**
   * @description AC3: fewer than 1 token is Throttling with a wait time.
   */
  @IsTest
  static void testThrottlingKey() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Map<String, Object>> rows = build(
        new Map<String, Rate_Limit_Config__mdt>{
          'FastApi' => config('FastApi', 10, 2.0),
          'SlowApi' => config('SlowApi', 5, 0.1)
        },
        new List<Rate_Limit_State__c>{
          state('FastApi', 0.5, NOW_MS),
          state('SlowApi', 0.0, NOW_MS)
        }
      );
      Map<String, Object> fast = rowFor(rows, 'FastApi');
      System.assertEquals(
        'THROTTLING',
        fast.get('status'),
        'Unexpected value of fast.get(\'status\')'
      );
      System.assertEquals(
        0.5,
        (Decimal) fast.get('availableTokens'),
        'Unexpected value of (Decimal) fast.get(\'availableTokens\')'
      );
      System.assertEquals(
        1L,
        (Long) fast.get('secondsUntilNextToken'),
        'Unexpected value of (Long) fast.get(\'secondsUntilNextToken\')'
      );
      Map<String, Object> slow = rowFor(rows, 'SlowApi');
      System.assertEquals(
        'THROTTLING',
        slow.get('status'),
        'Unexpected value of slow.get(\'status\')'
      );
      System.assertEquals(
        10L,
        (Long) slow.get('secondsUntilNextToken'),
        'Unexpected value of (Long) slow.get(\'secondsUntilNextToken\')'
      );
    }
  }

  /**
   * @description The Throttling boundary is the acquire() boundary (< 1 token).
   * The shown value rounds down, so the row never shows more tokens than exist.
   */
  @IsTest
  static void testThrottlingBoundaryAndRoundDown() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Map<String, Object>> rows = build(
        new Map<String, Rate_Limit_Config__mdt>{
          'EdgeApi' => config('EdgeApi', 10, 1.0),
          'OneApi' => config('OneApi', 10, 1.0)
        },
        new List<Rate_Limit_State__c>{
          state('EdgeApi', 0.9999, NOW_MS),
          state('OneApi', 1.0, NOW_MS)
        }
      );
      Map<String, Object> edge = rowFor(rows, 'EdgeApi');
      System.assertEquals(
        'THROTTLING',
        edge.get('status'),
        'Unexpected value of edge.get(\'status\')'
      );
      System.assertEquals(
        0.99,
        (Decimal) edge.get('availableTokens'),
        'Unexpected value of (Decimal) edge.get(\'availableTokens\')'
      );
      System.assertEquals(
        1L,
        (Long) edge.get('secondsUntilNextToken'),
        'Unexpected value of (Long) edge.get(\'secondsUntilNextToken\')'
      );
      System.assertEquals(
        'AVAILABLE',
        rowFor(rows, 'OneApi').get('status'),
        'Unexpected value of rowFor(rows, \'OneApi\').get(\'status\')'
      );
    }
  }

  /**
   * @description AC4: a key with no state row is Idle at full capacity.
   */
  @IsTest
  static void testNeverExercisedKeyIsIdle() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Map<String, Object>> rows = build(
        new Map<String, Rate_Limit_Config__mdt>{
          'NewApi' => config('NewApi', 7, 1.0)
        },
        new List<Rate_Limit_State__c>()
      );
      Map<String, Object> row = rowFor(rows, 'NewApi');
      System.assertEquals(
        'IDLE',
        row.get('status'),
        'Unexpected value of row.get(\'status\')'
      );
      System.assertEquals(
        7.0,
        (Decimal) row.get('availableTokens'),
        'Unexpected value of (Decimal) row.get(\'availableTokens\')'
      );
      System.assertEquals(
        null,
        row.get('secondsUntilNextToken'),
        'Unexpected value of row.get(\'secondsUntilNextToken\')'
      );
    }
  }

  /**
   * @description acquire() stores the caller's key casing. The join ignores case.
   */
  @IsTest
  static void testStateJoinIgnoresCase() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Map<String, Object>> rows = build(
        new Map<String, Rate_Limit_Config__mdt>{
          'StripeApi' => config('StripeApi', 10, 1.0)
        },
        new List<Rate_Limit_State__c>{ state('stripeapi', 0.0, NOW_MS) }
      );
      System.assertEquals(
        'THROTTLING',
        rowFor(rows, 'StripeApi').get('status'),
        'Unexpected value of rowFor(rows, \'StripeApi\').get(\'status\')'
      );
    }
  }

  /**
   * @description A config that acquire() rejects shows as Invalid. It never throws.
   */
  @IsTest
  static void testInvalidConfigNeverThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Map<String, Object>> rows = build(
        new Map<String, Rate_Limit_Config__mdt>{
          'NoCapacity' => config('NoCapacity', 0, 1.0),
          'NoRate' => config('NoRate', 5, 0)
        },
        new List<Rate_Limit_State__c>{ state('NoRate', 0.0, NOW_MS) }
      );
      for (String key : new List<String>{ 'NoCapacity', 'NoRate' }) {
        Map<String, Object> row = rowFor(rows, key);
        System.assertEquals(
          'INVALID',
          row.get('status'),
          'Unexpected value of row.get(\'status\')'
        );
        System.assertEquals(
          null,
          row.get('availableTokens'),
          'Unexpected value of row.get(\'availableTokens\')'
        );
        System.assertEquals(
          null,
          row.get('secondsUntilNextToken'),
          'Unexpected value of row.get(\'secondsUntilNextToken\')'
        );
      }
    }
  }

  /**
   * @description Rows sort bad news first, then by key without case.
   */
  @IsTest
  static void testRowsSortBadNewsFirst() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Map<String, Object>> rows = build(
        new Map<String, Rate_Limit_Config__mdt>{
          'bIdle' => config('bIdle', 5, 1.0),
          'aIdle' => config('aIdle', 5, 1.0),
          'Ok' => config('Ok', 5, 1.0),
          'Busy' => config('Busy', 5, 1.0),
          'Broken' => config('Broken', 0, 1.0)
        },
        new List<Rate_Limit_State__c>{
          state('Ok', 3.0, NOW_MS),
          state('Busy', 0.0, NOW_MS)
        }
      );
      List<String> order = new List<String>();
      for (Map<String, Object> row : rows) {
        order.add((String) row.get('integrationKey'));
      }
      System.assertEquals(
        new List<String>{ 'Broken', 'Busy', 'Ok', 'aIdle', 'bIdle' },
        order,
        'Unexpected value of order'
      );
    }
  }

  /**
   * @description No configs give no rows.
   */
  @IsTest
  static void testNoConfigsGiveNoRows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        0,
        build(
            new Map<String, Rate_Limit_Config__mdt>(),
            new List<Rate_Limit_State__c>()
          )
          .size(),
        'Unexpected value of build( new Map<String, Rate_Limit_Config__mdt>(), new Lis...'
      );
    }
  }

  /**
   * @description The endpoint reads live state from the database and writes nothing.
   */
  @IsTest
  static void testRateLimitStatusReadsDatabase() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      RateLimiter.mockConfigs.put('LiveApi', config('LiveApi', 10, 2.0));
      RateLimiter.mockConfigs.put('HeldApi', config('HeldApi', 10, 0.5));
      RateLimiter.mockConfigs.put('IdleApi', config('IdleApi', 4, 1.0));
      insert new List<Rate_Limit_State__c>{
        // 2 s ago with 1 token stored: live value is at least 5.
        state('LiveApi', 1.0, System.currentTimeMillis() - 2000),
        // Future timestamp: elapsed time clamps to 0, so the value is exact.
        state('HeldApi', 0.0, System.currentTimeMillis() + 60000)
      };

      Test.startTest();
      Integer dmlBefore = Limits.getDmlStatements();
      Map<String, Object> result = WorkflowRateLimitStatusService.rateLimitStatus();
      Integer dmlAfter = Limits.getDmlStatements();
      Test.stopTest();

      System.assertEquals(dmlBefore, dmlAfter, 'The panel must not write');
      System.assert(
        result.get('asOfMs') instanceof Long,
        'Expected true: result.get(\'asOfMs\') instanceof Long'
      );
      List<Map<String, Object>> rows = (List<Map<String, Object>>) result.get(
        'rows'
      );
      System.assertEquals(3, rows.size(), 'Unexpected value of rows.size()');

      Map<String, Object> live = rowFor(rows, 'LiveApi');
      System.assertEquals(
        'AVAILABLE',
        live.get('status'),
        'Unexpected value of live.get(\'status\')'
      );
      System.assert(
        (Decimal) live.get('availableTokens') >= 5.0,
        'Live value must include refill: ' + live.get('availableTokens')
      );

      Map<String, Object> held = rowFor(rows, 'HeldApi');
      System.assertEquals(
        'THROTTLING',
        held.get('status'),
        'Unexpected value of held.get(\'status\')'
      );
      System.assertEquals(
        0.0,
        (Decimal) held.get('availableTokens'),
        'Unexpected value of (Decimal) held.get(\'availableTokens\')'
      );
      System.assertEquals(
        2L,
        (Long) held.get('secondsUntilNextToken'),
        'Unexpected value of (Long) held.get(\'secondsUntilNextToken\')'
      );

      Map<String, Object> idle = rowFor(rows, 'IdleApi');
      System.assertEquals(
        'IDLE',
        idle.get('status'),
        'Unexpected value of idle.get(\'status\')'
      );
      System.assertEquals(
        4.0,
        (Decimal) idle.get('availableTokens'),
        'Unexpected value of (Decimal) idle.get(\'availableTokens\')'
      );
    }
  }

  /**
   * @description The panel agrees with the next acquire() call.
   */
  @IsTest
  static void testStatusMatchesAcquire() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      RateLimiter.mockConfigs.put('PairApi', config('PairApi', 2, 0.0001));
      Test.startTest();
      System.assert(
        RateLimiter.acquire('PairApi').isAllowed,
        'Expected true: RateLimiter.acquire(\'PairApi\').isAllowed'
      );
      System.assertEquals(
        'AVAILABLE',
        statusOf('PairApi'),
        '1 token left: acquire() would allow'
      );
      System.assert(
        RateLimiter.acquire('PairApi').isAllowed,
        'Expected true: RateLimiter.acquire(\'PairApi\').isAllowed'
      );
      System.assertEquals(
        'THROTTLING',
        statusOf('PairApi'),
        '0 tokens left: acquire() would throttle'
      );
      System.assert(
        !RateLimiter.acquire('PairApi').isAllowed,
        'Expected true: !RateLimiter.acquire(\'PairApi\').isAllowed'
      );
      Test.stopTest();
    }
  }

  private static String statusOf(String key) {
    List<Map<String, Object>> rows = (List<Map<String, Object>>) WorkflowRateLimitStatusService.rateLimitStatus()
      .get('rows');
    return (String) rowFor(rows, key).get('status');
  }

  /**
   * @description Without mocks the endpoint reads the CMDT records and does not fail.
   */
  @IsTest
  static void testRateLimitStatusWithoutMocks() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      RateLimiter.mockConfigs.clear();
      Map<String, Object> result = WorkflowRateLimitStatusService.rateLimitStatus();
      List<Map<String, Object>> rows = (List<Map<String, Object>>) result.get(
        'rows'
      );
      System.assertEquals(
        RateLimiter.configuredLimits().size(),
        rows.size(),
        'Unexpected value of rows.size()'
      );
    }
  }
}
