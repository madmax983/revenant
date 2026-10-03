# Plan: a Deduped fire ends a failure streak (#278)

## Problem

A `Deduped` fire writes no `Workflow_Log__c` row. The failure key uses the
last good fire log. So Failure, Deduped, same Failure gives the same key
and no second alert.

## Brainstorm

| Option | Result |
|---|---|
| A. Write a `Deduped` log row and add it to `GOOD_OUTCOMES` | No schema change. Two call sites. Chosen. |
| B. New "last good fire" field on the schedule | New field, new write on each fire. Rejected. |
| C. Key the alert on `Last_Fired_Window__c` | Re-alerts each failed window. Breaks the streak rule. Rejected. |

## Reverse brainstorm: how can A fail?

| Risk | Control |
|---|---|
| Log noise from `Deduped` rows | `Deduped` is rare. The sweep writes one row for each window. The upsert uses `Fire_Key__c`. |
| The row hides a failure | It cannot. A failure still sets `Last_Outcome__c`. The row only ends the streak. |
| The two fire paths drift | Test both paths. |
| Docs still say "no log row" | Update `recurring-schedules.md` and `schedule-health.md`. |
| `instanceId` is null | Guard the null `StartResult`. |

## Six hats

- White: both fire paths skip the log for `Deduped`. `ScheduleFireLog` already accepts it.
- Red: the operator expects an alert for a second failure.
- Yellow: small change, the streak rule stays the same.
- Black: extra DML rows. The sweep upserts all logs in one bulk call. It adds no DML statement.
- Green: option B is a fallback if volume becomes a problem.
- Blue: RED tests first, then GREEN, then REFACTOR, then review.

## Steps

1. RED: alerter test (Failure, Deduped, Failure gives two alerts).
2. RED: sweep and dedicated-fire tests (`Deduped` writes a log row).
3. GREEN: write the row in both paths. Add `Deduped` to `GOOD_OUTCOMES`.
4. REFACTOR: update comments and docs.
5. Review from several angles. Fix findings.
