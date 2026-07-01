@isTest
public class WorkflowStatusInvocableActionTest {
  private static WorkflowStatusInvocableAction.StatusRequest req(
    String keyOrId
  ) {
    WorkflowStatusInvocableAction.StatusRequest r = new WorkflowStatusInvocableAction.StatusRequest();
    r.workflowKeyOrId = keyOrId;
    return r;
  }

  private static List<WorkflowStatusInvocableAction.StatusResult> call(
    String keyOrId
  ) {
    return WorkflowStatusInvocableAction.getStatus(
      new List<WorkflowStatusInvocableAction.StatusRequest>{ req(keyOrId) }
    );
  }

  @isTest
  static void testCompletedByInstanceId() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'DoneKey',
      Output__c = '"all-good"'
    );
    insert inst;

    Test.startTest();
    List<WorkflowStatusInvocableAction.StatusResult> results = call(inst.Id);
    Test.stopTest();

    System.assertEquals(1, results.size());
    WorkflowStatusInvocableAction.StatusResult res = results[0];
    System.assertEquals(true, res.found, 'Instance should be found by Id');
    System.assertEquals(inst.Id, res.workflowInstanceId);
    System.assertEquals('Completed', res.status);
    System.assertEquals(true, res.isTerminal, 'Completed is terminal');
    System.assertEquals(true, res.isSuccess, 'Completed is success');
    System.assertEquals('"all-good"', res.outputJson);
    System.assertEquals(null, res.errorMessage);
  }

  @isTest
  static void testRunningByCorrelationKey() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Running',
      Correlation_Key__c = 'LiveKey'
    );
    insert inst;

    Test.startTest();
    List<WorkflowStatusInvocableAction.StatusResult> results = call('LiveKey');
    Test.stopTest();

    WorkflowStatusInvocableAction.StatusResult res = results[0];
    System.assertEquals(true, res.found);
    System.assertEquals(inst.Id, res.workflowInstanceId);
    System.assertEquals('Running', res.status);
    System.assertEquals(false, res.isTerminal, 'Running is not terminal');
    System.assertEquals(false, res.isSuccess, 'Running is not success');
  }

  @isTest
  static void testFailedExposesErrorDetail() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Failed',
      Correlation_Key__c = 'FailKey',
      Error_Message__c = 'Step blew up: boom'
    );
    insert inst;

    Test.startTest();
    List<WorkflowStatusInvocableAction.StatusResult> results = call('FailKey');
    Test.stopTest();

    WorkflowStatusInvocableAction.StatusResult res = results[0];
    System.assertEquals(true, res.found);
    System.assertEquals('Failed', res.status);
    System.assertEquals(true, res.isTerminal, 'Failed is terminal');
    System.assertEquals(false, res.isSuccess, 'Failed is not success');
    System.assertEquals('Step blew up: boom', res.errorMessage);
  }

  @isTest
  static void testCompensatedAndCancelledAreTerminalNotSuccess() {
    Workflow_Instance__c comp = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Compensated',
      Correlation_Key__c = 'CompKey'
    );
    Workflow_Instance__c canc = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Cancelled',
      Correlation_Key__c = 'CancKey'
    );
    insert new List<Workflow_Instance__c>{ comp, canc };

    Test.startTest();
    WorkflowStatusInvocableAction.StatusResult compRes = call('CompKey')[0];
    WorkflowStatusInvocableAction.StatusResult cancRes = call('CancKey')[0];
    Test.stopTest();

    System.assertEquals(true, compRes.isTerminal, 'Compensated is terminal');
    System.assertEquals(false, compRes.isSuccess, 'Compensated is not success');
    System.assertEquals(true, cancRes.isTerminal, 'Cancelled is terminal');
    System.assertEquals(false, cancRes.isSuccess, 'Cancelled is not success');
  }

  @isTest
  static void testOffloadedOutputIsRehydrated() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'BigKey'
    );
    insert inst;

    // Offload a >100k payload exactly as the engine does, so Output__c holds a pointer.
    String bigPayload = '"' + 'X'.repeat(110000) + '"';
    inst.Output__c = WorkflowEngine.savePayloadIfNeeded(
      inst.Id,
      bigPayload,
      'Output_Big'
    );
    update inst;
    System.assert(
      inst.Output__c.startsWith('{"$attachmentId":'),
      'Setup precondition: Output__c should hold an offload pointer, was: ' +
      inst.Output__c
    );

    Test.startTest();
    List<WorkflowStatusInvocableAction.StatusResult> results = call(inst.Id);
    Test.stopTest();

    WorkflowStatusInvocableAction.StatusResult res = results[0];
    System.assertEquals(true, res.found);
    System.assertEquals(
      bigPayload,
      res.outputJson,
      'Output should be the rehydrated full payload, not the pointer'
    );
    System.assert(
      !res.outputJson.startsWith('{"$attachmentId":'),
      'Output must never be the raw stored pointer'
    );
    // Parity with what an Apex caller sees via the engine.
    System.assertEquals(
      WorkflowEngine.resolvePayload(inst.Output__c),
      res.outputJson,
      'Action output must match the engine rehydration path'
    );
  }

  @isTest
  static void testContinuedAsNewChainResolvesSuccessorDistinctKey() {
    // Predecessor terminal-as-ContinuedAsNew; successor carries the default _run2 key.
    Workflow_Instance__c pred = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'ContinuedAsNew',
      Correlation_Key__c = 'ChainA'
    );
    insert pred;
    Workflow_Instance__c succ = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'ChainA_run2',
      Previous_Instance__c = pred.Id,
      Output__c = '"successor-output"'
    );
    insert succ;

    Test.startTest();
    // Look up by the ORIGINAL key, which only matches the stale predecessor directly.
    List<WorkflowStatusInvocableAction.StatusResult> results = call('ChainA');
    Test.stopTest();

    WorkflowStatusInvocableAction.StatusResult res = results[0];
    System.assertEquals(true, res.found);
    System.assertEquals(
      succ.Id,
      res.workflowInstanceId,
      'Should resolve forward to the live successor, not the predecessor'
    );
    System.assertEquals('Completed', res.status);
    System.assertEquals(true, res.isSuccess);
    System.assertEquals('"successor-output"', res.outputJson);
  }

  @isTest
  static void testContinuedAsNewChainMultiLevelSameKey() {
    // Three-generation chain where the successor reuses the same correlation key.
    Workflow_Instance__c gen1 = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'ContinuedAsNew',
      Correlation_Key__c = 'ChainB'
    );
    insert gen1;
    Workflow_Instance__c gen2 = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'ContinuedAsNew',
      Correlation_Key__c = 'ChainB',
      Previous_Instance__c = gen1.Id
    );
    insert gen2;
    Workflow_Instance__c gen3 = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Running',
      Correlation_Key__c = 'ChainB',
      Previous_Instance__c = gen2.Id
    );
    insert gen3;

    Test.startTest();
    List<WorkflowStatusInvocableAction.StatusResult> results = call('ChainB');
    Test.stopTest();

    WorkflowStatusInvocableAction.StatusResult res = results[0];
    System.assertEquals(true, res.found);
    System.assertEquals(
      gen3.Id,
      res.workflowInstanceId,
      'Should walk the full chain to the live generation'
    );
    System.assertEquals('Running', res.status);
    System.assertEquals(false, res.isTerminal);
  }

  @isTest
  static void testExplicitPredecessorIdIsNotWalked() {
    // An explicit Id is a precise handle: report that exact instance, no chain walk.
    Workflow_Instance__c pred = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'ContinuedAsNew',
      Correlation_Key__c = 'ChainC'
    );
    insert pred;
    Workflow_Instance__c succ = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'ChainC_run2',
      Previous_Instance__c = pred.Id
    );
    insert succ;

    Test.startTest();
    List<WorkflowStatusInvocableAction.StatusResult> results = call(pred.Id);
    Test.stopTest();

    WorkflowStatusInvocableAction.StatusResult res = results[0];
    System.assertEquals(true, res.found);
    System.assertEquals(pred.Id, res.workflowInstanceId);
    System.assertEquals('ContinuedAsNew', res.status);
    System.assertEquals(
      false,
      res.isTerminal,
      'ContinuedAsNew is not terminal'
    );
    System.assertEquals(false, res.isSuccess);
  }

  @isTest
  static void testReusedKeyPrefersActiveRunOverTerminalHistory() {
    // Correlation_Key__c is not unique: an old terminal run and a current active
    // run can share a key. getStatus must report the live run, not stale history.
    Workflow_Instance__c oldRun = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'ReuseKey',
      Output__c = '"stale-output"'
    );
    insert oldRun;
    Workflow_Instance__c currentRun = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Running',
      Correlation_Key__c = 'ReuseKey'
    );
    insert currentRun;

    Test.startTest();
    List<WorkflowStatusInvocableAction.StatusResult> results = call('ReuseKey');
    Test.stopTest();

    WorkflowStatusInvocableAction.StatusResult res = results[0];
    System.assertEquals(true, res.found);
    System.assertEquals(
      currentRun.Id,
      res.workflowInstanceId,
      'Should report the live (active) run, not the stale terminal one'
    );
    System.assertEquals('Running', res.status);
    System.assertEquals(false, res.isTerminal);
  }

  @isTest
  static void testUnknownKeyYieldsNotFound() {
    Test.startTest();
    List<WorkflowStatusInvocableAction.StatusResult> results = call(
      'no-such-key'
    );
    Test.stopTest();

    WorkflowStatusInvocableAction.StatusResult res = results[0];
    System.assertEquals(false, res.found, 'Unknown key is a clean not-found');
    System.assertEquals(null, res.status);
    System.assertEquals(false, res.isTerminal);
    System.assertEquals(false, res.isSuccess);
    System.assertEquals(null, res.workflowInstanceId);
  }

  @isTest
  static void testGarbageIdYieldsNotFoundNoException() {
    // A syntactically id-shaped but non-existent value must not fault the Flow.
    Test.startTest();
    List<WorkflowStatusInvocableAction.StatusResult> results = call(
      'a00000000000000AAA'
    );
    Test.stopTest();

    System.assertEquals(false, results[0].found);
  }

  @isTest
  static void testBlankInputYieldsNotFound() {
    Test.startTest();
    List<WorkflowStatusInvocableAction.StatusResult> results = call('');
    Test.stopTest();

    System.assertEquals(false, results[0].found);
  }

  @isTest
  static void testNullAndEmptyRequestLists() {
    Test.startTest();
    List<WorkflowStatusInvocableAction.StatusResult> nullRes = WorkflowStatusInvocableAction.getStatus(
      null
    );
    List<WorkflowStatusInvocableAction.StatusResult> emptyRes = WorkflowStatusInvocableAction.getStatus(
      new List<WorkflowStatusInvocableAction.StatusRequest>()
    );
    Test.stopTest();

    System.assertEquals(0, nullRes.size());
    System.assertEquals(0, emptyRes.size());
  }

  @isTest
  static void testReadOnlyNoDml() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'ReadOnlyKey',
      Output__c = '"x"'
    );
    insert inst;

    Test.startTest();
    Integer dmlBefore = Limits.getDmlStatements();
    Integer dmlRowsBefore = Limits.getDmlRows();
    call('ReadOnlyKey');
    System.assertEquals(
      dmlBefore,
      Limits.getDmlStatements(),
      'Action must perform no DML'
    );
    System.assertEquals(
      dmlRowsBefore,
      Limits.getDmlRows(),
      'Action must write no rows'
    );
    Test.stopTest();

    // No signal / step / compensation side effects.
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :inst.Id
      ]
    );
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :inst.Id
      ]
    );
  }

  @isTest
  static void testBulkOrderingAndGovernorSafety() {
    List<Workflow_Instance__c> insts = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < 50; i++) {
      insts.add(
        new Workflow_Instance__c(
          Workflow_Name__c = 'Test.Workflow',
          Status__c = (Math.mod(i, 2) == 0) ? 'Completed' : 'Failed',
          Correlation_Key__c = 'BulkKey' + i,
          Output__c = '"out' + i + '"',
          Error_Message__c = (Math.mod(i, 2) == 0) ? null : ('err' + i)
        )
      );
    }
    insert insts;

    List<WorkflowStatusInvocableAction.StatusRequest> requests = new List<WorkflowStatusInvocableAction.StatusRequest>();
    for (Integer i = 0; i < 50; i++) {
      requests.add(req('BulkKey' + i));
    }

    Test.startTest();
    Integer soqlBefore = Limits.getQueries();
    List<WorkflowStatusInvocableAction.StatusResult> results = WorkflowStatusInvocableAction.getStatus(
      requests
    );
    Integer soqlUsed = Limits.getQueries() - soqlBefore;
    Test.stopTest();

    System.assertEquals(50, results.size(), 'One result per request');
    System.assert(
      soqlUsed <= 5,
      'Bulk call must not issue per-record SOQL; used ' + soqlUsed
    );
    for (Integer i = 0; i < 50; i++) {
      WorkflowStatusInvocableAction.StatusResult res = results[i];
      System.assertEquals(true, res.found, 'Row ' + i + ' found');
      System.assertEquals(
        '"out' + i + '"',
        res.outputJson,
        'Ordering row ' + i
      );
      if (Math.mod(i, 2) == 0) {
        System.assertEquals('Completed', res.status);
        System.assertEquals(true, res.isSuccess);
      } else {
        System.assertEquals('Failed', res.status);
        System.assertEquals('err' + i, res.errorMessage);
      }
    }
  }

  @isTest
  static void testBulkMixedFoundAndNotFound() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'MixedKey'
    );
    insert inst;

    List<WorkflowStatusInvocableAction.StatusRequest> requests = new List<WorkflowStatusInvocableAction.StatusRequest>{
      req('missing-1'),
      req('MixedKey'),
      req('missing-2')
    };

    Test.startTest();
    List<WorkflowStatusInvocableAction.StatusResult> results = WorkflowStatusInvocableAction.getStatus(
      requests
    );
    Test.stopTest();

    System.assertEquals(3, results.size());
    System.assertEquals(false, results[0].found);
    System.assertEquals(true, results[1].found);
    System.assertEquals(inst.Id, results[1].workflowInstanceId);
    System.assertEquals(false, results[2].found);
  }

  @isTest
  static void testExposesProgressAndRehydrates() {
    Workflow_Instance__c inst1 = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Running',
      Correlation_Key__c = 'ProgressKey1',
      Progress__c = '{"percentComplete":42.5,"message":"Working"}'
    );
    insert inst1;

    List<WorkflowStatusInvocableAction.StatusResult> results1 = call(
      'ProgressKey1'
    );

    System.assertEquals(1, results1.size());
    System.assertEquals(true, results1[0].found);
    System.assertEquals(
      '{"percentComplete":42.5,"message":"Working"}',
      results1[0].progressJson
    );

    // Test offloaded progress rehydration
    Workflow_Instance__c inst2 = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Running',
      Correlation_Key__c = 'ProgressKey2'
    );
    insert inst2;

    String bigProgress =
      '{"percent":95.0,"details":"' +
      'P'.repeat(110000) +
      '"}';
    inst2.Progress__c = WorkflowEngine.savePayloadIfNeeded(
      inst2.Id,
      bigProgress,
      'Progress_Big'
    );
    update inst2;

    List<WorkflowStatusInvocableAction.StatusResult> results2 = call(inst2.Id);

    System.assertEquals(1, results2.size());
    System.assertEquals(true, results2[0].found);
    System.assertEquals(
      bigProgress,
      results2[0].progressJson,
      'Offloaded progress should be rehydrated'
    );
  }

  @isTest
  static void testGetStatusActionExposesCausationId() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'Test.Workflow',
      Status__c = 'Completed',
      Correlation_Key__c = 'CausationActionKey',
      Causation_Id__c = 'my-cause-abc'
    );
    insert inst;

    Test.startTest();
    List<WorkflowStatusInvocableAction.StatusResult> results = call(
      'CausationActionKey'
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    System.assertEquals(true, results[0].found);
    System.assertEquals('my-cause-abc', results[0].causationId);
  }
}
