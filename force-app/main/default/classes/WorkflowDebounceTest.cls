@isTest
private class WorkflowDebounceTest {
  @isTest
  static void testSingleDebounceStartsExactlyOnce() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.mockNow = Datetime.now();

    Test.startTest();
    WorkflowEngine.startDebounced(
      'WorkflowEngineTest.HappyWorkflow',
      'deb_key_1',
      '{"val":1}',
      10
    );

    // Verify no workflow instance is created yet, but Debounce_State__c exists
    List<Workflow_Instance__c> instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = 'deb_key_1'
    ];
    System.assertEquals(
      0,
      instances.size(),
      'Workflow should not start immediately'
    );

    List<Debounce_State__c> states = [
      SELECT Id, Fire_At__c, Input_Json__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'deb_key_1'
    ];
    System.assertEquals(1, states.size(), 'Debounce state should be created');
    System.assertEquals('{"val":1}', states[0].Input_Json__c);
    System.assertEquals(
      WorkflowEngine.mockNow.addSeconds(10),
      states[0].Fire_At__c
    );

    // Advance time slightly (not enough to trigger)
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(5);
    WorkflowEngine.processWatchdogHeartbeat();

    instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = 'deb_key_1'
    ];
    System.assertEquals(
      0,
      instances.size(),
      'Workflow should not start before debounce period'
    );

    // Advance time past debounce period
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(6); // Total +11s
    WorkflowEngine.processWatchdogHeartbeat();

    instances = [
      SELECT Id, Input__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = 'deb_key_1'
    ];
    System.assertEquals(
      1,
      instances.size(),
      'Workflow should start after debounce period'
    );
    System.assertEquals('{"val":1}', instances[0].Input__c);

    // Verify debounce state is deleted
    states = [
      SELECT Id
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'deb_key_1'
    ];
    System.assertEquals(
      0,
      states.size(),
      'Debounce state should be deleted after start'
    );
    Test.stopTest();
  }

  @isTest
  static void testSubsequentDebounceExtendsTimerLatestWins() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.mockNow = Datetime.now();

    Test.startTest();
    // First trigger
    WorkflowEngine.startDebounced(
      'WorkflowEngineTest.HappyWorkflow',
      'deb_key_2',
      '{"val":1}',
      10
    );

    // Advance 5 seconds and trigger again
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(5);
    WorkflowEngine.startDebounced(
      'WorkflowEngineTest.HappyWorkflow',
      'deb_key_2',
      '{"val":2}',
      10
    );

    // Verify timer extended: new Fire_At__c = start + 5 + 10 = start + 15
    List<Debounce_State__c> states = [
      SELECT Id, Fire_At__c, Input_Json__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'deb_key_2'
    ];
    System.assertEquals(1, states.size());
    System.assertEquals(
      '{"val":2}',
      states[0].Input_Json__c,
      'Latest input must win'
    );
    System.assertEquals(
      WorkflowEngine.mockNow.addSeconds(10),
      states[0].Fire_At__c
    );

    // Advance to 12s from start (which is past original 10s, but before extended 15s)
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(7); // start + 12s
    WorkflowEngine.processWatchdogHeartbeat();

    List<Workflow_Instance__c> instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = 'deb_key_2'
    ];
    System.assertEquals(
      0,
      instances.size(),
      'Workflow should not start during extended debounce period'
    );

    // Advance past extended timer
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(4); // start + 16s
    WorkflowEngine.processWatchdogHeartbeat();

    instances = [
      SELECT Id, Input__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = 'deb_key_2'
    ];
    System.assertEquals(
      1,
      instances.size(),
      'Workflow should start after extended period'
    );
    System.assertEquals(
      '{"val":2}',
      instances[0].Input__c,
      'Started instance must use latest input'
    );
    Test.stopTest();
  }

  @isTest
  static void testMaxWaitSecondsCapsExtension() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.mockNow = Datetime.now();

    Test.startTest();
    // First trigger: debounce = 10, maxWait = 15
    WorkflowEngine.startDebounced(
      'WorkflowEngineTest.HappyWorkflow',
      'deb_key_3',
      '{"val":1}',
      10,
      15
    );

    // Trigger again at start + 8s: expected extended is start + 18s, but capped at start + 15s
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(8);
    WorkflowEngine.startDebounced(
      'WorkflowEngineTest.HappyWorkflow',
      'deb_key_3',
      '{"val":2}',
      10,
      15
    );

    List<Debounce_State__c> states = [
      SELECT Id, Fire_At__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'deb_key_3'
    ];
    System.assertEquals(1, states.size());
    // First_Triggered_At__c = start
    // maxFireTime = start + 15s
    // proposedFireAt = start + 8 + 10 = start + 18s
    // Capped: start + 15s
    Datetime expectedFireAt = WorkflowEngine.mockNow.addSeconds(-8)
      .addSeconds(15);
    System.assertEquals(
      expectedFireAt,
      states[0].Fire_At__c,
      'Timer should be capped by maxWaitSeconds'
    );

    // Advance to start + 14s (before cap)
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(6); // start + 14s
    WorkflowEngine.processWatchdogHeartbeat();

    List<Workflow_Instance__c> instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = 'deb_key_3'
    ];
    System.assertEquals(0, instances.size());

    // Advance past cap
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(2); // start + 16s
    WorkflowEngine.processWatchdogHeartbeat();

    instances = [
      SELECT Id, Input__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = 'deb_key_3'
    ];
    System.assertEquals(
      1,
      instances.size(),
      'Workflow must start once cap is exceeded'
    );
    System.assertEquals('{"val":2}', instances[0].Input__c);
    Test.stopTest();
  }

  @isTest
  static void testTriggerBurstCoalescing() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.mockNow = Datetime.now();

    Test.startTest();
    // Burst of 15 calls within 5 seconds
    for (Integer i = 0; i < 15; i++) {
      WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(1);
      WorkflowEngine.startDebounced(
        'WorkflowEngineTest.HappyWorkflow',
        'deb_key_burst',
        '{"val":' + i + '}',
        10,
        30
      );
    }

    // After 15 seconds of active triggering, verify only 1 debounce state exists and no workflow started
    List<Workflow_Instance__c> instances = [
      SELECT Id
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = 'deb_key_burst'
    ];
    System.assertEquals(0, instances.size());

    List<Debounce_State__c> states = [
      SELECT Id, Input_Json__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'deb_key_burst'
    ];
    System.assertEquals(1, states.size());
    System.assertEquals(
      '{"val":14}',
      states[0].Input_Json__c,
      'Latest input should be stored'
    );

    // Advance past the latest timer
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(11);
    WorkflowEngine.processWatchdogHeartbeat();

    instances = [
      SELECT Id, Input__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = 'deb_key_burst'
    ];
    System.assertEquals(
      1,
      instances.size(),
      'Exactly one instance should have started'
    );
    System.assertEquals('{"val":14}', instances[0].Input__c);
    Test.stopTest();
  }

  @isTest
  static void testAdmissionDedupCollapsing() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.mockNow = Datetime.now();

    Test.startTest();
    // Start a normal instance for key 'deb_key_dedup' (already active)
    WorkflowEngine.StartResult first = WorkflowEngine.startOrGet(
      'WorkflowEngineTest.HappyWorkflow',
      'deb_key_dedup',
      null
    );
    System.assertEquals(true, first.isNew);

    // Call startDebounced for the same key
    WorkflowEngine.startDebounced(
      'WorkflowEngineTest.HappyWorkflow',
      'deb_key_dedup',
      '{"val":99}',
      10
    );

    // Advance time and sweep
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(11);
    WorkflowEngine.processWatchdogHeartbeat();

    // Verify it collapsed to the existing instance (no second instance created)
    List<Workflow_Instance__c> instances = [
      SELECT Id, Input__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = 'deb_key_dedup'
    ];
    System.assertEquals(
      1,
      instances.size(),
      'Should collapse to single instance'
    );
    System.assertEquals(
      null,
      instances[0].Input__c,
      'Should retain original input'
    );

    // Verify debounce state is deleted
    List<Debounce_State__c> states = [
      SELECT Id
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'deb_key_dedup'
    ];
    System.assertEquals(
      0,
      states.size(),
      'Debounce state should be cleaned up even if start was deduped'
    );
    Test.stopTest();
  }

  @isTest
  static void testLargePayloadValidation() {
    String largeJson = 'x'.repeat(131073);
    try {
      WorkflowEngine.startDebounced(
        'WorkflowEngineTest.HappyWorkflow',
        'deb_key_large',
        largeJson,
        10
      );
      System.assert(false, 'Should have failed due to payload size limit');
    } catch (WorkflowEngine.WorkflowException ex) {
      System.assert(
        ex.getMessage()
          .contains('Input JSON payload exceeds maximum size limit'),
        'Exception message should mention size limit'
      );
    }
  }

  @isTest
  static void testDebounceMetadataPreservation() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.mockNow = Datetime.now();

    Test.startTest();
    WorkflowEngine.startDebounced(
      'WorkflowEngineTest.HappyWorkflow',
      'deb_key_metadata',
      '{"val":1}',
      10,
      15,
      '{"attr1":"val1"}',
      'causation123'
    );

    // Verify debounce state record contains attributes and causation
    List<Debounce_State__c> states = [
      SELECT Id, Attributes_Json__c, Causation_Id__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'deb_key_metadata'
    ];
    System.assertEquals(1, states.size());
    System.assertEquals('{"attr1":"val1"}', states[0].Attributes_Json__c);
    System.assertEquals('causation123', states[0].Causation_Id__c);

    // Advance time and sweep
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(11);
    WorkflowEngine.processWatchdogHeartbeat();

    // Verify workflow instance started and has attributes and causation
    List<Workflow_Instance__c> instances = [
      SELECT Id, Causation_Id__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = 'deb_key_metadata'
    ];
    System.assertEquals(1, instances.size());
    System.assertEquals('causation123', instances[0].Causation_Id__c);

    List<Workflow_Search_Attribute__c> attrs = [
      SELECT Key__c, Value__c
      FROM Workflow_Search_Attribute__c
      WHERE Workflow_Instance__c = :instances[0].Id
    ];
    System.assertEquals(1, attrs.size());
    System.assertEquals('attr1', attrs[0].Key__c);
    System.assertEquals('val1', attrs[0].Value__c);
    Test.stopTest();
  }

  @isTest
  static void testOverlongCorrelationKeyValidation() {
    String longKey = 'k'.repeat(201);
    try {
      WorkflowEngine.startDebounced(
        'WorkflowEngineTest.HappyWorkflow',
        longKey,
        '{}',
        10
      );
      System.assert(false, 'Should have failed due to correlation key length');
    } catch (WorkflowEngine.WorkflowException ex) {
      System.assert(
        ex.getMessage()
          .contains('Correlation key length cannot exceed 200 characters'),
        'Exception message should mention 200 character limit'
      );
    }
  }

  @isTest
  static void testFailedDebounceRetryAndQuarantine() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.mockNow = Datetime.now();

    Test.startTest();
    // Enqueue debounce state with a invalid/non-existent workflow name
    WorkflowEngine.startDebounced(
      'NonExistentWorkflowClassDoesNotExist',
      'deb_key_fail_retry',
      '{}',
      10
    );

    // Verify debounce state created
    List<Debounce_State__c> states = [
      SELECT Id, Fire_At__c, Retry_Count__c, Error_Message__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'deb_key_fail_retry'
    ];
    System.assertEquals(1, states.size());
    System.assertEquals(0, states[0].Retry_Count__c);

    // 1st Sweep: Advance 11 seconds and run sweep
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(11);
    WorkflowDebouncer.sweep();

    states = [
      SELECT Id, Fire_At__c, Retry_Count__c, Error_Message__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'deb_key_fail_retry'
    ];
    System.assertEquals(1, states.size(), 'Poison row should not be deleted');
    System.assertEquals(
      1,
      states[0].Retry_Count__c,
      'Retry count should be incremented to 1'
    );
    System.assertNotEquals(null, states[0].Error_Message__c);
    System.assertEquals(
      WorkflowEngine.mockNow.addSeconds(60),
      states[0].Fire_At__c,
      'Fire time should be pushed by 60s'
    );

    // 2nd Sweep: Sweep again at current time (should skip since Fire_At__c is in the future)
    WorkflowDebouncer.sweep();
    states = [
      SELECT Id, Retry_Count__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'deb_key_fail_retry'
    ];
    System.assertEquals(
      1,
      states[0].Retry_Count__c,
      'Retry count should still be 1 (skipped)'
    );

    // 3rd Sweep: Advance past the 1-minute retry push (61 seconds) and sweep
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(61);
    WorkflowDebouncer.sweep();

    states = [
      SELECT Id, Fire_At__c, Retry_Count__c, Error_Message__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'deb_key_fail_retry'
    ];
    System.assertEquals(2, states[0].Retry_Count__c, 'Retry count should be 2');
    System.assertEquals(
      WorkflowEngine.mockNow.addSeconds(120),
      states[0].Fire_At__c,
      'Fire time should be pushed by 120s'
    );

    // 4th Sweep: Advance past the 2-minute retry push (121 seconds) and sweep
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(121);
    WorkflowDebouncer.sweep();

    states = [
      SELECT Id, Fire_At__c, Retry_Count__c, Error_Message__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'deb_key_fail_retry'
    ];
    System.assertEquals(3, states[0].Retry_Count__c, 'Retry count should be 3');
    System.assertEquals(
      WorkflowEngine.mockNow.addYears(100),
      states[0].Fire_At__c,
      'Fire time should be far-future (quarantined)'
    );

    // 5th Sweep: Sweep again. Since Retry_Count__c >= 3, it should never be picked up
    WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(1000);
    WorkflowDebouncer.sweep();

    states = [
      SELECT Id, Retry_Count__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = 'deb_key_fail_retry'
    ];
    System.assertEquals(
      3,
      states[0].Retry_Count__c,
      'Retry count should stay at 3 (completely ignored by sweep)'
    );
    Test.stopTest();
  }

  @isTest
  static void testDebounceKeyHashLengthSafety() {
    // Generate a long workflow name (>60 chars) and a long correlation key (200 chars)
    String longWorkflowName = 'a'.repeat(60);
    String longCorrelationKey = 'b'.repeat(200);

    Test.startTest();
    WorkflowEngine.startDebounced(
      longWorkflowName,
      longCorrelationKey,
      '{}',
      10
    );
    Test.stopTest();

    // Verify it was successfully saved
    List<Debounce_State__c> states = [
      SELECT Id, Debounce_Key__c
      FROM Debounce_State__c
      WHERE Correlation_Key__c = :longCorrelationKey
    ];
    System.assertEquals(1, states.size());
    // Verify unique key is a 32-character MD5 hash
    System.assertEquals(32, states[0].Debounce_Key__c.length());
  }

  @isTest
  static void testAttributesValidationLimits() {
    // 1. Exceed attribute count (11 attributes)
    Map<String, Object> tooManyAttrs = new Map<String, Object>();
    for (Integer i = 0; i < 11; i++) {
      tooManyAttrs.put('key' + i, 'val' + i);
    }
    try {
      WorkflowEngine.startDebounced(
        'WorkflowEngineTest.HappyWorkflow',
        'deb_key_limits_1',
        '{}',
        10,
        15,
        JSON.serialize(tooManyAttrs),
        'causation1'
      );
      System.assert(false, 'Should have failed due to attribute count limit');
    } catch (WorkflowEngine.WorkflowException ex) {
      System.assert(
        ex.getMessage().contains('Attribute count exceeds maximum limit'),
        'Exception message should indicate attribute count limit exceeded: ' +
        ex.getMessage()
      );
    }

    // 2. Exceed key length (101 characters)
    Map<String, Object> longKeyAttrs = new Map<String, Object>{
      'k'.repeat(101) => 'val'
    };
    try {
      WorkflowEngine.startDebounced(
        'WorkflowEngineTest.HappyWorkflow',
        'deb_key_limits_2',
        '{}',
        10,
        15,
        JSON.serialize(longKeyAttrs),
        'causation2'
      );
      System.assert(false, 'Should have failed due to key length limit');
    } catch (WorkflowEngine.WorkflowException ex) {
      System.assert(
        ex.getMessage().contains('Attribute key length exceeds maximum limit'),
        'Exception message should indicate key length limit exceeded: ' +
        ex.getMessage()
      );
    }

    // 3. Exceed value length (151 characters)
    Map<String, Object> longValAttrs = new Map<String, Object>{
      'key' => 'v'.repeat(151)
    };
    try {
      WorkflowEngine.startDebounced(
        'WorkflowEngineTest.HappyWorkflow',
        'deb_key_limits_3',
        '{}',
        10,
        15,
        JSON.serialize(longValAttrs),
        'causation3'
      );
      System.assert(false, 'Should have failed due to value length limit');
    } catch (WorkflowEngine.WorkflowException ex) {
      System.assert(
        ex.getMessage()
          .contains('Attribute value length exceeds maximum limit'),
        'Exception message should indicate value length limit exceeded: ' +
        ex.getMessage()
      );
    }
  }
}
