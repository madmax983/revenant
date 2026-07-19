/**
 * @description Governor-bound and per-row-mapping tests for the invocable suspect
 * (invalid-input) resolution path (issue #51). Proves the path is bounded — ONE
 * bulk key lookup plus at most ONE bulk signal delivery — rather than a per-row
 * scalar engine call (which the old code did: one dedup SOQL per Start row and one
 * savepoint per Signal-or-Start row, exhausting the 5-savepoint cap at 6 rows). The
 * `ContractWorkflow` fixture lives in the public {@link WorkflowInputValidationTest}.
 */
@IsTest
private class WorkflowInputValidationGovernorTest {
  private static final String CONTRACT_WF = 'WorkflowInputValidationTest.ContractWorkflow';

  private static Integer instanceCountForKey(String key) {
    return [
      SELECT COUNT()
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :key
    ];
  }

  private static Map<String, Object> validInput() {
    return new Map<String, Object>{
      'accountId' => 'ACME-ACCOUNT-1',
      'amount' => 2500
    };
  }

  @IsTest
  static void testStartManyInvalidNewRowsUseBoundedQueries() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // 100 parseable-but-contract-invalid Start rows (missing accountId), each a
      // distinct new key (no existing instance). The old per-row loop did one dedup
      // SOQL PER ROW -> 100 rows would hit the 100-query limit; the new path does
      // ONE bulk key lookup for all of them.
      List<WorkflowStartInvocableAction.StartRequest> rows = new List<WorkflowStartInvocableAction.StartRequest>();
      for (Integer k = 0; k < 100; k++) {
        WorkflowStartInvocableAction.StartRequest bad = new WorkflowStartInvocableAction.StartRequest();
        bad.workflowName = CONTRACT_WF;
        bad.correlationKey = 'VIV_gov_start_' + k;
        bad.inputJson = '{"amount":5}';
        rows.add(bad);
      }

      Test.startTest();
      Integer queriesBefore = Limits.getQueries();
      List<WorkflowStartInvocableAction.StartResult> results = WorkflowStartInvocableAction.startWorkflow(
        rows
      );
      Integer queriesDelta = Limits.getQueries() - queriesBefore;
      Test.stopTest();

