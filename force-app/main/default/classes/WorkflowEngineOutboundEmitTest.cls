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
@isTest
public class WorkflowEngineOutboundEmitTest {
  // ----- Workflow A: a single step that emits then yields -> retries -> completes.

  public class EmitWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'WorkflowEngineOutboundEmitTest.EmitOnceStep';
    }
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  /**
   * Calls ctx.emit() on EVERY execution but only reaches COMPLETE on the third,
   * driven through a yield and a retry first (the same >=3-re-execution shape
   * used by CaptureOnceWorkflowExample). If emit published per execution this
   * would publish three times; effectively-once publishes exactly one.
   */
  public class EmitOnceStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Buffered on every execution; published only when COMPLETE commits.
      ctx.emit(
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

  public class ResultEmitWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'WorkflowEngineOutboundEmitTest.ResultEmitStep';
    }
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  public class ResultEmitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      List<SObject> events = new List<SObject>{
        new Workflow_Lifecycle__e(
          Workflow_Instance_Id__c = ctx.workflowInstanceId,
          Status__c = 'Completed'
        )
      };
      return StepResult.complete(null, 'done', events);
    }
  }

  // ----- Workflow B: a split step that emits, fanning out to two branches.

  public class SplitEmitWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'WorkflowEngineOutboundEmitTest.SplitEmitStep';
    }
    public String getNextStep(String currentStep, StepResult result) {
      if (currentStep == 'WorkflowEngineOutboundEmitTest.SplitEmitStep') {
        return 'WorkflowEngineOutboundEmitTest.JoinStep';
      }
      return null;
    }
  }

  public class SplitEmitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      ctx.emit(
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

  public class BranchAStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'A');
    }
  }

  public class BranchBStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'B');
    }
  }

  public class JoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'joined');
    }
  }

  // ----- Workflow whose result events list contains a null entry.

  public class NullEventWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'WorkflowEngineOutboundEmitTest.NullEventStep';
    }
    public String getNextStep(String currentStep, StepResult result) {
      return null;
    }
  }

  public class NullEventStep implements WorkflowStep {
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
      return StepResult.complete(null, 'done', events);
    }
  }

  // ----- Saga whose compensation step emits on rollback.

  public class CompensationEmitWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'WorkflowEngineOutboundEmitTest.RefundableChargeStep';
    }
    public String getNextStep(String currentStep, StepResult result) {
      if (
        currentStep == 'WorkflowEngineOutboundEmitTest.RefundableChargeStep'
      ) {
        return 'WorkflowEngineOutboundEmitTest.FailingStep';
      }
      return null;
    }
  }

  public class RefundableChargeStep implements CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'chargeId' => 'ch_1' }
      );
    }

    public StepResult compensate(StepContext ctx) {
      // Emit on rollback — must publish, coupled to the Compensated commit.
      ctx.emit(
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

  public class FailingStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Force a failure so the saga rolls back into RefundableChargeStep.compensate().
      throw new WorkflowEngine.WorkflowException(
        'forced failure to trigger compensation'
      );
    }
  }

  // ===========================================================================

  @isTest
  static void emitPublishesExactlyOnceDespiteThreeReExecutions() {
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

  @isTest
  static void nothingIsPublishedBeforeCompleteCommits() {
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

  @isTest
  static void completeOverloadPublishesProvidedEvents() {
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
      'Events handed to StepResult.complete(next, output, events) publish ' +
      'once on COMPLETE'
    );
  }

  @isTest
  static void splitTransitionPublishesEmittedEventsOnce() {
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

  @isTest
  static void nullEntriesInResultEventsAreFilteredNotDropped() {
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

  @isTest
  static void compensationEmitPublishesOnCompensatedCommit() {
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
