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

    @InvocableVariable(
      label='Causation ID'
      description='Optional causation or trace identifier linking this instance to the upstream instance/event.'
    )
    public String causationId;
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
  public static List<SignalOrStartResult> signalOrStartWorkflow(
    List<SignalOrStartRequest> requests
  ) {
    if (requests == null || requests.isEmpty()) {
      return new List<SignalOrStartResult>();
    }

    List<WorkflowEngine.SignalOrStartRequest> engineRequests = new List<WorkflowEngine.SignalOrStartRequest>();
    for (SignalOrStartRequest req : requests) {
      engineRequests.add(toEngineRequest(req));
    }

    List<WorkflowEngine.StartResult> engineResults = WorkflowEngine.signalOrStart(
      engineRequests
    );

    return toResults(engineResults);
  }

  private static WorkflowEngine.SignalOrStartRequest toEngineRequest(
    SignalOrStartRequest req
  ) {
    if (req == null) {
      return null;
    }

    Object input = WorkflowInvocableInputParser.parseInputJson(req.inputJson);
    Map<String, String> attributes = WorkflowInvocableInputParser.parseAttributesJson(
      req.attributesJson
    );

    WorkflowEngine.StartRequest startReq = new WorkflowEngine.StartRequest(
      req.workflowName,
      req.correlationKey,
      input,
      attributes
    );
    startReq.inputJson = req.inputJson;
    startReq.causationId = req.causationId;

    return new WorkflowEngine.SignalOrStartRequest(
      startReq,
      req.signalName,
      req.payloadJson,
      req.idempotencyKey
    );
  }

  private static List<SignalOrStartResult> toResults(
    List<WorkflowEngine.StartResult> engineResults
  ) {
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
