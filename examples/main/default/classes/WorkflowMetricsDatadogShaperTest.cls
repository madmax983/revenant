/**
 * @description Tests for the reference metrics subscriber (issue #127):
 * shape one snapshot into a Datadog series body and push it.
 */
@IsTest
private class WorkflowMetricsDatadogShaperTest {
  private static final Datetime SNAPSHOT_AT = Datetime.newInstanceGmt(
    2026,
    9,
    28,
    10,
    0,
    0
  );

  private class SinkMock implements HttpCalloutMock {
    HttpRequest lastRequest;

    public HttpResponse respond(HttpRequest req) {
      lastRequest = req;
      HttpResponse res = new HttpResponse();
      res.setStatusCode(202);
      res.setBody('{"errors":[]}');
      return res;
    }
  }

  private static Workflow_Metrics__e snapshot() {
    WorkflowMetricsSnapshot.DefinitionMetrics row = new WorkflowMetricsSnapshot.DefinitionMetrics(
      'Acme.Order'
    );
    row.running = 4;
    row.failedInWindow = 2;
    row.oldestActiveAgeSeconds = 90;
    WorkflowMetricsSnapshot.DefinitionMetrics idle = new WorkflowMetricsSnapshot.DefinitionMetrics(
      'Acme.Idle'
    );
    idle.completedInWindow = 1;
    return new Workflow_Metrics__e(
      Snapshot_Id__c = 'b2a4e6c8-0000-4000-8000-000000000001',
      Snapshot_At__c = SNAPSHOT_AT,
      Chunk_Index__c = 1,
      Chunk_Count__c = 1,
      Schema_Version__c = 1,
      Metrics_Json__c = WorkflowMetricsSnapshot.chunk(
          new List<WorkflowMetricsSnapshot.DefinitionMetrics>{ row, idle },
          100000,
          1
        )
        .chunks[0]
    );
  }

  private static Map<String, Object> findSeries(
    List<Object> series,
    String metric,
    String workflowTag
  ) {
    for (Object item : series) {
      Map<String, Object> s = (Map<String, Object>) item;
      List<Object> tags = (List<Object>) s.get('tags');
      if (s.get('metric') == metric && tags.contains(workflowTag)) {
        return s;
      }
    }
    return null;
  }

  @IsTest
  static void shapesOneSeriesForEachGauge() {
    Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
      WorkflowMetricsDatadogShaper.toSeriesJson(snapshot())
    );
    List<Object> series = (List<Object>) body.get('series');

    Map<String, Object> running = findSeries(
      series,
      'revenant.workflow.running',
      'workflow:Acme.Order'
    );
    Assert.isNotNull(running, 'Running gauge present');
    Assert.areEqual(3, running.get('type'), 'Datadog gauge type');
    Map<String, Object> point = (Map<String, Object>) ((List<Object>) running.get(
      'points'
    ))[0];
    Assert.areEqual(
      SNAPSHOT_AT.getTime() / 1000,
      Long.valueOf(String.valueOf(point.get('timestamp')))
    );
    Assert.areEqual(4, point.get('value'));

    Map<String, Object> failed = findSeries(
      series,
      'revenant.workflow.failed_in_window',
      'workflow:Acme.Order'
    );
    Assert.areEqual(
      2,
      ((Map<String, Object>) ((List<Object>) failed.get('points'))[0])
        .get('value')
    );
    Assert.isNotNull(
      findSeries(
        series,
        'revenant.workflow.oldest_active_age_seconds',
        'workflow:Acme.Order'
      )
    );
    Assert.isNull(
      findSeries(
        series,
        'revenant.workflow.oldest_active_age_seconds',
        'workflow:Acme.Idle'
      ),
      'A null age sends no point'
    );
  }

  @IsTest
  static void emptySnapshotGivesNoSeries() {
    Workflow_Metrics__e event = snapshot();
    event.Metrics_Json__c = '{"definitions":[]}';

    Assert.isNull(
      WorkflowMetricsDatadogShaper.toSeriesJson(event),
      'Nothing to push'
    );
  }

  @IsTest
  static void pushJobPostsTheBody() {
    SinkMock mock = new SinkMock();
    Test.setMock(HttpCalloutMock.class, mock);
    String body = WorkflowMetricsDatadogShaper.toSeriesJson(snapshot());

    Test.startTest();
    System.enqueueJob(
      new WorkflowMetricsDatadogShaper.PushJob(
        body,
        'https://metrics.example.test/api/v2/series'
      )
    );
    Test.stopTest();

    Assert.isNotNull(mock.lastRequest, 'Push job makes one callout');
    Assert.areEqual('POST', mock.lastRequest.getMethod());
    Assert.areEqual(body, mock.lastRequest.getBody());
    Assert.areEqual(
      'application/json',
      mock.lastRequest.getHeader('Content-Type')
    );
  }
}
