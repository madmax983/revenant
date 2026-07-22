/**
 * @description Scalar exactly-once start admission (INV-1) for the workflow start
 * subsystem. Owns the single-instance get-or-start sequence kept intra-class:
 * dedup within the configured window ({@link WorkflowStartDedup}), build the
 * instance ({@link WorkflowStartInstanceBuilder}), insert under the unique-index
 * DUPLICATE_VALUE concurrency backstop, seed the initial step execution, and
 * apply the operator pause gate and concurrency-bounded timeout deferral.
 * Extracted from `WorkflowStartService`, which retains the public start facades
 * and delegates the scalar path here via the boolean-free
 * {@link #doStartGetOrStart} / {@link #doStartSingleton} entry points (the
 * get-or-start vs singleton include-terminal decision stays a private detail).
 * All DML and SOQL run in system mode; the dedup pre-query takes no `FOR UPDATE`
 * lock (see doStart).
 */
public inherited sharing class WorkflowScalarStartService {
  /**
   * @description Scalar get-or-start entry: admit a new instance or return the
   * in-window dedup winner (active, or recently terminal within the window).
   * @param req the start request to admit
   * @return a StartResult carrying the instance Id and whether it was newly created
   */
  public static WorkflowEngine.StartResult doStartGetOrStart(
    WorkflowEngine.StartRequest req
  ) {
    return doStart(req, true);
  }

  /**
   * @description Scalar singleton entry: admit a new instance or return the active
   * winner only, never deduping against a terminal instance so a dead singleton is
   * always restarted.
   * @param req the singleton start request to admit
   * @return a StartResult carrying the instance Id and whether it was newly created
   */
  public static WorkflowEngine.StartResult doStartSingleton(
    WorkflowEngine.StartRequest req
  ) {
    return doStart(req, false);
  }

  /**
   * Resolves an existing get-or-start winner within the dedup scope.
   * @param correlationKey the correlation key to look up
   * @param includeTerminal whether recently-terminal matches count
   * @return the existing instance, or null when none is in scope
   */
  private static Workflow_Instance__c resolveExistingStart(
    String correlationKey,
    Boolean includeTerminal
  ) {
    Set<String> keys = new Set<String>{ correlationKey };
    Map<String, Workflow_Instance__c> found = includeTerminal
      ? WorkflowStartDedup.findExistingByKey(keys)
      : WorkflowStartDedup.findActiveByKey(keys);
    return found.get(WorkflowKeys.normalizeKey(correlationKey));
  }

  /**
   * Inserts the instance and its search attributes, resolving the unique-index
   * concurrency backstop on DUPLICATE_VALUE.
   * @param instance the unsaved instance to insert
   * @param attributes the search attributes to insert alongside it
   * @param correlationKey the correlation key (used to resolve a race winner)
   * @return a WorkflowEngine.StartResult when a sibling won the race (caller returns it), else
   *   null on a normal successful insert
   */
  private static WorkflowEngine.StartResult insertStartInstance(
    Workflow_Instance__c instance,
    Map<String, String> attributes,
    String correlationKey
  ) {
    try {
      Database.insert(instance, true, AccessLevel.SYSTEM_MODE);
      List<Workflow_Search_Attribute__c> attrsToInsert = WorkflowStartInstanceBuilder.buildAttributes(
        instance.Id,
        attributes
      );
      if (!attrsToInsert.isEmpty()) {
        Database.insert(attrsToInsert, true, AccessLevel.SYSTEM_MODE);
      }
      return null;
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) != 'DUPLICATE_VALUE') {
        throw ex;
      }
      // Concurrency backstop: a sibling start won the race on the unique
      // Active_Correlation_Key__c index. A sibling provably exists, so resolve
      // the winner regardless of the dedup window (it may have completed
      // mid-race) and return its Id so the loser is a safe no-op.
      Workflow_Instance__c winner = WorkflowStartDedup.findAnyByKey(
          new Set<String>{ correlationKey }
        )
        .get(WorkflowKeys.normalizeKey(correlationKey));
      if (winner != null) {
        return new WorkflowEngine.StartResult(winner.Id);
      }
      throw new WorkflowEngine.WorkflowException(
        'An active workflow already exists with correlation key: ' +
        correlationKey
      );
    }
  }

  /**
   * Inserts the initial Pending step execution for a freshly-started instance,
   * arming the timeout clock unless the start is parked or concurrency-deferred.
   * @param instance the inserted instance
   * @param parkAtStart whether the start is parked by the operator pause gate
   * @param deferTimeoutForConcurrency whether admission will arm the timeout
   */
  private static void insertInitialStepExecution(
    Workflow_Instance__c instance,
    Boolean parkAtStart,
    Boolean deferTimeoutForConcurrency
  ) {
    if (String.isBlank(instance.Current_Step__c)) {
      return;
    }
    Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
    stepExec.Workflow_Instance__c = instance.Id;
    stepExec.Step_Name__c = instance.Current_Step__c;
    stepExec.Status__c = 'Pending';
    stepExec.Input__c = instance.Input__c;
    stepExec.Retry_Count__c = 0;
    // Do not start the timeout clock while parked — a paused/throttled step's
    // Timeout_At__c would otherwise pollute the watchdog timeout batch (selected,
    // then skipped because the parent is not runnable) or, for a still-Pending
    // bounded start, fail it before admission. Resume/admission re-establishes it.
    if (!parkAtStart && !deferTimeoutForConcurrency) {
      Integer timeout = WorkflowStepTimeoutConfig.getStepTimeoutSeconds(
        instance.Current_Step__c,
        WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
      );
      if (timeout != null && timeout > 0) {
        stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
      }
    }
    Database.insert(stepExec, true, AccessLevel.SYSTEM_MODE);
  }

  private static WorkflowEngine.StartResult doStart(
    WorkflowEngine.StartRequest req,
    Boolean includeTerminal
  ) {
    String correlationKey = req.correlationKey;
    Object input = req.input;
    Map<String, String> attributes = req.attributes;
    WorkflowPayloadOffload.validateCorrelationKey(correlationKey);
    WorkflowStartValidation.validateAttributes(attributes);

    // Get-or-start: return an existing instance within the dedup scope (active,
    // and optionally recently terminal within the configured window) instead of
    // throwing or inserting a duplicate. No step-execution write, no enqueue.
    //
    // Concurrency note (known limitation): the unique Active_Correlation_Key__c
    // index is the hard backstop for the active<->active race. Terminal-window
    // dedup is best-effort under concurrent redelivery: if a sibling start
    // inserts AND transitions to terminal in the narrow window between this
    // pre-query and our insert, the trigger has already cleared its active key,
    // so our insert succeeds and a duplicate of a just-finished, in-window run
    // can be created. Closing this fully would require a recheck-after-insert
    // (an extra SOQL on every successful start) or a lock surviving the terminal
    // transition; both are intentionally avoided here to keep the start path to
    // a single indexed SOQL. The common cases (active redelivery, sequential
    // post-completion redelivery) are fully covered.
    if (String.isNotBlank(correlationKey)) {
      Workflow_Instance__c match = resolveExistingStart(
        correlationKey,
        includeTerminal
      );
      if (match != null) {
        return new WorkflowEngine.StartResult(match.Id);
      }
    }

    // Opt-in input-contract validation (INV-51): only a GENUINE new start reaches
    // here (an existing get-or-start / signal-or-start hit returned above without
    // being validated, since its input is never persisted). If the target workflow
    // implements ValidatedWorkflow, reject a bad start payload now — before the
    // instance insert or any enqueue — with a field-level WorkflowInputException. A
    // non-ValidatedWorkflow workflow is a free no-op (an instanceof on the resolved
    // definition; zero SOQL, zero DML). Validation runs after the dedup pre-query
    // but adds no query/DML of its own.
    WorkflowInputValidator.validate(req);

    Workflow_Instance__c instance = WorkflowStartInstanceBuilder.buildInstance(
      req
    );

    WorkflowEngine.StartResult raceWinner = insertStartInstance(
      instance,
      attributes,
      correlationKey
    );
    if (raceWinner != null) {
      return raceWinner;
    }

    instance.Input__c = WorkflowPayloadOffload.savePayloadIfNeeded(
      instance.Id,
      (req.inputJson != null)
        ? req.inputJson
        : ((input != null) ? JSON.serialize(input) : null),
      'Input_' + instance.Id
    );

    // Operator pause gate — decide up front whether to park this start, so the
    // initial step's timeout clock is never started while parked.
    Boolean parkAtStart =
      WorkflowPauseGate.anyPaused() &&
      WorkflowPauseGate.isDefinitionPaused(instance.Workflow_Name__c);

    // A concurrency-bounded workflow may park on its first RUN_STEP before executing
    // a step. Defer arming the initial step's timeout until admission succeeds (the
    // admission path re-arms it via reArmTimeoutsForResume). Otherwise a still-Pending
    // step sitting in the event/queue backlog during a burst could be failed by the
    // timeout sweep before it ever reaches the gate to park.
    Boolean deferTimeoutForConcurrency = ConcurrencyGate.isConfigured(
      instance.Workflow_Name__c
    );
    // Stamp the durable awaiting-admission marker at deferral time. The pre-start
    // watchdog (WorkflowTimeoutJob) keys its null-deadline skip off this marker, not
    // the live CMDT, so a ceiling added later cannot retroactively silence a genuine
    // unbounded pre-start watchdog. Cleared on admission (the acquire path) / when the
    // ceiling is later removed (the unbounded fall-through).
    if (deferTimeoutForConcurrency) {
      instance.Concurrency_Parked__c = true;
    }
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);

    insertInitialStepExecution(
      instance,
      parkAtStart,
      deferTimeoutForConcurrency
    );

    // Park at start if the definition is currently paused. The initial Pending
    // Workflow_Step_Execution__c (inserted above, with no timeout clock) gives the
    // resume path a concrete step to drive. Skip timeout scheduling and the first
    // enqueue; the watchdog re-drives held work on resume.
    if (parkAtStart) {
      return parkStartInstance(instance);
    }

    return finalizeStart(instance, deferTimeoutForConcurrency);
  }

  /**
   * Parks a freshly-started instance under the operator pause gate.
   * @param instance the inserted instance to park
   * @return a new-marked WorkflowEngine.StartResult for the parked instance
   */
  private static WorkflowEngine.StartResult parkStartInstance(
    Workflow_Instance__c instance
  ) {
    instance.Status__c = 'Paused';
    Database.update(instance, true, AccessLevel.SYSTEM_MODE);
    return new WorkflowEngine.StartResult(instance.Id).markNew();
  }

  /**
   * Schedules the initial-step watchdog (unless concurrency-deferred) and enqueues
   * the first step execution for a non-parked start.
   * @param instance the inserted instance to drive
   * @param deferTimeoutForConcurrency whether admission will arm the timeout
   * @return a new-marked WorkflowEngine.StartResult for the started instance
   */
  private static WorkflowEngine.StartResult finalizeStart(
    Workflow_Instance__c instance,
    Boolean deferTimeoutForConcurrency
  ) {
    // Schedule watchdog for the initial step before executing it — unless this is a
    // bounded workflow, where the admission gate arms the timeout once a slot is won.
    if (!deferTimeoutForConcurrency) {
      WorkflowTimeoutArming.scheduleTimeoutJobForInstance(instance.Id);
    }

    // Enqueue the first step execution
    WorkflowOrchestratorEnqueue.enqueueOrchestrators(
      new List<Id>{ instance.Id }
    );
    return new WorkflowEngine.StartResult(instance.Id).markNew();
  }
}
