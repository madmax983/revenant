/**
 * @description Flow- and Process-Builder-invocable entry point for delivering signals to
 * running workflow instances, adapting invocable request rows into engine signal requests.
 */
global inherited sharing class WorkflowSignalInvocableAction {
  /**
   * @description Blocks construction outside this class. Without an explicit
   * constructor, a global class gets a default constructor that subscribers
   * can call (issue #122).
   */
  private WorkflowSignalInvocableAction() {
    // No state to set.
  }

  /**
   * @description Invocable request describing a single signal to deliver to a workflow
   * instance, addressed by correlation key or instance Id.
   */
  global class SignalRequest {
    @InvocableVariable(label='Correlation Key / Instance ID' required=true)
    global String targetKey;

    @InvocableVariable(label='Signal Name' required=true)
    global String signalName;

    @InvocableVariable(label='Payload JSON')
    global String payloadJson;

    @InvocableVariable(label='Idempotency Key')
    global String idempotencyKey;
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
  global static void signalWorkflow(List<SignalRequest> requests) {
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
