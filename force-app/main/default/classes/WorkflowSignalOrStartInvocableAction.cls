/**
 * @description Flow/Process Builder entry point that idempotently starts a workflow
 * and delivers a signal to it in a single transaction, adapting Invocable request
 * and result wrappers to the underlying WorkflowEngine signal-or-start API.
 *
 * "Signal or Start" is a dedup verb: the fallback start input is persisted only
 * when the call creates a NEW instance, so input-contract validation (INV-51) is
 * applied only there. A row that dedup-resolves to an EXISTING instance is
 * delivered even with an invalid/minimal fallback payload (that payload is never
 * persisted), while a row that would create a new instance with invalid input is
 * rejected with a branchable isValid=false + validationError (no Flow fault). Rows
 * with valid input are batched through the bulk engine call; rows with invalid
 * input are delegated to the engine individually so its dedup makes the call.
 */
public inherited sharing class WorkflowSignalOrStartInvocableAction {
  /**
   * @description Invocable input describing the workflow to signal-or-start, its
   * correlation key, optional input/attribute payloads, and the signal to deliver.
   */
  public class SignalOrStartRequest {
    @InvocableVariable(label='Workflow Name' required=true)
    public String workflowName;

    @InvocableVariable(label='Correlation Key' required=true)
    public String correlationKey;

    @InvocableVariable(label='Input JSON')
    public String inputJson;

    @InvocableVariable(label='Attributes JSON')
    public String attributesJson;

    @InvocableVariable(label='Signal Name' required=true)
    public String signalName;

    @InvocableVariable(label='Payload JSON')
    public String payloadJson;

    @InvocableVariable(label='Idempotency Key')
    public String idempotencyKey;

    @InvocableVariable(
      label='Causation ID'
      description='Optional causation or trace identifier linking this instance to the upstream instance/event.'
    )
    public String causationId;
  }

  /**
   * @description Invocable output carrying the resolved workflow instance id, a
   * flag indicating whether a new instance was started or an existing one reused,
   * and the branchable input-contract validation result.
   */
  public class SignalOrStartResult {
    @InvocableVariable(label='Workflow Instance ID')
    public Id workflowInstanceId;

    @InvocableVariable(
      label='Is New'
      description='True if a new instance was started; false if an existing instance was resolved.'
    )
    public Boolean isNew;

    @InvocableVariable(
      label='Is Valid'
      description='True when the signal was delivered / the workflow resolved (an existing instance is always delivered, since its fallback input is never persisted); false only when a NEW instance would have been created but its input failed the workflow\'s declared contract, in which case Validation Error explains why and nothing was created. Branch a Flow Decision on this.'
    )
    public Boolean isValid;

    @InvocableVariable(
      label='Validation Error'
      description='When Is Valid is false, a readable, field-level enumeration of every input-contract violation; null on success.'
    )
    public String validationError;
  }

  @InvocableMethod(
    label='Signal or Start Workflow'
    category='Revenant Workflows'
    description='Idempotently starts a workflow and/or signals it in one transaction'
  )
  /**
   * @description Idempotently starts and signals workflows for each request in one
   * transaction. Rows with valid contract input are batched to the engine FIRST;
   * then rows with invalid input are delegated individually so a dedup hit — to a
   * pre-existing instance OR one just created by a same-key valid sibling in this
   * batch — still delivers its signal, while a genuine new-start contract failure
   * becomes a branchable isValid=false result. Per-row results stay aligned to the
   * original request order despite the internal reordering.
   * @param requests The signal-or-start requests to process.
   * @return One result per request, or an empty list when requests is null/empty.
   */
  public static List<SignalOrStartResult> signalOrStartWorkflow(
    List<SignalOrStartRequest> requests
  ) {
    if (requests == null || requests.isEmpty()) {
      return new List<SignalOrStartResult>();
    }

    List<SignalOrStartResult> results = new List<SignalOrStartResult>();
    for (Integer i = 0; i < requests.size(); i++) {
      results.add(null);
    }

    List<WorkflowEngine.SignalOrStartRequest> cleanEngineRequests = new List<WorkflowEngine.SignalOrStartRequest>();
    List<Integer> cleanEngineIndices = new List<Integer>();
    // Rows with invalid input are collected here and resolved AFTER the clean
    // batch, never during the loop — so a same-key valid sibling has already
    // created its instance and this row's signal can be delivered to it.
    List<SignalOrStartRequest> suspectRequests = new List<SignalOrStartRequest>();
    List<Integer> suspectIndices = new List<Integer>();
    List<List<WorkflowInputFieldError>> suspectErrors = new List<List<WorkflowInputFieldError>>();

    for (Integer i = 0; i < requests.size(); i++) {
      SignalOrStartRequest req = requests[i];
      if (req == null) {
        results[i] = nullResult();
        continue;
      }
      List<WorkflowInputFieldError> inputErrors = WorkflowInputValidator.collectErrors(
        toValidationProbe(req)
      );
      if (inputErrors.isEmpty()) {
        cleanEngineRequests.add(toEngineRequest(req));
        cleanEngineIndices.add(i);
      } else {
        suspectRequests.add(req);
        suspectIndices.add(i);
        suspectErrors.add(inputErrors);
      }
    }

    // Create/resolve the valid rows FIRST (one bulk call), so an invalid row
    // sharing a correlation key can dedup-resolve to the just-created sibling and
    // its signal is delivered instead of dropped.
    applyCleanResults(cleanEngineRequests, cleanEngineIndices, results);

    // Then resolve the invalid-input rows individually against the now-existing
    // instances (intra-batch siblings included), preserving each row's index.
    for (Integer s = 0; s < suspectRequests.size(); s++) {
      results[suspectIndices[s]] = resolveSuspect(
        suspectRequests[s],
        suspectErrors[s]
      );
    }

    return results;
  }

  /**
   * @description Resolves a single row whose contract input is invalid by
   * delegating to the engine so its dedup decides. A malformed/unbuildable payload
   * is rejected immediately; otherwise the engine dedup-resolves to an existing
   * instance (delivered, isValid=true) or, for a genuine new start, throws
   * WorkflowInputException which is translated to a branchable isValid=false.
   * @param req the invocable signal-or-start request with invalid contract input
   * @param inputErrors the pre-computed contract violations for the message
   * @return a branchable SignalOrStartResult (delivered existing, or invalid)
   */
  private static SignalOrStartResult resolveSuspect(
    SignalOrStartRequest req,
    List<WorkflowInputFieldError> inputErrors
  ) {
    WorkflowEngine.SignalOrStartRequest engineReq;
    try {
      engineReq = toEngineRequest(req);
    } catch (WorkflowEngine.WorkflowException buildFailure) {
      return invalidResult(WorkflowInputValidator.describeErrors(inputErrors));
    }
    try {
      return deliveredResult(WorkflowEngine.signalOrStart(engineReq));
    } catch (WorkflowInputException contractFailure) {
      return invalidResult(contractFailure.getMessage());
    }
  }

  /**
   * @description Runs the batched signal-or-start for rows with valid contract
   * input (which never trip fresh-start validation) in one bulk engine call and
   * maps each result back to its original index with isValid=true.
   * @param cleanEngineRequests the engine requests for contract-valid rows
   * @param cleanEngineIndices their original indices in the invocable results
   * @param results the result list to populate in place
   */
  private static void applyCleanResults(
    List<WorkflowEngine.SignalOrStartRequest> cleanEngineRequests,
    List<Integer> cleanEngineIndices,
    List<SignalOrStartResult> results
  ) {
    if (cleanEngineRequests.isEmpty()) {
      return;
    }
    List<WorkflowEngine.StartResult> engineResults = WorkflowEngine.signalOrStart(
      cleanEngineRequests
    );
    for (Integer j = 0; j < engineResults.size(); j++) {
      results[cleanEngineIndices[j]] = deliveredResult(engineResults[j]);
    }
  }

  /**
   * @description Builds a side-effect-free start request used only to validate the
   * embedded start input's contract in memory (name + raw input JSON).
   * @param req the invocable signal-or-start request to probe
   * @return an engine start request carrying only the name and raw input JSON
   */
  private static WorkflowEngine.StartRequest toValidationProbe(
    SignalOrStartRequest req
  ) {
    WorkflowEngine.StartRequest probe = new WorkflowEngine.StartRequest(
      req.workflowName,
      req.correlationKey,
      null
    );
    probe.inputJson = req.inputJson;
    return probe;
  }

  private static WorkflowEngine.SignalOrStartRequest toEngineRequest(
    SignalOrStartRequest req
  ) {
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

    return new WorkflowEngine.SignalOrStartRequest(
        startReq,
        req.signalName,
        req.payloadJson
      )
      .withIdempotencyKey(req.idempotencyKey);
  }

  /**
   * @description Builds a delivered result (new or dedup-resolved instance),
   * flagged isValid=true.
   * @param engineResult the engine's start result (may be null)
   * @return a SignalOrStartResult carrying the instance Id / isNew and isValid=true
   */
  private static SignalOrStartResult deliveredResult(
    WorkflowEngine.StartResult engineResult
  ) {
    SignalOrStartResult res = new SignalOrStartResult();
    res.workflowInstanceId = engineResult == null
      ? null
      : engineResult.instanceId;
    res.isNew = engineResult == null ? null : engineResult.isNew;
    res.isValid = true;
    res.validationError = null;
    return res;
  }

  /**
   * @description Builds a branchable failure result for a row whose new-instance
   * start input violated the workflow's declared contract.
   * @param validationError the enumerated field-level violation message
   * @return a SignalOrStartResult flagged invalid, with no instance
   */
  private static SignalOrStartResult invalidResult(String validationError) {
    SignalOrStartResult res = new SignalOrStartResult();
    res.workflowInstanceId = null;
    res.isNew = null;
    res.isValid = false;
    res.validationError = validationError;
    return res;
  }

  private static SignalOrStartResult nullResult() {
    SignalOrStartResult res = new SignalOrStartResult();
    res.workflowInstanceId = null;
    res.isNew = null;
    res.isValid = null;
    res.validationError = null;
    return res;
  }
}
