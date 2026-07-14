/**
 * Engine-level tests for effectively-once outbound emit (issue #64).
 *
 * The success metric: a step replayed through WorkflowTestHarness with >=3
 * forced re-executions (yield -> retry -> complete) before commit publishes
 * each domain event exactly ONCE at the producer — versus a hand-rolled
 * EventBus.publish() in execute(), which would fire once per re-execution.
 *
 * The guarantee is anchored on the engine's append-only Completed record: the
 * engine publishes a step's buffered events only when its COMPLETE (or SPLIT)
 * transition commits. Emits buffered on the yield/retry executions are never
 * published, because publishOutboundEvents runs only on COMPLETE/SPLIT.
 *
 * Platform events are not SOQL-queryable, so we assert on the @TestVisible
 * WorkflowOutboundEventPublisher.publishedEvents capture. A Workflow_Lifecycle__e
 * instance stands in for an author-owned __e (the engine emits any SObject).
 *
 * Must be `public` (not private) so Type.forName can resolve the inner test
 * WorkflowDefinition/WorkflowStep classes the engine instantiates by name.
 */
@IsTest
public class WorkflowEngineOutboundEmitTest {
  // ----- Workflow A: a single step that emits then yields -> retries -> completes.

  /**
   * @description Fixture workflow with a single emit step that yields, retries, then
   * completes, exercising effectively-once publish across re-executions.
   */
  public class EmitWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single EmitOnceStep.
     * @return The one-element list naming EmitOnceStep.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineOutboundEmitTest.EmitOnceStep' };
    }
    /**
     * @description Returns EmitOnceStep as the entry point.
     * @return The name of the initial step.
     */
    public String getInitialStep() {
      return 'WorkflowEngineOutboundEmitTest.EmitOnceStep';
    }
    /**
     * @description Terminates after the single step.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, marking the workflow complete.
     */
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  /**
   * Calls ctx.events().emit() on EVERY execution but only reaches COMPLETE on the third,
   * driven through a yield and a retry first (the same >=3-re-execution shape
   * used by CaptureOnceWorkflowExample). If emit published per execution this
   * would publish three times; effectively-once publishes exactly one.
   */
  public class EmitOnceStep implements WorkflowStep {
    /**
     * @description Emits on every execution but yields, then retries, then completes,
     * so effectively-once publishing can be asserted across three re-executions.
     * @param ctx The durable step context used to emit and inspect retry state.
     * @return A yield, then a retry, then a complete result across successive runs.
     */
    public StepResult execute(StepContext ctx) {
      // Buffered on every execution; published only when COMPLETE commits.
      ctx.events()
        .emit(
          new Workflow_Lifecycle__e(
            Workflow_Instance_Id__c = ctx.workflowInstanceId,
            Status__c = 'Completed'
          )
        );

      Integer retryCount = currentRetryCount(ctx);
      Boolean resumedFromYield = String.isNotBlank(ctx.stepStateJson);

      if (retryCount == 0 && !resumedFromYield) {
        return StepResult.yield('{"phase":"yielded"}');
      }
      if (retryCount == 0 && resumedFromYield) {
        return StepResult.retry(new RetryPolicy(1, (Double) 1.0, 3));
      }
      return StepResult.complete(null, 'shipped');
    }

    private Integer currentRetryCount(StepContext ctx) {
      List<Workflow_Step_Execution__c> execs = [
        SELECT Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :ctx.workflowInstanceId
          AND Step_Name__c = :ctx.stepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      if (execs.isEmpty() || execs[0].Retry_Count__c == null) {
        return 0;
      }
      return execs[0].Retry_Count__c.intValue();
    }
  }

  // ----- Workflow using the StepResult.complete(next, output, events) overload.

  /**
   * @description Fixture workflow whose single step emits via the
   * StepResult.complete(next, output, events) overload rather than ctx.emit.
   */
  public class ResultEmitWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single ResultEmitStep.
     * @return The one-element list naming ResultEmitStep.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineOutboundEmitTest.ResultEmitStep'
      };
    }
    /**
     * @description Returns ResultEmitStep as the entry point.
     * @return The name of the initial step.
     */
    public String getInitialStep() {
      return 'WorkflowEngineOutboundEmitTest.ResultEmitStep';
    }
    /**
     * @description Terminates after the single step.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, marking the workflow complete.
     */
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  /**
   * @description Fixture step that attaches its outbound event to the complete result
   * via the events overload.
   */
  public class ResultEmitStep implements WorkflowStep {
    /**
     * @description Completes carrying a single lifecycle event on the result.
     * @param ctx The durable step context exposing the workflow instance Id.
     * @return A complete result carrying one outbound event.
     */
    public StepResult execute(StepContext ctx) {
      List<SObject> events = new List<SObject>{
        new Workflow_Lifecycle__e(
          Workflow_Instance_Id__c = ctx.workflowInstanceId,
          Status__c = 'Completed'
        )
      };
      for (SObject evt : events) {
        ctx.events().emit(evt);
      }
      return StepResult.complete(null, 'done');
    }
  }

  // ----- Workflow B: a split step that emits, fanning out to two branches.

  /**
   * @description Fixture workflow whose initial step emits then splits into two
   * branches that rejoin, verifying emit publishes exactly once on the SPLIT commit.
   */
  public class SplitEmitWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the split, two branch, and join steps.
     * @return The list of step names in the split-emit workflow.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineOutboundEmitTest.SplitEmitStep',
        'WorkflowEngineOutboundEmitTest.BranchAStep',
        'WorkflowEngineOutboundEmitTest.BranchBStep',
        'WorkflowEngineOutboundEmitTest.JoinStep'
      };
    }
    /**
     * @description Returns the split step as the entry point.
     * @return The name of the initial step.
     */
    public String getInitialStep() {
      return 'WorkflowEngineOutboundEmitTest.SplitEmitStep';
    }
    /**
     * @description Routes the split step to the join once both branches finish.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return The join step after the split, or null otherwise.
     */
    public String getNextStep(String currentStep, StepResult result) {
      if (currentStep == 'WorkflowEngineOutboundEmitTest.SplitEmitStep') {
        return 'WorkflowEngineOutboundEmitTest.JoinStep';
      }
      return null;
    }
  }

  /**
   * @description Fixture step that emits an event and then fans out into the two
   * parallel branches.
   */
  public class SplitEmitStep implements WorkflowStep {
    /**
     * @description Emits a lifecycle event, then splits into the A and B branches.
     * @param ctx The durable step context used to emit the event.
     * @return A split result naming the two branch steps.
     */
    public StepResult execute(StepContext ctx) {
      ctx.events()
        .emit(
          new Workflow_Lifecycle__e(
            Workflow_Instance_Id__c = ctx.workflowInstanceId,
            Status__c = 'Completed'
          )
        );
      return StepResult.split(
        new List<String>{
          'WorkflowEngineOutboundEmitTest.BranchAStep',
          'WorkflowEngineOutboundEmitTest.BranchBStep'
        }
      );
    }
  }

  /**
   * @description Fixture branch step A that completes immediately.
   */
  public class BranchAStep implements WorkflowStep {
    /**
     * @description Completes the A branch.
     * @param ctx The durable step context.
     * @return A complete result with output 'A'.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'A');
    }
  }

  /**
   * @description Fixture branch step B that completes immediately.
   */
  public class BranchBStep implements WorkflowStep {
    /**
     * @description Completes the B branch.
     * @param ctx The durable step context.
     * @return A complete result with output 'B'.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'B');
    }
  }

  /**
   * @description Fixture join step that completes once both branches finish.
   */
  public class JoinStep implements WorkflowStep {
    /**
     * @description Completes the join after the branches converge.
     * @param ctx The durable step context.
     * @return A complete result with output 'joined'.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'joined');
    }
  }

  // ----- Workflow whose result events list contains a null entry.

  /**
   * @description Fixture workflow whose step returns an events list containing a null,
   * verifying the engine filters nulls before publishing.
   */
  public class NullEventWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the single NullEventStep.
     * @return The one-element list naming NullEventStep.
     */
    public List<String> getSteps() {
      return new List<String>{ 'WorkflowEngineOutboundEmitTest.NullEventStep' };
    }
    /**
     * @description Returns NullEventStep as the entry point.
     * @return The name of the initial step.
     */
    public String getInitialStep() {
      return 'WorkflowEngineOutboundEmitTest.NullEventStep';
    }
    /**
     * @description Terminates after the single step.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return Always null, marking the workflow complete.
     */
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  /**
   * @description Fixture step whose result events list contains a valid event plus a
   * null, exercising the engine's null-filtering before EventBus.publish.
   */
  public class NullEventStep implements WorkflowStep {
    /**
     * @description Completes carrying an events list with one valid event and a null.
     * @param ctx The durable step context exposing the workflow instance Id.
     * @return A complete result carrying the mixed events list.
     */
    public StepResult execute(StepContext ctx) {
      // A conditionally-built list that ends up with a null alongside a valid
      // event. The engine must filter the null, not forward it to
      // EventBus.publish (which would throw and drop the whole batch).
      List<SObject> events = new List<SObject>{
        new Workflow_Lifecycle__e(
          Workflow_Instance_Id__c = ctx.workflowInstanceId,
          Status__c = 'Completed'
        ),
        null
      };
      for (SObject evt : events) {
        ctx.events().emit(evt);
      }
      return StepResult.complete(null, 'done');
    }
  }

  // ----- Saga whose compensation step emits on rollback.

  /**
   * @description Fixture saga whose second step fails, forcing a rollback so the first
   * step's compensation emits an event coupled to the Compensated commit.
   */
  public class CompensationEmitWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the refundable charge step and the failing step.
     * @return The list of step names in the compensation-emit saga.
     */
    public List<String> getSteps() {
      return new List<String>{
        'WorkflowEngineOutboundEmitTest.RefundableChargeStep',
        'WorkflowEngineOutboundEmitTest.FailingStep'
      };
    }
    /**
     * @description Returns the refundable charge step as the entry point.
     * @return The name of the initial step.
     */
    public String getInitialStep() {
      return 'WorkflowEngineOutboundEmitTest.RefundableChargeStep';
    }
    /**
     * @description Routes the charge step to the failing step to trigger rollback.
     * @param currentStep The name of the step that just completed.
     * @param result The result of the completed step.
     * @return The failing step after the charge, or null otherwise.
     */
    public String getNextStep(String currentStep, StepResult result) {
      if (
        currentStep == 'WorkflowEngineOutboundEmitTest.RefundableChargeStep'
      ) {
        return 'WorkflowEngineOutboundEmitTest.FailingStep';
      }
      return null;
    }
  }

  /**
   * @description Fixture compensatable step that charges on the forward path and emits
   * a Compensated event when its compensation runs on rollback.
   */
  public class RefundableChargeStep implements CompensatableStep {
    /**
     * @description Records a simulated charge on the forward path.
     * @param ctx The durable step context.
     * @return A complete result carrying the charge Id.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'chargeId' => 'ch_1' }
      );
    }

    /**
     * @description Emits a Compensated lifecycle event and records the refund during rollback.
     * @param ctx The durable step context used to emit the event.
     * @return A complete result carrying the refund outcome.
     */
    public StepResult compensate(StepContext ctx) {
      // Emit on rollback — must publish, coupled to the Compensated commit.
      ctx.events()
        .emit(
          new Workflow_Lifecycle__e(
            Workflow_Instance_Id__c = ctx.workflowInstanceId,
            Status__c = 'Compensated'
          )
        );
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'refunded' => true }
      );
    }
  }

  /**
   * @description Fixture step that always throws, forcing the saga to roll back into
   * the prior step's compensation.
   */
  public class FailingStep implements WorkflowStep {
    /**
     * @description Throws unconditionally to trigger compensation.
     * @param ctx The durable step context.
     * @return Never returns; always throws to force rollback.
     */
    public StepResult execute(StepContext ctx) {
      // Force a failure so the saga rolls back into RefundableChargeStep.compensate().
      throw new WorkflowEngine.WorkflowException(
        'forced failure to trigger compensation'
      );
    }
  }

  // ===========================================================================

  @IsTest
  static void emitPublishesExactlyOnceDespiteThreeReExecutions() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowOutboundEventPublisher.publishedEvents.clear();

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineOutboundEmitTest.EmitWorkflow',
        'emit-once-1',
        null
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      System.assertEquals('Completed', result.status, 'Workflow must complete');
      System.assert(
        result.reachedStep('WorkflowEngineOutboundEmitTest.EmitOnceStep'),
        'EmitOnceStep must have executed'
      );
      System.assertEquals(
        1,
        WorkflowOutboundEventPublisher.publishedEvents.size(),
        'Producer-side effectively-once: exactly one publish across yield -> ' +
        'retry -> complete (>=3 re-executions), each of which called emit()'
      );
    }
  }

  @IsTest
  static void nothingIsPublishedBeforeCompleteCommits() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowOutboundEventPublisher.publishedEvents.clear();

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineOutboundEmitTest.EmitWorkflow',
        'emit-once-pre-commit',
        null
      );
      WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

      // First hop: the step emits then YIELDS — no COMPLETE record, no publish.
      harness.step();
      System.assertEquals(
        0,
        WorkflowOutboundEventPublisher.publishedEvents.size(),
        'A yield (pre-commit) must publish nothing even though emit() was called'
      );

      // Drive the rest (retry -> complete): now exactly one publish.
      WorkflowTestHarness.Result result = harness.drive();
      Test.stopTest();

      System.assertEquals('Completed', result.status);
      System.assertEquals(
        1,
        WorkflowOutboundEventPublisher.publishedEvents.size(),
        'Publish happens only when COMPLETE commits'
      );
    }
  }

  @IsTest
  static void completeOverloadPublishesProvidedEvents() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowOutboundEventPublisher.publishedEvents.clear();

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineOutboundEmitTest.ResultEmitWorkflow',
        'result-emit-1',
        null
      );
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      System.assertEquals('Completed', result.status);
      System.assertEquals(
        1,
        WorkflowOutboundEventPublisher.publishedEvents.size(),
        'Events buffered via ctx.events().emit(...) publish once on COMPLETE'
      );
    }
  }

  @IsTest
  static void splitTransitionPublishesEmittedEventsOnce() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowOutboundEventPublisher.publishedEvents.clear();

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineOutboundEmitTest.SplitEmitWorkflow',
        'split-emit-1',
        null
      );
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      System.assertEquals('Completed', result.status);
      System.assertEquals(
        1,
        WorkflowOutboundEventPublisher.publishedEvents.size(),
        'A step that emits then SPLITs publishes its events once on the SPLIT ' +
        'commit; the fan-out branches emit nothing and add no publishes'
      );
    }
  }

  @IsTest
  static void nullEntriesInResultEventsAreFilteredNotDropped() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowOutboundEventPublisher.publishedEvents.clear();

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineOutboundEmitTest.NullEventWorkflow',
        'null-event-1',
        null
      );
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      System.assertEquals('Completed', result.status);
      System.assertEquals(
        1,
        WorkflowOutboundEventPublisher.publishedEvents.size(),
        'A null entry in the result events is filtered; the valid event still ' +
        'publishes (a null would otherwise throw and drop the whole batch)'
      );
    }
  }

  @IsTest
  static void compensationEmitPublishesOnCompensatedCommit() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowOutboundEventPublisher.publishedEvents.clear();

      Test.startTest();
      Id instanceId = WorkflowEngine.start(
        'WorkflowEngineOutboundEmitTest.CompensationEmitWorkflow',
        'comp-emit-1',
        null
      );
      WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId)
        .drive();
      Test.stopTest();

      System.assertEquals(
        'Compensated',
        result.status,
        'Saga must roll back so the compensation runs'
      );
      System.assertEquals(
        1,
        WorkflowOutboundEventPublisher.publishedEvents.size(),
        'A compensate() emit publishes once, coupled to the Compensated commit'
      );
    }
  }
}
