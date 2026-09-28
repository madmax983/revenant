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
3. Two metrics have a status. Both gate the Queueable chain: daily
   executions, and pending jobs (`Holding` + `Queued` + `Processing`) / daily
   executions left. Queueable jobs in `Queued` have no queue limit, so the
   pending jobs use the executions that are left as the limit.
4. The flex queue (`Holding` / 100) is a count with no status. Queueable jobs
   do not go into the flex queue, so a full flex queue cannot stop the chain.
5. When the org has an elastic limit above 0, use it as the daily limit. This
   is the same rule as `StepGovernor`.
6. One Text field `Async_Capacity_Thresholds__c` holds `warn,crit`. Default
   `80,95`. Text that is not valid gives the defaults and a note on the panel.
7. Classify the rounded percent that the panel shows.
8. Put the rules in a pure class (`AsyncCapacityEvaluator`). Put the reads in
   `WorkflowAsyncCapacityService`. Use a new controller, because
   `WorkflowDashboardController` is at the PMD public-member limit.
9. Show the panel as a child LWC (`asyncCapacityPanel`) in System Doctor.

## Consequences

- No DML.
- The enqueue path does not change. A test checks that the orchestrator and
  the classes that call `System.enqueueJob()` do not name the read.
- The status is a snapshot. An operator must open the panel.
- The same evaluator can feed a later alert (#127) or throttle (#91/#28).

## Rejected Options

- Two number fields for the thresholds: the issue permits one field.
- A fixed limit for `Queued` + `Processing`: Queueable jobs have no queue
  limit. An invented value gives false alerts. The batch limit of 5 is normal
  batch saturation. It is not a risk to the Queueable chain.
- Use only the base daily limit: it shows false saturation in orgs with an
  elastic limit, and it disagrees with `StepGovernor`.
- A status on the flex queue: a full flex queue does not stop Queueable jobs.
  It gives a false "Chain handoff at risk" alert.
- Add the metrics to `getWatchdogStatus`: that read runs many queries and the
  stall detector. The capacity read must stay small.
- Cache the read in a custom setting: it adds a write.
