/**
 * @description Tests for the Cancel Workflow invocable action (issue #107).
 */
@IsTest
private class WorkflowCancelInvocableActionTest {
  private static final String WORKFLOW = 'WorkflowEngineTest.HappyWorkflow';
  private static final String COMP_STEP = 'WorkflowEngineTest.CompensatableHappyStep';
  private static final String PLAIN_STEP = 'WorkflowEngineTest.NonCompensatableStep';

  private static WorkflowCancelInvocableAction.CancelRequest req(
    String keyOrId,
    Boolean runCompensations,
    String idempotencyKey
  ) {
    WorkflowCancelInvocableAction.CancelRequest r = new WorkflowCancelInvocableAction.CancelRequest();
    r.workflowKeyOrId = keyOrId;
    r.runCompensations = runCompensations;
    r.idempotencyKey = idempotencyKey;
    return r;
  }

  private static WorkflowCancelInvocableAction.CancelResult callOne(
    String keyOrId,
    Boolean runCompensations,
    String idempotencyKey
  ) {
    return WorkflowCancelInvocableAction.cancelWorkflow(
      new List<WorkflowCancelInvocableAction.CancelRequest>{
        req(keyOrId, runCompensations, idempotencyKey)
      }
    )[0];
  }

  private static Workflow_Instance__c buildInstance(String key, String status) {
    return new Workflow_Instance__c(
      Workflow_Name__c = WORKFLOW,
      Status__c = status,
      Correlation_Key__c = key
    );
  }

  // A suspended saga: two forward steps on the stack, the top one compensatable.
  private static Workflow_Instance__c buildSaga(String key) {
    Workflow_Instance__c inst = buildInstance(key, 'Suspended');
    inst.Compensation_Stack__c = JSON.serialize(
      new List<String>{ PLAIN_STEP, COMP_STEP }
    );
    return inst;
  }

