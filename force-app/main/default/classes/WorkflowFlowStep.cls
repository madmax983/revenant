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
            Flow.Interview flowInterview = Flow.Interview.createInterview(flowName, variables);
            flowInterview.start();
            
            Map<String, Object> outputsMap = new Map<String, Object>();
            List<Object> outputKeys = null;
            if (inputMap.containsKey('outputs') && inputMap.get('outputs') instanceof List<Object>) {
                outputKeys = (List<Object>)inputMap.get('outputs');
            }
            
            if (outputKeys != null) {
                for (Object keyObj : outputKeys) {
                    String key = (String)keyObj;
                    try {
                        Object val = flowInterview.getVariableValue(key);
                        outputsMap.put(key, val);
                    } catch (Exception varEx) {
                        // Variable might not exist in the flow
                        outputsMap.put(key, null);
                    }
                }
            }
            return StepResult.complete(null, outputsMap);
        } catch (Exception ex) {
            return StepResult.complete(null, new Map<String, Object>{'error' => ex.getMessage()});
        }
    }
}
