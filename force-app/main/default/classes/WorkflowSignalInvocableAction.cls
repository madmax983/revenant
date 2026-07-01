public inherited sharing class WorkflowSignalInvocableAction {
  public class SignalRequest {
    @InvocableVariable(label='Correlation Key / Instance ID' required=true)
    public String targetKey;

    @InvocableVariable(label='Signal Name' required=true)
    public String signalName;

    @InvocableVariable(label='Payload JSON')
    public String payloadJson;

    @InvocableVariable(label='Idempotency Key')
    public String idempotencyKey;
  }

  @InvocableMethod(
    label='Signal Workflow'
    category='Revenant Workflows'
    description='Sends a signal event to a running workflow instance'
  )
  public static void signalWorkflow(List<SignalRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return;
    }

    List<WorkflowEngine.SignalRequest> engineRequests = new List<WorkflowEngine.SignalRequest>();
    for (SignalRequest req : requests) {
      if (req == null) {
        continue;
      }
      WorkflowEngine.SignalRequest engineReq = new WorkflowEngine.SignalRequest(
        req.targetKey,
        req.signalName,
        req.payloadJson
      );
      engineReq.idempotencyKey = req.idempotencyKey;
      engineRequests.add(engineReq);
    }
    WorkflowEngine.signal(engineRequests);
  }
}
