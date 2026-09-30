/**
 * @description Tests for WorkflowBatchStep (issue #138). Unit tests use
 * StepContextTestBuilder and the WorkflowBatchJobs test seams. The last tests
 * drive a workflow through the harness and the watchdog heartbeat.
 */
@IsTest
private class WorkflowBatchStepTest {
  private static final Id JOB_ID = '707000000000001';
  private static final String STUB_BATCH = 'WorkflowBatchStepTest.StubBatch';
  private static final String BOUND_STEP = 'WorkflowBatchStepTest.BoundStep';
  private static final String WORKFLOW = 'WorkflowBatchStepTest.BatchWorkflow';

  /** @description A Batchable with no Revenant code. */
  public class StubBatch implements Database.Batchable<SObject> {
    public String tag;

    /**
     * @description Selects the accounts with the tag as name.
     * @param bc The batch context.
     * @return The query locator.
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
      return Database.getQueryLocator(
        [SELECT Id FROM Account WHERE Name = :tag WITH SYSTEM_MODE]
      );
    }

    /**
     * @description Does nothing.
     * @param bc The batch context.
     * @param scope The records of this chunk.
     */
    public void execute(Database.BatchableContext bc, List<SObject> scope) {
      return;
    }

    /**
     * @description Does nothing.
     * @param bc The batch context.
     */
    public void finish(Database.BatchableContext bc) {
      return;
    }
  }

  /** @description A class that is not a Batchable. */
  public class NotABatch {
    public String tag;
  }

  /** @description A subclass that gives the binding in Apex. */
  public class BoundStep extends WorkflowBatchStep {
    /**
     * @description Gives a fixed binding.
     * @param ctx The step context.
     * @return The binding.
     */
    protected override WorkflowBatchStep.Binding bind(StepContext ctx) {
      return new WorkflowBatchStep.Binding(
        STUB_BATCH,
        10,
        new Map<String, Object>{ 'tag' => 'bound' }
      );
    }
  }

  /** @description A one-step workflow that runs BoundStep. */
  public class BatchWorkflow implements WorkflowDefinition {
    /**
     * @description Returns the steps.
     * @return The step names.
     */
    public List<String> getSteps() {
      return new List<String>{ BOUND_STEP };
    }

    /**
     * @description Returns the first step.
     * @return The step name.
     */
    public String getInitialStep() {
      return BOUND_STEP;
    }

