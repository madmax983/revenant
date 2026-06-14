public inherited sharing class WorkflowFlowStep implements WorkflowStep {
  public StepResult execute(StepContext ctx) {
    if (ctx == null || String.isBlank(ctx.inputJson)) {
      throw new WorkflowEngine.WorkflowException('Input is null');
    }

    Map<String, Object> inputMap;
    try {
      inputMap = (Map<String, Object>) JSON.deserializeUntyped(ctx.inputJson);
    } catch (Exception ex) {
      throw new WorkflowEngine.WorkflowException(
        'Input must be a valid JSON object: ' + ex.getMessage()
      );
    }

    if (inputMap == null) {
      throw new WorkflowEngine.WorkflowException(
        'Input must be a valid JSON object'
      );
    }

    if (!inputMap.containsKey('flowName')) {
      throw new WorkflowEngine.WorkflowException(
        'flowName is required in input'
      );
    }
    Object flowNameObj = inputMap.get('flowName');
    if (flowNameObj == null) {
      throw new WorkflowEngine.WorkflowException(
        'flowName is required in input'
      );
    }
    if (!(flowNameObj instanceof String)) {
      throw new WorkflowEngine.WorkflowException('flowName must be a String');
    }
    String flowName = (String) flowNameObj;
    if (String.isBlank(flowName)) {
      throw new WorkflowEngine.WorkflowException(
        'flowName is required in input'
      );
    }

    Map<String, Object> variables = null;
    if (
      inputMap.containsKey('variables') &&
      inputMap.get('variables') instanceof Map<String, Object>
    ) {
      variables = (Map<String, Object>) inputMap.get('variables');
    }
    if (variables == null) {
      variables = new Map<String, Object>();
    }

    try {
      // Dynamic invocation via modern Invocable.Action API
      Invocable.Action action = Invocable.Action.createCustomAction(
        'flow',
        flowName
      );
      action.setInvocations(new List<Map<String, Object>>{ variables });
      List<Invocable.Action.Result> results = action.invoke();

      if (results == null || results.isEmpty()) {
        throw new WorkflowEngine.WorkflowException(
          'No result returned from action invocation'
        );
      }

      Invocable.Action.Result result = results[0];
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
      return StepResult.complete(null, outputsMap);
    } catch (WorkflowEngine.WorkflowException ex) {
      throw ex;
    } catch (Exception ex) {
      throw new WorkflowEngine.WorkflowException(ex.getMessage());
    }
  }
}
