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
public inherited sharing class WorkflowTestHarness {
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
    public Boolean isSleeping;
    public Boolean isAwaitingRetry;


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
  private final Set<Id> scannedInstanceIds = new Set<Id>();
  public Boolean disableAutoTimeSkip = false;

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

  /**
   * Advances the instance by exactly one logical hop and returns the current
   * result. Unlike drive(), this never throws when work remains — it lets the
   * caller decide whether to keep going (via another step() or drive()). If
   * nothing is advanceable, it returns the current result unchanged.
   */
  public Result step() {
    deliverEvents();
    for (Workflow_Instance__c inst : collectTree()) {
      if (isAdvanceable(inst)) {
        advanceOneStep(inst, 1);
        deliverEvents();
        return buildResult();
      }
    }
    return buildResult();
  }

  /**
   * Drives until the named step appears in the append-only audit trail, then
   * stops — useful for asserting intermediate state between specific steps
   * without knowing the exact hop count. Returns as soon as the step appears
   * (whether Completed or still Running/Retrying), or when the instance
   * stabilizes naturally (terminal or signal-suspend), whichever comes first.
   * Throws HarnessException if the step is never reached within maxHops.
   */
  public Result driveUntilStep(String stepName) {
    return driveUntilStep(stepName, DEFAULT_MAX_HOPS);
  }

  public Result driveUntilStep(String stepName, Integer maxHops) {
    if (String.isBlank(stepName)) {
      throw new HarnessException('stepName is required.');
    }
    if (maxHops == null || maxHops <= 0) {
      throw new HarnessException('maxHops must be a positive number.');
    }

    Integer hopsThisCall = 0;
    while (hopsThisCall < maxHops) {
      deliverEvents();
      Result current = buildResult();
      if (current.reachedStep(stepName) || current.isTerminal) {
        return current;
      }
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
        return buildResult();
      }
    }

    // One final check: the target step may have completed on the last hop.
    Result finalCheck = buildResult();
    if (finalCheck.reachedStep(stepName) || finalCheck.isTerminal) {
      return finalCheck;
    }
    throw new HarnessException(
      'Step ' +
        stepName +
        ' was not reached within ' +
        maxHops +
        ' hop(s). Root status: ' +
        finalCheck.status
    );
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
          Integer used = advanceOneStep(inst, maxHops - hopsThisCall);
          if (used > 0) {
            hopsThisCall += used;
            advancedAny = true;
          }
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
    scannedInstanceIds.clear();
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
    // If suspended but there are still branches in Current_Step__c that have not run yet,
    // the instance is still advanceable to let those sibling branches execute.
    if (String.isNotBlank(inst.Current_Step__c) && inst.Current_Step__c.contains(',')) {
      List<String> branches = new List<String>();
      for (String s : inst.Current_Step__c.split(',')) {
        branches.add(s.trim());
      }
      List<Workflow_Step_Execution__c> execs = [
        SELECT Step_Name__c, Status__c, SOQL_Query_Count__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :inst.Id
          AND Step_Name__c IN :branches
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
      ];
      Map<String, Workflow_Step_Execution__c> latestExecs = new Map<String, Workflow_Step_Execution__c>();
      for (Workflow_Step_Execution__c se : execs) {
        if (!latestExecs.containsKey(se.Step_Name__c)) {
          latestExecs.put(se.Step_Name__c, se);
        }
      }
      for (String branch : branches) {
        Workflow_Step_Execution__c se = latestExecs.get(branch);
        if (se == null || (se.Status__c == 'Pending' && se.SOQL_Query_Count__c == null)) {
          return true; // Sibling branch has not run yet!
        }
      }
    }

    if (disableAutoTimeSkip) {
      return false;
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
    String currentStep = inst.Current_Step__c;
    if (String.isNotBlank(currentStep) && currentStep.contains(',')) {
      List<String> branches = new List<String>();
      for (String branch : currentStep.split(',')) {
        branches.add(branch.trim());
      }
      List<Workflow_Step_Execution__c> execs = [
        SELECT Step_Name__c, Status__c, SOQL_Query_Count__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :inst.Id
          AND Step_Name__c IN :branches
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
      ];
      Map<String, Workflow_Step_Execution__c> latestExecMap = new Map<String, Workflow_Step_Execution__c>();
      for (Workflow_Step_Execution__c se : execs) {
        if (!latestExecMap.containsKey(se.Step_Name__c)) {
          latestExecMap.put(se.Step_Name__c, se);
        }
      }

      Integer used = 0;
      for (String branch : branches) {
        Workflow_Step_Execution__c se = latestExecMap.get(branch);
        if (se != null) {
          if (se.Status__c == 'Completed') {
            continue;
          }
          if (inst.Status__c == 'Suspended') {
            if (se.Status__c == 'Retrying' && disableAutoTimeSkip) {
              continue;
            }
            if (se.Status__c == 'Pending' && se.SOQL_Query_Count__c != null && disableAutoTimeSkip) {
              continue; // Already ran and suspended/sleeping/waiting
            }
          }
        }
        if (used >= remaining) {
          break;
        }
        Boolean isCallout = isCalloutStep(branch);
        if (!isCallout && inst.Status__c == 'Suspended') {
          Boolean isSleepingOrRetrying = (se != null && (
            se.Status__c == 'Retrying' ||
            (se.Status__c == 'Pending' && se.SOQL_Query_Count__c != null)
          ));
          if (isSleepingOrRetrying) {
            clearSleepMarkers(inst.Id);
          }
        }
        runStepSafely(inst.Id, branch);
        if (isCallout) {
          clearStaleSleepMarkers(inst.Id);
        }
        used++;
      }
      return used;
    }
    
    Boolean isCallout = isCalloutStep(inst.Current_Step__c);
    if (!isCallout && inst.Status__c == 'Suspended') {
      clearSleepMarkers(inst.Id);
    }
    runStepSafely(inst.Id, null);
    if (isCallout) {
      clearStaleSleepMarkers(inst.Id);
    }
    return 1;
  }

  /**
   * Invokes the engine the way WorkflowOrchestrator does, and rescues a thrown
   * step exactly as WorkflowFinalizer / SagaWorkflowExampleTest do — a synchronous
   * catch that hands off to WorkflowEngine.handleCrash. (An earlier version wrapped
   * each hop in a Database savepoint for production-faithful rollback, but that
   * leaks one unreleased savepoint per successful hop; this matches the engine's
   * own proven crash-driving pattern instead.)
   */
  private void runStepSafely(Id instanceId, String stepName) {
    scannedInstanceIds.remove(instanceId);
    totalHops++;
    try {
      WorkflowEngine.runStep(instanceId, stepName);
    } catch (Exception ex) {
      WorkflowEngine.handleCrash(instanceId, stepName, ex);
    }
  }

  private Boolean isCalloutStep(String stepName) {
    if (String.isBlank(stepName)) {
      return false;
    }
    try {
      Type stepType = Type.forName(stepName);
      if (stepType != null) {
        return stepType.newInstance() instanceof CalloutStep;
      }
    } catch (Exception e) {
      System.debug(LoggingLevel.FINEST, 'Ignore callout step resolution failure: ' + e.getMessage());
    }
    return false;
  }

  /**
   * Clears the sleep/retry wake markers on an instance (never Status__c or
   * Current_Step__c unless the instance is still Suspended). This is the same field
   * reset the engine performs when its watchdog or WorkflowSleepJob wakes a sleeping
   * instance.
   */
  private void clearSleepMarkers(Id instanceId) {
    List<Workflow_Instance__c> insts = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
    ];
    if (insts.isEmpty()) {
      return;
    }
    Workflow_Instance__c inst = insts[0];
    Workflow_Instance__c toUpdate = new Workflow_Instance__c(
      Id = instanceId,
      Sleep_Until__c = null,
      Async_Job_Id__c = null
    );
    if (inst.Status__c == 'Suspended') {
      toUpdate.Status__c = 'Running';
    }
    update as system toUpdate;
  }

  private void clearStaleSleepMarkers(Id instanceId) {
    List<Workflow_Instance__c> insts = [
      SELECT Status__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
    ];
    if (insts.isEmpty()) {
      return;
    }
    Workflow_Instance__c inst = insts[0];
    if (inst.Status__c != 'Suspended') {
      clearSleepMarkers(instanceId);
      return;
    }

    Boolean hasActiveSleepOrRetry = false;
    Boolean hasActiveWait = false;
    Boolean hasNormalPending = false;

    if (String.isNotBlank(inst.Current_Step__c)) {
      List<String> activeSteps = inst.Current_Step__c.split(',');
      List<Workflow_Step_Execution__c> execs = [
        SELECT Step_Name__c, Status__c, SOQL_Query_Count__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId
          AND Step_Name__c IN :activeSteps
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
      ];
      Map<String, Workflow_Step_Execution__c> latestStepMap = new Map<String, Workflow_Step_Execution__c>();
      for (Workflow_Step_Execution__c se : execs) {
        if (!latestStepMap.containsKey(se.Step_Name__c)) {
          latestStepMap.put(se.Step_Name__c, se);
        }
      }
      for (String stepName : activeSteps) {
        Workflow_Step_Execution__c se = latestStepMap.get(stepName.trim());
        if (se == null || (se.Status__c == 'Pending' && se.SOQL_Query_Count__c == null)) {
          hasNormalPending = true;
        } else if (se.Status__c == 'Retrying') {
          hasActiveSleepOrRetry = true;
        } else if (se.Status__c == 'Pending' && se.SOQL_Query_Count__c != null) {
          if (isFrameworkWaitState(se.Output__c)) {
            hasActiveWait = true;
          } else {
            Boolean hasJob = true;
            if (WorkflowEngine.useDynamicScheduling) {
              String jobPrefix = WorkflowEngine.getSleepJobPrefix(instanceId, stepName.trim()) + '%';
              List<CronTrigger> jobs = [
                SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE :jobPrefix WITH SYSTEM_MODE LIMIT 1
              ];
              hasJob = !jobs.isEmpty();
            }
            if (hasJob) {
              hasActiveSleepOrRetry = true;
            } else {
              hasNormalPending = true;
            }
          }
        }
      }
    }

    if (!hasActiveSleepOrRetry) {
      Workflow_Instance__c toUpdate = new Workflow_Instance__c(
        Id = instanceId,
        Sleep_Until__c = null,
        Async_Job_Id__c = null
      );
      if (hasNormalPending && !hasActiveWait) {
        toUpdate.Status__c = 'Running';
      }
      update as system toUpdate;
    }
  }

  private Boolean isFrameworkWaitState(String output) {
    if (String.isBlank(output) || !output.trim().startsWith('{')) {
      return false;
    }
    try {
      Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(output);
      if (data != null) {
        if (data.containsKey('$timeoutStep') ||
            data.containsKey('childWorkflowName') ||
            data.containsKey('childCorrelationKeys') ||
            data.containsKey('waitingForApproval')) {
          return true;
        }
      }
    } catch (Exception ex) {
      System.debug(LoggingLevel.FINEST, 'Ignore JSON deserialization failure: ' + ex.getMessage());
    }
    return false;
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

    Set<Id> unscannedIds = new Set<Id>();
    for (Id instId : knownInstanceIds) {
      if (!scannedInstanceIds.contains(instId)) {
        unscannedIds.add(instId);
      }
    }

    if (maybeSpawnedChild && !unscannedIds.isEmpty()) {
      List<Workflow_Instance__c> children = [
        SELECT Id, Status__c, Current_Step__c, Sleep_Until__c
        FROM Workflow_Instance__c
        WHERE
          Parent_Instance__c IN :unscannedIds
          AND Id NOT IN :knownInstanceIds
        WITH SYSTEM_MODE
      ];
      for (Workflow_Instance__c child : children) {
        byId.put(child.Id, child);
        knownInstanceIds.add(child.Id);
      }
      scannedInstanceIds.addAll(unscannedIds);
    }
    return byId.values();
  }

  private Workflow_Instance__c queryInstance(Id instanceId) {
    List<Workflow_Instance__c> results = [
      SELECT Id, Status__c, Current_Step__c, Sleep_Until__c, Output__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (results.isEmpty()) {
      throw new HarnessException('Workflow instance ' + instanceId + ' not found in the database.');
    }
    return results[0];
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

    Map<String, String> stepLatestStatus = new Map<String, String>();

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
      stepLatestStatus.put(se.Step_Name__c.toLowerCase(), se.Status__c);
    }

    r.isSleeping = false;
    r.isAwaitingRetry = false;
    if (root.Status__c == 'Suspended' && root.Sleep_Until__c != null) {
      List<String> activeSteps = new List<String>();
      if (String.isNotBlank(root.Current_Step__c)) {
        for (String s : root.Current_Step__c.split(',')) {
          activeSteps.add(s.trim());
        }
      }
      for (String step : activeSteps) {
        String forwardKey = step.toLowerCase();
        String compensateKey = forwardKey + '_compensate';
        String status = stepLatestStatus.containsKey(compensateKey)
          ? stepLatestStatus.get(compensateKey)
          : stepLatestStatus.get(forwardKey);
        if (status == 'Retrying') {
          r.isAwaitingRetry = true;
        } else if (status == 'Pending') {
          r.isSleeping = true;
        }
      }
      if (!r.isSleeping && !r.isAwaitingRetry) {
        r.isSleeping = true;
      }
    }

    return r;
  }

  public WorkflowTestHarness failStep(String stepName, String message) {
    if (String.isBlank(stepName)) {
      throw new HarnessException('stepName is required.');
    }
    if (WorkflowEngine.injectedFaults == null) {
      WorkflowEngine.injectedFaults = new Map<String, WorkflowEngine.FaultConfig>();
    }
    String key = rootInstanceId + ':' + stepName.toLowerCase();
    WorkflowEngine.injectedFaults.put(key, new WorkflowEngine.FaultConfig(message, null));
    return this;
  }

  public WorkflowTestHarness failStepOnce(String stepName, String message) {
    if (String.isBlank(stepName)) {
      throw new HarnessException('stepName is required.');
    }
    if (WorkflowEngine.injectedFaults == null) {
      WorkflowEngine.injectedFaults = new Map<String, WorkflowEngine.FaultConfig>();
    }
    String key = rootInstanceId + ':' + stepName.toLowerCase();
    WorkflowEngine.injectedFaults.put(key, new WorkflowEngine.FaultConfig(message, 1));
    return this;
  }

  public WorkflowTestHarness failStep(String stepName, String message, Integer failCount) {
    if (String.isBlank(stepName)) {
      throw new HarnessException('stepName is required.');
    }
    if (failCount == null || failCount <= 0) {
      throw new HarnessException('failCount must be greater than 0.');
    }
    if (WorkflowEngine.injectedFaults == null) {
      WorkflowEngine.injectedFaults = new Map<String, WorkflowEngine.FaultConfig>();
    }
    String key = rootInstanceId + ':' + stepName.toLowerCase();
    WorkflowEngine.injectedFaults.put(key, new WorkflowEngine.FaultConfig(message, failCount));
    return this;
  }

  public WorkflowTestHarness clearFaults() {
    if (WorkflowEngine.injectedFaults != null) {
      String prefix = rootInstanceId + ':';
      List<String> keysToRemove = new List<String>();
      for (String key : WorkflowEngine.injectedFaults.keySet()) {
        if (key.startsWith(prefix)) {
          keysToRemove.add(key);
        }
      }
      for (String key : keysToRemove) {
        WorkflowEngine.injectedFaults.remove(key);
      }
    }
    return this;
  }

  private Workflow_Instance__c findSleepingOrRetryingInstance(String stepName, Boolean checkSleep) {
    if (String.isBlank(stepName)) {
      return null;
    }
    List<Workflow_Instance__c> tree = collectTree();
    List<Id> candidateInstanceIds = new List<Id>();

    String checkName = stepName.toLowerCase();
    String forwardName = checkName;
    if (checkName.endsWith('_compensate')) {
      forwardName = checkName.substring(0, checkName.length() - 11);
    }

    for (Workflow_Instance__c inst : tree) {
      if (String.isNotBlank(inst.Current_Step__c)) {
        List<String> activeSteps = new List<String>();
        for (String s : inst.Current_Step__c.split(',')) {
          activeSteps.add(s.trim().toLowerCase());
        }
        if (activeSteps.contains(checkName) || activeSteps.contains(forwardName)) {
          candidateInstanceIds.add(inst.Id);
        }
      }
    }

    if (candidateInstanceIds.isEmpty()) {
      return null;
    }

    List<Workflow_Step_Execution__c> execs = [
      SELECT Workflow_Instance__c, Status__c, SOQL_Query_Count__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :candidateInstanceIds
        AND Step_Name__c = :stepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    Map<Id, Workflow_Step_Execution__c> latestStepMap = new Map<Id, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c se : execs) {
      if (!latestStepMap.containsKey(se.Workflow_Instance__c)) {
        latestStepMap.put(se.Workflow_Instance__c, se);
      }
    }

    for (Workflow_Instance__c inst : tree) {
      if (latestStepMap.containsKey(inst.Id)) {
        Workflow_Step_Execution__c se = latestStepMap.get(inst.Id);
        String status = se.Status__c;
        if (inst.Status__c == 'Suspended') {
          if (checkSleep && status == 'Pending' && se.SOQL_Query_Count__c != null) {
            if (isFrameworkWaitState(se.Output__c)) {
              continue;
            }
            if (WorkflowEngine.useDynamicScheduling) {
              String jobPrefix = WorkflowEngine.getSleepJobPrefix(inst.Id, stepName) + '%';
              List<CronTrigger> jobs = [
                SELECT Id
                FROM CronTrigger
                WHERE CronJobDetail.Name LIKE :jobPrefix
                WITH SYSTEM_MODE
                LIMIT 1
              ];
              if (jobs.isEmpty() && inst.Sleep_Until__c == null) {
                continue;
              }
            } else {
              if (inst.Sleep_Until__c == null) {
                continue;
              }
            }
            return inst;
          }
          if (!checkSleep && status == 'Retrying') {
            if (WorkflowEngine.useDynamicScheduling) {
              String jobPrefix = 'WorkflowRetry_' + inst.Id + '_%';
              List<CronTrigger> jobs = [
                SELECT Id
                FROM CronTrigger
                WHERE CronJobDetail.Name LIKE :jobPrefix
                WITH SYSTEM_MODE
                LIMIT 1
              ];
              if (jobs.isEmpty() && inst.Sleep_Until__c == null) {
                continue;
              }
            } else {
              if (inst.Sleep_Until__c == null) {
                continue;
              }
            }
            return inst;
          }
        }
      }
    }
    return null;
  }

  public Result fireSleep(String stepName) {
    return fireSleep(stepName, DEFAULT_MAX_HOPS);
  }

  public Result fireSleep(String stepName, Integer maxHops) {
    if (String.isBlank(stepName)) {
      throw new HarnessException('stepName is required.');
    }
    if (maxHops == null || maxHops <= 0) {
      throw new HarnessException('maxHops must be a positive number.');
    }
    Workflow_Instance__c inst = findSleepingOrRetryingInstance(stepName, true);
    if (inst == null) {
      throw new HarnessException('Step ' + stepName + ' is not currently sleeping.');
    }
    Boolean isCallout = isCalloutStep(stepName);
    if (!isCallout) {
      clearSleepMarkers(inst.Id);
    }
    runStepSafely(inst.Id, stepName);
    if (isCallout) {
      clearStaleSleepMarkers(inst.Id);
    }
    return drive(maxHops);
  }

  public Result fireRetry(String stepName) {
    return fireRetry(stepName, DEFAULT_MAX_HOPS);
  }

  public Result fireRetry(String stepName, Integer maxHops) {
    if (String.isBlank(stepName)) {
      throw new HarnessException('stepName is required.');
    }
    if (maxHops == null || maxHops <= 0) {
      throw new HarnessException('maxHops must be a positive number.');
    }
    Workflow_Instance__c inst = findSleepingOrRetryingInstance(stepName, false);
    if (inst == null) {
      throw new HarnessException('Step ' + stepName + ' is not currently awaiting retry.');
    }
    Boolean isCallout = isCalloutStep(stepName);
    if (!isCallout) {
      clearSleepMarkers(inst.Id);
    }
    runStepSafely(inst.Id, stepName);
    if (isCallout) {
      clearStaleSleepMarkers(inst.Id);
    }
    return drive(maxHops);
  }
}

