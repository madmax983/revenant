/**
 * @description End-to-end tests for cooperative cancellation (issue #143). A
 * loop step acts as the operator at a set item: it cancels an instance in the
 * same transaction. Apex tests are single-threaded, so this is how a test puts
 * a cancel in the middle of `execute()`.
 */
// Public: WorkflowEngine.start authorizes a definition through
// ApexTypeImplementor, which does not list inner classes of a private class.
@IsTest
public class WorkflowCooperativeCancelTest {
  private static final String LOOP_WORKFLOW = 'WorkflowCooperativeCancelTest.LoopWorkflow';
  private static final String SAGA_WORKFLOW = 'WorkflowCooperativeCancelTest.SagaLoopWorkflow';
  private static final String LOOP_STEP = 'WorkflowCooperativeCancelTest.LoopStep';
  private static final String TIMED_WORKFLOW = 'WorkflowCooperativeCancelTest.TimedLoopWorkflow';
  private static final String TIMED_STEP = 'WorkflowCooperativeCancelTest.TimedLoopStep';
  private static final String COMP_STEP = 'WorkflowCooperativeCancelTest.ReserveStep';

  // Operator actions that the loop step can do at item `actAtItem`.
  private static final String CANCEL = 'CANCEL';
  private static final String CANCEL_WITH_COMPENSATION = 'CANCEL_WITH_COMPENSATION';
  private static final String MARK_CANCELLED = 'MARK_CANCELLED';
  private static final String MARK_CANCELLING = 'MARK_CANCELLING';

  // Loop configuration. Each test sets these values.
  private static Integer totalItems = 100;
  private static Integer checkEvery = 10;
  private static Integer actAtItem = 23;
  private static String action = CANCEL;
  private static Id actionTargetId;
  private static Boolean cooperative = true;
  private static Boolean useDefaultMaxAge = false;
  // Optional: the status that the operator action also writes on this instance.
  private static Id selfId;
  private static String selfStatusAtAction;
  // Optional: after the step sees true, set the parent back to Suspended.
  private static Boolean revertParentAfterSeen = false;

  // Loop results.
  private static Integer processed = 0;
  private static Integer processedAfterAction = 0;
  private static Boolean compensateSawCancel;
  private static Integer keySequence = 0;

  /**
   * @description Workflow with one loop step.
   */
  public class LoopWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the steps.
     * @return The loop step.
     */
    public List<String> getSteps() {
      return new List<String>{ LOOP_STEP };
    }
    /**
     * @description Gives the first step.
     * @return The loop step.
     */
    public String getInitialStep() {
      return LOOP_STEP;
    }
    /**
     * @description Ends after the loop step.
     * @param currentStepName The step that completed.
     * @param result Its result.
     * @return Null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  /**
   * @description Saga: a compensatable step, then the loop step.
   */
  public class SagaLoopWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the steps.
     * @return The reserve step and the loop step.
     */
    public List<String> getSteps() {
      return new List<String>{ COMP_STEP, LOOP_STEP };
    }
    /**
     * @description Gives the first step.
     * @return The reserve step.
     */
    public String getInitialStep() {
      return COMP_STEP;
    }
    /**
     * @description Runs the loop step after the reserve step.
     * @param currentStepName The step that completed.
     * @param result Its result.
     * @return The next step, or null at the end.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return currentStepName == COMP_STEP ? LOOP_STEP : null;
    }
  }

  /**
   * @description Workflow with one loop step that has a timeout.
   */
  public class TimedLoopWorkflow implements WorkflowDefinition {
    /**
     * @description Lists the steps.
     * @return The timed loop step.
     */
    public List<String> getSteps() {
      return new List<String>{ TIMED_STEP };
    }
    /**
     * @description Gives the first step.
     * @return The timed loop step.
     */
    public String getInitialStep() {
      return TIMED_STEP;
    }
    /**
     * @description Ends after the loop step.
     * @param currentStepName The step that completed.
     * @param result Its result.
     * @return Null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  /**
   * @description Compensatable step. Its rollback records the cancel flag.
   */
  public class ReserveStep implements CompensatableStep {
    /**
     * @description Completes.
     * @param ctx The step context.
     * @return COMPLETE.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'reserved');
    }
    /**
     * @description Records the cancel flag that a rollback sees.
     * @param ctx The compensation context.
     * @return COMPLETE.
     */
    public StepResult compensate(StepContext ctx) {
      compensateSawCancel = ctx.isCancellationRequested(0);
      return StepResult.complete(null, 'released');
    }
  }