    /**
     * @description Ends after the batch step.
     * @param currentStepName The step that completed.
     * @param result The result.
     * @return Null.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      return null;
    }
  }

  // Builds an AsyncApexJob row in memory. Tests cannot insert this object.
  private static AsyncApexJob job(
    String status,
    Integer total,
    Integer processed,
    Integer errors,
    String extendedStatus
  ) {
    return (AsyncApexJob) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'attributes' => new Map<String, Object>{ 'type' => 'AsyncApexJob' },
          'Id' => JOB_ID,
          'Status' => status,
          'TotalJobItems' => total,
          'JobItemsProcessed' => processed,
          'NumberOfErrors' => errors,
          'ExtendedStatus' => extendedStatus
        }
      ),
      AsyncApexJob.class
    );
  }

  private static void stubJob(AsyncApexJob row) {
    WorkflowBatchJobs.stubJobs = new Map<Id, AsyncApexJob>{ JOB_ID => row };
  }

  private static Map<String, Object> input(Map<String, Object> extra) {
    Map<String, Object> m = new Map<String, Object>{
      'batchClass' => STUB_BATCH,
      'input' => new Map<String, Object>{ 'tag' => 't1' }
    };
    if (extra != null) {
      m.putAll(extra);
    }
    return m;
  }

  // Context for a run after the launch: the job Id is a capture.
  private static StepContext resumed(Map<String, Object> inputMap) {
    return new StepContextTestBuilder()
      .input(inputMap)
      .once(WorkflowBatchStep.KEY_JOB_ID, String.valueOf(JOB_ID))
      .build();
  }

  private static Map<String, Object> output(StepResult r) {
    return (Map<String, Object>) JSON.deserializeUntyped(
      r.directive().outputJson
    );
  }

  private static String errorFor(Object inputValue) {
    StepContextTestBuilder b = new StepContextTestBuilder();
    if (inputValue instanceof String) {
      b.inputJson((String) inputValue);
    } else {
      b.input(inputValue);
    }
    try {
      new WorkflowBatchStep().execute(b.build());
    } catch (WorkflowEngine.WorkflowException ex) {
      return ex.getMessage();
    }
    return null;
  }

  // ── Launch ────────────────────────────────────────────────────────────

  @IsTest
  static void testFirstRunLaunchesOnceAndSuspends() {
    WorkflowBatchJobs.stubLaunchId = JOB_ID;
    StepContext ctx = new StepContextTestBuilder()
      .input(input(new Map<String, Object>{ 'scopeSize' => 50 }))
      .build();

    StepResult r = new WorkflowBatchStep().execute(ctx);

    Assert.areEqual(StepResult.ActionType.SUSPEND, r.directive().action);
    Assert.areEqual(String.valueOf(JOB_ID), r.directive().awaitedBatchJobId);
    Assert.areEqual(1, WorkflowBatchJobs.launchCount, 'One launch');
    Assert.areEqual(50, WorkflowBatchJobs.lastScopeSize);
    Assert.isInstanceOfType(WorkflowBatchJobs.lastLaunched, StubBatch.class);
    Assert.areEqual('t1', ((StubBatch) WorkflowBatchJobs.lastLaunched).tag);
    Assert.isTrue(ctx.captures().hasNewCaptures(), 'The job Id is captured');
  }

  @IsTest
  static void testDefaultScopeSizeIs200() {
    WorkflowBatchJobs.stubLaunchId = JOB_ID;
    new WorkflowBatchStep()
      .execute(new StepContextTestBuilder().input(input(null)).build());
    Assert.areEqual(200, WorkflowBatchJobs.lastScopeSize);
  }

  @IsTest
  static void testNoInputObjectUsesNoArgConstructor() {
    WorkflowBatchJobs.stubLaunchId = JOB_ID;
    new WorkflowBatchStep()
      .execute(
        new StepContextTestBuilder()
          .input(new Map<String, Object>{ 'batchClass' => STUB_BATCH })
          .build()
      );
    Assert.isNull(((StubBatch) WorkflowBatchJobs.lastLaunched).tag);
  }

  @IsTest
  static void testReentrantHopDoesNotLaunchAgain() {
    stubJob(job('Processing', 3, 1, 0, null));
    StepResult r = new WorkflowBatchStep().execute(resumed(input(null)));

    Assert.areEqual(StepResult.ActionType.SUSPEND, r.directive().action);
    Assert.areEqual(String.valueOf(JOB_ID), r.directive().awaitedBatchJobId);
    Assert.areEqual(0, WorkflowBatchJobs.launchCount, 'No second launch');
  }

  @IsTest
  static void testSubclassBindingIsUsed() {
    WorkflowBatchJobs.stubLaunchId = JOB_ID;
    StepResult r = new BoundStep()
      .execute(new StepContextTestBuilder().build());
    Assert.areEqual(StepResult.ActionType.SUSPEND, r.directive().action);
    Assert.areEqual(10, WorkflowBatchJobs.lastScopeSize);
    Assert.areEqual('bound', ((StubBatch) WorkflowBatchJobs.lastLaunched).tag);
  }

  @IsTest
  static void testParallelBranchFailsBeforeLaunch() {
    Workflow_Instance__c inst = new Workflow_Instance__c(
      Workflow_Name__c = WORKFLOW,
      Status__c = 'Running',
      Current_Step__c = 'A,B',
      Correlation_Key__c = 'batch-parallel'
    );
    insert inst;
    WorkflowBatchJobs.stubLaunchId = JOB_ID;
    StepResult r = new WorkflowBatchStep()
      .execute(
        new StepContextTestBuilder()
          .workflowInstanceId(inst.Id)
          .input(input(null))
          .build()
      );
    Assert.areEqual(StepResult.ActionType.FAIL, r.directive().action);
    Assert.isTrue(r.directive().failureReason.contains('parallel'));
    Assert.areEqual(0, WorkflowBatchJobs.launchCount);
  }

  @IsTest
  static void testNonBatchableIsRefusedBeforeLaunch() {
    WorkflowBatchJobs.stubLaunchId = JOB_ID;
    String message = errorFor(
      new Map<String, Object>{
        'batchClass' => 'WorkflowBatchStepTest.NotABatch'
      }
    );
    Assert.isNotNull(message, 'A class that is not a Batchable must throw');
    Assert.isTrue(message.contains('not a Database.Batchable'), message);
    Assert.areEqual(0, WorkflowBatchJobs.launchCount, 'No launch');
  }

  @IsTest
  static void testLaunchErrorIsWrapped() {
    String message = errorFor(
      new Map<String, Object>{
        'batchClass' => 'WorkflowBatchStepTest.NotABatch'
      }
    );
    Assert.isNotNull(message, 'A class that is not a Batchable must throw');
    Assert.isTrue(message.startsWith('Batch launch failed'), message);
  }

  // ── Outcome ───────────────────────────────────────────────────────────

  @IsTest
  static void testCompletedJobCompletesWithOutcome() {
    stubJob(job('Completed', 3, 3, 0, null));
    StepResult r = new WorkflowBatchStep().execute(resumed(input(null)));

    Assert.areEqual(StepResult.ActionType.COMPLETE, r.directive().action);
    Assert.isNull(r.directive().nextStepName);
    Map<String, Object> out = output(r);
    Assert.areEqual(String.valueOf(JOB_ID), out.get('jobId'));
    Assert.areEqual('Completed', out.get('status'));
    Assert.areEqual(true, out.get('succeeded'));
    Assert.areEqual(3, out.get('totalJobItems'));
    Assert.areEqual(3, out.get('jobItemsProcessed'));
    Assert.areEqual(0, out.get('numberOfErrors'));
    Assert.isNull(out.get('firstError'));
    Assert.isTrue(out.containsKey('firstError'), 'The key is always there');
  }

  @IsTest
  static void testChunkErrorsAreNotSuccess() {
    stubJob(job('Completed', 3, 3, 1, 'First error: boom'));
    Map<String, Object> out = output(
      new WorkflowBatchStep().execute(resumed(input(null)))
    );
    Assert.areEqual(false, out.get('succeeded'));
    Assert.areEqual(1, out.get('numberOfErrors'));
    Assert.areEqual('First error: boom', out.get('firstError'));
  }

  @IsTest
  static void testFailedJobIsARoutableOutcome() {
    stubJob(job('Failed', 0, 0, 0, 'start() threw'));
    StepResult r = new WorkflowBatchStep().execute(resumed(input(null)));
    Assert.areEqual(StepResult.ActionType.COMPLETE, r.directive().action);
    Assert.areEqual('Failed', output(r).get('status'));
    Assert.areEqual(false, output(r).get('succeeded'));
  }

  @IsTest
  static void testAbortedJobIsNotSuccess() {
    stubJob(job('Aborted', 5, 2, 0, null));
    Map<String, Object> out = output(
      new WorkflowBatchStep().execute(resumed(input(null)))
    );
    Assert.areEqual('Aborted', out.get('status'));
    Assert.areEqual(false, out.get('succeeded'));
  }

  @IsTest
  static void testMissingJobRowIsNotFound() {
    WorkflowBatchJobs.stubJobs = new Map<Id, AsyncApexJob>();
    Map<String, Object> out = output(
      new WorkflowBatchStep().execute(resumed(input(null)))
    );
    Assert.areEqual(WorkflowBatchJobs.STATUS_NOT_FOUND, out.get('status'));
    Assert.areEqual(false, out.get('succeeded'));
  }

  @IsTest
  static void testOutcomeIsPinnedOnFirstRead() {
    stubJob(job('Completed', 3, 3, 0, null));
    StepContext ctx = resumed(input(null));
    new WorkflowBatchStep().execute(ctx);
    Assert.isTrue(ctx.captures().hasNewCaptures(), 'The outcome is captured');
    Assert.isTrue(
      ctx.captures()
        .getCapturedValuesJson()
        .contains(WorkflowBatchStep.KEY_OUTCOME)
    );
  }

  @IsTest
  static void testFailOnErrorFailsTheStep() {
    stubJob(job('Failed', 0, 0, 0, 'start() threw'));
    StepResult r = new WorkflowBatchStep()
      .execute(
        resumed(input(new Map<String, Object>{ 'failOnError' => true }))
      );
    Assert.areEqual(StepResult.ActionType.FAIL, r.directive().action);
    Assert.isTrue(r.directive().failureReason.contains('Failed'));
    Assert.isTrue(r.directive().failureReason.contains('start() threw'));
    Assert.isTrue(
      r.directive().failureDataJson.contains(String.valueOf(JOB_ID))
    );
  }

  @IsTest
  static void testFailOnErrorCompletesOnSuccess() {
    stubJob(job('Completed', 1, 1, 0, null));
    StepResult r = new WorkflowBatchStep()
      .execute(
        resumed(input(new Map<String, Object>{ 'failOnError' => true }))
      );
    Assert.areEqual(StepResult.ActionType.COMPLETE, r.directive().action);
  }

  // ── Input errors ──────────────────────────────────────────────────────

  @IsTest
  static void testInputErrors() {
    List<Object> inputs = new List<Object>{
      '',
      'not json',
      '[1]',
      new Map<String, Object>(),
      new Map<String, Object>{ 'batchClass' => ' ' },
      new Map<String, Object>{ 'batchClass' => 5 },
      input(new Map<String, Object>{ 'scopeSize' => 0 }),
      input(new Map<String, Object>{ 'scopeSize' => 2001 }),
      input(new Map<String, Object>{ 'scopeSize' => 1.5 }),
      input(new Map<String, Object>{ 'scopeSize' => 'x' }),
      input(new Map<String, Object>{ 'input' => 'x' }),
      input(new Map<String, Object>{ 'failOnError' => 'yes' })
    };
    List<String> expected = new List<String>{
      'Input is null',
      'Input must be a valid JSON object',
      'Input must be a valid JSON object',
      'batchClass is required',
      'batchClass is required',
      'batchClass must be a String',
      'scopeSize must be',
      'scopeSize must be',
      'scopeSize must be',
      'scopeSize must be',
      'input must be a JSON object',
      'failOnError must be a Boolean'
    };
    for (Integer i = 0; i < inputs.size(); i++) {
      String message = errorFor(inputs[i]);
      Assert.isNotNull(message, 'Must throw for case ' + i);
      Assert.isTrue(
        message.contains(expected[i]),
        'Case ' + i + ': expected "' + expected[i] + '" but got: ' + message
      );
    }
    Assert.areEqual(0, WorkflowBatchJobs.launchCount, 'No launch on bad input');
  }

  @IsTest
  static void testUnknownClassThrows() {
    String message = errorFor(
      new Map<String, Object>{ 'batchClass' => 'No_Such_Batch_Class_138' }
    );
    Assert.isNotNull(message);
    Assert.isTrue(message.contains('Batch class not found'), message);
  }

  @IsTest
  static void testBindingRejectsBadValues() {
    Assert.areEqual(
      200,
      new WorkflowBatchStep.Binding(STUB_BATCH, null, null).scopeSize
    );
    Boolean thrown = false;
    try {
      new WorkflowBatchStep.Binding(' ', 10, null);
    } catch (WorkflowEngine.WorkflowException ex) {
      thrown = true;
    }
    Assert.isTrue(thrown, 'A blank class name must throw');
    thrown = false;
    try {
      new WorkflowBatchStep.Binding(STUB_BATCH, 2001, null);
    } catch (WorkflowEngine.WorkflowException ex) {
      thrown = true;
    }
    Assert.isTrue(thrown, 'A scope size over 2000 must throw');
  }

  // ── StepResult directive ──────────────────────────────────────────────

  @IsTest
  static void testAwaitedBatchJobNeedsSuspendAndJobId() {
    Boolean thrown = false;
    try {
      StepResult.complete(null, null).withAwaitedBatchJob(JOB_ID);
    } catch (IllegalArgumentException ex) {
      thrown = true;
    }
    Assert.isTrue(thrown, 'Only a SUSPEND can await a batch job');
    thrown = false;
    try {
      StepResult.suspend().withAwaitedBatchJob(null);
    } catch (IllegalArgumentException ex) {
      thrown = true;
    }
    Assert.isTrue(thrown, 'The job Id is required');
    thrown = false;
    try {
      StepResult.suspend(60, 'X').withAwaitedBatchJob(JOB_ID);
    } catch (IllegalArgumentException ex) {
      thrown = true;
    }
    Assert.isTrue(thrown, 'A timed SUSPEND cannot await a batch job');
  }

  // ── Engine path (harness and heartbeat) ───────────────────────────────

  private static Workflow_Instance__c load(Id instanceId) {
    return [
      SELECT Status__c, Awaited_Batch_Job_Id__c, Sleep_Until__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
  }

  @IsTest
  static void testSuspendResumeExactlyOnceWithStrictDeterminism() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.strictDeterminism = true;
      WorkflowBatchJobs.stubLaunchId = JOB_ID;
      Test.startTest();
      Id instanceId = WorkflowEngine.start(WORKFLOW, 'batch-e2e', '{}');
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

      WorkflowTestHarness.Result r = harness.drive();
      Assert.isTrue(r.isSuspended, 'The step waits for the batch');
      Assert.areEqual(
        String.valueOf(JOB_ID),
        load(instanceId).Awaited_Batch_Job_Id__c,
        'The engine tracks the awaited job'
      );

      // Re-entrant hop: an operator resume while the job runs.
      stubJob(job('Processing', 2, 1, 0, null));
      WorkflowResumeService.resumeInstance(instanceId, null);
      r = harness.drive();
      Assert.isTrue(r.isSuspended, 'The step waits again');
      Assert.areEqual(1, WorkflowBatchJobs.launchCount, 'Zero double-launch');

      // A heartbeat while the job runs does nothing.
      WorkflowEngine.processWatchdogHeartbeat();
      Assert.areEqual('Suspended', load(instanceId).Status__c);

      // The job ends. One heartbeat resumes the instance.
      stubJob(job('Completed', 2, 2, 0, null));
      WorkflowEngine.processWatchdogHeartbeat();
      Workflow_Instance__c woken = load(instanceId);
      Assert.areEqual('Running', woken.Status__c, 'Resumed in one sweep');
      Assert.isNull(woken.Awaited_Batch_Job_Id__c, 'The sweep clears the job');

      r = harness.drive();
      Assert.areEqual('Completed', r.status, 'Strict mode sees no divergence');
      Assert.areEqual(1, WorkflowBatchJobs.launchCount, 'Still one launch');
      Map<String, Object> out = (Map<String, Object>) JSON.deserializeUntyped(
        [
          SELECT Output__c
          FROM Workflow_Step_Execution__c
          WHERE
            Workflow_Instance__c = :instanceId
            AND Step_Name__c = :BOUND_STEP
          ORDER BY CreatedDate DESC, Id DESC
          LIMIT 1
        ]
        .Output__c
      );
      Assert.areEqual(true, out.get('succeeded'));
      Assert.areEqual(
        1,
        [
          SELECT COUNT()
          FROM Workflow_Step_Execution__c
          WHERE
            Workflow_Instance__c = :instanceId
            AND Step_Name__c = :BOUND_STEP
        ],
        'The wait uses one step row'
      );
      Test.stopTest();
    }
  }
}
