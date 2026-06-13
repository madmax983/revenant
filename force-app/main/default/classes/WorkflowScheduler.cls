public inherited sharing class WorkflowScheduler implements Schedulable {
  private String workflowName;
  private String correlationKeyPrefix;
  private String inputJson;

  public WorkflowScheduler(
    String workflowName,
    String correlationKeyPrefix,
    String inputJson
  ) {
    this.workflowName = workflowName;
    this.correlationKeyPrefix = correlationKeyPrefix;
    this.inputJson = inputJson;
  }

  public void execute(SchedulableContext ctx) {
    String timestamp = DateTime.now().format('yyyy-MM-dd_HH-mm-ss');
    String key =
      (String.isNotBlank(this.correlationKeyPrefix)
        ? this.correlationKeyPrefix + '_'
        : '') + timestamp;

    Object input = null;
    if (String.isNotBlank(this.inputJson)) {
      input = JSON.deserializeUntyped(this.inputJson);
    }

    WorkflowEngine.start(this.workflowName, key, input);
  }
}
