/**
 * @description Integration tests for the routing/dedup behavior of opt-in start-input
 * validation (issue #51): the contract is enforced only on requests that create a
 * NEW instance, so get-or-start / signal-or-start dedup hits (pre-existing or an
 * intra-batch valid sibling) are delivered, and a debounced invalid input fails
 * observably at sweep. The `ContractWorkflow` fixture lives in the public
 * {@link WorkflowInputValidationTest}; these tests reference it by name.
 */
@IsTest
private class WorkflowInputValidationRoutingTest {
  private static final String CONTRACT_WF = 'WorkflowInputValidationTest.ContractWorkflow';

  private static Integer instanceCountForKey(String key) {
    return [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :key
    ];
  }

  private static Integer debounceStateCountForKey(String key) {
    return [
      SELECT COUNT()
      FROM Debounce_State__c
      WHERE Correlation_Key__c = :key
    ];
  }

  private static Map<String, Object> validInput() {
    return new Map<String, Object>{
      'accountId' => 'ACME-ACCOUNT-1',
      'amount' => 2500,
      'vipOnboarding' => true,
      'startDate' => '2026-07-19'
    };
  }

  // ── FIX 4: contract enforced only on NEW starts; dedup hits are not blocked ───

  @IsTest
  static void testScalarGetOrStartExistingWithInvalidFallbackNotBlocked() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // An instance already exists (started with valid input).
      Id existingId = WorkflowEngine.start(
        CONTRACT_WF,
        'VIV_exist_scalar',
        validInput()
      );

      // A get-or-start to the SAME key with an invalid fallback must dedup to the
      // existing instance WITHOUT throwing — its fallback input is never persisted.
      WorkflowEngine.StartResult res = WorkflowEngine.startOrGet(
        new WorkflowEngine.StartRequest(
          CONTRACT_WF,
          'VIV_exist_scalar',
          new Map<String, Object>{ 'amount' => 5 } // missing accountId
        )
      );