  /**
   * @description Loop step. It does the operator action at `actAtItem`. When
   * `cooperative` is true, it checks the flag every `checkEvery` items.
   */
  public virtual class LoopStep implements WorkflowStep {
    /**
     * @description Runs the loop.
     * @param ctx The step context.
     * @return YIELD after a cancel, else COMPLETE.
     */
    public StepResult execute(StepContext ctx) {
      for (Integer item = 1; item <= totalItems; item++) {
        if (item == actAtItem) {
          act();
        }
        processed++;
        if (item >= actAtItem) {
          processedAfterAction++;
        }
        if (
          cooperative &&
          Math.mod(item, checkEvery) == 0 &&
          isCancelled(ctx)
        ) {
          if (revertParentAfterSeen) {
            update new Workflow_Instance__c(
              Id = actionTargetId,
              Status__c = 'Suspended'
            );
          }
          return StepResult.yield(JSON.serialize(item));
        }
      }
      return StepResult.complete(null, processed);
    }

    private Boolean isCancelled(StepContext ctx) {
      return useDefaultMaxAge
        ? ctx.isCancellationRequested()
        : ctx.isCancellationRequested(0);
    }
  }

  /**
   * @description Loop step with a timeout. Its `finally` block saves the step
   * row before the seam runs.
   */
  public class TimedLoopStep extends LoopStep implements TimeoutConfigurable {
    /**
     * @description Gives the step timeout.
     * @return 300 seconds.
     */
    public Integer getTimeoutSeconds() {
      return 300;
    }
  }

  private static void act() {
    if (selfStatusAtAction != null) {
      update new Workflow_Instance__c(
        Id = selfId,
        Status__c = selfStatusAtAction
      );
    }
    if (action == CANCEL) {
      WorkflowEngine.cancel(actionTargetId);
    } else if (action == CANCEL_WITH_COMPENSATION) {
      WorkflowEngine.cancel(actionTargetId, true);
    } else if (action == MARK_CANCELLED) {
      update new Workflow_Instance__c(
        Id = actionTargetId,
        Status__c = 'Cancelled'
      );
    } else if (action == MARK_CANCELLING) {
      update new Workflow_Instance__c(
        Id = actionTargetId,
        Status__c = 'Cancelling'
      );
    }
  }

  private static Id start(String workflowName) {
    keySequence++;
    return WorkflowEngine.start(workflowName, 'Coop_' + keySequence, null);
  }

  private static Id startChild(String workflowName, Id parentId) {
    keySequence++;
    return WorkflowEngine.start(
      new WorkflowEngine.StartRequest(
          workflowName,
          'CoopChild_' + keySequence,
          null
        )
        .withParent(parentId)
    );
  }

  private static Id insertParent() {
    keySequence++;
    Workflow_Instance__c parent = new Workflow_Instance__c(
      Workflow_Name__c = LOOP_WORKFLOW,
      Status__c = 'Suspended',
      Current_Step__c = LOOP_STEP,
      Correlation_Key__c = 'CoopParent_' + keySequence
    );
    insert parent;
    return parent.Id;
  }

  private static String statusOf(Id instanceId) {
    return [SELECT Status__c FROM Workflow_Instance__c WHERE Id = :instanceId]
    .Status__c;
  }

  private static List<Workflow_Step_Execution__c> stepRows(
    Id instanceId,
    String stepName
  ) {
    return [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :instanceId AND Step_Name__c = :stepName
      ORDER BY CreatedDate ASC, Id ASC
    ];
  }

  // Drives the rollback hops until the instance is terminal (max 5 hops).
  private static void driveToTerminal(Id instanceId) {
    for (Integer hop = 0; hop < 5; hop++) {
      if (WorkflowCancellation.isTerminalForCancel(statusOf(instanceId))) {
        return;
      }
      WorkflowEngine.runStep(instanceId, null);
    }
  }

  private static void assertLoopStepAbandoned(Id instanceId) {
    List<Workflow_Step_Execution__c> rows = stepRows(instanceId, LOOP_STEP);
    Assert.areEqual(1, rows.size(), 'One row for the loop step');
    Assert.areEqual('Cancelled', rows[0].Status__c);
    Assert.isNull(
      rows[0].Output__c,
      'The engine dropped the YIELD: no step state was saved'
    );
  }

  private static void assertStoppedWithinOneCheck() {
    Assert.isTrue(
      processedAfterAction <= checkEvery,
      'At most one check interval after the cancel, got ' + processedAfterAction
    );
    Assert.isTrue(processed < totalItems, 'The loop stopped early');
  }

  @IsTest
  static void cooperativeLoopStopsWithinOneCheck() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = start(LOOP_WORKFLOW);
      actionTargetId = instanceId;

