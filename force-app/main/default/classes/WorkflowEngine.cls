public inherited sharing class WorkflowEngine {
  public static Boolean disableQueueableInTest = false;
  public static Integer watchdogDelayMinutes = 10;
  public static Boolean useDynamicScheduling = true;
  // Operator toggle (Revenant_Config__mdt.Publish_Lifecycle_Events__c): when true
  // the engine publishes a Workflow_Lifecycle__e event on terminal transitions.
  public static Boolean publishLifecycleEvents = true;

  // Get-or-start dedup window in minutes. Redelivered starts whose correlation
  // key matches a terminal instance that became terminal within this many
  // minutes resolve to that instance instead of spawning a duplicate. Set to 0
  // to preserve active-only dedup behavior.
  public static Integer dedupWindowMinutes = 1440;

  // Minutes of inactivity after which a Suspended instance with no active resume
  // mechanism is classified as stalled on the dashboard. Configurable via
  // Revenant_Config__mdt.Stale_Threshold_Minutes__c; default 60 minutes.
  public static Integer staleThresholdMinutes = 60;

  // Instances in these statuses are considered in-flight; a start that collides
  // with one of them always dedups to the existing instance.
  private static final Set<String> ACTIVE_STATUSES = new Set<String>{
    'Pending',
    'Running',
    'Suspended',
    'Compensating',
    'Cancelling',
    // A stalled rollback is non-terminal: it still has un-reversed side effects and
    // can be resumed, so it must keep reserving its correlation key to prevent a
    // duplicate active workflow from starting with the same key while half-undone.
    'CompensationFailed'
  };

  // Upper bound (~100 years) applied to the dedup window before it is subtracted
  // from "now", so a large/misconfigured Dedup_Window_Minutes__c cannot push the
  // computed lower bound outside Salesforce's valid DateTime range and fault
  // every start.
  private static final Integer MAX_DEDUP_WINDOW_MINUTES = 52560000;

  // Upper bound on rows read by a single dedup lookup, so a hot correlation key
  // with many historical terminal runs cannot exhaust the SOQL row governor.
  // Single-key lookups (the common start path) read only the top row.
  private static final Integer DEDUP_LOOKUP_ROW_CAP = 10000;

  // Max number of timed-out steps a single watchdog heartbeat will fail. Each failure
  // triggers failWorkflowInstance() (its own SOQL/DML + optional alert queries), so this
  // bounds the heartbeat's governor usage. Remaining timeouts drain on the next heartbeat.
  @TestVisible
  private static Integer WATCHDOG_TIMEOUT_BATCH_SIZE = 50;
  // Max number of sleeping instances a single heartbeat resumes, for the same reason.
  @TestVisible
  private static Integer WATCHDOG_RESUME_BATCH_SIZE = 200;

  static {
    try {
      List<Revenant_Config__mdt> configs = [
        SELECT
          Watchdog_Delay_Minutes__c,
          Use_Dynamic_Scheduling__c,
          Publish_Lifecycle_Events__c,
          Dedup_Window_Minutes__c,
          Stale_Threshold_Minutes__c
        FROM Revenant_Config__mdt
        WHERE DeveloperName = 'Default'
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (!configs.isEmpty()) {
        if (configs[0].Watchdog_Delay_Minutes__c != null) {
          watchdogDelayMinutes = configs[0]
            .Watchdog_Delay_Minutes__c.intValue();
        }
        if (configs[0].Use_Dynamic_Scheduling__c != null) {
          useDynamicScheduling = configs[0].Use_Dynamic_Scheduling__c;
        }
        if (configs[0].Publish_Lifecycle_Events__c != null) {
          publishLifecycleEvents = configs[0].Publish_Lifecycle_Events__c;
        }
        if (configs[0].Dedup_Window_Minutes__c != null) {
          dedupWindowMinutes = configs[0].Dedup_Window_Minutes__c.intValue();
        }
        if (configs[0].Stale_Threshold_Minutes__c != null) {
          staleThresholdMinutes = configs[0]
            .Stale_Threshold_Minutes__c.intValue();
        }
      }
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.WARN,
        'Revenant configuration metadata query failed: ' + ex.getMessage()
      );
    }
  }

  @TestVisible
  private static Set<Id> enqueuedInstanceIds = new Set<Id>();
  // Per-(instance, branch) enqueue dedup so resuming a parallel instance can
  // wake each branch by name without the instance-level dedup blocking siblings.
  @TestVisible
  private static Set<String> enqueuedBranchKeys = new Set<String>();
  public class WorkflowException extends Exception {
  }

  /**
   * Outcome of a get-or-start admission decision. Distinguishes a brand-new
   * instance from an existing instance returned for a deduplicated redelivery.
   */
  public class StartResult {
    public Id instanceId;
    // true when a new instance was inserted; false when an existing instance
    // was returned (deduped active or recently-terminal redelivery).
    public Boolean isNew;

    public StartResult(Id instanceId, Boolean isNew) {
      this.instanceId = instanceId;
      this.isNew = isNew;
    }
  }

  /**
   * Starts a new durable workflow instance (get-or-start). If an instance with
   * the same correlation key already exists within the dedup scope, returns
   * that instance's Id instead of inserting a duplicate.
   */
  public static Id start(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    return doStart(workflowName, correlationKey, input, null).instanceId;
  }

  /**
   * Starts a new durable workflow instance with a parent workflow reference
   * (get-or-start).
   */
  public static Id start(
    String workflowName,
    String correlationKey,
    Object input,
    Id parentInstanceId
  ) {
    return doStart(workflowName, correlationKey, input, parentInstanceId)
      .instanceId;
  }

  /**
   * Get-or-start variant that exposes whether a new instance was created or an
   * existing one was returned.
   */
  public static StartResult startOrGet(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    return doStart(workflowName, correlationKey, input, null);
  }

  public static StartResult startOrGet(
    String workflowName,
    String correlationKey,
    Object input,
    Id parentInstanceId
  ) {
    return doStart(workflowName, correlationKey, input, parentInstanceId, true);
  }

  /**
   * Active-only get-or-start for engine-internal singleton workflows (e.g. the
   * watchdog). Never dedups against terminal instances, so a failed or
   * continued-as-new singleton is always restarted rather than resolving to a
   * dead terminal run within the dedup window.
   */
  public static Id startSingleton(
    String workflowName,
    String correlationKey,
    Object input
  ) {
    return doStart(workflowName, correlationKey, input, null, false).instanceId;
  }

  private static StartResult doStart(
    String workflowName,
    String correlationKey,
    Object input,
    Id parentInstanceId
  ) {
    return doStart(workflowName, correlationKey, input, parentInstanceId, true);
  }

  private static StartResult doStart(
    String workflowName,
    String correlationKey,
    Object input,
    Id parentInstanceId,
    Boolean includeTerminal
  ) {
    validateCorrelationKey(correlationKey);

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
      Workflow_Instance__c match = findExistingByKey(
          new Set<String>{ correlationKey },
          includeTerminal
        )
        .get(normalizeKey(correlationKey));
      if (match != null) {
        return new StartResult(match.Id, false);
      }
    }

    Workflow_Instance__c instance = buildInstance(
      new StartRequest(workflowName, correlationKey, input, parentInstanceId)
    );

    try {
      insert as system instance;
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        // Concurrency backstop: a sibling start won the race on the unique
        // Active_Correlation_Key__c index. A sibling provably exists, so resolve
        // the winner regardless of the dedup window (it may have completed
        // mid-race) and return its Id so the loser is a safe no-op.
        Workflow_Instance__c winner = findAnyByKey(
            new Set<String>{ correlationKey }
          )
          .get(normalizeKey(correlationKey));
        if (winner != null) {
          return new StartResult(winner.Id, false);
        }
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' +
          correlationKey
        );
      }
      throw ex;
    }

    instance.Input__c = savePayloadIfNeeded(
      instance.Id,
      (input != null) ? JSON.serialize(input) : null,
      'Input_' + instance.Id
    );
    update as system instance;

    if (String.isNotBlank(instance.Current_Step__c)) {
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = instance.Current_Step__c;
      stepExec.Status__c = 'Pending';
      stepExec.Input__c = instance.Input__c;
      stepExec.Retry_Count__c = 0;
      Integer timeout = getStepTimeoutSeconds(instance.Current_Step__c);
      if (timeout != null && timeout > 0) {
        stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
      }
      insert as system stepExec;
    }

    // Schedule watchdog for the initial step before executing it
    scheduleTimeoutJobForInstance(instance.Id);

    // Enqueue the first step execution
    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(instance.Id));
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
    return new StartResult(instance.Id, true);
  }

  /**
   * Builds an unsaved Workflow_Instance__c for a start request, resolving the
   * definition version and initial step.
   */
  private static Workflow_Instance__c buildInstance(StartRequest req) {
    Workflow_Instance__c instance = new Workflow_Instance__c();
    instance.Workflow_Name__c = req.workflowName;
    instance.Status__c = 'Pending';
    instance.Correlation_Key__c = req.correlationKey;
    instance.Parent_Instance__c = req.parentInstanceId;

    Type wflowType = Type.forName(req.workflowName);
    if (wflowType != null) {
      Object defObj = wflowType.newInstance();
      if (defObj instanceof VersionedWorkflow) {
        instance.Definition_Version__c = ((VersionedWorkflow) defObj)
          .getLatestVersion();
      } else {
        instance.Definition_Version__c = 1;
      }
      if (defObj instanceof WorkflowDefinition) {
        instance.Current_Step__c = ((WorkflowDefinition) defObj)
          .getInitialStep();
      }
    } else {
      instance.Definition_Version__c = 1;
    }
    return instance;
  }

  /**
   * Canonical form of a correlation key for in-memory dedup maps/sets.
   * Correlation_Key__c is case-insensitive (and the unique
   * Active_Correlation_Key__c index is too), but Apex Map/Set keys are
   * case-sensitive, so keys are lower-cased to match the database semantics.
   */
  private static String normalizeKey(String key) {
    return key == null ? null : key.toLowerCase();
  }

  /**
   * Resolves the dedup-winner instance for each correlation key: an active
   * instance if one exists, otherwise (when includeTerminal is true) the most
   * recent terminal instance that became terminal within the configured dedup
   * window. The returned map is keyed by the normalized correlation key.
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
      dedupWindowMinutes != null &&
      dedupWindowMinutes > 0;

    // Fast path: a single key needs only the single most-relevant row (an active
    // instance preferred via NULLS FIRST, else the newest in-window terminal).
    // One indexed SOQL with LIMIT 1 keeps the common start path to a single
    // query and bounds the row governor regardless of how many historical
    // terminal runs the key has. SOQL equality is case-insensitive, so a stored
    // "Foo" matches a requested "foo".
    if (keys.size() == 1) {
      DateTime windowStart = terminalEnabled
        ? dedupWindowStart()
        : DateTime.now().addYears(1000);
      for (Workflow_Instance__c inst : [
        SELECT Id, Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE
          Correlation_Key__c IN :keys
          AND (Status__c IN :ACTIVE_STATUSES
          OR Terminal_At__c >= :windowStart)
        WITH SYSTEM_MODE
        ORDER BY Terminal_At__c DESC NULLS FIRST, CreatedDate DESC
        LIMIT 1
      ]) {
        result.put(normalizeKey(inst.Correlation_Key__c), inst);
      }
      return result;
    }

    // Bulk path: resolve each key independently so no single hot key can crowd
    // out another, and without reading every historical terminal row.
    // 1) Active instances — bounded to at most one per key by the unique
    //    Active_Correlation_Key__c index.
    for (Workflow_Instance__c inst : [
      SELECT Id, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :keys AND Status__c IN :ACTIVE_STATUSES
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
    ]) {
      String n = normalizeKey(inst.Correlation_Key__c);
      if (!result.containsKey(n)) {
        result.put(n, inst);
      }
    }
    if (!terminalEnabled) {
      return result;
    }

    // 2) Most-recent terminal per key not already resolved to an active
    //    instance. An aggregate yields one MAX(Terminal_At__c) per key (each
    //    grouped result counts as a single row toward the SOQL row limit, so a
    //    hot key cannot exhaust it), then a bounded fetch resolves the Id at
    //    those timestamps. Because the unique active-key index forces terminal
    //    runs of one key to occur serially, their Terminal_At__c values are
    //    distinct, so the fetch matches ~one row per key.
    Set<String> remaining = new Set<String>();
    for (String k : keys) {
      if (!result.containsKey(normalizeKey(k))) {
        remaining.add(k);
      }
    }
    if (remaining.isEmpty()) {
      return result;
    }

    DateTime windowStart = dedupWindowStart();
    Map<String, Datetime> maxTimeByKey = new Map<String, Datetime>();
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
      String n = normalizeKey((String) ar.get('ck'));
      Datetime existing = maxTimeByKey.get(n);
      if (existing == null || mt > existing) {
        maxTimeByKey.put(n, mt);
      }
      maxTimes.add(mt);
    }
    if (maxTimes.isEmpty()) {
      return result;
    }

    for (Workflow_Instance__c inst : [
      SELECT Id, Correlation_Key__c, Terminal_At__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :remaining AND Terminal_At__c IN :maxTimes
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC
    ]) {
      String n = normalizeKey(inst.Correlation_Key__c);
      if (
        !result.containsKey(n) && inst.Terminal_At__c == maxTimeByKey.get(n)
      ) {
        result.put(n, inst);
      }
    }
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
   */
  private static Map<String, Workflow_Instance__c> findAnyByKey(
    Set<String> keys
  ) {
    Map<String, Workflow_Instance__c> result = new Map<String, Workflow_Instance__c>();
    if (keys == null || keys.isEmpty()) {
      return result;
    }
    Integer rowLimit = keys.size() == 1 ? 1 : DEDUP_LOOKUP_ROW_CAP;
    for (Workflow_Instance__c inst : [
      SELECT Id, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c IN :keys
      WITH SYSTEM_MODE
      ORDER BY Terminal_At__c DESC NULLS FIRST, CreatedDate DESC
      LIMIT :rowLimit
    ]) {
      String normalized = normalizeKey(inst.Correlation_Key__c);
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
   */
  private static DateTime dedupWindowStart() {
    if (dedupWindowMinutes != null && dedupWindowMinutes > 0) {
      Integer minutes = Math.min(dedupWindowMinutes, MAX_DEDUP_WINDOW_MINUTES);
      return DateTime.now().addMinutes(-minutes);
    }
    return DateTime.now().addYears(1000);
  }

  public class StartRequest {
    public String workflowName;
    public String correlationKey;
    public Object input;
    public Id parentInstanceId;

    public StartRequest(
      String workflowName,
      String correlationKey,
      Object input
    ) {
      this.workflowName = workflowName;
      this.correlationKey = correlationKey;
      this.input = input;
    }

    public StartRequest(
      String workflowName,
      String correlationKey,
      Object input,
      Id parentInstanceId
    ) {
      this.workflowName = workflowName;
      this.correlationKey = correlationKey;
      this.input = input;
      this.parentInstanceId = parentInstanceId;
    }
  }

  public class ResumeRequest {
    public String correlationKey;
    public Id instanceId;
    public String payload;

    public ResumeRequest(String correlationKey, String payload) {
      this.correlationKey = correlationKey;
      this.payload = payload;
    }

    public ResumeRequest(Id instanceId, String payload) {
      this.instanceId = instanceId;
      this.payload = payload;
    }
  }

  public class SignalRequest {
    public String keyOrId;
    public String signalName;
    public String payload;

    public SignalRequest(String keyOrId, String signalName, String payload) {
      this.keyOrId = keyOrId;
      this.signalName = signalName;
      this.payload = payload;
    }
  }

  /**
   * Starts multiple durable workflow instances in a bulk-friendly transaction
   * (get-or-start). A duplicate correlation key resolves to the existing
   * instance and never faults sibling requests in the same invocation.
   */
  public static List<Id> start(List<StartRequest> requests) {
    List<Id> ids = new List<Id>();
    for (StartResult r : startOrGet(requests)) {
      ids.add(r == null ? null : r.instanceId);
    }
    return ids;
  }

  /**
   * Bulk get-or-start. Returns a result per request (index-aligned) reporting
   * the resolved instance Id and whether it was newly created or deduped.
   */
  public static List<StartResult> startOrGet(List<StartRequest> requests) {
    List<StartResult> results = new List<StartResult>();
    if (requests == null || requests.isEmpty()) {
      return results;
    }

    // 1. Validate and gather correlation keys
    Set<String> correlationKeys = new Set<String>();
    for (StartRequest req : requests) {
      validateCorrelationKey(req.correlationKey);
      if (String.isNotBlank(req.correlationKey)) {
        correlationKeys.add(req.correlationKey);
      }
    }

    // 2. Pre-resolve existing instances within the dedup scope (keyed by the
    //    normalized correlation key to honor case-insensitive matching).
    Map<String, Workflow_Instance__c> existingByKey = findExistingByKey(
      correlationKeys,
      true
    );

    // 3. Decide per request (preserving order): dedup to an existing instance,
    //    dedup to an intra-batch sibling, or build a fresh instance to insert.
    for (Integer i = 0; i < requests.size(); i++) {
      results.add(null);
    }
    List<Workflow_Instance__c> toInsert = new List<Workflow_Instance__c>();
    List<Integer> insertReqIndexes = new List<Integer>();
    Set<String> newKeysInBatch = new Set<String>();

    for (Integer i = 0; i < requests.size(); i++) {
      StartRequest req = requests[i];
      String key = req.correlationKey;
      String normKey = normalizeKey(key);

      if (String.isNotBlank(key) && existingByKey.containsKey(normKey)) {
        results[i] = new StartResult(existingByKey.get(normKey).Id, false);
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

    // 4. Insert fresh instances, tolerating per-row DUPLICATE_VALUE from a
    //    concurrent winner (the unique Active_Correlation_Key__c backstop).
    List<Workflow_Instance__c> insertedInstances = new List<Workflow_Instance__c>();
    List<Integer> insertedReqIndexes = new List<Integer>();
    Set<String> concurrentLoserKeys = new Set<String>();

    if (!toInsert.isEmpty()) {
      Database.SaveResult[] saveResults = Database.insert(
        toInsert,
        false,
        AccessLevel.SYSTEM_MODE
      );
      String genuineError = null;
      for (Integer j = 0; j < saveResults.size(); j++) {
        Database.SaveResult sr = saveResults[j];
        Integer reqIdx = insertReqIndexes[j];
        if (sr.isSuccess()) {
          Workflow_Instance__c inst = toInsert[j];
          insertedInstances.add(inst);
          insertedReqIndexes.add(reqIdx);
          results[reqIdx] = new StartResult(inst.Id, true);
        } else {
          Boolean isDup = false;
          for (Database.Error err : sr.getErrors()) {
            if (err.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
              isDup = true;
              break;
            }
          }
          String key = requests[reqIdx].correlationKey;
          if (isDup && String.isNotBlank(key)) {
            concurrentLoserKeys.add(key);
          } else if (genuineError == null) {
            genuineError = sr.getErrors()[0].getMessage();
          }
        }
      }
      // A genuine (non-duplicate) row failure restores all-or-none semantics:
      // delete every sibling row that succeeded in this partial insert (no
      // savepoint is spent on the all-success path) and surface the error so no
      // orphan Pending instances are left behind.
      if (genuineError != null) {
        if (!insertedInstances.isEmpty()) {
          delete as system insertedInstances;
        }
        throw new WorkflowException(
          'Failed to start workflow: ' + genuineError
        );
      }
    }

    // 5. Build a key -> resolved Id map for newly inserted instances and for
    //    any concurrent winners, then fill remaining (intra-batch / loser)
    //    results. A DUPLICATE_VALUE proves a sibling exists, so losers are
    //    resolved regardless of the dedup window (the winner may have completed
    //    mid-race, including when the window is disabled).
    Map<String, Id> resolvedIdByKey = new Map<String, Id>();
    for (Integer j = 0; j < insertedInstances.size(); j++) {
      String key = requests[insertedReqIndexes[j]].correlationKey;
      if (String.isNotBlank(key)) {
        resolvedIdByKey.put(normalizeKey(key), insertedInstances[j].Id);
      }
    }
    if (!concurrentLoserKeys.isEmpty()) {
      Map<String, Workflow_Instance__c> winners = findAnyByKey(
        concurrentLoserKeys
      );
      for (String normalized : winners.keySet()) {
        if (!resolvedIdByKey.containsKey(normalized)) {
          resolvedIdByKey.put(normalized, winners.get(normalized).Id);
        }
      }
    }
    for (Integer i = 0; i < requests.size(); i++) {
      if (results[i] != null) {
        continue;
      }
      String normKey = normalizeKey(requests[i].correlationKey);
      if (
        String.isNotBlank(requests[i].correlationKey) &&
        resolvedIdByKey.containsKey(normKey)
      ) {
        results[i] = new StartResult(resolvedIdByKey.get(normKey), false);
      }
    }

    // Safety net: every request carries a non-blank key (validated above) and
    // must resolve to an instance. A lingering null would mean a duplicate
    // loser whose winner could not be located; rather than return a null
    // instance Id, roll back this invocation's inserts and surface an error.
    List<String> unresolvedKeys = new List<String>();
    for (Integer i = 0; i < requests.size(); i++) {
      if (results[i] == null) {
        unresolvedKeys.add(requests[i].correlationKey);
      }
    }
    if (!unresolvedKeys.isEmpty()) {
      if (!insertedInstances.isEmpty()) {
        delete as system insertedInstances;
      }
      throw new WorkflowException(
        'Failed to resolve workflow start for correlation key(s): ' +
        String.join(unresolvedKeys, ', ')
      );
    }

    // 6. Resolve input payloads for newly inserted instances
    for (Integer j = 0; j < insertedInstances.size(); j++) {
      StartRequest req = requests[insertedReqIndexes[j]];
      Workflow_Instance__c instance = insertedInstances[j];
      String inputJson = (req.input != null) ? JSON.serialize(req.input) : null;
      instance.Input__c = savePayloadIfNeeded(
        instance.Id,
        inputJson,
        'Input_' + instance.Id
      );
    }
    if (!insertedInstances.isEmpty()) {
      update as system insertedInstances;
    }

    // 7. Construct initial Step Execution logs for inserted instances only
    List<Workflow_Step_Execution__c> stepExecs = new List<Workflow_Step_Execution__c>();
    for (Workflow_Instance__c instance : insertedInstances) {
      if (String.isNotBlank(instance.Current_Step__c)) {
        Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
        stepExec.Workflow_Instance__c = instance.Id;
        stepExec.Step_Name__c = instance.Current_Step__c;
        stepExec.Status__c = 'Pending';
        stepExec.Input__c = instance.Input__c;
        stepExec.Retry_Count__c = 0;
        Integer timeout = getStepTimeoutSeconds(instance.Current_Step__c);
        if (timeout != null && timeout > 0) {
          stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
        }
        stepExecs.add(stepExec);
      }
    }
    if (!stepExecs.isEmpty()) {
      insert as system stepExecs;
    }

    // 8. Schedule timeout jobs and enqueue orchestrators for inserted instances
    scheduleTimeoutJobsForInstances(insertedInstances);

    List<Id> instanceIds = new List<Id>();
    for (Workflow_Instance__c instance : insertedInstances) {
      instanceIds.add(instance.Id);
    }
    enqueueOrchestrators(instanceIds);

    return results;
  }

  /**
   * Resumes a suspended workflow matching the correlation key.
   */
  public static void resume(String correlationKey, String payload) {
    List<Workflow_Instance__c> instances = [
      SELECT Id, Workflow_Name__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Correlation_Key__c = :correlationKey AND Status__c = 'Suspended'
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];

    if (instances.isEmpty()) {
      throw new WorkflowException(
        'No suspended workflow found with correlation key: ' + correlationKey
      );
    }

    Workflow_Instance__c instance = instances[0];
    instance.Status__c = 'Running';
    update as system instance;

    // If there is an active step, we can store the resume payload in its step execution record
    if (String.isNotBlank(instance.Current_Step__c)) {
      List<Workflow_Step_Execution__c> activeSteps = [
        SELECT Id, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instance.Id
          AND Step_Name__c = :instance.Current_Step__c
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      if (!activeSteps.isEmpty()) {
        Workflow_Step_Execution__c stepExec = activeSteps[0];
        stepExec.Status__c = 'Running';
        stepExec.Output__c = savePayloadIfNeeded(
          instance.Id,
          payload,
          'Resume_' + stepExec.Id
        );
        Integer timeout = getStepTimeoutSeconds(instance.Current_Step__c);
        if (timeout != null && timeout > 0) {
          stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
        } else {
          stepExec.Timeout_At__c = null;
        }
        update as system stepExec;
      }
    }

    scheduleTimeoutJobForInstance(instance.Id);

    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(instance.Id));
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  /**
   * Resumes a suspended workflow instance directly by its database ID.
   */
  public static void resumeInstance(Id instanceId, String payload) {
    List<Workflow_Instance__c> instances = [
      SELECT Id, Workflow_Name__c, Current_Step__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId AND Status__c = 'Suspended'
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];

    if (instances.isEmpty()) {
      throw new WorkflowException(
        'No suspended workflow found with ID: ' + instanceId
      );
    }

    Workflow_Instance__c instance = instances[0];
    instance.Status__c = 'Running';
    update as system instance;

    // If there is an active step, we can store the resume payload in its step execution record
    if (String.isNotBlank(instance.Current_Step__c)) {
      List<Workflow_Step_Execution__c> activeSteps = [
        SELECT Id, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instance.Id
          AND Step_Name__c = :instance.Current_Step__c
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      if (!activeSteps.isEmpty()) {
        Workflow_Step_Execution__c stepExec = activeSteps[0];
        stepExec.Status__c = 'Running';
        stepExec.Output__c = savePayloadIfNeeded(
          instance.Id,
          payload,
          'Resume_' + stepExec.Id
        );
        Integer timeout = getStepTimeoutSeconds(instance.Current_Step__c);
        if (timeout != null && timeout > 0) {
          stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
        } else {
          stepExec.Timeout_At__c = null;
        }
        update as system stepExec;
      }
    }

    scheduleTimeoutJobForInstance(instance.Id);

    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(instance.Id));
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  /**
   * Resumes multiple suspended workflows in a bulk-friendly transaction.
   */
  public static void resume(List<ResumeRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    Set<String> keys = new Set<String>();
    Set<Id> ids = new Set<Id>();
    for (ResumeRequest req : requests) {
      if (req.instanceId != null) {
        ids.add(req.instanceId);
      } else if (String.isNotBlank(req.correlationKey)) {
        keys.add(req.correlationKey);
      }
    }

    List<Workflow_Instance__c> instances = [
      SELECT Id, Workflow_Name__c, Current_Step__c, Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE
        (Id IN :ids
        OR Correlation_Key__c IN :keys)
        AND Status__c = 'Suspended'
      WITH SYSTEM_MODE
      FOR UPDATE
    ];

    Map<Id, Workflow_Instance__c> instById = new Map<Id, Workflow_Instance__c>();
    Map<String, Workflow_Instance__c> instByKey = new Map<String, Workflow_Instance__c>();
    for (Workflow_Instance__c inst : instances) {
      instById.put(inst.Id, inst);
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        instByKey.put(inst.Correlation_Key__c, inst);
      }
    }

    // Verify that we found a suspended instance for every request
    for (ResumeRequest req : requests) {
      Workflow_Instance__c inst = null;
      if (req.instanceId != null) {
        inst = instById.get(req.instanceId);
      } else if (String.isNotBlank(req.correlationKey)) {
        inst = instByKey.get(req.correlationKey);
      }
      if (inst == null) {
        throw new WorkflowException(
          'No suspended workflow found with key or ID: ' +
          (req.instanceId != null
            ? (String) req.instanceId
            : req.correlationKey)
        );
      }
    }

    // Gathers active step execution logs for the instances in bulk
    Set<Id> activeInstIds = instById.keySet();
    List<Workflow_Step_Execution__c> allActiveSteps = [
      SELECT Id, Workflow_Instance__c, Step_Name__c, Status__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE Workflow_Instance__c IN :activeInstIds
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    Map<Id, Workflow_Step_Execution__c> latestStepByInstanceId = new Map<Id, Workflow_Step_Execution__c>();
    for (Workflow_Step_Execution__c step : allActiveSteps) {
      if (!latestStepByInstanceId.containsKey(step.Workflow_Instance__c)) {
        Workflow_Instance__c inst = instById.get(step.Workflow_Instance__c);
        if (inst != null && String.isNotBlank(inst.Current_Step__c)) {
          Boolean stepMatches = false;
          if (inst.Current_Step__c.contains(',')) {
            for (String pStep : inst.Current_Step__c.split(',')) {
              if (pStep.trim() == step.Step_Name__c) {
                stepMatches = true;
                break;
              }
            }
          } else if (inst.Current_Step__c == step.Step_Name__c) {
            stepMatches = true;
          }
          if (stepMatches) {
            latestStepByInstanceId.put(step.Workflow_Instance__c, step);
          }
        }
      }
    }

    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    List<Workflow_Step_Execution__c> stepsToUpdate = new List<Workflow_Step_Execution__c>();

    for (ResumeRequest req : requests) {
      Workflow_Instance__c inst = null;
      if (req.instanceId != null) {
        inst = instById.get(req.instanceId);
      } else if (String.isNotBlank(req.correlationKey)) {
        inst = instByKey.get(req.correlationKey);
      }

      if (inst != null) {
        inst.Status__c = 'Running';
        instancesToUpdate.add(inst);

        Workflow_Step_Execution__c stepExec = latestStepByInstanceId.get(
          inst.Id
        );
        if (stepExec != null) {
          stepExec.Status__c = 'Running';
          stepExec.Output__c = savePayloadIfNeeded(
            inst.Id,
            req.payload,
            'Resume_' + stepExec.Id
          );
          Integer timeout = getStepTimeoutSeconds(inst.Current_Step__c);
          if (timeout != null && timeout > 0) {
            stepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
          } else {
            stepExec.Timeout_At__c = null;
          }
          stepsToUpdate.add(stepExec);
        }
      }
    }

    update as system instancesToUpdate;
    if (!stepsToUpdate.isEmpty()) {
      update as system stepsToUpdate;
    }

    scheduleTimeoutJobsForInstances(instancesToUpdate);

    List<Id> instanceIds = new List<Id>();
    for (Workflow_Instance__c inst : instancesToUpdate) {
      instanceIds.add(inst.Id);
    }
    enqueueOrchestrators(instanceIds);
  }

  /**
   * Executes the active step for a workflow instance. Designed to run in a Queueable context.
   */
  public static void runStep(Id instanceId) {
    runStep(instanceId, null);
  }

  public static void runStep(Id instanceId, String stepName) {
    // 1. Fetch instance state (NO FOR UPDATE lock to allow parallel execution and direct callouts)
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Status__c,
        Current_Step__c,
        Input__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Parent_Instance__c,
        Compensation_Stack__c,
        Definition_Version__c,
        Error_Message__c,
        Previous_Run_At__c,
        CreatedDate
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];

    if (instances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instanceId);
    }

    Workflow_Instance__c instance = instances[0];
    if (
      instance.Status__c == 'Completed' ||
      instance.Status__c == 'Failed' ||
      instance.Status__c == 'Compensated' ||
      instance.Status__c == 'CompensationFailed' ||
      instance.Status__c == 'Cancelled' ||
      instance.Status__c == 'ContinuedAsNew'
    ) {
      return; // Already finished
    }

    Boolean isCompensating = (instance.Status__c == 'Compensating' ||
    instance.Status__c == 'Cancelling');
    // A compensation step that SUSPENDed (e.g. waiting on a signal) leaves the
    // instance Suspended; signal() then flips it to Running before re-enqueueing.
    // In either state a latest step ending in '_Compensate' means the instance
    // is still compensating and must route to runCompensationStep, not the
    // forward path -- otherwise a signal-driven compensation is skipped and the
    // instance stays stuck Running with the compensation step pending.
    if (
      instance.Status__c == 'Suspended' ||
      instance.Status__c == 'Running'
    ) {
      // Only treat a trailing-'_Compensate' latest step as a live compensation
      // when the instance's compensation stack actually holds the matching base
      // step. A normal forward step that happens to be named '<x>_Compensate'
      // and is resumed by signal() (Suspended/Running with no -- or unrelated --
      // stack) must NOT be misrouted to runCompensationStep, which would see no
      // matching stack entry and mark the instance Compensated instead of
      // resuming it. The forward execution of compensatable steps grows the
      // stack too, so a non-empty stack alone is not enough; require the base
      // name to be on it.
      List<String> compStack = String.isNotBlank(
          instance.Compensation_Stack__c
        )
        ? (List<String>) JSON.deserialize(
            instance.Compensation_Stack__c,
            List<String>.class
          )
        : new List<String>();
      if (!compStack.isEmpty()) {
        List<Workflow_Step_Execution__c> latestSteps = [
          SELECT Step_Name__c
          FROM Workflow_Step_Execution__c
          WHERE Workflow_Instance__c = :instance.Id
          WITH SYSTEM_MODE
          ORDER BY CreatedDate DESC, Id DESC
          LIMIT 1
        ];
        if (
          !latestSteps.isEmpty() &&
          latestSteps[0].Step_Name__c != null &&
          latestSteps[0].Step_Name__c.endsWith('_Compensate') &&
          compStack.contains(
            latestSteps[0].Step_Name__c.removeEnd('_Compensate')
          )
        ) {
          isCompensating = true;
        }
      }
    }

    if (isCompensating) {
      // Re-assert the compensating status before running the step: runCompensationStep
      // early-exits unless the instance is Compensating/Cancelling, so a
      // Suspended (initial detection) or Running (signal-resumed) instance must
      // be restored to the right compensation status first.
      String reassertedStatus = null;
      if (
        instance.Status__c == 'Suspended' ||
        instance.Status__c == 'Running'
      ) {
        reassertedStatus = (instance.Error_Message__c != null &&
          instance.Error_Message__c.contains('Cancelled by user'))
          ? 'Cancelling'
          : 'Compensating';
        instance.Status__c = reassertedStatus;
        instance.Async_Job_Id__c = null;
        // Set the compensating status in memory but DEFER its DML to
        // runCompensationStep. A compensation step resumed by a signal may be a
        // CalloutStep that makes a payload-driven callout in compensate(), and
        // Salesforce forbids a callout once the transaction holds uncommitted
        // DML. Committing here (as this used to) made that callout illegal.
        // runCompensationStep re-applies this phase after its own re-query and
        // commits it before compensate() for an ordinary step / after it for a
        // CalloutStep. A crash before that commit leaves the instance Suspended/
        // Running with the '_Compensate' step on the stack, which this same
        // detection re-routes on the next drive.
      }
      runCompensationStep(instance, reassertedStatus);
      return;
    }

    // 2. Initialize initial step in memory if this is the start (DML deferred to outcome handler)
    if (String.isBlank(instance.Current_Step__c)) {
      Type wflowType = Type.forName(instance.Workflow_Name__c);
      if (wflowType == null) {
        throw new WorkflowException(
          'Could not resolve workflow definition class: ' +
          instance.Workflow_Name__c
        );
      }
      WorkflowDefinition def = (WorkflowDefinition) wflowType.newInstance();
      instance.Current_Step__c = def.getInitialStep();
      instance.Status__c = 'Running';
    } else if (
      instance.Status__c == 'Suspended' ||
      instance.Status__c == 'Pending'
    ) {
      instance.Status__c = 'Running';
      instance.Async_Job_Id__c = null;
    }

    // If stepName is blank but Current_Step__c is a parallel list, this is a stale/duplicate orchestrator run. Return early.
    if (
      String.isBlank(stepName) &&
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',')
    ) {
      return;
    }

    // Validate explicit stepName only when Current_Step__c is a parallel list and the requested step is in that list
    if (String.isNotBlank(stepName) && instance.Current_Step__c != stepName) {
      if (
        String.isBlank(instance.Current_Step__c) ||
        !instance.Current_Step__c.contains(',')
      ) {
        throw new WorkflowException(
          'Step ' +
            stepName +
            ' is not the active/expected step for this instance: ' +
            instance.Current_Step__c
        );
      }
      Boolean isValid = false;
      for (String pStep : instance.Current_Step__c.split(',')) {
        if (pStep.trim() == stepName) {
          isValid = true;
          break;
        }
      }
      if (!isValid) {
        throw new WorkflowException(
          'Step ' +
            stepName +
            ' is not the active/expected step for this instance: ' +
            instance.Current_Step__c
        );
      }
    }

    // Determine step name to execute
    String activeStepName = String.isNotBlank(stepName)
      ? stepName
      : instance.Current_Step__c;

    // 3. Retrieve or create Step Execution log with FOR UPDATE lock.
    // Load all executions for this step so we can derive the visit count in
    // Apex without an extra COUNT() SOQL query.
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Step_Name__c, Status__c, Input__c, Output__c, Retry_Count__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = :activeStepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    Integer stepVisit = 0;
    for (Workflow_Step_Execution__c exec : stepExecs) {
      if (exec.Status__c == 'Completed') {
        stepVisit++;
      }
    }

    if (!stepExecs.isEmpty()) {
      stepExecs = [
        SELECT Id, Step_Name__c, Status__c, Input__c, Output__c, Retry_Count__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExecs[0].Id
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
    }

    // Re-query the instance after acquiring the lock on the step execution to get the most up-to-date committed state
    instances = [
      SELECT
        Id,
        Name,
        Workflow_Name__c,
        Status__c,
        Current_Step__c,
        Input__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Parent_Instance__c,
        Compensation_Stack__c,
        Definition_Version__c,
        Error_Message__c,
        Previous_Run_At__c,
        CreatedDate
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instanceId);
    }
    instance = instances[0];

    // Check early exit conditions for instance status
    if (
      instance.Status__c == 'Completed' ||
      instance.Status__c == 'Failed' ||
      instance.Status__c == 'Compensated' ||
      instance.Status__c == 'CompensationFailed' ||
      instance.Status__c == 'Cancelled' ||
      instance.Status__c == 'ContinuedAsNew'
    ) {
      return; // Already finished
    }

    Workflow_Step_Execution__c stepExec;
    if (stepExecs.isEmpty()) {
      stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instanceId;
      stepExec.Step_Name__c = activeStepName;
      stepExec.Status__c = 'Running';
      stepExec.Retry_Count__c = 0;

      // Get previous step's output to feed as input
      List<Workflow_Step_Execution__c> completedSteps = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Completed'
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      stepExec.Input__c = !completedSteps.isEmpty()
        ? completedSteps[0].Output__c
        : instance.Input__c;
    } else {
      stepExec = stepExecs[0];
      if (
        stepExec.Status__c == 'Completed' ||
        stepExec.Status__c == 'Failed' ||
        stepExec.Status__c == 'Cancelled' ||
        stepExec.Status__c == 'Compensated'
      ) {
        return; // Already completed or terminated by concurrent thread
      }
      stepExec.Status__c = 'Running';
    }

    // 4. Resolve previous step output & step state (for yielded/resumed executions)
    String prevOutput = null;
    List<Workflow_Step_Execution__c> lastCompleted;
    if (
      String.isNotBlank(stepName) &&
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',')
    ) {
      List<String> activeParallelSteps = instance.Current_Step__c.split(',');
      lastCompleted = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Completed'
          AND Step_Name__c NOT IN :activeParallelSteps
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
    } else {
      lastCompleted = [
        SELECT Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Completed'
          AND Step_Name__c != :activeStepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
    }
    if (!lastCompleted.isEmpty()) {
      prevOutput = lastCompleted[0].Output__c;
    }

    // 5. Invoke Step Execution
    Type stepType = Type.forName(activeStepName);
    if (stepType == null) {
      throw new WorkflowException(
        'Could not resolve class for step: ' + activeStepName
      );
    }
    WorkflowStep stepInstance = (WorkflowStep) stepType.newInstance();

    Boolean isParallelBranchStep =
      String.isNotBlank(stepName) &&
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',');
    // A parallel branch claims signals at read time (Received -> Processing) so
    // siblings cannot double-process them. That claim is uncommitted DML, which
    // would make a payload-driven callout illegal, so a step that declares
    // CalloutStep opts out of claiming and reads at-least-once instead.
    Boolean claimSignals =
      isParallelBranchStep && !(stepInstance instanceof CalloutStep);
    StepContext.SignalSource signalSrc = claimSignals
      ? (StepContext.SignalSource) new ParallelBranchSignalSource(instanceId)
      : (StepContext.SignalSource) new PendingSignalSource(instanceId);
    // stepVisit: number of already-completed runs of this step in this instance.
    // Computed above from the stepExecs list (before FOR UPDATE re-assigns it)
    // to avoid a separate COUNT() SOQL query.
    StepContext context = new StepContext(
      instanceId,
      instance.Workflow_Name__c,
      activeStepName,
      resolvePayload(stepExec.Input__c),
      resolvePayload(prevOutput),
      resolvePayload(stepExec.Output__c),
      resolvePayload(instance.Input__c),
      instance.Definition_Version__c != null
        ? (Integer) instance.Definition_Version__c
        : 1,
      stepVisit,
      signalSrc,
      instance.Previous_Run_At__c
    );

    // Save/Commit step execution status and set Timeout_At__c before executing the step so watchdog can detect timeouts.
    // A CalloutStep performs a synchronous, payload-driven HTTP callout inside
    // execute(), and Salesforce forbids a callout once the transaction holds
    // pending DML. We already skip signal claiming for such a step (claimSignals
    // above), but this timeout bookkeeping also writes DML, so defer that write
    // past execute() for a CalloutStep. The step's Timeout_At__c and scheduled
    // timeout job were already committed when it was queued, so the watchdog
    // stays armed across the callout; the finally block reconciles the timeout
    // once execute() returns.
    Boolean deferPreExecDml = stepInstance instanceof CalloutStep;
    stepExec.Status__c = 'Running';
    Integer timeoutSeconds = null;
    if (stepInstance instanceof TimeoutConfigurable) {
      timeoutSeconds = ((TimeoutConfigurable) stepInstance).getTimeoutSeconds();
    }
    if (timeoutSeconds != null && timeoutSeconds > 0) {
      stepExec.Timeout_At__c = DateTime.now().addSeconds(timeoutSeconds);
      if (!deferPreExecDml) {
        saveStepExec(stepExec);
      }
    } else {
      stepExec.Timeout_At__c = null;
      if (stepExec.Id == null && !deferPreExecDml) {
        saveStepExec(stepExec);
      }
    }

    StepResult result;
    try {
      result = stepInstance.execute(context);
    } finally {
      if (timeoutSeconds != null && timeoutSeconds > 0) {
        stepExec.Timeout_At__c = null;
        saveStepExec(stepExec);
        cancelTimeoutJob(instanceId, activeStepName);
      }
    }

    // 6. Handle Step Outcome
    handleStepResult(instance, stepExec, result, context);
  }

  // Caps how many signals a serial step may observe in one execution. Serial
  // steps never claim (no read-side DML), so the only DML is the COMPLETE
  // consume; 8 000 keeps the consume update (matched ids + same-name duplicate
  // cleanup) safely under the 10 000 DML-row limit while never exposing more
  // rows than completion can consume. Excess rows stay Received for a later read.
  // @TestVisible (non-final) so a test can shrink the cap to exercise budget
  // exhaustion without inserting thousands of rows.
  @TestVisible
  private static Integer SERIAL_SIGNAL_ROW_CAP = 8000;

  /**
   * Lazily supplies the pending (unconsumed) signals targeting an instance so a
   * step that never reads signals pays no query/heap cost for unrelated
   * unconsumed signals on the instance. Tracks a cumulative row budget across
   * accessor calls so the step can never observe (and mark consumed) more rows
   * than the COMPLETE consume pass can handle.
   */
  private class PendingSignalSource implements StepContext.SignalSource {
    private final Id instanceId;
    private Integer rowBudget = SERIAL_SIGNAL_ROW_CAP;
    private Boolean capped = false;

    private PendingSignalSource(Id instanceId) {
      this.instanceId = instanceId;
    }

    public List<StepContext.Signal> getPendingSignals(String signalName) {
      if (rowBudget <= 0) {
        capped = true;
        // Don't report a false absence once the budget is spent: return one
        // still-Received row so a step that suspends-if-empty is not stranded
        // while a matching signal is pending (its wake event already fired on
        // insert). Bounded to a single row; the budget still bounds full
        // enumeration, and the remainder stays Received for a later read.
        return loadPendingSignals(this.instanceId, signalName, 1);
      }
      List<StepContext.Signal> loaded = loadPendingSignals(
        this.instanceId,
        signalName,
        rowBudget
      );
      // A full page means more rows of this name may exist beyond what was
      // returned, so the step did not necessarily see every pending row.
      if (loaded.size() >= rowBudget) {
        capped = true;
      }
      rowBudget -= loaded.size();
      return loaded;
    }

    public StepContext.Signal getLatestSignal(String signalName) {
      // A single-row "latest"/"has" lookup must reflect database truth even
      // after the row budget is spent. Reporting a false absence here is unsafe:
      // a step that then suspends as if the signal never arrived would never be
      // re-woken (the signal's wake event already fired on insert), stranding
      // the instance. One extra observed row stays within the COMPLETE consume
      // pass's headroom (the budget caps list reads, not single lookups), so the
      // lookup always queries the true most-recent row rather than gating on the
      // budget. Only a genuine full page is still flagged capped.
      //
      // Consume-safety of ungated lookups: each distinct name is queried once
      // (StepContext caches per name via latestByName), so the number of extra
      // observed rows past budget exhaustion is bounded by the SOQL-query
      // governor limit (~200 async) -- far under the 1 000-row headroom between
      // SERIAL_SIGNAL_ROW_CAP (8 000) and the 9 000-row consume cap. A step
      // would exhaust SOQL long before it could match more ids than
      // markSignalsConsumed() can update, so no consume-overflow redelivery
      // arises (Codex L1108 documented as not reachable, not gated).
      StepContext.Signal latest = loadLatestSignal(this.instanceId, signalName);
      if (latest != null && rowBudget > 0) {
        rowBudget -= 1;
      }
      return latest;
    }

    public Boolean readWasCapped() {
      return capped;
    }
  }

  // Caps how many signals a single parallel-branch accessor call claims at read
  // time. A claim writes Processing now and the matching COMPLETE writes
  // Consumed later in the SAME transaction, so claim + consume both draw on the
  // 10 000 DML-row governor limit; 4 000 leaves headroom for the consume pass
  // and the engine's other DML. Bounding the claim keeps a branch facing a huge
  // redelivery backlog from blowing the limit on every attempt and stalling
  // forever; any rows beyond the cap stay Received for a later read.
  private static final Integer PARALLEL_CLAIM_ROW_CAP = 4000;
  // Caps how many claim DML *statements* a parallel branch issues in one
  // execution. Each named getSignal/hasSignal (and each getSignals page) is one
  // update statement, so a fan-in step probing many distinct names could exceed
  // the 150 DML-statement governor limit; once this budget is spent the branch
  // reads remaining signals WITHOUT claiming (at-least-once). 100 leaves room
  // for the consume statement and the engine's other DML.
  private static final Integer PARALLEL_CLAIM_STATEMENT_BUDGET = 100;
  // How many times a parallel getSignals() re-pages past a fully-lost candidate
  // page (every row claimed by a sibling between query and lock) before giving
  // up, so a loser does not return empty while later Received rows remain.
  private static final Integer PARALLEL_CLAIM_PAGE_RETRIES = 3;

  /**
   * Signal source for parallel branch steps. Atomically claims each signal at
   * read time (Received → Processing) so two concurrent branches cannot both
   * process the same payload. The claim is held for the lifetime of the current
   * execution attempt: COMPLETE promotes Processing → Consumed; any other
   * outcome (YIELD, SUSPEND, SLEEP, RETRY, …) rolls the claim back to Received
   * so the branch can re-observe the signal on its next run. Each call claims at
   * most PARALLEL_CLAIM_ROW_CAP rows so the read can never exceed the DML-row
   * limit before the step returns.
   *
   * Two-step pattern: an ORDER BY query finds candidate IDs, then a FOR UPDATE
   * lock on those IDs atomically claims them. The claim writes uncommitted DML,
   * which makes a later callout in the same transaction illegal; a step that
   * reads a signal and then calls out on its payload must implement CalloutStep
   * to opt into a non-claiming (at-least-once) read instead.
   */
  private class ParallelBranchSignalSource implements StepContext.SignalSource {
    private final Id instanceId;
    // Cumulative claim ROW budget across all accessor calls in this execution,
    // so claim DML (now) + the matching consume DML (at COMPLETE, same
    // transaction) together stay under the 10 000 DML-row limit no matter how
    // many names the step reads.
    private Integer claimBudget = PARALLEL_CLAIM_ROW_CAP;
    // Cumulative claim DML-STATEMENT budget; bounds how many update statements
    // the accessors issue so a many-name fan-in cannot exceed the 150 statement
    // limit. When spent, reads fall back to non-claiming (at-least-once).
    private Integer claimStatementBudget = PARALLEL_CLAIM_STATEMENT_BUDGET;
    // Set whenever a read was truncated, or fell back to non-claiming, so the
    // step may not have seen (or exclusively claimed) every matching row. The
    // engine then skips same-name duplicate cleanup at consume time.
    private Boolean capped = false;

    private ParallelBranchSignalSource(Id instanceId) {
      this.instanceId = instanceId;
    }

    public Boolean readWasCapped() {
      return capped;
    }

    // True when SOQL usage is close to the governor limit. Each claim issues a
    // FOR UPDATE lock query, so a many-name fan-in could exhaust SOQL before the
    // DML-statement budget; once near the limit the accessors stop locking and
    // read non-claiming instead (at-least-once) to make progress.
    private Boolean nearSoqlLimit() {
      return Limits.getLimitQueries() > 0 &&
        Limits.getQueries() >= (Integer) (0.8 * Limits.getLimitQueries());
    }

    // Reads still-Received rows in arrival order, optionally excluding ids and
    // scoped to a name. Read-only (no claim) -- the callers decide whether to
    // claim what comes back.
    private List<Workflow_Signal__c> queryReceived(
      String signalName,
      Set<Id> excludeIds,
      Integer limitN
    ) {
      Set<Id> skip = (excludeIds != null) ? excludeIds : new Set<Id>();
      if (String.isBlank(signalName)) {
        return [
          SELECT Id, Signal_Name__c, Payload__c, CreatedDate
          FROM Workflow_Signal__c
          WHERE
            Workflow_Instance__c = :instanceId
            AND Status__c = 'Received'
            AND Id NOT IN :skip
          WITH SYSTEM_MODE
          ORDER BY CreatedDate ASC, Id ASC
          LIMIT :limitN
        ];
      }
      return [
        SELECT Id, Signal_Name__c, Payload__c, CreatedDate
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
          AND Signal_Name__c = :signalName
          AND Id NOT IN :skip
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC, Id ASC
        LIMIT :limitN
      ];
    }

    private List<StepContext.Signal> toSignals(List<Workflow_Signal__c> rows) {
      List<String> rawPayloads = new List<String>();
      for (Workflow_Signal__c c : rows) {
        rawPayloads.add(c.Payload__c);
      }
      // Resolve offloaded payloads in one bulk query rather than one per row.
      List<String> resolvedPayloads = resolvePayloads(rawPayloads);

      List<StepContext.Signal> out = new List<StepContext.Signal>();
      for (Integer i = 0; i < rows.size(); i++) {
        out.add(
          new StepContext.Signal(
            rows[i].Id,
            rows[i].Signal_Name__c,
            resolvedPayloads[i],
            rows[i].CreatedDate
          )
        );
      }
      return out;
    }

    public List<StepContext.Signal> getPendingSignals(String signalName) {
      if (claimBudget <= 0) {
        capped = true;
        // Don't report a false absence once the claim budget is spent: return
        // one still-Received row read-only (at-least-once) so a branch that
        // suspends-if-empty is not stranded while a matching signal is pending.
        // Bounded to a single row; no claim is issued.
        return toSignals(queryReceived(signalName, null, 1));
      }
      // Statement or SOQL budget spent: read without claiming so a many-name
      // fan-in cannot exceed the DML-statement or SOQL limit. These rows are
      // returned read-only (claimed = false) and at-least-once; mark capped.
      // Debit the row budget just like the claim path so total observed rows
      // stay bounded by PARALLEL_CLAIM_ROW_CAP -- otherwise repeated fallback
      // pages could mark more observed-only ids than the COMPLETE consume pass
      // (capped at 9 000) can handle, leaving the remainder Received.
      if (claimStatementBudget <= 0 || nearSoqlLimit()) {
        capped = true;
        List<Workflow_Signal__c> rows = queryReceived(
          signalName,
          null,
          claimBudget
        );
        claimBudget -= rows.size();
        return toSignals(rows);
      }

      // Try to claim a page; if a sibling claimed the entire page between query
      // and lock, re-page past it (bounded) so we do not return empty while
      // later Received rows remain unclaimed and unwoken.
      Set<Id> tried = new Set<Id>();
      Integer attempts = 0;
      while (
        claimBudget > 0 &&
        claimStatementBudget > 0 &&
        attempts < PARALLEL_CLAIM_PAGE_RETRIES
      ) {
        attempts++;
        List<Workflow_Signal__c> candidates = queryReceived(
          signalName,
          tried,
          claimBudget
        );
        if (candidates.isEmpty()) {
          break; // no more matching Received rows anywhere
        }
        // A full page means more matching rows may remain beyond the budget,
        // so flag capped: the COMPLETE consume then preserves (does not clean up)
        // same-name rows this read did not return, leaving them Received for a
        // later read rather than losing them.
        //
        // Short-page note: if a sibling claims only PART of this page between the
        // query and the FOR UPDATE lock, we return just the surviving subset
        // (the sibling exclusively owns the rest -- correct for exactly-once).
        // When the page was NOT full, the query already returned every matching
        // Received row, so that subset is the complete backlog. A short page that
        // still leaves matching rows unreturned can only arise from a FULL page,
        // which requires >PARALLEL_CLAIM_ROW_CAP pending rows of one name (or a
        // budget already drawn down by claiming that many) -- the same
        // pathological >cap regime as the documented at-least-once degradation;
        // capped is set above so the remainder is preserved for a later read.
        if (candidates.size() >= claimBudget) {
          capped = true;
        }
        Set<Id> candidateIds = new Map<Id, Workflow_Signal__c>(candidates)
          .keySet();
        tried.addAll(candidateIds);

        List<Workflow_Signal__c> locked = [
          SELECT Id
          FROM Workflow_Signal__c
          WHERE Id IN :candidateIds AND Status__c = 'Received'
          WITH SYSTEM_MODE
          FOR UPDATE
        ];
        if (locked.isEmpty()) {
          continue; // whole page lost to siblings; try the next page
        }

        Set<Id> claimedIds = new Set<Id>();
        for (Workflow_Signal__c sig : locked) {
          sig.Status__c = 'Processing';
          claimedIds.add(sig.Id);
        }
        update as system locked; // one statement for the whole page
        claimBudget -= claimedIds.size();
        claimStatementBudget -= 1;

        List<Workflow_Signal__c> claimedRows = new List<Workflow_Signal__c>();
        List<String> rawPayloads = new List<String>();
        for (Workflow_Signal__c c : candidates) {
          if (claimedIds.contains(c.Id)) {
            claimedRows.add(c);
            rawPayloads.add(c.Payload__c);
          }
        }
        // Resolve any offloaded payloads with a single bulk query (not one per
        // row), matching the read-only list path: a claimed page of offloaded
        // child-completion signals would otherwise run one ContentVersion query
        // each and could exhaust SOQL.
        List<String> resolvedPayloads = resolvePayloads(rawPayloads);
        List<StepContext.Signal> result = new List<StepContext.Signal>();
        for (Integer i = 0; i < claimedRows.size(); i++) {
          // claimed = true: this branch now exclusively owns the row.
          result.add(
            new StepContext.Signal(
              claimedRows[i].Id,
              claimedRows[i].Signal_Name__c,
              resolvedPayloads[i],
              claimedRows[i].CreatedDate,
              true
            )
          );
        }
        return result;
      }
      return new List<StepContext.Signal>();
    }

    public StepContext.Signal getLatestSignal(String signalName) {
      if (String.isBlank(signalName)) {
        return null;
      }
      // A sibling can claim the newest candidates between our query and lock. If
      // an entire page of 10 is lost that way, a still-Received row just beyond
      // the page must not be reported absent (which could strand it), so re-page
      // (claimed rows are now Processing and drop out of the Received view) up to
      // a bounded number of times.
      for (Integer attempt = 0; attempt <= PARALLEL_CLAIM_PAGE_RETRIES; attempt++) {
        // Fetch recent candidates newest-first.
        List<Workflow_Signal__c> candidates = [
          SELECT Id, Signal_Name__c, Payload__c, CreatedDate
          FROM Workflow_Signal__c
          WHERE
            Workflow_Instance__c = :instanceId
            AND Status__c = 'Received'
            AND Signal_Name__c = :signalName
          WITH SYSTEM_MODE
          ORDER BY CreatedDate DESC, Id DESC
          LIMIT 10
        ];
        if (candidates.isEmpty()) {
          return null; // no matching Received rows remain
        }
        // Row, statement or SOQL budget spent: a single-row lookup must still
        // reflect database truth, so return the newest read-only (at-least-once)
        // rather than reporting a false absence -- a branch that then suspends as
        // if the signal never arrived would never be re-woken (its wake event
        // already fired on insert) and would strand. No claim is issued (no
        // budget), so mark capped to skip same-name cleanup at consume.
        if (
          claimBudget <= 0 ||
          claimStatementBudget <= 0 ||
          nearSoqlLimit()
        ) {
          capped = true;
          Workflow_Signal__c c = candidates[0];
          return new StepContext.Signal(
            c.Id,
            c.Signal_Name__c,
            resolvePayload(c.Payload__c),
            c.CreatedDate
          );
        }
        // Try to claim each candidate newest-first; if a sibling wins the race on
        // the newest row, fall back to the next-newest still-Received row instead
        // of reporting absence while a matching signal is still available.
        for (Workflow_Signal__c cand : candidates) {
          Id targetId = cand.Id;
          List<Workflow_Signal__c> locked = [
            SELECT Id
            FROM Workflow_Signal__c
            WHERE Id = :targetId AND Status__c = 'Received'
            WITH SYSTEM_MODE
            FOR UPDATE
          ];
          if (locked.isEmpty()) {
            continue; // lost the race on this row; try the next-newest
          }
          locked[0].Status__c = 'Processing';
          update as system locked[0];
          claimBudget -= 1;
          claimStatementBudget -= 1;
          // claimed = true: this branch now exclusively owns the row.
          return new StepContext.Signal(
            cand.Id,
            cand.Signal_Name__c,
            resolvePayload(cand.Payload__c),
            cand.CreatedDate,
            true
          );
        }
        // Every candidate in this page was claimed by a sibling between query and
        // lock; those rows are now Processing and drop out of the next query, so
        // re-page to consider rows beyond the first 10.
      }
      // Could not claim a matching row within the retry budget (siblings own the
      // visible matches). Mark capped so consume skips same-name cleanup.
      capped = true;
      return null;
    }
  }

  /**
   * Loads only the single most-recent pending signal matching a name, so a step
   * reading one decision via getSignal/hasSignal does not pull every duplicate
   * payload (consumption still re-queries by name, without payloads). Returns
   * null when no matching Received signal exists.
   */
  private static StepContext.Signal loadLatestSignal(
    Id instanceId,
    String signalName
  ) {
    if (String.isBlank(signalName)) {
      return null;
    }
    List<Workflow_Signal__c> records = [
      SELECT Id, Signal_Name__c, Payload__c, CreatedDate
      FROM Workflow_Signal__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Status__c = 'Received'
        AND Signal_Name__c = :signalName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (records.isEmpty()) {
      return null;
    }
    return new StepContext.Signal(
      records[0].Id,
      records[0].Signal_Name__c,
      resolvePayload(records[0].Payload__c),
      records[0].CreatedDate
    );
  }

  /**
   * Loads the pending (unconsumed) signals targeting an instance as read-only
   * StepContext.Signal views, in deterministic arrival order. A non-blank
   * signalName scopes the query (and its payload heap cost) to that one name so
   * a single named accessor never pulls every pending payload on the instance;
   * a blank name loads them all. Bounded by rowLimit so a serial step never
   * observes (and marks consumed) more rows than the COMPLETE consume pass can
   * handle. Cancel control signals are handled inline by signal() and never
   * persist a Workflow_Signal__c record, so they are structurally excluded here.
   */
  private static List<StepContext.Signal> loadPendingSignals(
    Id instanceId,
    String signalName,
    Integer rowLimit
  ) {
    Integer effectiveLimit = (rowLimit != null && rowLimit > 0)
      ? rowLimit
      : SERIAL_SIGNAL_ROW_CAP;
    List<Workflow_Signal__c> records;
    if (String.isBlank(signalName)) {
      records = [
        SELECT Id, Signal_Name__c, Payload__c, CreatedDate
        FROM Workflow_Signal__c
        WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Received'
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC, Id ASC
        LIMIT :effectiveLimit
      ];
    } else {
      records = [
        SELECT Id, Signal_Name__c, Payload__c, CreatedDate
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
          AND Signal_Name__c = :signalName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate ASC, Id ASC
        LIMIT :effectiveLimit
      ];
    }

    List<String> rawPayloads = new List<String>();
    for (Workflow_Signal__c sig : records) {
      rawPayloads.add(sig.Payload__c);
    }
    // Resolve any offloaded payloads with a single bulk query (not one per row).
    List<String> resolvedPayloads = resolvePayloads(rawPayloads);

    List<StepContext.Signal> signals = new List<StepContext.Signal>();
    for (Integer i = 0; i < records.size(); i++) {
      signals.add(
        new StepContext.Signal(
          records[i].Id,
          records[i].Signal_Name__c,
          resolvedPayloads[i],
          records[i].CreatedDate
        )
      );
    }
    return signals;
  }

  /**
   * Rolls back the Processing claims a parallel branch step made but did not
   * durably COMPLETE (e.g. YIELD, SUSPEND, SLEEP, WAIT_FOR_APPROVAL,
   * START_CHILD, RETRY), restoring them to Received so the branch (next run) or
   * a sibling can re-observe them. Scoped to ids this branch actually CLAIMED --
   * never rows it merely observed (a CalloutStep branch reads without claiming),
   * so it can never flip a sibling's concurrent claim back to Received.
   */
  private static void rollbackClaimedSignals(StepContext context) {
    if (context == null) {
      return;
    }
    Set<Id> claimedIds = context.getClaimedSignalIds();
    if (claimedIds == null || claimedIds.isEmpty()) {
      return;
    }
    List<Workflow_Signal__c> toRollback = [
      SELECT Id
      FROM Workflow_Signal__c
      WHERE Id IN :claimedIds AND Status__c = 'Processing'
      WITH SYSTEM_MODE
    ];
    if (toRollback.isEmpty()) {
      return;
    }
    for (Workflow_Signal__c sig : toRollback) {
      sig.Status__c = 'Received';
    }
    update as system toRollback;
  }

  /**
   * Marks the signals a step matched consumed at its successful transition.
   * The exact rows the step observed/claimed (context.getConsumedSignalIds())
   * are consumed FIRST so they can never be starved by the row cap when a name
   * has a large backlog of duplicates; only then is any remaining budget spent
   * cleaning up same-name at-least-once duplicates (including one delivered
   * mid-execution after the snapshot was taken). A name only probed absent never
   * consumes a signal that arrives afterwards (it contributes no matched id and
   * no matched name).
   *
   * Ownership-scoped consumption (per signal id, not per transition kind):
   *  - CLAIMED ids (this branch holds them as exclusive Processing) are consumed
   *    while Received OR Processing -- promoting this branch's own claim.
   *  - OBSERVED-ONLY ids (matched but not claimed: serial reads, SPLIT spawn,
   *    compensation, CalloutStep branches, and claim-budget overflow rows) are
   *    consumed only while STILL Received. If a sibling has since claimed one
   *    (Processing), it now belongs to that sibling and is left alone, so this
   *    branch can never consume a row out from under a sibling's rollback.
   *  - Same-name duplicate cleanup (serial only, and only when no read was
   *    capped) catches an at-least-once redelivery that arrived after the
   *    snapshot, restricted to still-Received rows. It is skipped when a read
   *    was capped, because backlog rows the step never saw would otherwise be
   *    consumed and lost.
   *
   * Matched ids are consumed first so the exact row the step read is never left
   * behind in favor of unrelated duplicates. The combined update is capped at
   * 9 000 rows to stay below the 10 000 DML-row governor limit; any excess rows
   * are consumed on the next COMPLETE that observes them.
   */
  private static void markSignalsConsumed(
    Id instanceId,
    StepContext context,
    Boolean parallelBranch
  ) {
    if (context == null) {
      return;
    }
    Set<Id> matchedIds = context.getConsumedSignalIds();
    if (matchedIds == null) {
      matchedIds = new Set<Id>();
    }
    Set<Id> claimedIds = context.getClaimedSignalIds();
    if (claimedIds == null) {
      claimedIds = new Set<Id>();
    }
    Set<String> matchedNames = context.getConsumedSignalNames();
    if (matchedNames == null) {
      matchedNames = new Set<String>();
    }
    // A step that matched nothing triggers no query, keeping non-signal steps cheap.
    if (matchedIds.isEmpty() && matchedNames.isEmpty()) {
      return;
    }

    final Integer ROW_CAP = 9000;
    Map<Id, Workflow_Signal__c> toConsume = new Map<Id, Workflow_Signal__c>();

    // 1a. Claimed ids: consume while Received OR Processing (this branch's own
    //     exclusive claim).
    if (!claimedIds.isEmpty()) {
      for (Workflow_Signal__c sig : [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE Id IN :claimedIds AND Status__c IN ('Received', 'Processing')
        WITH SYSTEM_MODE
        LIMIT 9000
      ]) {
        toConsume.put(sig.Id, sig);
      }
    }

    // 1b. Observed-but-not-claimed ids: consume only while STILL Received, so a
    //     row a sibling has since claimed (Processing) is left for the sibling.
    Set<Id> observedOnly = new Set<Id>(matchedIds);
    observedOnly.removeAll(claimedIds);
    if (!observedOnly.isEmpty() && toConsume.size() < ROW_CAP) {
      for (Workflow_Signal__c sig : [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE Id IN :observedOnly AND Status__c = 'Received'
        WITH SYSTEM_MODE
        LIMIT 9000
      ]) {
        toConsume.put(sig.Id, sig);
      }
    }

    // 2. Serial steps only, and only when no read was capped: clean up same-name
    //    at-least-once duplicates that arrived after the snapshot. Skipped on a
    //    capped read so backlog rows the step never observed are not consumed
    //    (lost); restricted to still-Received rows so it never steals a sibling's
    //    claim.
    //
    //    Known limitation (accepted): signalReadWasCapped() is a single flag for
    //    the whole execution, so if ANY name's read was capped, duplicate cleanup
    //    is suppressed for EVERY matched name -- even names whose own read was not
    //    capped. Those names then degrade to at-least-once (an older duplicate may
    //    survive and be reprocessed later). Scoping suppression per-name would
    //    require threading capped-name tracking through the SignalSource into
    //    consume; it is not done because the cap only triggers at pathological
    //    scale (thousands of unconsumed same-name rows on one instance), where
    //    at-least-once is already the documented contract.
    Integer remaining = ROW_CAP - toConsume.size();
    if (
      !parallelBranch &&
      !context.signalReadWasCapped() &&
      !matchedNames.isEmpty() &&
      remaining > 0
    ) {
      for (Workflow_Signal__c sig : [
        SELECT Id
        FROM Workflow_Signal__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Status__c = 'Received'
          AND Signal_Name__c IN :matchedNames
          AND Id NOT IN :matchedIds
        WITH SYSTEM_MODE
        LIMIT :remaining
      ]) {
        toConsume.put(sig.Id, sig);
      }
    }

    if (toConsume.isEmpty()) {
      return;
    }
    for (Workflow_Signal__c sig : toConsume.values()) {
      sig.Status__c = 'Consumed';
    }
    update as system toConsume.values();
  }

  private static void saveStepExec(Workflow_Step_Execution__c stepExec) {
    if (stepExec.Id == null) {
      insert as system stepExec;
    } else {
      update as system stepExec;
    }
  }

  /**
   * Counts terminal (completed) executions of a step name within an instance.
   * Used to derive the per-visit idempotency sequence for StepContext: the
   * current (not-yet-completed) visit is excluded, so this is 0 for the first
   * visit and increments each time the engine loops back to the same step.
   */
  private static Integer countCompletedStepExecutions(
    Id instanceId,
    String stepName,
    Set<String> completedStatuses
  ) {
    return [
      SELECT COUNT()
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instanceId
        AND Step_Name__c = :stepName
        AND Status__c IN :completedStatuses
      WITH SYSTEM_MODE
    ];
  }

  private static void handleStepResult(
    Workflow_Instance__c instance,
    Workflow_Step_Execution__c stepExec,
    StepResult result,
    StepContext context
  ) {
    // Re-query to avoid overwriting a timeout or finalizer crash status and race conditions
    Workflow_Instance__c freshInstance = [
      SELECT
        Id,
        Status__c,
        Current_Step__c,
        Compensation_Stack__c,
        Output__c,
        Parent_Instance__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Input__c,
        Definition_Version__c,
        Previous_Run_At__c,
        CreatedDate
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (
      String.isBlank(freshInstance.Current_Step__c) &&
      String.isNotBlank(instance.Current_Step__c)
    ) {
      freshInstance.Current_Step__c = instance.Current_Step__c;
    }
    if (
      freshInstance.Status__c == 'Failed' ||
      freshInstance.Status__c == 'Compensating' ||
      freshInstance.Status__c == 'Compensated' ||
      freshInstance.Status__c == 'CompensationFailed' ||
      freshInstance.Status__c == 'Cancelled' ||
      freshInstance.Status__c == 'Cancelling' ||
      freshInstance.Status__c == 'ContinuedAsNew'
    ) {
      throw new WorkflowException(
        'Workflow execution was terminated, cancelled, is compensating, or was continued as new.'
      );
    }
    if (
      freshInstance.Status__c == 'Pending' ||
      freshInstance.Status__c == 'Suspended'
    ) {
      freshInstance.Status__c = 'Running';
    }
    instance = freshInstance;
    Boolean isParallel =
      String.isNotBlank(instance.Current_Step__c) &&
      instance.Current_Step__c.contains(',');

    if (result.action == StepResult.ActionType.COMPLETE) {
      // Step is complete. Store output.
      stepExec.Status__c = 'Completed';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.outputJson,
        'Output_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      // Tie signal consumption to the step's durable COMPLETE transition: only
      // now (not on yield/retry/suspend) are the signals this step observed
      // marked consumed, so an at-least-once redelivered duplicate cannot be
      // reprocessed by a later step. A parallel branch consumes only its own
      // claimed ids so it cannot strip a sibling branch's signal.
      markSignalsConsumed(instance.Id, context, isParallel);

      // Update compensation stack if step is CompensatableStep
      Type stepType = Type.forName(stepExec.Step_Name__c);
      if (stepType != null) {
        Object stepInstanceObj = stepType.newInstance();
        if (stepInstanceObj instanceof CompensatableStep) {
          List<String> stack = new List<String>();
          if (String.isNotBlank(instance.Compensation_Stack__c)) {
            stack = (List<String>) JSON.deserialize(
              instance.Compensation_Stack__c,
              List<String>.class
            );
          }
          stack.add(stepExec.Step_Name__c);
          instance.Compensation_Stack__c = JSON.serialize(stack);
          // If not parallel or if parallel and not all done, update here so stack is saved.
          // (Parallel allDone paths will update instance later, but doing a single update here is safe).
          update as system instance;
        }
      }

      if (!isParallel) {
        // Determine next step
        Type wflowType = Type.forName(instance.Workflow_Name__c);
        WorkflowDefinition def = (WorkflowDefinition) wflowType.newInstance();
        String nextStepName;
        if (def instanceof VersionedWorkflow) {
          nextStepName = ((VersionedWorkflow) def)
            .getNextStep(
              instance.Current_Step__c,
              result,
              instance.Definition_Version__c != null
                ? (Integer) instance.Definition_Version__c
                : 1
            );
        } else {
          nextStepName = def.getNextStep(instance.Current_Step__c, result);
        }

        if (String.isBlank(nextStepName)) {
          // Workflow is finished
          instance.Status__c = 'Completed';
          instance.Output__c = savePayloadIfNeeded(
            instance.Id,
            result.outputJson,
            'Output_Final'
          );
          instance.Current_Step__c = null;
          update as system instance;

          // Notify parent completion if this is a child workflow. This publishes
          // the load-bearing Workflow_Event__e, so it must run BEFORE the
          // best-effort lifecycle publish to keep first claim on DML budget.
          notifyParentCompletion(instance);

          // Fire-and-forget outbound lifecycle event on terminal transition.
          WorkflowLifecyclePublisher.publish(instance);
          return;
        }

        // Advance to next step
        instance.Current_Step__c = nextStepName;
        update as system instance;

        Workflow_Step_Execution__c nextStepExec = new Workflow_Step_Execution__c();
        nextStepExec.Workflow_Instance__c = instance.Id;
        nextStepExec.Step_Name__c = nextStepName;
        nextStepExec.Status__c = 'Pending';
        nextStepExec.Input__c = stepExec.Output__c;
        nextStepExec.Retry_Count__c = 0;
        insert as system nextStepExec;

        scheduleTimeoutJobForInstance(instance.Id);
        enqueueOrchestrator(instance.Id, null);
        return;
      }

      // Parallel logic (which was under if (isParallel))
      List<String> activeParallelSteps = instance.Current_Step__c.split(',');
      List<Workflow_Step_Execution__c> parallelExecs = [
        SELECT Step_Name__c, Status__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instance.Id
          AND Step_Name__c IN :activeParallelSteps
        WITH SYSTEM_MODE
      ];

      Boolean allDone = true;
      for (String ps : activeParallelSteps) {
        Boolean found = false;
        for (Workflow_Step_Execution__c pe : parallelExecs) {
          if (pe.Step_Name__c == ps && pe.Status__c == 'Completed') {
            found = true;
            break;
          }
        }
        if (!found) {
          allDone = false;
          break;
        }
      }

      if (!allDone) {
        return;
      }

      // All parallel steps completed. Proceed to Join step.
      List<Workflow_Step_Execution__c> spawningSteps = [
        SELECT Step_Name__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instance.Id
          AND Status__c = 'Completed'
          AND Step_Name__c NOT IN :activeParallelSteps
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];

      Type wflowType = Type.forName(instance.Workflow_Name__c);
      WorkflowDefinition def = (WorkflowDefinition) wflowType.newInstance();

      String spawningStepName = !spawningSteps.isEmpty()
        ? spawningSteps[0].Step_Name__c
        : '';
      StepResult mockResult = StepResult.complete(
        null,
        !spawningSteps.isEmpty() ? spawningSteps[0].Output__c : null
      );

      String nextStepName;
      if (def instanceof VersionedWorkflow) {
        nextStepName = ((VersionedWorkflow) def)
          .getNextStep(
            spawningStepName,
            mockResult,
            instance.Definition_Version__c != null
              ? (Integer) instance.Definition_Version__c
              : 1
          );
      } else {
        nextStepName = def.getNextStep(spawningStepName, mockResult);
      }

      Map<String, Object> joinInput = new Map<String, Object>();
      for (Workflow_Step_Execution__c pe : parallelExecs) {
        Object outputVal = null;
        String resolvedOutput = resolvePayload(pe.Output__c);
        if (String.isNotBlank(resolvedOutput)) {
          try {
            outputVal = JSON.deserializeUntyped(resolvedOutput);
          } catch (Exception ex) {
            System.debug(
              LoggingLevel.FINE,
              'Parallel step output was not JSON, falling back to raw string: ' +
              ex.getMessage()
            );
            outputVal = resolvedOutput;
          }
        }
        joinInput.put(pe.Step_Name__c, outputVal);
      }
      String joinInputJson = JSON.serialize(joinInput);

      if (String.isBlank(nextStepName)) {
        instance.Status__c = 'Completed';
        instance.Output__c = savePayloadIfNeeded(
          instance.Id,
          joinInputJson,
          'Output_Join'
        );
        instance.Current_Step__c = null;
        update as system instance;

        // Parent notification publishes the load-bearing Workflow_Event__e, so it
        // runs BEFORE the best-effort lifecycle publish (first claim on DML budget).
        notifyParentCompletion(instance);

        // Fire-and-forget outbound lifecycle event on terminal transition.
        WorkflowLifecyclePublisher.publish(instance);
        return;
      }

      Workflow_Step_Execution__c joinStepExec = new Workflow_Step_Execution__c();
      joinStepExec.Workflow_Instance__c = instance.Id;
      joinStepExec.Step_Name__c = nextStepName;
      joinStepExec.Status__c = 'Pending';
      joinStepExec.Input__c = savePayloadIfNeeded(
        instance.Id,
        joinInputJson,
        'Input_' + nextStepName.replaceAll('[^a-zA-Z0-9]', '_')
      );
      joinStepExec.Retry_Count__c = 0;
      insert as system joinStepExec;

      instance.Current_Step__c = nextStepName;
      update as system instance;

      scheduleTimeoutJobForInstance(instance.Id);
      enqueueOrchestrator(instance.Id, null);
    } else if (result.action == StepResult.ActionType.YIELD) {
      // Step yielded (e.g. Apex Cursor chunk). Save state to Output and run again in a new transaction.
      if (isParallel) {
        rollbackClaimedSignals(context);
      }
      stepExec.Status__c = 'Running';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.stepStateJson,
        'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      update as system instance;

      scheduleTimeoutJobForInstance(instance.Id);
      enqueueOrchestrator(instance.Id, null);
    } else if (result.action == StepResult.ActionType.SUSPEND) {
      // Step suspended (waiting for external signal). Save state and mark instance.
      if (isParallel) {
        rollbackClaimedSignals(context);
      }
      // Explicit stepStateJson is preserved; no-arg suspend() nulls Output__c so
      // stale yield checkpoints from a prior YIELD in the same execution don't
      // survive into a retry and cause duplicate-spawn collisions.
      stepExec.Status__c = 'Pending';
      stepExec.Output__c = String.isNotBlank(result.stepStateJson)
        ? savePayloadIfNeeded(
            instance.Id,
            result.stepStateJson,
            'State_Suspend_' +
              stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
          )
        : null;
      saveStepExec(stepExec);

      instance.Status__c = 'Suspended';
      update as system instance;
    } else if (result.action == StepResult.ActionType.SLEEP) {
      // Step requested sleep
      if (isParallel) {
        rollbackClaimedSignals(context);
      }
      stepExec.Status__c = 'Pending';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.stepStateJson,
        'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      instance.Status__c = 'Suspended';
      instance.Sleep_Until__c = DateTime.now()
        .addSeconds(result.sleepDurationSeconds);
      instance.Async_Job_Id__c = scheduleSleepResume(
        instance.Id,
        result.sleepDurationSeconds
      );
      update as system instance;
    } else if (result.action == StepResult.ActionType.START_CHILD) {
      // Step requested child workflow.
      //
      // Observed signals are intentionally NOT consumed here. START_CHILD
      // suspends and re-runs the SAME step when the child completes (like
      // SUSPEND/WAIT_FOR_APPROVAL), rather than transitioning forward like
      // COMPLETE/SPLIT. Consuming on this path would break a step that re-reads
      // its kickoff signal on resume to confirm it is still in the active flow.
      // A START_CHILD step should therefore check the child-completion signal
      // before re-acting on a kickoff signal (or stash needed data in step state).
      if (isParallel) {
        rollbackClaimedSignals(context);
      }
      stepExec.Status__c = 'Pending';
      Map<String, Object> childInfo = new Map<String, Object>{
        'childWorkflowName' => result.childWorkflowName,
        'childCorrelationKey' => result.childCorrelationKey
      };
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        JSON.serialize(childInfo),
        'State_ChildInfo_' +
        stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      instance.Status__c = 'Suspended';
      update as system instance;

      startChildWorkflow(
        instance.Id,
        result.childWorkflowName,
        result.childCorrelationKey,
        result.childInputJson
      );
    } else if (result.action == StepResult.ActionType.WAIT_FOR_APPROVAL) {
      if (isParallel) {
        rollbackClaimedSignals(context);
      }
      stepExec.Status__c = 'Pending';
      Map<String, Object> state = new Map<String, Object>{
        'waitingForApproval' => true,
        'approvalKey' => result.approvalKey,
        'approvalRole' => result.approvalRole
      };
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        JSON.serialize(state),
        'State_Approval_' +
        stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      instance.Status__c = 'Suspended';
      update as system instance;
    } else if (result.action == StepResult.ActionType.SPLIT) {
      stepExec.Status__c = 'Completed';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.parallelInputJson != null
          ? result.parallelInputJson
          : result.outputJson,
        'Output_Split_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      // The spawning step durably completed; consume the signals it observed so
      // they are not re-loaded into the parallel branches it fans out to. The
      // spawning step runs serially (it is the fan-out point, not a branch) and
      // does not claim, so it consumes still-Received rows plus same-name
      // duplicate cleanup.
      markSignalsConsumed(instance.Id, context, false);

      String parallelStepsStr = String.join(result.parallelStepNames, ',');
      instance.Current_Step__c = parallelStepsStr;
      instance.Status__c = 'Running';
      update as system instance;

      List<Workflow_Step_Execution__c> parallelExecs = new List<Workflow_Step_Execution__c>();
      for (String ps : result.parallelStepNames) {
        Workflow_Step_Execution__c pe = new Workflow_Step_Execution__c();
        pe.Workflow_Instance__c = instance.Id;
        pe.Step_Name__c = ps;
        pe.Status__c = 'Pending';
        pe.Input__c = savePayloadIfNeeded(
          instance.Id,
          result.parallelInputJson != null
            ? result.parallelInputJson
            : stepExec.Output__c,
          'Input_Parallel_' + ps.replaceAll('[^a-zA-Z0-9]', '_')
        );
        pe.Retry_Count__c = 0;
        Integer timeout = getStepTimeoutSeconds(ps);
        if (timeout != null && timeout > 0) {
          pe.Timeout_At__c = DateTime.now().addSeconds(timeout);
        }
        parallelExecs.add(pe);
      }
      insert as system parallelExecs;

      scheduleTimeoutJobForInstance(instance.Id);
      for (String ps : result.parallelStepNames) {
        enqueueOrchestrator(instance.Id, ps);
      }
    } else if (result.action == StepResult.ActionType.RETRY) {
      // Step requested retry
      if (isParallel) {
        rollbackClaimedSignals(context);
      }
      stepExec.Retry_Count__c += 1;

      // Get or default retry policy
      RetryPolicy policy = (result.retryPolicy != null)
        ? result.retryPolicy
        : new RetryPolicy();

      if (stepExec.Retry_Count__c >= policy.maximumAttempts) {
        stepExec.Status__c = 'Failed';
        stepExec.Error_Details__c =
          'Max retries (' +
          policy.maximumAttempts +
          ') exceeded.';
        saveStepExec(stepExec);

        failWorkflowInstance(
          instance.Id,
          instance.Current_Step__c,
          'Max retries exceeded.'
        );
      } else {
        stepExec.Status__c = 'Retrying';
        stepExec.Output__c = null;
        saveStepExec(stepExec);

        // Calculate exponential backoff
        Double backoff = Math.pow(
          (Double) policy.backoffCoefficient,
          (Double) (stepExec.Retry_Count__c - 1)
        );
        Integer delay = (Integer) (policy.initialIntervalSeconds * backoff);
        delay = Math.min(delay, 86400);

        instance.Status__c = 'Suspended';
        instance.Sleep_Until__c = DateTime.now().addSeconds(delay);
        instance.Async_Job_Id__c = scheduleRetry(
          instance.Id,
          stepExec.Step_Name__c,
          delay
        );
        update as system instance;
      }
    } else if (result.action == StepResult.ActionType.CONTINUE_AS_NEW) {
      if (isParallel) {
        rollbackClaimedSignals(context);
      }
      stepExec.Status__c = 'ContinuedAsNew';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.nextInputJson,
        'ContinueInput_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      // Resolve the new correlation key
      String newKey = resolveContinueAsNewKey(
        instance.Correlation_Key__c,
        result.newCorrelationKey
      );

      // Mark current instance as ContinuedAsNew
      instance.Status__c = 'ContinuedAsNew';
      instance.Current_Step__c = null;
      update as system instance;

      // Resolve initial step for successor instance
      String initialStep = null;
      Type wflowType = Type.forName(instance.Workflow_Name__c);
      if (wflowType != null) {
        Object defObj = wflowType.newInstance();
        if (defObj instanceof WorkflowDefinition) {
          initialStep = ((WorkflowDefinition) defObj).getInitialStep();
        }
      }

      // Spawn successor instance. Carry the chain's root correlation key forward
      // unchanged so the whole continue-as-new chain shares one stable key that
      // external callers can correlate the terminal lifecycle event against.
      // Fall back to the predecessor's own key if the root was never populated
      // (pre-existing data created before the Root_Correlation_Key__c field).
      String rootKey = String.isNotBlank(instance.Root_Correlation_Key__c)
        ? instance.Root_Correlation_Key__c
        : instance.Correlation_Key__c;
      Workflow_Instance__c nextInstance = new Workflow_Instance__c(
        Workflow_Name__c = instance.Workflow_Name__c,
        Correlation_Key__c = newKey,
        Root_Correlation_Key__c = rootKey,
        Previous_Instance__c = instance.Id,
        Definition_Version__c = instance.Definition_Version__c,
        Current_Step__c = initialStep,
        // Use the predecessor's CreatedDate (when it started) rather than
        // System.now() (when it finished). This prevents a gap: records
        // modified during the predecessor's execution window are covered by
        // the successor's query (>= predecessor start). The tradeoff is
        // bounded overlap near the boundary, which is correct at-least-once
        // behavior — the same contract Temporal/DBOS use for polling cursors.
        Previous_Run_At__c = instance.CreatedDate
      );
      try {
        insert as system nextInstance;
      } catch (DmlException ex) {
        if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
          throw new WorkflowException(
            'An active workflow already exists with correlation key: ' + newKey
          );
        }
        throw ex;
      }

      // Set input and save payload
      nextInstance.Input__c = savePayloadIfNeeded(
        nextInstance.Id,
        result.nextInputJson,
        'Input_' + nextInstance.Id
      );
      update as system nextInstance;

      // Pre-create the successor's first step execution log
      if (String.isNotBlank(initialStep)) {
        Workflow_Step_Execution__c nextStepExec = new Workflow_Step_Execution__c();
        nextStepExec.Workflow_Instance__c = nextInstance.Id;
        nextStepExec.Step_Name__c = initialStep;
        nextStepExec.Status__c = 'Pending';
        nextStepExec.Input__c = nextInstance.Input__c;
        nextStepExec.Retry_Count__c = 0;
        Integer timeout = getStepTimeoutSeconds(initialStep);
        if (timeout != null && timeout > 0) {
          nextStepExec.Timeout_At__c = DateTime.now().addSeconds(timeout);
        }
        insert as system nextStepExec;
      }

      // Enqueue the successor run
      scheduleTimeoutJobForInstance(nextInstance.Id);
      if (Test.isRunningTest()) {
        if (!disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(nextInstance.Id));
        }
      } else {
        enqueueOrchestrator(nextInstance.Id, null);
      }
    }
  }

  /**
   * Rescues a workflow when the host transaction fails or hits governor limits.
   * Invoked from a System.Finalizer.
   */
  public static void handleCrash(Id instanceId, Exception ex) {
    handleCrash(instanceId, null, ex);
  }

  public static void handleCrash(Id instanceId, String stepName, Exception ex) {
    // Run as separate DML transaction to ensure it's written even if parent rolled back
    List<Workflow_Instance__c> instances = [
      SELECT Id, Status__c, Current_Step__c, Compensation_Stack__c, Input__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];

    if (instances.isEmpty()) {
      return;
    }

    Workflow_Instance__c instance = instances[0];

    // Resolve target step name. An explicit stepName always wins. Otherwise, if the
    // instance is mid-rollback the crashing work is the top-of-stack compensation (the
    // compensation orchestrator is enqueued without a stepName), so record the crash
    // against that '_Compensate' step rather than the stale forward Current_Step__c.
    // This keeps the failed compensation in the append-only audit trail and lets the
    // resume path append a fresh attempt instead of mistaking a stale log for in-flight.
    //
    // The instance is mid-rollback when its status is Compensating/Cancelling, OR when it
    // is Suspended and its most recent step execution is a '_Compensate' attempt. The
    // latter is the sleeping/approval-gated compensation case: a compensation returned
    // SLEEP/SUSPEND/WAIT_FOR_APPROVAL, so the engine parked the instance as Suspended and
    // resumed it later via WorkflowOrchestrator(instanceId) with no stepName. runStep()
    // flips that Suspended status back to Compensating/Cancelling in-transaction (using
    // the same latest-'_Compensate' signal), but a crash rolls that flip back, leaving the
    // persisted status as Suspended here. Detect it the same way runStep() does so the
    // crash is recorded against the '_Compensate' step instead of the stale forward step.
    Boolean midRollback =
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling';
    if (!midRollback && instance.Status__c == 'Suspended') {
      List<Workflow_Step_Execution__c> latestSteps = [
        SELECT Step_Name__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c = :instance.Id
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      midRollback =
        !latestSteps.isEmpty() &&
        latestSteps[0].Step_Name__c != null &&
        latestSteps[0].Step_Name__c.endsWith('_Compensate');
    }

    String targetStepName;
    if (String.isNotBlank(stepName)) {
      targetStepName = stepName;
    } else if (
      midRollback && String.isNotBlank(instance.Compensation_Stack__c)
    ) {
      List<String> stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
      targetStepName = stack.isEmpty()
        ? instance.Current_Step__c
        : stack[stack.size() - 1] + '_Compensate';
    } else {
      targetStepName = instance.Current_Step__c;
    }

    // Mark step failed first
    if (String.isNotBlank(targetStepName)) {
      List<Workflow_Step_Execution__c> stepExecs = [
        SELECT Id
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c = :targetStepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];
      if (!stepExecs.isEmpty()) {
        Workflow_Step_Execution__c stepExec = stepExecs[0];
        stepExec.Status__c = 'Failed';
        stepExec.Error_Details__c = (ex != null
          ? ex.getMessage() + '\n' + ex.getStackTraceString()
          : 'Unknown governor limit / crash');
        update as system stepExec;
      } else {
        // Construct and insert the step execution log with failed status
        Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
        stepExec.Workflow_Instance__c = instanceId;
        stepExec.Step_Name__c = targetStepName;
        stepExec.Status__c = 'Failed';
        stepExec.Error_Details__c = (ex != null
          ? ex.getMessage() + '\n' + ex.getStackTraceString()
          : 'Unknown governor limit / crash');

        if (targetStepName.endsWith('_Compensate')) {
          // Crash row for a compensation step: seed from THIS step's own forward
          // execution (input/output), matching how compensation logs are seeded
          // everywhere else. Using the latest completed step overall would be wrong
          // once earlier compensations have popped — that row belongs to a step that
          // is already reversed, giving the wrong undo context on resume.
          String forwardStepName = targetStepName.removeEnd('_Compensate');
          List<Workflow_Step_Execution__c> forwardExecs = [
            SELECT Input__c, Output__c
            FROM Workflow_Step_Execution__c
            WHERE
              Workflow_Instance__c = :instanceId
              AND Step_Name__c = :forwardStepName
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
          ];
          if (!forwardExecs.isEmpty()) {
            stepExec.Input__c = forwardExecs[0].Input__c;
            stepExec.Output__c = forwardExecs[0].Output__c;
          }
        } else {
          // Forward step crash: feed the previous step's output as input.
          List<Workflow_Step_Execution__c> completedSteps = [
            SELECT Output__c
            FROM Workflow_Step_Execution__c
            WHERE Workflow_Instance__c = :instanceId AND Status__c = 'Completed'
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
          ];
          stepExec.Input__c = !completedSteps.isEmpty()
            ? completedSteps[0].Output__c
            : instance.Input__c;
        }
        insert as system stepExec;
      }
    }

    // Use fail helper
    String errorMsg =
      'Transaction crashed: ' +
      (ex != null ? ex.getMessage() : 'Unknown governor limit');
    failWorkflowInstance(instanceId, targetStepName, errorMsg);
  }

  /**
   * Transitions a workflow instance to Failed or Compensating state.
   */
  public static void failWorkflowInstance(
    Id instanceId,
    String stepName,
    String errorMessage
  ) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Name,
        Status__c,
        Error_Message__c,
        Compensation_Stack__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      return;
    }
    Workflow_Instance__c instance = instances[0];

    // Check if there are compensations to run
    Boolean hasCompensations = false;
    if (String.isNotBlank(instance.Compensation_Stack__c)) {
      List<String> stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
      hasCompensations = !stack.isEmpty();
    }

    if (!hasCompensations) {
      instance.Status__c = 'Failed';
      instance.Error_Message__c =
        'Failed at step ' +
        stepName +
        ': ' +
        errorMessage;
      update as system instance;
      WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
      WorkflowLifecyclePublisher.publish(instance);
      return;
    }

    Boolean isCompensationFailure = (instance.Status__c == 'Compensating' ||
    instance.Status__c == 'Cancelling' ||
    (String.isNotBlank(stepName) && stepName.endsWith('_Compensate')));

    if (isCompensationFailure) {
      // The rollback itself could not complete. Because the failed step's entry is
      // never popped, the remaining LIFO stack is still intact here. Rather than
      // driving to a generic terminal Failed and silently abandoning the deeper
      // (un-run) compensations, park the saga in the recoverable, operator-visible
      // "rollback incomplete" condition so it can be resumed from this exact point.
      //
      // Detect the cancel phase via the engine-owned 'Cancelled by user' marker in
      // addition to the live status: when a cancel-driven rollback crashed while a
      // compensation was Suspended (sleep/approval), the in-transaction flip back to
      // 'Cancelling' was rolled back, so the persisted status is 'Suspended' but the
      // preserved Error_Message__c still carries the marker. Reading it keeps the saga on
      // the cancel path so it finishes 'Cancelled' rather than 'Compensated' on resume.
      Boolean wasCancelling =
        instance.Status__c == 'Cancelling' ||
        (instance.Error_Message__c != null &&
        instance.Error_Message__c.contains('Cancelled by user'));
      instance.Status__c = 'CompensationFailed';
      instance.Error_Message__c = buildRollbackIncompleteMessage(
        wasCancelling,
        'Rollback incomplete at compensation step ' +
          stepName +
          ': ' +
          errorMessage
      );
      // Clear any stale sleep/retry deadline so the watchdog cannot prematurely wake a
      // remaining SUSPEND/approval gate once the rollback is resumed.
      instance.Sleep_Until__c = null;
      instance.Async_Job_Id__c = null;
      update as system instance;
      WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
      WorkflowLifecyclePublisher.publish(instance);
      return;
    }

    instance.Status__c = 'Compensating';
    instance.Error_Message__c =
      'Failed at step ' +
      stepName +
      ': ' +
      errorMessage;
    preCreateFirstCompensationStep(instance);
    update as system instance;

    // Kick off rollback loop
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instance.Id));
      }
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  private static void startChildWorkflow(
    Id parentId,
    String workflowName,
    String correlationKey,
    String inputJson
  ) {
    validateCorrelationKey(correlationKey);
    if (String.isNotBlank(correlationKey)) {
      List<Workflow_Instance__c> existing = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE
          Correlation_Key__c = :correlationKey
          AND Status__c IN ('Pending', 'Running', 'Suspended', 'CompensationFailed')
        WITH SYSTEM_MODE
        LIMIT 1
      ];
      if (!existing.isEmpty()) {
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' +
          correlationKey
        );
      }
    }

    Workflow_Instance__c instance = new Workflow_Instance__c();
    instance.Workflow_Name__c = workflowName;
    instance.Status__c = 'Pending';
    instance.Correlation_Key__c = correlationKey;
    instance.Parent_Instance__c = parentId;

    // Resolve child version
    Type wflowType = Type.forName(workflowName);
    if (wflowType != null) {
      Object defObj = wflowType.newInstance();
      if (defObj instanceof VersionedWorkflow) {
        instance.Definition_Version__c = ((VersionedWorkflow) defObj)
          .getLatestVersion();
      } else {
        instance.Definition_Version__c = 1;
      }
      if (defObj instanceof WorkflowDefinition) {
        instance.Current_Step__c = ((WorkflowDefinition) defObj)
          .getInitialStep();
      }
    } else {
      instance.Definition_Version__c = 1;
    }

    try {
      insert as system instance;
    } catch (DmlException ex) {
      if (ex.getDmlStatusCode(0) == 'DUPLICATE_VALUE') {
        throw new WorkflowException(
          'An active workflow already exists with correlation key: ' +
          correlationKey
        );
      }
      throw ex;
    }

    instance.Input__c = savePayloadIfNeeded(
      instance.Id,
      inputJson,
      'Input_Child_' + instance.Id
    );
    update as system instance;

    if (String.isNotBlank(instance.Current_Step__c)) {
      Workflow_Step_Execution__c stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = instance.Current_Step__c;
      stepExec.Status__c = 'Pending';
      stepExec.Input__c = instance.Input__c;
      stepExec.Retry_Count__c = 0;
      insert as system stepExec;
    }

    // Schedule the watchdog for the child's initial step before executing it, matching
    // the start() overloads. Without this a TimeoutConfigurable first step of a child
    // workflow would never get a scheduled timeout job.
    scheduleTimeoutJobForInstance(instance.Id);

    if (!Test.isRunningTest()) {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  private static void notifyParentCompletion(
    Workflow_Instance__c childInstance
  ) {
    if (childInstance.Parent_Instance__c != null) {
      Workflow_Instance__c parent = [
        SELECT Correlation_Key__c
        FROM Workflow_Instance__c
        WHERE Id = :childInstance.Parent_Instance__c
        WITH SYSTEM_MODE
      ];

      String targetKey = String.isNotBlank(parent.Correlation_Key__c)
        ? parent.Correlation_Key__c
        : parent.Id;

      String signalName = 'ChildCompleted';
      if (String.isNotBlank(childInstance.Correlation_Key__c)) {
        signalName += ':' + childInstance.Correlation_Key__c;
      } else {
        signalName += ':' + childInstance.Id;
      }

      Workflow_Event__e event = new Workflow_Event__e(
        Workflow_Instance_Id__c = targetKey,
        Event_Type__c = 'SIGNAL:' + signalName,
        Payload__c = childInstance.Output__c
      );
      Database.SaveResult sr = EventBus.publish(event);
      if (!sr.isSuccess()) {
        List<String> errMsgs = new List<String>();
        for (Database.Error err : sr.getErrors()) {
          errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
        }
        throw new WorkflowException(
          'Failed to publish child completion event: ' +
          String.join(errMsgs, ', ')
        );
      }
    }
  }

  /**
   * Sends an external signal to a workflow instance by correlation key or instance ID.
   */
  public static void signal(String keyOrId, String signalName, String payload) {
    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe()
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');
    Boolean isId =
      String.isNotBlank(keyOrId) &&
      idPattern.matcher(keyOrId).matches() &&
      keyOrId.startsWith(wflowPrefix);
    Id targetId = isId ? (Id) keyOrId : null;

    // A Cancel signal must also be able to reach a stalled rollback (CompensationFailed)
    // so cancellation can resume it to completion or force it terminal. Other signals keep
    // the active-only lookup — a stalled rollback is not a forward-signal target.
    Boolean isCancelSignal =
      String.isNotBlank(signalName) &&
      (signalName.equalsIgnoreCase('Cancel') ||
      signalName.equalsIgnoreCase('CancelWorkflow'));
    List<String> lookupStatuses = isCancelSignal
      ? new List<String>{
          'Pending',
          'Running',
          'Suspended',
          'CompensationFailed'
        }
      : new List<String>{
          'Pending',
          'Running',
          'Suspended',
          'Compensating',
          'Cancelling'
        };

    List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
    if (isId) {
      // Query by ID first to prevent matching a correlation key that equals this ID string
      instances = [
        SELECT Id, Status__c
        FROM Workflow_Instance__c
        WHERE Id = :targetId AND Status__c IN :lookupStatuses
        WITH SYSTEM_MODE
        LIMIT 1
        FOR UPDATE
      ];
    }

    if (instances.isEmpty()) {
      instances = [
        SELECT Id, Status__c
        FROM Workflow_Instance__c
        WHERE Correlation_Key__c = :keyOrId AND Status__c IN :lookupStatuses
        WITH SYSTEM_MODE
        LIMIT 1
        FOR UPDATE
      ];
    }

    if (instances.isEmpty()) {
      throw new WorkflowException(
        'No active workflow found with key or ID: ' + keyOrId
      );
    }

    Workflow_Instance__c instance = instances[0];

    if (
      signalName.equalsIgnoreCase('Cancel') ||
      signalName.equalsIgnoreCase('CancelWorkflow')
    ) {
      Boolean runCompensations = true;
      if (String.isNotBlank(payload)) {
        try {
          Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(
            payload
          );
          if (params.containsKey('runCompensations')) {
            runCompensations = (Boolean) params.get('runCompensations');
          }
        } catch (Exception e) {
          System.debug(
            LoggingLevel.WARN,
            'Failed to parse cancel payload, using default runCompensations: ' +
            e.getMessage()
          );
        }
      }
      cancel(instance.Id, runCompensations);
      return;
    }

    // Insert the signal record
    Workflow_Signal__c sig = new Workflow_Signal__c();
    sig.Workflow_Instance__c = instance.Id;
    sig.Signal_Name__c = signalName;
    sig.Payload__c = payload;
    sig.Status__c = 'Received';
    insert as system sig;

    // If the workflow is suspended or running, resume/orchestrate it. A parallel
    // instance must wake each incomplete branch by name (see enqueueResume). A
    // Compensating/Cancelling instance is mid-rollback: a compensation step can
    // depend on inbound signals, so wake it too rather than rejecting the signal
    // as "no active workflow". The compensation status is left untouched (only a
    // Suspended instance flips to Running); runStep re-detects the compensation
    // from the trailing '_Compensate' step and routes to runCompensationStep.
    if (
      instance.Status__c == 'Suspended' ||
      instance.Status__c == 'Running' ||
      instance.Status__c == 'Compensating' ||
      instance.Status__c == 'Cancelling'
    ) {
      if (instance.Status__c == 'Suspended') {
        instance.Status__c = 'Running';
        update as system instance;
      }
      enqueueResume(instance.Id);
    }
  }

  /**
   * Wakes a (possibly parallel) instance to resume execution. When
   * Current_Step__c is a parallel branch list, each still-incomplete branch is
   * enqueued by its own step name: runStep returns early for a comma-separated
   * Current_Step__c with a blank stepName, so a single blank enqueue would never
   * resume a branch suspended on a signal. A serial instance is enqueued once
   * with a null stepName.
   */
  private static void enqueueResume(Id instanceId) {
    List<Workflow_Instance__c> rows = [
      SELECT Id, Current_Step__c, Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    String currentStep = rows.isEmpty() ? null : rows[0].Current_Step__c;
    // A Compensating/Cancelling instance rolls back serially off the LIFO stack,
    // so it needs a single compensation wake, never per-branch fan-out -- even if
    // Current_Step__c still holds a stale comma-separated parallel branch list from
    // the forward phase. Only forward parallel instances fan out per branch.
    Boolean isCompensatingInst =
      !rows.isEmpty() &&
      (rows[0].Status__c == 'Compensating' || rows[0].Status__c == 'Cancelling');

    if (
      !isCompensatingInst &&
      String.isNotBlank(currentStep) &&
      currentStep.contains(',')
    ) {
      // Delegate to the batched bulk path (single-element list) so a parallel
      // instance with many unfinished branches publishes one EventBus call
      // rather than one publish per branch (which could exceed the 150
      // publish/DML-statement limit).
      enqueueResumeBulk(rows);
      return;
    }

    // Serial resume.
    if (enqueuedInstanceIds.contains(instanceId)) {
      return;
    }
    enqueuedInstanceIds.add(instanceId);
    if (Test.isRunningTest()) {
      System.enqueueJob(new WorkflowOrchestrator(instanceId));
    } else {
      try {
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
          System.enqueueJob(new WorkflowOrchestrator(instanceId));
        } else {
          enqueueOrchestrator(instanceId, null);
        }
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.WARN,
          'Queueable enqueue failed, falling back to Platform Event: ' +
          ex.getMessage()
        );
        enqueueOrchestrator(instanceId, null);
      }
    }
  }

  /**
   * Sends external signals to multiple workflow instances in bulk.
   */
  public static void signal(List<SignalRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    String wflowPrefix = Workflow_Instance__c.SObjectType.getDescribe()
      .getKeyPrefix();
    Pattern idPattern = Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$');
    Set<Id> ids = new Set<Id>();
    Set<String> keys = new Set<String>();

    for (SignalRequest req : requests) {
      if (String.isNotBlank(req.keyOrId)) {
        if (
          idPattern.matcher(req.keyOrId).matches() &&
          req.keyOrId.startsWith(wflowPrefix)
        ) {
          ids.add((Id) req.keyOrId);
        } else {
          keys.add(req.keyOrId);
        }
      }
    }

    // Include CompensationFailed so a Cancel signal can reach a stalled rollback; the
    // per-request guard below still rejects non-cancel signals to a stalled instance,
    // preserving the active-only semantics for everything except cancellation.
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Status__c,
        Correlation_Key__c,
        Current_Step__c,
        Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE
        (Id IN :ids
        OR Correlation_Key__c IN :keys)
        AND Status__c IN (
          'Pending',
          'Running',
          'Suspended',
          'Compensating',
          'Cancelling',
          'CompensationFailed'
        )
      WITH SYSTEM_MODE
      FOR UPDATE
    ];

    Map<String, Workflow_Instance__c> instById = new Map<String, Workflow_Instance__c>();
    Map<String, Workflow_Instance__c> instByKey = new Map<String, Workflow_Instance__c>();
    for (Workflow_Instance__c inst : instances) {
      instById.put(inst.Id, inst);
      String idStr = String.valueOf(inst.Id);
      if (idStr.length() == 18) {
        instById.put(idStr.substring(0, 15), inst);
      }
      if (String.isNotBlank(inst.Correlation_Key__c)) {
        instByKey.put(inst.Correlation_Key__c, inst);
      }
    }

    // Verify that we found an active instance for every request, or throw. A stalled
    // rollback (CompensationFailed) only qualifies for a Cancel signal; any other signal
    // targeting it is treated as "no active workflow", preserving prior semantics.
    for (SignalRequest req : requests) {
      Workflow_Instance__c inst = instById.get(req.keyOrId);
      if (inst == null) {
        inst = instByKey.get(req.keyOrId);
      }
      Boolean isCancel =
        String.isNotBlank(req.signalName) &&
        (req.signalName.equalsIgnoreCase('Cancel') ||
        req.signalName.equalsIgnoreCase('CancelWorkflow'));
      if (
        inst == null ||
        (inst.Status__c == 'CompensationFailed' && !isCancel)
      ) {
        throw new WorkflowException(
          'No active workflow found with key or ID: ' + req.keyOrId
        );
      }
    }

    List<Workflow_Signal__c> signalsToInsert = new List<Workflow_Signal__c>();
    List<Workflow_Instance__c> instancesToUpdate = new List<Workflow_Instance__c>();
    List<Workflow_Instance__c> activeInstances = new List<Workflow_Instance__c>();

    for (SignalRequest req : requests) {
      Workflow_Instance__c inst = instById.get(req.keyOrId);
      if (inst == null) {
        inst = instByKey.get(req.keyOrId);
      }

      if (inst != null) {
        if (
          req.signalName.equalsIgnoreCase('Cancel') ||
          req.signalName.equalsIgnoreCase('CancelWorkflow')
        ) {
          Boolean runCompensations = true;
          if (String.isNotBlank(req.payload)) {
            try {
              Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(
                req.payload
              );
              if (params.containsKey('runCompensations')) {
                runCompensations = (Boolean) params.get('runCompensations');
              }
            } catch (Exception e) {
              System.debug(
                LoggingLevel.WARN,
                'Failed to deserialize signal cancel payload: ' + e.getMessage()
              );
            }
          }
          cancel(inst.Id, runCompensations);
          continue;
        }

        // Insert the signal record
        Workflow_Signal__c sig = new Workflow_Signal__c();
        sig.Workflow_Instance__c = inst.Id;
        sig.Signal_Name__c = req.signalName;
        sig.Payload__c = req.payload;
        sig.Status__c = 'Received';
        signalsToInsert.add(sig);

        // If the workflow is suspended or running, resume/orchestrate it. A
        // Compensating/Cancelling instance is mid-rollback: a compensation step
        // may depend on this signal, so wake it too rather than rejecting it. The
        // compensation status is left untouched (only Suspended flips to Running);
        // runStep re-detects the rollback from the trailing '_Compensate' step.
        if (
          inst.Status__c == 'Suspended' ||
          inst.Status__c == 'Running' ||
          inst.Status__c == 'Compensating' ||
          inst.Status__c == 'Cancelling'
        ) {
          if (inst.Status__c == 'Suspended') {
            inst.Status__c = 'Running';
            instancesToUpdate.add(inst);
          }
          activeInstances.add(inst);
        }
      }
    }

    if (!signalsToInsert.isEmpty()) {
      insert as system signalsToInsert;
    }
    if (!instancesToUpdate.isEmpty()) {
      update as system instancesToUpdate;
    }

    List<Id> instanceIdsToEnqueue = new List<Id>();
    List<Workflow_Instance__c> parallelInstances = new List<Workflow_Instance__c>();
    for (Workflow_Instance__c inst : activeInstances) {
      // A Compensating/Cancelling instance rolls back serially off the LIFO stack,
      // so it needs exactly one compensation wake -- never per-branch fan-out, even
      // if Current_Step__c still holds a stale comma-separated parallel branch list
      // from the forward phase. Otherwise one compensation signal would publish a
      // RUN_STEP per stale branch and pile up duplicate rollback workers.
      Boolean isCompensatingInst =
        inst.Status__c == 'Compensating' || inst.Status__c == 'Cancelling';
      // Parallel (forward) instances must wake each branch by name; collect them
      // for a single bulk resume rather than a per-instance query each (which would
      // exhaust the SOQL limit when many parallel workflows are signaled at once).
      if (
        !isCompensatingInst &&
        String.isNotBlank(inst.Current_Step__c) &&
        inst.Current_Step__c.contains(',')
      ) {
        parallelInstances.add(inst);
        continue;
      }
      if (!enqueuedInstanceIds.contains(inst.Id)) {
        enqueuedInstanceIds.add(inst.Id);
        instanceIdsToEnqueue.add(inst.Id);
      }
    }
    enqueueOrchestrators(instanceIdsToEnqueue);
    enqueueResumeBulk(parallelInstances);
  }

  /**
   * Bulk variant of enqueueResume for the bulk signal() path: wakes the
   * incomplete branches of many parallel instances using the already-loaded
   * Current_Step__c values and ONE step-execution query across all of them,
   * instead of two queries per instance.
   */
  private static void enqueueResumeBulk(
    List<Workflow_Instance__c> parallelInstances
  ) {
    if (parallelInstances == null || parallelInstances.isEmpty()) {
      return;
    }
    // Map each instance to its branch step names, and collect all branch names
    // for a single step-execution lookup.
    Map<Id, List<String>> branchesByInstance = new Map<Id, List<String>>();
    Set<String> allBranchNames = new Set<String>();
    for (Workflow_Instance__c inst : parallelInstances) {
      List<String> branches = new List<String>();
      for (String b : inst.Current_Step__c.split(',')) {
        branches.add(b.trim());
        allBranchNames.add(b.trim());
      }
      branchesByInstance.put(inst.Id, branches);
    }

    // One query: latest execution per (instance, branch step name).
    Map<String, String> latestStatusByKey = new Map<String, String>();
    for (Workflow_Step_Execution__c se : [
      SELECT Workflow_Instance__c, Step_Name__c, Status__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c IN :branchesByInstance.keySet()
        AND Step_Name__c IN :allBranchNames
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ]) {
      String key = se.Workflow_Instance__c + '::' + se.Step_Name__c;
      if (!latestStatusByKey.containsKey(key)) {
        latestStatusByKey.put(key, se.Status__c);
      }
    }

    // Collect all branch RUN_STEP events and publish them in ONE EventBus call,
    // so signaling many parallel instances cannot exceed the publish/DML
    // statement limit (one publish per branch).
    List<Workflow_Event__e> branchEvents = new List<Workflow_Event__e>();
    for (Id instId : branchesByInstance.keySet()) {
      for (String b : branchesByInstance.get(instId)) {
        String key = instId + '::' + b;
        if (latestStatusByKey.get(key) == 'Completed') {
          continue; // branch already finished
        }
        if (enqueuedBranchKeys.contains(key)) {
          continue;
        }
        enqueuedBranchKeys.add(key);
        if (Test.isRunningTest()) {
          if (!disableQueueableInTest) {
            System.enqueueJob(new WorkflowOrchestrator(instId, b));
          }
        } else {
          branchEvents.add(
            new Workflow_Event__e(
              Workflow_Instance_Id__c = instId,
              Event_Type__c = 'RUN_STEP',
              Payload__c = b
            )
          );
        }
      }
    }

    if (!branchEvents.isEmpty()) {
      WorkflowWatchdog.bootstrap();
      List<Database.SaveResult> srs = EventBus.publish(branchEvents);
      for (Database.SaveResult sr : srs) {
        if (!sr.isSuccess()) {
          List<String> errMsgs = new List<String>();
          for (Database.Error err : sr.getErrors()) {
            errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
          }
          throw new WorkflowException(
            'Failed to publish resumed branch event: ' +
            String.join(errMsgs, ', ')
          );
        }
      }
    }
  }

  /**
   * Resumes a failed workflow instance from the step where it failed, resetting its state and retry counter.
   */
  public static void retryWorkflow(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT
        Id,
        Status__c,
        Current_Step__c,
        Error_Message__c,
        Compensation_Stack__c,
        Workflow_Name__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      throw new WorkflowException('Workflow instance not found: ' + instanceId);
    }
    Workflow_Instance__c instance = instances[0];
    if (instance.Status__c != 'Failed') {
      throw new WorkflowException(
        'Workflow instance is not in Failed status. Current status: ' +
        instance.Status__c
      );
    }

    Boolean hasCompensations = false;
    List<String> stack = new List<String>();
    if (String.isNotBlank(instance.Compensation_Stack__c)) {
      stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
      hasCompensations = !stack.isEmpty();
    }

    List<String> targetStepNames = new List<String>();
    if (hasCompensations) {
      targetStepNames.add(stack[stack.size() - 1] + '_Compensate');
    } else if (String.isNotBlank(instance.Current_Step__c)) {
      if (instance.Current_Step__c.contains(',')) {
        for (String pStep : instance.Current_Step__c.split(',')) {
          targetStepNames.add(pStep.trim());
        }
      } else {
        targetStepNames.add(instance.Current_Step__c);
      }
    }

    if (String.isBlank(instance.Current_Step__c) && !hasCompensations) {
      Type wflowType = Type.forName(instance.Workflow_Name__c);
      if (wflowType != null) {
        Object defObj = wflowType.newInstance();
        if (defObj instanceof WorkflowDefinition) {
          instance.Current_Step__c = ((WorkflowDefinition) defObj)
            .getInitialStep();
          targetStepNames.add(instance.Current_Step__c);
        }
      }
    }

    // Reset the failed step's execution status to let it execute again. Bulk-load the
    // latest execution per target step in ONE query (was one SOQL per step in a loop),
    // build a name->latest map, then update the resettable ones together.
    Map<String, Workflow_Step_Execution__c> latestStepByName = new Map<String, Workflow_Step_Execution__c>();
    if (!targetStepNames.isEmpty()) {
      for (Workflow_Step_Execution__c se : [
        SELECT Id, Step_Name__c, Status__c, Retry_Count__c, Error_Details__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c IN :targetStepNames
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
      ]) {
        if (!latestStepByName.containsKey(se.Step_Name__c)) {
          latestStepByName.put(se.Step_Name__c, se);
        }
      }
    }

    List<Workflow_Step_Execution__c> stepsToReset = new List<Workflow_Step_Execution__c>();
    for (String targetStepName : targetStepNames) {
      Workflow_Step_Execution__c stepExec = latestStepByName.get(
        targetStepName
      );
      if (stepExec != null && stepExec.Status__c != 'Completed') {
        stepExec.Status__c = 'Pending';
        stepExec.Retry_Count__c = 0; // reset retry counter
        stepExec.Error_Details__c = null;
        stepsToReset.add(stepExec);
      }
    }
    if (!stepsToReset.isEmpty()) {
      update as system stepsToReset;
    }

    if (hasCompensations) {
      instance.Status__c = 'Compensating';
    } else {
      instance.Status__c = 'Running';
    }
    instance.Error_Message__c = null;
    update as system instance;

    // Enqueue the orchestrator to resume execution
    if (
      hasCompensations ||
      String.isBlank(instance.Current_Step__c) ||
      !instance.Current_Step__c.contains(',')
    ) {
      if (Test.isRunningTest()) {
        if (!disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(instanceId));
        }
      } else {
        enqueueOrchestrator(instanceId, null);
      }
      return;
    }

    // Parallel forward execution retry: enqueue only incomplete branches. Reuse the
    // already-loaded step map (reset steps are now 'Pending' in memory) instead of
    // re-querying once per branch.
    for (String targetStepName : targetStepNames) {
      Workflow_Step_Execution__c stepExec = latestStepByName.get(
        targetStepName
      );
      if (stepExec == null || stepExec.Status__c != 'Completed') {
        if (Test.isRunningTest()) {
          if (!disableQueueableInTest) {
            System.enqueueJob(
              new WorkflowOrchestrator(instanceId, targetStepName)
            );
          }
        } else {
          enqueueOrchestrator(instanceId, targetStepName);
        }
      }
    }
  }

  /**
   * Builds the Error_Message for a stalled ("rollback incomplete") saga, preserving
   * the cancel-driven phase marker when applicable. The resume paths (resumeCompensation,
   * the watchdog sleep-resume, and runStep) infer whether to resume as 'Cancelling'
   * vs 'Compensating' from the presence of 'Cancelled' in this text, so a cancel-driven
   * rollback must retain that marker across the stall — otherwise a cancelled saga would
   * resume as a plain compensation and wrongly terminate as 'Compensated' instead of
   * 'Cancelled'.
   */
  private static String buildRollbackIncompleteMessage(
    Boolean wasCancelling,
    String detail
  ) {
    return (wasCancelling ? 'Cancelled by user. ' : '') + detail;
  }

  /**
   * Resumes a saga whose rollback stalled (status CompensationFailed) from exactly
   * the failed compensation point. The remaining LIFO stack — preserved intact when
   * the compensation failed — is replayed in strict order through the existing
   * compensation/orchestrator path; no forward step is re-executed and no
   * already-successful compensation is re-run.
   *
   * Idempotent by construction: the status guard + FOR UPDATE lock means a second
   * (e.g. double-clicked) resume sees the instance already out of CompensationFailed
   * and is a no-op, so two concurrent orchestrator chains can never roll back the
   * same instance and no compensation is double-run.
   */
  public static void resumeCompensation(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT Id, Status__c, Compensation_Stack__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId AND Status__c = 'CompensationFailed'
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      // Not stalled (already resumed, fully compensated, or never stalled). The
      // operator action is idempotent, so treat this as a safe no-op.
      return;
    }
    Workflow_Instance__c instance = instances[0];

    List<String> stack = new List<String>();
    if (String.isNotBlank(instance.Compensation_Stack__c)) {
      stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
    }

    if (stack.isEmpty()) {
      // Defensive: a stalled state with no remaining work means the rollback is in
      // fact complete. Promote it to the fully-compensated terminal state.
      instance.Status__c = 'Compensated';
      instance.Current_Step__c = null;
      instance.Error_Message__c = null;
      update as system instance;
      return;
    }

    // Resume into the same phase the rollback was running in. A cancel-driven rollback
    // continues as 'Cancelling'; a failure-driven one as 'Compensating'. The phase is
    // identified by the engine-owned 'Cancelled by user' marker (set by cancel() and the
    // stalled-message builder) rather than an arbitrary 'Cancelled' substring, so a
    // failure-driven rollback whose compensation error text merely contains the word
    // "Cancelled" is not mistaken for a cancellation.
    Boolean isCancelling =
      instance.Error_Message__c != null &&
      instance.Error_Message__c.contains('Cancelled by user');
    instance.Status__c = isCancelling ? 'Cancelling' : 'Compensating';
    // Clear the stalled "rollback incomplete" banner, but for a cancel-driven rollback
    // keep the 'Cancelled by user' marker: runStep and the watchdog sleep-resume path read
    // it to restore the phase as 'Cancelling' if a remaining compensation suspends (RETRY/
    // SLEEP) before the stack drains. Without it the rollback would finish 'Compensated'
    // instead of 'Cancelled'. Also clear any stale sleep deadline so a later SUSPEND/
    // approval gate is not prematurely woken by the watchdog.
    instance.Error_Message__c = isCancelling
      ? 'Cancelled by user. Compensating.'
      : null;
    instance.Sleep_Until__c = null;
    instance.Async_Job_Id__c = null;
    update as system instance;

    // Append-only: create a FRESH pending compensation attempt for the stalled
    // top-of-stack step, leaving the failed attempt's record intact for the audit
    // trail. This is what makes runCompensationStep re-run the stalled compensation
    // rather than treating the prior Failed record as a terminal "already done".
    appendCompensationRetryStep(instance, stack);

    scheduleTimeoutJobForInstance(instance.Id);
    if (Test.isRunningTest()) {
      if (!disableQueueableInTest) {
        System.enqueueJob(new WorkflowOrchestrator(instance.Id));
      }
    } else {
      enqueueOrchestrator(instance.Id, null);
    }
  }

  /**
   * Inserts a new Pending compensation step-execution log for the current top of the
   * rollback stack, unless a non-terminal (Pending/Running/Retrying) attempt already
   * exists. Unlike preCreateFirstCompensationStep, it does NOT short-circuit on a
   * prior terminal (Failed) attempt — that record is preserved and a fresh attempt is
   * appended, keeping the audit trail append-only while letting the rollback resume.
   */
  private static void appendCompensationRetryStep(
    Workflow_Instance__c instance,
    List<String> stack
  ) {
    if (stack == null || stack.isEmpty()) {
      return;
    }
    String activeStepName = stack[stack.size() - 1];
    String compensationStepLogName = activeStepName + '_Compensate';

    List<Workflow_Step_Execution__c> existing = [
      SELECT Id, Status__c, Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :compensationStepLogName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    // If an attempt is already in flight, do not stack a duplicate (idempotency).
    if (!existing.isEmpty()) {
      String latestStatus = existing[0].Status__c;
      if (
        latestStatus == 'Pending' ||
        latestStatus == 'Running' ||
        latestStatus == 'Retrying'
      ) {
        return;
      }
    }

    // Seed the retry attempt. Prefer any checkpoint the failed compensation already saved
    // (a YIELD stores progress in its own Output__c → StepContext.stepStateJson), so a
    // resumed compensation continues from where it left off rather than re-running partial
    // rollback side effects from the start. Fall back to the original forward execution's
    // input/output (the initial undo context) when the failed attempt has no saved state
    // (e.g. a RETRY attempt nulls its Output before exhausting).
    List<Workflow_Step_Execution__c> originalExecs = [
      SELECT Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :activeStepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    String forwardInput = !originalExecs.isEmpty()
      ? originalExecs[0].Input__c
      : null;
    String forwardOutput = !originalExecs.isEmpty()
      ? originalExecs[0].Output__c
      : null;

    String priorInput = (!existing.isEmpty() &&
      String.isNotBlank(existing[0].Input__c))
      ? existing[0].Input__c
      : forwardInput;
    String checkpointOutput = (!existing.isEmpty() &&
      String.isNotBlank(existing[0].Output__c))
      ? existing[0].Output__c
      : forwardOutput;

    Workflow_Step_Execution__c compStepExec = new Workflow_Step_Execution__c();
    compStepExec.Workflow_Instance__c = instance.Id;
    compStepExec.Step_Name__c = compensationStepLogName;
    compStepExec.Status__c = 'Pending';
    compStepExec.Input__c = priorInput;
    compStepExec.Output__c = checkpointOutput;
    compStepExec.Retry_Count__c = 0;
    insert as system compStepExec;
  }

  private static void runCompensationStep(
    Workflow_Instance__c instance,
    String reassertedStatus
  ) {
    // 1. Read the compensation stack
    if (String.isBlank(instance.Compensation_Stack__c)) {
      instance.Status__c = (instance.Status__c == 'Cancelling')
        ? 'Cancelled'
        : 'Compensated';
      instance.Current_Step__c = null;
      update as system instance;
      // Fire-and-forget outbound lifecycle event on terminal transition.
      WorkflowLifecyclePublisher.publish(instance);
      return;
    }

    List<String> stack = (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
    if (stack.isEmpty()) {
      instance.Status__c = (instance.Status__c == 'Cancelling')
        ? 'Cancelled'
        : 'Compensated';
      instance.Current_Step__c = null;
      update as system instance;
      // Fire-and-forget outbound lifecycle event on terminal transition.
      WorkflowLifecyclePublisher.publish(instance);
      return;
    }

    // 2. Get the top step to compensate (do not pop yet, only pop on success)
    String activeStepName = stack[stack.size() - 1];

    // 3. Create or retrieve the compensation step execution log with FOR UPDATE lock.
    // Load all executions so compensateVisit can be derived in Apex without an
    // extra COUNT() SOQL query.
    String compensationStepLogName = activeStepName + '_Compensate';
    List<Workflow_Step_Execution__c> stepExecs = [
      SELECT Id, Status__c, Input__c, Output__c, Retry_Count__c, Step_Name__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :compensationStepLogName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
    ];

    Integer compensateVisit = 0;
    for (Workflow_Step_Execution__c exec : stepExecs) {
      if (exec.Status__c == 'Compensated' || exec.Status__c == 'Completed') {
        compensateVisit++;
      }
    }

    if (!stepExecs.isEmpty()) {
      stepExecs = [
        SELECT Id, Status__c, Input__c, Output__c, Retry_Count__c, Step_Name__c
        FROM Workflow_Step_Execution__c
        WHERE Id = :stepExecs[0].Id
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
    }

    // Re-query the instance after acquiring the lock on the step execution to get the most up-to-date committed state
    List<Workflow_Instance__c> freshInstances = [
      SELECT
        Id,
        Status__c,
        Compensation_Stack__c,
        Definition_Version__c,
        Workflow_Name__c,
        Input__c,
        Correlation_Key__c,
        Root_Correlation_Key__c,
        Error_Message__c,
        Previous_Run_At__c
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (freshInstances.isEmpty()) {
      throw new WorkflowException(
        'Workflow instance not found: ' + instance.Id
      );
    }
    instance = freshInstances[0];

    // A signal-resumed compensation: runStep detected the rollback but DEFERRED
    // the Suspended/Running -> Compensating status DML (so a CalloutStep callout
    // stays legal), so the re-queried status is still Suspended/Running. Restore
    // the in-memory compensating phase runStep computed so the guard below and the
    // terminal-status decisions use the correct phase; the DML is committed later
    // (before compensate() for an ordinary step, after it for a CalloutStep). Only
    // restore from Suspended/Running -- a status another transaction drove to a
    // terminal/failed value is left intact so the guard can early-exit on it.
    if (
      reassertedStatus != null &&
      (instance.Status__c == 'Suspended' || instance.Status__c == 'Running')
    ) {
      instance.Status__c = reassertedStatus;
      instance.Async_Job_Id__c = null;
    }

    // Check early exit conditions for instance status
    if (
      instance.Status__c != 'Compensating' &&
      instance.Status__c != 'Cancelling'
    ) {
      return; // Already completed compensation or aborted
    }

    Workflow_Step_Execution__c stepExec;
    if (stepExecs.isEmpty()) {
      stepExec = new Workflow_Step_Execution__c();
      stepExec.Workflow_Instance__c = instance.Id;
      stepExec.Step_Name__c = compensationStepLogName;
      stepExec.Status__c = 'Running';
      stepExec.Retry_Count__c = 0;

      // Retrieve the original step execution to get inputs/outputs
      List<Workflow_Step_Execution__c> originalExecs = [
        SELECT Input__c, Output__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instance.Id
          AND Step_Name__c = :activeStepName
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
        LIMIT 1
      ];

      stepExec.Input__c = !originalExecs.isEmpty()
        ? originalExecs[0].Input__c
        : null;
      stepExec.Output__c = !originalExecs.isEmpty()
        ? originalExecs[0].Output__c
        : null;
    } else {
      stepExec = stepExecs[0];
      if (
        stepExec.Status__c == 'Completed' ||
        stepExec.Status__c == 'Compensated' ||
        stepExec.Status__c == 'Failed' ||
        stepExec.Status__c == 'Cancelled'
      ) {
        stack.remove(stack.size() - 1);
        instance.Compensation_Stack__c = JSON.serialize(stack);
        update as system instance;

        if (!stack.isEmpty()) {
          preCreateFirstCompensationStep(instance);
          scheduleTimeoutJobForInstance(instance.Id);
        }

        if (Test.isRunningTest()) {
          if (!disableQueueableInTest) {
            System.enqueueJob(new WorkflowOrchestrator(instance.Id));
          }
        } else {
          enqueueOrchestrator(instance.Id, null);
        }
        return;
      }
      stepExec.Status__c = 'Running';
    }

    // 4. Instantiate the step and execute compensate
    Type stepType = Type.forName(activeStepName);
    if (stepType == null) {
      throw new WorkflowException(
        'Could not resolve class for step compensation: ' + activeStepName
      );
    }

    Object stepInstanceObj = stepType.newInstance();
    if (!(stepInstanceObj instanceof CompensatableStep)) {
      stepExec.Status__c = 'Compensated';
      saveStepExec(stepExec);

      stack.remove(stack.size() - 1);
      instance.Compensation_Stack__c = JSON.serialize(stack);
      update as system instance;

      if (!stack.isEmpty()) {
        scheduleTimeoutJobForInstance(instance.Id);
      }

      if (Test.isRunningTest()) {
        if (!disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(instance.Id));
        }
      } else {
        enqueueOrchestrator(instance.Id, null);
      }
      return;
    }

    CompensatableStep compensatableStepInstance = (CompensatableStep) stepInstanceObj;

    // Build context for compensate
    String prevOutput = null;
    List<Workflow_Step_Execution__c> completedBefore = [
      SELECT Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Status__c = 'Completed'
        AND Step_Name__c != :activeStepName
        AND Step_Name__c != :compensationStepLogName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];
    if (!completedBefore.isEmpty()) {
      prevOutput = completedBefore[0].Output__c;
    }

    // compensateVisit: computed above from the stepExecs list to avoid a
    // separate COUNT() SOQL query.

    // previousRunAt is threaded here only for parity with the forward execute()
    // context, so compensate() sees the same instance metadata rather than a
    // surprising null. It is NOT how a compensation identifies what to undo: a
    // correct compensate() reverses exactly what the forward step did, using the
    // recorded step Input__c/Output__c above -- never a fresh "scan since
    // previousRunAt", which can drift to records the forward run never touched.
    StepContext context = new StepContext(
      instance.Id,
      instance.Workflow_Name__c,
      compensationStepLogName,
      resolvePayload(stepExec.Input__c),
      resolvePayload(prevOutput),
      resolvePayload(stepExec.Output__c),
      resolvePayload(instance.Input__c),
      instance.Definition_Version__c != null
        ? (Integer) instance.Definition_Version__c
        : 1,
      compensateVisit,
      new PendingSignalSource(instance.Id),
      instance.Previous_Run_At__c
    );

    // Save/Commit step execution status and set Timeout_At__c before executing compensation so watchdog can detect timeouts.
    // As in the forward execute() path, a CalloutStep performs a synchronous,
    // payload-driven callout inside compensate() and Salesforce forbids a
    // callout once the transaction holds pending DML, so defer this timeout
    // write past compensate() for a CalloutStep. The step's Timeout_At__c and
    // scheduled job were already committed when it was queued, so the watchdog
    // stays armed; the finally block reconciles the timeout afterward.
    Boolean deferPreExecDml = compensatableStepInstance instanceof CalloutStep;
    // Persist the compensating status that runStep re-asserted in memory. For an
    // ordinary step commit it now (matching the prior commit-before-compensate()
    // behavior); for a CalloutStep leave it uncommitted so the payload-driven
    // callout in compensate() below stays legal -- handleCompensationStepResult
    // writes the instance after compensate() returns. The earlier early-return
    // branches (already-terminal exec, non-CompensatableStep) commit the status
    // via their own update, so a pending re-assert is never dropped.
    if (reassertedStatus != null && !deferPreExecDml) {
      update as system instance;
    }
    stepExec.Status__c = 'Running';
    Integer timeoutSeconds = null;
    if (compensatableStepInstance instanceof TimeoutConfigurable) {
      timeoutSeconds = ((TimeoutConfigurable) compensatableStepInstance)
        .getTimeoutSeconds();
    }
    if (timeoutSeconds != null && timeoutSeconds > 0) {
      stepExec.Timeout_At__c = DateTime.now().addSeconds(timeoutSeconds);
      if (!deferPreExecDml) {
        saveStepExec(stepExec);
      }
    } else {
      stepExec.Timeout_At__c = null;
      if (stepExec.Id == null && !deferPreExecDml) {
        saveStepExec(stepExec);
      }
    }

    StepResult result;
    try {
      result = compensatableStepInstance.compensate(context);
    } catch (Exception ex) {
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c =
        ex.getMessage() +
        '\n' +
        ex.getStackTraceString();
      saveStepExec(stepExec);
      failWorkflowInstance(
        instance.Id,
        compensationStepLogName,
        ex.getMessage()
      );
      return;
    } finally {
      if (timeoutSeconds != null && timeoutSeconds > 0) {
        stepExec.Timeout_At__c = null;
        saveStepExec(stepExec);
        cancelTimeoutJob(instance.Id, compensationStepLogName);
      }
    }

    handleCompensationStepResult(instance, stepExec, result, stack, context);
  }

  private static void handleCompensationStepResult(
    Workflow_Instance__c instance,
    Workflow_Step_Execution__c stepExec,
    StepResult result,
    List<String> stack,
    StepContext context
  ) {
    Workflow_Instance__c freshInstance = [
      SELECT Status__c
      FROM Workflow_Instance__c
      WHERE Id = :instance.Id
      WITH SYSTEM_MODE
      FOR UPDATE
    ];
    if (
      freshInstance.Status__c == 'Failed' ||
      freshInstance.Status__c == 'CompensationFailed' ||
      freshInstance.Status__c == 'Cancelled'
    ) {
      throw new WorkflowException(
        'Workflow execution was terminated or cancelled.'
      );
    }

    if (result.action == StepResult.ActionType.COMPLETE) {
      stepExec.Status__c = 'Compensated';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.outputJson,
        'Output_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      // A compensating step that read signals durably completed; consume them on
      // the same contract as a forward step so a later compensation attempt or
      // step does not re-observe them. Compensation runs serially (LIFO) and
      // does not claim, so it consumes still-Received rows plus same-name cleanup.
      markSignalsConsumed(instance.Id, context, false);

      stack.remove(stack.size() - 1);
      instance.Compensation_Stack__c = JSON.serialize(stack);

      if (stack.isEmpty()) {
        instance.Status__c = (instance.Status__c == 'Cancelling')
          ? 'Cancelled'
          : 'Compensated';
        instance.Current_Step__c = null;
      }
      update as system instance;

      if (!stack.isEmpty()) {
        scheduleTimeoutJobForInstance(instance.Id);
      }

      if (Test.isRunningTest()) {
        if (!disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(instance.Id));
        }
      } else {
        enqueueOrchestrator(instance.Id, null);
      }

      // Fire-and-forget outbound lifecycle event; only fires once the stack is
      // drained and the instance has reached Compensated/Cancelled. Runs LAST so
      // the load-bearing orchestrator enqueue above keeps first claim on DML budget.
      WorkflowLifecyclePublisher.publish(instance);
    } else if (result.action == StepResult.ActionType.YIELD) {
      stepExec.Status__c = 'Running';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.stepStateJson,
        'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);

      update as system instance;

      scheduleTimeoutJobForInstance(instance.Id);
      enqueueOrchestrator(instance.Id, null);
    } else if (result.action == StepResult.ActionType.SUSPEND) {
      stepExec.Status__c = 'Pending';
      stepExec.Output__c = String.isNotBlank(result.stepStateJson)
        ? savePayloadIfNeeded(
            instance.Id,
            result.stepStateJson,
            'State_Suspend_' +
              stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
          )
        : null;
      saveStepExec(stepExec);
      instance.Status__c = 'Suspended';
      update as system instance;
    } else if (result.action == StepResult.ActionType.SLEEP) {
      stepExec.Status__c = 'Pending';
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        result.stepStateJson,
        'State_' + stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);
      instance.Status__c = 'Suspended';
      if (result.sleepDurationSeconds != null) {
        instance.Sleep_Until__c = DateTime.now()
          .addSeconds(result.sleepDurationSeconds);
        instance.Async_Job_Id__c = scheduleSleepResume(
          instance.Id,
          result.sleepDurationSeconds
        );
      }
      update as system instance;
    } else if (result.action == StepResult.ActionType.WAIT_FOR_APPROVAL) {
      stepExec.Status__c = 'Pending';
      Map<String, Object> state = new Map<String, Object>{
        'waitingForApproval' => true,
        'approvalKey' => result.approvalKey,
        'approvalRole' => result.approvalRole
      };
      stepExec.Output__c = savePayloadIfNeeded(
        instance.Id,
        JSON.serialize(state),
        'State_Approval_' +
        stepExec.Step_Name__c.replaceAll('[^a-zA-Z0-9]', '_')
      );
      saveStepExec(stepExec);
      instance.Status__c = 'Suspended';
      update as system instance;
    } else if (result.action == StepResult.ActionType.RETRY) {
      stepExec.Retry_Count__c += 1;
      RetryPolicy policy = (result.retryPolicy != null)
        ? result.retryPolicy
        : new RetryPolicy();

      if (stepExec.Retry_Count__c >= policy.maximumAttempts) {
        stepExec.Status__c = 'Failed';
        stepExec.Error_Details__c =
          'Compensation max retries (' +
          policy.maximumAttempts +
          ') exceeded.';
        saveStepExec(stepExec);

        // The author's RetryPolicy budget for the automatic phase is exhausted, but
        // the remaining stack is intact. Surface a recoverable "rollback incomplete"
        // state (resumable by an operator) instead of abandoning the deeper steps.
        Boolean wasCancelling = (instance.Status__c == 'Cancelling');
        instance.Status__c = 'CompensationFailed';
        instance.Error_Message__c = buildRollbackIncompleteMessage(
          wasCancelling,
          'Rollback incomplete: compensation step ' +
            stepExec.Step_Name__c +
            ' failed after max retries.'
        );
        // This branch was reached by the scheduled retry firing, so clear that elapsed
        // sleep deadline; otherwise a later resumed SUSPEND/approval gate would be
        // immediately re-woken by the watchdog (Sleep_Until__c <= now).
        instance.Sleep_Until__c = null;
        instance.Async_Job_Id__c = null;
        update as system instance;
        WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
        WorkflowLifecyclePublisher.publish(instance);
      } else {
        stepExec.Status__c = 'Retrying';
        stepExec.Output__c = null;
        saveStepExec(stepExec);

        Double backoff = Math.pow(
          (Double) policy.backoffCoefficient,
          (Double) (stepExec.Retry_Count__c - 1)
        );
        Integer delay = (Integer) (policy.initialIntervalSeconds * backoff);
        delay = Math.min(delay, 86400);
        instance.Status__c = 'Suspended';
        instance.Sleep_Until__c = DateTime.now().addSeconds(delay);
        instance.Async_Job_Id__c = scheduleRetry(
          instance.Id,
          stepExec.Step_Name__c,
          delay
        );
        update as system instance;
      }
    } else {
      stepExec.Status__c = 'Failed';
      stepExec.Error_Details__c =
        'Unsupported compensation action: ' +
        (result != null ? result.action : null);
      saveStepExec(stepExec);

      // Remaining stack is intact; leave the saga recoverable rather than abandoning it.
      Boolean wasCancelling = (instance.Status__c == 'Cancelling');
      instance.Status__c = 'CompensationFailed';
      instance.Error_Message__c = buildRollbackIncompleteMessage(
        wasCancelling,
        'Rollback incomplete: compensation step ' +
          stepExec.Step_Name__c +
          ' failed: Unsupported action.'
      );
      // Clear any stale sleep/retry deadline (see the max-retries branch above).
      instance.Sleep_Until__c = null;
      instance.Async_Job_Id__c = null;
      update as system instance;
      WorkflowAlertManager.sendAlert(instance, instance.Error_Message__c);
      WorkflowLifecyclePublisher.publish(instance);
    }
  }

  private static void preCreateFirstCompensationStep(
    Workflow_Instance__c instance
  ) {
    if (String.isBlank(instance.Compensation_Stack__c)) {
      return;
    }
    List<String> stack = (List<String>) JSON.deserialize(
      instance.Compensation_Stack__c,
      List<String>.class
    );
    if (stack.isEmpty()) {
      return;
    }
    String activeStepName = stack[stack.size() - 1];
    String compensationStepLogName = activeStepName + '_Compensate';

    // Check if it already exists to avoid duplicates
    List<Workflow_Step_Execution__c> existing = [
      SELECT Id
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :compensationStepLogName
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!existing.isEmpty()) {
      return;
    }

    List<Workflow_Step_Execution__c> originalExecs = [
      SELECT Input__c, Output__c
      FROM Workflow_Step_Execution__c
      WHERE
        Workflow_Instance__c = :instance.Id
        AND Step_Name__c = :activeStepName
      WITH SYSTEM_MODE
      ORDER BY CreatedDate DESC, Id DESC
      LIMIT 1
    ];

    Workflow_Step_Execution__c compStepExec = new Workflow_Step_Execution__c();
    compStepExec.Workflow_Instance__c = instance.Id;
    compStepExec.Step_Name__c = compensationStepLogName;
    compStepExec.Status__c = 'Pending';
    compStepExec.Input__c = !originalExecs.isEmpty()
      ? originalExecs[0].Input__c
      : null;
    compStepExec.Output__c = !originalExecs.isEmpty()
      ? originalExecs[0].Output__c
      : null;
    compStepExec.Retry_Count__c = 0;
    insert as system compStepExec;
  }

  /**
   * Cancels a workflow instance, aborts scheduled jobs, and optionally runs saga compensations.
   */
  public static void cancel(Id instanceId, Boolean runCompensations) {
    // Cancel the target instance and its entire active descendant tree. Descendants are
    // gathered iteratively (one set-based query per tree level) rather than via recursive
    // cancel() calls, so deep/wide trees cannot blow the SOQL or stack-depth governor
    // limits through uncontrolled recursion. Parent-before-child ordering is preserved.
    //
    // Note: each node still costs a handful of SOQL/DML in cancelSingleInstance(); a tree
    // with thousands of nodes would need async chunking. That is intentionally out of
    // scope here — the goal is to remove the recursion-driven multiplication.
    // The traversal always yields the target first, so it is cancelled with the original
    // not-found semantics (throwIfMissing = true); descendants are best-effort.
    //
    // Lifecycle events are collected and published in a single bulk batch AFTER every
    // node is cancelled, so the best-effort publish never spends a DML statement that a
    // later child cancellation still needs.
    List<Workflow_Instance__c> terminallyCancelled = new List<Workflow_Instance__c>();
    for (Id targetId : collectInstanceAndActiveDescendants(instanceId)) {
      Workflow_Instance__c cancelled = cancelSingleInstance(
        targetId,
        runCompensations,
        targetId == instanceId
      );
      if (cancelled != null) {
        terminallyCancelled.add(cancelled);
      }
    }
    WorkflowLifecyclePublisher.publish(terminallyCancelled);
  }

  /**
   * Breadth-first collection of an instance plus all of its active descendants using one
   * set-based query per tree level. Returns IDs in parent-before-child order. A `seen`
   * guard makes the traversal safe against accidental parent-reference cycles.
   */
  private static List<Id> collectInstanceAndActiveDescendants(Id rootId) {
    List<Id> ordered = new List<Id>{ rootId };
    Set<Id> seen = new Set<Id>{ rootId };
    List<Id> frontier = new List<Id>{ rootId };
    while (!frontier.isEmpty()) {
      List<Workflow_Instance__c> children = [
        SELECT Id
        FROM Workflow_Instance__c
        WHERE
          Parent_Instance__c IN :frontier
          AND Status__c IN ('Pending', 'Running', 'Suspended', 'Cancelling', 'CompensationFailed')
        WITH SYSTEM_MODE
      ];
      List<Id> nextFrontier = new List<Id>();
      for (Workflow_Instance__c child : children) {
        if (!seen.contains(child.Id)) {
          seen.add(child.Id);
          ordered.add(child.Id);
          nextFrontier.add(child.Id);
        }
      }
      frontier = nextFrontier;
    }
    return ordered;
  }

  /**
   * Cancels a single workflow instance (no descendant traversal). When throwIfMissing is
   * true the original not-found exception is preserved for the top-level target.
   *
   * Returns the instance when this call drove it to a terminal Cancelled state (the
   * no-compensation path), otherwise null. The caller (cancel()) collects these and
   * publishes one bulk lifecycle batch AFTER the whole tree is cancelled, so a
   * per-node publish can never spend the DML budget that a later child cancellation
   * still needs. (The compensation path reaches Cancelled asynchronously and emits
   * its own event from the orchestrator.)
   */
  private static Workflow_Instance__c cancelSingleInstance(
    Id instanceId,
    Boolean runCompensations,
    Boolean throwIfMissing
  ) {
    List<Workflow_Instance__c> instances = [
      SELECT Id, Status__c, Current_Step__c, Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      if (throwIfMissing) {
        throw new WorkflowException(
          'Workflow instance not found: ' + instanceId
        );
      }
      return null;
    }

    Workflow_Instance__c instance = instances[0];
    if (
      instance.Status__c == 'Completed' ||
      instance.Status__c == 'Failed' ||
      instance.Status__c == 'Compensated' ||
      instance.Status__c == 'Cancelled' ||
      instance.Status__c == 'ContinuedAsNew'
    ) {
      return null; // Already in terminal state
    }
    // Note: CompensationFailed is intentionally NOT treated as terminal here — a stalled
    // rollback is resumable and still holds un-reversed side effects, so cancellation must
    // reach it (handled explicitly below) rather than skip it.

    // 1. Lock active step executions FOR UPDATE first
    List<Workflow_Step_Execution__c> stepExecs = new List<Workflow_Step_Execution__c>();
    if (String.isNotBlank(instance.Current_Step__c)) {
      List<String> activeStepNames = new List<String>();
      if (instance.Current_Step__c.contains(',')) {
        activeStepNames = instance.Current_Step__c.split(',');
      } else {
        activeStepNames.add(instance.Current_Step__c);
      }

      stepExecs = [
        SELECT Id, Status__c
        FROM Workflow_Step_Execution__c
        WHERE
          Workflow_Instance__c = :instanceId
          AND Step_Name__c IN :activeStepNames
          AND Status__c IN ('Running', 'Pending', 'Retrying')
        WITH SYSTEM_MODE
        FOR UPDATE
      ];
    }

    // 2. Lock the instance FOR UPDATE second
    instances = [
      SELECT
        Id,
        Status__c,
        Current_Step__c,
        Compensation_Stack__c,
        Error_Message__c,
        Workflow_Name__c,
        Correlation_Key__c,
        Root_Correlation_Key__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
      FOR UPDATE
    ];
    if (instances.isEmpty()) {
      if (throwIfMissing) {
        throw new WorkflowException(
          'Workflow instance not found: ' + instanceId
        );
      }
      return null;
    }
    instance = instances[0];

    // Recheck status under lock
    if (
      instance.Status__c == 'Completed' ||
      instance.Status__c == 'Failed' ||
      instance.Status__c == 'Compensated' ||
      instance.Status__c == 'Cancelled' ||
      instance.Status__c == 'ContinuedAsNew'
    ) {
      return null;
    }

    // Abort all scheduled jobs for this instance (sleeps, retries, timeouts)
    abortScheduledJobs(instanceId);

    // Update step executions to Cancelled
    for (Workflow_Step_Execution__c stepExec : stepExecs) {
      stepExec.Status__c = 'Cancelled';
    }
    if (!stepExecs.isEmpty()) {
      update as system stepExecs;
    }

    // A stalled rollback (CompensationFailed) being cancelled is handled per cancel mode:
    // with compensations requested, resume the remaining rollback under the cancel phase so
    // it drains to 'Cancelled' (every remaining side effect reversed); without, force it
    // terminal 'Cancelled', abandoning the un-run compensations but releasing its key.
    if (instance.Status__c == 'CompensationFailed') {
      List<String> remaining = new List<String>();
      if (String.isNotBlank(instance.Compensation_Stack__c)) {
        remaining = (List<String>) JSON.deserialize(
          instance.Compensation_Stack__c,
          List<String>.class
        );
      }
      if (runCompensations && !remaining.isEmpty()) {
        instance.Status__c = 'Cancelling';
        instance.Error_Message__c = 'Cancelled by user. Compensating.';
        update as system instance;

        // Append a fresh attempt for the stalled top-of-stack step (the prior Failed
        // attempt is preserved) so the existing compensation loop re-runs it.
        appendCompensationRetryStep(instance, remaining);
        scheduleTimeoutJobForInstance(instance.Id);
        if (Test.isRunningTest()) {
          if (!disableQueueableInTest) {
            System.enqueueJob(new WorkflowOrchestrator(instance.Id));
          }
        } else {
          enqueueOrchestrator(instance.Id, null);
        }
        // Not terminal yet — the orchestrator emits the lifecycle event when the
        // compensation stack drains to Cancelled.
        return null;
      } else {
        instance.Status__c = 'Cancelled';
        instance.Error_Message__c = 'Cancelled by user.';
        update as system instance;
        // Terminal immediately — hand back to cancel() for bulk lifecycle publish.
        return instance;
      }
    }

    // Check for compensations
    Boolean hasCompensations = false;
    if (runCompensations && String.isNotBlank(instance.Compensation_Stack__c)) {
      List<String> stack = (List<String>) JSON.deserialize(
        instance.Compensation_Stack__c,
        List<String>.class
      );
      hasCompensations = !stack.isEmpty();
    }

    if (hasCompensations) {
      instance.Status__c = 'Cancelling';
      instance.Error_Message__c = 'Cancelled by user. Compensating.';
      preCreateFirstCompensationStep(instance);
      update as system instance;

      // Kick off rollback loop
      if (Test.isRunningTest()) {
        if (!disableQueueableInTest) {
          System.enqueueJob(new WorkflowOrchestrator(instance.Id));
        }
      } else {
        enqueueOrchestrator(instance.Id, null);
      }
      // Not terminal yet (Cancelling); the orchestrator emits the lifecycle event
      // when the compensation stack drains to Cancelled.
      return null;
    }

    instance.Status__c = 'Cancelled';
    instance.Error_Message__c = 'Cancelled by user.';
    update as system instance;
    // Terminal: hand the instance back to cancel() for a single bulk publish after
    // the whole descendant tree is cancelled (preserves DML headroom mid-loop).
    // Active child workflows are handled by the caller (cancel()) via iterative
    // descendant traversal, so no recursive child cancellation happens here.
    return instance;
  }

  /**
   * Aborts all Scheduled Apex cron jobs associated with the workflow instance.
   */
  public static void abortScheduledJobs(Id instanceId) {
    String sleepPrefix = 'WorkflowSleep_' + instanceId + '_%';
    String retryPrefix = 'WorkflowRetry_' + instanceId + '_%';
    String timeoutPrefix = 'Timeout_' + instanceId + '_%';
    List<CronTrigger> triggers = [
      SELECT Id
      FROM CronTrigger
      WHERE
        CronJobDetail.Name LIKE :sleepPrefix
        OR CronJobDetail.Name LIKE :retryPrefix
        OR CronJobDetail.Name LIKE :timeoutPrefix
      WITH SYSTEM_MODE
    ];
    for (CronTrigger triggerJob : triggers) {
      try {
        System.abortJob(triggerJob.Id);
      } catch (Exception e) {
        System.debug(
          LoggingLevel.WARN,
          'Failed to abort job ' + triggerJob.Id + ': ' + e.getMessage()
        );
      }
    }
  }

  public static void enqueueOrchestrators(List<Id> instanceIds) {
    WorkflowWatchdog.bootstrap();
    if (Test.isRunningTest()) {
      for (Id instId : instanceIds) {
        try {
          if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new WorkflowOrchestrator(instId));
          }
        } catch (Exception e) {
          System.debug(
            LoggingLevel.WARN,
            'Failed to enqueue WorkflowOrchestrator for ' +
              instId +
              ': ' +
              e.getMessage()
          );
        }
      }
      return;
    }
    List<Workflow_Event__e> events = new List<Workflow_Event__e>();
    for (Id instId : instanceIds) {
      events.add(
        new Workflow_Event__e(
          Workflow_Instance_Id__c = instId,
          Event_Type__c = 'RUN_STEP',
          Payload__c = null
        )
      );
    }
    if (!events.isEmpty()) {
      List<Database.SaveResult> srs = EventBus.publish(events);
      for (Database.SaveResult sr : srs) {
        if (!sr.isSuccess()) {
          List<String> errMsgs = new List<String>();
          for (Database.Error err : sr.getErrors()) {
            errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
          }
          throw new WorkflowException(
            'Failed to publish orchestrator event: ' +
            String.join(errMsgs, ', ')
          );
        }
      }
    }
  }

  public static void enqueueOrchestrator(Id instanceId, String stepName) {
    WorkflowWatchdog.bootstrap();
    if (Test.isRunningTest()) {
      return;
    }
    Workflow_Event__e event = new Workflow_Event__e(
      Workflow_Instance_Id__c = instanceId,
      Event_Type__c = 'RUN_STEP',
      Payload__c = stepName
    );
    Database.SaveResult sr = EventBus.publish(event);
    if (!sr.isSuccess()) {
      List<String> errMsgs = new List<String>();
      for (Database.Error err : sr.getErrors()) {
        errMsgs.add(err.getStatusCode() + ': ' + err.getMessage());
      }
      throw new WorkflowException(
        'Failed to publish orchestrator event: ' + String.join(errMsgs, ', ')
      );
    }
  }

  private static void validateCorrelationKey(String correlationKey) {
    if (String.isBlank(correlationKey)) {
      throw new WorkflowException('Correlation key is required.');
    }
    if (correlationKey.length() > 200) {
      throw new WorkflowException(
        'Correlation key length cannot exceed 200 characters.'
      );
    }
  }

  public static String resolvePayload(String textValue) {
    if (
      String.isNotBlank(textValue) && textValue.startsWith('{"$attachmentId":')
    ) {
      try {
        Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(
          textValue
        );
        Id attachmentId = (Id) marker.get('$attachmentId');
        List<ContentVersion> cvs = [
          SELECT VersionData
          FROM ContentVersion
          WHERE ContentDocumentId = :attachmentId AND IsLatest = TRUE
          WITH SYSTEM_MODE
        ];
        if (!cvs.isEmpty()) {
          return cvs[0].VersionData.toString();
        }
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.WARN,
          'Failed to resolve offloaded payload, falling back to raw value: ' +
          ex.getMessage()
        );
      }
    }
    return textValue;
  }

  /**
   * Bulk variant of resolvePayload: resolves a list of payload strings, fetching
   * every offloaded ContentVersion in ONE query rather than one per row. A list
   * accessor (e.g. a parent reading a backlog of child-completion signals with
   * large offloaded outputs) would otherwise issue a ContentVersion query per
   * offloaded payload and hit the SOQL-query governor limit after ~100-200 rows,
   * defeating the accessor's design of loading thousands in one call. Inline
   * (non-marker) payloads and unresolved markers pass through unchanged, index
   * for index with the input.
   */
  private static List<String> resolvePayloads(List<String> rawValues) {
    Map<Integer, Id> markerDocByIndex = new Map<Integer, Id>();
    Set<Id> docIds = new Set<Id>();
    for (Integer i = 0; i < rawValues.size(); i++) {
      String v = rawValues[i];
      if (String.isNotBlank(v) && v.startsWith('{"$attachmentId":')) {
        try {
          Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(
            v
          );
          Id docId = (Id) marker.get('$attachmentId');
          markerDocByIndex.put(i, docId);
          docIds.add(docId);
        } catch (Exception ex) {
          System.debug(LoggingLevel.WARN, 'Failed to parse offload marker, using raw value: ' + ex.getMessage());
        }
      }
    }
    Map<Id, String> resolvedByDoc = new Map<Id, String>();
    if (!docIds.isEmpty()) {
      for (ContentVersion cv : [
        SELECT ContentDocumentId, VersionData
        FROM ContentVersion
        WHERE ContentDocumentId IN :docIds AND IsLatest = TRUE
        WITH SYSTEM_MODE
      ]) {
        resolvedByDoc.put(cv.ContentDocumentId, cv.VersionData.toString());
      }
    }
    List<String> out = new List<String>();
    for (Integer i = 0; i < rawValues.size(); i++) {
      Id docId = markerDocByIndex.get(i);
      out.add(
        (docId != null && resolvedByDoc.containsKey(docId))
          ? resolvedByDoc.get(docId)
          : rawValues[i]
      );
    }
    return out;
  }

  public static String savePayloadIfNeeded(
    Id instanceId,
    String textValue,
    String title
  ) {
    if (String.isNotBlank(textValue) && textValue.length() > 100000) {
      ContentVersion cv = new ContentVersion();
      cv.Title = title;
      cv.PathOnClient = title + '.json';
      cv.VersionData = Blob.valueOf(textValue);
      insert as system cv;

      Id docId = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv.Id
        WITH SYSTEM_MODE
      ]
      .ContentDocumentId;

      ContentDocumentLink cdl = new ContentDocumentLink();
      cdl.ContentDocumentId = docId;
      cdl.LinkedEntityId = instanceId;
      cdl.ShareType = 'V';
      cdl.Visibility = 'InternalUsers';
      try {
        insert as system cdl;
      } catch (DmlException ex) {
        System.debug(
          LoggingLevel.FINE,
          'ContentDocumentLink insert failed with default visibility, retrying with AllUsers: ' +
          ex.getMessage()
        );
        cdl.Visibility = 'AllUsers';
        insert as system cdl;
      }

      return JSON.serialize(
        new Map<String, String>{ '$attachmentId' => docId }
      );
    }
    return textValue;
  }

  /**
   * Evaluates and resumes suspended workflows that have exceeded their sleep time,
   * and terminates active steps that have exceeded their timeout limits.
   */
  public static void processWatchdogHeartbeat() {
    Datetime now = System.now();

    // Terminal instances finalized by the timed-out-steps section below. Their
    // lifecycle events are published once at the very END of the heartbeat, after
    // ALL required work (including the sleep-resume section) is done, so the
    // best-effort publish can never spend a DML statement the resume section needs.
    List<Workflow_Instance__c> watchdogTerminalInstances = new List<Workflow_Instance__c>();

    // 1. Process Timed-out Steps
    List<Workflow_Step_Execution__c> timedOutSteps = [
      SELECT Id, Workflow_Instance__c, Step_Name__c, Status__c, Error_Details__c
      FROM Workflow_Step_Execution__c
      WHERE Status__c IN ('Running', 'Pending') AND Timeout_At__c <= :now
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT :WATCHDOG_TIMEOUT_BATCH_SIZE
    ];

    if (!timedOutSteps.isEmpty()) {
      Set<Id> stepIds = new Set<Id>();
      Set<Id> instanceIds = new Set<Id>();
      for (Workflow_Step_Execution__c step : timedOutSteps) {
        stepIds.add(step.Id);
        instanceIds.add(step.Workflow_Instance__c);
      }

      // Lock parent instances
      Map<Id, Workflow_Instance__c> parents = new Map<Id, Workflow_Instance__c>(
        [
          SELECT
            Id,
            Name,
            Status__c,
            Current_Step__c,
            Compensation_Stack__c,
            Error_Message__c,
            Workflow_Name__c,
            Correlation_Key__c,
            Root_Correlation_Key__c
          FROM Workflow_Instance__c
          WHERE Id IN :instanceIds
          WITH SYSTEM_MODE
          FOR UPDATE
        ]
      );

      // Lock step executions
      Map<Id, Workflow_Step_Execution__c> lockedSteps = new Map<Id, Workflow_Step_Execution__c>(
        [
          SELECT
            Id,
            Status__c,
            Error_Details__c,
            Timeout_At__c,
            Step_Name__c,
            Workflow_Instance__c
          FROM Workflow_Step_Execution__c
          WHERE Id IN :stepIds
          WITH SYSTEM_MODE
          FOR UPDATE
        ]
      );

      List<Workflow_Step_Execution__c> stepsToUpdate = new List<Workflow_Step_Execution__c>();
      Map<Id, Workflow_Instance__c> instancesToUpdate = new Map<Id, Workflow_Instance__c>();
      List<Workflow_Step_Execution__c> compensationStepsToInsert = new List<Workflow_Step_Execution__c>();
      List<Id> orchestratorInstanceIds = new List<Id>();

      Set<Id> instancesNeedingCompensationInfo = new Set<Id>();
      Set<String> activeStepNamesForComp = new Set<String>();

      for (Workflow_Step_Execution__c step : timedOutSteps) {
        Workflow_Instance__c parent = parents.get(step.Workflow_Instance__c);
        if (parent == null) {
          continue;
        }
        if (
          parent.Status__c != 'Pending' &&
          parent.Status__c != 'Running' &&
          parent.Status__c != 'Compensating' &&
          parent.Status__c != 'Cancelling'
        ) {
          continue;
        }

        Workflow_Step_Execution__c lockedStep = lockedSteps.get(step.Id);
        if (lockedStep == null) {
          continue;
        }
        if (
          lockedStep.Status__c != 'Running' &&
          lockedStep.Status__c != 'Pending'
        ) {
          continue;
        }

        String errorMsg = (lockedStep.Status__c == 'Running')
          ? 'Step execution timed out.'
          : 'Step execution timed out before starting.';

        lockedStep.Status__c = 'Failed';
        lockedStep.Error_Details__c = errorMsg;
        lockedStep.Timeout_At__c = null;
        stepsToUpdate.add(lockedStep);

        if (!instancesToUpdate.containsKey(parent.Id)) {
          // Check if there are compensations to run
          Boolean hasCompensations = false;
          List<String> stack = new List<String>();
          if (String.isNotBlank(parent.Compensation_Stack__c)) {
            stack = (List<String>) JSON.deserialize(
              parent.Compensation_Stack__c,
              List<String>.class
            );
            hasCompensations = !stack.isEmpty();
          }

          Boolean isCompensationFailure = (parent.Status__c == 'Compensating' ||
          parent.Status__c == 'Cancelling' ||
          (String.isNotBlank(step.Step_Name__c) &&
          step.Step_Name__c.endsWith('_Compensate')));

          if (isCompensationFailure && hasCompensations) {
            // A compensation step timed out mid-rollback. The remaining stack is
            // intact, so park the saga in the recoverable "rollback incomplete"
            // state rather than abandoning the deeper compensations.
            Boolean wasCancelling = (parent.Status__c == 'Cancelling');
            parent.Status__c = 'CompensationFailed';
            parent.Error_Message__c = buildRollbackIncompleteMessage(
              wasCancelling,
              'Rollback incomplete at compensation step ' +
                step.Step_Name__c +
                ': ' +
                errorMsg
            );
            // Clear any stale sleep/retry deadline so a later resumed SUSPEND/approval
            // gate is not prematurely woken by the watchdog.
            parent.Sleep_Until__c = null;
            parent.Async_Job_Id__c = null;
            instancesToUpdate.put(parent.Id, parent);
          } else if (!hasCompensations) {
            parent.Status__c = 'Failed';
            parent.Error_Message__c =
              'Failed at step ' +
              step.Step_Name__c +
              ': ' +
              errorMsg;
            instancesToUpdate.put(parent.Id, parent);
          } else {
            parent.Status__c = 'Compensating';
            parent.Error_Message__c =
              'Failed at step ' +
              step.Step_Name__c +
              ': ' +
              errorMsg;
            instancesToUpdate.put(parent.Id, parent);

            instancesNeedingCompensationInfo.add(parent.Id);
            if (!stack.isEmpty()) {
              activeStepNamesForComp.add(stack[stack.size() - 1]);
            }
          }
        }
      }

      Map<String, Workflow_Step_Execution__c> existingCompSteps = new Map<String, Workflow_Step_Execution__c>();
      Map<String, Workflow_Step_Execution__c> originalStepsMap = new Map<String, Workflow_Step_Execution__c>();

      if (!instancesNeedingCompensationInfo.isEmpty()) {
        List<Workflow_Step_Execution__c> existing = [
          SELECT Id, Workflow_Instance__c, Step_Name__c
          FROM Workflow_Step_Execution__c
          WHERE
            Workflow_Instance__c IN :instancesNeedingCompensationInfo
            AND Step_Name__c LIKE '%\_Compensate'
          WITH SYSTEM_MODE
        ];
        for (Workflow_Step_Execution__c e : existing) {
          existingCompSteps.put(
            e.Workflow_Instance__c + ':' + e.Step_Name__c,
            e
          );
        }

        List<Workflow_Step_Execution__c> originalExecs = [
          SELECT Workflow_Instance__c, Step_Name__c, Input__c, Output__c
          FROM Workflow_Step_Execution__c
          WHERE
            Workflow_Instance__c IN :instancesNeedingCompensationInfo
            AND Step_Name__c IN :activeStepNamesForComp
          WITH SYSTEM_MODE
          ORDER BY CreatedDate DESC, Id DESC
        ];
        for (Workflow_Step_Execution__c o : originalExecs) {
          String key = o.Workflow_Instance__c + ':' + o.Step_Name__c;
          if (!originalStepsMap.containsKey(key)) {
            originalStepsMap.put(key, o);
          }
        }
      }

      for (Id instId : instancesNeedingCompensationInfo) {
        Workflow_Instance__c parent = parents.get(instId);
        List<String> stack = (List<String>) JSON.deserialize(
          parent.Compensation_Stack__c,
          List<String>.class
        );
        String activeStepName = stack[stack.size() - 1];
        String compensationStepLogName = activeStepName + '_Compensate';

        if (
          existingCompSteps.containsKey(
            parent.Id + ':' + compensationStepLogName
          )
        ) {
          continue;
        }

        Workflow_Step_Execution__c orig = originalStepsMap.get(
          parent.Id + ':' + activeStepName
        );

        Workflow_Step_Execution__c compStepExec = new Workflow_Step_Execution__c();
        compStepExec.Workflow_Instance__c = parent.Id;
        compStepExec.Step_Name__c = compensationStepLogName;
        compStepExec.Status__c = 'Pending';
        compStepExec.Input__c = (orig != null) ? orig.Input__c : null;
        compStepExec.Output__c = (orig != null) ? orig.Output__c : null;
        compStepExec.Retry_Count__c = 0;
        compensationStepsToInsert.add(compStepExec);
        orchestratorInstanceIds.add(parent.Id);
      }

      if (!stepsToUpdate.isEmpty()) {
        update as system stepsToUpdate;
      }
      if (!compensationStepsToInsert.isEmpty()) {
        insert as system compensationStepsToInsert;
      }
      if (!instancesToUpdate.isEmpty()) {
        update as system instancesToUpdate.values();
      }

      for (Workflow_Instance__c parent : instancesToUpdate.values()) {
        WorkflowAlertManager.sendAlert(parent, parent.Error_Message__c);
      }

      if (!orchestratorInstanceIds.isEmpty()) {
        if (Test.isRunningTest() && disableQueueableInTest) {
          // Do nothing
        } else {
          enqueueOrchestrators(orchestratorInstanceIds);
        }
      }

      // Defer lifecycle publishing to the end of the heartbeat. Only the parents
      // transitioned to a terminal state (Failed) emit — Compensating parents are
      // skipped by the publisher.
      watchdogTerminalInstances.addAll(instancesToUpdate.values());
    }

    // 2. Process Sleep Resumptions (bounded per heartbeat; backlog drains on subsequent
    // heartbeats so an unbounded suspended-instance backlog cannot blow row/heap limits).
    List<Workflow_Instance__c> readyToResume = [
      SELECT Id, Status__c, Sleep_Until__c, Async_Job_Id__c, Error_Message__c
      FROM Workflow_Instance__c
      WHERE Status__c = 'Suspended' AND Sleep_Until__c <= :now
      WITH SYSTEM_MODE
      LIMIT :WATCHDOG_RESUME_BATCH_SIZE
      FOR UPDATE
    ];

    if (!readyToResume.isEmpty()) {
      Set<Id> resumeIds = new Set<Id>();
      for (Workflow_Instance__c inst : readyToResume) {
        resumeIds.add(inst.Id);
      }

      List<Workflow_Step_Execution__c> latestSteps = [
        SELECT Workflow_Instance__c, Step_Name__c
        FROM Workflow_Step_Execution__c
        WHERE Workflow_Instance__c IN :resumeIds
        WITH SYSTEM_MODE
        ORDER BY CreatedDate DESC, Id DESC
      ];

      Map<Id, Workflow_Step_Execution__c> latestStepByInstId = new Map<Id, Workflow_Step_Execution__c>();
      for (Workflow_Step_Execution__c step : latestSteps) {
        if (!latestStepByInstId.containsKey(step.Workflow_Instance__c)) {
          latestStepByInstId.put(step.Workflow_Instance__c, step);
        }
      }

      List<Id> instanceIds = new List<Id>();
      for (Workflow_Instance__c inst : readyToResume) {
        Workflow_Step_Execution__c latestStep = latestStepByInstId.get(inst.Id);
        if (
          latestStep != null &&
          latestStep.Step_Name__c != null &&
          latestStep.Step_Name__c.endsWith('_Compensate')
        ) {
          if (
            inst.Error_Message__c != null &&
            inst.Error_Message__c.contains('Cancelled by user')
          ) {
            inst.Status__c = 'Cancelling';
          } else {
            inst.Status__c = 'Compensating';
          }
        } else {
          inst.Status__c = 'Running';
        }
        inst.Sleep_Until__c = null;
        inst.Async_Job_Id__c = null;
        instanceIds.add(inst.Id);
      }
      update as system readyToResume;
      enqueueOrchestrators(instanceIds);
    }

    // 3. Process due recurring schedules (0-slot: runs inside the watchdog heartbeat,
    // so enabling N Workflow_Schedule__c records adds 0 scheduled-job slots).
    try {
      WorkflowScheduleSweeper.sweep();
    } catch (Exception scheduleEx) {
      System.debug(
        LoggingLevel.ERROR,
        'WorkflowEngine: schedule sweep failed: ' + scheduleEx.getMessage()
      );
    }

    // All required heartbeat work (timed-out-step failures, sleep resumptions,
    // and schedule sweeps) is now done, so the best-effort lifecycle publish
    // runs last with no risk of starving a required update/enqueue of its DML budget.
    WorkflowLifecyclePublisher.publish(watchdogTerminalInstances);
  }

  private static Integer getStepTimeoutSeconds(String stepName) {
    if (String.isBlank(stepName)) {
      return null;
    }
    String className = stepName.endsWith('_Compensate')
      ? stepName.substring(0, stepName.lastIndexOf('_Compensate'))
      : stepName;
    try {
      Type stepType = Type.forName(className);
      if (stepType != null) {
        Object stepObj = stepType.newInstance();
        if (stepObj instanceof TimeoutConfigurable) {
          return ((TimeoutConfigurable) stepObj).getTimeoutSeconds();
        }
      }
    } catch (Exception e) {
      System.debug(
        LoggingLevel.FINE,
        'Failed to instantiate type to read timeout duration for step: ' +
          className +
          ', error: ' +
          e.getMessage()
      );
    }
    return null;
  }

  private static String resolveContinueAsNewKey(
    String currentKey,
    String customKey
  ) {
    if (String.isNotBlank(customKey)) {
      return customKey;
    }
    if (String.isBlank(currentKey)) {
      return 'Run_' + System.currentTimeMillis();
    }

    Pattern p = Pattern.compile('^(.*)_run(\\d+)$');
    Matcher m = p.matcher(currentKey);
    if (m.matches()) {
      String base = m.group(1);
      Integer nextNum = Integer.valueOf(m.group(2)) + 1;
      return base + '_run' + nextNum;
    }
    return currentKey + '_run2';
  }

  public static void scheduleTimeoutJobsForInstances(
    List<Workflow_Instance__c> instances
  ) {
    for (Workflow_Instance__c instance : instances) {
      if (
        instance.Status__c == 'Compensating' ||
        instance.Status__c == 'Cancelling'
      ) {
        if (String.isNotBlank(instance.Compensation_Stack__c)) {
          List<String> stack = (List<String>) JSON.deserialize(
            instance.Compensation_Stack__c,
            List<String>.class
          );
          if (!stack.isEmpty()) {
            scheduleTimeoutJobIfNeeded(
              instance.Id,
              stack[stack.size() - 1] + '_Compensate'
            );
          }
        }
      } else if (String.isNotBlank(instance.Current_Step__c)) {
        if (instance.Current_Step__c.contains(',')) {
          for (String pStep : instance.Current_Step__c.split(',')) {
            scheduleTimeoutJobIfNeeded(instance.Id, pStep.trim());
          }
        } else {
          scheduleTimeoutJobIfNeeded(instance.Id, instance.Current_Step__c);
        }
      }
    }
  }

  public static void scheduleTimeoutJobForInstance(Id instanceId) {
    List<Workflow_Instance__c> instances = [
      SELECT Status__c, Current_Step__c, Compensation_Stack__c
      FROM Workflow_Instance__c
      WHERE Id = :instanceId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (instances.isEmpty()) {
      return;
    }
    Workflow_Instance__c instance = instances[0];
    scheduleTimeoutJobsForInstances(new List<Workflow_Instance__c>{ instance });
  }

  public static void scheduleTimeoutJobIfNeeded(
    Id instanceId,
    String stepName
  ) {
    if (String.isBlank(stepName) || !useDynamicScheduling) {
      return;
    }
    try {
      Integer timeoutSeconds = getStepTimeoutSeconds(stepName);
      if (timeoutSeconds != null && timeoutSeconds > 0) {
        if (
          !Test.isRunningTest() &&
          timeoutSeconds >= 60 &&
          timeoutSeconds <= 600 &&
          Math.mod(timeoutSeconds, 60) == 0
        ) {
          if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(
              new WorkflowTimeoutJob.QueueableTimeoutJob(instanceId, stepName),
              timeoutSeconds / 60
            );
            return;
          }
        }
        WorkflowTimeoutJob job = new WorkflowTimeoutJob(instanceId, stepName);
        Datetime runTime = Datetime.now()
          .addSeconds(
            Test.isRunningTest() ? timeoutSeconds + 60 : timeoutSeconds
          );
        String cronStr =
          runTime.second() +
          ' ' +
          runTime.minute() +
          ' ' +
          runTime.hour() +
          ' ' +
          runTime.day() +
          ' ' +
          runTime.month() +
          ' ? ' +
          runTime.year();
        String cleanStepName = stepName.replaceAll('[^a-zA-Z0-9]', '_');
        String jobName = 'Timeout_' + instanceId + '_' + cleanStepName;
        // The job name is deterministic, so a re-schedule (e.g. retry, or a yielded step
        // that re-enters before its prior timeout job fires) collides with the existing
        // scheduled job and System.schedule() throws. Clear any stale job with this name
        // first so the new timeout is actually registered instead of silently dropped.
        cancelTimeoutJob(instanceId, stepName);
        System.schedule(jobName, cronStr, job);
      }
    } catch (AsyncException ex) {
      System.debug(
        LoggingLevel.INFO,
        'Async timeout scheduling limit reached, relying on watchdog: ' +
        ex.getMessage()
      );
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.WARN,
        'Failed to schedule timeout job: ' + ex.getMessage()
      );
    }
  }

  private static String scheduleRetry(
    Id instanceId,
    String stepName,
    Integer delaySeconds
  ) {
    if (!useDynamicScheduling) {
      return null;
    }
    try {
      if (
        !Test.isRunningTest() &&
        delaySeconds >= 60 &&
        delaySeconds <= 600 &&
        Math.mod(delaySeconds, 60) == 0
      ) {
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
          return String.valueOf(
            System.enqueueJob(
              new WorkflowRetryJob.QueueableRetryJob(instanceId, stepName),
              delaySeconds / 60
            )
          );
        }
      }
      WorkflowRetryJob job = new WorkflowRetryJob(instanceId, stepName);
      Datetime runTime = Datetime.now()
        .addSeconds(Test.isRunningTest() ? delaySeconds + 60 : delaySeconds);
      String cronStr =
        runTime.second() +
        ' ' +
        runTime.minute() +
        ' ' +
        runTime.hour() +
        ' ' +
        runTime.day() +
        ' ' +
        runTime.month() +
        ' ? ' +
        runTime.year();
      return String.valueOf(
        System.schedule(
          'WorkflowRetry_' + instanceId + '_' + runTime.getTime(),
          cronStr,
          job
        )
      );
    } catch (AsyncException ex) {
      System.debug(
        LoggingLevel.INFO,
        'Async retry scheduling limit reached, relying on watchdog: ' +
        ex.getMessage()
      );
      return null;
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.WARN,
        'Failed to schedule retry job: ' + ex.getMessage()
      );
      return null;
    }
  }

  private static String scheduleSleepResume(
    Id instanceId,
    Integer delaySeconds
  ) {
    if (!useDynamicScheduling) {
      return null;
    }
    try {
      if (
        !Test.isRunningTest() &&
        delaySeconds >= 60 &&
        delaySeconds <= 600 &&
        Math.mod(delaySeconds, 60) == 0
      ) {
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
          return String.valueOf(
            System.enqueueJob(
              new WorkflowSleepJob.QueueableSleepJob(instanceId),
              delaySeconds / 60
            )
          );
        }
      }
      WorkflowSleepJob job = new WorkflowSleepJob(instanceId);
      Datetime runTime = Datetime.now()
        .addSeconds(Test.isRunningTest() ? delaySeconds + 60 : delaySeconds);
      String cronStr =
        runTime.second() +
        ' ' +
        runTime.minute() +
        ' ' +
        runTime.hour() +
        ' ' +
        runTime.day() +
        ' ' +
        runTime.month() +
        ' ? ' +
        runTime.year();
      return String.valueOf(
        System.schedule(
          'WorkflowSleep_' + instanceId + '_' + runTime.getTime(),
          cronStr,
          job
        )
      );
    } catch (AsyncException ex) {
      System.debug(
        LoggingLevel.INFO,
        'Async sleep scheduling limit reached, relying on watchdog: ' +
        ex.getMessage()
      );
      return null;
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.WARN,
        'Failed to schedule sleep job: ' + ex.getMessage()
      );
      return null;
    }
  }

  private static void cancelTimeoutJob(Id instanceId, String stepName) {
    String cleanStepName = stepName.replaceAll('[^a-zA-Z0-9]', '_');
    String jobName = 'Timeout_' + instanceId + '_' + cleanStepName;
    List<CronTrigger> triggers = [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name = :jobName
      WITH SYSTEM_MODE
    ];
    for (CronTrigger triggerJob : triggers) {
      try {
        System.abortJob(triggerJob.Id);
      } catch (Exception e) {
        System.debug(
          LoggingLevel.WARN,
          'Failed to cancel timeout job ' +
            triggerJob.Id +
            ': ' +
            e.getMessage()
        );
      }
    }
  }
}
