/**
 * Engine-level coverage for issue #11: the engine surfaces pending signals into
 * StepContext and ties consumption to the step's successful (COMPLETE)
 * transition.
 */
@isTest
public class StepContextSignalEngineTest {
  // --- Re-observation safety (AC4a) ---------------------------------------

  public class ReObserveWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.ReObserveStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class ReObserveStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Tick');
      if (!s.isPresent()) {
        return StepResult.suspend();
      }
      if (String.isBlank(ctx.stepStateJson)) {
        // Observed the signal but yield (NOT complete): engine must not consume
        // it yet, so the next attempt re-observes the same pending signal.
        return StepResult.yield('{"seen":true}');
      }
      return StepResult.complete(null, 'done:' + s.payload);
    }
  }

  @isTest
  static void testObservedSignalSurvivesYieldUntilComplete() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.ReObserveWorkflow',
      'ReObserveKey',
      null
    );

    // Suspends waiting for the signal.
    new WorkflowOrchestrator(instanceId).execute(null);

    WorkflowEngine.signal('ReObserveKey', 'Tick', '{"v":1}');

    // First observed run yields without completing.
    new WorkflowOrchestrator(instanceId).execute(null);
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
      ],
      'A signal observed by a step that yields (not completes) must remain pending'
    );

    // Second run sees state set, completes, and the engine consumes the signal.
    new WorkflowOrchestrator(instanceId).execute(null);

    Workflow_Instance__c inst = [
      SELECT Status__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertEquals('Completed', inst.Status__c);
    System.assertEquals('"done:{\\"v\\":1}"', inst.Output__c);
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
      ],
      'Signal must be consumed once the observing step completes'
    );
  }

  // --- Cancel control signals are never surfaced (AC5) --------------------

  public class PlainWaitWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.PlainWaitStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class PlainWaitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Asserts the control signal is never visible as a readable payload.
      System.assertEquals(
        0,
        ctx.getSignals('Cancel').size(),
        'Cancel must never be surfaced as a readable signal'
      );
      if (ctx.getSignal('Go').isPresent()) {
        return StepResult.complete(null, 'went');
      }
      return StepResult.suspend();
    }
  }

  @isTest
  static void testCancelSignalIsNotSurfacedAsReadablePayload() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.PlainWaitWorkflow',
      'CancelKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);

    Test.startTest();
    WorkflowEngine.signal('CancelKey', 'Cancel', null);
    Test.stopTest();

    // Cancellation is handled inline by the engine and never persists a
    // Workflow_Signal__c record, so it can never reach StepContext.
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :instanceId
      ],
      'Cancel control signals must not create readable signal records'
    );

    Workflow_Instance__c inst = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
    ];
    System.assertNotEquals(
      'Running',
      inst.Status__c,
      'Cancel must still drive cancellation semantics'
    );
  }

  // --- In-flight duplicate consumed by observed-name re-query (AC4b) -------

  public class InFlightDupWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.InFlightDupStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class InFlightDupStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Dup');
      if (!s.isPresent()) {
        return StepResult.suspend();
      }
      // Simulate an at-least-once duplicate of the observed signal arriving in
      // another transaction *while* this step executes -- i.e. after the context
      // snapshot was loaded. Consumption must still catch it by name.
      insert new Workflow_Signal__c(
        Workflow_Instance__c = ctx.workflowInstanceId,
        Signal_Name__c = 'Dup',
        Payload__c = s.payload,
        Status__c = 'Received'
      );
      return StepResult.complete(null, 'handled');
    }
  }

  @isTest
  static void testInFlightDuplicateConsumedByName() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.InFlightDupWorkflow',
      'InFlightKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);

    WorkflowEngine.signal('InFlightKey', 'Dup', '{"v":1}');

    // Step reads the signal, a duplicate lands mid-execution, then it completes.
    new WorkflowOrchestrator(instanceId).execute(null);

    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
      ],
      'A same-name duplicate delivered during execution must also be consumed'
    );
    System.assertEquals(
      2,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Consumed'
      ]
    );
  }

  // --- SPLIT consumes the spawning step's observed signals (AC4) ----------

  public class SplitSignalWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.SignalThenSplitStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (
        currentStepName == 'StepContextSignalEngineTest.SignalThenSplitStep'
      ) {
        return 'StepContextSignalEngineTest.SplitJoinStep';
      }
      return null;
    }
  }

  public class SignalThenSplitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Fan');
      if (!s.isPresent()) {
        return StepResult.suspend();
      }
      return StepResult.split(
        new List<String>{
          'StepContextSignalEngineTest.BranchAStep',
          'StepContextSignalEngineTest.BranchBStep'
        },
        s.payload
      );
    }
  }

  public class BranchAStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      System.assertEquals(
        false,
        ctx.hasSignal('Fan'),
        'The spawning step signal must not leak into a parallel branch'
      );
      return StepResult.complete(null, 'A');
    }
  }

  public class BranchBStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      System.assertEquals(
        false,
        ctx.hasSignal('Fan'),
        'The spawning step signal must not leak into a parallel branch'
      );
      return StepResult.complete(null, 'B');
    }
  }

  public class SplitJoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'joined');
    }
  }

  @isTest
  static void testSplitConsumesSpawningStepSignals() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.SplitSignalWorkflow',
      'FanKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);

    WorkflowEngine.signal('FanKey', 'Fan', '{"x":1}');

    // SignalThenSplitStep observes 'Fan' and fans out: the signal must be
    // consumed at the split so it is not re-loaded into the parallel branches.
    new WorkflowOrchestrator(instanceId).execute(null);

    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
      ],
      'SPLIT must consume the spawning step observed signals'
    );

    // Run the parallel branches; their in-step asserts confirm no leak.
    new WorkflowOrchestrator(
        instanceId,
        'StepContextSignalEngineTest.BranchAStep'
      )
      .execute(null);
    new WorkflowOrchestrator(
        instanceId,
        'StepContextSignalEngineTest.BranchBStep'
      )
      .execute(null);
  }

  // --- A name probed absent must not consume a later arrival (AC4b nuance) -

  public class ProbeAbsentWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.ProbeAbsentStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class ProbeAbsentStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal trigger = ctx.getSignal('Trigger');
      if (!trigger.isPresent()) {
        return StepResult.suspend();
      }
      // Probe a name that is absent now -- this records nothing as matched.
      System.assertEquals(
        false,
        ctx.hasSignal('LateGhost'),
        'LateGhost is not pending at probe time'
      );
      // A signal of that probed-absent name now arrives mid-execution.
      insert new Workflow_Signal__c(
        Workflow_Instance__c = ctx.workflowInstanceId,
        Signal_Name__c = 'LateGhost',
        Payload__c = 'boo',
        Status__c = 'Received'
      );
      // The step never matched LateGhost, so completion must not consume it.
      return StepResult.complete(null, 'done');
    }
  }

  @isTest
  static void testProbeAbsentNamePreservesLaterSignal() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.ProbeAbsentWorkflow',
      'ProbeKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);

    WorkflowEngine.signal('ProbeKey', 'Trigger', '{"v":1}');
    new WorkflowOrchestrator(instanceId).execute(null);

    // Trigger was matched and consumed.
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Signal_Name__c = 'Trigger'
          AND Status__c = 'Received'
      ]
    );
    // LateGhost was only probed absent -> it must survive for a later step.
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Signal_Name__c = 'LateGhost'
          AND Status__c = 'Received'
      ],
      'A signal that arrived after an absent probe must be preserved'
    );
  }
}
