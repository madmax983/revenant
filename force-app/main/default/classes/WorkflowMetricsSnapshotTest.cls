/**
 * @description Tests for WorkflowMetricsSnapshot (issue #127): the chunker
 * and the parser. 0 SOQL, 0 DML.
 */
@IsTest
private class WorkflowMetricsSnapshotTest {
  private static List<WorkflowMetricsSnapshot.DefinitionMetrics> rows(
    Integer n
  ) {
    List<WorkflowMetricsSnapshot.DefinitionMetrics> result = new List<WorkflowMetricsSnapshot.DefinitionMetrics>();
    for (Integer i = 0; i < n; i++) {
      WorkflowMetricsSnapshot.DefinitionMetrics row = new WorkflowMetricsSnapshot.DefinitionMetrics(
        'Wf' + String.valueOf(i).leftPad(4, '0')
      );
      row.running = i;
      result.add(row);
    }
    return result;
  }

  private static List<String> namesOf(List<String> chunks) {
    List<String> names = new List<String>();
    for (String chunk : chunks) {
      for (
        WorkflowMetricsSnapshot.DefinitionMetrics row : WorkflowMetricsSnapshot.parse(
          chunk
        )
      ) {
        names.add(row.workflowName);
      }
    }
    return names;
  }

  @IsTest
  static void emptyFleetGivesOneEmptyChunk() {
    WorkflowMetricsSnapshot.ChunkPlan plan = WorkflowMetricsSnapshot.chunk(
      new List<WorkflowMetricsSnapshot.DefinitionMetrics>(),
      1000,
      5
    );

    Assert.areEqual(1, plan.chunks.size(), 'One chunk for an empty fleet');
    Assert.areEqual('{"definitions":[]}', plan.chunks[0]);
    Assert.isFalse(plan.truncated);
    Assert.areEqual(0, plan.droppedRows);
  }

  @IsTest
  static void smallFleetGivesOneChunk() {
    WorkflowMetricsSnapshot.ChunkPlan plan = WorkflowMetricsSnapshot.chunk(
      rows(3),
      100000,
      5
    );

    Assert.areEqual(1, plan.chunks.size());
    Assert.areEqual(
      new List<String>{ 'Wf0000', 'Wf0001', 'Wf0002' },
      namesOf(plan.chunks),
      'All rows in input order'
    );
    Assert.isFalse(plan.truncated);
  }

  @IsTest
  static void largeFleetSplitsUnderBudget() {
    Integer budget = 600;
    List<WorkflowMetricsSnapshot.DefinitionMetrics> input = rows(20);

    WorkflowMetricsSnapshot.ChunkPlan plan = WorkflowMetricsSnapshot.chunk(
      input,
      budget,
      100
    );

    Assert.isTrue(plan.chunks.size() > 1, 'Snapshot splits into chunks');
    for (String chunk : plan.chunks) {
      Assert.isTrue(
        chunk.length() <= budget,
        'Chunk length ' + chunk.length() + ' is over the budget'
      );
    }
    List<String> expected = new List<String>();
    for (WorkflowMetricsSnapshot.DefinitionMetrics row : input) {
      expected.add(row.workflowName);
    }
    Assert.areEqual(expected, namesOf(plan.chunks), 'No row lost');
    Assert.isFalse(plan.truncated);
    Assert.areEqual(0, plan.droppedRows);
  }

  @IsTest
  static void chunkCapTruncates() {
    WorkflowMetricsSnapshot.ChunkPlan plan = WorkflowMetricsSnapshot.chunk(
      rows(20),
      600,
      2
    );

    Assert.areEqual(2, plan.chunks.size(), 'Chunk count stops at the cap');
    Assert.isTrue(plan.truncated);
    Assert.isTrue(plan.droppedRows > 0);
    Assert.areEqual(
      20,
      namesOf(plan.chunks).size() + plan.droppedRows,
      'Kept + dropped = input'
    );
  }

  @IsTest
  static void rowOverBudgetIsDropped() {
    WorkflowMetricsSnapshot.DefinitionMetrics big = new WorkflowMetricsSnapshot.DefinitionMetrics(
      'X'.repeat(255)
    );

    WorkflowMetricsSnapshot.ChunkPlan plan = WorkflowMetricsSnapshot.chunk(
      new List<WorkflowMetricsSnapshot.DefinitionMetrics>{ big },
      200,
      5
    );

    Assert.isTrue(plan.truncated);
    Assert.areEqual(1, plan.droppedRows);
    Assert.areEqual(1, plan.chunks.size());
    Assert.areEqual('{"definitions":[]}', plan.chunks[0]);
  }

