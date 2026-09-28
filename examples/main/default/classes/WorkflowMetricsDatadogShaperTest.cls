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
      Window_Start__c = SNAPSHOT_AT.addMinutes(-10),
      Is_Truncated__c = false,
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
      Boolean tagMatches = workflowTag == null
        ? tags.isEmpty()
        : tags.contains(workflowTag);
      if (s.get('metric') == metric && tagMatches) {
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
    Assert.areEqual(1, failed.get('type'), 'Window value is a count');
    Assert.areEqual(600, failed.get('interval'), 'Interval = window seconds');
    Assert.areEqual(
      2,
      ((Map<String, Object>) ((List<Object>) failed.get('points'))[0])
        .get('value')
    );
    for (Object item : series) {
      for (
        Object tag : (List<Object>) ((Map<String, Object>) item).get('tags')
      ) {
        Assert.isFalse(
          ((String) tag).startsWith('snapshot_id:'),
          'No high-cardinality tag'
        );
      }
    }
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
  static void batchGivesOneBodyForAllChunks() {
    Workflow_Metrics__e first = snapshot();
    Workflow_Metrics__e second = snapshot();
    second.Chunk_Index__c = 2;
    second.Metrics_Json__c = '{"definitions":[{"workflowName":"Acme.Ship","running":7}]}';

    Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
      WorkflowMetricsDatadogShaper.toSeriesJson(
        new List<Workflow_Metrics__e>{ first, second }
      )
    );
    List<Object> series = (List<Object>) body.get('series');

    Assert.isNotNull(
      findSeries(series, 'revenant.workflow.running', 'workflow:Acme.Order'),
      'Series from chunk 1'
    );
    Assert.isNotNull(
      findSeries(series, 'revenant.workflow.running', 'workflow:Acme.Ship'),
      'Series from chunk 2 in the same body'
    );
  }

  @IsTest
  static void emptySnapshotSendsOnlyTheTruncationGauge() {
    Workflow_Metrics__e event = snapshot();
    event.Metrics_Json__c = '{"definitions":[]}';

    List<Object> series = (List<Object>) ((Map<String, Object>) JSON.deserializeUntyped(
        WorkflowMetricsDatadogShaper.toSeriesJson(event)
      ))
      .get('series');

    Assert.areEqual(1, series.size(), 'One point for each snapshot');
    Map<String, Object> only = (Map<String, Object>) series[0];
    Assert.areEqual('revenant.snapshot.truncated', only.get('metric'));
    Assert.areEqual(
      0,
      ((Map<String, Object>) ((List<Object>) only.get('points'))[0])
        .get('value')
    );
  }

  @IsTest
  static void truncatedSnapshotSendsOne() {
    Workflow_Metrics__e event = snapshot();
    event.Is_Truncated__c = true;

    List<Object> series = (List<Object>) ((Map<String, Object>) JSON.deserializeUntyped(
        WorkflowMetricsDatadogShaper.toSeriesJson(event)
      ))
      .get('series');

    Map<String, Object> gauge = findSeries(
      series,
      'revenant.snapshot.truncated',
      null
    );
    Assert.areEqual(
      1,
      ((Map<String, Object>) ((List<Object>) gauge.get('points'))[0])
        .get('value')
    );
  }

  @IsTest
  static void blankNameIsTaggedUnnamed() {
    Workflow_Metrics__e event = snapshot();
    event.Metrics_Json__c = '{"definitions":[{"workflowName":null,"running":1}]}';

    List<Object> series = (List<Object>) ((Map<String, Object>) JSON.deserializeUntyped(
        WorkflowMetricsDatadogShaper.toSeriesJson(event)
      ))
      .get('series');

    Assert.isNotNull(
      findSeries(series, 'revenant.workflow.running', 'workflow:unnamed')
    );
  }

  @IsTest
  static void nullInputGivesNull() {
    Assert.isNull(
      WorkflowMetricsDatadogShaper.toSeriesJson((Workflow_Metrics__e) null)
    );
    Assert.isNull(
      WorkflowMetricsDatadogShaper.toSeriesJson(
        (List<Workflow_Metrics__e>) null
      )
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