  private static Workflow_Instance__c insertSaga(String key) {
    Workflow_Instance__c inst = buildSaga(key);
    insert inst;
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = COMP_STEP,
      Status__c = 'Completed',
      Input__c = '{"stepInput": 1}',
      Output__c = '{"stepOutput": 2}'
    );
    return inst;
  }

  private static String statusOf(Id instanceId) {
    return [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
    .Status__c;
  }

  private static List<Workflow_Step_Execution__c> compensationRows(
    Id instanceId
  ) {
    return [
      SELECT Step_Name__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c LIKE '%_Compensate'
      ORDER BY CreatedDate ASC, Id ASC
    ];
  }

  // Runs the orchestrator until the rollback drains (bounded).
  private static void drainRollback(Id instanceId) {
    for (Integer i = 0; i < 5 && statusOf(instanceId) == 'Cancelling'; i++) {
      WorkflowEngine.runStep(instanceId, null);
    }
  }

  @IsTest
  static void testCancelByIdWithoutCompensations() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = insertSaga('NoCompKey');

      Test.startTest();
      WorkflowCancelInvocableAction.CancelResult res = callOne(
        inst.Id,
        false,
        null
      );
      Test.stopTest();

      Assert.isTrue(res.found, 'Id must resolve');
      Assert.areEqual(
        inst.Id,
        res.workflowInstanceId,
        'res.workflowInstanceId must be inst.Id'
      );
      Assert.isTrue(res.cancelled, 'Live instance must cancel');
      Assert.isFalse(res.isCompensating, 'No rollback requested');
      Assert.areEqual('Cancelled', res.status, 'res.status must be Cancelled');
      Assert.areEqual(
        'Cancelled',
        statusOf(inst.Id),
        'statusOf(inst.Id) must be Cancelled'
      );
      Assert.areEqual(0, compensationRows(inst.Id).size(), 'No rollback rows');
    }
  }

  @IsTest
  static void testCancelByKeyWithCompensationsRollsBackLifo() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = insertSaga('CompKey');

      Test.startTest();
      WorkflowCancelInvocableAction.CancelResult res = callOne(
        'CompKey',
        true,
        null
      );
      Assert.isTrue(res.cancelled, 'res.cancelled must be true');
      Assert.isTrue(res.isCompensating, 'Rollback must start');
      Assert.areEqual(
        'Cancelling',
        res.status,
        'res.status must be Cancelling'
      );
      drainRollback(inst.Id);
      Test.stopTest();

      // Engine contract (ADR 0004): a cancel rollback ends Cancelled.
      Assert.areEqual(
        'Cancelled',
        statusOf(inst.Id),
        'statusOf(inst.Id) must be Cancelled'
      );
      List<Workflow_Step_Execution__c> rows = compensationRows(inst.Id);
      Assert.areEqual(2, rows.size(), 'Each stack entry rolls back once');
      Assert.areEqual(COMP_STEP + '_Compensate', rows[0].Step_Name__c, 'LIFO');
      Assert.areEqual(PLAIN_STEP + '_Compensate', rows[1].Step_Name__c, 'LIFO');
      Assert.areEqual(
        'Compensated',
        rows[0].Status__c,
        'rows[0].Status__c must be Compensated'
      );
      Assert.areEqual(
        'Compensated',
        rows[1].Status__c,
        'rows[1].Status__c must be Compensated'
      );
    }
  }

  @IsTest
  static void testEmptyRunCompensationsDefaultsToRollback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = insertSaga('DefaultKey');

      Test.startTest();
      WorkflowCancelInvocableAction.CancelResult res = callOne(
        'DefaultKey',
        null,
        null
      );
      Test.stopTest();

      Assert.isTrue(res.isCompensating, 'Empty flag means rollback');
      Assert.areEqual(
        'Cancelling',
        statusOf(inst.Id),
        'statusOf(inst.Id) must be Cancelling'
      );
    }
  }

  @IsTest
  static void testParentCancelReapsChildren() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = buildInstance('ParentKey', 'Suspended');
      insert parent;
      Workflow_Instance__c child = buildInstance('ChildKey', 'Pending');
      child.Parent_Instance__c = parent.Id;
      Workflow_Instance__c doneChild = buildInstance(
        'DoneChildKey',
        'Completed'
      );
      doneChild.Parent_Instance__c = parent.Id;
      insert new List<Workflow_Instance__c>{ child, doneChild };
      Workflow_Instance__c grandchild = buildInstance('GrandKey', 'Running');
      grandchild.Parent_Instance__c = child.Id;
      insert grandchild;

      Test.startTest();
      WorkflowCancelInvocableAction.CancelResult res = callOne(
        'ParentKey',
        false,
        null
      );
      Test.stopTest();

      Assert.isTrue(res.cancelled, 'res.cancelled must be true');
      Assert.areEqual(
        'Cancelled',
        statusOf(parent.Id),
        'statusOf(parent.Id) must be Cancelled'
      );
      Assert.areEqual('Cancelled', statusOf(child.Id), 'Child must cancel');
      Assert.areEqual('Cancelled', statusOf(grandchild.Id), 'Grandchild too');
      Assert.areEqual(
        'Completed',
        statusOf(doneChild.Id),
        'Terminal child stays'
      );
    }
  }

  @IsTest
  static void testTerminalInstancesAreNoOp() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<String> statuses = new List<String>{
        'Completed',
        'Failed',
        'Compensated',
        'Cancelled'
      };
      List<Workflow_Instance__c> rows = new List<Workflow_Instance__c>();
      List<WorkflowCancelInvocableAction.CancelRequest> reqs = new List<WorkflowCancelInvocableAction.CancelRequest>();
      for (String status : statuses) {
        rows.add(buildInstance('Terminal' + status, status));
        reqs.add(req('Terminal' + status, true, 'key-' + status));
      }
      insert rows;

      Test.startTest();
      List<WorkflowCancelInvocableAction.CancelResult> results = WorkflowCancelInvocableAction.cancelWorkflow(
        reqs
      );
      Test.stopTest();

      Assert.areEqual(
        statuses.size(),
        results.size(),
        'results.size() must be statuses.size()'
      );
      for (Integer i = 0; i < statuses.size(); i++) {
        Assert.isTrue(results[i].found, statuses[i] + ' must resolve');
        Assert.isFalse(results[i].cancelled, statuses[i] + ' is a no-op');
        Assert.isFalse(
          results[i].isCompensating,
          'results[i].isCompensating must be false'
        );
        Assert.areEqual(
          statuses[i],
          results[i].status,
          'results[i].status must be statuses[i]'
        );
        Assert.areEqual(
          statuses[i],
          statusOf(rows[i].Id),
          'statusOf(rows[i].Id) must be statuses[i]'
        );
      }
      Assert.areEqual(
        0,
        [SELECT COUNT() FROM Workflow_Signal__c],
        'No claim for a terminal instance'
      );
    }
  }

  @IsTest
  static void testUnknownBlankAndNullRowsReturnNotFound() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<WorkflowCancelInvocableAction.CancelRequest> reqs = new List<WorkflowCancelInvocableAction.CancelRequest>{
        req('NoSuchKey', true, null),
        req('', true, null),
        req(null, false, 'k'),
        null
      };

      Test.startTest();
      List<WorkflowCancelInvocableAction.CancelResult> results = WorkflowCancelInvocableAction.cancelWorkflow(
        reqs
      );
      Test.stopTest();

      Assert.areEqual(4, results.size(), 'One result per row');
      for (WorkflowCancelInvocableAction.CancelResult res : results) {
        Assert.isFalse(res.found, 'res.found must be false');
        Assert.isFalse(res.cancelled, 'res.cancelled must be false');
        Assert.isFalse(res.isCompensating, 'res.isCompensating must be false');
        Assert.isNull(
          res.workflowInstanceId,
          'res.workflowInstanceId must be null'
        );
        Assert.isNull(res.status, 'res.status must be null');
      }
    }
  }

  @IsTest
  static void testNullOrEmptyInputReturnsEmptyList() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areEqual(
        0,
        WorkflowCancelInvocableAction.cancelWorkflow(null).size(),
        'Null input gives no results'
      );
      Assert.areEqual(
        0,
        WorkflowCancelInvocableAction.cancelWorkflow(
            new List<WorkflowCancelInvocableAction.CancelRequest>()
          )
          .size(),
        'Empty input gives no results'
      );
    }
  }

  @IsTest
  static void testCorrelationKeyFollowsContinuedAsNewChain() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c pred = buildInstance('ChainKey', 'ContinuedAsNew');
      insert pred;
      Workflow_Instance__c succ = buildInstance('ChainKey_run2', 'Suspended');
      succ.Previous_Instance__c = pred.Id;
      insert succ;

      Test.startTest();
      WorkflowCancelInvocableAction.CancelResult res = callOne(
        'ChainKey',
        false,
        null
      );
      Test.stopTest();

      Assert.areEqual(succ.Id, res.workflowInstanceId, 'Live successor wins');
      Assert.isTrue(res.cancelled, 'res.cancelled must be true');
      Assert.areEqual(
        'Cancelled',
        statusOf(succ.Id),
        'statusOf(succ.Id) must be Cancelled'
      );
      Assert.areEqual(
        'ContinuedAsNew',
        statusOf(pred.Id),
        'statusOf(pred.Id) must be ContinuedAsNew'
      );
    }
  }

  @IsTest
  static void testPredecessorIdIsNoOp() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c pred = buildInstance('ChainIdKey', 'ContinuedAsNew');
      insert pred;
      Workflow_Instance__c succ = buildInstance('ChainIdKey_run2', 'Suspended');
      succ.Previous_Instance__c = pred.Id;
      insert succ;

      Test.startTest();
      WorkflowCancelInvocableAction.CancelResult res = callOne(
        pred.Id,
        false,
        null
      );
      Test.stopTest();

      // An Id is a precise handle, same as Get Workflow Status.
      Assert.areEqual(
        pred.Id,
        res.workflowInstanceId,
        'res.workflowInstanceId must be pred.Id'
      );
      Assert.isFalse(res.cancelled, 'res.cancelled must be false');
      Assert.areEqual(
        'Suspended',
        statusOf(succ.Id),
        'statusOf(succ.Id) must be Suspended'
      );
    }
  }

  // Runs one batch of 2 * pairs rows (half with rollback, all keyed) and
  // returns the SOQL and DML the batch used.
  private static List<Integer> measureBatch(String prefix, Integer pairs) {
    List<Workflow_Instance__c> rows = new List<Workflow_Instance__c>();
    for (Integer i = 0; i < pairs * 2; i++) {
      rows.add(buildSaga(prefix + i));
    }
    insert rows;
    List<WorkflowCancelInvocableAction.CancelRequest> reqs = new List<WorkflowCancelInvocableAction.CancelRequest>();
    for (Integer i = 0; i < rows.size(); i++) {
      reqs.add(req(prefix + i, Math.mod(i, 2) == 0, 'bulk-' + prefix + i));
    }
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    List<WorkflowCancelInvocableAction.CancelResult> results = WorkflowCancelInvocableAction.cancelWorkflow(
      reqs
    );
    Integer queries = Limits.getQueries() - q0;
    Integer dml = Limits.getDmlStatements() - d0;
    for (WorkflowCancelInvocableAction.CancelResult res : results) {
      Assert.isTrue(res.cancelled, 'Every live row must cancel');
    }
    return new List<Integer>{ queries, dml };
  }

  @IsTest
  static void testBulkCostDoesNotGrowWithRowCount() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Test.startTest();
      List<Integer> small = measureBatch('Small', 1);
      List<Integer> large = measureBatch('Large', 100);
      Test.stopTest();

      Assert.areEqual(small[0], large[0], 'SOQL must not grow with rows');
      Assert.areEqual(small[1], large[1], 'DML must not grow with rows');
      Assert.areEqual(
        101,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Status__c = 'Cancelling'
        ],
        'Each rollback row starts a rollback (1 small + 100 large)'
      );
    }
  }

  @IsTest
  static void testDuplicateIdempotencyKeyDoesNotRerunRollback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = insertSaga('DupKey');

      Test.startTest();
      WorkflowCancelInvocableAction.CancelResult first = callOne(
        'DupKey',
        true,
        'flow-retry-1'
      );
      // A redelivery with the same key. Without dedup, false would hard-stop the rollback.
      WorkflowCancelInvocableAction.CancelResult second = callOne(
        'DupKey',
        false,
        'flow-retry-1'
      );
      drainRollback(inst.Id);
      Test.stopTest();

      Assert.isTrue(first.cancelled, 'first.cancelled must be true');
      Assert.isFalse(second.cancelled, 'Duplicate key is a no-op');
      Assert.areEqual(
        'Cancelling',
        second.status,
        'second.status must be Cancelling'
      );
      Assert.isTrue(
        second.isCompensating,
        'second.isCompensating must be true'
      );
      Assert.areEqual(
        'Cancelled',
        statusOf(inst.Id),
        'statusOf(inst.Id) must be Cancelled'
      );
      Assert.areEqual(
        2,
        compensationRows(inst.Id).size(),
        'Rollback runs once'
      );
      Assert.areEqual(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :inst.Id AND Status__c = 'Consumed'
        ],
        'One claim tombstone'
      );
    }
  }

  @IsTest
  static void testKeyDedupsAgainstSignalCancel() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = insertSaga('SharedKey');
      WorkflowEngine.SignalRequest sig = new WorkflowEngine.SignalRequest(
        'SharedKey',
        'Cancel',
        '{"runCompensations": true}'
      );
      sig.idempotencyKey = 'shared-1';
      WorkflowEngine.signal(sig);
      Assert.areEqual(
        'Cancelling',
        statusOf(inst.Id),
        'statusOf(inst.Id) must be Cancelling'
      );

      Test.startTest();
      WorkflowCancelInvocableAction.CancelResult res = callOne(
        'SharedKey',
        false,
        'shared-1'
      );
      Test.stopTest();

      Assert.isFalse(res.cancelled, 'Signal and action share one key space');
      Assert.areEqual(
        'Cancelling',
        statusOf(inst.Id),
        'statusOf(inst.Id) must be Cancelling'
      );
    }
  }

  @IsTest
  static void testRepeatUnkeyedRollbackCancelIsNoOp() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = insertSaga('RepeatKey');

      Test.startTest();
      callOne('RepeatKey', true, null);
      WorkflowCancelInvocableAction.CancelResult second = callOne(
        'RepeatKey',
        true,
        null
      );
      Test.stopTest();

      Assert.isFalse(second.cancelled, 'Rollback already runs');
      Assert.isTrue(
        second.isCompensating,
        'second.isCompensating must be true'
      );
      Assert.areEqual(
        1,
        compensationRows(inst.Id).size(),
        'No second rollback'
      );
    }
  }

  @IsTest
  static void testRollbackCancelSkipsCompensatingInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = buildSaga('FailingKey');
      inst.Status__c = 'Compensating';
      insert inst;

      Test.startTest();
      WorkflowCancelInvocableAction.CancelResult res = callOne(
        'FailingKey',
        true,
        null
      );
      Test.stopTest();

      Assert.isFalse(res.cancelled, 'Rollback already runs');
      Assert.isTrue(res.isCompensating, 'res.isCompensating must be true');
      Assert.areEqual(
        'Compensating',
        statusOf(inst.Id),
        'statusOf(inst.Id) must be Compensating'
      );
    }
  }

  @IsTest
  static void testHardStopOfRunningRollback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = insertSaga('HardStopKey');

      Test.startTest();
      callOne('HardStopKey', true, null);
      WorkflowCancelInvocableAction.CancelResult res = callOne(
        'HardStopKey',
        false,
        null
      );
      Test.stopTest();

      Assert.isTrue(res.cancelled, 'Run Compensations off stops the rollback');
      Assert.isFalse(res.isCompensating, 'res.isCompensating must be false');
      Assert.areEqual(
        'Cancelled',
        statusOf(inst.Id),
        'statusOf(inst.Id) must be Cancelled'
      );
    }
  }

  @IsTest
  static void testInBatchDuplicateRowsFirstRowWins() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = insertSaga('TwinKey');

      Test.startTest();
      List<WorkflowCancelInvocableAction.CancelResult> results = WorkflowCancelInvocableAction.cancelWorkflow(
        new List<WorkflowCancelInvocableAction.CancelRequest>{
          req('TwinKey', false, null),
          req(inst.Id, true, null)
        }
      );
      Test.stopTest();

      Assert.isTrue(results[0].cancelled, 'First row wins');
      Assert.isFalse(results[1].cancelled, 'Second row is a duplicate');
      Assert.areEqual('Cancelled', results[1].status, 'Status is current');
      Assert.areEqual(0, compensationRows(inst.Id).size(), 'No rollback');
    }
  }

  @IsTest
  static void testEngineErrorRollsBackClaims() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = buildInstance('BadStackKey', 'Suspended');
      inst.Compensation_Stack__c = 'not-json';
      insert inst;

      Boolean threw = false;
      Test.startTest();
      try {
        callOne('BadStackKey', true, 'bad-1');
      } catch (Exception e) {
        threw = true;
      }
      Test.stopTest();

      Assert.isTrue(threw, 'A malformed stack must fault');
      Assert.areEqual(
        'Suspended',
        statusOf(inst.Id),
        'statusOf(inst.Id) must be Suspended'
      );
      Assert.areEqual(
        0,
        [SELECT COUNT() FROM Workflow_Signal__c],
        'Claim rolls back so a retry can run'
      );
    }
  }

  @IsTest
  static void testEngineCancelOverload() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c withRollback = insertSaga('OverloadComp');
      Workflow_Instance__c hardStop = insertSaga('OverloadHard');
      Workflow_Instance__c empty = insertSaga('OverloadNull');

      Test.startTest();
      WorkflowEngine.cancel(withRollback.Id, true);
      WorkflowEngine.cancel(hardStop.Id, false);
      WorkflowEngine.cancel(empty.Id, null);
      Test.stopTest();

      Assert.areEqual(
        'Cancelling',
        statusOf(empty.Id),
        'Null means rollback, same as the action'
      );

      Assert.areEqual(
        'Cancelling',
        statusOf(withRollback.Id),
        'statusOf(withRollback.Id) must be Cancelling'
      );
      Assert.areEqual(
        'Cancelled',
        statusOf(hardStop.Id),
        'statusOf(hardStop.Id) must be Cancelled'
      );
    }
  }

  // Writes a claim tombstone, as an earlier keyed signal or cancel does.
  private static void useKey(Id instanceId, String key) {
    insert WorkflowSignalBatchCancel.buildCancelClaim(
      instanceId,
      'Cancel',
      key
    );
  }

  @IsTest
  static void testLaterRowRunsWhenFirstRowKeyIsUsed() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = insertSaga('UsedKey');
      useKey(inst.Id, 'k-used');

      Test.startTest();
      List<WorkflowCancelInvocableAction.CancelResult> results = WorkflowCancelInvocableAction.cancelWorkflow(
        new List<WorkflowCancelInvocableAction.CancelRequest>{
          req('UsedKey', false, 'k-used'),
          req('UsedKey', false, 'k-new')
        }
      );
      Test.stopTest();

      Assert.isFalse(results[0].cancelled, 'A used key is a duplicate');
      Assert.isTrue(results[1].cancelled, 'The next row with a new key acts');
      Assert.areEqual(
        'Cancelled',
        statusOf(inst.Id),
        'The instance must not keep running'
      );
    }
  }

  @IsTest
  static void testDuplicateDescendantRowIsNotCancelled() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = buildInstance('DupParent', 'Suspended');
      insert parent;
      Workflow_Instance__c child = buildInstance('DupChild', 'Pending');
      child.Parent_Instance__c = parent.Id;
      insert child;
      useKey(child.Id, 'child-used');

      Test.startTest();
      List<WorkflowCancelInvocableAction.CancelResult> results = WorkflowCancelInvocableAction.cancelWorkflow(
        new List<WorkflowCancelInvocableAction.CancelRequest>{
          req('DupParent', false, 'parent-new'),
          req('DupChild', false, 'child-used')
        }
      );
      Test.stopTest();

      Assert.isTrue(results[0].cancelled, 'The parent row acts');
      Assert.isFalse(
        results[1].cancelled,
        'A duplicate row is false, also when the parent cancels its instance'
      );
      Assert.areEqual('Cancelled', results[1].status, 'The status is current');
    }
  }

  @IsTest
  static void testParentHardStopWinsOverChildRollbackRow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = buildInstance('MixParent', 'Suspended');
      insert parent;
      Workflow_Instance__c child = buildSaga('MixChild');
      child.Parent_Instance__c = parent.Id;
      insert child;

      Test.startTest();
      List<WorkflowCancelInvocableAction.CancelResult> results = WorkflowCancelInvocableAction.cancelWorkflow(
        new List<WorkflowCancelInvocableAction.CancelRequest>{
          req('MixChild', true, null),
          req('MixParent', false, null)
        }
      );
      Test.stopTest();

      Assert.isFalse(
        results[0].cancelled,
        'The child rollback did not run, so the row must be false'
      );
      Assert.isTrue(results[1].cancelled, 'The parent hard stop acts');
      Assert.areEqual(
        'Cancelled',
        statusOf(child.Id),
        'The parent hard stop reaches the child'
      );
      Assert.areEqual(
        0,
        compensationRows(child.Id).size(),
        'No rollback for the child'
      );
    }
  }

  @IsTest
  static void testRollbackRowOnRollingBackParentLeavesChildren() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = buildSaga('BusyParent');
      parent.Status__c = 'Cancelling';
      insert parent;
      Workflow_Instance__c child = buildSaga('StalledChild');
      child.Status__c = 'CompensationFailed';
      child.Parent_Instance__c = parent.Id;
      insert child;

      Test.startTest();
      WorkflowCancelInvocableAction.CancelResult res = callOne(
        'BusyParent',
        true,
        null
      );
      Test.stopTest();

      Assert.isFalse(res.cancelled, 'The parent rollback already runs');
      Assert.areEqual(
        'CompensationFailed',
        statusOf(child.Id),
        'A no-op row must not change a child'
      );
    }
  }

  @IsTest
  static void testLookupDoesNotLoadPayloads() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = buildInstance('PayloadKey', 'Running');
      inst.Output__c = '"big-output"';
      inst.Progress__c = '{"pct": 50}';
      insert inst;

      Test.startTest();
      Workflow_Instance__c found = WorkflowStatusInvocableAction.resolveInstances(
        new List<String>{ 'PayloadKey' }
      )[0];
      Test.stopTest();

      Assert.areEqual(inst.Id, found.Id, 'The key must resolve');
      Boolean loaded;
      try {
        loaded = found.Output__c != null;
      } catch (SObjectException e) {
        loaded = false;
      }
      Assert.isFalse(loaded, 'The lookup must not load payloads (heap)');
    }
  }

  @IsTest
  static void testKeyLookupIgnoresCase() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c inst = buildInstance('Order-ABC', 'Suspended');
      insert inst;

      Test.startTest();
      WorkflowCancelInvocableAction.CancelResult res = callOne(
        'order-abc',
        false,
        null
      );
      Test.stopTest();

      Assert.isTrue(res.found, 'The key matches without case, as in SOQL');
      Assert.isTrue(res.cancelled, 'The live instance must cancel');
      Assert.areEqual(
        'Cancelled',
        statusOf(inst.Id),
        'The instance must not keep running'
      );
    }
  }

  @IsTest
  static void testBulkEngineEntryIgnoresNullAndEmpty() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Integer q0 = Limits.getQueries();
      Assert.areEqual(
        0,
        WorkflowCancellation.cancelInstances(null).size(),
        'Null roots cancel nothing'
      );
      Assert.areEqual(
        0,
        WorkflowCancellation.cancelWithCompensationsInstances(new List<Id>())
          .size(),
        'Empty roots cancel nothing'
      );
      Assert.areEqual(q0, Limits.getQueries(), 'An empty group uses no SOQL');
    }
  }
}
