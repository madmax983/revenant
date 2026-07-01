public inherited sharing class WorkflowFlowStep implements WorkflowStep {
  private static final String ACTION_TYPE_FLOW = 'flow';

  public StepResult execute(StepContext ctx) {
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
    String flowName = (String) flowNameObj;

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

    try {
      FlowExecutionProducer producer = new FlowExecutionProducer(
        flowName,
        variables
      );
      String cacheKey = 'flow_output_' + flowName.toLowerCase().trim();
      Map<String, Object> outputsMap = (Map<String, Object>) ctx.once(
        cacheKey,
        producer
      );
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

  private class FlowExecutionProducer implements CaptureProducer {
    private String flowName;
    private Map<String, Object> variables;

    public FlowExecutionProducer(
      String flowName,
      Map<String, Object> variables
    ) {
      this.flowName = flowName;
      this.variables = variables;
    }

    public Object produce() {
      // Security: Validate that the Flow exists, is active, and is an Autolaunched Flow
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

      // Dynamic invocation via modern Invocable.Action API
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
        String errorMsg = 'Flow invocation failed';
        if (result.getErrors() != null && !result.getErrors().isEmpty()) {
          errorMsg += ': ' + result.getErrors()[0].getMessage();
        }
        throw new WorkflowEngine.WorkflowException(errorMsg);
      }

      Map<String, Object> outputsMap = result.getOutputParameters();
      if (outputsMap == null) {
        outputsMap = new Map<String, Object>();
      }
      return outputsMap;
    }
  }
}
