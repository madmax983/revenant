/**
 * WorkflowTestHarness — a test-only utility that drives a started WorkflowDefinition
 * instance to its next stable state (Completed, Failed, Compensated, Cancelled, or a
 * genuine Suspended-for-signal wait) and hands the author an inspectable result.
 *
 * It exists so workflow/saga authors can test a DAG, branches, sagas, and signals
 * without hand-pumping the orchestrator chain, the platform-event bus, or the
 * sleep/timeout jobs. It is annotated @IsTest, so it is callable only from test
 * context and adds no production code path.
 *
 * Design guarantees (see issue #3 acceptance criteria):
 *  - It only invokes the already-shipped execution paths: WorkflowEngine.runStep
 *    (the same entry point WorkflowOrchestrator uses), WorkflowEngine.handleCrash
 *    (the same path WorkflowFinalizer uses on a step crash), WorkflowEngine.signal,
 *    and WorkflowTimeoutJob. It never constructs WorkflowOrchestrator, never changes
 *    the Queueable chain handoff, and never mutates Status__c / Current_Step__c (or
 *    the append-only Workflow_Step_Execution__c audit records) directly.
 *  - It auto-pumps parallel scatter-gather branches and the rejoin.
 *  - It auto-delivers pending Workflow_Event__e platform events.
 *  - It deterministically resumes sleep/retry waits through the engine's own
 *    runStep resume path (the path WorkflowSleepJob enqueues) and can fire the
 *    shipped WorkflowTimeoutJob for watchdog-timeout waits.
 *  - It is bounded by a caller-supplied max-hop budget and fails the test with a
 *    clear message if the workflow has not stabilized.
 *
 * Usage note — the initial Queueable: WorkflowEngine.start() always enqueues the
 * first orchestrator in test context (it does not consult disableQueueableInTest),
 * and there is no Apex API to drain a queued job. That job runs at the next
 * Test.stopTest(). The harness keeps this harmless by driving synchronously and by
 * suppressing every enqueue it can (disableQueueableInTest), so the only stray run
 * re-enters the instance's current step — which is a no-op once terminal and an
 * idempotent re-suspend while parked on a suspend-style step. For workflows whose
 * suspended step is not idempotent, flush that job by calling Test.stopTest()
 * before driving past the suspend.
 *
 * Implementation note: this class is the public facade. The heavy internal
 * machinery is split into cohesive, test-only collaborator classes that operate on
 * a shared WorkflowHarnessContext (holding the per-run state): WorkflowHarnessDriver
 * (hop loops), WorkflowHarnessAdvancer / WorkflowHarnessStepRunner (single-hop
 * execution), WorkflowHarnessSleep (sleep/retry markers), WorkflowHarnessWaitFinder
 * (locating a parked instance), WorkflowHarnessSleepFire (firing sleep/retry),
 * WorkflowHarnessFaults (fault injection), WorkflowHarnessCore (low-level SOQL/DML +
 * Result assembly) and WorkflowHarnessCron (CronTrigger lookups). Splitting keeps
 * each unit small and readable without changing any observable behavior.
 */
