# Engine-Health Metrics Event (Issue #127)

## Goal

Send a periodic engine-health snapshot on a Platform Event. An external
pipeline (Datadog, Grafana, Splunk) can then chart the fleet. Use the
watchdog sweep. Add no scheduled job. Default: off.

## Facts About The Engine

- `WorkflowHeartbeatService.runWatchdogHeartbeat()` runs each sweep. It
  publishes lifecycle events after the required work. Then it writes the
  liveness stamp (`WatchdogLiveness.recordSweep`).
- `Watchdog_Liveness__c.Last_Sweep_At__c` holds the previous sweep time. A
  read costs 0 SOQL.
- `Terminal_At__c` is set at the first terminal transition.
- Salesforce: `COUNT(field)` with `GROUP BY` uses one query row for each
  group. `MIN()` uses one query row for each aggregated row.
- Apex cannot catch a `LimitException`. A guard must stop it before it
  occurs.
- An aggregate query can return not more than 2,000 rows.
- `EventBus.publish` uses one DML statement and one DML row for each event.

## Brainstorming (options)

| #   | Idea                                                                         | Keep?                                                          |
| --- | ---------------------------------------------------------------------------- | -------------------------------------------------------------- |
| B1  | One event for each definition, with flat fields.                             | No. Event count grows with the fleet. No chunk contract.       |
| B2  | One event with a JSON list of definitions. Chunk when the JSON is large.     | Yes. Meets the chunk AC. Few events.                           |
| B3  | `GROUP BY Workflow_Name__c, Status__c` with `COUNT(Id)` for active counts.   | Yes. One row for each group.                                   |
| B4  | Same query shape with a `Terminal_At__c` window for terminal counts.         | Yes. One row for each group.                                   |
| B5  | `MIN(CreatedDate)` for the oldest age.                                       | No. Costs one row for each active instance. No bound.          |
| B6  | Oldest age from `ORDER BY CreatedDate ASC LIMIT k`. First row for each name. | Yes. Bounded cost. Exact when active rows ≤ k.                 |
| B7  | Window start = previous `Last_Sweep_At__c`.                                  | Yes. Windows do not overlap. 0 SOQL.                           |
| B8  | Run the snapshot in a new Queueable.                                         | No. The watchdog Queueable can enqueue only one child.         |
| B9  | Add a new schedule for metrics.                                              | No. The issue forbids a new slot.                              |
| B10 | A public DTO and `parse()` for subscribers.                                  | Yes. Subscribers do not parse raw JSON keys by hand.           |
| B11 | A shaper example (Datadog series) plus a trigger snippet in the docs.        | Yes. Meets the reference subscriber AC. The shaper has a test. |

## Reverse Brainstorming (how to make it fail)

| How to fail                                                  | Counter                                                                  |
| ------------------------------------------------------------ | ------------------------------------------------------------------------ |
| An aggregate uses all 50,000 query rows. `LimitException`.   | No `MIN()`. Group caps. Age scan cap. Check free rows before each query. |
| Publish uses the last DML. The step commit fails.            | Keep 11 DML statements free. Else skip.                                  |
| Publish throws. The sweep stops. Continue-as-new breaks.     | Catch all. The heartbeat also wraps the call.                            |
| A large fleet makes one event too large.                     | Chunk by a character budget. All chunks share one snapshot id.           |
| Chunk count grows with no limit.                             | Chunk cap. Set `Is_Truncated__c`. Write a warn log.                      |
| A group cap drops rows with no signal.                       | Set `Is_Truncated__c`. Write a warn log.                                 |
| Orgs that do not subscribe pay a cost.                       | Toggle default off. Off = 0 SOQL, 0 DML.                                 |
| Subscribers bind to internal field names.                    | Stable JSON keys and a versioned contract doc. `Schema_Version__c`.      |
| Two windows count one failure two times.                     | Window is `(previous sweep, now]`.                                       |
| A rolled-back sweep sends a snapshot. The retry sends again. | `PublishAfterCommit`.                                                    |

## Six Thinking Hats

