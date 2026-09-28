# ADR 0004: Watchdog liveness marker and stall alert

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #113

## Context

One self-chaining watchdog runs all time-based work. No supervisor restarts
it. When it stops, nothing reports it. A check inside the watchdog cannot
find a dead watchdog. The issue forbids a new scheduled-job slot.

## Decision

1. Add a hierarchy custom setting `Watchdog_Liveness__c` with
   `Last_Sweep_At__c` and `Cadence_Minutes__c`. The heartbeat writes it last,
   best-effort, only after a full sweep.
2. Compute the state on read: `UNKNOWN`, `HEALTHY` or `STALE`. Threshold =
   2 × max(recorded cadence, configured cadence).
3. Run the stall detector in `WorkflowWatchdog.bootstrap()`, not in the
   heartbeat. Show the state in System Doctor from the same read.
4. Claim each stall with a `Workflow_Log__c` row keyed
   `WatchdogStall:<last sweep ms>` on the unique `Fire_Key__c`. Send the alert
   only after a good claim.
5. Use the `WatchdogWorkflow` alert config with `Default` fallback. No config,
   no alert.

## Consequences

- One new schema object. Reads cost 0 SOQL.
- One DML statement per sweep. No change to the orchestrator chain.
- An org with no traffic and no dashboard view finds a stall only when an
  operator schedules `WorkflowWatchdog`.
- Rejected: read the last heartbeat step row (SOQL on a large table, cleanup
  can purge it); a new scheduled detector (new slot); auto-restart (out of
  scope).
