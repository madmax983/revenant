public inherited sharing class WorkflowSignalOrStartInvocableAction {
  public class SignalOrStartRequest {
    @InvocableVariable(label='Workflow Name' required=true)
    public String workflowName;

    @InvocableVariable(label='Correlation Key' required=true)
    public String correlationKey;

    @InvocableVariable(label='Input JSON')
    public String inputJson;

    @InvocableVariable(label='Attributes JSON')
    public String attributesJson;

    @InvocableVariable(label='Signal Name' required=true)
    public String signalName;

    @InvocableVariable(label='Payload JSON')
    public String payloadJson;

    @InvocableVariable(label='Idempotency Key')
    public String idempotencyKey;
  }

  public class SignalOrStartResult {
    @InvocableVariable(label='Workflow Instance ID')
    public Id workflowInstanceId;

    @InvocableVariable(
      label='Is New'
      description='True if a new instance was started; false if an existing instance was resolved.'
    )
    public Boolean isNew;
  }

  @InvocableMethod(
    label='Signal or Start Workflow'
    category='Revenant Workflows'
    description='Idempotently starts a workflow and/or signals it in one transaction'
  )
  public static List<SignalOrStartResult> signalOrStartWorkflow(List<SignalOrStartRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return new List<SignalOrStartResult>();
    }

    List<WorkflowEngine.SignalOrStartRequest> engineRequests = new List<WorkflowEngine.SignalOrStartRequest>();
    for (SignalOrStartRequest req : requests) {
      if (req == null) {
        engineRequests.add(null);
        continue;
      }
      Object input = null;
      if (String.isNotBlank(req.inputJson)) {
        try {
          input = JSON.deserializeUntyped(req.inputJson);
        } catch (Exception ex) {
          throw new WorkflowEngine.WorkflowException(
            'Invalid Input JSON: ' + ex.getMessage()
          );
        }
      }
      Map<String, String> attributes = null;
      if (String.isNotBlank(req.attributesJson)) {
        attributes = new Map<String, String>();
        try {
          Object deserialized = JSON.deserializeUntyped(req.attributesJson);
          if (deserialized instanceof Map<String, Object>) {
            Map<String, Object> raw = (Map<String, Object>) deserialized;
            for (String k : raw.keySet()) {
              attributes.put(k, String.valueOf(raw.get(k)));
            }
          } else {
            throw new WorkflowEngine.WorkflowException(
              'Attributes JSON must represent a key-value object.'
            );
          }
        } catch (Exception ex) {
          throw new WorkflowEngine.WorkflowException(
            'Invalid Attributes JSON: ' + ex.getMessage()
          );
        }
      }

      WorkflowEngine.StartRequest startReq = new WorkflowEngine.StartRequest(
        req.workflowName,
        req.correlationKey,
        input,
        attributes
      );
      startReq.inputJson = req.inputJson;

      WorkflowEngine.SignalOrStartRequest engineReq = new WorkflowEngine.SignalOrStartRequest(
        startReq,
        req.signalName,
        req.payloadJson,
        req.idempotencyKey
      );

      engineRequests.add(engineReq);
    }

    List<WorkflowEngine.StartResult> engineResults = WorkflowEngine.signalOrStart(
      engineRequests
    );

    List<SignalOrStartResult> results = new List<SignalOrStartResult>();
    for (WorkflowEngine.StartResult engineResult : engineResults) {
      SignalOrStartResult res = new SignalOrStartResult();
      res.workflowInstanceId = engineResult == null
        ? null
        : engineResult.instanceId;
      res.isNew = engineResult == null ? null : engineResult.isNew;
      results.add(res);
    }
    return results;
  }
}
