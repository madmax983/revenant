# ADR 0006: Async Apex capacity panel

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #129

## Context

The Queueable chain stops when the org has no async Apex capacity. Operators
cannot see the capacity before the chain stops. The issue permits one optional
config field, no new object, max 1 SOQL and no change to the enqueue path.

## Decision

1. Read the daily count from `System.OrgLimits` key
   `DailyAsyncApexExecutions`. `Limits.getAsyncCalls()` is "reserved for
   future use" and gives no org data.
2. Read job counts with one `AsyncApexJob` aggregate, `GROUP BY Status`, for
   `Holding`, `Queued` and `Processing`. Max 3 query rows.
3. Two metrics have a status: daily executions (limit from `OrgLimits`) and
   the flex queue (`Holding` / 100). `Queued` and `Processing` are counts only,
   because the platform has no fixed ceiling for them.
4. One Text field `Async_Capacity_Thresholds__c` holds `warn,crit`. Default
   `80,95`. Text that is not valid gives the defaults and a note on the panel.
5. Classify the rounded percent that the panel shows.
6. Put the rules in a pure class (`AsyncCapacityEvaluator`). Put the reads in
   `WorkflowAsyncCapacityService`. Use a new controller, because
   `WorkflowDashboardController` is at the PMD public-member limit.
7. Show the panel as a child LWC (`asyncCapacityPanel`) in System Doctor.

## Consequences

- No new object. One new optional field. No DML.
- The enqueue path does not change. A test checks that
  `WorkflowOrchestrator` does not name the read.
- The status is a snapshot. An operator must open the panel.
- The same evaluator can feed a later alert (#127) or throttle (#91/#28).

## Rejected Options

- Two number fields for the thresholds: the issue permits one field.
- A ceiling for `Queued` + `Processing`: the platform has none. An invented
  value gives false alerts.
- Add the metrics to `getWatchdogStatus`: that read runs many queries and the
  stall detector. The capacity read must stay small.
- Cache the read in a custom setting: it adds a write.