      System.assertEquals(existingId, res.instanceId, 'Deduped to existing');
      System.assertEquals(false, res.isNew);
      System.assertEquals(
        1,
        instanceCountForKey('VIV_exist_scalar'),
        'No new instance created for the dedup hit'
      );
    }
  }

  @IsTest
  static void testBulkSignalOrStartExistingWithInvalidFallbackDelivers() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // A suspended instance already exists for the key (proven signal-target
      // pattern), so signal-or-start dedups to it.
      Workflow_Instance__c existing = new Workflow_Instance__c(
        Workflow_Name__c = CONTRACT_WF,
        Status__c = 'Suspended',
        Correlation_Key__c = 'VIV_exist_sos'
      );
      insert existing;

      // signal-or-start to the existing instance with an invalid/minimal fallback:
      // the signal must be delivered (existing returned), no throw, no new instance.
      WorkflowEngine.StartRequest badStart = new WorkflowEngine.StartRequest(
        CONTRACT_WF,
        'VIV_exist_sos',
        new Map<String, Object>{ 'amount' => 5 } // missing accountId
      );
      WorkflowEngine.SignalOrStartRequest sosReq = new WorkflowEngine.SignalOrStartRequest(
        badStart,
        'WakeUp',
        '{"x":1}'
      );

      List<WorkflowEngine.StartResult> res = WorkflowEngine.signalOrStart(
        new List<WorkflowEngine.SignalOrStartRequest>{ sosReq }
      );

      System.assertEquals(1, res.size());
      System.assertEquals(
        existing.Id,
        res[0].instanceId,
        'Signal delivered to existing'
      );
      System.assertEquals(1, instanceCountForKey('VIV_exist_sos'));
    }
  }

  @IsTest
  static void testInvocableGetOrStartExistingWithInvalidFallbackDelivers() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id existingId = WorkflowEngine.start(
        CONTRACT_WF,
        'VIV_inv_exist',
        validInput()
      );

      WorkflowStartInvocableAction.StartRequest bad = new WorkflowStartInvocableAction.StartRequest();
      bad.workflowName = CONTRACT_WF;
      bad.correlationKey = 'VIV_inv_exist';
      bad.inputJson = '{"amount":5}'; // missing accountId

      Test.startTest();
      List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
        new List<WorkflowStartInvocableAction.StartRequest>{ bad }
      );
      Test.stopTest();

      System.assertEquals(1, results.size());
      System.assertEquals(
        true,
        results[0].isValid,
        'A get-or-start dedup hit is delivered, not blocked by an unused invalid fallback'
      );
      System.assertEquals(existingId, results[0].workflowInstanceId);
      System.assertEquals(1, instanceCountForKey('VIV_inv_exist'));
    }
  }

  @IsTest
  static void testInvocableSignalOrStartExistingWithInvalidFallbackDelivers() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c existing = new Workflow_Instance__c(
        Workflow_Name__c = CONTRACT_WF,
        Status__c = 'Suspended',
        Correlation_Key__c = 'VIV_sos_exist'
      );
      insert existing;

      WorkflowSignalOrStartInvocableAction.SignalOrStartRequest bad = new WorkflowSignalOrStartInvocableAction.SignalOrStartRequest();
      bad.workflowName = CONTRACT_WF;
      bad.correlationKey = 'VIV_sos_exist';
      bad.inputJson = '{"amount":5}'; // missing accountId
      bad.signalName = 'WakeUp';
      bad.payloadJson = '{"x":1}';

      Test.startTest();
      List<WorkflowSignalOrStartInvocableAction.SignalOrStartResult> results = WorkflowSignalOrStartInvocableAction.signalOrStartWorkflow(
        new List<WorkflowSignalOrStartInvocableAction.SignalOrStartRequest>{
          bad
        }
      );
      Test.stopTest();

      System.assertEquals(1, results.size());
      System.assertEquals(
        true,
        results[0].isValid,
        'A signal-or-start dedup hit is delivered, not blocked by an unused invalid fallback'
      );
      System.assertEquals(existing.Id, results[0].workflowInstanceId);
      System.assertEquals(1, instanceCountForKey('VIV_sos_exist'));
    }
  }

  @IsTest
  static void testInvocableSignalOrStartNewInvalidRejected() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // No existing instance for this key: a genuine new start with invalid input
      // is rejected with a branchable isValid=false and nothing is created.
      WorkflowSignalOrStartInvocableAction.SignalOrStartRequest bad = new WorkflowSignalOrStartInvocableAction.SignalOrStartRequest();
      bad.workflowName = CONTRACT_WF;
      bad.correlationKey = 'VIV_sos_new';
      bad.inputJson = '{"amount":5}'; // missing accountId
      bad.signalName = 'WakeUp';
      bad.payloadJson = '{"x":1}';

      Test.startTest();
      List<WorkflowSignalOrStartInvocableAction.SignalOrStartResult> results = WorkflowSignalOrStartInvocableAction.signalOrStartWorkflow(
        new List<WorkflowSignalOrStartInvocableAction.SignalOrStartRequest>{
          bad
        }
      );
      Test.stopTest();

      System.assertEquals(1, results.size());
      System.assertEquals(false, results[0].isValid);
      System.assertNotEquals(null, results[0].validationError);
      System.assert(results[0].validationError.contains('accountId'));
      System.assertEquals(null, results[0].workflowInstanceId);
      System.assertEquals(0, instanceCountForKey('VIV_sos_new'));
    }
  }

  // ── FIX 5: a debounced invalid input fails observably/safely at sweep ─────────

  @IsTest
  static void testDebouncedInvalidInputFailsObservablyAtSweepNoSiblingAbort() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.mockNow = Datetime.now();

      Test.startTest();
      // Arm an INVALID debounced ValidatedWorkflow row: it is accepted at arm time
      // (the contract is deferred to sweep, per the ratified arm-and-defer rule)...
      WorkflowStartService.startDebounced(
        new WorkflowDebouncer.DebounceRequest(
            CONTRACT_WF,
            'VIV_deb_sweep_bad',
            '{"amount":5}' // parseable, but missing required accountId
          )
          .withDebounce(10)
      );
      // ...alongside a VALID sibling row armed in the same window.
      WorkflowStartService.startDebounced(
        new WorkflowDebouncer.DebounceRequest(
            CONTRACT_WF,
            'VIV_deb_sweep_good',
            JSON.serialize(validInput())
          )
          .withDebounce(10)
      );

      System.assertEquals(
        1,
        debounceStateCountForKey('VIV_deb_sweep_bad'),
        'Invalid input is armed (not rejected) at debounce time'
      );

      // Advance past the debounce window and run the sweep (deferred materialization).
      WorkflowEngine.mockNow = WorkflowEngine.mockNow.addSeconds(11);
      WorkflowDebouncer.sweep();
      Test.stopTest();

      // (a) LOGGED + (b) TERMINAL-BOUNDED: the invalid row's debounce state
      // survives with an incremented retry count and a recorded error message that
      // enumerates the contract failure, backed off rather than looping forever.
      List<Debounce_State__c> badStates = [
        SELECT Retry_Count__c, Error_Message__c
        FROM Debounce_State__c
        WHERE Correlation_Key__c = 'VIV_deb_sweep_bad'
      ];
      System.assertEquals(
        1,
        badStates.size(),
        'Invalid debounce row is retained (not silently dropped)'
      );
      System.assertEquals(
        1,
        badStates[0].Retry_Count__c,
        'The sweep failure is recorded as a bounded retry'
      );
      System.assertNotEquals(
        null,
        badStates[0].Error_Message__c,
        'The contract failure is recorded on the debounce state (not silent)'
      );
      System.assert(
        badStates[0].Error_Message__c.contains('accountId'),
        'Recorded error enumerates the contract violation: ' +
        badStates[0].Error_Message__c
      );
      System.assertEquals(
        0,
        instanceCountForKey('VIV_deb_sweep_bad'),
        'No workflow instance is created for the invalid row'
      );

      // (c) SIBLING ISOLATION: the valid sibling materialized and its debounce
      // state was consumed — the invalid row did not abort it.
      System.assertEquals(
        1,
        instanceCountForKey('VIV_deb_sweep_good'),
        'The valid sibling materialized (not aborted by the invalid row)'
      );
      System.assertEquals(
        0,
        debounceStateCountForKey('VIV_deb_sweep_good'),
        'The fired sibling debounce state was deleted'
      );
    }
  }

  // ── FIX 6: an invalid-fallback row dedups to an intra-batch valid sibling ─────

  @IsTest
  static void testInvocableTwoRowsSameKeyInvalidDedupsToValidSibling() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // ONE invocation, TWO rows sharing a correlation key: a VALID row, then a
      // row with INVALID fallback input. The invalid row must dedup-resolve to the
      // instance the valid sibling creates in the same call — not be rejected.
      WorkflowStartInvocableAction.StartRequest validRow = new WorkflowStartInvocableAction.StartRequest();
      validRow.workflowName = CONTRACT_WF;
      validRow.correlationKey = 'VIV_sibling_start';
      validRow.inputJson = JSON.serialize(validInput());

      WorkflowStartInvocableAction.StartRequest invalidRow = new WorkflowStartInvocableAction.StartRequest();
      invalidRow.workflowName = CONTRACT_WF;
      invalidRow.correlationKey = 'VIV_sibling_start';
      invalidRow.inputJson = '{"amount":5}'; // missing accountId

      Test.startTest();
      List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
        new List<WorkflowStartInvocableAction.StartRequest>{
          validRow,
          invalidRow
        }
      );
      Test.stopTest();

      System.assertEquals(2, results.size());
      System.assertEquals(true, results[0].isValid, 'Valid row started');
      System.assertNotEquals(null, results[0].workflowInstanceId);
      System.assertEquals(
        true,
        results[1].isValid,
        'Invalid row dedups to the in-batch valid sibling (not rejected)'
      );
      System.assertEquals(
        results[0].workflowInstanceId,
        results[1].workflowInstanceId,
        'Both rows resolve to the same instance'
      );
      System.assertEquals(
        1,
        instanceCountForKey('VIV_sibling_start'),
        'Exactly one instance total'
      );
    }
  }

  @IsTest
  static void testInvocableTwoRowsSameKeyInvalidSignalDelivered() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      WorkflowSignalOrStartInvocableAction.SignalOrStartRequest validRow = new WorkflowSignalOrStartInvocableAction.SignalOrStartRequest();
      validRow.workflowName = CONTRACT_WF;
      validRow.correlationKey = 'VIV_sibling_sos';
      validRow.inputJson = JSON.serialize(validInput());
      validRow.signalName = 'Approve:FromValid';
      validRow.payloadJson = '{"v":1}';

      WorkflowSignalOrStartInvocableAction.SignalOrStartRequest invalidRow = new WorkflowSignalOrStartInvocableAction.SignalOrStartRequest();
      invalidRow.workflowName = CONTRACT_WF;
      invalidRow.correlationKey = 'VIV_sibling_sos';
      invalidRow.inputJson = '{"amount":5}'; // missing accountId
      invalidRow.signalName = 'Approve:FromInvalid';
      invalidRow.payloadJson = '{"v":2}';

      Test.startTest();
      List<WorkflowSignalOrStartInvocableAction.SignalOrStartResult> results = WorkflowSignalOrStartInvocableAction.signalOrStartWorkflow(
        new List<WorkflowSignalOrStartInvocableAction.SignalOrStartRequest>{
          validRow,
          invalidRow
        }
      );
      Test.stopTest();

      System.assertEquals(2, results.size());
      System.assertEquals(true, results[0].isValid);
      System.assertEquals(
        true,
        results[1].isValid,
        'Invalid row dedups to the in-batch valid sibling (signal not dropped)'
      );
      Id instanceId = results[0].workflowInstanceId;
      System.assertNotEquals(null, instanceId);
      System.assertEquals(instanceId, results[1].workflowInstanceId);
      System.assertEquals(1, instanceCountForKey('VIV_sibling_sos'));

      // The later invalid row's signal WAS delivered to the sibling-created
      // instance (data loss avoided).
      List<Workflow_Signal__c> invalidSignals = [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Signal_Name__c = 'Approve:FromInvalid'
      ];
      System.assertEquals(
        1,
        invalidSignals.size(),
        'The invalid row signal landed on the sibling instance (not dropped)'
      );
    }
  }
}
