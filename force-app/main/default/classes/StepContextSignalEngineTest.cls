/**
 * Engine-level coverage for issue #11: the engine surfaces pending signals into
 * StepContext and ties consumption to the step's successful (COMPLETE)
 * transition.
 */
@IsTest
public class StepContextSignalEngineTest {
  // --- Re-observation safety (AC4a) ---------------------------------------

  public class ReObserveWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'StepContextSignalEngineTest.ReObserveStep' };
    }
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

  @IsTest
  static void testObservedSignalSurvivesYieldUntilComplete() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
          WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Received'
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
          WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Received'
        ],
        'Signal must be consumed once the observing step completes'
      );
    }
  }

  // --- Cancel control signals are never surfaced (AC5) --------------------

  public class PlainWaitWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'StepContextSignalEngineTest.PlainWaitStep' };
    }
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

  @IsTest
  static void testCancelSignalIsNotSurfacedAsReadablePayload() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  // --- In-flight duplicate consumed by observed-name re-query (AC4b) -------

  public class InFlightDupWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'StepContextSignalEngineTest.InFlightDupStep' };
    }
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

  @IsTest
  static void testInFlightDuplicateConsumedByName() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
          WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Received'
        ],
        'A same-name duplicate delivered during execution must also be consumed'
      );
      System.assertEquals(
        2,
        [
          SELECT COUNT()
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Consumed'
        ]
      );
    }
  }

  // --- SPLIT consumes the spawning step's observed signals (AC4) ----------

  public class SplitSignalWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepContextSignalEngineTest.SignalThenSplitStep',
        'StepContextSignalEngineTest.SplitJoinStep',
        'StepContextSignalEngineTest.BranchAStep',
        'StepContextSignalEngineTest.BranchBStep'
      };
    }
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

  @IsTest
  static void testSplitConsumesSpawningStepSignals() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
          WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Received'
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
  }

  // --- A name probed absent must not consume a later arrival (AC4b nuance) -

  public class ProbeAbsentWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{ 'StepContextSignalEngineTest.ProbeAbsentStep' };
    }
    public String getInitialStep() {
      return 'StepContextSignalEngineTest.ProbeAbsentStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class ProbeAbsentStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      StepContext.Signal triggerSig = ctx.getSignal('Trigger');
      if (!triggerSig.isPresent()) {
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

  @IsTest
  static void testProbeAbsentNamePreservesLaterSignal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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

  // --- Atomic claim-at-read for parallel branches (AC6) --------------------

  public class ClaimRaceWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepContextSignalEngineTest.ClaimRaceSpawnStep',
        'StepContextSignalEngineTest.ClaimRaceJoinStep',
        'StepContextSignalEngineTest.ClaimBranchAlpha',
        'StepContextSignalEngineTest.ClaimBranchBeta'
      };
    }
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
  @IsTest
  static void testParallelBranchAtomicClaimAtRead() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  /**
   * Verifies that a completing parallel branch consumes ONLY its own claimed
   * signal and never a sibling branch's claim of the same name. A sibling that
   * has not durably finished (its claim is still Processing, or was rolled back
   * to Received after a yield/retry) must keep its signal so it can finish.
   */
  @IsTest
  static void testParallelCompleteDoesNotConsumeSiblingClaim() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }

  // --- Guard-then-read returns the claimed payload (StepContext cache merge) --

  public class GuardReadWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepContextSignalEngineTest.GuardReadSpawnStep',
        'StepContextSignalEngineTest.GuardReadJoinStep',
        'StepContextSignalEngineTest.GuardReadBranch',
        'StepContextSignalEngineTest.GuardReadOtherBranch'
      };
    }
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

  @IsTest
  static void testParallelGuardThenReadReturnsClaimedPayload() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
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
  }
}
