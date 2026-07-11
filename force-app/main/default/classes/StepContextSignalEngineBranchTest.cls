/**
 * Continuation of StepContextSignalEngineTest (issue #11): engine-level signal
 * surfacing/consumption coverage for parallel branches, CalloutStep branches,
 * arrival ordering, fallback/rollback, budget/offload, and end-to-end replay.
 * Split into a sibling @IsTest class to keep each type within the analyzer's
 * per-class size limits. Mock workflow/step definitions used only by these tests
 * were moved here alongside them and are referenced by their fully-qualified
 * string names, exactly as the engine resolves them.
 */
@IsTest
public class StepContextSignalEngineBranchTest {
  // --- A parallel branch suspended on a signal is woken by name (D) ---------

  public class WakeWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepContextSignalEngineBranchTest.WakeSpawnStep',
        'StepContextSignalEngineBranchTest.WakeJoinStep',
        'StepContextSignalEngineBranchTest.WakeWaitBranch',
        'StepContextSignalEngineBranchTest.WakeOtherBranch'
      };
    }
    public String getInitialStep() {
      return 'StepContextSignalEngineBranchTest.WakeSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (
        currentStepName == 'StepContextSignalEngineBranchTest.WakeSpawnStep'
      ) {
        return 'StepContextSignalEngineBranchTest.WakeJoinStep';
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
          'StepContextSignalEngineBranchTest.WakeWaitBranch',
          'StepContextSignalEngineBranchTest.WakeOtherBranch'
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

  @IsTest
  static void testParallelBranchSuspendedOnSignalIsWokenByName() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = WorkflowEngine.start(
        'StepContextSignalEngineBranchTest.WakeWorkflow',
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
          'StepContextSignalEngineBranchTest.WakeWaitBranch'
        )
        .execute(null);

      // Signal Resume: the suspended parallel branch must be enqueued BY NAME,
      // not via a blank-stepName enqueue that runStep would discard.
      WorkflowEngine.enqueuedBranchKeys.clear();
      WorkflowEngine.signal('WakeKey', 'Resume', '{}');

      System.assert(
        WorkflowEngine.enqueuedBranchKeys.contains(
          instanceId + '::StepContextSignalEngineBranchTest.WakeWaitBranch'
        ),
        'A parallel branch suspended on a signal must be woken by its step name. Keys: ' +
        WorkflowEngine.enqueuedBranchKeys
      );
    }
  }

  // --- CalloutStep branches read without claiming (C) -----------------------

  public class ProbeWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepContextSignalEngineBranchTest.ProbeSpawnStep',
        'StepContextSignalEngineBranchTest.ProbeJoinStep',
        'StepContextSignalEngineBranchTest.ProbeClaimBranch',
        'StepContextSignalEngineBranchTest.ProbeCalloutBranch'
      };
    }
    public String getInitialStep() {
      return 'StepContextSignalEngineBranchTest.ProbeSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (
        currentStepName == 'StepContextSignalEngineBranchTest.ProbeSpawnStep'
      ) {
        return 'StepContextSignalEngineBranchTest.ProbeJoinStep';
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
          'StepContextSignalEngineBranchTest.ProbeClaimBranch',
          'StepContextSignalEngineBranchTest.ProbeCalloutBranch'
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

  @IsTest
  static void testCalloutStepBranchReadsWithoutClaiming() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = WorkflowEngine.start(
        'StepContextSignalEngineBranchTest.ProbeWorkflow',
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
          'StepContextSignalEngineBranchTest.ProbeClaimBranch'
        )
        .execute(null);
      // CalloutStep branch: its signal stays Received while it runs (no claim).
      new WorkflowOrchestrator(
          instanceId,
          'StepContextSignalEngineBranchTest.ProbeCalloutBranch'
        )
        .execute(null);

      Workflow_Step_Execution__c claimExec = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'StepContextSignalEngineBranchTest.ProbeClaimBranch'
          AND Status__c = 'Completed'
      ];
      Workflow_Step_Execution__c calloutExec = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'StepContextSignalEngineBranchTest.ProbeCalloutBranch'
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
  }

  // --- A CalloutStep that is also TimeoutConfigurable must run its synchronous
  // callout without the engine's pre-execute timeout DML triggering an
  // uncommitted-work exception. ----------------------------------------------

  public class CalloutTimeoutWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepContextSignalEngineBranchTest.CTSpawnStep',
        'StepContextSignalEngineBranchTest.CTCalloutTimeoutBranch'
      };
    }
    public String getInitialStep() {
      return 'StepContextSignalEngineBranchTest.CTSpawnStep';
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
        new List<String>{
          'StepContextSignalEngineBranchTest.CTCalloutTimeoutBranch'
        },
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

  @IsTest
  static void testCalloutStepWithTimeoutDoesNotHitUncommittedWork() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Test.setMock(HttpCalloutMock.class, new CTOkMock());
      // Drive setup synchronously with queueable suppressed so we control every
      // hop without auto-enqueuing noise.
      WorkflowEngine.disableQueueableInTest = true;
      Id instanceId = WorkflowEngine.start(
        'StepContextSignalEngineBranchTest.CalloutTimeoutWorkflow',
        'CTKey',
        null
      );
      new WorkflowOrchestrator(instanceId).execute(null); // spawn suspends on Kick
      WorkflowEngine.signal('CTKey', 'Kick', '{}');
      WorkflowEngine.signal('CTKey', 'CTSig', '{"v":1}');
      new WorkflowOrchestrator(instanceId).execute(null); // fan out

      // Run the CalloutStep + TimeoutConfigurable branch via the async Queueable
      // path. In production each orchestrator hop is a separate Queueable
      // transaction, so the callout never sees uncommitted work from prior hops.
      // Test.stopTest() replicates that: it executes enqueued jobs in a fresh
      // async context where prior test DML appears committed. Calling execute(null)
      // directly (synchronously) would leave all the setup DML uncommitted and the
      // callout would throw "You have uncommitted work pending" regardless of the
      // deferPreExecDml fix — the fix only removes DML *within* the current
      // runStep call, not DML from previous calls in the same test transaction.
      WorkflowEngine.disableQueueableInTest = false;
      Test.startTest();
      System.enqueueJob(
        new WorkflowOrchestrator(
          instanceId,
          'StepContextSignalEngineBranchTest.CTCalloutTimeoutBranch'
        )
      );
      Test.stopTest();

      Workflow_Step_Execution__c branchExec = [
        SELECT Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'StepContextSignalEngineBranchTest.CTCalloutTimeoutBranch'
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
        'callout response status should be recorded, got: ' +
        branchExec.Output__c
      );
    }
  }

  // --- Unscoped getSignals() preserves arrival order after a claim (B) ------

  public class OrderWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepContextSignalEngineBranchTest.OrderSpawnStep',
        'StepContextSignalEngineBranchTest.OrderJoinStep',
        'StepContextSignalEngineBranchTest.OrderBranch',
        'StepContextSignalEngineBranchTest.OrderOtherBranch'
      };
    }
    public String getInitialStep() {
      return 'StepContextSignalEngineBranchTest.OrderSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (
        currentStepName == 'StepContextSignalEngineBranchTest.OrderSpawnStep'
      ) {
        return 'StepContextSignalEngineBranchTest.OrderJoinStep';
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
          'StepContextSignalEngineBranchTest.OrderBranch',
          'StepContextSignalEngineBranchTest.OrderOtherBranch'
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

  @IsTest
  static void testUnscopedGetSignalsPreservesArrivalOrderAfterClaim() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = WorkflowEngine.start(
        'StepContextSignalEngineBranchTest.OrderWorkflow',
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
          'StepContextSignalEngineBranchTest.OrderBranch'
        )
        .execute(null);

      Workflow_Step_Execution__c branchExec = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'StepContextSignalEngineBranchTest.OrderBranch'
          AND Status__c = 'Completed'
      ];
      Integer fooIdx = branchExec.Output__c.indexOf('Foo');
      Integer barIdx = branchExec.Output__c.indexOf('Bar');
      System.assert(
        fooIdx >= 0,
        'Foo must be present: ' + branchExec.Output__c
      );
      System.assert(
        barIdx >= 0,
        'Bar must be present: ' + branchExec.Output__c
      );
      System.assert(
        fooIdx < barIdx,
        'The earlier-arriving Foo (claimed) must sort before the later Bar even after being merged back in, got: ' +
        branchExec.Output__c
      );
    }
  }

  // --- getSignal falls back to an older signal when the newest is taken (E) -

  public class FallbackWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepContextSignalEngineBranchTest.FallbackSpawnStep',
        'StepContextSignalEngineBranchTest.FallbackJoinStep',
        'StepContextSignalEngineBranchTest.FallbackBranch',
        'StepContextSignalEngineBranchTest.FallbackOtherBranch'
      };
    }
    public String getInitialStep() {
      return 'StepContextSignalEngineBranchTest.FallbackSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (
        currentStepName == 'StepContextSignalEngineBranchTest.FallbackSpawnStep'
      ) {
        return 'StepContextSignalEngineBranchTest.FallbackJoinStep';
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
          'StepContextSignalEngineBranchTest.FallbackBranch',
          'StepContextSignalEngineBranchTest.FallbackOtherBranch'
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

  @IsTest
  static void testGetSignalFallsBackToOlderWhenNewestUnavailable() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = WorkflowEngine.start(
        'StepContextSignalEngineBranchTest.FallbackWorkflow',
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
          'StepContextSignalEngineBranchTest.FallbackBranch'
        )
        .execute(null);

      Workflow_Step_Execution__c branchExec = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'StepContextSignalEngineBranchTest.FallbackBranch'
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
  }

  // --- A CalloutStep branch must not consume a sibling's later claim (find 3) -

  public class CalloutSiblingWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepContextSignalEngineBranchTest.CalloutSiblingSpawnStep',
        'StepContextSignalEngineBranchTest.CalloutSiblingJoinStep',
        'StepContextSignalEngineBranchTest.CalloutSiblingBranch',
        'StepContextSignalEngineBranchTest.CalloutSiblingOtherBranch'
      };
    }
    public String getInitialStep() {
      return 'StepContextSignalEngineBranchTest.CalloutSiblingSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (
        currentStepName ==
        'StepContextSignalEngineBranchTest.CalloutSiblingSpawnStep'
      ) {
        return 'StepContextSignalEngineBranchTest.CalloutSiblingJoinStep';
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
          'StepContextSignalEngineBranchTest.CalloutSiblingBranch',
          'StepContextSignalEngineBranchTest.CalloutSiblingOtherBranch'
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

  @IsTest
  static void testCalloutStepBranchDoesNotConsumeSiblingClaim() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = WorkflowEngine.start(
        'StepContextSignalEngineBranchTest.CalloutSiblingWorkflow',
        'CalloutSiblingKey',
        null
      );
      new WorkflowOrchestrator(instanceId).execute(null);
      WorkflowEngine.signal('CalloutSiblingKey', 'Kick', '{}');
      WorkflowEngine.signal('CalloutSiblingKey', 'Shared', '{"s":1}');
      new WorkflowOrchestrator(instanceId).execute(null);

      new WorkflowOrchestrator(
          instanceId,
          'StepContextSignalEngineBranchTest.CalloutSiblingBranch'
        )
        .execute(null);

      // The row the CalloutStep branch observed was claimed by a sibling mid-flight
      // (now Processing). The branch must leave it for the sibling, not consume it.
      System.assertEquals(
        'Processing',
        [
          SELECT Status__c
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId AND Signal_Name__c = 'Shared'
        ]
        .Status__c,
        'A non-claiming (CalloutStep) branch must not consume a row a sibling has since claimed'
      );
    }
  }

  // --- Bulk signal wakes parallel branches across instances (find 1) --------

  @IsTest
  static void testBulkSignalWakesParallelBranchesAcrossInstances() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;
      Id i1 = WorkflowEngine.start(
        'StepContextSignalEngineBranchTest.WakeWorkflow',
        'BulkWakeKey1',
        null
      );
      Id i2 = WorkflowEngine.start(
        'StepContextSignalEngineBranchTest.WakeWorkflow',
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
          'StepContextSignalEngineBranchTest.WakeWaitBranch'
        )
        .execute(null);
      new WorkflowOrchestrator(
          i2,
          'StepContextSignalEngineBranchTest.WakeWaitBranch'
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
          i1 + '::StepContextSignalEngineBranchTest.WakeWaitBranch'
        ),
        'Bulk signal must wake instance 1 suspended branch by name. Keys: ' +
        WorkflowEngine.enqueuedBranchKeys
      );
      System.assert(
        WorkflowEngine.enqueuedBranchKeys.contains(
          i2 + '::StepContextSignalEngineBranchTest.WakeWaitBranch'
        ),
        'Bulk signal must wake instance 2 suspended branch by name. Keys: ' +
        WorkflowEngine.enqueuedBranchKeys
      );
    }
  }

  // --- Rollback must not release a sibling's claim on an observed row (find 1) -

  public class CalloutRollbackWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepContextSignalEngineBranchTest.CalloutRollbackSpawnStep',
        'StepContextSignalEngineBranchTest.CalloutRollbackJoinStep',
        'StepContextSignalEngineBranchTest.CalloutRollbackBranch',
        'StepContextSignalEngineBranchTest.CalloutRollbackOtherBranch'
      };
    }
    public String getInitialStep() {
      return 'StepContextSignalEngineBranchTest.CalloutRollbackSpawnStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      if (
        currentStepName ==
        'StepContextSignalEngineBranchTest.CalloutRollbackSpawnStep'
      ) {
        return 'StepContextSignalEngineBranchTest.CalloutRollbackJoinStep';
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
          'StepContextSignalEngineBranchTest.CalloutRollbackBranch',
          'StepContextSignalEngineBranchTest.CalloutRollbackOtherBranch'
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

  @IsTest
  static void testYieldDoesNotReleaseSiblingClaimOnObservedRow() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = WorkflowEngine.start(
        'StepContextSignalEngineBranchTest.CalloutRollbackWorkflow',
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
          'StepContextSignalEngineBranchTest.CalloutRollbackBranch'
        )
        .execute(null);

      System.assertEquals(
        'Processing',
        [
          SELECT Status__c
          FROM Workflow_Signal__c
          WHERE Workflow_Instance__c = :instanceId AND Signal_Name__c = 'Shared'
        ]
        .Status__c,
        'A yielding branch must not roll back a row it only observed (now a sibling claim)'
      );
    }
  }

  // --- A named lookup must not falsely report absence after the row budget is
  // spent (a step that suspends as if absent would strand). ------------------

  public class BudgetWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepContextSignalEngineBranchTest.BudgetReadStep'
      };
    }
    public String getInitialStep() {
      return 'StepContextSignalEngineBranchTest.BudgetReadStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null; // terminal
    }
  }

  public class BudgetReadStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      // Spend the row budget on a noisy name, then probe a different name via
      // both the latest lookup and the list accessor: neither may report a
      // false absence even though the budget is now exhausted.
      List<StepContext.Signal> noise = ctx.getSignals('Noise');
      Boolean importantPresent = ctx.hasSignal('Important');
      List<StepContext.Signal> importantList = ctx.getSignals('Important');
      return StepResult.complete(
        null,
        new Map<String, Object>{
          'noiseSeen' => noise.size(),
          'importantPresent' => importantPresent,
          'importantListSize' => importantList.size()
        }
      );
    }
  }

  @IsTest
  static void testNamedLookupNotFalselyAbsentAfterBudgetExhausted() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Shrink the cap so a single Noise row exhausts the budget.
      WorkflowEngine.SERIAL_SIGNAL_ROW_CAP = 1;

      Id instanceId = WorkflowEngine.start(
        'StepContextSignalEngineBranchTest.BudgetWorkflow',
        'BudgetKey',
        null
      );

      // Land signals as Received before the step runs: two of the noisy name and
      // one of the name the step probes after exhausting its budget.
      insert new List<Workflow_Signal__c>{
        new Workflow_Signal__c(
          Workflow_Instance__c = instanceId,
          Signal_Name__c = 'Noise',
          Payload__c = 'n1',
          Status__c = 'Received'
        ),
        new Workflow_Signal__c(
          Workflow_Instance__c = instanceId,
          Signal_Name__c = 'Noise',
          Payload__c = 'n2',
          Status__c = 'Received'
        ),
        new Workflow_Signal__c(
          Workflow_Instance__c = instanceId,
          Signal_Name__c = 'Important',
          Payload__c = 'imp',
          Status__c = 'Received'
        )
      };

      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Step_Execution__c stepExec = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'StepContextSignalEngineBranchTest.BudgetReadStep'
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      System.assert(
        stepExec.Output__c != null &&
        stepExec.Output__c.contains('"noiseSeen":1'),
        'The noisy read should have been capped to one row, got: ' +
        stepExec.Output__c
      );
      System.assert(
        stepExec.Output__c.contains('"importantPresent":true'),
        'A named lookup after the row budget is spent must still find a Received signal (no false absence), got: ' +
        stepExec.Output__c
      );
      System.assert(
        stepExec.Output__c.contains('"importantListSize":1'),
        'A list accessor after the row budget is spent must still return the pending signal (no empty false absence), got: ' +
        stepExec.Output__c
      );
    }
  }

  // --- Offloaded signal payloads resolve (in bulk) for list accessors --------

  public class OffloadWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepContextSignalEngineBranchTest.OffloadReadStep'
      };
    }
    public String getInitialStep() {
      return 'StepContextSignalEngineBranchTest.OffloadReadStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  public class OffloadReadStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      List<StepContext.Signal> sigs = ctx.getSignals('Big');
      List<Integer> lens = new List<Integer>();
      for (StepContext.Signal s : sigs) {
        lens.add(s.payload == null ? -1 : s.payload.length());
      }
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'lens' => lens }
      );
    }
  }

  @IsTest
  static void testOffloadedSignalPayloadsResolvedForListRead() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Id instanceId = WorkflowEngine.start(
        'StepContextSignalEngineBranchTest.OffloadWorkflow',
        'OffloadKey',
        null
      );
      // Two signals whose payloads exceed the offload threshold, so each is stored
      // as a ContentVersion marker rather than inline.
      String big1 = 'a'.repeat(100001);
      String big2 = 'b'.repeat(100001);
      String marker1 = WorkflowEngine.savePayloadIfNeeded(
        instanceId,
        big1,
        'Big1'
      );
      String marker2 = WorkflowEngine.savePayloadIfNeeded(
        instanceId,
        big2,
        'Big2'
      );
      System.assert(
        marker1.startsWith('{"$attachmentId":'),
        'payload should have been offloaded to a marker'
      );
      insert new List<Workflow_Signal__c>{
        new Workflow_Signal__c(
          Workflow_Instance__c = instanceId,
          Signal_Name__c = 'Big',
          Payload__c = marker1,
          Status__c = 'Received'
        ),
        new Workflow_Signal__c(
          Workflow_Instance__c = instanceId,
          Signal_Name__c = 'Big',
          Payload__c = marker2,
          Status__c = 'Received'
        )
      };

      new WorkflowOrchestrator(instanceId).execute(null);

      Workflow_Step_Execution__c stepExec = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = 'StepContextSignalEngineBranchTest.OffloadReadStep'
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      // Both offloaded payloads must resolve to their full content (length 100001),
      // not the short marker string -- proving bulk resolution returned the right
      // value per row.
      System.assert(
        stepExec.Output__c.contains('100001,100001') ||
        stepExec.Output__c.contains('100001, 100001'),
        'Offloaded signal payloads must resolve to full content for a list read, got: ' +
        stepExec.Output__c
      );
    }
  }

  public class E2EYieldWaitStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
      if (ctx.shouldYield()) {
        return StepResult.suspend();
      }
      if (ctx.getSignal('E2EGo').isPresent()) {
        return StepResult.complete(null, 'completed');
      }
      return StepResult.suspend();
    }
  }

  public class E2EYieldWaitWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'StepContextSignalEngineBranchTest.E2EYieldWaitStep'
      };
    }
    public String getInitialStep() {
      return 'StepContextSignalEngineBranchTest.E2EYieldWaitStep';
    }
    public String getNextStep(String currentStepName, StepResult stepResult) {
      return null;
    }
  }

  @IsTest
  static void testE2EAutoReplayPreArrivedSignal() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      WorkflowEngine.disableQueueableInTest = true;

      // Publish signal BEFORE starting the workflow
      WorkflowEngine.signal('E2E-CorrKey-999', 'E2EGo', '{"ready":true}');

      // Verify it is captured as Unrouted
      List<Workflow_Signal__c> unrouted = [
        SELECT Status__c, Correlation_Key__c
        FROM Workflow_Signal__c
        WHERE Correlation_Key__c = 'E2E-CorrKey-999'
      ];
      System.assertEquals(1, unrouted.size());
      System.assertEquals('Unrouted', unrouted[0].Status__c);

      // Start the workflow
      Id instanceId = WorkflowEngine.start(
        'StepContextSignalEngineBranchTest.E2EYieldWaitWorkflow',
        'E2E-CorrKey-999',
        null
      );

      // Run the orchestrator manually.
      // The step runs, returns suspend(), and the suspension immediately redelivers the pre-arrived signal, reparents it, and resumes the instance.
      new WorkflowOrchestrator(instanceId).execute(null);

      // Verify the signal is now Received and mapped to the instance
      Workflow_Signal__c reloadedSig = [
        SELECT Status__c, Workflow_Instance__c
        FROM Workflow_Signal__c
        WHERE Id = :unrouted[0].Id
      ];
      System.assertEquals('Received', reloadedSig.Status__c);
      System.assertEquals(instanceId, reloadedSig.Workflow_Instance__c);

      // And verify the instance was woke up and status is Running
      Workflow_Instance__c reloadedInst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals('Running', reloadedInst.Status__c);

      // Run the orchestrator again to execute the step with the signal present
      new WorkflowOrchestrator(instanceId).execute(null);

      // Assert that the workflow reaches completion
      Workflow_Instance__c finalInst = [
        SELECT Status__c, Current_Step__c
        FROM Workflow_Instance__c
        WHERE Id = :instanceId
      ];
      System.assertEquals(
        'Completed',
        finalInst.Status__c,
        'Workflow should have reached completion'
      );
    }
  }
}
