/**
 * @description Built-in WorkflowStep that invokes a named Autolaunched Flow as a
 * durable step, passing input variables through and capturing the Flow's outputs
 * effectively-once via ctx.once so retries never re-run the Flow.
 */
public inherited sharing class WorkflowFlowStep implements WorkflowStep {
  private static final String ACTION_TYPE_FLOW = 'flow';

  /**
   * @description Parses the step input, resolves the target Flow and variables,
   * and runs the Flow effectively-once, completing the step with its outputs.
   * @param ctx The durable step context carrying the input JSON.
   * @return A completed StepResult carrying the Flow's output parameters.
   */
  public StepResult execute(StepContext ctx) {
    Map<String, Object> inputMap = parseInput(ctx);
    String flowName = extractFlowName(inputMap);
    Map<String, Object> variables = extractVariables(inputMap);
    return runFlow(ctx, flowName, variables);
  }

  /**
   * Validates the step context and deserializes its inputJson into a JSON
   * object, throwing a WorkflowException for a null/blank input, malformed JSON,
   * or a non-object payload.
   *
   * @param ctx The step context carrying the input JSON.
   * @return The deserialized input as a JSON object map.
   */
  private Map<String, Object> parseInput(StepContext ctx) {
    if (ctx == null || String.isBlank(ctx.inputJson)) {
      throw new WorkflowEngine.WorkflowException('Input is null');
    }

    Map<String, Object> inputMap;
    try {
      inputMap = (Map<String, Object>) JSON.deserializeUntyped(ctx.inputJson);
    } catch (Exception ex) {
      WorkflowEngine.WorkflowException wrapper = new WorkflowEngine.WorkflowException(
        'Input must be a valid JSON object: ' + ex.getMessage()
      );
      wrapper.initCause(ex);
      throw wrapper;
    }

    if (inputMap == null) {
      throw new WorkflowEngine.WorkflowException(
        'Input must be a valid JSON object'
      );
    }
    return inputMap;
  }

  /**
   * @description Extracts and validates the required String flowName from the
   * input map.
   * @param inputMap The parsed step input.
   * @return The validated flow API name.
   */
  private String extractFlowName(Map<String, Object> inputMap) {
    Object flowNameObj = inputMap.get('flowName');
    if (
      flowNameObj == null ||
      (flowNameObj instanceof String && String.isBlank((String) flowNameObj))
    ) {
      throw new WorkflowEngine.WorkflowException(
        'flowName is required in input'
      );
    }
    if (!(flowNameObj instanceof String)) {
      throw new WorkflowEngine.WorkflowException('flowName must be a String');
    }
    return (String) flowNameObj;
  }

  /**
   * Extracts the optional variables map from the input, defaulting to an empty
   * map. Rejects a present-but-non-object variables value.
   *
   * @param inputMap The parsed step input.
   * @return The variables map to pass to the Flow; empty when unspecified.
   */
  private Map<String, Object> extractVariables(Map<String, Object> inputMap) {
    Map<String, Object> variables = null;
    if (inputMap.containsKey('variables')) {
      Object varsObj = inputMap.get('variables');
      if (varsObj != null && !(varsObj instanceof Map<String, Object>)) {
        throw new WorkflowEngine.WorkflowException(
          'variables must be a JSON object'
        );
      }
      variables = (Map<String, Object>) varsObj;
    }
    if (variables == null) {
      variables = new Map<String, Object>();
    }
    return variables;
  }

  /**
   * Runs the flow effectively-once through ctx.once, re-throwing Workflow
   * exceptions verbatim and wrapping any other failure.
   *
   * @param ctx The step context, whose once() makes the run effectively-once.
   * @param flowName The Flow API name to invoke.
   * @param variables The input variables to pass to the Flow.
   * @return A completed StepResult carrying the Flow's outputs.
   */
  private StepResult runFlow(
    StepContext ctx,
    String flowName,
    Map<String, Object> variables
  ) {
    try {
      FlowExecutionProducer producer = new FlowExecutionProducer(
        flowName,
        variables
      );
      String cacheKey = 'flow_output_' + flowName.toLowerCase().trim();
      Map<String, Object> outputsMap = (Map<String, Object>) ctx.captures()
        .once(cacheKey, producer);
      return StepResult.complete(null, outputsMap);
    } catch (WorkflowEngine.WorkflowException ex) {
      throw ex;
    } catch (Exception ex) {
      WorkflowEngine.WorkflowException wrapper = new WorkflowEngine.WorkflowException(
        ex.getMessage()
      );
      wrapper.initCause(ex);
      throw wrapper;
    }
  }

  /**
   * @description CaptureProducer that actually validates and invokes the Flow.
   * It runs at most once per logical step (inside ctx.once), so the Flow's
   * side effects and outputs are captured effectively-once across retries.
   */
  private inherited sharing class FlowExecutionProducer implements CaptureProducer {
    private String flowName;
    private Map<String, Object> variables;

    /**
     * @description Constructs the producer with the target Flow and its inputs.
     * @param flowName The Flow API name to invoke.
     * @param variables The input variables to pass to the Flow.
     */
    public FlowExecutionProducer(
      String flowName,
      Map<String, Object> variables
    ) {
      this.flowName = flowName;
      this.variables = variables;
    }

    /**
     * @description Validates and invokes the Flow, returning its output
     * parameters for capture.
     * @return The Flow's output parameters as a map.
     */
    public Object produce() {
      validateFlow();
      Invocable.Action.Result result = invokeFlow();
      return extractOutputs(result);
    }

    /**
     * Security: validate that the Flow exists, is active, and is an
     * Autolaunched Flow before invoking it.
     */
    private void validateFlow() {
      List<FlowDefinitionView> flows = [
        SELECT ApiName, ProcessType
        FROM FlowDefinitionView
        WHERE ApiName = :this.flowName AND IsActive = TRUE
        WITH USER_MODE
        LIMIT 1
      ];
      if (flows.isEmpty()) {
        throw new WorkflowEngine.WorkflowException(
          'Flow not found or not active: ' + this.flowName
        );
      }
      if (flows[0].ProcessType != 'AutoLaunchedFlow') {
        throw new WorkflowEngine.WorkflowException(
          'Unsupported flow type: ' + flows[0].ProcessType
        );
      }
    }

    /**
     * Dynamically invokes the flow via the modern Invocable.Action API,
     * throwing a WorkflowException for a missing, null, or failed result.
     *
     * @return The successful invocation result.
     */
    private Invocable.Action.Result invokeFlow() {
      Invocable.Action action = Invocable.Action.createCustomAction(
        ACTION_TYPE_FLOW,
        this.flowName
      );
      action.setInvocations(new List<Map<String, Object>>{ this.variables });
      List<Invocable.Action.Result> results = action.invoke();

      if (results == null || results.isEmpty()) {
        throw new WorkflowEngine.WorkflowException(
          'No result returned from action invocation'
        );
      }

      Invocable.Action.Result result = results[0];
      if (result == null) {
        throw new WorkflowEngine.WorkflowException(
          'Result of flow invocation is null'
        );
      }
      if (!result.isSuccess()) {
        throw new WorkflowEngine.WorkflowException(failureMessage(result));
      }
      return result;
    }

    /**
     * Builds the failure message for an unsuccessful invocation, appending the
     * first reported error when one is present.
     *
     * @param result The unsuccessful invocation result.
     * @return The composed failure message.
     */
    private String failureMessage(Invocable.Action.Result result) {
      String errorMsg = 'Flow invocation failed';
      if (result.getErrors() != null && !result.getErrors().isEmpty()) {
        errorMsg += ': ' + result.getErrors()[0].getMessage();
      }
      return errorMsg;
    }

    /**
     * @description Reads the Flow's output parameters, defaulting to an empty
     * map.
     * @param result The successful invocation result.
     * @return The Flow's output parameters, or an empty map when none.
     */
    private Map<String, Object> extractOutputs(Invocable.Action.Result result) {
      Map<String, Object> outputsMap = result.getOutputParameters();
      if (outputsMap == null) {
        outputsMap = new Map<String, Object>();
      }
      return outputsMap;
    }
  }
}
