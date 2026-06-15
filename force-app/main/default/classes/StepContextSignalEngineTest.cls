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

  // --- Atomic claim-at-read for parallel branches (AC6) --------------------

  public class ClaimRaceWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.ClaimRaceSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'StepContextSignalEngineTest.ClaimRaceSpawnStep') {
        return 'StepContextSignalEngineTest.ClaimRaceJoinStep';
      }
      return null;
    }
  }

  // Spawning step: wait for a signal, then fan out two branches.
  public class ClaimRaceSpawnStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Fan');
      if (!s.isPresent()) {
        return StepResult.suspend();
      }
      return StepResult.split(
        new List<String>{
          'StepContextSignalEngineTest.ClaimBranchAlpha',
          'StepContextSignalEngineTest.ClaimBranchBeta'
        },
        s.payload
      );
    }
  }

  // Branch Alpha: claims a shared "Shared" signal if present; stores result in output.
  public class ClaimBranchAlpha implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Shared');
      return StepResult.complete(null, s.isPresent() ? 'claimed' : 'absent');
    }
  }

  // Branch Beta: also tries to claim the same "Shared" signal.
  public class ClaimBranchBeta implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Shared');
      return StepResult.complete(null, s.isPresent() ? 'claimed' : 'absent');
    }
  }

  public class ClaimRaceJoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, ctx.inputJson);
    }
  }

  /**
   * Verifies that when a "Shared" signal is present before both branches run,
   * exactly one branch claims it (the first to execute) and the second sees it
   * as absent (Processing, not Received) -- atomic claim-at-read for parallel
   * branches.  The signal ends up Consumed after the claiming branch completes.
   */
  @isTest
  static void testParallelBranchAtomicClaimAtRead() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.ClaimRaceWorkflow',
      'ClaimRaceKey',
      null
    );

    // Suspends waiting for Fan signal.
    new WorkflowOrchestrator(instanceId).execute(null);

    // Send the fan-out trigger.
    WorkflowEngine.signal('ClaimRaceKey', 'Fan', '{"x":1}');
    // Send the shared signal that both branches will race to claim.
    WorkflowEngine.signal('ClaimRaceKey', 'Shared', '{"s":1}');

    // Spawning step consumes 'Fan' and fans out; 'Shared' is untouched.
    new WorkflowOrchestrator(instanceId).execute(null);

    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Signal_Name__c = 'Shared'
          AND Status__c = 'Received'
      ],
      'Shared signal must still be Received after spawn'
    );

    // Run Alpha branch first -- it claims 'Shared'.
    new WorkflowOrchestrator(
        instanceId,
        'StepContextSignalEngineTest.ClaimBranchAlpha'
      )
      .execute(null);

    // After Alpha completes, the signal is Consumed (claim + consume in one transaction).
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Signal_Name__c = 'Shared'
          AND Status__c = 'Received'
      ],
      'Shared signal must no longer be Received after Alpha completes'
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Signal_Name__c = 'Shared'
          AND Status__c = 'Consumed'
      ],
      'Shared signal must be Consumed once Alpha completes'
    );

    // Run Beta branch -- it must find no Received signal (Alpha claimed it).
    new WorkflowOrchestrator(
        instanceId,
        'StepContextSignalEngineTest.ClaimBranchBeta'
      )
      .execute(null);

    // Verify Beta output was 'absent'.
    List<Workflow_Step_Execution__c> betaExecs = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'StepContextSignalEngineTest.ClaimBranchBeta'
        AND Status__c = 'Completed'
    ];
    System.assertEquals(1, betaExecs.size());
    System.assertEquals(
      '"absent"',
      betaExecs[0].Output__c,
      'Beta must have seen signal as absent (already claimed by Alpha)'
    );
  }

  /**
   * Verifies that a completing parallel branch consumes ONLY its own claimed
   * signal and never a sibling branch's claim of the same name. A sibling that
   * has not durably finished (its claim is still Processing, or was rolled back
   * to Received after a yield/retry) must keep its signal so it can finish.
   */
  @isTest
  static void testParallelCompleteDoesNotConsumeSiblingClaim() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.ClaimRaceWorkflow',
      'SiblingClaimKey',
      null
    );

    new WorkflowOrchestrator(instanceId).execute(null);
    WorkflowEngine.signal('SiblingClaimKey', 'Fan', '{"x":1}');
    WorkflowEngine.signal('SiblingClaimKey', 'Shared', '{"s":1}');
    // Fan-out: spawn step reads Fan (consumed), fans out branches.
    new WorkflowOrchestrator(instanceId).execute(null);

    // Simulate a sibling branch (Beta) that has already claimed its OWN copy of
    // 'Shared' but has not yet durably completed -- its claim sits in Processing.
    Workflow_Signal__c siblingClaim = new Workflow_Signal__c(
      Workflow_Instance__c = instanceId,
      Signal_Name__c = 'Shared',
      Payload__c = '{"s":2}',
      Status__c = 'Processing'
    );
    insert siblingClaim;

    // Alpha reads the Received 'Shared' (claims its own copy), then completes.
    new WorkflowOrchestrator(
        instanceId,
        'StepContextSignalEngineTest.ClaimBranchAlpha'
      )
      .execute(null);

    // Alpha consumed only the row IT claimed.
    System.assertEquals(
      'Consumed',
      [
        SELECT Status__c
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Signal_Name__c = 'Shared'
          AND Id != :siblingClaim.Id
      ]
      .Status__c,
      'Alpha must consume the copy it claimed'
    );

    // The sibling branch's Processing claim must be untouched -- consuming it
    // would strip a signal from a branch that has not durably finished.
    System.assertEquals(
      'Processing',
      [SELECT Status__c FROM Workflow_Signal__c WHERE Id = :siblingClaim.Id]
      .Status__c,
      'A completing branch must NOT consume a sibling branch claim of the same name'
    );
  }

  // --- Guard-then-read returns the claimed payload (StepContext cache merge) --

  public class GuardReadWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.GuardReadSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'StepContextSignalEngineTest.GuardReadSpawnStep') {
        return 'StepContextSignalEngineTest.GuardReadJoinStep';
      }
      return null;
    }
  }

  public class GuardReadSpawnStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Fan');
      if (!s.isPresent()) {
        return StepResult.suspend();
      }
      return StepResult.split(
        new List<String>{
          'StepContextSignalEngineTest.GuardReadBranch',
          'StepContextSignalEngineTest.GuardReadOtherBranch'
        },
        s.payload
      );
    }
  }

  // Guard-then-read: hasSignal('Shared') (claims the latest row out of the
  // source's Received view), then getSignals('Shared') -- which must still
  // return that already-claimed payload, not an empty list.
  public class GuardReadBranch implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      Boolean guard = ctx.hasSignal('Shared');
      List<StepContext.Signal> all = ctx.getSignals('Shared');
      String marker = guard
        ? 'guard=true;count=' + all.size()
        : 'guard=false;count=' + all.size();
      // Confirm the payload survived the guard-then-read.
      if (!all.isEmpty()) {
        marker += ';payload=' + all[0].payload;
      }
      return StepResult.complete(null, marker);
    }
  }

  public class GuardReadOtherBranch implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'other');
    }
  }

  public class GuardReadJoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, ctx.inputJson);
    }
  }

  @isTest
  static void testParallelGuardThenReadReturnsClaimedPayload() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.GuardReadWorkflow',
      'GuardReadKey',
      null
    );

    new WorkflowOrchestrator(instanceId).execute(null);
    WorkflowEngine.signal('GuardReadKey', 'Fan', '{"x":1}');
    WorkflowEngine.signal('GuardReadKey', 'Shared', '{"s":1}');
    // Fan-out.
    new WorkflowOrchestrator(instanceId).execute(null);

    // Run the guard-then-read branch.
    new WorkflowOrchestrator(
        instanceId,
        'StepContextSignalEngineTest.GuardReadBranch'
      )
      .execute(null);

    Workflow_Step_Execution__c branchExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'StepContextSignalEngineTest.GuardReadBranch'
        AND Status__c = 'Completed'
    ];
    System.assert(
      branchExec.Output__c.contains('guard=true'),
      'hasSignal must have observed the Shared signal'
    );
    System.assert(
      branchExec.Output__c.contains('count=1'),
      'getSignals(name) after hasSignal must still return the claimed signal, got: ' +
      branchExec.Output__c
    );
    System.assert(
      branchExec.Output__c.contains('payload={\\"s\\":1}') ||
      branchExec.Output__c.contains('payload={"s":1}'),
      'The claimed payload must survive the guard-then-read: ' +
      branchExec.Output__c
    );
  }

  // --- A parallel branch suspended on a signal is woken by name (D) ---------

  public class WakeWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.WakeSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'StepContextSignalEngineTest.WakeSpawnStep') {
        return 'StepContextSignalEngineTest.WakeJoinStep';
      }
      return null;
    }
  }

  public class WakeSpawnStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Go');
      if (!s.isPresent()) {
        return StepResult.suspend();
      }
      return StepResult.split(
        new List<String>{
          'StepContextSignalEngineTest.WakeWaitBranch',
          'StepContextSignalEngineTest.WakeOtherBranch'
        },
        s.payload
      );
    }
  }

  public class WakeWaitBranch implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (!ctx.getSignal('Resume').isPresent()) {
        return StepResult.suspend();
      }
      return StepResult.complete(null, 'resumed');
    }
  }

  public class WakeOtherBranch implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'other');
    }
  }

  public class WakeJoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, ctx.inputJson);
    }
  }

  @isTest
  static void testParallelBranchSuspendedOnSignalIsWokenByName() {
    WorkflowEngine.disableQueueableInTest = true;
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.WakeWorkflow',
      'WakeKey',
      null
    );
    // Spawn suspends waiting for Go.
    new WorkflowOrchestrator(instanceId).execute(null);
    WorkflowEngine.signal('WakeKey', 'Go', '{}');
    // Spawn fans out into the two branches.
    new WorkflowOrchestrator(instanceId).execute(null);
    // The waiting branch suspends on the Resume signal.
    new WorkflowOrchestrator(
        instanceId,
        'StepContextSignalEngineTest.WakeWaitBranch'
      )
      .execute(null);

    // Signal Resume: the suspended parallel branch must be enqueued BY NAME,
    // not via a blank-stepName enqueue that runStep would discard.
    WorkflowEngine.enqueuedBranchKeys.clear();
    WorkflowEngine.signal('WakeKey', 'Resume', '{}');

    System.assert(
      WorkflowEngine.enqueuedBranchKeys.contains(
        instanceId + '::StepContextSignalEngineTest.WakeWaitBranch'
      ),
      'A parallel branch suspended on a signal must be woken by its step name. Keys: ' +
      WorkflowEngine.enqueuedBranchKeys
    );
  }

  // --- CalloutStep branches read without claiming (C) -----------------------

  public class ProbeWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.ProbeSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'StepContextSignalEngineTest.ProbeSpawnStep') {
        return 'StepContextSignalEngineTest.ProbeJoinStep';
      }
      return null;
    }
  }

  public class ProbeSpawnStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Kick');
      if (!s.isPresent()) {
        return StepResult.suspend();
      }
      return StepResult.split(
        new List<String>{
          'StepContextSignalEngineTest.ProbeClaimBranch',
          'StepContextSignalEngineTest.ProbeCalloutBranch'
        },
        s.payload
      );
    }
  }

  // Default branch: claims, so its signal flips to Processing mid-execution.
  public class ProbeClaimBranch implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('ProbeA');
      String status = '';
      if (s.isPresent()) {
        status = [
          SELECT Status__c
          FROM Workflow_Signal__c
          WHERE Id = :s.signalId
        ]
        .Status__c;
      }
      return StepResult.complete(null, status);
    }
  }

  // CalloutStep branch: must NOT claim, so its signal stays Received mid-step
  // and a subsequent payload-driven callout would be legal.
  public class ProbeCalloutBranch implements WorkflowStep, CalloutStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('ProbeB');
      String status = '';
      if (s.isPresent()) {
        status = [
          SELECT Status__c
          FROM Workflow_Signal__c
          WHERE Id = :s.signalId
        ]
        .Status__c;
      }
      return StepResult.complete(null, status);
    }
  }

  public class ProbeJoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, ctx.inputJson);
    }
  }

  @isTest
  static void testCalloutStepBranchReadsWithoutClaiming() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.ProbeWorkflow',
      'ProbeKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);
    WorkflowEngine.signal('ProbeKey', 'Kick', '{}');
    WorkflowEngine.signal('ProbeKey', 'ProbeA', '{"a":1}');
    WorkflowEngine.signal('ProbeKey', 'ProbeB', '{"b":1}');
    // Fan out.
    new WorkflowOrchestrator(instanceId).execute(null);

    // Default (claiming) branch: its signal is Processing while it runs.
    new WorkflowOrchestrator(
        instanceId,
        'StepContextSignalEngineTest.ProbeClaimBranch'
      )
      .execute(null);
    // CalloutStep branch: its signal stays Received while it runs (no claim).
    new WorkflowOrchestrator(
        instanceId,
        'StepContextSignalEngineTest.ProbeCalloutBranch'
      )
      .execute(null);

    Workflow_Step_Execution__c claimExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'StepContextSignalEngineTest.ProbeClaimBranch'
        AND Status__c = 'Completed'
    ];
    Workflow_Step_Execution__c calloutExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'StepContextSignalEngineTest.ProbeCalloutBranch'
        AND Status__c = 'Completed'
    ];

    System.assert(
      claimExec.Output__c.contains('Processing'),
      'A claiming parallel branch must flip its signal to Processing mid-step, got: ' +
      claimExec.Output__c
    );
    System.assert(
      calloutExec.Output__c.contains('Received'),
      'A CalloutStep branch must read its signal without claiming (stays Received), got: ' +
      calloutExec.Output__c
    );
  }

  // --- A CalloutStep that is also TimeoutConfigurable must run its synchronous
  // callout without the engine's pre-execute timeout DML triggering an
  // uncommitted-work exception. ----------------------------------------------

  public class CalloutTimeoutWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.CTSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null; // branch is terminal
    }
  }

  public class CTSpawnStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Kick');
      if (!s.isPresent()) {
        return StepResult.suspend();
      }
      return StepResult.split(
        new List<String>{ 'StepContextSignalEngineTest.CTCalloutTimeoutBranch' },
        s.payload
      );
    }
  }

  // Reads a signal (the reason CalloutStep exists) then makes a synchronous,
  // payload-driven callout. Also TimeoutConfigurable: the engine must defer its
  // timeout DML past execute() so this callout stays legal.
  public class CTCalloutTimeoutBranch implements WorkflowStep, CalloutStep, TimeoutConfigurable {
    public Integer getTimeoutSeconds() {
      return 60;
    }
    public StepResult execute(StepContext ctx) {
      ctx.getSignal('CTSig');
      HttpRequest req = new HttpRequest();
      req.setEndpoint('https://example.com/probe');
      req.setMethod('GET');
      HttpResponse res = new Http().send(req);
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'status' => res.getStatusCode() }
      );
    }
  }

  public class CTOkMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      res.setBody('{"ok":true}');
      return res;
    }
  }

  @isTest
  static void testCalloutStepWithTimeoutDoesNotHitUncommittedWork() {
    Test.setMock(HttpCalloutMock.class, new CTOkMock());
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.CalloutTimeoutWorkflow',
      'CTKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null); // spawn suspends on Kick
    WorkflowEngine.signal('CTKey', 'Kick', '{}');
    WorkflowEngine.signal('CTKey', 'CTSig', '{"v":1}');
    new WorkflowOrchestrator(instanceId).execute(null); // fan out

    // Run the CalloutStep + TimeoutConfigurable branch. Before the fix the
    // engine persisted Timeout_At__c before execute(), so this synchronous
    // callout threw "You have uncommitted work pending".
    new WorkflowOrchestrator(
        instanceId,
        'StepContextSignalEngineTest.CTCalloutTimeoutBranch'
      )
      .execute(null);

    Workflow_Step_Execution__c branchExec = [
      SELECT Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'StepContextSignalEngineTest.CTCalloutTimeoutBranch'
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    System.assertEquals(
      'Completed',
      branchExec.Status__c,
      'A CalloutStep+TimeoutConfigurable branch must complete its synchronous callout without an uncommitted-work exception'
    );
    System.assert(
      branchExec.Output__c != null && branchExec.Output__c.contains('200'),
      'callout response status should be recorded, got: ' + branchExec.Output__c
    );
  }

  // --- Unscoped getSignals() preserves arrival order after a claim (B) ------

  public class OrderWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.OrderSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'StepContextSignalEngineTest.OrderSpawnStep') {
        return 'StepContextSignalEngineTest.OrderJoinStep';
      }
      return null;
    }
  }

  public class OrderSpawnStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Kick');
      if (!s.isPresent()) {
        return StepResult.suspend();
      }
      return StepResult.split(
        new List<String>{
          'StepContextSignalEngineTest.OrderBranch',
          'StepContextSignalEngineTest.OrderOtherBranch'
        },
        s.payload
      );
    }
  }

  public class OrderBranch implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Claim the older 'Foo' first, then read the full list. The merged-in
      // claimed Foo must sort before the newer still-Received Bar.
      ctx.getSignal('Foo');
      String names = '';
      for (StepContext.Signal s : ctx.getSignals()) {
        names += s.name + ',';
      }
      return StepResult.complete(null, names);
    }
  }

  public class OrderOtherBranch implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'other');
    }
  }

  public class OrderJoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, ctx.inputJson);
    }
  }

  @isTest
  static void testUnscopedGetSignalsPreservesArrivalOrderAfterClaim() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.OrderWorkflow',
      'OrderKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);
    WorkflowEngine.signal('OrderKey', 'Kick', '{}');
    WorkflowEngine.signal('OrderKey', 'Foo', '{"foo":1}');
    WorkflowEngine.signal('OrderKey', 'Bar', '{"bar":1}');
    // Fan out.
    new WorkflowOrchestrator(instanceId).execute(null);

    new WorkflowOrchestrator(
        instanceId,
        'StepContextSignalEngineTest.OrderBranch'
      )
      .execute(null);

    Workflow_Step_Execution__c branchExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'StepContextSignalEngineTest.OrderBranch'
        AND Status__c = 'Completed'
    ];
    Integer fooIdx = branchExec.Output__c.indexOf('Foo');
    Integer barIdx = branchExec.Output__c.indexOf('Bar');
    System.assert(fooIdx >= 0, 'Foo must be present: ' + branchExec.Output__c);
    System.assert(barIdx >= 0, 'Bar must be present: ' + branchExec.Output__c);
    System.assert(
      fooIdx < barIdx,
      'The earlier-arriving Foo (claimed) must sort before the later Bar even after being merged back in, got: ' +
      branchExec.Output__c
    );
  }

  // --- getSignal falls back to an older signal when the newest is taken (E) -

  public class FallbackWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.FallbackSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (currentStepName == 'StepContextSignalEngineTest.FallbackSpawnStep') {
        return 'StepContextSignalEngineTest.FallbackJoinStep';
      }
      return null;
    }
  }

  public class FallbackSpawnStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Kick');
      if (!s.isPresent()) {
        return StepResult.suspend();
      }
      return StepResult.split(
        new List<String>{
          'StepContextSignalEngineTest.FallbackBranch',
          'StepContextSignalEngineTest.FallbackOtherBranch'
        },
        s.payload
      );
    }
  }

  public class FallbackBranch implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Foo');
      return StepResult.complete(null, s.isPresent() ? s.payload : 'absent');
    }
  }

  public class FallbackOtherBranch implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'other');
    }
  }

  public class FallbackJoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, ctx.inputJson);
    }
  }

  @isTest
  static void testGetSignalFallsBackToOlderWhenNewestUnavailable() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.FallbackWorkflow',
      'FallbackKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);
    WorkflowEngine.signal('FallbackKey', 'Kick', '{}');
    WorkflowEngine.signal('FallbackKey', 'Foo', '{"old":1}');
    WorkflowEngine.signal('FallbackKey', 'Foo', '{"new":1}');
    // Fan out.
    new WorkflowOrchestrator(instanceId).execute(null);

    // Simulate a racing sibling having already claimed the NEWEST Foo.
    Workflow_Signal__c newest = [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Signal_Name__c = 'Foo'
        AND Status__c = 'Received'
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    newest.Status__c = 'Processing';
    update newest;

    // The branch must fall back to the older still-Received Foo, not report absent.
    new WorkflowOrchestrator(
        instanceId,
        'StepContextSignalEngineTest.FallbackBranch'
      )
      .execute(null);

    Workflow_Step_Execution__c branchExec = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = 'StepContextSignalEngineTest.FallbackBranch'
        AND Status__c = 'Completed'
    ];
    System.assert(
      branchExec.Output__c.contains('old'),
      'getSignal must fall back to the older available Foo when the newest is unavailable, got: ' +
      branchExec.Output__c
    );
    System.assert(
      !branchExec.Output__c.contains('absent'),
      'getSignal must not report absent while a matching signal remains, got: ' +
      branchExec.Output__c
    );
  }

  // --- A CalloutStep branch must not consume a sibling's later claim (find 3) -

  public class CalloutSiblingWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.CalloutSiblingSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (
        currentStepName == 'StepContextSignalEngineTest.CalloutSiblingSpawnStep'
      ) {
        return 'StepContextSignalEngineTest.CalloutSiblingJoinStep';
      }
      return null;
    }
  }

  public class CalloutSiblingSpawnStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Kick');
      if (!s.isPresent()) {
        return StepResult.suspend();
      }
      return StepResult.split(
        new List<String>{
          'StepContextSignalEngineTest.CalloutSiblingBranch',
          'StepContextSignalEngineTest.CalloutSiblingOtherBranch'
        },
        s.payload
      );
    }
  }

  // CalloutStep branch reads 'Shared' without claiming, then a sibling claims
  // the same row (Processing) before this branch completes. At COMPLETE this
  // branch must NOT consume the now-Processing row.
  public class CalloutSiblingBranch implements WorkflowStep, CalloutStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Shared');
      if (s.isPresent()) {
        // Simulate a sibling claiming the same row mid-flight.
        update new Workflow_Signal__c(
          Id = s.signalId,
          Status__c = 'Processing'
        );
      }
      return StepResult.complete(null, 'done');
    }
  }

  public class CalloutSiblingOtherBranch implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'other');
    }
  }

  public class CalloutSiblingJoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, ctx.inputJson);
    }
  }

  @isTest
  static void testCalloutStepBranchDoesNotConsumeSiblingClaim() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.CalloutSiblingWorkflow',
      'CalloutSiblingKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);
    WorkflowEngine.signal('CalloutSiblingKey', 'Kick', '{}');
    WorkflowEngine.signal('CalloutSiblingKey', 'Shared', '{"s":1}');
    new WorkflowOrchestrator(instanceId).execute(null);

    new WorkflowOrchestrator(
        instanceId,
        'StepContextSignalEngineTest.CalloutSiblingBranch'
      )
      .execute(null);

    // The row the CalloutStep branch observed was claimed by a sibling mid-flight
    // (now Processing). The branch must leave it for the sibling, not consume it.
    System.assertEquals(
      'Processing',
      [
        SELECT Status__c
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Signal_Name__c = 'Shared'
      ]
      .Status__c,
      'A non-claiming (CalloutStep) branch must not consume a row a sibling has since claimed'
    );
  }

  // --- Bulk signal wakes parallel branches across instances (find 1) --------

  @isTest
  static void testBulkSignalWakesParallelBranchesAcrossInstances() {
    WorkflowEngine.disableQueueableInTest = true;
    Id i1 = WorkflowEngine.start(
      'StepContextSignalEngineTest.WakeWorkflow',
      'BulkWakeKey1',
      null
    );
    Id i2 = WorkflowEngine.start(
      'StepContextSignalEngineTest.WakeWorkflow',
      'BulkWakeKey2',
      null
    );
    // Spawns suspend for Go.
    new WorkflowOrchestrator(i1).execute(null);
    new WorkflowOrchestrator(i2).execute(null);
    WorkflowEngine.signal('BulkWakeKey1', 'Go', '{}');
    WorkflowEngine.signal('BulkWakeKey2', 'Go', '{}');
    // Fan out both.
    new WorkflowOrchestrator(i1).execute(null);
    new WorkflowOrchestrator(i2).execute(null);
    // Wait branches suspend on Resume.
    new WorkflowOrchestrator(
        i1,
        'StepContextSignalEngineTest.WakeWaitBranch'
      )
      .execute(null);
    new WorkflowOrchestrator(
        i2,
        'StepContextSignalEngineTest.WakeWaitBranch'
      )
      .execute(null);

    WorkflowEngine.enqueuedBranchKeys.clear();
    // One bulk signal for both parallel instances.
    WorkflowEngine.signal(
      new List<WorkflowEngine.SignalRequest>{
        new WorkflowEngine.SignalRequest('BulkWakeKey1', 'Resume', null),
        new WorkflowEngine.SignalRequest('BulkWakeKey2', 'Resume', null)
      }
    );

    System.assert(
      WorkflowEngine.enqueuedBranchKeys.contains(
        i1 + '::StepContextSignalEngineTest.WakeWaitBranch'
      ),
      'Bulk signal must wake instance 1 suspended branch by name. Keys: ' +
      WorkflowEngine.enqueuedBranchKeys
    );
    System.assert(
      WorkflowEngine.enqueuedBranchKeys.contains(
        i2 + '::StepContextSignalEngineTest.WakeWaitBranch'
      ),
      'Bulk signal must wake instance 2 suspended branch by name. Keys: ' +
      WorkflowEngine.enqueuedBranchKeys
    );
  }

  // --- Rollback must not release a sibling's claim on an observed row (find 1) -

  public class CalloutRollbackWorkflow implements WorkflowDefinition {
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.CalloutRollbackSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (
        currentStepName ==
        'StepContextSignalEngineTest.CalloutRollbackSpawnStep'
      ) {
        return 'StepContextSignalEngineTest.CalloutRollbackJoinStep';
      }
      return null;
    }
  }

  public class CalloutRollbackSpawnStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Kick');
      if (!s.isPresent()) {
        return StepResult.suspend();
      }
      return StepResult.split(
        new List<String>{
          'StepContextSignalEngineTest.CalloutRollbackBranch',
          'StepContextSignalEngineTest.CalloutRollbackOtherBranch'
        },
        s.payload
      );
    }
  }

  // CalloutStep branch observes 'Shared' without claiming, a sibling then claims
  // it (Processing), and this branch YIELDs. Rollback must leave the sibling's
  // claim intact because this branch never claimed the row.
  public class CalloutRollbackBranch implements WorkflowStep, CalloutStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal s = ctx.getSignal('Shared');
      if (s.isPresent() && String.isBlank(ctx.stepStateJson)) {
        // A sibling claims the same row mid-flight.
        update new Workflow_Signal__c(
          Id = s.signalId,
          Status__c = 'Processing'
        );
        // Yield without completing -- rollback runs but must not touch the claim.
        return StepResult.yield('{"seen":true}');
      }
      return StepResult.complete(null, 'done');
    }
  }

  public class CalloutRollbackOtherBranch implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, 'other');
    }
  }

  public class CalloutRollbackJoinStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(null, ctx.inputJson);
    }
  }

  @isTest
  static void testYieldDoesNotReleaseSiblingClaimOnObservedRow() {
    Id instanceId = WorkflowEngine.start(
      'StepContextSignalEngineTest.CalloutRollbackWorkflow',
      'CalloutRollbackKey',
      null
    );
    new WorkflowOrchestrator(instanceId).execute(null);
    WorkflowEngine.signal('CalloutRollbackKey', 'Kick', '{}');
    WorkflowEngine.signal('CalloutRollbackKey', 'Shared', '{"s":1}');
    new WorkflowOrchestrator(instanceId).execute(null);

    // The CalloutStep branch observes Shared, a sibling claims it, the branch
    // yields. Its rollback must NOT flip the sibling's claim back to Received.
    new WorkflowOrchestrator(
        instanceId,
        'StepContextSignalEngineTest.CalloutRollbackBranch'
      )
      .execute(null);

    System.assertEquals(
      'Processing',
      [
        SELECT Status__c
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Signal_Name__c = 'Shared'
      ]
      .Status__c,
      'A yielding branch must not roll back a row it only observed (now a sibling claim)'
    );
  }
}
