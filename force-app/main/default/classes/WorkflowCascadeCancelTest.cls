/**
 * Tests for issue #94: a parent that enters a failure state cancels its
 * in-flight descendants through the cancel path. The RED phase wrote these
 * tests before the code.
 *
 * AC map:
 *  AC1 failure states cascade through the cancel traversal
 *  AC2 a child with a compensation stack runs its compensations
 *  AC3 terminal descendants stay untouched
 *  AC4 a repeated cascade is idempotent
 *  AC5 success path and explicit cancel stay the same
 *  AC6 the Revenant_Config__mdt toggle disables the cascade
 *  AC7 SOQL/DML cost does not grow with tree width
 *  AC8 children stop through the cancel path; completed step logs stay
 */
@IsTest
private class WorkflowCascadeCancelTest {
  private static Integer keySeq = 0;

  /**
   * @description Minimal definition so the failure path can resolve the type.
   */
  public class CascadeWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the steps.
     * @return the step names
     */
    public List<String> getSteps() {
      return new List<String>{ 'StepA' };
    }

    /**
     * @description Returns the first step.
     * @return the first step name
     */
    public String getInitialStep() {
      return 'StepA';
    }

    /**
     * @description Ends the workflow after any step.
     * @param currentStepName the step that completed
     * @param result the step result
     * @return null (no next step)
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  // ============================================================
  // HELPERS
  // ============================================================

  private static String nextKey(String prefix) {
    keySeq++;
    return prefix + '-' + keySeq + '-' + Crypto.getRandomInteger();
  }

  private static Workflow_Instance__c newInstance(Id parentId, String status) {
    return new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowCascadeCancelTest.CascadeWorkflow',
      Status__c = status,
      Current_Step__c = 'StepA',
      Parent_Instance__c = parentId,
      Correlation_Key__c = nextKey('Cascade')
    );
  }

  private static Workflow_Instance__c insertInstance(
    Id parentId,
    String status
  ) {
    Workflow_Instance__c inst = newInstance(parentId, status);
    insert inst;
    return inst;
  }

  private static List<Workflow_Instance__c> insertChildren(
    List<Workflow_Instance__c> parents,
    Integer width,
    String status
  ) {
    List<Workflow_Instance__c> children = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c parent : parents) {
      for (Integer i = 0; i < width; i++) {
        children.add(newInstance(parent.Id, status));
      }
    }
    insert children;
    return children;
  }

  // Gives the instance a one-entry compensation stack backed by a completed
  // forward step log, so a compensating cancel has work to do.
  private static void giveCompensationStack(Workflow_Instance__c inst) {
    inst.Compensation_Stack__c = '["StepA"]';
    update inst;
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = inst.Id,
      Step_Name__c = 'StepA',
      Status__c = 'Completed',
      Output__c = '{"done":true}',
      Retry_Count__c = 0
    );
  }

  private static String statusOf(Id instanceId) {
    return [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ]
    .Status__c;
  }

  private static Integer compensateLogCount(Id instanceId) {
    return [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'StepA_Compensate'
    ];
  }

  // Delivers the cascade events level by level. Each pass publishes the events
  // of the next level, so one tree needs one delivery for each level.
  private static void deliverAll() {
    for (Integer i = 0; i < 6; i++) {
      Test.getEventBus().deliver();
    }
  }

  private static void setStatus(Id instanceId, String status) {
    update new Workflow_Instance__c(Id = instanceId, Status__c = status);
  }

  // ============================================================
  // AC1 — failure states cascade
  // ============================================================

  @IsTest
  static void failedParentViaEngineCancelsRunningChild() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Running');

      Test.startTest();
      WorkflowEngine.failWorkflowInstance(parent.Id, 'StepA', 'boom');
      deliverAll();
      Test.stopTest();

      System.assertEquals(
        'Failed',
        statusOf(parent.Id),
        'The parent must stay Failed'
      );
      System.assertEquals(
        'Cancelled',
        statusOf(child.Id),
        'A failed parent must cancel its running child'
      );
    }
  }

  @IsTest
  static void compensatedParentCancelsChild() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Compensating');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Suspended');

      Test.startTest();
      setStatus(parent.Id, 'Compensated');
      deliverAll();
      Test.stopTest();

      System.assertEquals(
        'Cancelled',
        statusOf(child.Id),
        'A Compensated parent must cancel its suspended child'
      );
    }
  }

  @IsTest
  static void compensationFailedParentCancelsChild() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Compensating');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Pending');

      Test.startTest();
      setStatus(parent.Id, 'CompensationFailed');
      deliverAll();
      Test.stopTest();

      System.assertEquals(
        'Cancelled',
        statusOf(child.Id),
        'A CompensationFailed parent must cancel its pending child'
      );
      System.assertEquals(
        'CompensationFailed',
        statusOf(parent.Id),
        'The cascade must not change the parent'
      );
    }
  }

  @IsTest
  static void cascadeReachesGrandchildren() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Suspended');
      Workflow_Instance__c grandchild = insertInstance(child.Id, 'Running');

      Test.startTest();
      setStatus(parent.Id, 'Failed');
      deliverAll();
      Test.stopTest();

      System.assertEquals('Cancelled', statusOf(child.Id), 'Child reaped');
      System.assertEquals(
        'Cancelled',
        statusOf(grandchild.Id),
        'Grandchild reaped'
      );
    }
  }

  // The request runs no query, so a child linked later is still covered. A
  // childless parent costs one cheap pass that cancels nothing.
  @IsTest
  static void childlessFailurePublishesOneHarmlessEvent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c parent = insertInstance(null, 'Running');

      Test.startTest();
      setStatus(parent.Id, 'Failed');
      System.assertEquals(
        1,
        WorkflowCascadeCancel.publishedEvents.size(),
        'Every failed parent gets one event'
      );
      deliverAll();
      Test.stopTest();

      System.assertEquals('Failed', statusOf(parent.Id), 'Parent unchanged');
      System.assertEquals(
        1,
        WorkflowCascadeCancel.publishedEvents.size(),
        'A childless pass publishes no next level'
      );
    }
  }

  // A child linked after the parent failed (same transaction) is reaped.
  @IsTest
  static void childLinkedAfterFailureIsReaped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');

      Test.startTest();
      setStatus(parent.Id, 'Failed');
      Workflow_Instance__c late = insertInstance(parent.Id, 'Running');
      deliverAll();
      Test.stopTest();

      System.assertEquals('Cancelled', statusOf(late.Id), 'Late child reaped');
    }
  }

  // ============================================================
  // Issue #241 — a child linked after the cascade pass
  // ============================================================

  // The pass ran and found no child. A child then commits. It must be reaped.
  private static void assertLateChildReaped(String parentStatus) {
    WorkflowEngine.disableQueueableInTest = true;
    Workflow_Instance__c parent = insertInstance(null, 'Running');

    Test.startTest();
    setStatus(parent.Id, parentStatus);
    deliverAll();
    WorkflowCascadeCancel.publishedEvents.clear();
    Workflow_Instance__c late = insertInstance(parent.Id, 'Running');
    System.assertEquals(
      1,
      WorkflowCascadeCancel.publishedEvents.size(),
      'A late child requests one cascade'
    );
    deliverAll();
    Test.stopTest();

    System.assertEquals(parentStatus, statusOf(parent.Id), 'Parent unchanged');
    System.assertEquals('Cancelled', statusOf(late.Id), 'Late child reaped');
  }

  @IsTest
  static void childAfterPassUnderFailedParentIsReaped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      assertLateChildReaped('Failed');
    }
  }

  @IsTest
  static void childAfterPassUnderCompensatedParentIsReaped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      assertLateChildReaped('Compensated');
    }
  }

  @IsTest
  static void childAfterPassUnderCompensationFailedParentIsReaped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      assertLateChildReaped('CompensationFailed');
    }
  }

  @IsTest
  static void lateChildWithToggleOffIsKept() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.cascadeCancelChildrenOnFailure = false;
      Workflow_Instance__c parent = insertInstance(null, 'Failed');

      Test.startTest();
      Workflow_Instance__c late = insertInstance(parent.Id, 'Running');
      deliverAll();
      Test.stopTest();

      System.assertEquals(
        0,
        WorkflowCascadeCancel.publishedEvents.size(),
        'Toggle off: no event for a late child'
      );
      System.assertEquals('Running', statusOf(late.Id), 'Child kept');
    }
  }

  @IsTest
  static void childOfActiveParentPublishesNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');

      Test.startTest();
      Workflow_Instance__c child = insertInstance(parent.Id, 'Running');
      deliverAll();
      Test.stopTest();

      System.assertEquals(
        0,
        WorkflowCascadeCancel.publishedEvents.size(),
        'An active parent needs no cascade'
      );
      System.assertEquals('Running', statusOf(child.Id), 'Child keeps running');
    }
  }

  @IsTest
  static void noParentRunsNoQuery() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      Integer q0 = Limits.getQueries();
      WorkflowCascadeCancel.requestCascadeForLateChildren(null);
      WorkflowCascadeCancel.requestCascadeForLateChildren(new Set<Id>());
      System.assertEquals(0, Limits.getQueries() - q0, 'No parent, no query');
      System.assertEquals(
        0,
        WorkflowCascadeCancel.publishedEvents.size(),
        'No parent, no event'
      );
      Test.stopTest();
    }
  }

  @IsTest
  static void bulkLateChildrenCostDoesNotGrowAndPublishOncePerFailedParent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c failedA = insertInstance(null, 'Failed');
      Workflow_Instance__c failedB = insertInstance(null, 'Compensated');
      Workflow_Instance__c active = insertInstance(null, 'Running');
      List<Workflow_Instance__c> kids = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 3; i++) {
        kids.add(newInstance(failedA.Id, 'Running'));
        kids.add(newInstance(failedB.Id, 'Running'));
        kids.add(newInstance(active.Id, 'Running'));
      }

      Test.startTest();
      Integer q0 = Limits.getQueries();
      insert kids;
      System.assertEquals(
        2,
        WorkflowCascadeCancel.publishedEvents.size(),
        'One event for each failed parent'
      );
      Integer smallCost = Limits.getQueries() - q0;
      List<Workflow_Instance__c> more = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 30; i++) {
        more.add(newInstance(failedA.Id, 'Running'));
      }
      q0 = Limits.getQueries();
      insert more;
      System.assert(
        Limits.getQueries() - q0 <= smallCost,
        'Query cost does not grow with the child count'
      );
      Test.stopTest();
    }
  }

  @IsTest
  static void terminalLateChildPublishesNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c parent = insertInstance(null, 'Failed');

      Test.startTest();
      insertInstance(parent.Id, 'Completed');
      Test.stopTest();

      System.assertEquals(
        0,
        WorkflowCascadeCancel.publishedEvents.size(),
        'A finished child needs no cascade'
      );
    }
  }

  // ============================================================
  // AC2 — saga semantics
  // ============================================================

  @IsTest
  static void childWithCompensationStackCompensates() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Suspended');
      giveCompensationStack(child);

      Test.startTest();
      setStatus(parent.Id, 'Failed');
      deliverAll();
      Test.stopTest();

      Workflow_Instance__c after = [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :child.Id
      ];
      System.assertEquals(
        'Cancelling',
        after.Status__c,
        'A child with a compensation stack must roll back'
      );
      System.assert(
        after.Error_Message__c.contains('Cancelled by user'),
        'The cancel-phase marker must be set: ' + after.Error_Message__c
      );
      Workflow_Step_Execution__c comp = [
        SELECT Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :child.Id
          AND Step_Name__c = 'StepA_Compensate'
      ];
      System.assertEquals('Pending', comp.Status__c, 'First undo step queued');
      System.assertEquals(
        '{"done":true}',
        comp.Output__c,
        'The undo step gets the forward output'
      );
    }
  }

  // Builds a suspended child with a real compensatable step on its stack.
  private static Workflow_Instance__c insertSagaChild(Id parentId) {
    Workflow_Instance__c child = new Workflow_Instance__c(
      Workflow_Name__c = 'WorkflowEngineTest.HappyWorkflow',
      Status__c = 'Suspended',
      Parent_Instance__c = parentId,
      Correlation_Key__c = nextKey('Saga'),
      Input__c = '{}',
      Compensation_Stack__c = JSON.serialize(
        new List<String>{ 'WorkflowEngineTest.CompensatableHappyStep' }
      )
    );
    insert child;
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = child.Id,
      Step_Name__c = 'WorkflowEngineTest.CompensatableHappyStep',
      Status__c = 'Completed',
      Output__c = '{}',
      Retry_Count__c = 0
    );
    return child;
  }

  // Builds a child whose rollback stalled (CompensationFailed) with one failed
  // undo attempt.
  private static Workflow_Instance__c insertStalledChild(Id parentId) {
    Workflow_Instance__c child = insertInstance(parentId, 'Compensating');
    giveCompensationStack(child);
    insert new Workflow_Step_Execution__c(
      Workflow_Instance__c = child.Id,
      Step_Name__c = 'StepA_Compensate',
      Status__c = 'Failed',
      Retry_Count__c = 0
    );
    setStatus(child.Id, 'CompensationFailed');
    return child;
  }

  // A stalled rollback is not terminal. The cascade uses the compensating cancel,
  // so the stalled rollback resumes under the cancel phase.
  @IsTest
  static void compensationFailedChildResumesRollback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertStalledChild(parent.Id);
      WorkflowEngine.cascadeCancelChildrenOnFailure = false;
      Workflow_Instance__c grandchild = insertInstance(child.Id, 'Running');
      WorkflowEngine.cascadeCancelChildrenOnFailure = true;

      Test.startTest();
      setStatus(parent.Id, 'Failed');
      deliverAll();
      Test.stopTest();

      System.assertEquals(
        'Cancelling',
        statusOf(child.Id),
        'The stalled rollback resumes under the cancel phase'
      );
      System.assertEquals(
        2,
        compensateLogCount(child.Id),
        'A fresh undo attempt is appended; the failed one stays'
      );
      System.assertEquals(
        'Cancelled',
        statusOf(grandchild.Id),
        'The walk goes through the stalled child'
      );
    }
  }

  // End to end: the cascaded rollback runs the compensation and drains.
  @IsTest
  static void cascadedRollbackDrainsToCancelled() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertSagaChild(parent.Id);

      Test.startTest();
      setStatus(parent.Id, 'Failed');
      deliverAll();
      WorkflowEngine.runStep(child.Id, null); // compensate()
      WorkflowEngine.runStep(child.Id, null); // stack drained
      Test.stopTest();

      System.assertEquals(
        'Cancelled',
        statusOf(child.Id),
        'The cascaded rollback drains to Cancelled'
      );
    }
  }

  // ============================================================
  // AC3 — terminal descendants untouched
  // ============================================================

  @IsTest
  static void terminalDescendantsAreUntouched() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      List<String> terminal = new List<String>{
        'Completed',
        'Failed',
        'Compensated',
        'Cancelled',
        'ContinuedAsNew'
      };
      List<Workflow_Instance__c> children = new List<Workflow_Instance__c>();
      for (String status : terminal) {
        Workflow_Instance__c child = newInstance(parent.Id, status);
        child.Error_Message__c = 'original-' + status;
        children.add(child);
      }
      insert children;
      Workflow_Instance__c live = insertInstance(parent.Id, 'Running');

      Test.startTest();
      setStatus(parent.Id, 'Failed');
      deliverAll();
      Test.stopTest();

      List<Workflow_Instance__c> rows = [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id IN :children
      ];
      System.assertEquals(5, rows.size(), 'All terminal children read');
      for (Workflow_Instance__c after : rows) {
        System.assertEquals(
          'original-' + after.Status__c,
          after.Error_Message__c,
          'A terminal child must not change'
        );
      }
      System.assertEquals('Cancelled', statusOf(live.Id), 'Live child reaped');
    }
  }

  // ============================================================
  // AC4 — idempotency
  // ============================================================

  @IsTest
  static void repeatedCascadeIsIdempotent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Suspended');
      giveCompensationStack(child);
      Workflow_Instance__c plain = insertInstance(parent.Id, 'Running');
      setStatus(parent.Id, 'Failed');

      Test.startTest();
      Set<Id> parents = new Set<Id>{ parent.Id };
      WorkflowCascadeCancel.reapFailedParents(parents);
      WorkflowCascadeCancel.reapFailedParents(parents);
      // A duplicate event pair in one batch is also safe.
      WorkflowCascadeCancel.handleEvents(
        new List<Workflow_Event__e>{
          WorkflowCascadeCancel.buildParentEvent(parent.Id),
          WorkflowCascadeCancel.buildParentEvent(parent.Id)
        }
      );
      Test.stopTest();

      System.assertEquals(
        'Cancelling',
        statusOf(child.Id),
        'Still rolling back'
      );
      System.assertEquals(
        1,
        compensateLogCount(child.Id),
        'A repeat must not queue a second undo step'
      );
      System.assertEquals(
        'Cancelled',
        statusOf(plain.Id),
        'Plain child reaped'
      );
      System.assertEquals('Failed', statusOf(parent.Id), 'Parent unchanged');
    }
  }

  @IsTest
  static void cancellingChildIsSkipped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Cancelling');
      child.Error_Message__c = 'already cancelling';
      update child;
      setStatus(parent.Id, 'Failed');

      Test.startTest();
      WorkflowCascadeCancel.reapFailedParents(new Set<Id>{ parent.Id });
      Test.stopTest();

      Workflow_Instance__c after = [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id = :child.Id
      ];
      System.assertEquals('Cancelling', after.Status__c, 'No re-cancel');
      System.assertEquals(
        'already cancelling',
        after.Error_Message__c,
        'A child already being reaped must not change'
      );
    }
  }

  @IsTest
  static void staleEventForRedrivenParentIsIgnored() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Running');

      Test.startTest();
      setStatus(parent.Id, 'Failed');
      // An operator redrives the parent before the event arrives.
      setStatus(parent.Id, 'Running');
      deliverAll();
      Test.stopTest();

      System.assertEquals(
        'Running',
        statusOf(child.Id),
        'A redriven parent must keep its children'
      );
    }
  }

  @IsTest
  static void cascadeErrorNeverFailsParentAndRetries() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      // Toggle off in setup: only the retry job can reap the child.
      WorkflowEngine.cascadeCancelChildrenOnFailure = false;
      Workflow_Instance__c parent = insertInstance(null, 'Failed');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Running');
      WorkflowEngine.cascadeCancelChildrenOnFailure = true;

      Test.startTest();
      WorkflowCascadeCancel.throwTestException = true;
      WorkflowCascadeCancel.handleEvents(
        new List<Workflow_Event__e>{
          WorkflowCascadeCancel.buildParentEvent(parent.Id)
        }
      );

      System.assertEquals('Failed', statusOf(parent.Id), 'Parent unchanged');
      System.assertEquals('Running', statusOf(child.Id), 'Pass rolled back');
      System.assertEquals(
        1,
        Limits.getQueueableJobs(),
        'A failed pass must schedule one delayed retry job'
      );

      // The retry job runs at stopTest and succeeds when the fault is gone.
      WorkflowCascadeCancel.throwTestException = false;
      Test.stopTest();

      System.assertEquals('Cancelled', statusOf(child.Id), 'Retry reaps');
    }
  }

  // ============================================================
  // Issue #310 — the DML budget is spent
  // ============================================================

  // Uses all DML statements of the transaction.
  private static void spendDmlBudget() {
    while (Limits.getDmlStatements() < Limits.getLimitDmlStatements()) {
      insert new Account(Name = 'Spend');
    }
  }

  // A failed parent with a running child and no cascade pass yet.
  private static List<Workflow_Instance__c> failedParentWithChild() {
    WorkflowEngine.disableQueueableInTest = true;
    WorkflowEngine.cascadeCancelChildrenOnFailure = false;
    Workflow_Instance__c parent = insertInstance(null, 'Failed');
    Workflow_Instance__c child = insertInstance(parent.Id, 'Running');
    WorkflowEngine.cascadeCancelChildrenOnFailure = true;
    return new List<Workflow_Instance__c>{ parent, child };
  }

  @IsTest
  static void failurePathWithoutDmlBudgetStillReapsChild() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> pair = failedParentWithChild();

      Test.startTest();
      spendDmlBudget();
      WorkflowCascadeCancel.requestCascade(new Set<Id>{ pair[0].Id });
      System.assertEquals(
        1,
        Limits.getQueueableJobs(),
        'No DML budget: the request goes to one job'
      );
      Test.stopTest();

      System.assertEquals('Failed', statusOf(pair[0].Id), 'Parent unchanged');
      System.assertEquals('Cancelled', statusOf(pair[1].Id), 'Job reaps');
    }
  }

  @IsTest
  static void lateChildPathWithoutDmlBudgetStillReapsChild() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> pair = failedParentWithChild();

      Test.startTest();
      spendDmlBudget();
      WorkflowCascadeCancel.requestCascadeForLateChildren(
        new Set<Id>{ pair[0].Id }
      );
      System.assertEquals(
        1,
        Limits.getQueueableJobs(),
        'No DML budget: the late child request goes to one job'
      );
      Test.stopTest();

      System.assertEquals('Cancelled', statusOf(pair[1].Id), 'Job reaps');
    }
  }

  @IsTest
  static void noDmlBudgetWithToggleOffEnqueuesNothing() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> pair = failedParentWithChild();
      WorkflowEngine.cascadeCancelChildrenOnFailure = false;

      Test.startTest();
      spendDmlBudget();
      WorkflowCascadeCancel.requestCascade(new Set<Id>{ pair[0].Id });
      System.assertEquals(0, Limits.getQueueableJobs(), 'Toggle off: no job');
      Test.stopTest();

      System.assertEquals('Running', statusOf(pair[1].Id), 'Child kept');
    }
  }

  @IsTest
  static void noDmlBudgetAndNoQueueableSlotDoesNotThrow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Workflow_Instance__c> pair = failedParentWithChild();

      Test.startTest();
      spendDmlBudget();
      while (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
        System.enqueueJob(new WorkflowCascadeCancelTest.NoopJob());
      }
      WorkflowCascadeCancel.requestCascade(new Set<Id>{ pair[0].Id });
      System.assertEquals(
        Limits.getLimitQueueableJobs(),
        Limits.getQueueableJobs(),
        'No slot: no extra job and no exception'
      );
      Test.stopTest();
    }
  }

  public class NoopJob implements Queueable {
    public void execute(QueueableContext context) {
    }
  }

  @IsTest
  static void cascadeStopsRetryAfterMaxAttempts() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.cascadeCancelChildrenOnFailure = false;
      Workflow_Instance__c parent = insertInstance(null, 'Failed');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Running');
      WorkflowEngine.cascadeCancelChildrenOnFailure = true;
      Workflow_Event__e last = WorkflowCascadeCancel.buildParentEvent(
        parent.Id
      );
      last.Payload__c =
        '{"attempt":' +
        WorkflowCascadeCancel.MAX_ATTEMPTS +
        '}';

      Test.startTest();
      WorkflowCascadeCancel.throwTestException = true;
      WorkflowCascadeCancel.publishedEvents.clear();
      WorkflowCascadeCancel.handleEvents(new List<Workflow_Event__e>{ last });

      System.assertEquals(0, Limits.getQueueableJobs(), 'No retry job');
      System.assertEquals('Running', statusOf(child.Id), 'Pass rolled back');
      System.assertEquals(
        0,
        WorkflowCascadeCancel.publishedEvents.size(),
        'The last attempt must not republish'
      );
      WorkflowCascadeCancel.throwTestException = false;
      Test.stopTest();
    }
  }

  // A bad node fails the merged pass. The retry job runs each request alone,
  // so the healthy parent is still reaped.
  @IsTest
  static void retryIsolatesPoisonRequest() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.cascadeCancelChildrenOnFailure = false;
      Workflow_Instance__c poisonParent = insertInstance(null, 'Failed');
      Workflow_Instance__c poison = newInstance(poisonParent.Id, 'Running');
      poison.Compensation_Stack__c = 'not json';
      Workflow_Instance__c healthyParent = insertInstance(null, 'Failed');
      Workflow_Instance__c healthy = newInstance(healthyParent.Id, 'Running');
      insert new List<Workflow_Instance__c>{ poison, healthy };
      WorkflowEngine.cascadeCancelChildrenOnFailure = true;

      Test.startTest();
      WorkflowCascadeCancel.handleEvents(
        new List<Workflow_Event__e>{
          WorkflowCascadeCancel.buildParentEvent(poisonParent.Id),
          WorkflowCascadeCancel.buildParentEvent(healthyParent.Id)
        }
      );
      System.assertEquals(
        'Running',
        statusOf(healthy.Id),
        'The merged pass rolled back'
      );
      Test.stopTest();

      System.assertEquals(
        'Cancelled',
        statusOf(healthy.Id),
        'The retry reaps the healthy request alone'
      );
      System.assertEquals(
        'Running',
        statusOf(poison.Id),
        'The bad node stops only its own request'
      );
    }
  }

  // Apex allows 5 savepoints per transaction. A retry job with 6 requests must
  // not exceed it: it runs 4 and schedules the rest.
  @IsTest
  static void retryJobStaysUnderSavepointLimit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      List<Workflow_Instance__c> parents = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 6; i++) {
        parents.add(newInstance(null, 'Failed'));
      }
      insert parents;
      WorkflowEngine.cascadeCancelChildrenOnFailure = false;
      insertChildren(parents, 1, 'Running');
      WorkflowEngine.cascadeCancelChildrenOnFailure = true;
      List<Workflow_Event__e> events = new List<Workflow_Event__e>();
      for (Workflow_Instance__c p : parents) {
        events.add(WorkflowCascadeCancel.buildParentEvent(p.Id));
      }

      Test.startTest();
      WorkflowCascadeCancel.throwTestException = true;
      WorkflowCascadeCancel.handleEvents(events);
      WorkflowCascadeCancel.throwTestException = false;
      Test.stopTest();

      System.assert(
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Parent_Instance__c IN :parents AND Status__c = 'Cancelled'
        ] >= 4,
        'The retry job reaps its first 4 requests without a savepoint error'
      );
    }
  }

  // The rest of the tree is reachable only through the next-level events. A
  // failed publish must roll back the pass and schedule a retry.
  @IsTest
  static void failedContinuationPublishRetries() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.cascadeCancelChildrenOnFailure = false;
      Workflow_Instance__c parent = insertInstance(null, 'Failed');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Running');
      WorkflowEngine.cascadeCancelChildrenOnFailure = true;

      Test.startTest();
      WorkflowCascadeCancel.failContinuationPublish = true;
      WorkflowCascadeCancel.handleEvents(
        new List<Workflow_Event__e>{
          WorkflowCascadeCancel.buildParentEvent(parent.Id)
        }
      );
      System.assertEquals('Running', statusOf(child.Id), 'Pass rolled back');
      System.assertEquals(1, Limits.getQueueableJobs(), 'Retry scheduled');
      WorkflowCascadeCancel.failContinuationPublish = false;
      Test.stopTest();

      System.assertEquals('Cancelled', statusOf(child.Id), 'Retry reaps');
    }
  }

  // A redriven parent keeps the children that later pages would reap.
  @IsTest
  static void nextPageRechecksParent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      insertChildren(new List<Workflow_Instance__c>{ parent }, 5, 'Running');

      Test.startTest();
      WorkflowCascadeCancel.maxNodesPerPass = 2;
      setStatus(parent.Id, 'Failed');
      Test.getEventBus().deliver();
      // An operator redrives the parent between two pages.
      setStatus(parent.Id, 'Running');
      deliverAll();
      Test.stopTest();

      System.assertEquals(
        3,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Parent_Instance__c = :parent.Id AND Status__c = 'Running'
        ],
        'The next page must not reap the children of a redriven parent'
      );
    }
  }

  // ============================================================
  // AC5 — success path and explicit cancel unchanged
  // ============================================================

  @IsTest
  static void completedParentDoesNotCascade() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Running');

      Test.startTest();
      setStatus(parent.Id, 'Completed');
      deliverAll();
      Test.stopTest();

      System.assertEquals(
        0,
        WorkflowCascadeCancel.publishedEvents.size(),
        'A successful parent publishes no cascade'
      );
      System.assertEquals('Running', statusOf(child.Id), 'Child keeps running');
    }
  }

  @IsTest
  static void explicitCancelStillReapsTree() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Suspended');
      Workflow_Instance__c grandchild = insertInstance(child.Id, 'Running');
      Workflow_Instance__c done = insertInstance(parent.Id, 'Completed');

      Test.startTest();
      WorkflowEngine.cancel(parent.Id);
      Test.stopTest();

      System.assertEquals('Cancelled', statusOf(parent.Id), 'Parent');
      System.assertEquals('Cancelled', statusOf(child.Id), 'Child');
      System.assertEquals('Cancelled', statusOf(grandchild.Id), 'Grandchild');
      System.assertEquals('Completed', statusOf(done.Id), 'Terminal child');
      System.assertEquals(
        0,
        WorkflowCascadeCancel.publishedEvents.size(),
        'An explicit cancel publishes no cascade'
      );
    }
  }

  @IsTest
  static void explicitCompensatingCancelUnchanged() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      giveCompensationStack(parent);
      Workflow_Instance__c child = insertInstance(parent.Id, 'Suspended');
      giveCompensationStack(child);

      Test.startTest();
      WorkflowCancellation.cancelWithCompensations(parent.Id);
      Test.stopTest();

      for (Workflow_Instance__c after : [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id IN :new List<Id>{ parent.Id, child.Id }
      ]) {
        System.assertEquals('Cancelling', after.Status__c, 'Rolling back');
        System.assertEquals(
          'Cancelled by user. Compensating.',
          after.Error_Message__c,
          'Message unchanged'
        );
      }
      System.assertEquals(1, compensateLogCount(parent.Id), 'Parent undo');
      System.assertEquals(1, compensateLogCount(child.Id), 'Child undo');
    }
  }

  @IsTest
  static void explicitCompensatingCancelResumesStalledChild() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.cascadeCancelChildrenOnFailure = false;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertStalledChild(parent.Id);

      Test.startTest();
      WorkflowCancellation.cancelWithCompensations(parent.Id);
      Test.stopTest();

      System.assertEquals(
        'Cancelled',
        statusOf(parent.Id),
        'No stack: Cancelled'
      );
      System.assertEquals(
        'Cancelling',
        statusOf(child.Id),
        'An explicit compensating cancel still resumes a stalled rollback'
      );
      System.assertEquals(
        2,
        compensateLogCount(child.Id),
        'A fresh undo attempt is appended; the failed one stays'
      );
    }
  }

  @IsTest
  static void explicitPlainCancelForcesStalledChildTerminal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.cascadeCancelChildrenOnFailure = false;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertStalledChild(parent.Id);

      Test.startTest();
      WorkflowEngine.cancel(parent.Id);
      Test.stopTest();

      System.assertEquals(
        'Cancelled',
        statusOf(child.Id),
        'A plain cancel forces a stalled rollback terminal'
      );
      System.assertEquals(1, compensateLogCount(child.Id), 'No new attempt');
    }
  }

  @IsTest
  static void explicitCancelNullIdStillThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Boolean threw = false;
      try {
        WorkflowEngine.cancel(null);
      } catch (WorkflowEngine.WorkflowException ex) {
        threw = ex.getMessage().contains('Workflow instance not found');
      }
      System.assert(threw, 'A null root must still throw');
    }
  }

  @IsTest
  static void explicitCancelMissingInstanceStillThrows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c gone = insertInstance(null, 'Running');
      Id goneId = gone.Id;
      delete gone;

      Test.startTest();
      Boolean threw = false;
      try {
        WorkflowEngine.cancel(goneId);
      } catch (WorkflowEngine.WorkflowException ex) {
        threw = ex.getMessage().contains('Workflow instance not found');
      }
      Test.stopTest();

      System.assert(threw, 'A missing root must still throw');
    }
  }

  // ============================================================
  // AC6 — operator toggle
  // ============================================================

  @IsTest
  static void toggleOffKeepsLegacyAbandonBehavior() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      WorkflowEngine.cascadeCancelChildrenOnFailure = false;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Running');

      Test.startTest();
      setStatus(parent.Id, 'Failed');
      deliverAll();
      WorkflowCascadeCancel.reapFailedParents(new Set<Id>{ parent.Id });
      Test.stopTest();

      System.assertEquals(
        0,
        WorkflowCascadeCancel.publishedEvents.size(),
        'Toggle off: no cascade event'
      );
      System.assertEquals('Running', statusOf(child.Id), 'Child abandoned');
    }
  }

  @IsTest
  static void toggleDefaultsToEnabled() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      System.assertEquals(
        true,
        Revenant_Config__mdt.getInstance('Default')
          .Cascade_Cancel_Children_On_Failure__c,
        'The shipped Default record turns the cascade on'
      );
      System.assertEquals(
        true,
        WorkflowEngine.cascadeCancelChildrenOnFailure,
        'The engine loads the toggle as on'
      );
    }
  }

  // ============================================================
  // AC7 — bulk safety
  // ============================================================

  // Builds a 3-level tree (parent -> width children -> width grandchildren
  // each). Every child carries a compensation stack.
  private static Id buildFailedTree(Integer width) {
    Workflow_Instance__c parent = insertInstance(null, 'Running');
    List<Workflow_Instance__c> children = insertChildren(
      new List<Workflow_Instance__c>{ parent },
      width,
      'Suspended'
    );
    List<Workflow_Step_Execution__c> forward = new List<Workflow_Step_Execution__c>();
    for (Workflow_Instance__c child : children) {
      child.Compensation_Stack__c = '["StepA"]';
      forward.add(
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = child.Id,
          Step_Name__c = 'StepA',
          Status__c = 'Completed',
          Retry_Count__c = 0
        )
      );
      forward.add(
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = child.Id,
          Step_Name__c = 'StepA',
          Status__c = 'Pending',
          Retry_Count__c = 0
        )
      );
    }
    update children;
    insert forward;
    insertChildren(children, width, 'Running');
    setStatus(parent.Id, 'Failed');
    return parent.Id;
  }

  private static Integer[] measureReap(Id parentId) {
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    WorkflowCascadeCancel.reapFailedParents(new Set<Id>{ parentId });
    return new List<Integer>{
      Limits.getQueries() - q0,
      Limits.getDmlStatements() - d0
    };
  }

  // Cost of one pass over the grandchild level (all nodes go terminal, so the
  // parent notice and the lifecycle publish run too).
  private static Integer[] measureLevel(Id parentId) {
    List<Id> childIds = new List<Id>(
      new Map<Id, Workflow_Instance__c>(
          [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE Parent_Instance__c = :parentId
          ]
        )
        .keySet()
    );
    Workflow_Event__e event = WorkflowCascadeCancel.buildParentEvent(parentId);
    event.Payload__c = JSON.serialize(
      new Map<String, Object>{ 'attempt' => 1, 'frontier' => childIds }
    );
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    WorkflowCascadeCancel.handleEvents(new List<Workflow_Event__e>{ event });
    return new List<Integer>{
      Limits.getQueries() - q0,
      Limits.getDmlStatements() - d0
    };
  }

  @IsTest
  static void cascadeCostIsConstantInTreeWidth() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id warmUp = buildFailedTree(1);
      Id narrow = buildFailedTree(2);
      Id wide = buildFailedTree(12);

      Test.startTest();
      // The first pass runs static initializers; do not measure it.
      measureReap(warmUp);
      Integer[] narrowCost = measureReap(narrow);
      Integer[] wideCost = measureReap(wide);
      measureLevel(warmUp);
      Integer[] narrowLevel = measureLevel(narrow);
      Integer[] wideLevel = measureLevel(wide);
      deliverAll();
      Test.stopTest();

      System.assertEquals(
        narrowLevel[0],
        wideLevel[0],
        'SOQL of a terminal level must not grow with width'
      );
      System.assertEquals(
        narrowLevel[1],
        wideLevel[1],
        'DML of a terminal level must not grow with width'
      );

      System.assertEquals(
        narrowCost[0],
        wideCost[0],
        'SOQL must not grow with width'
      );
      System.assertEquals(
        narrowCost[1],
        wideCost[1],
        'DML statements must not grow with width'
      );
      System.assertEquals(
        0,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE
            Parent_Instance__c != NULL
            AND Status__c IN ('Running', 'Suspended', 'Pending')
        ],
        'Every descendant is reaped'
      );
    }
  }

  // One pass reads one page, not the whole level.
  @IsTest
  static void wideLevelPassReadsBoundedRows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      insertChildren(new List<Workflow_Instance__c>{ parent }, 60, 'Running');
      setStatus(parent.Id, 'Failed');

      Test.startTest();
      WorkflowCascadeCancel.maxNodesPerPass = 3;
      Integer rows0 = Limits.getQueryRows();
      WorkflowCascadeCancel.reapFailedParents(new Set<Id>{ parent.Id });
      Integer rowsRead = Limits.getQueryRows() - rows0;

      System.assert(
        rowsRead < 20,
        'A pass must read a bounded page, not 60 rows: ' + rowsRead
      );
      System.assertEquals(
        57,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Parent_Instance__c = :parent.Id AND Status__c = 'Running'
        ],
        'One pass cancels one page'
      );
      Test.stopTest();
    }
  }

  @IsTest
  static void overCapTreeContinuesInNextEvent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      insertChildren(new List<Workflow_Instance__c>{ parent }, 5, 'Running');

      Test.startTest();
      WorkflowCascadeCancel.maxNodesPerPass = 2;
      setStatus(parent.Id, 'Failed');
      // Pass 1 reaps 2 nodes and publishes the next page.
      Test.getEventBus().deliver();
      System.assertEquals(
        3,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Parent_Instance__c = :parent.Id AND Status__c = 'Running'
        ],
        'The cap bounds one pass'
      );
      // The next events reap the rest.
      deliverAll();
      Test.stopTest();

      System.assertEquals(
        0,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Parent_Instance__c = :parent.Id AND Status__c = 'Running'
        ],
        'Continuations reap the remainder'
      );
    }
  }

  // AC4: a re-hop of the failure transition (Failed -> Failed) publishes no
  // second cascade.
  @IsTest
  static void failureReHopPublishesOnce() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Running');

      Test.startTest();
      WorkflowEngine.failWorkflowInstance(parent.Id, 'StepA', 'boom');
      WorkflowEngine.failWorkflowInstance(parent.Id, 'StepA', 'boom again');
      System.assertEquals(
        1,
        WorkflowCascadeCancel.publishedEvents.size(),
        'A re-hop publishes no second event'
      );
      deliverAll();
      Test.stopTest();

      System.assertEquals('Failed', statusOf(parent.Id), 'Parent unchanged');
      System.assertEquals('Cancelled', statusOf(child.Id), 'Child reaped');
    }
  }

  // AC7 request side: a bulk failure costs no query and one publish.
  @IsTest
  static void bulkParentFailureCostsNoQuery() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      List<Workflow_Instance__c> parents = new List<Workflow_Instance__c>{
        newInstance(null, 'Running'),
        newInstance(null, 'Running')
      };
      insert parents;
      insertChildren(parents, 3, 'Running');
      Boolean warm = WorkflowEngine.cascadeCancelChildrenOnFailure;

      Test.startTest();
      for (Workflow_Instance__c p : parents) {
        p.Status__c = 'Failed';
      }
      Integer q0 = Limits.getQueries();
      update parents;
      System.assertEquals(
        0,
        Limits.getQueries() - q0,
        'The failure transaction runs no cascade query'
      );
      System.assertEquals(
        2,
        WorkflowCascadeCancel.publishedEvents.size(),
        'One event per failed parent'
      );
      deliverAll();
      Test.stopTest();

      System.assert(warm, 'Toggle on');
      System.assertEquals(
        0,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Parent_Instance__c IN :parents AND Status__c = 'Running'
        ],
        'All children of both parents reaped'
      );
    }
  }

  @IsTest
  static void malformedEventIsDropped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.startTest();
      WorkflowCascadeCancel.handleEvents(
        new List<Workflow_Event__e>{
          new Workflow_Event__e(
            Workflow_Instance_Id__c = 'not-an-id',
            Event_Type__c = WorkflowCascadeCancel.EVENT_TYPE
          )
        }
      );
      Test.stopTest();
      System.assertEquals(0, Limits.getQueueableJobs(), 'No retry for junk');
    }
  }

  // ============================================================
  // AC8 — chain handoff and append-only log
  // ============================================================

  @IsTest
  static void reapedChildStopsThroughCancelPath() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Running');
      child.Sleep_Until__c = System.now().addHours(1);
      update child;
      Workflow_Step_Execution__c done = new Workflow_Step_Execution__c(
        Workflow_Instance__c = child.Id,
        Step_Name__c = 'StepZ',
        Status__c = 'Completed',
        Output__c = 'kept',
        Retry_Count__c = 0
      );
      Workflow_Step_Execution__c active = new Workflow_Step_Execution__c(
        Workflow_Instance__c = child.Id,
        Step_Name__c = 'StepA',
        Status__c = 'Running',
        Retry_Count__c = 0
      );
      insert new List<Workflow_Step_Execution__c>{ done, active };
      Integer logsBefore = [
        SELECT COUNT()
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :child.Id
      ];

      Test.startTest();
      setStatus(parent.Id, 'Failed');
      deliverAll();
      Test.stopTest();

      System.assertEquals(
        'Cancelled',
        [SELECT Status__c FROM Workflow_Step_Execution__c WHERE Id = :active.Id]
        .Status__c,
        'The in-flight step is cancelled like an explicit cancel'
      );
      Workflow_Step_Execution__c doneAfter = [
        SELECT Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :done.Id
      ];
      System.assertEquals('Completed', doneAfter.Status__c, 'Log kept');
      System.assertEquals('kept', doneAfter.Output__c, 'Log kept');
      System.assertEquals(
        logsBefore,
        [
          SELECT COUNT()
          FROM Workflow_Step_Execution__c
          WHERE Workflow_Instance__c = :child.Id
        ],
        'No step log is deleted or added for a plain cancel'
      );
      System.assertEquals(
        null,
        [SELECT Sleep_Until__c FROM Workflow_Instance__c WHERE Id = :child.Id]
        .Sleep_Until__c,
        'The timed wait is disarmed'
      );
    }
  }

  // AC8: a cascaded rollback starts its own orchestrator chain.
  @IsTest
  static void cascadedRollbackEnqueuesOrchestrator() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.cascadeCancelChildrenOnFailure = false;
      Workflow_Instance__c parent = insertInstance(null, 'Failed');
      insertSagaChild(parent.Id);
      WorkflowEngine.cascadeCancelChildrenOnFailure = true;

      Test.startTest();
      WorkflowEngine.disableQueueableInTest = false;
      WorkflowCascadeCancel.reapFailedParents(new Set<Id>{ parent.Id });
      System.assertEquals(
        1,
        Limits.getQueueableJobs(),
        'The Cancelling child gets one orchestrator hop'
      );
      WorkflowEngine.disableQueueableInTest = true;
      Test.stopTest();
    }
  }
}
