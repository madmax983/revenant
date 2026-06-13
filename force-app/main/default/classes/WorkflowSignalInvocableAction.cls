public inherited sharing class WorkflowSignalInvocableAction {

    public class SignalRequest {
        @InvocableVariable(label='Correlation Key / Instance ID' required=true)
        public String targetKey;
        
        @InvocableVariable(label='Signal Name' required=true)
        public String signalName;
        
        @InvocableVariable(label='Payload JSON')
        public String payloadJson;
    }

    @InvocableMethod(label='Signal Workflow' category='Revenant Workflows' description='Sends a signal event to a running workflow instance')
    public static void signalWorkflow(List<SignalRequest> requests) {
        for (SignalRequest req : requests) {
            WorkflowEngine.signal(req.targetKey, req.signalName, req.payloadJson);
        }
    }
}
