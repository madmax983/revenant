/**
 * @description Tests for the one-walk mixed-mode bulk cancel (issue #264).
 */
@IsTest
private class WorkflowCancellationByModeTest {
  private static final String WORKFLOW = 'WorkflowEngineTest.HappyWorkflow';
  private static final String PLAIN_STEP = 'WorkflowEngineTest.NonCompensatableStep';
  private static final String COMP_STEP = 'WorkflowEngineTest.CompensatableHappyStep';

  private static Workflow_Instance__c build(
    String key,
    Boolean saga,
    Id parentId
  ) {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WORKFLOW,
      Status__c = 'Suspended',
      Correlation_Key__c = key,
      Parent_Instance__c = parentId
    );
    if (saga) {
      inst.Compensation_Stack__c = JSON.serialize(
        new List<String>{ PLAIN_STEP, COMP_STEP }
      );
    }
    return inst;
  }

  private static String statusOf(Id instanceId) {
    return [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
    .Status__c;
  }

  // Two disjoint chains of depth + 1 nodes, inserted one level at a time.
  // Index 0 is the chain of the hard-stop root, index 1 of the rollback root.
  private static List<List<Id>> insertChains(String prefix, Integer depth) {
    List<List<Id>> chains = new List<List<Id>>{
      new List<Id>(),
      new List<Id>()
    };
    for (Integer level = 0; level <= depth; level++) {
      List<Workflow_Instance__c> pair = new List<Workflow_Instance__c>();
      for (Integer side = 0; side < 2; side++) {
        pair.add(
          build(
            prefix + side + '-' + level,
            side == 1 && level == 0,
            level == 0 ? null : chains[side][level - 1]
          )
        );
      }
      insert pair;
      chains[0].add(pair[0].Id);
      chains[1].add(pair[1].Id);
    }
    return chains;
  }

  // Cancels the two roots in one call and returns the SOQL that it used.
  private static Integer queriesForDepth(String prefix, Integer depth) {
    List<List<Id>> chains = insertChains(prefix, depth);
    Integer q0 = Limits.getQueries();
    WorkflowCancellation.cancelInstancesByMode(
      new List<Id>{ chains[0][0] },
      new List<Id>{ chains[1][0] }
    );
    return Limits.getQueries() - q0;
  }

  @IsTest
  static void testWalkCostDoesNotGrowWithModeCount() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      Test.startTest();
      Integer shallow = queriesForDepth('Shallow', 3);
      Integer deep = queriesForDepth('Deep', 10);
      Test.stopTest();

      Assert.areEqual(
        7,
        deep - shallow,
        'Each extra level must cost one query for both modes together'
      );
    }
  }

  @IsTest
  static void testTwoDeepTreesOfMixedModeFitSoqlLimit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      List<List<Id>> chains = insertChains('Limit', 49);

      Test.startTest();
      List<WorkflowCancelInvocableAction.CancelRequest> reqs = new List<WorkflowCancelInvocableAction.CancelRequest>();
      for (Integer side = 0; side < 2; side++) {
        WorkflowCancelInvocableAction.CancelRequest r = new WorkflowCancelInvocableAction.CancelRequest();
        r.workflowKeyOrId = chains[side][0];
        r.runCompensations = side == 1;
        reqs.add(r);
      }
      List<WorkflowCancelInvocableAction.CancelResult> results = WorkflowCancelInvocableAction.cancelWorkflow(
        reqs
      );
      Test.stopTest();

      Assert.isTrue(results[0].cancelled, 'The hard-stop root must cancel');
      Assert.isTrue(results[1].cancelled, 'The rollback root must cancel');
      Set<Id> allIds = new Set<Id>(chains[0]);
      allIds.addAll(chains[1]);
      Assert.areEqual(
        99,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Id IN :allIds AND Status__c = 'Cancelled'
        ],
        'All nodes but the rolling-back root must be Cancelled'
      );
      Assert.areEqual('Cancelled', statusOf(chains[0][49]), 'Deep hard stop');
      Assert.areEqual('Cancelling', statusOf(chains[1][0]), 'Root rolls back');
      Assert.areEqual('Cancelled', statusOf(chains[1][49]), 'Deep child');
    }
  }

  @IsTest
  static void testRollbackRootUnderHardStopRootIsHardStopped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = build('HardParent', false, null);
      insert parent;
      Workflow_Instance__c child = build('RollChild', true, parent.Id);
      insert child;

      Test.startTest();
      WorkflowCancellation.ModeResult res = WorkflowCancellation.cancelInstancesByMode(
        new List<Id>{ parent.Id },
        new List<Id>{ child.Id }
      );
      Test.stopTest();

      Assert.areEqual('Cancelled', statusOf(child.Id), 'Hard stop must win');
      Assert.isTrue(
        res.hardStopped.contains(child.Id),
        'Hard pass cancelled it'
      );
      Assert.isFalse(res.rolledBack.contains(child.Id), 'No rollback ran');
    }
  }

  @IsTest
  static void testHardStopRootUnderRollbackRootStaysHardStopped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = build('RollParent', true, null);
      insert parent;
      Workflow_Instance__c child = build('HardChild', false, parent.Id);
      insert child;

      Test.startTest();
      WorkflowCancellation.ModeResult res = WorkflowCancellation.cancelInstancesByMode(
        new List<Id>{ child.Id },
        new List<Id>{ parent.Id }
      );
      Test.stopTest();

      Assert.areEqual('Cancelled', statusOf(child.Id), 'Child hard stops');
      Assert.areEqual('Cancelling', statusOf(parent.Id), 'Parent rolls back');
      Assert.isTrue(
        res.hardStopped.contains(child.Id),
        'Hard pass cancelled it'
      );
      Assert.isTrue(res.rolledBack.contains(parent.Id), 'Rollback pass ran');
      Assert.isFalse(
        res.rolledBack.contains(child.Id),
        'Child did not roll back'
      );
    }
  }

  @IsTest
  static void testOneModeOnlyAndEmptyCalls() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c inst = build('OnlyRoll', true, null);
      insert inst;

      Test.startTest();
      Integer q0 = Limits.getQueries();
      WorkflowCancellation.ModeResult none = WorkflowCancellation.cancelInstancesByMode(
        null,
        new List<Id>()
      );
      Assert.areEqual(q0, Limits.getQueries(), 'An empty call uses no SOQL');
      Assert.isTrue(none.hardStopped.isEmpty(), 'Nothing hard stopped');
      Assert.isTrue(none.rolledBack.isEmpty(), 'Nothing rolled back');

      WorkflowCancellation.ModeResult res = WorkflowCancellation.cancelInstancesByMode(
        new List<Id>(),
        new List<Id>{ inst.Id }
      );
      Test.stopTest();

      Assert.isTrue(res.hardStopped.isEmpty(), 'No hard-stop root');
      Assert.isTrue(res.rolledBack.contains(inst.Id), 'The root rolls back');
      Assert.areEqual('Cancelling', statusOf(inst.Id), 'Rollback starts');
    }
  }
}
