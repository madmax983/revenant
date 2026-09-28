/**
 * @description Stub (issue #127).
 */
public with sharing class WorkflowMetricsDatadogShaper {
  /**
   * @description Stub.
   * @param event Event.
   * @return Null.
   */
  public static String toSeriesJson(Workflow_Metrics__e event) {
    return null;
  }

  /**
   * @description Stub.
   */
  public class PushJob implements Queueable, Database.AllowsCallouts {
    private final String body;
    private final String endpoint;

    /**
     * @description Stub.
     * @param body Body.
     * @param endpoint Endpoint.
     */
    public PushJob(String body, String endpoint) {
      this.body = body;
      this.endpoint = endpoint;
    }

    /**
     * @description Stub.
     * @param ctx Context.
     */
    public void execute(QueueableContext ctx) {
      return;
    }
  }
}