  @IsTest
  static void parseRoundTripKeepsAllKeys() {
    WorkflowMetricsSnapshot.DefinitionMetrics row = new WorkflowMetricsSnapshot.DefinitionMetrics(
      'Acme.Order'
    );
    row.pending = 1;
    row.running = 2;
    row.suspended = 3;
    row.paused = 4;
    row.definitionChanged = 5;
    row.cancelling = 6;
    row.compensating = 7;
    row.compensationFailed = 8;
    row.completedInWindow = 9;
    row.failedInWindow = 10;
    row.compensatedInWindow = 11;
    row.cancelledInWindow = 12;
    row.oldestActiveAgeSeconds = 3600;

    String chunk = WorkflowMetricsSnapshot.chunk(
        new List<WorkflowMetricsSnapshot.DefinitionMetrics>{ row },
        100000,
        1
      )
      .chunks[0];
    WorkflowMetricsSnapshot.DefinitionMetrics back = WorkflowMetricsSnapshot.parse(
      chunk
    )[0];

    Assert.areEqual('Acme.Order', back.workflowName);
    Assert.areEqual(1, back.pending);
    Assert.areEqual(2, back.running);
    Assert.areEqual(3, back.suspended);
    Assert.areEqual(4, back.paused);
    Assert.areEqual(5, back.definitionChanged);
    Assert.areEqual(6, back.cancelling);
    Assert.areEqual(7, back.compensating);
    Assert.areEqual(8, back.compensationFailed);
    Assert.areEqual(9, back.completedInWindow);
    Assert.areEqual(10, back.failedInWindow);
    Assert.areEqual(11, back.compensatedInWindow);
    Assert.areEqual(12, back.cancelledInWindow);
    Assert.areEqual(3600L, back.oldestActiveAgeSeconds);
    // The JSON keys are the public contract (schema version 1).
    Map<String, Object> raw = (Map<String, Object>) ((List<Object>) ((Map<String, Object>) JSON.deserializeUntyped(
        chunk
      ))
      .get('definitions'))[0];
    Assert.areEqual(
      new Set<String>{
        'workflowName',
        'pending',
        'running',
        'suspended',
        'paused',
        'definitionChanged',
        'cancelling',
        'compensating',
        'compensationFailed',
        'completedInWindow',
        'failedInWindow',
        'compensatedInWindow',
        'cancelledInWindow',
        'oldestActiveAgeSeconds'
      },
      raw.keySet(),
      'A rename breaks subscribers'
    );
  }

  @IsTest
  static void nullAgeStaysNull() {
    String chunk = WorkflowMetricsSnapshot.chunk(
        new List<WorkflowMetricsSnapshot.DefinitionMetrics>{
          new WorkflowMetricsSnapshot.DefinitionMetrics('Acme.Idle')
        },
        100000,
        1
      )
      .chunks[0];

    Assert.isTrue(
      chunk.contains('"oldestActiveAgeSeconds":null'),
      'A null age is explicit in the JSON'
    );
    Assert.isNull(
      WorkflowMetricsSnapshot.parse(chunk)[0].oldestActiveAgeSeconds
    );
  }

  @IsTest
  static void parseIgnoresUnknownKeys() {
    List<WorkflowMetricsSnapshot.DefinitionMetrics> parsed = WorkflowMetricsSnapshot.parse(
      '{"definitions":[{"workflowName":"A","running":2,"futureKey":1}],"futureRoot":true}'
    );

    Assert.areEqual(1, parsed.size());
    Assert.areEqual(2, parsed[0].running, 'Later versions can add keys');
    Assert.areEqual(0, parsed[0].pending, 'A missing count is 0');
  }

  @IsTest
  static void parseBlankGivesEmptyList() {
    Assert.areEqual(0, WorkflowMetricsSnapshot.parse((String) null).size());
    Assert.areEqual(0, WorkflowMetricsSnapshot.parse('').size());
    Assert.areEqual(
      0,
      WorkflowMetricsSnapshot.parse((Workflow_Metrics__e) null).size()
    );
  }

  @IsTest
  static void parseReadsEvent() {
    Workflow_Metrics__e event = new Workflow_Metrics__e(
      Metrics_Json__c = '{"definitions":[{"workflowName":"A","failedInWindow":4}]}'
    );

    List<WorkflowMetricsSnapshot.DefinitionMetrics> parsed = WorkflowMetricsSnapshot.parse(
      event
    );

    Assert.areEqual('A', parsed[0].workflowName);
    Assert.areEqual(4, parsed[0].failedInWindow);
  }
}
