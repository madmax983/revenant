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

  private static StepContext.Builder contextFor(Id instanceId) {
    return new StepContext.Builder()
      .instanceId(instanceId)
      .workflowName('GuardTestWorkflow')
      .stepName('StepA')
      .inputJson('{"a":1}')
      .previousStepOutput('{"p":1}')
      .attempt(1);
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
      StepContext context = contextFor(insertInstance().Id).build();
      Integer before = Limits.getQueries();
      Assert.isNull(WorkflowDeterminismGuard.captureInputs(context));
      Assert.areEqual(before, Limits.getQueries(), 'Off costs no SOQL');
    }
  }

  @IsTest
  static void captureInputsIsStableWhenOn() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      Id instId = insertInstance().Id;
      Integer before = Limits.getQueries();
      String first = WorkflowDeterminismGuard.captureInputs(
        contextFor(instId).build()
      );
      Assert.areEqual(before + 1, Limits.getQueries(), 'On costs one SOQL');
      Assert.areEqual(64, first.length());
      Assert.areEqual(
        first,
        WorkflowDeterminismGuard.captureInputs(contextFor(instId).build())
      );
    }
  }

  @IsTest
  static void captureInputsSeesEachInput() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      Id instId = insertInstance().Id;
      String base = WorkflowDeterminismGuard.captureInputs(
        contextFor(instId).build()
      );
      Assert.areNotEqual(
        base,
        WorkflowDeterminismGuard.captureInputs(
          contextFor(instId).attempt(2).build()
        ),
        'Attempt is an input'
      );
      Assert.areNotEqual(
        base,
        WorkflowDeterminismGuard.captureInputs(
          contextFor(instId).inputJson('{"a":2}').build()
        ),
        'Step input is an input'
      );
      Assert.areNotEqual(
        base,
        WorkflowDeterminismGuard.captureInputs(
          contextFor(instId).previousStepOutput('{"p":2}').build()
        ),
        'Previous output is an input'
      );
      Assert.areNotEqual(
        base,
        WorkflowDeterminismGuard.captureInputs(
          contextFor(instId).markTimeoutResume().build()
        ),
        'A timeout resume is an input'
      );
      Assert.areEqual(
        base,
        WorkflowDeterminismGuard.captureInputs(
          contextFor(instId)
            .capturedValuesJson('{"k":"v"}')
            .stepStateJson('{"s":1}')
            .build()
        ),
        'Captures and step state are not inputs'
      );
    }
  }

  @IsTest
  static void captureInputsSeesNewAndChangedSignals() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      Workflow_Instance__c inst = insertInstance();
      String none = WorkflowDeterminismGuard.captureInputs(
        contextFor(inst.Id).build()
      );
      Workflow_Signal__c sig = new Workflow_Signal__c(
        Workflow_Instance__c = inst.Id,
        Correlation_Key__c = inst.Correlation_Key__c,
        Signal_Name__c = 'Go',
        Status__c = 'Received'
      );
      insert sig;
      String received = WorkflowDeterminismGuard.captureInputs(
        contextFor(inst.Id).build()
      );
      Assert.areNotEqual(none, received, 'A new signal changes the inputs');

      sig.Status__c = 'Consumed';
      update sig;
      Assert.areNotEqual(
        received,
        WorkflowDeterminismGuard.captureInputs(contextFor(inst.Id).build()),
        'A signal status change changes the inputs'
      );
    }
  }

  // ============================================================
  // verify
  // ============================================================

  @IsTest
  static void verifyDoesNothingWithoutInputs() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepRunner.RunStepContext ctx = runContext(null);
      Assert.isNull(
        WorkflowDeterminismGuard.verify(null, ctx, StepResult.suspend())
      );
      Assert.isNull(ctx.stepExec.Decision_Record__c, 'Off writes no record');
    }
  }

  @IsTest
  static void verifyRecordsAFirstWait() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepRunner.RunStepContext ctx = runContext(null);
      Assert.isNull(
        WorkflowDeterminismGuard.verify('in1', ctx, StepResult.suspend())
      );
      WorkflowDecisionFingerprint.Record rec = WorkflowDecisionFingerprint.parseRecord(
        ctx.stepExec.Decision_Record__c
      );
      Assert.areEqual('in1', rec.inputs);
      Assert.areEqual('SUSPEND timeout=-', rec.decision);
    }
  }

  @IsTest
  static void verifyDoesNotRecordANonWait() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepRunner.RunStepContext ctx = runContext(null);
      Assert.isNull(
        WorkflowDeterminismGuard.verify('in1', ctx, StepResult.sleep(5))
      );
      Assert.isNull(ctx.stepExec.Decision_Record__c);
    }
  }

  @IsTest
  static void verifyPassesTheSameDecision() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      String record = recordOf('in1', StepResult.suspend());
      WorkflowStepRunner.RunStepContext ctx = runContext(record);
      Assert.isNull(
        WorkflowDeterminismGuard.verify('in1', ctx, StepResult.suspend())
      );
      Assert.areEqual(record, ctx.stepExec.Decision_Record__c);
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
      Assert.isNotNull(message);
      Assert.isTrue(
        message.startsWith(WorkflowDeterminismGuard.MESSAGE_PREFIX),
        message
      );
      Assert.isTrue(message.contains('SUSPEND timeout=-'), message);
      Assert.isTrue(
        message.contains('COMPLETE next=Other compensate=false'),
        message
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
        message.contains('COMPLETE next=- compensate=true'),
        'The message names the compensation push: ' + message
      );
    }
  }

  @IsTest
  static void verifyFlagsATransientResultOnSameInputs() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowStepRunner.RunStepContext ctx = runContext(
        recordOf('in1', StepResult.suspend())
      );
      Assert.isNotNull(
        WorkflowDeterminismGuard.verify('in1', ctx, StepResult.sleep(5)),
        'Same inputs must give the same decision'
      );
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
        )
      );
      WorkflowDecisionFingerprint.Record rec = WorkflowDecisionFingerprint.parseRecord(
        ctx.stepExec.Decision_Record__c
      );
      Assert.areEqual('in2', rec.inputs);
      Assert.isTrue(rec.decision.startsWith('WAIT_FOR_APPROVAL'));
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
          StepResult.retry(new RetryPolicy())
        )
      );
      Assert.isNull(ctx.stepExec.Decision_Record__c);
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
          StepResult.retry(new RetryPolicy())
        ),
        'A thrown error is not a decision'
      );
      Assert.areEqual(record, ctx.stepExec.Decision_Record__c);
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
        )
      );
    }
  }

  @IsTest
  static void failIfDivergentIgnoresACleanOutcome() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.StepOutcomeContext outcome = new WorkflowEngine.StepOutcomeContext();
      Integer before = Limits.getDmlStatements();
      Assert.isFalse(WorkflowDeterminismGuard.failIfDivergent(outcome));
      Assert.areEqual(before, Limits.getDmlStatements());
    }
  }
}