@IsTest
public inherited sharing class WorkflowTestHarness {
  /** Default hop budget if the caller does not supply one. */
  public static final Integer DEFAULT_MAX_HOPS = 100;

  private final WorkflowHarnessContext ctx;

  /**
   * When true, the harness stops auto-resuming sleep/retry waits (it no longer
   * skips the wake timer for a Suspended-with-Sleep_Until__c instance), so the
   * author can assert the parked sleeping/retrying state before firing it
   * explicitly. The value is forwarded into the shared context (which the driving
   * collaborators read) on every advancing call.
   */
  public Boolean disableAutoTimeSkip = false;

  /**
   * Returns the shared context after forwarding the caller-settable
   * disableAutoTimeSkip flag into it, so the collaborators that read the context
   * see the author's latest choice at drive time. Used by every advancing call.
   *
   * @return The shared harness context with the current flags applied.
   */
  private WorkflowHarnessContext ctxSynced() {
    ctx.disableAutoTimeSkip = disableAutoTimeSkip;
    return ctx;
  }

  /** @description Signals a harness failure, e.g. a workflow that never stabilized within the hop budget. */
  public class HarnessException extends Exception {
  }

  /** An inspectable snapshot of the root instance after driving. */
  public class Result {
    public Id instanceId;
    /** Final Status__c of the root instance. */
    public String status;
    /** Resolved final Output__c of the root instance (offloaded payloads inlined). */
    public String output;
    /** Every step execution name for the root instance, in append-only audit order. */
    public List<String> executedSteps;
    /** Forward steps that completed, in order (excludes _Compensate records). */
    public List<String> completedSteps;
    /** Compensation steps that ran, in order — the LIFO compensate() sequence. */
    public List<String> compensatedSteps;
    /** Total hops the harness consumed across all calls on this instance. */
    public Integer hops;
    public Boolean isTerminal;
    public Boolean isSuspended;
    public Boolean isSleeping;
    public Boolean isAwaitingRetry;

    /**
     * @description True if the named step appears anywhere in the audit trail.
     * @param stepName The step name to look for.
     * @return True if the step was executed on this instance.
     */
    public Boolean reachedStep(String stepName) {
      return executedSteps != null && executedSteps.contains(stepName);
    }
  }

  /**
   * @description Creates a harness bound to a started workflow instance and
   * suppresses the engine's in-test Queueable hand-offs so the harness can drive
   * synchronously.
   * @param instanceId The Workflow_Instance__c id to drive.
   */
  public WorkflowTestHarness(Id instanceId) {
    this.ctx = WorkflowHarnessContext.forInstance(instanceId);
    // Keep the async chain quiet: drive synchronously and suppress the engine's
    // in-test Queueable hand-offs so they cannot double-run or pile up against the
    // queueable limit. The harness invokes runStep directly instead.
    WorkflowEngine.disableQueueableInTest = true;
  }

  /**
   * Advances the instance by exactly one logical hop and returns the current
   * result. Unlike drive(), this never throws when work remains — it lets the
   * caller decide whether to keep going (via another step() or drive()). If
   * nothing is advanceable, it returns the current result unchanged.
   *
   * @return The current inspectable result after at most one hop.
   */
  public Result step() {
    return WorkflowHarnessDriver.stepOnce(ctxSynced());
  }

  /**
   * Drives until the named step appears in the append-only audit trail, then
   * stops — useful for asserting intermediate state between specific steps
   * without knowing the exact hop count. Returns as soon as the step appears
   * (whether Completed or still Running/Retrying), or when the instance
   * stabilizes naturally (terminal or signal-suspend), whichever comes first.
   * Throws HarnessException if the step is never reached within maxHops.
   *
   * @param stepName The step name to drive toward.
   * @return The result once the step is reached or the instance stabilizes.
   */
  public Result driveUntilStep(String stepName) {
    return WorkflowHarnessDriver.driveUntilStep(
      ctxSynced(),
      stepName,
      DEFAULT_MAX_HOPS
    );
  }

  /**
   * @description Drives until the named step appears in the audit trail, bounded
   * by an explicit hop budget.
   * @param stepName The step name to drive toward.
   * @param maxHops The maximum number of hops to consume.
   * @return The result once the step is reached or the instance stabilizes.
   */
  public Result driveUntilStep(String stepName, Integer maxHops) {
    return WorkflowHarnessDriver.driveUntilStep(ctxSynced(), stepName, maxHops);
  }

  /**
   * @description Drives to the next stable state using the default hop budget.
   * @return The result at the next terminal or signal-suspend state.
   */
  public Result drive() {
    return WorkflowHarnessDriver.drive(ctxSynced(), DEFAULT_MAX_HOPS);
  }

  /**
   * Drives the instance (and any child workflows it spawns) until nothing can
   * advance — i.e. it reaches a terminal state or a genuine wait-for-signal
   * suspend. Throws HarnessException if it cannot stabilize within maxHops.
   *
   * @param maxHops The maximum number of hops to consume.
   * @return The result at the next terminal or signal-suspend state.
   */
  public Result drive(Integer maxHops) {
    return WorkflowHarnessDriver.drive(ctxSynced(), maxHops);
  }

  /**
   * Delivers an external signal to a workflow (by correlation key or instance Id)
   * and resumes driving — the human-in-the-loop / external-signal affordance. Uses
   * the shipped WorkflowEngine.signal path; no manual event-bus plumbing.
   *
   * @param correlationKey The correlation key or instance Id to target.
   * @param signalName The signal name to deliver.
   * @param payload The signal payload.
   * @return The result after delivering the signal and resuming driving.
   */
  public Result injectSignal(
    String correlationKey,
    String signalName,
    String payload
  ) {
    ctx.scannedInstanceIds.clear();
    WorkflowEngine.signal(correlationKey, signalName, payload);
    return WorkflowHarnessDriver.drive(ctxSynced(), DEFAULT_MAX_HOPS);
  }

  /**
   * Fires the shipped WorkflowTimeoutJob against a step on the root instance,
   * reproducing a watchdog timeout, then resumes driving (so a timeout that
   * triggers compensation is pumped to its terminal state). The author never
   * hand-mutates Status__c / Current_Step__c to simulate the timeout.
   *
   * @param stepName The step whose watchdog timeout to fire.
   * @return The result after firing the timeout and resuming driving.
   */
  public Result fireTimeout(String stepName) {
    return fireTimeout(stepName, DEFAULT_MAX_HOPS);
  }

  /**
   * @description Fires the shipped WorkflowTimeoutJob against a step, bounded by
   * an explicit hop budget, then resumes driving.
   * @param stepName The step whose watchdog timeout to fire.
   * @param maxHops The maximum number of hops to consume while resuming.
   * @return The result after firing the timeout and resuming driving.
   */
  public Result fireTimeout(String stepName, Integer maxHops) {
    new WorkflowTimeoutJob(ctx.rootInstanceId, stepName).executeInternal();
    return WorkflowHarnessDriver.drive(ctxSynced(), maxHops);
  }

  /**
   * @description Returns the current inspectable result without advancing the
   * workflow.
   * @return The current inspectable result.
   */
  public Result inspect() {
    return WorkflowHarnessCore.buildResult(ctx);
  }

  /**
   * @description Registers a persistent fault so the named step always throws
   * the given message when executed, until faults are cleared.
   * @param stepName The step to fault.
   * @param message The exception message to throw.
   * @return This harness, for chaining.
   */
  public WorkflowTestHarness failStep(String stepName, String message) {
    new WorkflowHarnessFaults(ctx).registerFault(stepName, message);
    return this;
  }

  /**
   * @description Registers a one-shot fault so the named step throws once and
   * then succeeds on the subsequent retry.
   * @param stepName The step to fault once.
   * @param message The exception message to throw.
   * @return This harness, for chaining.
   */
  public WorkflowTestHarness failStepOnce(String stepName, String message) {
    new WorkflowHarnessFaults(ctx).registerFaultOnce(stepName, message);
    return this;
  }

  /**
   * @description Registers a fault so the named step throws for a fixed number
   * of executions before succeeding, to exercise retry policies.
   * @param stepName The step to fault.
   * @param message The exception message to throw.
   * @param failCount The number of executions to fail before succeeding.
   * @return This harness, for chaining.
   */
  public WorkflowTestHarness failStep(
    String stepName,
    String message,
    Integer failCount
  ) {
    new WorkflowHarnessFaults(ctx).registerFault(stepName, message, failCount);
    return this;
  }

  /**
   * @description Clears all registered faults so steps execute normally again.
   * @return This harness, for chaining.
   */
  public WorkflowTestHarness clearFaults() {
    new WorkflowHarnessFaults(ctx).removeFaults();
    return this;
  }

  /**
   * @description Fires a parked sleep wait on the named step through the
   * engine's resume path, then resumes driving.
   * @param stepName The sleeping step to wake.
   * @return The result after waking the sleep and resuming driving.
   */
  public Result fireSleep(String stepName) {
    return WorkflowHarnessSleepFire.fireSleep(
      ctxSynced(),
      stepName,
      DEFAULT_MAX_HOPS
    );
  }

  /**
   * @description Fires a parked sleep wait on the named step, bounded by an
   * explicit hop budget, then resumes driving.
   * @param stepName The sleeping step to wake.
   * @param maxHops The maximum number of hops to consume while resuming.
   * @return The result after waking the sleep and resuming driving.
   */
  public Result fireSleep(String stepName, Integer maxHops) {
    return WorkflowHarnessSleepFire.fireSleep(ctxSynced(), stepName, maxHops);
  }

  /**
   * @description Fires a parked retry wait on the named step through the
   * engine's resume path, then resumes driving.
   * @param stepName The retrying step to wake.
   * @return The result after firing the retry and resuming driving.
   */
  public Result fireRetry(String stepName) {
    return WorkflowHarnessSleepFire.fireRetry(
      ctxSynced(),
      stepName,
      DEFAULT_MAX_HOPS
    );
  }

  /**
   * @description Fires a parked retry wait on the named step, bounded by an
   * explicit hop budget, then resumes driving.
   * @param stepName The retrying step to wake.
   * @param maxHops The maximum number of hops to consume while resuming.
   * @return The result after firing the retry and resuming driving.
   */
  public Result fireRetry(String stepName, Integer maxHops) {
    return WorkflowHarnessSleepFire.fireRetry(ctxSynced(), stepName, maxHops);
  }
}
