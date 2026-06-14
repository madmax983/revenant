public inherited sharing class WorkflowStartInvocableAction {
  public class StartRequest {
    @InvocableVariable(label='Workflow Name' required=true)
    public String workflowName;

    @InvocableVariable(label='Correlation Key')
    public String correlationKey;

    @InvocableVariable(label='Input JSON')
    public String inputJson;
  }

  public class StartResult {
    @InvocableVariable(label='Workflow Instance ID')
    public Id workflowInstanceId;
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
      Object input = null;
      if (String.isNotBlank(req.inputJson)) {
        input = JSON.deserializeUntyped(req.inputJson);
      }
      engineRequests.add(
        new WorkflowEngine.StartRequest(
          req.workflowName,
          req.correlationKey,
          input
        )
      );
    }

    List<Id> instanceIds = WorkflowEngine.start(engineRequests);

    List<StartResult> results = new List<StartResult>();
    for (Id instanceId : instanceIds) {
      StartResult res = new StartResult();
      res.workflowInstanceId = instanceId;
      results.add(res);
    }
    return results;
  }
}
