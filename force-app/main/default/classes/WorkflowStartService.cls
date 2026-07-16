/**
 * @description Start / get-or-start deduplication subsystem for {@link
 * WorkflowEngine}. Owns the exactly-once admission of new `Workflow_Instance__c`
 * runs: correlation-key dedup within the configured window, the unique-index
 * DUPLICATE_VALUE concurrency backstop, scalar and bulk get-or-start pipelines,
 * the debounced and singleton start entry points, initial step-execution
 * seeding, the operator pause gate and concurrency-bounded timeout deferral.
 * Extracted from `WorkflowEngine` so the highest-risk exactly-once start paths
 * live in one cohesive unit; `WorkflowEngine` retains thin facades that delegate
 * here. All DML and SOQL run in system mode. Dedup queries deliberately use no
 * `FOR UPDATE` lock; the unique `Active_Correlation_Key__c` index is the hard
 * active/active backstop and terminal-window dedup is best-effort under
 * concurrency (see doStart).
 */
public inherited sharing class WorkflowStartService {
  private static Map<String, Boolean> validatedWorkflows = new Map<String, Boolean>();

  // Upper bound (~100 years) applied to the dedup window before it is subtracted
  // from "now", so a large/misconfigured Dedup_Window_Minutes__c cannot push the
  // computed lower bound outside Salesforce's valid DateTime range and fault
  // every start.
  private static final Integer MAX_DEDUP_WINDOW_MINUTES = 52560000;

  /**
   * @description Get-or-start facade target: get-or-start a workflow instance and
   * return its Id. Delegates to the scalar admission pipeline.
   * @param workflowName developer name of the workflow definition to start
   * @param correlationKey dedup/correlation key for the instance
   * @param input start input payload passed to the first step
   * @return Id of the new or deduplicated existing instance
   */
  public static Id startOne(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    return doStart(
        new WorkflowEngine.StartRequest(workflowName, correlationKey, input),
        true
      )
      .instanceId;
  }

  /**
   * @description Get-or-start facade target from a fully-built request.
   * @param request the start request describing the instance to get-or-start
   * @return Id of the new or deduplicated existing instance
   */
  public static Id startOne(WorkflowEngine.StartRequest request) {
    return doStart(request, true).instanceId;
  }

  /**
   * @description startOrGet facade target: get-or-start a workflow instance and
   * report whether it was newly created.
   * @param workflowName developer name of the workflow definition to start
   * @param correlationKey dedup/correlation key for the instance
   * @param input start input payload passed to the first step
   * @return a StartResult carrying the instance Id and whether it was newly created
   */
  public static WorkflowEngine.StartResult startOrGetOne(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    return doStart(
      new WorkflowEngine.StartRequest(workflowName, correlationKey, input),
      true
    );
  }

  /**
   * @description startOrGet facade target from a fully-built request.
   * @param request the start request describing the instance to get-or-start
   * @return a StartResult carrying the instance Id and whether it was newly created
   */
  public static WorkflowEngine.StartResult startOrGetOne(
    WorkflowEngine.StartRequest request
  ) {
    return doStart(request, true);
  }

  /**
   * @description Bulk start facade target: start multiple instances and return
   * their Ids index-aligned with the requests.
   * @param requests the start requests to process
   * @return instance Ids index-aligned with requests (null per null request)
   */
  public static List<Id> startBulk(List<WorkflowEngine.StartRequest> requests) {
    List<Id> ids = new List<Id>();
    for (WorkflowEngine.StartResult r : startOrGetBulk(requests)) {
      ids.add(r == null ? null : r.instanceId);
    }
    return ids;
  }

  /**
   * Active-only get-or-start for engine-internal singleton workflows (e.g. the
   * watchdog). Never dedups against terminal instances, so a failed or
   * continued-as-new singleton is always restarted rather than resolving to a
   * dead terminal run within the dedup window.
   * @param workflowName developer name of the singleton workflow definition
   * @param correlationKey dedup/correlation key for the singleton
   * @param input start input payload passed to the first step
   * @return Id of the active instance (existing if one is live, otherwise newly created)
   */
  public static Id startSingleton(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    return doStart(
        new WorkflowEngine.StartRequest(workflowName, correlationKey, input),
        false
      )
      .instanceId;
  }

  /**
   * Arms a durable trailing-edge debounce timer for starting a workflow. Build
   * the request with workflowName, correlationKey, inputJson and debounceSeconds
   * (and optionally maxWaitSeconds, attributesJson and causationId). Replaces the
   * former positional startDebounced overloads.
   * @param request the debounce request describing the coalesced start
   */
  public static void startDebounced(WorkflowDebouncer.DebounceRequest request) {
    WorkflowDebouncer.startDebounced(
      new List<WorkflowDebouncer.DebounceRequest>{ request }
    );
  }

  /**
   * @description Bulk get-or-start pipeline (facade target for {@link
   * WorkflowEngine}). Returns a result per request (index-aligned) reporting the
   * resolved instance Id and whether it was newly created or deduped.
   * @param requests the start requests to process
   * @return StartResults index-aligned with requests (null per null request)
   */
  public static List<WorkflowEngine.StartResult> startOrGetBulk(
    List<WorkflowEngine.StartRequest> requests
  ) {
    List<WorkflowEngine.StartResult> results = new List<WorkflowEngine.StartResult>();
    if (requests == null || requests.isEmpty()) {
      return results;
    }
    StartOrGetRun run = new StartOrGetRun();
    run.requests = requests;
    run.results = results;

    // 1. Validate and gather correlation keys, and pre-validate workflow names in bulk
    Set<String> correlationKeys = validateAndPrevalidateStarts(requests);

    // 2. Pre-resolve existing instances within the dedup scope (keyed by the
    //    normalized correlation key to honor case-insensitive matching).
    Map<String, Workflow_Instance__c> existingByKey = findExistingByKey(
      correlationKeys,
      true
    );

    // 3. Decide per request (preserving order): dedup to an existing instance,
    //    dedup to an intra-batch sibling, or build a fresh instance to insert.
    decideStartRequests(run, existingByKey);

    // 4. Insert fresh instances, tolerating per-row DUPLICATE_VALUE from a
    //    concurrent winner (the unique Active_Correlation_Key__c backstop).
    insertFreshInstances(run);
    insertStartSearchAttributes(run);

    // 5. Build a key -> resolved Id map for newly inserted instances and for
    //    any concurrent winners, then fill remaining results and assert resolution.
    fillRemainingStartResults(run);
    assertAllStartsResolved(run);

    // 6. Resolve input payloads for newly inserted instances
    resolveStartInputPayloads(run);

    // Operator pause gate and concurrency-bounded deferral (mirror doStart).
    applyStartPauseGate(run);
    applyStartConcurrencyGate(run);

    // 7. Construct initial Step Execution logs for inserted instances only
    buildInitialStepExecs(run);

    // Persist the parked status transition; parked instances are neither scheduled
    // nor enqueued — the resume path drives them when the definition is resumed.
    if (!run.instancesToPark.isEmpty()) {
      Database.update(run.instancesToPark, true, AccessLevel.SYSTEM_MODE);
    }

    // 8. Schedule timeout jobs and enqueue orchestrators for eligible instances.
    scheduleAndEnqueueStarts(run);

    return results;
  }

  private static void validateAttributes(Map<String, String> attributes) {
    if (attributes == null || attributes.isEmpty()) {
      return;
    }
    if (attributes.size() > WorkflowEngine.MAX_ATTRIBUTES_PER_INSTANCE) {
      throw new WorkflowEngine.WorkflowException(
        'Attribute count exceeds maximum limit of ' +
        WorkflowEngine.MAX_ATTRIBUTES_PER_INSTANCE
      );
    }
    for (String key : attributes.keySet()) {
      validateAttributeEntry(key, attributes.get(key));
    }
  }

  /**
   * Validates a single search-attribute key/value pair against the key-blankness,
   * key-length, and value-length limits.
   * @param key the attribute key
   * @param val the attribute value (may be null)
   */
  private static void validateAttributeEntry(String key, String val) {
    if (String.isBlank(key)) {
      throw new WorkflowEngine.WorkflowException(
        'Attribute key cannot be blank'
      );
    }
    if (key.length() > WorkflowEngine.MAX_ATTRIBUTE_KEY_LENGTH) {
      throw new WorkflowEngine.WorkflowException(
        'Attribute key length exceeds maximum limit of ' +
          WorkflowEngine.MAX_ATTRIBUTE_KEY_LENGTH +
          ' characters: ' +
          key
      );
    }
    if (
      val != null &&
      val.length() > WorkflowEngine.MAX_ATTRIBUTE_VALUE_LENGTH
    ) {
      throw new WorkflowEngine.WorkflowException(
        'Attribute value length exceeds maximum limit of ' +
          WorkflowEngine.MAX_ATTRIBUTE_VALUE_LENGTH +
          ' characters: ' +
          val
      );
    }
  }

  private static List<Workflow_Search_Attribute__c> buildAttributes(
    Id instanceId,
    Map<String, String> attributes
  ) {
    List<Workflow_Search_Attribute__c> records = new List<Workflow_Search_Attribute__c>();
    if (attributes == null || attributes.isEmpty()) {
      return records;
    }
    for (String key : attributes.keySet()) {
      String val = attributes.get(key);
      records.add(
        new Workflow_Search_Attribute__c(
          Workflow_Instance__c = instanceId,
          Key__c = key,
          Value__c = val,
          Key_Value__c = key + '=' + (val == null ? '' : val)
        )
      );
    }
    return records;
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
    return findExistingByKey(new Set<String>{ correlationKey }, includeTerminal)
      .get(WorkflowEngine.normalizeKey(correlationKey));
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
      List<Workflow_Search_Attribute__c> attrsToInsert = buildAttributes(
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
      Workflow_Instance__c winner = findAnyByKey(
          new Set<String>{ correlationKey }
        )
        .get(WorkflowEngine.normalizeKey(correlationKey));
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
    validateAttributes(attributes);

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

    Workflow_Instance__c instance = buildInstance(req);

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

  /**
   * Builds an unsaved Workflow_Instance__c for a start request, resolving the
   * definition version and initial step.
   * @param req the start request describing the workflow to instantiate
   * @return an unsaved Workflow_Instance__c populated from the request and definition
   */
  // Candidate (localName, namespace) pairs used to authorize a workflow name
  // against ApexTypeImplementor with and without its resolved namespace prefix.
  private class WorkflowNameCandidates {
    String localName1;
    String ns1;
    String localName2;
    String ns2;
  }

  private static Workflow_Instance__c buildInstance(
    WorkflowEngine.StartRequest req
  ) {
    Workflow_Instance__c instance = new Workflow_Instance__c();
    Type startWflowType = WorkflowTypeResolver.resolve(
      req.workflowName,
      WorkflowTypeResolver.extractNamespace(req.workflowName)
    );
    instance.Workflow_Name__c = startWflowType != null
      ? String.valueOf(startWflowType)
      : req.workflowName;
    instance.Status__c = 'Pending';
    instance.Correlation_Key__c = req.correlationKey;
    instance.Parent_Instance__c = req.parentInstanceId;
    instance.Causation_Id__c = resolveCausationId(req);

    validateWorkflowAuthorization(req);
    applyDefinitionMetadata(instance, req);
    return instance;
  }

  private static String resolveCausationId(WorkflowEngine.StartRequest req) {
    if (String.isBlank(req.causationId)) {
      return req.parentInstanceId;
    }
    String finalCausationId = req.causationId;
    if (finalCausationId.startsWith('key:')) {
      Map<String, Object> payload = new Map<String, Object>{
        'k' => finalCausationId.substring(4),
        't' => System.now().getTime() + 1000
      };
      finalCausationId = 'key:' + JSON.serialize(payload);
    }
    return finalCausationId;
  }

  // Authorize the workflow name against ApexTypeImplementor once per name
  // (memoized in validatedWorkflows); throws when no authorized implementor
  // matches either candidate (local or fully-qualified) form.
  private static void validateWorkflowAuthorization(
    WorkflowEngine.StartRequest req
  ) {
    if (String.isBlank(req.workflowName)) {
      return;
    }
    String wflowKey = req.workflowName.toLowerCase();
    if (validatedWorkflows.containsKey(wflowKey)) {
      return;
    }
    WorkflowNameCandidates c = resolveNameCandidates(req.workflowName);
    List<ApexTypeImplementor> queryResults = [
      SELECT ClassName, ClassNamespacePrefix
      FROM ApexTypeImplementor
      WHERE
        ClassName IN (:c.localName1, :c.localName2)
        AND ClassNamespacePrefix IN (:c.ns1, :c.ns2)
        AND InterfaceName IN (
          'WorkflowDefinition',
          'VersionedWorkflow',
          'ErrorRoutingWorkflow'
        )
      WITH SYSTEM_MODE
    ];
    if (!matchesAuthorizedImpl(queryResults, c)) {
      throw new WorkflowEngine.WorkflowException(
        'Unauthorized or invalid workflow definition: ' + req.workflowName
      );
    }
    validatedWorkflows.put(wflowKey, true);
  }

  private static WorkflowNameCandidates resolveNameCandidates(
    String workflowName
  ) {
    WorkflowNameCandidates c = new WorkflowNameCandidates();
    c.localName1 = workflowName;
    c.ns1 = '';
    c.localName2 = workflowName;
    c.ns2 = '';
    Type resolvedWflowType = WorkflowTypeResolver.resolve(
      workflowName,
      WorkflowTypeResolver.extractNamespace(workflowName)
    );
    if (resolvedWflowType != null) {
      String fqName = String.valueOf(resolvedWflowType);
      if (fqName.contains('.')) {
        c.ns1 = fqName.substringBefore('.');
        c.localName1 = fqName.substringAfter('.');
        c.ns2 = '';
        c.localName2 = fqName;
      } else {
        c.localName1 = fqName;
        c.localName2 = fqName;
      }
    }
    return c;
  }

  private static Boolean matchesAuthorizedImpl(
    List<ApexTypeImplementor> queryResults,
    WorkflowNameCandidates c
  ) {
    for (ApexTypeImplementor impl : queryResults) {
      String implNs = String.isBlank(impl.ClassNamespacePrefix)
        ? ''
        : impl.ClassNamespacePrefix;
      if (
        (impl.ClassName.equalsIgnoreCase(c.localName1) &&
        implNs.equalsIgnoreCase(c.ns1)) ||
        (impl.ClassName.equalsIgnoreCase(c.localName2) &&
        implNs.equalsIgnoreCase(c.ns2))
      ) {
        return true;
      }
    }
    return false;
  }

  private static void applyDefinitionMetadata(
    Workflow_Instance__c instance,
    WorkflowEngine.StartRequest req
  ) {
    Type wflowType = WorkflowTypeResolver.resolve(
      req.workflowName,
      WorkflowTypeResolver.extractNamespace(req.workflowName)
    );
    if (wflowType == null) {
      instance.Definition_Version__c = 1;
      return;
    }
    Object defObj = wflowType.newInstance();
    if (defObj instanceof VersionedWorkflow) {
      instance.Definition_Version__c = ((VersionedWorkflow) defObj)
        .getLatestVersion();
    } else {
      instance.Definition_Version__c = 1;
    }
    if (defObj instanceof WorkflowDefinition) {
      instance.Current_Step__c = ((WorkflowDefinition) defObj).getInitialStep();
    }
    if (defObj instanceof ExecutionTimeoutConfigurable) {
      Integer timeoutSecs = ((ExecutionTimeoutConfigurable) defObj)
        .getExecutionTimeoutSeconds();
      if (timeoutSecs != null) {
        instance.Deadline_At__c = DateTime.now().addSeconds(timeoutSecs);
      }
    }
  }

  /**
   * Fast path for a single requested key: one indexed LIMIT 1 query returns the
   * single most-relevant row (an active instance preferred via NULLS FIRST, else
   * the newest in-window terminal), bounding the row governor regardless of how
   * many historical terminal runs the key has.
   * @param keys the single-element requested key set
   * @param terminalEnabled when true, allow an in-window terminal instance to win
   * @return the (at most one) resolved key-to-instance mapping
   */
  private static Map<String, Workflow_Instance__c> findSingleKeyWinner(
    Set<String> keys,
    Boolean terminalEnabled
  ) {
    Map<String, Workflow_Instance__c> result = new Map<String, Workflow_Instance__c>();
    DateTime windowStart = terminalEnabled
      ? dedupWindowStart()
      : DateTime.now().addYears(1000);
    for (Workflow_Instance__c inst : [
      SELECT Id, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        Correlation_Key__c IN :keys
        AND (Status__c IN :WorkflowEngine.ACTIVE_STATUSES
        OR Terminal_At__c >= :windowStart)
      WITH SYSTEM_MODE
      ORDER BY Terminal_At__c DESC NULLS FIRST, CreatedDate DESC
      LIMIT 1
    ]) {
      result.put(WorkflowEngine.normalizeKey(inst.Correlation_Key__c), inst);
    }
    return result;
  }

  /**
   * Computes the maximum in-window Terminal_At__c per remaining key via an
   * aggregate (each grouped result counts as a single SOQL row, so a hot key
   * cannot exhaust the row limit), filling maxTimeByKey and returning the set of
   * distinct max timestamps for the follow-up bounded fetch.
   * @param remaining the keys still unresolved after the active-instance pass
   * @param windowStart the dedup-window lower bound
   * @param maxTimeByKey out: normalized key to its max Terminal_At__c
   * @return the distinct max timestamps across the remaining keys
   */
  private static Set<Datetime> computeMaxTerminalTimes(
    Set<String> remaining,
    DateTime windowStart,
    Map<String, Datetime> maxTimeByKey
  ) {
    Set<Datetime> maxTimes = new Set<Datetime>();
    for (AggregateResult ar : [
      SELECT Correlation_Key__c ck, MAX(Terminal_At__c) mt
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :remaining AND Terminal_At__c >= :windowStart
      WITH SYSTEM_MODE
      GROUP BY Correlation_Key__c
    ]) {
      Datetime mt = (Datetime) ar.get('mt');
      if (mt == null) {
        continue;
      }
      String n = WorkflowEngine.normalizeKey((String) ar.get('ck'));
      Datetime existing = maxTimeByKey.get(n);
      if (existing == null || mt > existing) {
        maxTimeByKey.put(n, mt);
      }
      maxTimes.add(mt);
    }
    return maxTimes;
  }

  /**
   * Bulk terminal pass (phase 2): resolves the most-recent in-window terminal
   * instance for each key not already resolved to an active instance. Mutates
   * result in place.
   * @param keys the full requested key set
   * @param result the accumulating key-to-instance map to extend
   */
  private static void resolveTerminalWinners(
    Set<String> keys,
    Map<String, Workflow_Instance__c> result
  ) {
    Set<String> remaining = new Set<String>();
    for (String k : keys) {
      if (!result.containsKey(WorkflowEngine.normalizeKey(k))) {
        remaining.add(k);
      }
    }
    if (remaining.isEmpty()) {
      return;
    }

    DateTime windowStart = dedupWindowStart();
    Map<String, Datetime> maxTimeByKey = new Map<String, Datetime>();
    Set<Datetime> maxTimes = computeMaxTerminalTimes(
      remaining,
      windowStart,
      maxTimeByKey
    );
    if (maxTimes.isEmpty()) {
      return;
    }

    for (Workflow_Instance__c inst : [
      SELECT Id, Correlation_Key__c, Terminal_At__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :remaining AND Terminal_At__c IN :maxTimes
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
    ]) {
      String n = WorkflowEngine.normalizeKey(inst.Correlation_Key__c);
      if (
        !result.containsKey(n) && inst.Terminal_At__c == maxTimeByKey.get(n)
      ) {
        result.put(n, inst);
      }
    }
  }

  /**
   * Resolves the dedup-winner instance for each correlation key: an active
   * instance if one exists, otherwise (when includeTerminal is true) the most
   * recent terminal instance that became terminal within the configured dedup
   * window. The returned map is keyed by the normalized correlation key.
   * @param keys normalized correlation keys to resolve
   * @param includeTerminal when true, allow a recently-terminal instance to win
   * @return map of normalized key to its dedup-winning instance
   */
  private static Map<String, Workflow_Instance__c> findExistingByKey(
    Set<String> keys,
    Boolean includeTerminal
  ) {
    Map<String, Workflow_Instance__c> result = new Map<String, Workflow_Instance__c>();
    if (keys == null || keys.isEmpty()) {
      return result;
    }
    Boolean terminalEnabled =
      includeTerminal &&
      WorkflowEngine.dedupWindowMinutes != null &&
      WorkflowEngine.dedupWindowMinutes > 0;

    // Fast path: a single key needs only the single most-relevant row. SOQL
    // equality is case-insensitive, so a stored "Foo" matches a requested "foo".
    if (keys.size() == 1) {
      return findSingleKeyWinner(keys, terminalEnabled);
    }

    // Bulk path: resolve each key independently so no single hot key can crowd
    // out another, and without reading every historical terminal row.
    // 1) Active instances — bounded to at most one per key by the unique
    //    Active_Correlation_Key__c index.
    for (Workflow_Instance__c inst : [
      SELECT Id, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        Correlation_Key__c IN :keys
        AND Status__c IN :WorkflowEngine.ACTIVE_STATUSES
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
    ]) {
      String n = WorkflowEngine.normalizeKey(inst.Correlation_Key__c);
      if (!result.containsKey(n)) {
        result.put(n, inst);
      }
    }
    if (!terminalEnabled) {
      return result;
    }

    // 2) Most-recent terminal per key not already resolved to an active instance.
    resolveTerminalWinners(keys, result);
    return result;
  }

  /**
   * Resolves the existing instance per key regardless of the dedup window,
   * preferring an active instance then the most recent terminal one. Used as the
   * post-DUPLICATE_VALUE concurrency backstop, where a sibling is known to exist
   * and the loser must always resolve to the winner per the get-or-start
   * contract (even if the winner completed mid-race, and even when the window is
   * disabled). Row-bounded for the same governor-safety reason as
   * findExistingByKey.
   * @param keys normalized correlation keys to resolve
   * @return map of normalized key to the preferred (active, else latest terminal)
   * instance
   */
  private static Map<String, Workflow_Instance__c> findAnyByKey(
    Set<String> keys
  ) {
    Map<String, Workflow_Instance__c> result = new Map<String, Workflow_Instance__c>();
    if (keys == null || keys.isEmpty()) {
      return result;
    }
    Integer rowLimit = keys.size() == 1 ? 1 : WorkflowEngine.dedupLookupRowCap;
    for (Workflow_Instance__c inst : [
      SELECT Id, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :keys
      WITH SYSTEM_MODE
      ORDER BY Terminal_At__c DESC NULLS FIRST, CreatedDate DESC
      LIMIT :rowLimit
    ]) {
      String normalized = WorkflowEngine.normalizeKey(inst.Correlation_Key__c);
      if (!result.containsKey(normalized)) {
        result.put(normalized, inst);
      }
    }
    return result;
  }

  /**
   * Lower bound for the terminal dedup window. When the window is at its
   * minimum (<= 0) a far-future sentinel is returned so no terminal instance
   * matches, preserving active-only dedup behavior. The window is clamped to a
   * safe maximum so a misconfigured value cannot underflow the valid DateTime
   * range.
   * @return the lower-bound timestamp for terminal dedup, or a far-future sentinel
   * when the window is disabled
   */
  private static DateTime dedupWindowStart() {
    if (
      WorkflowEngine.dedupWindowMinutes != null &&
      WorkflowEngine.dedupWindowMinutes > 0
    ) {
      Integer minutes = Math.min(
        WorkflowEngine.dedupWindowMinutes,
        MAX_DEDUP_WINDOW_MINUTES
      );
      return DateTime.now().addMinutes(-minutes);
    }
    return DateTime.now().addYears(1000);
  }

  // Mutable accumulator threaded through the startOrGet phase helpers so each
  // helper stays within the parameter and complexity budgets.
  private class StartOrGetRun {
    List<WorkflowEngine.StartRequest> requests;
    List<WorkflowEngine.StartResult> results;
    List<Workflow_Instance__c> toInsert;
    List<Integer> insertReqIndexes;
    List<Workflow_Instance__c> insertedInstances = new List<Workflow_Instance__c>();
    List<Integer> insertedReqIndexes = new List<Integer>();
    Set<String> concurrentLoserKeys = new Set<String>();
    Set<Id> parkedIds = new Set<Id>();
    Set<Id> deferTimeoutIds = new Set<Id>();
    List<Workflow_Instance__c> instancesToPark = new List<Workflow_Instance__c>();
  }

  // Candidate class-name / namespace sets to query for workflow-name validation,
  // plus the raw-spelling back-references keyed by resolved class name.
  private class WorkflowNameQuery {
    Set<String> localNames = new Set<String>();
    Set<String> namespaces = new Set<String>();
    Map<String, List<String>> rawNamesByResolved = new Map<String, List<String>>();
  }

  // §1: validate each request and gather correlation keys; pre-validate any
  // not-yet-cached workflow names in bulk via ApexTypeImplementor.
  private static Set<String> validateAndPrevalidateStarts(
    List<WorkflowEngine.StartRequest> requests
  ) {
    Set<String> correlationKeys = new Set<String>();
    Set<String> workflowNamesToQuery = new Set<String>();
    for (WorkflowEngine.StartRequest req : requests) {
      if (req == null) {
        continue;
      }
      WorkflowPayloadOffload.validateCorrelationKey(req.correlationKey);
      validateAttributes(req.attributes);
      if (String.isNotBlank(req.correlationKey)) {
        correlationKeys.add(req.correlationKey);
      }
      if (String.isNotBlank(req.workflowName)) {
        String wflowKey = req.workflowName.toLowerCase();
        if (!validatedWorkflows.containsKey(wflowKey)) {
          workflowNamesToQuery.add(req.workflowName);
        }
      }
    }

    if (!workflowNamesToQuery.isEmpty()) {
      prevalidateWorkflowNames(workflowNamesToQuery);
    }
    return correlationKeys;
  }

  // Query ApexTypeImplementor for the candidate class/namespace pairs and mark
  // the matching workflow names validated (both resolved and raw spellings).
  private static void prevalidateWorkflowNames(
    Set<String> workflowNamesToQuery
  ) {
    WorkflowNameQuery q = buildWorkflowNameQuery(workflowNamesToQuery);
    Set<String> localNamesToQuery = q.localNames;
    Set<String> namespacesToQuery = q.namespaces;

    for (ApexTypeImplementor impl : [
      SELECT ClassName, ClassNamespacePrefix
      FROM ApexTypeImplementor
      WHERE
        ClassName IN :localNamesToQuery
        AND ClassNamespacePrefix IN :namespacesToQuery
        AND InterfaceName IN (
          'WorkflowDefinition',
          'VersionedWorkflow',
          'ErrorRoutingWorkflow'
        )
      WITH SYSTEM_MODE
    ]) {
      String matchName = String.isBlank(impl.ClassNamespacePrefix)
        ? impl.ClassName
        : (impl.ClassNamespacePrefix + '.' + impl.ClassName);
      String matchLower = matchName.toLowerCase();
      validatedWorkflows.put(matchLower, true);

      if (q.rawNamesByResolved.containsKey(matchLower)) {
        for (String rawName : q.rawNamesByResolved.get(matchLower)) {
          validatedWorkflows.put(rawName.toLowerCase(), true);
        }
      }
    }
  }

  // Resolve each raw workflow name into the local-name/namespace candidates to
  // query, tracking which raw spellings map to each resolved class.
  private static WorkflowNameQuery buildWorkflowNameQuery(
    Set<String> workflowNamesToQuery
  ) {
    WorkflowNameQuery q = new WorkflowNameQuery();
    for (String rawName : workflowNamesToQuery) {
      Type resolved = WorkflowTypeResolver.resolve(
        rawName,
        WorkflowTypeResolver.extractNamespace(rawName)
      );
      String localName1 = rawName;
      String ns1 = '';
      String localName2 = rawName;
      String ns2 = '';
      if (resolved != null) {
        String fqName = String.valueOf(resolved);
        String resName = fqName.toLowerCase();
        if (!q.rawNamesByResolved.containsKey(resName)) {
          q.rawNamesByResolved.put(resName, new List<String>());
        }
        q.rawNamesByResolved.get(resName).add(rawName);

        if (fqName.contains('.')) {
          ns1 = fqName.substringBefore('.');
          localName1 = fqName.substringAfter('.');
          ns2 = '';
          localName2 = fqName;
        } else {
          localName1 = fqName;
          localName2 = fqName;
        }
      }
      q.localNames.add(localName1);
      q.localNames.add(localName2);
      q.namespaces.add(ns1);
      q.namespaces.add(ns2);
    }
    return q;
  }

  // §3: per request, dedup to an existing/intra-batch instance or queue a fresh
  // instance for insertion, populating run.toInsert / run.insertReqIndexes.
  private static void decideStartRequests(
    StartOrGetRun run,
    Map<String, Workflow_Instance__c> existingByKey
  ) {
    List<WorkflowEngine.StartRequest> requests = run.requests;
    List<WorkflowEngine.StartResult> results = run.results;
    for (Integer i = 0; i < requests.size(); i++) {
      results.add(null);
    }
    List<Workflow_Instance__c> toInsert = new List<Workflow_Instance__c>();
    List<Integer> insertReqIndexes = new List<Integer>();
    Set<String> newKeysInBatch = new Set<String>();

    for (Integer i = 0; i < requests.size(); i++) {
      WorkflowEngine.StartRequest req = requests[i];
      if (req == null) {
        continue;
      }
      String key = req.correlationKey;
      String normKey = WorkflowEngine.normalizeKey(key);

      if (String.isNotBlank(key) && existingByKey.containsKey(normKey)) {
        results[i] = new WorkflowEngine.StartResult(
          existingByKey.get(normKey).Id
        );
        continue;
      }
      if (String.isNotBlank(key) && newKeysInBatch.contains(normKey)) {
        // Intra-batch duplicate; resolved to the sibling's Id after insert.
        continue;
      }

      toInsert.add(buildInstance(req));
      insertReqIndexes.add(i);
      if (String.isNotBlank(key)) {
        newKeysInBatch.add(normKey);
      }
    }
    run.toInsert = toInsert;
    run.insertReqIndexes = insertReqIndexes;
  }

  // §4a: insert the fresh instances, resolving new results and tolerating
  // per-row DUPLICATE_VALUE losers; a genuine failure deletes siblings + throws.
  private static void insertFreshInstances(StartOrGetRun run) {
    List<Workflow_Instance__c> toInsert = run.toInsert;
    if (toInsert.isEmpty()) {
      return;
    }
    Database.SaveResult[] saveResults = Database.insert(
      toInsert,
      false,
      AccessLevel.SYSTEM_MODE
    );
    String genuineError = null;
    for (Integer j = 0; j < saveResults.size(); j++) {
      String rowError = processStartInsertRow(run, saveResults[j], j);
      if (rowError != null && genuineError == null) {
        genuineError = rowError;
      }
    }
    // A genuine (non-duplicate) row failure restores all-or-none semantics:
    // delete every sibling row that succeeded in this partial insert (no
    // savepoint is spent on the all-success path) and surface the error so no
    // orphan Pending instances are left behind.
    if (genuineError != null) {
      if (!run.insertedInstances.isEmpty()) {
        Database.delete(run.insertedInstances, true, AccessLevel.SYSTEM_MODE);
      }
      throw new WorkflowEngine.WorkflowException(
        'Failed to start workflow: ' + genuineError
      );
    }
  }

  // Handle one insert save-result row: record a success/new result or a
  // concurrent DUPLICATE_VALUE loser key. Returns a genuine error message
  // (a non-duplicate failure, or a duplicate on a blank key) or null.
  private static String processStartInsertRow(
    StartOrGetRun run,
    Database.SaveResult sr,
    Integer j
  ) {
    Integer reqIdx = run.insertReqIndexes[j];
    if (sr.isSuccess()) {
      Workflow_Instance__c inst = run.toInsert[j];
      run.insertedInstances.add(inst);
      run.insertedReqIndexes.add(reqIdx);
      run.results[reqIdx] = new WorkflowEngine.StartResult(inst.Id).markNew();
      return null;
    }
    Boolean isDup = isDuplicateSaveError(sr);
    String key = run.requests[reqIdx].correlationKey;
    if (isDup && String.isNotBlank(key)) {
      run.concurrentLoserKeys.add(key);
      return null;
    }
    return sr.getErrors()[0].getMessage();
  }

  /**
   * @description True when every error on the save result is a DUPLICATE_VALUE.
   * Public so the bulk start pipeline and the signal claim/consume paths on
   * {@link WorkflowEngine} share one duplicate-detection predicate.
   * @param sr the DML save result to classify
   * @return true when every error on the result is a DUPLICATE_VALUE
   */
  public static Boolean isDuplicateSaveError(Database.SaveResult sr) {
    for (Database.Error err : sr.getErrors()) {
      if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
        return true;
      }
    }
    return false;
  }

  // §4b: insert search-attribute rows for the freshly inserted instances.
  private static void insertStartSearchAttributes(StartOrGetRun run) {
    if (run.insertedInstances.isEmpty()) {
      return;
    }
    List<Workflow_Search_Attribute__c> attrsToInsert = new List<Workflow_Search_Attribute__c>();
    for (Integer j = 0; j < run.insertedInstances.size(); j++) {
      WorkflowEngine.StartRequest req = run.requests[run.insertedReqIndexes[j]];
      Workflow_Instance__c instance = run.insertedInstances[j];
      if (req.attributes != null && !req.attributes.isEmpty()) {
        for (String key : req.attributes.keySet()) {
          String val = req.attributes.get(key);
          attrsToInsert.add(
            new Workflow_Search_Attribute__c(
              Workflow_Instance__c = instance.Id,
              Key__c = key,
              Value__c = val,
              Key_Value__c = key + '=' + (val == null ? '' : val)
            )
          );
        }
      }
    }
    if (!attrsToInsert.isEmpty()) {
      Database.insert(attrsToInsert, true, AccessLevel.SYSTEM_MODE);
    }
  }

  // §5a: resolve remaining (intra-batch / concurrent-loser) results by key.
  private static void fillRemainingStartResults(StartOrGetRun run) {
    Map<String, Id> resolvedIdByKey = buildResolvedIdByKey(run);
    List<WorkflowEngine.StartRequest> requests = run.requests;
    List<WorkflowEngine.StartResult> results = run.results;
    for (Integer i = 0; i < requests.size(); i++) {
      if (requests[i] == null || results[i] != null) {
        continue;
      }
      String normKey = WorkflowEngine.normalizeKey(requests[i].correlationKey);
      if (
        String.isNotBlank(requests[i].correlationKey) &&
        resolvedIdByKey.containsKey(normKey)
      ) {
        results[i] = new WorkflowEngine.StartResult(
          resolvedIdByKey.get(normKey)
        );
      }
    }
  }

  // Build the normalized-key -> Id map from inserted instances and any
  // concurrent winners located for DUPLICATE_VALUE loser keys.
  private static Map<String, Id> buildResolvedIdByKey(StartOrGetRun run) {
    Map<String, Id> resolvedIdByKey = new Map<String, Id>();
    for (Integer j = 0; j < run.insertedInstances.size(); j++) {
      String key = run.requests[run.insertedReqIndexes[j]].correlationKey;
      if (String.isNotBlank(key)) {
        resolvedIdByKey.put(
          WorkflowEngine.normalizeKey(key),
          run.insertedInstances[j].Id
        );
      }
    }
    if (!run.concurrentLoserKeys.isEmpty()) {
      Map<String, Workflow_Instance__c> winners = findAnyByKey(
        run.concurrentLoserKeys
      );
      for (String normalized : winners.keySet()) {
        if (!resolvedIdByKey.containsKey(normalized)) {
          resolvedIdByKey.put(normalized, winners.get(normalized).Id);
        }
      }
    }
    return resolvedIdByKey;
  }

  // §5b safety net: a lingering unresolved (non-null) request would mean a
  // duplicate loser whose winner could not be found; roll back and surface it.
  private static void assertAllStartsResolved(StartOrGetRun run) {
    List<WorkflowEngine.StartRequest> requests = run.requests;
    List<WorkflowEngine.StartResult> results = run.results;
    List<String> unresolvedKeys = new List<String>();
    for (Integer i = 0; i < requests.size(); i++) {
      if (requests[i] == null) {
        continue;
      }
      if (results[i] == null) {
        unresolvedKeys.add(requests[i].correlationKey);
      }
    }

    if (unresolvedKeys.isEmpty()) {
      return;
    }
    if (!run.insertedInstances.isEmpty()) {
      Database.delete(run.insertedInstances, true, AccessLevel.SYSTEM_MODE);
    }
    throw new WorkflowEngine.WorkflowException(
      'Failed to resolve workflow start for correlation key(s): ' +
      String.join(unresolvedKeys, ', ')
    );
  }

  // §6: resolve/persist input payloads for the freshly inserted instances.
  private static void resolveStartInputPayloads(StartOrGetRun run) {
    for (Integer j = 0; j < run.insertedInstances.size(); j++) {
      WorkflowEngine.StartRequest req = run.requests[run.insertedReqIndexes[j]];
      Workflow_Instance__c instance = run.insertedInstances[j];
      String inputJson = (req.inputJson != null)
        ? req.inputJson
        : ((req.input != null) ? JSON.serialize(req.input) : null);
      instance.Input__c = WorkflowPayloadOffload.savePayloadIfNeeded(
        instance.Id,
        inputJson,
        'Input_' + instance.Id
      );
    }
    if (!run.insertedInstances.isEmpty()) {
      Database.update(run.insertedInstances, true, AccessLevel.SYSTEM_MODE);
    }
  }

  // Operator pause gate (bulk path — used by scheduled jobs and the Flow
  // invocable): instances whose definition is paused are parked at start. They
  // get a Pending initial step with NO timeout clock and are excluded from
  // timeout scheduling and the initial enqueue, mirroring the scalar doStart.
  private static void applyStartPauseGate(StartOrGetRun run) {
    if (!WorkflowPauseGate.anyPaused()) {
      return;
    }
    for (Workflow_Instance__c instance : run.insertedInstances) {
      if (WorkflowPauseGate.isDefinitionPaused(instance.Workflow_Name__c)) {
        instance.Status__c = 'Paused';
        run.parkedIds.add(instance.Id);
        run.instancesToPark.add(instance);
      }
    }
  }

  // Concurrency-bounded workflows defer the initial timeout clock until the
  // admission gate wins a slot (mirrors doStart). A bounded first step is enqueued
  // so its RUN_STEP reaches the gate, but a still-Pending overflow item sitting in
  // the event/queue backlog during a burst would be failed by the timeout sweep
  // before it ever reaches the gate to park. Admission re-arms the timeout via
  // reArmTimeoutsForResume. isConfigured is memoized per name, so this is bulk-safe.
  private static void applyStartConcurrencyGate(StartOrGetRun run) {
    List<Workflow_Instance__c> deferredToMark = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c instance : run.insertedInstances) {
      if (ConcurrencyGate.isConfigured(instance.Workflow_Name__c)) {
        run.deferTimeoutIds.add(instance.Id);
        // Durable awaiting-admission marker (see doStart): the pre-start watchdog
        // keys its null-deadline skip off this, not the live CMDT, so a ceiling added
        // later cannot silence a genuine unbounded pre-start watchdog. Cleared on
        // admission. Parked-at-start instances are handled by instancesToPark below.
        if (!run.parkedIds.contains(instance.Id)) {
          deferredToMark.add(
            new Workflow_Instance__c(
              Id = instance.Id,
              Concurrency_Parked__c = true
            )
          );
        }
      }
    }
    if (!deferredToMark.isEmpty()) {
      Database.update(deferredToMark, true, AccessLevel.SYSTEM_MODE);
    }
  }

  // §7: construct initial Step Execution logs for the inserted instances.
  private static void buildInitialStepExecs(StartOrGetRun run) {
    List<Workflow_Step_Execution__c> stepExecs = new List<Workflow_Step_Execution__c>();
    for (Workflow_Instance__c instance : run.insertedInstances) {
      if (String.isBlank(instance.Current_Step__c)) {
        continue;
      }
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = instance.Current_Step__c;
      stepExec.Status__c = 'Pending';
      stepExec.Input__c = instance.Input__c;
      stepExec.Retry_Count__c = 0;
      // No timeout clock for a parked step (see doStart) or a bounded start awaiting
      // admission — either would otherwise pollute the watchdog timeout batch or fail
      // a still-Pending bounded start before admission. Resume/admission re-establishes it.
      if (
        !run.parkedIds.contains(instance.Id) &&
        !run.deferTimeoutIds.contains(instance.Id)
      ) {
        Integer timeout = WorkflowStepTimeoutConfig.getStepTimeoutSeconds(
          instance.Current_Step__c,
          WorkflowTypeResolver.extractNamespace(instance.Workflow_Name__c)
        );
        if (timeout != null && timeout > 0) {
          stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
        }
      }
      stepExecs.add(stepExec);
    }
    if (!stepExecs.isEmpty()) {
      Database.insert(stepExecs, true, AccessLevel.SYSTEM_MODE);
    }
  }

  // §8: schedule timeout jobs for non-parked, non-deferred instances and enqueue
  // orchestrators for all non-parked instances.
  private static void scheduleAndEnqueueStarts(StartOrGetRun run) {
    List<Workflow_Instance__c> instancesToSchedule = new List<Workflow_Instance__c>();
    List<Id> instanceIds = new List<Id>();
    for (Workflow_Instance__c instance : run.insertedInstances) {
      if (run.parkedIds.contains(instance.Id)) {
        continue;
      }
      instanceIds.add(instance.Id);
      if (!run.deferTimeoutIds.contains(instance.Id)) {
        instancesToSchedule.add(instance);
      }
    }
    if (!instancesToSchedule.isEmpty()) {
      WorkflowTimeoutArming.scheduleTimeoutJobsForInstances(
        instancesToSchedule
      );
    }
    if (!instanceIds.isEmpty()) {
      WorkflowOrchestratorEnqueue.enqueueOrchestrators(instanceIds);
    }
  }
}
