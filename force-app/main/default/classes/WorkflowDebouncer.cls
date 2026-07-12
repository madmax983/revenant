/**
 * @description Coalesces rapid repeated start requests for the same workflow and
 * correlation key into a single deferred start: it maintains durable
 * Debounce_State__c rows with a rolling fire time (bounded by an optional max
 * wait) and a sweeper that fires the due states once, with per-state retry.
 */
public inherited sharing class WorkflowDebouncer {
  /**
   * @description A single debounce start request: the target workflow and
   * correlation key, its input/attributes payloads, and the debounce and
   * max-wait windows that govern when the coalesced start fires.
   */
  public class DebounceRequest {
    public String workflowName;
    public String correlationKey;
    public String inputJson;
    public Integer debounceSeconds;
    public Integer maxWaitSeconds;
    public String attributesJson;
    public String causationId;
  }

  private class SweepContext {
    List<Debounce_State__c> dueStates;
    List<WorkflowEngine.StartRequest> startRequests;
    Datetime now;
    List<Debounce_State__c> toDelete = new List<Debounce_State__c>();
    List<Debounce_State__c> toUpdate = new List<Debounce_State__c>();
  }

  /**
   * @description Bulk-registers debounced start requests, upserting a durable
   * debounce state per key and advancing its rolling fire time (capped by max wait).
   * @param requests The debounce requests to register; null and invalid entries are skipped.
   */
  public static void startDebounced(List<DebounceRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    Datetime now = currentTime();

    Set<String> debounceKeys = new Set<String>();
    List<DebounceRequest> validRequests = collectValidRequests(
      requests,
      debounceKeys
    );

    if (validRequests.isEmpty()) {
      return;
    }

    Map<String, Debounce_State__c> existingMap = loadExistingStates(
      debounceKeys
    );
    Map<String, Debounce_State__c> statesToUpsert = buildStatesToUpsert(
      validRequests,
      existingMap,
      now
    );

    if (!statesToUpsert.isEmpty()) {
      upsert as system statesToUpsert.values() Debounce_Key__c;
    }
  }

  private static List<DebounceRequest> collectValidRequests(
    List<DebounceRequest> requests,
    Set<String> debounceKeys
  ) {
    List<DebounceRequest> validRequests = new List<DebounceRequest>();
    for (DebounceRequest req : requests) {
      if (req == null) {
        continue;
      }
      validateRequestIdentity(req);
      validateRequestTiming(req);
      validateRequestPayloadSize(req);
      validateAttributesJson(req.attributesJson);

      debounceKeys.add(
        generateDebounceKey(req.workflowName, req.correlationKey)
      );
      validRequests.add(req);
    }
    return validRequests;
  }

  private static void validateRequestIdentity(DebounceRequest req) {
    if (String.isBlank(req.workflowName)) {
      throw new WorkflowEngine.WorkflowException('Workflow name is required.');
    }
    if (String.isBlank(req.correlationKey)) {
      throw new WorkflowEngine.WorkflowException(
        'Correlation key is required.'
      );
    }
    if (req.correlationKey.length() > 200) {
      throw new WorkflowEngine.WorkflowException(
        'Correlation key length cannot exceed 200 characters.'
      );
    }
  }

  private static void validateRequestTiming(DebounceRequest req) {
    if (req.debounceSeconds == null || req.debounceSeconds < 0) {
      throw new WorkflowEngine.WorkflowException(
        'Debounce seconds must be non-negative.'
      );
    }
    if (req.maxWaitSeconds != null && req.maxWaitSeconds < 0) {
      throw new WorkflowEngine.WorkflowException(
        'Max wait seconds must be non-negative.'
      );
    }
  }

  private static void validateRequestPayloadSize(DebounceRequest req) {
    if (String.isNotBlank(req.inputJson) && req.inputJson.length() > 131072) {
      throw new WorkflowEngine.WorkflowException(
        'Input JSON payload exceeds maximum size limit of 131,072 characters.'
      );
    }
  }

  private static Map<String, Debounce_State__c> loadExistingStates(
    Set<String> debounceKeys
  ) {
    Map<String, Debounce_State__c> existingMap = new Map<String, Debounce_State__c>();
    for (Debounce_State__c state : [
      SELECT
        Id,
        Debounce_Key__c,
        First_Triggered_At__c,
        Fire_At__c,
        Retry_Count__c,
        Error_Message__c
      FROM Debounce_State__c
      WHERE Debounce_Key__c IN :debounceKeys
      WITH SYSTEM_MODE
      FOR UPDATE
    ]) {
      existingMap.put(state.Debounce_Key__c.toLowerCase(), state);
    }
    return existingMap;
  }

  private static Map<String, Debounce_State__c> buildStatesToUpsert(
    List<DebounceRequest> validRequests,
    Map<String, Debounce_State__c> existingMap,
    Datetime now
  ) {
    Map<String, Debounce_State__c> statesToUpsert = new Map<String, Debounce_State__c>();
    for (DebounceRequest req : validRequests) {
      String key = generateDebounceKey(req.workflowName, req.correlationKey);

      Debounce_State__c state = statesToUpsert.get(key);
      if (state == null) {
        state = resolveBaseState(existingMap.get(key), req, now);
      }

      state.Fire_At__c = computeFireAt(state, req, now);
      state.Input_Json__c = req.inputJson;
      state.Attributes_Json__c = req.attributesJson;
      state.Causation_Id__c = req.causationId;

      statesToUpsert.put(key, state);
    }
    return statesToUpsert;
  }

  private static Debounce_State__c resolveBaseState(
    Debounce_State__c dbState,
    DebounceRequest req,
    Datetime now
  ) {
    if (dbState == null) {
      return new Debounce_State__c(
        Debounce_Key__c = generateDebounceKey(
          req.workflowName,
          req.correlationKey
        ),
        Workflow_Name__c = req.workflowName,
        Correlation_Key__c = req.correlationKey,
        First_Triggered_At__c = now
      );
    }
    if (dbState.Retry_Count__c != null && dbState.Retry_Count__c > 0) {
      dbState.First_Triggered_At__c = now;
      dbState.Retry_Count__c = 0;
      dbState.Error_Message__c = null;
    }
    return dbState;
  }

  private static Datetime computeFireAt(
    Debounce_State__c state,
    DebounceRequest req,
    Datetime now
  ) {
    Datetime proposedFireAt = now.addSeconds(req.debounceSeconds);
    if (req.maxWaitSeconds != null && req.maxWaitSeconds > 0) {
      Datetime maxFireAt = state.First_Triggered_At__c.addSeconds(
        req.maxWaitSeconds
      );
      if (proposedFireAt > maxFireAt) {
        proposedFireAt = maxFireAt;
      }
    }
    return proposedFireAt;
  }

  /**
   * Sweeps and fires due debounce states, deleting them after starting.
   */
  public static void sweep() {
    Datetime now = currentTime();

    List<Debounce_State__c> dueStates = loadDueStates(now);
    if (dueStates.isEmpty()) {
      return;
    }

    SweepContext ctx = new SweepContext();
    ctx.dueStates = dueStates;
    ctx.startRequests = buildStartRequests(dueStates);
    ctx.now = now;

    fireDueStates(ctx);
  }

  private static List<Debounce_State__c> loadDueStates(Datetime now) {
    return [
      SELECT
        Id,
        Workflow_Name__c,
        Correlation_Key__c,
        Input_Json__c,
        Attributes_Json__c,
        Causation_Id__c,
        Fire_At__c,
        Retry_Count__c,
        Error_Message__c
      FROM Debounce_State__c
      WHERE Fire_At__c <= :now AND (Retry_Count__c = NULL OR Retry_Count__c < 3)
      WITH SYSTEM_MODE
      ORDER BY Fire_At__c ASC, Id ASC
      LIMIT 100
    ];
  }

  private static List<WorkflowEngine.StartRequest> buildStartRequests(
    List<Debounce_State__c> dueStates
  ) {
    List<WorkflowEngine.StartRequest> startRequests = new List<WorkflowEngine.StartRequest>();
    for (Debounce_State__c state : dueStates) {
      Map<String, String> attributes = WorkflowInvocableInputParser.parseAttributesJsonLenient(
        state.Attributes_Json__c
      );

      // Pass null to input since we set inputJson directly, saving CPU deserialization cycles.
      WorkflowEngine.StartRequest req = new WorkflowEngine.StartRequest(
        state.Workflow_Name__c,
        state.Correlation_Key__c,
        null,
        attributes
      );
      req.inputJson = state.Input_Json__c;
      req.causationId = state.Causation_Id__c;
      startRequests.add(req);
    }
    return startRequests;
  }

  private static void fireDueStates(SweepContext ctx) {
    Savepoint sp = Database.setSavepoint();
    try {
      WorkflowEngine.startOrGet(ctx.startRequests);
      ctx.toDelete.addAll(ctx.dueStates);
    } catch (Exception ex) {
      Database.rollback(sp);
      // Fallback: start them individually
      fireIndividually(ctx);
    } finally {
      if (!ctx.toDelete.isEmpty()) {
        delete as system ctx.toDelete;
      }
      if (!ctx.toUpdate.isEmpty()) {
        update as system ctx.toUpdate;
      }
    }
  }

  private static void fireIndividually(SweepContext ctx) {
    for (Integer i = 0; i < ctx.startRequests.size(); i++) {
      // Halt if approaching SOQL or DML limits to prevent uncatchable governor exceptions
      if (Limits.getQueries() >= 90 || Limits.getDmlStatements() >= 135) {
        break;
      }
      Debounce_State__c state = ctx.dueStates[i];
      if (startIndividual(ctx.startRequests[i], state, ctx.now)) {
        ctx.toDelete.add(state);
      } else {
        ctx.toUpdate.add(state);
      }
    }
  }

  private static Boolean startIndividual(
    WorkflowEngine.StartRequest req,
    Debounce_State__c state,
    Datetime now
  ) {
    Savepoint individualSp = Database.setSavepoint();
    try {
      WorkflowEngine.startOrGet(new List<WorkflowEngine.StartRequest>{ req });
      return true;
    } catch (Exception innerEx) {
      Database.rollback(individualSp);
      recordRetry(state, innerEx, now);
      return false;
    }
  }

  private static void recordRetry(
    Debounce_State__c state,
    Exception innerEx,
    Datetime now
  ) {
    Integer currentRetries = state.Retry_Count__c == null
      ? 0
      : (Integer) state.Retry_Count__c;
    currentRetries++;
    state.Retry_Count__c = currentRetries;

    String errMsg = innerEx.getMessage();
    if (innerEx.getStackTraceString() != null) {
      errMsg += '\n' + innerEx.getStackTraceString();
    }
    if (errMsg.length() > 32768) {
      errMsg = errMsg.substring(0, 32768);
    }
    state.Error_Message__c = errMsg;

    if (currentRetries >= 3) {
      state.Fire_At__c = now.addYears(100); // Quarantine
    } else {
      // Exponential backoff retry in 1 or 2 minutes
      state.Fire_At__c = now.addSeconds(currentRetries * 60);
    }
  }

  private static Datetime currentTime() {
    return WorkflowEngine.mockNow != null
      ? WorkflowEngine.mockNow
      : Datetime.now();
  }

  /**
   * @description Derives the stable debounce key for a workflow/correlation pair
   * by hashing the lowercased "name:key" string, so repeated triggers collapse
   * onto the same durable debounce state.
   * @param workflowName The target workflow name.
   * @param correlationKey The correlation key identifying the logical subject.
   * @return The hex-encoded MD5 digest used as the debounce key.
   */
  public static String generateDebounceKey(
    String workflowName,
    String correlationKey
  ) {
    Blob keyBlob = Blob.valueOf(
      (workflowName + ':' + correlationKey).toLowerCase()
    );
    return EncodingUtil.convertToHex(Crypto.generateDigest('MD5', keyBlob));
  }

  /**
   * @description Validates an attributes JSON payload against the engine's structural
   * and size limits. Delegates to the shared parser; retained as a public entry
   * point for existing callers.
   * @param attributesJson The attributes JSON string to validate.
   */
  public static void validateAttributesJson(String attributesJson) {
    WorkflowInvocableInputParser.validateAttributesJson(attributesJson);
  }
}
