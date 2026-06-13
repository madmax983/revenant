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
    List<StartResult> results = new List<StartResult>();
    for (StartRequest req : requests) {
      Object input = null;
      if (String.isNotBlank(req.inputJson)) {
        input = JSON.deserializeUntyped(req.inputJson);
      }
      Id instanceId = WorkflowEngine.start(
        req.workflowName,
        req.correlationKey,
        input
      );
      StartResult res = new StartResult();
      res.workflowInstanceId = instanceId;
      results.add(res);
    }
    return results;
  }
}
