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
 */
@IsTest
public class WorkflowTestHarness {
  /** Default hop budget if the caller does not supply one. */
  public static final Integer DEFAULT_MAX_HOPS = 100;

  private static final Set<String> TERMINAL_STATUSES = new Set<String>{
    'Completed',
    'Failed',
    'Compensated',
    'Cancelled',
    'ContinuedAsNew'
  };

  // Statuses from which the engine can be driven forward by re-invoking runStep.
  private static final Set<String> ACTIVE_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Compensating',
    'Cancelling'
  };

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

    /** True if the named step appears anywhere in the audit trail. */
    public Boolean reachedStep(String stepName) {
      return executedSteps != null && executedSteps.contains(stepName);
    }
  }

  private final Id rootInstanceId;
  private Integer totalHops = 0;
  // Instances discovered so far (root + spawned children). Cached so the per-hop
  // tree scan stays cheap on SOQL instead of re-walking the whole tree each hop.
  private final Set<Id> knownInstanceIds;

  public WorkflowTestHarness(Id instanceId) {
    if (!Test.isRunningTest()) {
      throw new HarnessException('WorkflowTestHarness is test-context only.');
    }
    if (instanceId == null) {
      throw new HarnessException('A workflow instance Id is required.');
    }
    this.rootInstanceId = instanceId;
    this.knownInstanceIds = new Set<Id>{ instanceId };
    // Keep the async chain quiet: drive synchronously and suppress the engine's
    // in-test Queueable hand-offs so they cannot double-run or pile up against the
    // queueable limit. The harness invokes runStep directly instead.
    WorkflowEngine.disableQueueableInTest = true;
  }

  /** Drives to the next stable state using the default hop budget. */
  public Result drive() {
    return drive(DEFAULT_MAX_HOPS);
  }

  /**
   * Drives the instance (and any child workflows it spawns) until nothing can
   * advance — i.e. it reaches a terminal state or a genuine wait-for-signal
   * suspend. Throws HarnessException if it cannot stabilize within maxHops.
   */
  public Result drive(Integer maxHops) {
    if (maxHops == null || maxHops <= 0) {
      throw new HarnessException('maxHops must be a positive number.');
    }

    Integer hopsThisCall = 0;
    while (hopsThisCall < maxHops) {
      // Deliver any pending platform events (e.g. child-completion signals) so a
      // parent that was waiting on a child becomes advanceable again.
      deliverEvents();

      Boolean advancedAny = false;
      for (Workflow_Instance__c inst : collectTree()) {
        if (hopsThisCall >= maxHops) {
          break;
        }
        if (isAdvanceable(inst)) {
          hopsThisCall += advanceOneStep(inst, maxHops - hopsThisCall);
          advancedAny = true;
        }
      }

      if (!advancedAny) {
        // Nothing in the tree can move on its own: the workflow has stabilized.
        return buildResult();
      }
    }

    // Budget spent. If the tree still has work to do, fail loudly.
    deliverEvents();
    for (Workflow_Instance__c inst : collectTree()) {
      if (isAdvanceable(inst)) {
        Workflow_Instance__c root = queryInstance(rootInstanceId);
        throw new HarnessException(
          'Workflow ' +
            rootInstanceId +
            ' did not stabilize within ' +
            maxHops +
            ' hop(s). Root status: ' +
            root.Status__c +
            ', current step: ' +
            root.Current_Step__c +
            '. Increase the hop budget passed to drive(), or check for a ' +
            'non-terminating workflow.'
        );
      }
    }
    // Stabilized exactly at the budget boundary.
    return buildResult();
  }

  /**
   * Delivers an external signal to a workflow (by correlation key or instance Id)
   * and resumes driving — the human-in-the-loop / external-signal affordance. Uses
   * the shipped WorkflowEngine.signal path; no manual event-bus plumbing.
   */
  public Result injectSignal(
    String correlationKey,
    String signalName,
    String payload
  ) {
    return injectSignal(correlationKey, signalName, payload, DEFAULT_MAX_HOPS);
  }

  public Result injectSignal(
    String correlationKey,
    String signalName,
    String payload,
    Integer maxHops
  ) {
    WorkflowEngine.signal(correlationKey, signalName, payload);
    return drive(maxHops);
  }

  /**
   * Fires the shipped WorkflowTimeoutJob against a step on the root instance,
   * reproducing a watchdog timeout, then resumes driving (so a timeout that
   * triggers compensation is pumped to its terminal state). The author never
   * hand-mutates Status__c / Current_Step__c to simulate the timeout.
   */
  public Result fireTimeout(String stepName) {
    return fireTimeout(stepName, DEFAULT_MAX_HOPS);
  }

  public Result fireTimeout(String stepName, Integer maxHops) {
    new WorkflowTimeoutJob(rootInstanceId, stepName).executeInternal();
    return drive(maxHops);
  }

  /** Returns the current inspectable result without advancing the workflow. */
  public Result inspect() {
    return buildResult();
  }

  // --- internals -----------------------------------------------------------

  private void deliverEvents() {
    // Safe to call even with nothing queued; flushes published Workflow_Event__e
    // records through WorkflowEventTrigger (signals, child completions).
    Test.getEventBus().deliver();
  }

  private Boolean isAdvanceable(Workflow_Instance__c inst) {
    if (ACTIVE_STATUSES.contains(inst.Status__c)) {
      return true;
    }
    // A sleep/retry wait carries a wake time; resuming it is deterministic, so the
    // harness skips the timer and lets the engine re-run the step (the same resume
    // runStep that WorkflowSleepJob/WorkflowRetryJob enqueue). An external-signal
    // suspend (approval, wait-for-child) has no Sleep_Until__c and is left stable.
    return inst.Status__c == 'Suspended' && inst.Sleep_Until__c != null;
  }

  /**
   * Advances a single instance by one logical step, consuming at most `remaining`
   * hops, and returns the hop count actually consumed. Parallel instances run each
   * not-yet-complete branch (the engine no-ops already-completed branches and
   * auto-inserts the rejoin once the last branch finishes), but never more branches
   * than the remaining budget allows — any leftover branches resume on the next hop.
   */
  private Integer advanceOneStep(Workflow_Instance__c inst, Integer remaining) {
    // Resuming a sleep/retry wait: clear the wake markers first, exactly as the
    // engine's own watchdog resume does (processWatchdogHeartbeat), so a later
    // external suspend on this same instance is not misread as a sleep to skip.
    if (inst.Status__c == 'Suspended') {
      clearSleepMarkers(inst.Id);
    }

    String currentStep = inst.Current_Step__c;
    if (String.isNotBlank(currentStep) && currentStep.contains(',')) {
      Integer used = 0;
      for (String branch : currentStep.split(',')) {
        if (used >= remaining) {
          break;
        }
        runStepSafely(inst.Id, branch.trim());
        used++;
      }
      return used;
    }
    runStepSafely(inst.Id, null);
    return 1;
  }

  /**
   * Invokes the engine the way WorkflowOrchestrator does, and rescues a thrown
   * step exactly as WorkflowFinalizer would on a Queueable crash. A savepoint is
   * rolled back before handleCrash so the failed step's partial DML is discarded —
   * mirroring production, where the step's Queueable transaction is rolled back
   * before the finalizer runs in a fresh transaction.
   */
  private void runStepSafely(Id instanceId, String stepName) {
    totalHops++;
    System.Savepoint sp = Database.setSavepoint();
    try {
      WorkflowEngine.runStep(instanceId, stepName);
    } catch (Exception ex) {
      Database.rollback(sp);
      WorkflowEngine.handleCrash(instanceId, stepName, ex);
    }
  }

  /**
   * Clears the sleep/retry wake markers on an instance (never Status__c or
   * Current_Step__c). This is the same field reset the engine performs when its
   * watchdog or WorkflowSleepJob wakes a sleeping instance, so resuming a sleep
   * here leaves no stale Sleep_Until__c to confuse a later external suspend.
   */
  private void clearSleepMarkers(Id instanceId) {
    update as system new Workflow_Instance__c(
      Id = instanceId,
      Sleep_Until__c = null,
      Async_Job_Id__c = null
    );
  }

  /**
   * Root instance plus all live descendants (children spawned via START_CHILD).
   *
   * Stays frugal with SOQL — the whole drive runs inside the caller's one
   * governor-limit budget. The known-instance set is cached across hops, so the
   * common case costs a single status query per hop. The descendant scan only runs
   * when some instance is parked in a non-sleep suspend (the state a START_CHILD
   * leaves its parent in), which is the only way a new child can have appeared.
   */
  private List<Workflow_Instance__c> collectTree() {
    Map<Id, Workflow_Instance__c> byId = new Map<Id, Workflow_Instance__c>(
      [
        SELECT Id, Status__c, Current_Step__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE Id IN :knownInstanceIds
        WITH SYSTEM_MODE
      ]
    );

    Boolean maybeSpawnedChild = false;
    for (Workflow_Instance__c inst : byId.values()) {
      if (inst.Status__c == 'Suspended' && inst.Sleep_Until__c == null) {
        maybeSpawnedChild = true;
        break;
      }
    }

    if (maybeSpawnedChild) {
      for (Workflow_Instance__c child : [
        SELECT Id, Status__c, Current_Step__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE
          Parent_Instance__c IN :knownInstanceIds
          AND Id NOT IN :knownInstanceIds
        WITH SYSTEM_MODE
      ]) {
        byId.put(child.Id, child);
        knownInstanceIds.add(child.Id);
      }
    }
    return byId.values();
  }

  private Workflow_Instance__c queryInstance(Id instanceId) {
    return [
      SELECT Id, Status__c, Current_Step__c, Sleep_Until__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
  }

  private Result buildResult() {
    Workflow_Instance__c root = queryInstance(rootInstanceId);

    Result r = new Result();
    r.instanceId = rootInstanceId;
    r.status = root.Status__c;
    r.output = WorkflowEngine.resolvePayload(root.Output__c);
    r.hops = totalHops;
    r.isTerminal = TERMINAL_STATUSES.contains(root.Status__c);
    r.isSuspended = root.Status__c == 'Suspended';
    r.executedSteps = new List<String>();
    r.completedSteps = new List<String>();
    r.compensatedSteps = new List<String>();

    for (Workflow_Step_Execution__c se : [
      SELECT Step_Name__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c = :rootInstanceId
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
    ]) {
      r.executedSteps.add(se.Step_Name__c);
      if (se.Status__c == 'Completed') {
        r.completedSteps.add(se.Step_Name__c);
      } else if (se.Status__c == 'Compensated') {
        r.compensatedSteps.add(se.Step_Name__c);
      }
    }
    return r;
  }
}
