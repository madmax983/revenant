/**
 * @description Schedulable that starts a fresh workflow instance on each firing,
 * deriving a unique correlation key from an optional prefix and the fire time so
 * a cron schedule launches one distinct instance per run.
 */
public inherited sharing class WorkflowScheduler implements Schedulable {
  private String workflowName;
  private String correlationKeyPrefix;
  private String inputJson;

  /**
   * @description Constructs the scheduler with the workflow to start and the
   * inputs each firing should launch it with.
   * @param workflowName The workflow definition name to start.
   * @param correlationKeyPrefix Optional prefix for the generated correlation key.
   * @param inputJson Optional JSON input to pass to the started instance.
   */
  public WorkflowScheduler(
    String workflowName,
    String correlationKeyPrefix,
    String inputJson
  ) {
    this.workflowName = workflowName;
    this.correlationKeyPrefix = correlationKeyPrefix;
    this.inputJson = inputJson;
  }

  /**
   * @description Fires on schedule: builds a time-stamped correlation key,
   * deserializes any input JSON, and starts the workflow instance.
   * @param ctx The schedulable execution context.
   */
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
