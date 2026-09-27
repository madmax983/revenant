/**
 * Tests for issue #94: a parent terminal failure cancels its in-flight
 * descendants through the cancel path.
 * Written before the implementation (RED phase).
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

  private static void setStatus(Id instanceId, String status) {
    update new Workflow_Instance__c(Id = instanceId, Status__c = status);
  }

  // ============================================================
  // AC1 — terminal failure states cascade
  // ============================================================

  @IsTest
  static void failedParentViaEngineCancelsRunningChild() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Running');

      Test.startTest();
      WorkflowEngine.failWorkflowInstance(parent.Id, 'StepA', 'boom');
      Test.getEventBus().deliver();
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
      Test.getEventBus().deliver();
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
      Test.getEventBus().deliver();
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
      Test.getEventBus().deliver();
      Test.stopTest();

      System.assertEquals('Cancelled', statusOf(child.Id), 'Child reaped');
      System.assertEquals(
        'Cancelled',
        statusOf(grandchild.Id),
        'Grandchild reaped'
      );
    }
  }

  @IsTest
  static void childlessFailurePublishesNoEvent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c parent = insertInstance(null, 'Running');

      Test.startTest();
      setStatus(parent.Id, 'Failed');
      Test.stopTest();

      System.assertEquals(
        0,
        WorkflowCascadeCancel.publishedEvents.size(),
        'A parent with no active child must not spend a platform event'
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
      Test.getEventBus().deliver();
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

  @IsTest
  static void compensationFailedChildResumesRollback() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Compensating');
      giveCompensationStack(child);
      insert new Workflow_Step_Execution__c(
        Workflow_Instance__c = child.Id,
        Step_Name__c = 'StepA_Compensate',
        Status__c = 'Failed',
        Retry_Count__c = 0
      );
      setStatus(child.Id, 'CompensationFailed');

      Test.startTest();
      WorkflowCascadeCancel.publishedEvents.clear();
      setStatus(parent.Id, 'Failed');
      Test.getEventBus().deliver();
      Test.stopTest();

      System.assertEquals(
        'Cancelling',
        statusOf(child.Id),
        'A stalled child rollback resumes under the cancel phase'
      );
      System.assertEquals(
        2,
        compensateLogCount(child.Id),
        'A fresh undo attempt is appended; the failed one stays'
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
      Test.getEventBus().deliver();
      Test.stopTest();

      for (Workflow_Instance__c after : [
        SELECT Status__c, Error_Message__c
        FROM Workflow_Instance__c
        WHERE Id IN :children
      ]) {
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
      Test.getEventBus().deliver();
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
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Running');
      setStatus(parent.Id, 'Failed');

      Test.startTest();
      WorkflowCascadeCancel.throwTestException = true;
      WorkflowCascadeCancel.publishedEvents.clear();
      WorkflowCascadeCancel.handleEvents(
        new List<Workflow_Event__e>{
          WorkflowCascadeCancel.buildParentEvent(parent.Id)
        }
      );

      System.assertEquals('Failed', statusOf(parent.Id), 'Parent unchanged');
      System.assertEquals('Running', statusOf(child.Id), 'Pass rolled back');
      System.assertEquals(
        1,
        WorkflowCascadeCancel.publishedEvents.size(),
        'A failed pass must republish one retry event'
      );
      System.assert(
        WorkflowCascadeCancel.publishedEvents[0]
          .Payload__c.contains('"attempt":2'),
        'The retry carries the next attempt number'
      );

      // The retry succeeds when the fault is gone.
      WorkflowCascadeCancel.throwTestException = false;
      Test.stopTest();

      System.assertEquals('Cancelled', statusOf(child.Id), 'Retry reaps');
    }
  }

  @IsTest
  static void cascadeStopsRetryAfterMaxAttempts() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      insertInstance(parent.Id, 'Running');
      setStatus(parent.Id, 'Failed');
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

      System.assertEquals(
        0,
        WorkflowCascadeCancel.publishedEvents.size(),
        'The last attempt must not republish'
      );
      WorkflowCascadeCancel.throwTestException = false;
      Test.stopTest();
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
      Test.getEventBus().deliver();
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
      Test.getEventBus().deliver();
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
        WorkflowEngine.cascadeCancelChildrenOnFailure,
        'The cascade is on by default'
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

  @IsTest
  static void cascadeCostIsConstantInTreeWidth() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id warmUp = buildFailedTree(1);
      Id narrow = buildFailedTree(2);
      Id wide = buildFailedTree(12);

      Test.startTest();
      // The first pass loads caches; do not measure it.
      measureReap(warmUp);
      Integer[] narrowCost = measureReap(narrow);
      Integer[] wideCost = measureReap(wide);
      Test.stopTest();

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

  @IsTest
  static void overCapTreeContinuesInNextEvent() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      insertChildren(new List<Workflow_Instance__c>{ parent }, 5, 'Running');

      Test.startTest();
      WorkflowCascadeCancel.maxNodesPerPass = 2;
      setStatus(parent.Id, 'Failed');
      // Pass 1 reaps 2 nodes and publishes a continuation.
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
      // Passes 2 and 3 reap the rest.
      Test.getEventBus().deliver();
      Test.getEventBus().deliver();
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

  // ============================================================
  // AC8 — chain handoff and append-only log
  // ============================================================

  @IsTest
  static void reapedChildStopsThroughCancelPath() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Workflow_Instance__c parent = insertInstance(null, 'Running');
      Workflow_Instance__c child = insertInstance(parent.Id, 'Running');
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
      Test.getEventBus().deliver();
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
}
