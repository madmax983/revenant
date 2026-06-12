public class StepContext {
    public Id workflowInstanceId { get; set; }
    public String workflowName { get; set; }
    public String stepName { get; set; }
    public String inputJson { get; set; }
    public String previousStepOutput { get; set; }
    public String stepStateJson { get; set; }
    public String workflowInputJson { get; set; }

    public StepContext(Id workflowInstanceId, String workflowName, String stepName, String inputJson, String previousStepOutput, String stepStateJson, String workflowInputJson) {
        this.workflowInstanceId = workflowInstanceId;
        this.workflowName = workflowName;
        this.stepName = stepName;
        this.inputJson = inputJson;
        this.previousStepOutput = previousStepOutput;
        this.stepStateJson = stepStateJson;
        this.workflowInputJson = workflowInputJson;
    }
}
