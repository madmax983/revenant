/**
 * @description Request translation and single-row suspect delegation for the
 * "Start Workflow" invocable, factored out of {@link WorkflowStartInvocableRouter}
 * so each class stays within the repo's per-class complexity budget. Converts an
 * invocable {@link WorkflowStartInvocableAction.StartRequest} into the engine's
 * request shapes and resolves an invalid-input row against the engine's dedup.
 */
public inherited sharing class WorkflowStartInvocableRequests {
  /**
   * @description Builds a side-effect-free engine start request carrying only the
   * name and raw input JSON, used to validate the contract in memory without
   * inserting/enqueuing.
   * @param req the invocable start request to probe
   * @return an engine start request with only the name and raw input JSON
   */
  public static WorkflowEngine.StartRequest toValidationProbe(
    WorkflowStartInvocableAction.StartRequest req
  ) {
    WorkflowEngine.StartRequest probe = new WorkflowEngine.StartRequest(
      req.workflowName,
      req.correlationKey,
      null
    );
    probe.inputJson = req.inputJson;
    return probe;
  }

  /**
   * @description Builds the full engine start request, parsing the input and
   * attributes JSON (which throws WorkflowException on a malformed payload).
   * @param req the invocable start request to convert
   * @return the engine start request
   */
  public static WorkflowEngine.StartRequest toEngineRequest(
    WorkflowStartInvocableAction.StartRequest req
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
    return startReq;
  }

  /**
   * @description Builds a debounce request, preserving the invocable's
   * non-negative-seconds and JSON guardrails (a malformed payload surfaces as a
   * Flow fault here).
   * @param req the invocable start request to convert
   * @return the debounce request to arm
   */
  public static WorkflowDebouncer.DebounceRequest toDebounceRequest(
    WorkflowStartInvocableAction.StartRequest req
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
   * @description Resolves one invalid-input row by delegating to the engine so its
   * dedup decides: a malformed/unbuildable payload is rejected immediately;
   * otherwise the engine dedup-resolves to an existing instance (delivered,
   * isValid=true) or, for a genuine new start, throws WorkflowInputException which
   * is translated to a branchable isValid=false.
   * @param req the invocable start request with invalid contract input
   * @param inputErrors the pre-computed contract violations for the message
   * @return a branchable StartResult (delivered existing, or invalid)
   */
  public static WorkflowStartInvocableAction.StartResult resolveSuspectStart(
    WorkflowStartInvocableAction.StartRequest req,
    List<WorkflowInputFieldError> inputErrors
  ) {
    WorkflowEngine.StartRequest engineReq;
    try {
      engineReq = toEngineRequest(req);
    } catch (WorkflowEngine.WorkflowException buildFailure) {
      return WorkflowStartInvocableResults.invalidResult(
        WorkflowInputValidator.describeErrors(inputErrors)
      );
    }
    try {
      return WorkflowStartInvocableResults.startedResult(
        WorkflowEngine.startOrGet(engineReq)
      );
    } catch (WorkflowInputException contractFailure) {
      return WorkflowStartInvocableResults.invalidResult(
        contractFailure.getMessage()
      );
    }
  }
}
