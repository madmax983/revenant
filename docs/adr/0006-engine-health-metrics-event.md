# ADR 0006: Engine-health metrics event on the watchdog sweep

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #127

## Context

SREs need fleet health in their own monitoring tools. All Revenant
telemetry stays in Salesforce (dashboard, System Doctor, alert email). The
issue forbids a new scheduled job and a per-instance query.

## Decision

1. Add the Platform Event `Workflow_Metrics__e` (HighVolume,
   `PublishAfterCommit`). One event holds a JSON list of definition rows.
   A large snapshot uses more chunks with one `Snapshot_Id__c`.
2. Publish from `WorkflowHeartbeatService`, after the lifecycle publish and
   before the liveness stamp. Toggle: `Publish_Metrics_Events__c`, default
   off.
3. Read with max three queries: grouped `COUNT(Id)` for active statuses,
   grouped `COUNT(Id)` for terminal statuses in the window, and an
   `ORDER BY CreatedDate ASC LIMIT k` scan for the oldest age. Do not use
   `MIN()`: it uses one query row for each aggregated row.
4. Window = `(previous Last_Sweep_At__c, snapshot time]`. The read costs 0
   SOQL.
5. Caps (groups, age rows, chunks) set `Is_Truncated__c` and write one Warn
   log. Budget reserves keep the sweep safe from a `LimitException`.
6. Freeze the event fields and JSON keys as schema version 1. Later versions
   only add.

## Consequences

- One new public schema object and one new config field.
- When on: max 3 SOQL, 1 DML statement for each sweep. When off: 0.
- On a fleet with more than 10,000 active instances, some ages can be null.
  The counts stay exact.
- Late commits near the window end can be missed. Counts are gauges.

## Alternatives

- One event for each definition with flat fields. Rejected: the event count
  grows with the fleet.
- `MIN(CreatedDate)` for the age. Rejected: no bound on query rows.
- A Queueable for the snapshot. Rejected: the watchdog Queueable can enqueue
  only one child, and the chain needs it.
- A REST pull endpoint. Rejected: out of scope (push only).
