public inherited sharing class WorkflowStartInvocableAction {
  public class StartRequest {
    @InvocableVariable(label='Workflow Name' required=true)
    public String workflowName;

    @InvocableVariable(label='Correlation Key' required=true)
    public String correlationKey;

    @InvocableVariable(label='Input JSON')
    public String inputJson;

    @InvocableVariable(label='Attributes JSON')
    public String attributesJson;

    @InvocableVariable(
      label='Causation ID'
      description='Optional causation or trace identifier linking this instance to the upstream instance/event.'
    )
    public String causationId;
  }

  public class StartResult {
    @InvocableVariable(label='Workflow Instance ID')
    public Id workflowInstanceId;

    @InvocableVariable(
      label='Is New'
      description='True if a new instance was started; false if an existing instance was returned for a deduplicated (already-seen) correlation key.'
    )
    public Boolean isNew;
  }

  @InvocableMethod(
    label='Start Workflow'
    category='Revenant Workflows'
    description='Initiates a Revenant durable workflow instance'
  )
  public static List<StartResult> startWorkflow(List<StartRequest> requests) {
    if (requests == null || requests.isEmpty()) {
      return new List<StartResult>();
    }

    List<WorkflowEngine.StartRequest> engineRequests = new List<WorkflowEngine.StartRequest>();
    for (StartRequest req : requests) {
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
      startReq.causationId = req.causationId;
      engineRequests.add(startReq);
    }

    List<WorkflowEngine.StartResult> engineResults = WorkflowEngine.startOrGet(
      engineRequests
    );

    List<StartResult> results = new List<StartResult>();
    for (WorkflowEngine.StartResult engineResult : engineResults) {
      StartResult res = new StartResult();
      res.workflowInstanceId = engineResult == null
        ? null
        : engineResult.instanceId;
      res.isNew = engineResult == null ? null : engineResult.isNew;
      results.add(res);
    }
    return results;
  }
}