- **White (facts):** Group query rows = groups. The heartbeat already has a
  DML reserve pattern (`WatchdogLiveness.DML_RESERVE`). The watchdog runs
  each 1-10 minutes.
- **Red (feel):** SREs want one gauge stream that they can trust. A gap
  with no log breaks trust. A drop must show.
- **Black (risk):** The event schema is public for all time. Large tables
  make aggregate queries slow. Late commits near the window edge can be
  missed. The age scan can be partial on a very large fleet.
- **Yellow (value):** Fleet health in the tools that SREs already use. 0 new
  slots. Three queries for each sweep.
- **Green (ideas):** Later: add step-level counts in schema version 2. A
  Flow subscriber can use the Apex shaper through an invocable.
- **Blue (process):** Spec, RED, GREEN, REFACTOR. Then agent review. Then
  map each AC to evidence.

## Spec

Event `Workflow_Metrics__e` (HighVolume, PublishAfterCommit):

| Field               | Type                | Meaning                                  |
| ------------------- | ------------------- | ---------------------------------------- |
| `Snapshot_Id__c`    | Text(36)            | One UUID for all chunks of one snapshot. |
| `Snapshot_At__c`    | DateTime            | Snapshot time. Window end.               |
| `Window_Start__c`   | DateTime            | Window start (not included).             |
| `Chunk_Index__c`    | Number(4,0)         | 1-based chunk number.                    |
| `Chunk_Count__c`    | Number(4,0)         | Number of chunks in the snapshot.        |
| `Is_Truncated__c`   | Checkbox            | True when a cap dropped data.            |
| `Schema_Version__c` | Number(3,0)         | Contract version. Now `1`.               |
| `Metrics_Json__c`   | Long Text (131,072) | `{"definitions":[...]}`.                 |

Definition row (JSON keys): `workflowName`, `pending`, `running`,
`suspended`, `paused`, `definitionChanged`, `cancelling`, `compensating`,
`compensationFailed`, `completedInWindow`, `failedInWindow`,
`compensatedInWindow`, `cancelledInWindow`, `oldestActiveAgeSeconds`.

Invariants:

- Toggle off: 0 SOQL, 0 DML, 0 events.
- Toggle on: not more than 3 SOQL for each sweep, for all fleet sizes.
- Each chunk JSON length ≤ the character budget.
- All chunks of one snapshot have the same `Snapshot_Id__c` and
  `Chunk_Count__c`. `Chunk_Index__c` is 1..n.
- A dropped row sets `Is_Truncated__c` on all chunks and writes one warn log.
- The call never throws. It keeps 11 DML statements and 5,000 query rows free.
- An empty fleet sends one chunk with an empty list.

## Design

- `WorkflowMetricsSnapshot`: public DTO `DefinitionMetrics`, `parse()`, and
  the pure `chunk()` (0 SOQL, 0 DML).
- `WorkflowMetricsCollector`: three bounded queries to `DefinitionMetrics`.
- `WorkflowMetricsPublisher.publishSnapshot(now)`: toggle, window, collect,
  chunk, guard, publish, log. Catch all.
- `WorkflowHeartbeatService`: call it after the lifecycle publish and before
  the liveness stamp.
- `Revenant_Config__mdt.Publish_Metrics_Events__c` (default off) to
  `WorkflowEngine.publishMetricsEvents`.
- `Revenant_Admin`: read and create on the event and its fields.
- Example: `WorkflowMetricsDatadogShaper` (examples) with a test.
- Docs: `docs/workflow-metrics-event.md`, ADR 0006, README.

## Test Plan

- `WorkflowMetricsSnapshotTest`: empty list, one chunk, many chunks under
  the budget, chunk cap, oversize row, parse round trip.
- `WorkflowMetricsCollectorTest`: counts for each status, window edges,
  oldest age, age scan cap, group cap, constant query count.
- `WorkflowMetricsPublisherTest`: toggle off costs 0 SOQL, one event,
  window from the liveness stamp and fallback, chunks share an id,
  truncation log, publish failure does not throw, DML guard, heartbeat
  sends when on and continues after a failure, default record is off.
- `WorkflowMetricsDatadogShaperTest`: one series point for each gauge.
