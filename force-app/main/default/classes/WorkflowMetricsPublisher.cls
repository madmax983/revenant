/**
 * @description Stub (issue #127).
 */
public inherited sharing class WorkflowMetricsPublisher {
  public static final String LOG_TYPE = 'WorkflowMetrics';
  @TestVisible
  private static Integer chunkCharBudget = 100000;
  @TestVisible
  private static Integer maxChunks = 10;
  @TestVisible
  private static List<Workflow_Metrics__e> publishedEvents = new List<Workflow_Metrics__e>();
  @TestVisible
  private static Boolean throwTestException = false;
  @TestVisible
  private static Boolean forceDmlBudgetExhausted = false;

  /**
   * @description Stub.
   * @param snapshotAt Time.
   */
  public static void publishSnapshot(Datetime snapshotAt) {
    return;
  }
}
