/**
 * @description Engine-health snapshot contract (issue #127). Holds the
 * public row DTO, the JSON parser and the chunker.
 */
public inherited sharing class WorkflowMetricsSnapshot {
  /** @description Version of the Metrics_Json__c contract. */
  public static final Integer SCHEMA_VERSION = 1;

  /**
   * @description Metrics of one workflow definition.
   */
  public class DefinitionMetrics {
    public String workflowName;
    public Integer pending = 0;
    public Integer running = 0;
    public Integer suspended = 0;
    public Integer paused = 0;
    public Integer definitionChanged = 0;
    public Integer cancelling = 0;
    public Integer compensating = 0;
    public Integer compensationFailed = 0;
    public Integer completedInWindow = 0;
    public Integer failedInWindow = 0;
    public Integer compensatedInWindow = 0;
    public Integer cancelledInWindow = 0;
    public Long oldestActiveAgeSeconds;

    /**
     * @description Makes a row with all counts at 0.
     * @param workflowName Value of Workflow_Name__c.
     */
    public DefinitionMetrics(String workflowName) {
      this.workflowName = workflowName;
    }
  }

  /**
   * @description Result of chunk().
   */
  public class ChunkPlan {
    public List<String> chunks = new List<String>();
    public Boolean truncated = false;
    public Integer droppedRows = 0;
  }

  /**
   * @description Stub.
   * @param rows Rows.
   * @param charBudget Budget.
   * @param maxChunks Cap.
   * @return Plan.
   */
  public static ChunkPlan chunk(
    List<DefinitionMetrics> rows,
    Integer charBudget,
    Integer maxChunks
  ) {
    return new ChunkPlan();
  }

  /**
   * @description Stub.
   * @param metricsJson JSON.
   * @return Rows.
   */
  public static List<DefinitionMetrics> parse(String metricsJson) {
    return new List<DefinitionMetrics>();
  }

  /**
   * @description Stub.
   * @param event Event.
   * @return Rows.
   */
  public static List<DefinitionMetrics> parse(Workflow_Metrics__e event) {
    return new List<DefinitionMetrics>();
  }
}
