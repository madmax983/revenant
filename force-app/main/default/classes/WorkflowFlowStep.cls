public with sharing class WorkflowFlowStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
        if (ctx == null || String.isBlank(ctx.inputJson)) {
            return StepResult.complete(null, new Map<String, Object>{'error' => 'Input is null'});
        }
        
        Map<String, Object> inputMap;
        try {
            inputMap = (Map<String, Object>)JSON.deserializeUntyped(ctx.inputJson);
        } catch (Exception ex) {
            return StepResult.complete(null, new Map<String, Object>{'error' => 'Input must be a valid JSON object'});
        }
        
        String flowName = (String)inputMap.get('flowName');
        if (String.isBlank(flowName)) {
            return StepResult.complete(null, new Map<String, Object>{'error' => 'flowName is required in input'});
        }
        
        Map<String, Object> variables = null;
        if (inputMap.containsKey('variables') && inputMap.get('variables') instanceof Map<String, Object>) {
            variables = (Map<String, Object>)inputMap.get('variables');
        }
        if (variables == null) {
            variables = new Map<String, Object>();
        }
        
        try {
            // Dynamic invocation via modern Invocable.Action API
            Invocable.Action action = Invocable.Action.createCustomAction('flow', flowName);
            action.setInvocations(new List<Map<String, Object>>{ variables });
            List<Invocable.Action.Result> results = action.invoke();
            
            if (results == null || results.isEmpty()) {
                return StepResult.complete(null, new Map<String, Object>{'error' => 'No result returned from action invocation'});
            }
            
            Invocable.Action.Result result = results[0];
            if (!result.isSuccess()) {
                String errorMsg = 'Flow invocation failed';
                if (result.getErrors() != null && !result.getErrors().isEmpty()) {
                    errorMsg += ': ' + result.getErrors()[0].getMessage();
                }
                return StepResult.complete(null, new Map<String, Object>{'error' => errorMsg});
            }
            
            Map<String, Object> outputsMap = result.getOutputParameters();
            if (outputsMap == null) {
                outputsMap = new Map<String, Object>();
            }
            return StepResult.complete(null, outputsMap);
        } catch (Exception ex) {
            return StepResult.complete(null, new Map<String, Object>{'error' => ex.getMessage()});
        }
    }
}
