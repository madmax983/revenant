/**
 * @description Engine-health snapshot contract (issue #127). Holds the public
 * row DTO, the parser for subscribers and the chunker. The JSON keys are the
 * field names of DefinitionMetrics. They are a stable contract: see
 * docs/workflow-metrics-event.md. 0 SOQL, 0 DML.
 */
public inherited sharing class WorkflowMetricsSnapshot {
  /** @description Version of the Metrics_Json__c contract. */
  public static final Integer SCHEMA_VERSION = 1;

  private static final String PREFIX = '{"definitions":[';
  private static final String SUFFIX = ']}';

  /**
   * @description Metrics of one workflow definition. Counts are never null.
   * The InWindow counts are for the window (Window_Start__c, Snapshot_At__c].
   */
  public class DefinitionMetrics {
    /** @description Value of Workflow_Name__c. */
    public String workflowName;
    /** @description Instances in Pending. */
    public Integer pending = 0;
    /** @description Instances in Running. */
    public Integer running = 0;
    /** @description Instances in Suspended (sleep, signal or child wait). */
    public Integer suspended = 0;
    /** @description Instances in Paused. */
    public Integer paused = 0;
    /** @description Instances in DefinitionChanged. */
    public Integer definitionChanged = 0;
    /** @description Instances in Cancelling. */
    public Integer cancelling = 0;
    /** @description Instances in Compensating. */
    public Integer compensating = 0;
    /** @description Instances in CompensationFailed. */
    public Integer compensationFailed = 0;
    /** @description Instances that became Completed in the window. */
    public Integer completedInWindow = 0;
    /** @description Instances that became Failed in the window. */
    public Integer failedInWindow = 0;
    /** @description Instances that became Compensated in the window. */
    public Integer compensatedInWindow = 0;
    /** @description Instances that became Cancelled in the window. */
    public Integer cancelledInWindow = 0;
    /**
     * @description Age in seconds of the oldest active instance. Null when
     * the definition has no active instance or a cap stopped the age scan.
     */
    public Long oldestActiveAgeSeconds;

    /**
     * @description Makes an empty row. The JSON parser uses it.
     */
    public DefinitionMetrics() {
      this(null);
    }

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
    /** @description Metrics_Json__c value of each chunk, in order. */
    public List<String> chunks = new List<String>();
    /** @description True when chunk() dropped a row. */
    public Boolean truncated = false;
    /** @description Number of dropped rows. */
    public Integer droppedRows = 0;
  }

  private class Envelope {
    public List<DefinitionMetrics> definitions;
  }

  /**
   * @description Splits the rows into JSON chunks. Each chunk has not more
   * than charBudget characters. Keeps the row order. Drops a row that is
   * larger than the budget. When the chunk count is maxChunks, drops all
   * remaining rows. Always gives one chunk or more.
   * @param rows Rows in the order to send.
   * @param charBudget Maximum characters in one chunk.
   * @param maxChunks Maximum chunks.
   * @return The chunks and the truncation data.
   */
  public static ChunkPlan chunk(
    List<DefinitionMetrics> rows,
    Integer charBudget,
    Integer maxChunks
  ) {
    ChunkPlan plan = new ChunkPlan();
    Integer overhead = PREFIX.length() + SUFFIX.length();
    List<String> current = new List<String>();
    Integer currentLength = overhead;
    List<DefinitionMetrics> safeRows = rows == null
      ? new List<DefinitionMetrics>()
      : rows;
    for (Integer i = 0; i < safeRows.size(); i++) {
      String rowJson = JSON.serialize(safeRows[i]);
      if (overhead + rowJson.length() > charBudget) {
        plan.droppedRows++;
        continue;
      }
      Integer separator = current.isEmpty() ? 0 : 1;
      if (currentLength + separator + rowJson.length() > charBudget) {
        plan.chunks.add(wrap(current));
        if (plan.chunks.size() >= maxChunks) {
          plan.droppedRows += safeRows.size() - i;
          current.clear();
          break;
        }
        current.clear();
        currentLength = overhead;
        separator = 0;
      }
      current.add(rowJson);
      currentLength += separator + rowJson.length();
    }
    if (!current.isEmpty() || plan.chunks.isEmpty()) {
      plan.chunks.add(wrap(current));
    }
    plan.truncated = plan.droppedRows > 0;
    return plan;
  }

  /**
   * @description Reads the rows of one Metrics_Json__c value. Ignores
   * unknown keys, so a later schema version can add keys. A missing count
   * becomes 0.
   * @param metricsJson Value of Metrics_Json__c.
   * @return The rows. Empty for a blank value.
   */
  public static List<DefinitionMetrics> parse(String metricsJson) {
    List<DefinitionMetrics> rows = new List<DefinitionMetrics>();
    if (String.isBlank(metricsJson)) {
      return rows;
    }
    Envelope envelope = (Envelope) JSON.deserialize(
      metricsJson,
      Envelope.class
    );
    if (envelope == null || envelope.definitions == null) {
      return rows;
    }
    for (DefinitionMetrics row : envelope.definitions) {
      if (row != null) {
        rows.add(zeroNullCounts(row));
      }
    }
    return rows;
  }

  /**
   * @description Reads the rows of one event.
   * @param event The Workflow_Metrics__e event.
   * @return The rows. Empty for a null event.
   */
  public static List<DefinitionMetrics> parse(Workflow_Metrics__e event) {
    return event == null
      ? new List<DefinitionMetrics>()
      : parse(event.Metrics_Json__c);
  }

  private static String wrap(List<String> rowJsons) {
    return PREFIX + String.join(rowJsons, ',') + SUFFIX;
  }

  private static DefinitionMetrics zeroNullCounts(DefinitionMetrics row) {
    row.pending = zeroIfNull(row.pending);
    row.running = zeroIfNull(row.running);
    row.suspended = zeroIfNull(row.suspended);
    row.paused = zeroIfNull(row.paused);
    row.definitionChanged = zeroIfNull(row.definitionChanged);
    row.cancelling = zeroIfNull(row.cancelling);
    row.compensating = zeroIfNull(row.compensating);
    row.compensationFailed = zeroIfNull(row.compensationFailed);
    row.completedInWindow = zeroIfNull(row.completedInWindow);
    row.failedInWindow = zeroIfNull(row.failedInWindow);
    row.compensatedInWindow = zeroIfNull(row.compensatedInWindow);
    row.cancelledInWindow = zeroIfNull(row.cancelledInWindow);
    return row;
  }

  private static Integer zeroIfNull(Integer value) {
    return value == null ? 0 : value;
  }
}
