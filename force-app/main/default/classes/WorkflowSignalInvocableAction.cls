/**
 * @description Flow- and Process-Builder-invocable entry point for delivering signals to
 * running workflow instances, adapting invocable request rows into engine signal requests.
 */
public inherited sharing class WorkflowSignalInvocableAction {
  /**
   * @description Invocable request describing a single signal to deliver to a workflow
   * instance, addressed by correlation key or instance Id.
   */
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
  /**
   * @description Converts each invocable signal request into an engine signal request and
   * dispatches the batch to the workflow engine, skipping null rows.
   * @param requests The invocable signal requests to deliver; null or empty is a no-op.
   */
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
