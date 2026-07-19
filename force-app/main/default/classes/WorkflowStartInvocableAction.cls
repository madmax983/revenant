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
   * @description Bulk invocable that starts (or debounces) a workflow instance per
   * request and returns one result per input, positionally aligned to the requests.
   *
   * The "Start Workflow" action is a GET-OR-START verb (it dedups on the
   * correlation key), so input-contract validation (INV-51) is applied only where
   * a new instance would actually be created:
   * - Rows with valid contract input are batched through {@link
   *   WorkflowEngine#startOrGet} (one bulk call; each returns isValid=true whether
   *   it started a new instance or resolved an existing one).
   * - Rows with invalid contract input are NOT blocked up front; each is delegated
   *   to the engine individually so its dedup decides: a row that resolves to an
   *   EXISTING instance is delivered (isValid=true — its unused fallback input was
   *   never persisted), while a row that would create a NEW instance is rejected
   *   with a branchable isValid=false + validationError (no Flow fault, no insert).
   * - Debounce rows arm a future startOrGet at sweep; the dedup outcome is unknown
   *   now, so they are not pre-validated (that would block a row that will
   *   dedup-resolve). The sweep-time startOrGet validates only fresh starts.
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

    List<WorkflowEngine.StartRequest> cleanEngineRequests = new List<WorkflowEngine.StartRequest>();
    List<Integer> cleanEngineIndices = new List<Integer>();
    List<WorkflowDebouncer.DebounceRequest> debounceRequests = new List<WorkflowDebouncer.DebounceRequest>();

    for (Integer i = 0; i < requests.size(); i++) {
      StartRequest req = requests[i];
      if (req == null) {
        results[i] = nullResult();
        continue;
      }
      if (req.debounceSeconds != null) {
        // Debounce wraps a dedup verb (sweep-time startOrGet): don't pre-validate.
        debounceRequests.add(toDebounceRequest(req));
        results[i] = debouncedResult();
        continue;
      }
      List<WorkflowInputFieldError> inputErrors = WorkflowInputValidator.collectErrors(
        toValidationProbe(req)
      );
      if (inputErrors.isEmpty()) {
        cleanEngineRequests.add(toEngineRequest(req));
        cleanEngineIndices.add(i);
      } else {
        results[i] = resolveSuspectStart(req, inputErrors);
      }
    }

    if (!debounceRequests.isEmpty()) {
      WorkflowDebouncer.startDebounced(debounceRequests);
    }

    applyCleanStartResults(cleanEngineRequests, cleanEngineIndices, results);

    return results;
  }

  /**
   * @description Resolves a single row whose contract input is invalid by
   * delegating to the engine so its dedup decides, rather than blocking it up
   * front. A malformed/unbuildable payload cannot be delivered and is rejected
   * immediately; otherwise the engine dedup-resolves to an existing instance
   * (delivered, isValid=true) or, for a genuine new start, throws
   * WorkflowInputException which is translated to a branchable isValid=false.
   * @param req the invocable start request with invalid contract input
   * @param inputErrors the pre-computed contract violations for the message
   * @return a branchable StartResult (delivered existing, or invalid)
   */
  private static StartResult resolveSuspectStart(
    StartRequest req,
    List<WorkflowInputFieldError> inputErrors
  ) {
    WorkflowEngine.StartRequest engineReq;
    try {
      engineReq = toEngineRequest(req);
    } catch (WorkflowEngine.WorkflowException buildFailure) {
      // Unparseable input (malformed JSON / bad attributes) can never be
      // delivered as-is; reject up front with the enumerated violations.
      return invalidResult(WorkflowInputValidator.describeErrors(inputErrors));
    }
    try {
      return startedResult(WorkflowEngine.startOrGet(engineReq));
    } catch (WorkflowInputException contractFailure) {
      return invalidResult(contractFailure.getMessage());
    }
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

  /**
   * @description Runs the batched get-or-start for the rows with valid contract
   * input (which never trip fresh-start validation) in one bulk engine call and
   * maps each result back to its original index with isValid=true.
   * @param cleanEngineRequests the engine requests for contract-valid rows
   * @param cleanEngineIndices their original indices in the invocable results
   * @param results the result list to populate in place
   */
  private static void applyCleanStartResults(
    List<WorkflowEngine.StartRequest> cleanEngineRequests,
    List<Integer> cleanEngineIndices,
    List<StartResult> results
  ) {
    if (cleanEngineRequests.isEmpty()) {
      return;
    }
    List<WorkflowEngine.StartResult> engineResults = WorkflowEngine.startOrGet(
      cleanEngineRequests
    );
    for (Integer j = 0; j < engineResults.size(); j++) {
      results[cleanEngineIndices[j]] = startedResult(engineResults[j]);
    }
  }

  /**
   * @description Builds a successful (delivered) result from an engine start
   * result — a new or dedup-resolved instance — flagged isValid=true.
   * @param engineResult the engine's start result (may be null)
   * @return a StartResult carrying the instance Id / isNew and isValid=true
   */
  private static StartResult startedResult(
    WorkflowEngine.StartResult engineResult
  ) {
    StartResult res = new StartResult();
    res.workflowInstanceId = engineResult == null
      ? null
      : engineResult.instanceId;
    res.isNew = engineResult == null ? null : engineResult.isNew;
    res.isValid = true;
    res.validationError = null;
    return res;
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
