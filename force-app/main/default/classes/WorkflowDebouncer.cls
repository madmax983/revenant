/**
 * @description Coalesces rapid repeated start requests for the same workflow and
 * correlation key into a single deferred start: it maintains durable
 * Debounce_State__c rows with a rolling fire time (bounded by an optional max
 * wait) and a sweeper that fires the due states once, with per-state retry.
 * The global members are in docs/global-api.md (issue #140).
 */
global inherited sharing class WorkflowDebouncer {
  /**
   * @description Blocks construction. Without an explicit constructor, a
   * global class gets a default constructor that subscribers can call.
   */
  private WorkflowDebouncer() {
    // No state to set.
  }

  /**
   * @description Test seam. When true, the first read finds no row. This
   * acts as a row that another transaction committed after the read.
   */
  @TestVisible
  private static Boolean skipExistingLoadForTest = false;

  /**
   * @description A single debounce start request: the target workflow and
   * correlation key, its input/attributes payloads, and the debounce and
   * max-wait windows that govern when the coalesced start fires.
   */
  global class DebounceRequest {
    public String workflowName;
    public String correlationKey;
    public String inputJson;
    public Integer debounceSeconds;
    public Integer maxWaitSeconds;
    public String attributesJson;
    public String causationId;

    /**
     * @description Builds a minimal debounce request. Set the debounce window and
     * any optional caps/attributes with the fluent setters.
     * @param workflowName developer name of the workflow definition to start
     * @param correlationKey dedup/correlation key coalescing the debounced starts
     * @param inputJson serialized start input applied when the timer fires
     */
    global DebounceRequest(
      String workflowName,
      String correlationKey,
      String inputJson
    ) {
      this.workflowName = workflowName;
      this.correlationKey = correlationKey;
      this.inputJson = inputJson;
    }

    /**
     * @description Fluent setter for the trailing-edge quiet period.
     * @param debounceSecondsArg trailing-edge quiet period before the start fires
     * @return this request, for call chaining
     */
    global DebounceRequest withDebounce(Integer debounceSecondsArg) {
      this.debounceSeconds = debounceSecondsArg;
      return this;
    }

    /**
     * @description Fluent setter for the maximum-wait cap.
     * @param maxWaitSecondsArg ceiling on total wait before the start is forced
     * @return this request, for call chaining
     */
    global DebounceRequest withMaxWait(Integer maxWaitSecondsArg) {
      this.maxWaitSeconds = maxWaitSecondsArg;
      return this;
    }

    /**
     * @description Fluent setter for the serialized searchable attributes.
     * @param attributesJsonArg serialized searchable attributes to stamp
     * @return this request, for call chaining
     */
    public DebounceRequest withAttributesJson(String attributesJsonArg) {
      this.attributesJson = attributesJsonArg;
      return this;
    }

    /**
     * @description Fluent setter for the causation id.
     * @param causationIdArg causation id linking the start to its trigger
     * @return this request, for call chaining
     */
    public DebounceRequest withCausationId(String causationIdArg) {
      this.causationId = causationIdArg;
      return this;
    }
  }

  /**
   * @description Arms one debounced start. See the bulk overload.
   * @param request The debounce request to register.
   */
  global static void startDebounced(DebounceRequest request) {
    startDebounced(new List<DebounceRequest>{ request });
  }

  /**
   * @description Bulk-registers debounced start requests, upserting a durable
   * debounce state per key and advancing its rolling fire time (capped by max wait).
   * @param requests The debounce requests to register; null and invalid entries are skipped.
   */
  global static void startDebounced(List<DebounceRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    Datetime now = currentTime();

    Set<String> debounceKeys = new Set<String>();
    List<DebounceRequest> validRequests = WorkflowDebounceValidator.collectValidRequests(
      requests,
      debounceKeys
    );

    if (validRequests.isEmpty()) {
      return;
    }

    Map<String, Debounce_State__c> existingMap = skipExistingLoadForTest
      ? new Map<String, Debounce_State__c>()
      : loadExistingStates(debounceKeys);
    Map<String, Debounce_State__c> states = buildStatesToUpsert(
      validRequests,
      existingMap,
      now
    );

    List<Debounce_State__c> toUpdate = new List<Debounce_State__c>();
    List<Debounce_State__c> toInsert = new List<Debounce_State__c>();
    for (Debounce_State__c state : states.values()) {
      if (state.Id == null) {
        toInsert.add(state);
      } else {
        toUpdate.add(state);
      }
    }
    if (!toUpdate.isEmpty()) {
      update as system toUpdate;
    }
    Set<String> lostKeys = insertNewStates(toInsert);
    if (!lostKeys.isEmpty()) {
      reArmLostKeys(validRequests, lostKeys, now);
    }
  }

  /**
   * @description Inserts new rows. A parallel transaction can insert the same
   * key after our read. Then the insert gets DUPLICATE_VALUE. That is not an
   * error: the caller re-arms the other row.
   * @param toInsert The new rows.
   * @return The keys that another transaction inserted first.
   */
  private static Set<String> insertNewStates(List<Debounce_State__c> toInsert) {
    Set<String> lostKeys = new Set<String>();
    if (toInsert.isEmpty()) {
      return lostKeys;
    }
    List<Database.SaveResult> results = Database.insert(
      toInsert,
      false,
      AccessLevel.SYSTEM_MODE
    );
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i].isSuccess()) {
        continue;
      }
      Database.Error err = results[i].getErrors()[0];
      if (err.getStatusCode() != StatusCode.DUPLICATE_VALUE) {
        throw new WorkflowEngine.WorkflowException(
          'Could not arm the debounced start: ' + err.getMessage()
        );
      }
      lostKeys.add(toInsert[i].Debounce_Key__c);
    }
    return lostKeys;
  }

  /**
   * @description Locks the rows that another transaction inserted first and
   * applies the requests to them. Upsert also covers a row that a sweep
   * deleted in the meantime.
   * @param validRequests All valid requests of this call.
   * @param lostKeys The keys to re-arm.
   * @param now The arm time.
   */
  private static void reArmLostKeys(
    List<DebounceRequest> validRequests,
    Set<String> lostKeys,
    Datetime now
  ) {
    List<DebounceRequest> lost = new List<DebounceRequest>();
    for (DebounceRequest req : validRequests) {
      if (
        lostKeys.contains(
          generateDebounceKey(req.workflowName, req.correlationKey)
        )
      ) {
        lost.add(req);
      }
    }
    List<Debounce_State__c> states = buildStatesToUpsert(
        lost,
        loadExistingStates(lostKeys),
        now
      )
      .values();
    upsert as system states Debounce_Key__c;
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
      // Pending input is workflow input at rest. The sweeper decodes it.
      state.Input_Json__c = WorkflowPayloadCodecs.encode(
        req.inputJson,
        CodecContext.PayloadKind.WORKFLOW_INPUT
      );
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
    return ceilToSecond(proposedFireAt);
  }

  /**
   * @description Rounds up to the next whole second. A DateTime field can
   * drop milliseconds. Without this, a row can fire before its window ends.
   * @param value The time to round.
   * @return The first whole second at or after the value.
   */
  private static Datetime ceilToSecond(Datetime value) {
    Long millis = value.getTime();
    Long remainder = Math.mod(millis, 1000L);
    return remainder == 0
      ? value
      : Datetime.newInstance(millis - remainder + 1000L);
  }

  /**
   * @description Sweeps and fires due debounce states, deleting them after
   * starting. Thin delegator retained for scheduler callers; the sweep
   * machinery lives in WorkflowDebounceSweeper.
   */
  public static void sweep() {
    WorkflowDebounceSweeper.sweep(currentTime());
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