      // Completes with no LimitException; every invalid-new row is rejected.
      System.assertEquals(100, results.size());
      for (Integer k = 0; k < 100; k++) {
        System.assertEquals(
          false,
          results[k].isValid,
          'Invalid-new Start row ' + k + ' must be rejected'
        );
      }
      // Query count is O(1) in the number of suspect rows (one bulk key lookup),
      // NOT O(rows). Old per-row path would have issued ~100 queries.
      System.assert(
        queriesDelta <= 6,
        'Suspect resolution must be a bounded number of queries, was ' +
        queriesDelta
      );
    }
  }

  @IsTest
  static void testSignalOrStartManyInvalidNewRowsNoSavepointFault() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // One valid sibling plus 10 (> the 5-savepoint cap) parseable-but-contract-
      // invalid signal rows with NO existing instance. The old per-row loop called
      // a scalar signalOrStart (a savepoint each) per invalid row and would fault
      // with a LimitException at the 6th; the new path resolves invalid-new rows in
      // memory (no engine call), so the whole invocation completes.
      List<WorkflowSignalOrStartInvocableAction.SignalOrStartRequest> rows = new List<WorkflowSignalOrStartInvocableAction.SignalOrStartRequest>();
      WorkflowSignalOrStartInvocableAction.SignalOrStartRequest good = new WorkflowSignalOrStartInvocableAction.SignalOrStartRequest();
      good.workflowName = CONTRACT_WF;
      good.correlationKey = 'VIV_gov_sig_good';
      good.inputJson = JSON.serialize(validInput());
      good.signalName = 'Approve:GovGood';
      good.payloadJson = '{"g":1}';
      rows.add(good);
      for (Integer k = 0; k < 10; k++) {
        WorkflowSignalOrStartInvocableAction.SignalOrStartRequest bad = new WorkflowSignalOrStartInvocableAction.SignalOrStartRequest();
        bad.workflowName = CONTRACT_WF;
        bad.correlationKey = 'VIV_gov_sig_bad_' + k;
        bad.inputJson = '{"amount":5}';
        bad.signalName = 'Approve:GovBad';
        bad.payloadJson = '{"b":1}';
        rows.add(bad);
      }

      Test.startTest();
      Integer queriesBefore = Limits.getQueries();
      List<WorkflowSignalOrStartInvocableAction.SignalOrStartResult> results = WorkflowSignalOrStartInvocableAction.signalOrStartWorkflow(
        rows
      );
      Integer queriesDelta = Limits.getQueries() - queriesBefore;
      Test.stopTest();

      // Completes with no LimitException (the old per-row savepoints faulted at 6).
      System.assertEquals(11, results.size());
      System.assertEquals(
        true,
        results[0].isValid,
        'Valid sibling signal delivered'
      );
      System.assertNotEquals(null, results[0].workflowInstanceId);
      System.assertEquals(1, instanceCountForKey('VIV_gov_sig_good'));
      for (Integer k = 1; k <= 10; k++) {
        System.assertEquals(
          false,
          results[k].isValid,
          'Invalid-new signal row ' + k + ' must be rejected'
        );
      }
      // The 10 invalid-new rows added at most ONE shared bulk key lookup, not a
      // per-row engine call — bounded regardless of count.
      System.assert(
        queriesDelta <= 15,
        'Suspect resolution must be bounded, was ' + queriesDelta
      );
    }
  }

  @IsTest
  static void testSignalOrStartBulkDeliverPerRowMapping() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // Two pre-existing suspended instances with DIFFERENT keys.
      Workflow_Instance__c instA = new Workflow_Instance__c(
        Workflow_Name__c = CONTRACT_WF,
        Status__c = 'Suspended',
        Correlation_Key__c = 'VIV_mapA'
      );
      Workflow_Instance__c instB = new Workflow_Instance__c(
        Workflow_Name__c = CONTRACT_WF,
        Status__c = 'Suspended',
        Correlation_Key__c = 'VIV_mapB'
      );
      insert new List<Workflow_Instance__c>{ instA, instB };

      // Two invalid-fallback signal rows, different keys, different signals — both
      // dedup hits routed through the ONE bulk delivery.
      WorkflowSignalOrStartInvocableAction.SignalOrStartRequest rowA = new WorkflowSignalOrStartInvocableAction.SignalOrStartRequest();
      rowA.workflowName = CONTRACT_WF;
      rowA.correlationKey = 'VIV_mapA';
      rowA.inputJson = '{"amount":5}';
      rowA.signalName = 'Approve:ToA';
      rowA.payloadJson = '{"a":1}';
      WorkflowSignalOrStartInvocableAction.SignalOrStartRequest rowB = new WorkflowSignalOrStartInvocableAction.SignalOrStartRequest();
      rowB.workflowName = CONTRACT_WF;
      rowB.correlationKey = 'VIV_mapB';
      rowB.inputJson = '{"amount":5}';
      rowB.signalName = 'Approve:ToB';
      rowB.payloadJson = '{"b":1}';

      Test.startTest();
      List<WorkflowSignalOrStartInvocableAction.SignalOrStartResult> results = WorkflowSignalOrStartInvocableAction.signalOrStartWorkflow(
        new List<WorkflowSignalOrStartInvocableAction.SignalOrStartRequest>{
          rowA,
          rowB
        }
      );
      Test.stopTest();

      // Each output row maps to the RIGHT instance.
      System.assertEquals(2, results.size());
      System.assertEquals(true, results[0].isValid);
      System.assertEquals(instA.Id, results[0].workflowInstanceId);
      System.assertEquals(true, results[1].isValid);
      System.assertEquals(instB.Id, results[1].workflowInstanceId);

      // Each signal landed on the RIGHT instance (and not the wrong one).
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE
            Workflow_Instance__c = :instA.Id
            AND Signal_Name__c = 'Approve:ToA'
        ],
        'A signal landed on instance A'
      );
      System.assertEquals(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE
            Workflow_Instance__c = :instB.Id
            AND Signal_Name__c = 'Approve:ToB'
        ],
        'B signal landed on instance B'
      );
      System.assertEquals(
        0,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE
            Workflow_Instance__c = :instB.Id
            AND Signal_Name__c = 'Approve:ToA'
        ],
        'A signal must not land on instance B'
      );
    }
  }
}
