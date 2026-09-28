/**
 * @description Reference subscriber for Workflow_Metrics__e (issue #127).
 * Shapes snapshot chunks into a Datadog v2 series body and pushes it with a
 * Queueable callout. A platform event trigger cannot make a callout and can
 * enqueue only one Queueable, so the trigger makes one body for its batch
 * and enqueues one PushJob. See docs/workflow-metrics-event.md for the
 * trigger.
 *
 * Each gauge is one series with the tag `workflow:<name>`. A null age sends
 * no point. Adapt the metric names and the endpoint to your sink.
 */
public with sharing class WorkflowMetricsDatadogShaper {
  // Datadog v2 series type for a gauge.
  private static final Integer GAUGE = 3;
  private static final String PREFIX = 'revenant.workflow.';

  /**
   * @description Makes the Datadog v2 series body for one snapshot chunk.
   * @param event One Workflow_Metrics__e chunk.
   * @return The JSON body, or null when the chunk has no definitions.
   */
  public static String toSeriesJson(Workflow_Metrics__e event) {
    return toSeriesJson(new List<Workflow_Metrics__e>{ event });
  }

  /**
   * @description Makes one Datadog v2 series body for all chunks of a
   * trigger batch.
   * @param events The Workflow_Metrics__e chunks, for example Trigger.new.
   * @return The JSON body, or null when no chunk has definitions.
   */
  public static String toSeriesJson(List<Workflow_Metrics__e> events) {
    List<Object> series = new List<Object>();
    if (events == null) {
      return null;
    }
    for (Workflow_Metrics__e event : events) {
      addSeries(series, event);
    }
    return series.isEmpty()
      ? null
      : JSON.serialize(new Map<String, Object>{ 'series' => series });
  }

  private static void addSeries(
    List<Object> series,
    Workflow_Metrics__e event
  ) {
    List<WorkflowMetricsSnapshot.DefinitionMetrics> rows = WorkflowMetricsSnapshot.parse(
      event
    );
    if (rows.isEmpty()) {
      return;
    }
    Long timestamp = event.Snapshot_At__c.getTime() / 1000;
    for (WorkflowMetricsSnapshot.DefinitionMetrics row : rows) {
      // Do not tag the snapshot id: a new tag value on each sweep makes
      // high cardinality in the sink.
      List<String> tags = new List<String>{ 'workflow:' + row.workflowName };
      Map<String, Object> gauges = new Map<String, Object>{
        'pending' => row.pending,
        'running' => row.running,
        'suspended' => row.suspended,
        'paused' => row.paused,
        'definition_changed' => row.definitionChanged,
        'cancelling' => row.cancelling,
        'compensating' => row.compensating,
        'compensation_failed' => row.compensationFailed,
        'completed_in_window' => row.completedInWindow,
        'failed_in_window' => row.failedInWindow,
        'compensated_in_window' => row.compensatedInWindow,
        'cancelled_in_window' => row.cancelledInWindow,
        'oldest_active_age_seconds' => row.oldestActiveAgeSeconds
      };
      for (String name : gauges.keySet()) {
        Object value = gauges.get(name);
        if (value != null) {
          series.add(point(PREFIX + name, timestamp, value, tags));
        }
      }
    }
  }

  private static Map<String, Object> point(
    String metric,
    Long timestamp,
    Object value,
    List<String> tags
  ) {
    return new Map<String, Object>{
      'metric' => metric,
      'type' => GAUGE,
      'points' => new List<Object>{
        new Map<String, Object>{ 'timestamp' => timestamp, 'value' => value }
      },
      'tags' => tags
    };
  }

  /**
   * @description Posts one series body to the sink.
   */
  public class PushJob implements Queueable, Database.AllowsCallouts {
    private final String body;
    private final String endpoint;

    /**
     * @description Makes the job.
     * @param body The series body from toSeriesJson().
     * @param endpoint The sink URL, for example
     * 'callout:Datadog/api/v2/series' with a Named Credential.
     */
    public PushJob(String body, String endpoint) {
      this.body = body;
      this.endpoint = endpoint;
    }

    /**
     * @description Sends the body. Metrics are best effort: a failed push
     * is not sent again. The next snapshot comes one cadence later.
     * @param ctx The Queueable context.
     */
    public void execute(QueueableContext ctx) {
      if (String.isBlank(body)) {
        return;
      }
      HttpRequest req = new HttpRequest();
      req.setEndpoint(endpoint);
      req.setMethod('POST');
      req.setHeader('Content-Type', 'application/json');
      req.setBody(body);
      req.setTimeout(10000);
      new Http().send(req);
    }
  }
}
