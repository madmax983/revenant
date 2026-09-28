# ADR 0008: Schedule miss and fail alert

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #126

## Context

A 0-slot schedule can stop firing: a bad cron, an error that the sweep
catches, or a row that the sweep does not reach. No instance is created, so
instance alerts cannot find it. Watchdog liveness (#113) shows that the
heartbeat runs, but not that each schedule fires. The issue does not permit
a new scheduled job.

## Decision

1. Add `ScheduleHealth`, a rule class with no SOQL and no DML. Overdue =
   enabled, not dedicated, `Last_Fired_Window__c` is before
   `Next_Fire_Window__c`, now − reference > one sweep interval, and a sweep
   ran at or after the reference. Reference = the later of
   `Next_Fire_Window__c` and `LastModifiedDate`. Last fire failed = enabled
   and `Last_Outcome__c` is `Error`, `Invalid cron` or `Invalid time zone`.
2. Run `ScheduleHealthAlerter` in the heartbeat after Sweep 3.
3. Claim each problem with a `Workflow_Log__c` row and a unique
   `Fire_Key__c`. Overdue key: Id + cursor. Failed key: Id + outcome + last
   good fire. Delete the claim when no channel sends the alert.
4. Resolve the config with the workflow `DeveloperName`, then `Default`.
5. Show the state in System Doctor and in the Schedule Manager. A read uses
   the last sweep time of a healthy watchdog.
6. Reseed a past cursor when the sweep finds the window handled. A cron
   edit made in Setup does not reseed the cursor.

## Consequences

- No new schema and no new scheduled job.
- The heartbeat does 1 more query. It does DML only for a new problem.
- Dedicated schedules get only the failed check.
- The detector does not write schedule, instance or step rows.

## Alternatives

- Keep dedup fields on `Workflow_Schedule__c`. Rejected: a write changes
  `LastModifiedDate` and can race the sweep. It also adds schema.
- Key a failure on the failed window. Rejected: a failing hourly schedule
  then sends an alert each hour.
- Add a CMDT grace field. Rejected: the acceptance criteria set the grace
  to one interval.
- Run the check on each dashboard read. Rejected for alerts: a read must
  not send an alert. The dashboard only shows the state.
- Fire the missed window again. Rejected: out of scope.
