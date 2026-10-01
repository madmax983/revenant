/**
 * @description Unit tests for WorkflowDeterminismGuard (issue #102). They test
 * the inputs digest and the verify decision table on an in-memory step row.
 */
@IsTest
private class WorkflowDeterminismGuardTest {
  /** @description Plain fixture step. */
  public class PlainStep implements WorkflowStep {
    /**
     * @description Completes.
     * @param ctx The step context.
     * @return A completed result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  /** @description Compensatable fixture step. */
  public class CompStep implements CompensatableStep {
    /**
     * @description Completes.
     * @param ctx The step context.
     * @return A completed result.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, null);
    }
    /**
     * @description Undoes nothing.
     * @param ctx The step context.
     * @return A completed result.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(null, null);
    }
  }

  private static Workflow_Instance__c insertInstance() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = 'GuardTestWorkflow',
      Status__c = 'Running',
      Correlation_Key__c = 'Guard-' + Crypto.getRandomInteger()
    );
    insert inst;
    return inst;
  }

  // A run context with a stored step input and no step state.
  private static WorkflowStepRunner.RunStepContext rowContext(Id instanceId) {
    WorkflowStepRunner.RunStepContext ctx = new WorkflowStepRunner.RunStepContext();
    ctx.instanceId = instanceId;
    ctx.stepInstance = new PlainStep();
    ctx.stepExec = new Workflow_Step_Execution__c(
      Step_Name__c = 'StepA',
      Input__c = '{"a":1}',
      Output__c = null
    );
    return ctx;
  }

  private static StepContext.Builder contextFor(Id instanceId) {
    return new StepContext.Builder()
      .instanceId(instanceId)
      .workflowName('GuardTestWorkflow')
      .stepName('StepA')
      .attempt(1);
  }

  private static String digestOf(
    WorkflowStepRunner.RunStepContext ctx,
    StepContext.Builder builder
  ) {
    return WorkflowDeterminismGuard.captureInputs(
      ctx,
      builder.build(),
      '{"p":1}'
    );
  }

  private static List<Workflow_Signal__c> insertSignals(
    Workflow_Instance__c inst,
    Integer count
  ) {
    List<Workflow_Signal__c> sigs = new List<Workflow_Signal__c>();
    for (Integer i = 0; i < count; i++) {
      sigs.add(
        new Workflow_Signal__c(
          Workflow_Instance__c = inst.Id,
          Correlation_Key__c = inst.Correlation_Key__c,
          Signal_Name__c = 'Go' + i,
          Payload__c = '{"i":' + i + '}',
          Status__c = 'Received'
        )
      );
    }
    insert sigs;
    return sigs;
  }

  private static WorkflowStepRunner.RunStepContext runContext(String record) {
    WorkflowStepRunner.RunStepContext ctx = new WorkflowStepRunner.RunStepContext();
    ctx.stepInstance = new PlainStep();
    ctx.stepExec = new Workflow_Step_Execution__c(
      Step_Name__c = 'StepA',
      Decision_Record__c = record
    );
    return ctx;
  }

  private static String recordOf(String inputs, StepResult result) {
    return WorkflowDecisionFingerprint.toRecordJson(
      inputs,
      WorkflowDecisionFingerprint.describe(result, false)
    );
  }

  // ============================================================
  // captureInputs
  // ============================================================

  @IsTest
  static void captureInputsIsFreeWhenOff() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = false;
      Id instId = insertInstance().Id;
      Integer before = Limits.getQueries();
      Assert.isNull(
        digestOf(rowContext(instId), contextFor(instId)),
        'Off gives no digest'
      );
      Assert.areEqual(before, Limits.getQueries(), 'Off costs no SOQL');
    }
  }

  @IsTest
  static void captureInputsIsStableWhenOn() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      Id instId = insertInstance().Id;
      Integer before = Limits.getQueries();
      String first = digestOf(rowContext(instId), contextFor(instId));
      Assert.areEqual(
        before + 2,
        Limits.getQueries(),
        'On costs two SOQL: live signals and child status'
      );
      Assert.areEqual(64, first.length(), 'SHA-256 hex digest');
      Assert.areEqual(
        first,
        digestOf(rowContext(instId), contextFor(instId)),
        'Equal inputs give an equal digest'
      );
    }
  }

  @IsTest
  static void captureInputsSeesEachInput() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      Id instId = insertInstance().Id;
      String base = digestOf(rowContext(instId), contextFor(instId));

      Assert.areNotEqual(
        base,
        digestOf(rowContext(instId), contextFor(instId).attempt(2)),
        'Attempt is an input'
      );
      Assert.areNotEqual(
        base,
        digestOf(rowContext(instId), contextFor(instId).markTimeoutResume()),
        'A timeout resume is an input'
      );

      WorkflowStepRunner.RunStepContext changedInput = rowContext(instId);
      changedInput.stepExec.Input__c = '{"a":2}';
      Assert.areNotEqual(
        base,
        digestOf(changedInput, contextFor(instId)),
        'Stored step input is an input'
      );

      WorkflowStepRunner.RunStepContext resumed = rowContext(instId);
      resumed.stepExec.Output__c = '{"status":200}';
      Assert.areNotEqual(
        base,
        digestOf(resumed, contextFor(instId)),
        'Stored step state is an input, for example a resume payload'
      );

      Assert.areNotEqual(
        base,
        WorkflowDeterminismGuard.captureInputs(
          rowContext(instId),
          contextFor(instId).build(),
          '{"p":2}'
        ),
        'Previous output is an input'
      );

      Assert.areEqual(
        base,
        digestOf(
          rowContext(instId),
          contextFor(instId).capturedValuesJson('{"k":"v"}')
        ),
        'Captures are not inputs'
      );
    }
  }

  @IsTest
  static void captureInputsSeesNewAndChangedSignals() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      Workflow_Instance__c inst = insertInstance();
      String none = digestOf(rowContext(inst.Id), contextFor(inst.Id));
      Workflow_Signal__c sig = new Workflow_Signal__c(
        Workflow_Instance__c = inst.Id,
        Correlation_Key__c = inst.Correlation_Key__c,
        Signal_Name__c = 'Go',
        Status__c = 'Received'
      );
      insert sig;
      String received = digestOf(rowContext(inst.Id), contextFor(inst.Id));
      Assert.areNotEqual(none, received, 'A new signal changes the inputs');

      sig.Status__c = 'Consumed';
      update sig;
      Assert.areNotEqual(
        received,
        digestOf(rowContext(inst.Id), contextFor(inst.Id)),
        'A consumed signal changes the inputs'
      );
    }
  }

  @IsTest
  static void captureInputsSeesChildStatus() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      Workflow_Instance__c parent = insertInstance();
      Workflow_Instance__c child = new Workflow_Instance__c(
        Workflow_Name__c = 'GuardTestChild',
        Status__c = 'Running',
        Correlation_Key__c = 'GuardChild-' + Crypto.getRandomInteger(),
        Parent_Instance__c = parent.Id
      );
      insert child;
      String running = digestOf(rowContext(parent.Id), contextFor(parent.Id));

      child.Status__c = 'Completed';
      update child;
      Assert.areNotEqual(
        running,
        digestOf(rowContext(parent.Id), contextFor(parent.Id)),
        'A child status change changes the inputs'
      );
    }
  }

  @IsTest
  static void captureInputsCountsManyChildrenByStatus() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      Workflow_Instance__c parent = insertInstance();
      List<Workflow_Instance__c> children = new List<Workflow_Instance__c>();
      for (Integer i = 0; i < 3; i++) {
        children.add(
          new Workflow_Instance__c(
            Workflow_Name__c = 'GuardTestChild',
            Status__c = 'Running',
            Correlation_Key__c = 'GuardMany-' +
              i +
              '-' +
              Crypto.getRandomInteger(),
            Parent_Instance__c = parent.Id
          )
        );
      }
      insert children;
      String before = digestOf(rowContext(parent.Id), contextFor(parent.Id));
      Assert.areNotEqual(
        WorkflowDeterminismGuard.UNKNOWN_INPUTS,
        before,
        'Children have no cap'
      );

      children[0].Status__c = 'Completed';
      update children[0];
      Assert.areNotEqual(
        before,
        digestOf(rowContext(parent.Id), contextFor(parent.Id)),
        'A status count change changes the inputs'
      );
      Assert.areEqual(
        2,
        [
          SELECT COUNT()
          FROM Workflow_Instance__c
          WHERE Parent_Instance__c = :parent.Id AND Status__c = 'Running'
        ],
        'The fixture has two Running children and one Completed child'
      );
    }
  }

  @IsTest
  static void captureInputsIgnoresTheClaimsOfThisRun() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      Workflow_Instance__c inst = insertInstance();
      insert new Workflow_Signal__c(
        Workflow_Instance__c = inst.Id,
        Correlation_Key__c = inst.Correlation_Key__c,
        Signal_Name__c = 'Go',
        Status__c = 'Received'
      );
      StepContext context = contextFor(inst.Id)
        .signalSource(
          new WorkflowSignalSources.ParallelBranchSignalSource(inst.Id)
        )
        .build();
      WorkflowStepRunner.RunStepContext ctx = rowContext(inst.Id);
      String before = WorkflowDeterminismGuard.captureInputs(
        ctx,
        context,
        '{"p":1}'
      );

      // A parallel branch claims the signal it reads.
      Assert.isTrue(
        context.signals().getSignal('Go').isPresent(),
        'The branch reads the signal'
      );
      Assert.areEqual(
        'Processing',
        [
          SELECT Status__c
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :inst.Id
        ]
        .Status__c,
        'The read claims the signal'
      );

      Assert.areEqual(
        before,
        WorkflowDeterminismGuard.captureInputs(ctx, context, '{"p":1}'),
        'The claims of this run do not change the inputs'
      );
    }
  }

  @IsTest
  static void captureInputsTellsNullFromTheTextNull() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      Id instId = insertInstance().Id;
      WorkflowStepRunner.RunStepContext textNull = rowContext(instId);
      textNull.stepExec.Output__c = 'null';
      Assert.areNotEqual(
        digestOf(rowContext(instId), contextFor(instId)),
        digestOf(textNull, contextFor(instId)),
        'A null state and the text "null" are different inputs'
      );
    }
  }

  @IsTest
  static void captureInputsKnowsTheBacklogOverTheSignalCap() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      WorkflowDeterminismGuard.maxLiveSignals = 1;
      Workflow_Instance__c inst = insertInstance();
      insertSignals(inst, 2);
      String before = digestOf(rowContext(inst.Id), contextFor(inst.Id));
      Assert.areNotEqual(
        WorkflowDeterminismGuard.UNKNOWN_INPUTS,
        before,
        'A backlog over the cap still gives a digest'
      );

      insertSignals(inst, 1);
      Assert.areNotEqual(
        before,
        digestOf(rowContext(inst.Id), contextFor(inst.Id)),
        'An arrival over the cap changes the inputs'
      );
    }
  }

  @IsTest
  static void captureInputsChangesOnALiveSignalNameEdit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      Workflow_Instance__c inst = insertInstance();
      Workflow_Signal__c sig = insertSignals(inst, 1)[0];
      String before = digestOf(rowContext(inst.Id), contextFor(inst.Id));

      sig.Signal_Name__c = 'Renamed';
      update sig;
      Assert.areNotEqual(
        before,
        digestOf(rowContext(inst.Id), contextFor(inst.Id)),
        'A name edit is a new input'
      );
    }
  }

  @IsTest
  static void captureInputsChangesOnALiveSignalPayloadEdit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      Workflow_Instance__c inst = insertInstance();
      Workflow_Signal__c sig = insertSignals(inst, 1)[0];
      String before = digestOf(rowContext(inst.Id), contextFor(inst.Id));

      sig.Payload__c = '{"route":"B"}';
      update sig;
      Assert.areNotEqual(
        before,
        digestOf(rowContext(inst.Id), contextFor(inst.Id)),
        'A payload edit is a new input'
      );
    }
  }

  @IsTest
  static void captureInputsChangesOnAClaimedSignalPayloadEdit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      Workflow_Instance__c inst = insertInstance();
      Workflow_Signal__c sig = insertSignals(inst, 1)[0];
      StepContext context = contextFor(inst.Id)
        .signalSource(
          new WorkflowSignalSources.ParallelBranchSignalSource(inst.Id)
        )
        .build();
      WorkflowStepRunner.RunStepContext ctx = rowContext(inst.Id);
      String before = WorkflowDeterminismGuard.captureInputs(
        ctx,
        context,
        '{"p":1}'
      );
      Assert.isTrue(
        context.signals().getSignal('Go0').isPresent(),
        'The branch claims the signal'
      );

      sig.Payload__c = '{"route":"B"}';
      update sig;
      Assert.areNotEqual(
        before,
        WorkflowDeterminismGuard.captureInputs(ctx, context, '{"p":1}'),
        'A payload edit of a claimed signal is a new input'
      );
    }
  }

  @IsTest
  static void captureInputsTellsNullFromTheTextNullInASignal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      Workflow_Instance__c inst = insertInstance();
      Workflow_Signal__c sig = insertSignals(inst, 1)[0];
      sig.Payload__c = null;
      update sig;
      String nullPayload = digestOf(rowContext(inst.Id), contextFor(inst.Id));

      sig.Payload__c = 'null';
      update sig;
      Assert.areNotEqual(
        nullPayload,
        digestOf(rowContext(inst.Id), contextFor(inst.Id)),
        'A null payload and the text "null" are different inputs'
      );
    }
  }

  @IsTest
  static void captureInputsChangesOnAForeignClaim() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      Workflow_Instance__c inst = insertInstance();
      Workflow_Signal__c sig = insertSignals(inst, 1)[0];
      String before = digestOf(rowContext(inst.Id), contextFor(inst.Id));

      sig.Status__c = 'Processing';
      update sig;
      Assert.areNotEqual(
        before,
        digestOf(rowContext(inst.Id), contextFor(inst.Id)),
        'A claim by another branch is a new input'
      );
    }
  }

  // ============================================================
  // verify
  // ============================================================

  @IsTest
  static void verifyClearsTheRecordWhenOff() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepRunner.RunStepContext ctx = runContext(
        recordOf('in1', StepResult.suspend())
      );
      Assert.isNull(
        WorkflowDeterminismGuard.verify(null, ctx, StepResult.suspend()),
        'Off never reports a divergence'
      );
      Assert.isNull(
        ctx.stepExec.Decision_Record__c,
        'Off removes an old record'
      );
    }
  }

  @IsTest
  static void verifyRecordsAFirstWait() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepRunner.RunStepContext ctx = runContext(null);
      Assert.isNull(
        WorkflowDeterminismGuard.verify('in1', ctx, StepResult.suspend()),
        'A first wait is not a divergence'
      );
      WorkflowDecisionFingerprint.Record rec = WorkflowDecisionFingerprint.parseRecord(
        ctx.stepExec.Decision_Record__c
      );
      Assert.areEqual('in1', rec.inputs, 'The record keeps the inputs');
      Assert.areEqual(
        'SUSPEND timeout=null',
        rec.decision,
        'The record keeps the decision'
      );
    }
  }

  @IsTest
  static void verifyDoesNotRecordACompletion() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepRunner.RunStepContext ctx = runContext(null);
      Assert.isNull(
        WorkflowDeterminismGuard.verify(
          'in1',
          ctx,
          StepResult.complete('Next', null)
        ),
        'A completion without a record passes'
      );
      Assert.isNull(ctx.stepExec.Decision_Record__c, 'Only a wait is recorded');
    }
  }

  @IsTest
  static void verifyPassesTheSameDecision() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String record = recordOf('in1', StepResult.suspend());
      WorkflowStepRunner.RunStepContext ctx = runContext(record);
      Assert.isNull(
        WorkflowDeterminismGuard.verify('in1', ctx, StepResult.suspend()),
        'The same decision passes'
      );
      Assert.areEqual(
        record,
        ctx.stepExec.Decision_Record__c,
        'The record does not change'
      );
    }
  }

  @IsTest
  static void verifyFlagsADifferentDecision() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepRunner.RunStepContext ctx = runContext(
        recordOf('in1', StepResult.suspend())
      );
      String message = WorkflowDeterminismGuard.verify(
        'in1',
        ctx,
        StepResult.complete('Other', null)
      );
      Assert.isNotNull(message, 'A different decision is a divergence');
      Assert.isTrue(
        message.startsWith(WorkflowDeterminismGuard.MESSAGE_PREFIX),
        'The message starts with the prefix: ' + message
      );
      Assert.isTrue(
        message.contains('Recorded: SUSPEND timeout=null'),
        'The message shows the recorded decision: ' + message
      );
      Assert.isTrue(
        message.contains('New: COMPLETE next="Other" compensate=false'),
        'The message shows the new decision: ' + message
      );
    }
  }

  @IsTest
  static void verifyNamesTheCompensationPush() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepRunner.RunStepContext ctx = runContext(
        recordOf('in1', StepResult.suspend())
      );
      ctx.stepInstance = new CompStep();
      String message = WorkflowDeterminismGuard.verify(
        'in1',
        ctx,
        StepResult.complete(null, null)
      );
      Assert.isTrue(
        message.contains('COMPLETE next=null compensate=true'),
        'The message names the compensation push: ' + message
      );
    }
  }

  @IsTest
  static void verifyIgnoresATransientResult() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String record = recordOf('in1', StepResult.suspend());
      List<StepResult> transients = new List<StepResult>{
        StepResult.retry(new RetryPolicy()),
        StepResult.sleep(5),
        StepResult.yield('{}')
      };
      for (StepResult result : transients) {
        WorkflowStepRunner.RunStepContext ctx = runContext(record);
        Assert.isNull(
          WorkflowDeterminismGuard.verify('in1', ctx, result),
          'A transient result is not a decision: ' + result.directive().action
        );
        Assert.areEqual(
          record,
          ctx.stepExec.Decision_Record__c,
          'A transient result keeps the record: ' + result.directive().action
        );
      }
    }
  }

  @IsTest
  static void verifyReplacesTheRecordOnNewInputs() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepRunner.RunStepContext ctx = runContext(
        recordOf('in1', StepResult.suspend())
      );
      Assert.isNull(
        WorkflowDeterminismGuard.verify(
          'in2',
          ctx,
          StepResult.waitForApproval('K', null)
        ),
        'New inputs allow a new decision'
      );
      WorkflowDecisionFingerprint.Record rec = WorkflowDecisionFingerprint.parseRecord(
        ctx.stepExec.Decision_Record__c
      );
      Assert.areEqual('in2', rec.inputs, 'The record has the new inputs');
      Assert.isTrue(
        rec.decision.startsWith('WAIT_FOR_APPROVAL'),
        'The record has the new wait: ' + rec.decision
      );
    }
  }

  @IsTest
  static void verifyClearsTheRecordOnNewInputsAndNoWait() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepRunner.RunStepContext ctx = runContext(
        recordOf('in1', StepResult.suspend())
      );
      Assert.isNull(
        WorkflowDeterminismGuard.verify(
          'in2',
          ctx,
          StepResult.complete('Next', null)
        ),
        'New inputs allow a completion'
      );
      Assert.isNull(
        ctx.stepExec.Decision_Record__c,
        'A completion clears the record'
      );
    }
  }

  @IsTest
  static void verifyKeepsTheRecordOnUnknownInputs() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String record = recordOf('in1', StepResult.suspend());
      WorkflowStepRunner.RunStepContext ctx = runContext(record);
      Assert.isNull(
        WorkflowDeterminismGuard.verify(
          WorkflowDeterminismGuard.UNKNOWN_INPUTS,
          ctx,
          StepResult.complete('Other', null)
        ),
        'Unknown inputs give no compare'
      );
      Assert.areEqual(
        record,
        ctx.stepExec.Decision_Record__c,
        'Unknown inputs keep the record'
      );
    }
  }

  @IsTest
  static void verifySkipsAThrownError() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String record = recordOf('in1', StepResult.suspend());
      WorkflowStepRunner.RunStepContext ctx = runContext(record);
      ctx.thrownError = new WorkflowEngine.WorkflowException('boom');
      Assert.isNull(
        WorkflowDeterminismGuard.verify(
          'in1',
          ctx,
          StepResult.complete('Other', null)
        ),
        'A thrown error is not a decision'
      );
      Assert.areEqual(
        record,
        ctx.stepExec.Decision_Record__c,
        'A thrown error keeps the record'
      );
    }
  }

  @IsTest
  static void verifyTreatsAnUnreadableRecordAsNone() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepRunner.RunStepContext ctx = runContext('garbage');
      Assert.isNull(
        WorkflowDeterminismGuard.verify(
          'in1',
          ctx,
          StepResult.complete('Other', null)
        ),
        'An unreadable record is no record'
      );
    }
  }

  @IsTest
  static void clearRecordsClearsOnlyOpenCurrentRows() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instId = insertInstance().Id;
      String record = recordOf('in1', StepResult.suspend());
      List<Workflow_Step_Execution__c> execs = new List<Workflow_Step_Execution__c>{
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = instId,
          Step_Name__c = 'StepA',
          Status__c = 'Pending',
          Decision_Record__c = record
        ),
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = instId,
          Step_Name__c = 'StepB',
          Status__c = 'Running',
          Decision_Record__c = record
        ),
        new Workflow_Step_Execution__c(
          Workflow_Instance__c = instId,
          Step_Name__c = 'StepA',
          Status__c = 'Completed',
          Decision_Record__c = record
        )
      };
      insert execs;

      WorkflowDeterminismGuard.clearRecords(instId, 'StepA, StepB');

      Map<Id, Workflow_Step_Execution__c> after = new Map<Id, Workflow_Step_Execution__c>(
        [
          SELECT Decision_Record__c
          FROM Workflow_Step_Execution__c
          WHERE Workflow_Instance__c = :instId
        ]
      );
      Assert.isNull(
        after.get(execs[0].Id).Decision_Record__c,
        'An open row of a current step is cleared'
      );
      Assert.isNull(
        after.get(execs[1].Id).Decision_Record__c,
        'An open parallel branch row is cleared'
      );
      Assert.areEqual(
        record,
        after.get(execs[2].Id).Decision_Record__c,
        'A closed row keeps its record'
      );
    }
  }

  @IsTest
  static void failIfDivergentIgnoresACleanOutcome() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.StepOutcomeContext outcome = new WorkflowEngine.StepOutcomeContext();
      Integer before = Limits.getDmlStatements();
      Assert.isFalse(
        WorkflowDeterminismGuard.failIfDivergent(outcome),
        'No divergence, no failure'
      );
      Assert.areEqual(
        before,
        Limits.getDmlStatements(),
        'No divergence costs no DML'
      );
    }
  }
}
