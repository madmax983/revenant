/**
 * @description Stub (issue #127).
 */
public inherited sharing class WorkflowMetricsCollector {
  @TestVisible
  private static Integer groupRowCap = 2000;
  @TestVisible
  private static Integer ageScanRowCap = 10000;
  @TestVisible
  private static Boolean forceQueryBudgetExhausted = false;

  /**
   * @description Result of collect().
   */
  public class Result {
    public List<WorkflowMetricsSnapshot.DefinitionMetrics> rows = new List<WorkflowMetricsSnapshot.DefinitionMetrics>();
    public Boolean truncated = false;
    public List<String> notes = new List<String>();
  }

  /**
   * @description Stub.
   * @param windowStart Start.
   * @param snapshotAt End.
   * @return Null.
   */
  public static Result collect(Datetime windowStart, Datetime snapshotAt) {
    return null;
  }

  @TestVisible
  private static List<AggregateResult> queryActiveCounts() {
    return new List<AggregateResult>();
  }
}
