# ADR 0004: Watchdog liveness marker and stall alert

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #113

## Context

One self-chaining watchdog runs all time-based work. No supervisor restarts
it. When it stops, nothing reports it. A check inside the watchdog cannot
find a dead watchdog. The issue does not permit a new scheduled job.

## Decision

1. Add a hierarchy custom setting `Watchdog_Liveness__c` with
   `Last_Sweep_At__c`, `Cadence_Minutes__c` and `Last_Alert_Sweep_At__c`. The
   heartbeat writes the first two after a complete sweep. The write does not
   throw.
2. Calculate the state on each read: `UNKNOWN`, `HEALTHY` or `STALE`.
   Threshold = 2 × max(recorded cadence, configured cadence).
3. Run the stall detector in `WorkflowWatchdog.bootstrap()` and in the System
   Doctor read. Do not run it in the heartbeat.
4. Claim each stall with a `Workflow_Log__c` row keyed
   `WatchdogStall:<last sweep ms>` on the unique `Fire_Key__c`. Send the
   alert after the claim. If no channel sends it, delete the claim. After a
   sent alert, write `Last_Alert_Sweep_At__c`. Later checks then do no DML.
5. Use the `WatchdogWorkflow` alert config, then `Default`. If no config
   exists, send no alert.

## Consequences

- One new schema object. A read costs 0 SOQL.
- The heartbeat does one more DML statement.
- `bootstrap()` is on the orchestrator chain. The detector adds one cached
  read there. It does DML only at the first detection of a stall, and it
  keeps 10 DML statements free.
- In an org with no traffic, the alert comes when an operator opens System
  Doctor, or when an operator schedules `WorkflowWatchdog`.

## Alternatives

- Read the last heartbeat step row. Rejected: SOQL on a large table, and
  cleanup can delete the row.
- Add a scheduled detector. Rejected: it uses a new scheduled job.
- Restart the watchdog automatically. Rejected: out of scope.