      WorkflowEngine.runStep(instanceId, null);

      Assert.areEqual(30, processed, 'Stops at the first check after item 23');
      assertStoppedWithinOneCheck();
      Assert.areEqual('Cancelled', statusOf(instanceId));
      assertLoopStepAbandoned(instanceId);
      Workflow_Instance__c inst = [
        SELECT Current_Step__c, Output__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      Assert.areEqual(LOOP_STEP, inst.Current_Step__c, 'No transition');
      Assert.isNull(inst.Output__c, 'No completion output');
    }
  }

  @IsTest
  static void cooperativeLoopRunsCompensations() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = start(SAGA_WORKFLOW);
      actionTargetId = instanceId;
      action = CANCEL_WITH_COMPENSATION;

      WorkflowEngine.runStep(instanceId, null); // ReserveStep completes
      WorkflowEngine.runStep(instanceId, null); // LoopStep sees the cancel

      assertStoppedWithinOneCheck();
      Assert.areEqual('Cancelling', statusOf(instanceId));
      assertLoopStepAbandoned(instanceId);

      driveToTerminal(instanceId);

      Assert.areEqual('Cancelled', statusOf(instanceId));
      List<Workflow_Step_Execution__c> comp = stepRows(
        instanceId,
        COMP_STEP + '_Compensate'
      );
      Assert.isFalse(comp.isEmpty(), 'The rollback ran');
      Assert.areEqual('Compensated', comp[comp.size() - 1].Status__c);
      Assert.isFalse(
        compensateSawCancel,
        'A compensation context never reports a cancel'
      );
      assertLoopStepAbandoned(instanceId);
    }
  }

  @IsTest
  static void defaultAccessorSeesEarlierCancel() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = start(LOOP_WORKFLOW);
      actionTargetId = instanceId;
      actAtItem = 1;
      useDefaultMaxAge = true;

      WorkflowEngine.runStep(instanceId, null);

      Assert.areEqual(checkEvery, processed);
      Assert.areEqual('Cancelled', statusOf(instanceId));
      assertLoopStepAbandoned(instanceId);
    }
  }

  @IsTest
  static void nonCooperativeStepKeepsOldBehavior() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = start(LOOP_WORKFLOW);
      actionTargetId = instanceId;
      cooperative = false;

      Exception thrown;
      try {
        WorkflowEngine.runStep(instanceId, null);
      } catch (WorkflowEngine.WorkflowException ex) {
        thrown = ex;
      }

      Assert.areEqual(totalItems, processed, 'The loop ran to the end');
      Assert.isNotNull(thrown, 'The seam still rejects the late result');
      Assert.isTrue(thrown.getMessage().contains('cancelled'));
    }
  }

  @IsTest
  static void parentCancelCascadesToRunningChild() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id parentId = insertParent();
      Id childId = startChild(LOOP_WORKFLOW, parentId);
      actionTargetId = parentId;

      WorkflowEngine.runStep(childId, null);

      assertStoppedWithinOneCheck();
      Assert.areEqual('Cancelled', statusOf(parentId));
      Assert.areEqual('Cancelled', statusOf(childId));
      assertLoopStepAbandoned(childId);
    }
  }

  @IsTest
  static void cancelledAncestorCancelsInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id parentId = insertParent();
      Id childId = startChild(LOOP_WORKFLOW, parentId);
      actionTargetId = parentId;
      action = MARK_CANCELLED;

      WorkflowEngine.runStep(childId, null);

      assertStoppedWithinOneCheck();
      Assert.areEqual(
        'Cancelled',
        statusOf(childId),
        'The seam cancels an instance whose ancestor is cancelled'
      );
      assertLoopStepAbandoned(childId);
    }
  }

  @IsTest
  static void cancellingAncestorRollsBackInstance() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id parentId = insertParent();
      Id childId = startChild(SAGA_WORKFLOW, parentId);
      actionTargetId = parentId;
      action = MARK_CANCELLING;

      WorkflowEngine.runStep(childId, null); // ReserveStep completes
      WorkflowEngine.runStep(childId, null); // LoopStep sees the parent

      assertStoppedWithinOneCheck();
      Assert.areEqual('Cancelling', statusOf(childId));
      assertLoopStepAbandoned(childId);

      driveToTerminal(childId);

      Assert.areEqual('Cancelled', statusOf(childId));
      List<Workflow_Step_Execution__c> comp = stepRows(
        childId,
        COMP_STEP + '_Compensate'
      );
      Assert.isFalse(comp.isEmpty(), 'The rollback ran');
    }
  }

  @IsTest
  static void cooperativeStepWithNoCancelCompletes() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = start(LOOP_WORKFLOW);
      action = 'NONE';

      WorkflowEngine.runStep(instanceId, null);

      Assert.areEqual(totalItems, processed);
      Assert.areEqual('Completed', statusOf(instanceId));
      List<Workflow_Step_Execution__c> rows = stepRows(instanceId, LOOP_STEP);
      Assert.areEqual('Completed', rows[0].Status__c);
    }
  }

  @IsTest
  static void timedStepEndsCancelled() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = start(TIMED_WORKFLOW);
      actionTargetId = instanceId;

      WorkflowEngine.runStep(instanceId, null);

      assertStoppedWithinOneCheck();
      Assert.areEqual('Cancelled', statusOf(instanceId));
      List<Workflow_Step_Execution__c> rows = stepRows(instanceId, TIMED_STEP);
      Assert.areEqual(1, rows.size());
      Assert.areEqual(
        'Cancelled',
        rows[0].Status__c,
        'The seam writes Cancelled after the timeout save'
      );
    }
  }

  @IsTest
  static void nonRunnableInstanceKeepsOldPath() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id parentId = insertParent();
      Id childId = startChild(LOOP_WORKFLOW, parentId);
      actionTargetId = parentId;
      action = MARK_CANCELLED;
      selfId = childId;
      selfStatusAtAction = 'Compensating';

      Exception thrown;
      try {
        WorkflowEngine.runStep(childId, null);
      } catch (WorkflowEngine.WorkflowException ex) {
        thrown = ex;
      }

      Assert.isNotNull(thrown, 'A Compensating instance keeps the old throw');
      Assert.areEqual(30, processed, 'The step saw the flag');
      Assert.areNotEqual(
        'Cancelled',
        stepRows(childId, LOOP_STEP)[0].Status__c,
        'The seam did not act'
      );
    }
  }

  @IsTest
  static void withdrawnAncestorCancelKeepsNormalPath() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id parentId = insertParent();
      Id childId = startChild(LOOP_WORKFLOW, parentId);
      actionTargetId = parentId;
      action = MARK_CANCELLING;
      revertParentAfterSeen = true;

      WorkflowEngine.runStep(childId, null);

      Assert.areEqual(30, processed, 'The step saw the flag');
      Assert.areEqual(
        'Running',
        statusOf(childId),
        'No cancel at the seam: the YIELD runs'
      );
      Assert.areEqual('Running', stepRows(childId, LOOP_STEP)[0].Status__c);
    }
  }

  @IsTest
  static void seamIgnoresAnOutcomeWithNoContext() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.StepOutcomeContext outcome = new WorkflowEngine.StepOutcomeContext();
      Assert.isFalse(
        WorkflowCooperativeCancel.stopIfCancelled(
          outcome,
          new Workflow_Instance__c(Status__c = 'Cancelled')
        )
      );
    }
  }

  @IsTest
  static void seamWithNoStepRowDoesNoDml() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.StepOutcomeContext outcome = observedOutcome();
      Integer dmlBefore = Limits.getDmlStatements();

      Assert.isTrue(
        WorkflowCooperativeCancel.stopIfCancelled(
          outcome,
          new Workflow_Instance__c(Status__c = 'Cancelled')
        )
      );
      Assert.areEqual(dmlBefore, Limits.getDmlStatements());
    }
  }

  @IsTest
  static void seamInsertsAnUnsavedStepRowAsCancelled() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id parentId = insertParent();
      WorkflowEngine.StepOutcomeContext outcome = observedOutcome();
      // A new CalloutStep row has no Id until after execute().
      outcome.stepExec = new Workflow_Step_Execution__c(
        Workflow_Instance__c = parentId,
        Step_Name__c = 'CalloutLoop',
        Status__c = 'Running'
      );

      Assert.isTrue(
        WorkflowCooperativeCancel.stopIfCancelled(
          outcome,
          new Workflow_Instance__c(Id = parentId, Status__c = 'Cancelling')
        )
      );
      List<Workflow_Step_Execution__c> rows = stepRows(parentId, 'CalloutLoop');
      Assert.areEqual(1, rows.size(), 'An audit row exists');
      Assert.areEqual('Cancelled', rows[0].Status__c);
    }
  }

  // An outcome whose context saw a cancel, with no step row.
  private static WorkflowEngine.StepOutcomeContext observedOutcome() {
    StepContext ctx = new StepContextTestBuilder()
      .requestCancellation()
      .build();
    Assert.isTrue(ctx.isCancellationRequested());
    WorkflowEngine.StepOutcomeContext outcome = new WorkflowEngine.StepOutcomeContext();
    outcome.context = ctx;
    return outcome;
  }
}
