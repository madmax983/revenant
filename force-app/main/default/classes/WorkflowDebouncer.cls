public inherited sharing class WorkflowDebouncer {
  public class DebounceRequest {
    public String workflowName;
    public String correlationKey;
    public String inputJson;
    public Integer debounceSeconds;
    public Integer maxWaitSeconds;
    public String attributesJson;
    public String causationId;

    public DebounceRequest(
      String workflowName,
      String correlationKey,
      String inputJson,
      Integer debounceSeconds,
      Integer maxWaitSeconds
    ) {
      this(
        workflowName,
        correlationKey,
        inputJson,
        debounceSeconds,
        maxWaitSeconds,
        null,
        null
      );
    }

    public DebounceRequest(
      String workflowName,
      String correlationKey,
      String inputJson,
      Integer debounceSeconds,
      Integer maxWaitSeconds,
      String attributesJson,
      String causationId
    ) {
      this.workflowName = workflowName;
      this.correlationKey = correlationKey;
      this.inputJson = inputJson;
      this.debounceSeconds = debounceSeconds;
      this.maxWaitSeconds = maxWaitSeconds;
      this.attributesJson = attributesJson;
      this.causationId = causationId;
    }
  }

  /**
   * Public Apex entry point delegating to the bulk implementation.
   */
  public static void startDebounced(
    String workflowName,
    String correlationKey,
    String inputJson,
    Integer debounceSeconds,
    Integer maxWaitSeconds
  ) {
    startDebounced(
      workflowName,
      correlationKey,
      inputJson,
      debounceSeconds,
      maxWaitSeconds,
      null,
      null
    );
  }

  public static void startDebounced(
    String workflowName,
    String correlationKey,
    String inputJson,
    Integer debounceSeconds,
    Integer maxWaitSeconds,
    String attributesJson,
    String causationId
  ) {
    startDebounced(
      new List<DebounceRequest>{
        new DebounceRequest(
          workflowName,
          correlationKey,
          inputJson,
          debounceSeconds,
          maxWaitSeconds,
          attributesJson,
          causationId
        )
      }
    );
  }

  /**
   * Bulk start debounced requests.
   */
  public static void startDebounced(List<DebounceRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    Datetime now = WorkflowEngine.mockNow != null
      ? WorkflowEngine.mockNow
      : Datetime.now();

    Set<String> debounceKeys = new Set<String>();
    List<DebounceRequest> validRequests = new List<DebounceRequest>();

    for (DebounceRequest req : requests) {
      if (req == null) {
        continue;
      }
      if (String.isBlank(req.workflowName)) {
        throw new WorkflowEngine.WorkflowException(
          'Workflow name is required.'
        );
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
      if (String.isNotBlank(req.inputJson) && req.inputJson.length() > 131072) {
        throw new WorkflowEngine.WorkflowException(
          'Input JSON payload exceeds maximum size limit of 131,072 characters.'
        );
      }
      validateAttributesJson(req.attributesJson);

      debounceKeys.add(
        generateDebounceKey(req.workflowName, req.correlationKey)
      );
      validRequests.add(req);
    }

    if (validRequests.isEmpty()) {
      return;
    }

    List<Debounce_State__c> existingStates = [
      SELECT Id, Debounce_Key__c, First_Triggered_At__c, Fire_At__c
      FROM Debounce_State__c
      WHERE Debounce_Key__c IN :debounceKeys
      WITH SYSTEM_MODE
      FOR UPDATE
    ];

    Map<String, Debounce_State__c> existingMap = new Map<String, Debounce_State__c>();
    for (Debounce_State__c state : existingStates) {
      existingMap.put(state.Debounce_Key__c.toLowerCase(), state);
    }

    Map<String, Debounce_State__c> statesToUpsert = new Map<String, Debounce_State__c>();

    for (DebounceRequest req : validRequests) {
      String key = generateDebounceKey(req.workflowName, req.correlationKey);

      Debounce_State__c state = statesToUpsert.get(key);
      if (state == null) {
        Debounce_State__c dbState = existingMap.get(key);
        if (dbState != null) {
          state = dbState;
        } else {
          state = new Debounce_State__c(
            Debounce_Key__c = key,
            Workflow_Name__c = req.workflowName,
            Correlation_Key__c = req.correlationKey,
            First_Triggered_At__c = now
          );
        }
      }

      Datetime proposedFireAt = now.addSeconds(req.debounceSeconds);

      if (req.maxWaitSeconds != null && req.maxWaitSeconds > 0) {
        Datetime maxFireAt = state.First_Triggered_At__c.addSeconds(
          req.maxWaitSeconds
        );
        if (proposedFireAt > maxFireAt) {
          proposedFireAt = maxFireAt;
        }
      }

      state.Fire_At__c = proposedFireAt;
      state.Input_Json__c = req.inputJson;
      state.Attributes_Json__c = req.attributesJson;
      state.Causation_Id__c = req.causationId;

      statesToUpsert.put(key, state);
    }

    if (!statesToUpsert.isEmpty()) {
      upsert as system statesToUpsert.values() Debounce_Key__c;
    }
  }

  /**
   * Sweeps and fires due debounce states, deleting them after starting.
   */
  public static void sweep() {
    Datetime now = WorkflowEngine.mockNow != null
      ? WorkflowEngine.mockNow
      : Datetime.now();

    List<Debounce_State__c> dueStates = [
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

    if (dueStates.isEmpty()) {
      return;
    }

    List<WorkflowEngine.StartRequest> startRequests = new List<WorkflowEngine.StartRequest>();
    for (Debounce_State__c state : dueStates) {
      Map<String, String> attributes = null;
      if (String.isNotBlank(state.Attributes_Json__c)) {
        attributes = new Map<String, String>();
        try {
          Object deserialized = JSON.deserializeUntyped(
            state.Attributes_Json__c
          );
          if (deserialized instanceof Map<String, Object>) {
            Map<String, Object> raw = (Map<String, Object>) deserialized;
            for (String k : raw.keySet()) {
              attributes.put(k, String.valueOf(raw.get(k)));
            }
          }
        } catch (Exception ex) {
          // ignore parsing error
        }
      }

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

    List<Debounce_State__c> statesToDelete = new List<Debounce_State__c>();
    List<Debounce_State__c> statesToUpdate = new List<Debounce_State__c>();

    try {
      WorkflowEngine.startOrGet(startRequests);
      statesToDelete.addAll(dueStates);
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'WorkflowDebouncer sweep failed to bulk start: ' + ex.getMessage()
      );
      // Fallback: start them individually
      for (Integer i = 0; i < startRequests.size(); i++) {
        // Halt if approaching SOQL or DML limits to prevent uncatchable governor exceptions
        if (Limits.getQueries() >= 90 || Limits.getDmlStatements() >= 135) {
          System.debug(
            LoggingLevel.WARN,
            'WorkflowDebouncer sweep individual fallback halted to prevent Governor Limit exceptions.'
          );
          break;
        }
        WorkflowEngine.StartRequest req = startRequests[i];
        Debounce_State__c state = dueStates[i];
        try {
          WorkflowEngine.startOrGet(
            new List<WorkflowEngine.StartRequest>{ req }
          );
          statesToDelete.add(state);
        } catch (Exception innerEx) {
          System.debug(
            LoggingLevel.ERROR,
            'WorkflowDebouncer sweep failed to start individual: ' +
            innerEx.getMessage()
          );

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
          statesToUpdate.add(state);
        }
      }
    } finally {
      if (!statesToDelete.isEmpty()) {
        delete as system statesToDelete;
      }
      if (!statesToUpdate.isEmpty()) {
        update as system statesToUpdate;
      }
    }
  }

  public static String generateDebounceKey(
    String workflowName,
    String correlationKey
  ) {
    Blob keyBlob = Blob.valueOf(
      (workflowName + ':' + correlationKey).toLowerCase()
    );
    return EncodingUtil.convertToHex(Crypto.generateDigest('MD5', keyBlob));
  }

  public static void validateAttributesJson(String attributesJson) {
    if (String.isBlank(attributesJson)) {
      return;
    }
    if (attributesJson.length() > 131072) {
      throw new WorkflowEngine.WorkflowException(
        'Attributes JSON payload exceeds maximum size limit of 131,072 characters.'
      );
    }
    Object deserialized;
    try {
      deserialized = JSON.deserializeUntyped(attributesJson);
    } catch (Exception ex) {
      throw new WorkflowEngine.WorkflowException(
        'Invalid Attributes JSON: ' + ex.getMessage()
      );
    }
    if (!(deserialized instanceof Map<String, Object>)) {
      throw new WorkflowEngine.WorkflowException(
        'Attributes JSON must represent a key-value object.'
      );
    }
    Map<String, Object> raw = (Map<String, Object>) deserialized;
    if (raw.size() > WorkflowEngine.MAX_ATTRIBUTES_PER_INSTANCE) {
      throw new WorkflowEngine.WorkflowException(
        'Attribute count exceeds maximum limit of ' +
        WorkflowEngine.MAX_ATTRIBUTES_PER_INSTANCE
      );
    }
    for (String key : raw.keySet()) {
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
      String val = raw.get(key) == null ? null : String.valueOf(raw.get(key));
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
  }
}
