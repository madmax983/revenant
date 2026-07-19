/**
 * @description Invocable entry point that lets Flow and other declarative tools
 * start (or debounce) Revenant workflow instances, translating declarative
 * requests into WorkflowEngine or WorkflowDebouncer calls.
 */
public inherited sharing class WorkflowStartInvocableAction {
  /**
   * @description Invocable input describing one workflow to start: its name,
   * correlation key, optional input/attributes JSON, and optional debounce window.
   */
  public class StartRequest {
    @InvocableVariable(label='Workflow Name' required=true)
    public String workflowName;

    @InvocableVariable(label='Correlation Key' required=true)
    public String correlationKey;

    @InvocableVariable(label='Input JSON')
    public String inputJson;

    @InvocableVariable(label='Attributes JSON')
    public String attributesJson;

    @InvocableVariable(
      label='Causation ID'
      description='Optional causation or trace identifier linking this instance to the upstream instance/event.'
    )
    public String causationId;

    @InvocableVariable(label='Debounce Seconds')
    public Integer debounceSeconds;

    @InvocableVariable(label='Max Wait Seconds')
    public Integer maxWaitSeconds;
  }

  /**
   * @description Invocable output for one start request, carrying the resulting
   * workflow instance Id and whether it was newly created or deduplicated.
   */
  public class StartResult {
    @InvocableVariable(label='Workflow Instance ID')
    public Id workflowInstanceId;

    @InvocableVariable(
      label='Is New'
      description='True if a new instance was started; false if an existing instance was returned for a deduplicated (already-seen) correlation key.'
    )
    public Boolean isNew;

    @InvocableVariable(
      label='Is Valid'
      description='True when the start input satisfied the workflow\'s declared input contract (or the workflow declares none) and the start proceeded; false when validation rejected the input, in which case Validation Error explains why and no instance was started. Branch a Flow Decision on this.'
    )
    public Boolean isValid;

    @InvocableVariable(
      label='Validation Error'
      description='When Is Valid is false, a readable, field-level enumeration of every input-contract violation; null on success.'
    )
    public String validationError;
  }

  @InvocableMethod(
    label='Start Workflow'
    category='Revenant Workflows'
    description='Initiates a Revenant durable workflow instance'
  )
  /**
   * @description Bulk invocable that starts a workflow instance per request,
   * routing debounced requests to WorkflowDebouncer and the rest to the engine,
   * and returns one result per input positionally aligned to the requests.
   * @param requests The list of start requests, one per Flow invocation row.
   * @return A list of results aligned by index to the input requests.
   */
  public static List<StartResult> startWorkflow(List<StartRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return new List<StartResult>();
    }

    List<StartResult> results = new List<StartResult>();
    for (Integer i = 0; i < requests.size(); i++) {
      results.add(null);
    }

    List<WorkflowEngine.StartRequest> engineRequests = new List<WorkflowEngine.StartRequest>();
    List<Integer> engineRequestIndices = new List<Integer>();
    List<WorkflowDebouncer.DebounceRequest> debounceRequests = new List<WorkflowDebouncer.DebounceRequest>();

    for (Integer i = 0; i < requests.size(); i++) {
      StartRequest req = requests[i];
      if (req == null) {
        results[i] = nullResult();
      } else if (req.debounceSeconds != null) {
        debounceRequests.add(toDebounceRequest(req));
        results[i] = debouncedResult();
      } else {
        // Opt-in input-contract validation (INV-51): validate this row in memory
        // before it reaches the engine. An invalid row yields a branchable
        // failure result (isValid=false + a field-level validationError) and is
        // NOT routed to the engine, so no instance is started for it and its
        // valid siblings are unaffected. A non-ValidatedWorkflow workflow yields
        // no errors, preserving today's behavior exactly.
        List<WorkflowInputFieldError> inputErrors = WorkflowInputValidator.collectErrors(
          toValidationProbe(req)
        );
        if (!inputErrors.isEmpty()) {
          results[i] = invalidResult(
            WorkflowInputValidator.describeErrors(inputErrors)
          );
        } else {
          engineRequests.add(toEngineRequest(req));
          engineRequestIndices.add(i);
        }
      }
    }

    if (!debounceRequests.isEmpty()) {
      WorkflowDebouncer.startDebounced(debounceRequests);
    }

    applyEngineResults(engineRequests, engineRequestIndices, results);

    return results;
  }

  private static WorkflowDebouncer.DebounceRequest toDebounceRequest(
    StartRequest req
  ) {
    if (req.debounceSeconds < 0) {
      throw new WorkflowEngine.WorkflowException(
        'Debounce seconds must be non-negative.'
      );
    }
    // Validate the input JSON (result discarded; deferred deserialization).
    WorkflowInvocableInputParser.parseInputJson(req.inputJson);
    WorkflowDebouncer.validateAttributesJson(req.attributesJson);

    WorkflowDebouncer.DebounceRequest debounceReq = new WorkflowDebouncer.DebounceRequest(
      req.workflowName,
      req.correlationKey,
      req.inputJson
    );
    debounceReq.debounceSeconds = req.debounceSeconds;
    debounceReq.maxWaitSeconds = req.maxWaitSeconds;
    debounceReq.attributesJson = req.attributesJson;
    debounceReq.causationId = req.causationId;
    return debounceReq;
  }

  /**
   * @description Builds a lightweight, side-effect-free engine start request used
   * only to validate the input contract in memory. It carries the workflow name
   * and the raw input JSON so the validator can parse and check the payload
   * without the request ever being inserted or enqueued.
   * @param req the invocable start request to probe
   * @return an engine start request carrying only the name and raw input JSON
   */
  private static WorkflowEngine.StartRequest toValidationProbe(
    StartRequest req
  ) {
    WorkflowEngine.StartRequest probe = new WorkflowEngine.StartRequest(
      req.workflowName,
      req.correlationKey,
      null
    );
    probe.inputJson = req.inputJson;
    return probe;
  }

  private static WorkflowEngine.StartRequest toEngineRequest(StartRequest req) {
    Object input = WorkflowInvocableInputParser.parseInputJson(req.inputJson);
    Map<String, String> attributes = WorkflowInvocableInputParser.parseAttributesJson(
      req.attributesJson
    );

    WorkflowEngine.StartRequest startReq = new WorkflowEngine.StartRequest(
        req.workflowName,
        req.correlationKey,
        input
      )
      .withAttributes(attributes);
    startReq.inputJson = req.inputJson;
    startReq.causationId = req.causationId;
    return startReq;
  }

  private static void applyEngineResults(
    List<WorkflowEngine.StartRequest> engineRequests,
    List<Integer> engineRequestIndices,
    List<StartResult> results
  ) {
    if (engineRequests.isEmpty()) {
      return;
    }
    List<WorkflowEngine.StartResult> engineResults = WorkflowEngine.startOrGet(
      engineRequests
    );
    for (Integer j = 0; j < engineResults.size(); j++) {
      WorkflowEngine.StartResult engineResult = engineResults[j];
      Integer origIndex = engineRequestIndices[j];
      StartResult res = new StartResult();
      res.workflowInstanceId = engineResult == null
        ? null
        : engineResult.instanceId;
      res.isNew = engineResult == null ? null : engineResult.isNew;
      // This row passed input-contract validation before it was routed here.
      res.isValid = true;
      res.validationError = null;
      results[origIndex] = res;
    }
  }

  private static StartResult nullResult() {
    StartResult res = new StartResult();
    res.workflowInstanceId = null;
    res.isNew = null;
    res.isValid = null;
    res.validationError = null;
    return res;
  }

  private static StartResult debouncedResult() {
    StartResult res = new StartResult();
    res.workflowInstanceId = null;
    res.isNew = false;
    res.isValid = true;
    res.validationError = null;
    return res;
  }

  /**
   * @description Builds a branchable failure result for a row whose input violated
   * the workflow's declared contract: no instance Id, isValid=false, and the
   * field-level enumeration in validationError so a Flow Decision can route it.
   * @param validationError the enumerated field-level violation message
   * @return a StartResult flagged invalid, with no started instance
   */
  private static StartResult invalidResult(String validationError) {
    StartResult res = new StartResult();
    res.workflowInstanceId = null;
    res.isNew = null;
    res.isValid = false;
    res.validationError = validationError;
    return res;
  }
}
