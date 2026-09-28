# Schedule Miss And Fail Alert (Issue #126)

## Goal

Find an enabled 0-slot schedule that did not fire in its window. Find a
schedule whose last fire failed. Show both on the dashboard. Send one alert
for each problem.

## Facts About The Engine

- The heartbeat runs the schedule sweep (Sweep 3) in
  `WorkflowHeartbeatService`. The sweep advances `Last_Fired_Window__c`,
  `Next_Fire_Window__c` and `Last_Outcome__c`.
- The sweep catches all errors. A bad row can stay on an old cursor and
  nothing reports it.
- Failure outcomes are `Error`, `Invalid cron` and `Invalid time zone`.
  `Started`, `Skipped` and `Deduped` are not failures.
- A cursor is an absolute UTC instant. The zone-aware evaluator (#109)
  calculates it.
- A dedicated schedule uses a `CronTrigger` in the time zone of the user who
  armed it. Its cursor can differ from its real fire time by hours.
- `Workflow_Log__c.Fire_Key__c` is unique. An insert gives an atomic claim
  (the #113 pattern).
- `WatchdogLiveness` gives the cadence (max of recorded and configured) for
  0 SOQL.

## Brainstorming (options)

| #   | Idea                                                                              | Keep?                                                                   |
| --- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| B1  | Pure classifier `ScheduleHealth` (0 SOQL, 0 DML).                                 | Yes. Dashboard, manager and alerter use the same rule.                  |
| B2  | Overdue = now − cursor > one sweep interval.                                      | Yes. The AC gives this rule.                                            |
| B3  | Use the later of the cursor and `LastModifiedDate` as the reference.              | Yes. A schedule enabled outside the UI gets one interval of grace.      |
| B4  | A blank cursor uses `LastModifiedDate`.                                           | Yes. The sweep seeds a cursor in one interval. A blank one is a miss.   |
| B5  | Include dedicated schedules in the overdue check.                                 | No. Their cursor is not in the zone of the `CronTrigger`. False alerts. |
| B6  | Include dedicated schedules in the failed check.                                  | Yes. Their outcome field is correct.                                    |
| B7  | Detect in the heartbeat, after Sweep 3.                                           | Yes. 0 new job slots. The sweep fires due rows first.                   |
| B8  | Add a new scheduled detector.                                                     | No. The AC forbids a new slot.                                          |
| B9  | Keep dedup on the schedule row.                                                   | No. A write changes `LastModifiedDate` and races the sweep.             |
| B10 | Claim each problem with a `Workflow_Log__c` row and a unique key.                 | Yes. One alert per problem, also under a race.                          |
| B11 | Key overdue by schedule + cursor; key failed by schedule + outcome + last window. | Yes. A new window or a new failure gives a new key.                     |
| B12 | Config: workflow `DeveloperName`, then `Default`.                                 | Yes. The AC gives this convention.                                      |
| B13 | Add a CMDT grace field.                                                           | No. The AC fixes the grace at one interval. No new schema.              |
| B14 | Auto refire the missed window.                                                    | No. Out of scope.                                                       |
| B15 | Show a Health column in the schedule manager.                                     | Yes. Same classifier. 0 new SOQL.                                       |

## Reverse Brainstorming (how to make it fail)

| How to fail                                            | Counter                                                           |
| ------------------------------------------------------ | ----------------------------------------------------------------- |
| Page on each sweep for the same miss.                  | Unique claim key. Query claims before the insert.                 |
| Report a paused schedule.                              | Filter on `Enabled__c = TRUE` in SOQL and in the classifier.      |
| Compare wall-clock local times across DST.             | Compare absolute instants (`getTime()`) only.                     |
| Report a schedule that the same sweep just fired.      | Detect after Sweep 3 in the same transaction.                     |
| Report a schedule just enabled via Setup (old cursor). | Reference = later of the cursor and `LastModifiedDate`.           |
| Write the schedule row from the detector.              | The detector writes only `Workflow_Log__c` claim rows.            |
| Touch instance or step rows.                           | No DML on them. A test checks `SystemModstamp`.                   |
| Spend the heartbeat DML or email budget.               | Budget guard. Cap alerts per sweep. One email per recipient list. |
| An error stops the heartbeat.                          | Catch all errors. The heartbeat also catches.                     |
| Keep a claim when no channel sends.                    | Delete the claim. A later sweep tries again.                      |
| Alert with no config.                                  | Alert only when `Enable_Alerts__c` and a channel is set.          |
| Report a dedicated schedule because of its time zone.  | No overdue check for dedicated schedules.                         |

## Six Thinking Hats

- **White (facts):** Cursor fields exist. Cadence 1–10 min, default 10. The
  sweep batch is 50 rows. Email: 10 invocations per transaction.
- **Red (feel):** Operators trust a quiet schedule. One false page makes
  them ignore the signal. One page per problem, not per sweep.
- **Black (risk):** The watchdog can be dead. Then no heartbeat runs and
  this check does not run. #113 covers that case. Cleanup can delete a claim
  and cause a second page. A backlog of more than 50 due rows can cause a
  true overdue report.
- **Yellow (value):** A silent stop shows in one sweep interval. The
  dashboard and the manager show it. No new job slot and no new schema.
- **Green (ideas):** Put the alert history in the schedule's **View Logs**
  (`Schedule__c` on the claim row, `Outcome__c = Overdue` or `Fire failed`).
- **Blue (process):** Spec, RED, GREEN, REFACTOR. Then agent review. Then map
  each AC to evidence.

## Spec

Per schedule `s`, at time `now`, grace `g` = cadence minutes:

| Condition                                                               | Flag             |
| ----------------------------------------------------------------------- | ---------------- |
| `Enabled__c = false`                                                    | none (`PAUSED`)  |
| `Last_Outcome__c` in {`Error`, `Invalid cron`, `Invalid time zone`}     | `lastFireFailed` |
| not dedicated, and `now − ref > g`, and `Last_Fired_Window__c < cursor` | `overdue`        |

- `ref` = later of `Next_Fire_Window__c` and `LastModifiedDate`. A blank
  cursor uses `LastModifiedDate`.
- Status: `PAUSED`, `OVERDUE`, `FAILED` or `OK`. `OVERDUE` wins when both
  flags are true. The flags stay separate.
- Invariant: a disabled schedule has no flag.
- Invariant: the alerter writes only `Workflow_Log__c` rows.
- Invariant: at most one alert per key.
- Invariant: no claim stays when no channel sent the alert.

## Design

- `ScheduleHealth`: `assess()`, `findUnhealthy()`, `summary()`.
- `ScheduleHealthAlert`: key, message, claim row, event, email for one
  problem.
- `ScheduleHealthAlerter.detectAndAlert(now)`: find, claim, send, release.
  Facade: `WorkflowAlertManager.detectAndAlertScheduleHealth(now)`.
- `WorkflowHeartbeatService`: step 3c, after the schedule sweeps.
- `WorkflowDashboardStatusService.watchdogStatus()`: `scheduleHealth` key.
- `WorkflowScheduleReadService.listSchedules()`: `overdue`,
  `lastFireFailed`, `healthStatus` per row.
- LWC: System Doctor **Schedule Health** panel. Manager **Health** column.

## Test Plan

- `ScheduleHealthTest`: boundary at one interval, disabled, dedicated,
  window handled, recent edit, blank cursor, each failure outcome, both
  flags, DST spring-forward, zone offset, SOQL finder, summary map.
- `ScheduleHealthAlerterTest`: one alert and one claim, no repage, distinct
  failed reason, new window gives a new alert, disabled, no config,
  workflow config and `Default` fallback, release when no channel sends,
  lost claim, no instance/step/schedule write, no new `CronTrigger`,
  heartbeat end to end with a starved row.
- `ScheduleHealthAlertTest`: keys, blank cursor, message, claim, event,
  email escape, email null cases.
- Dashboard Apex: `scheduleHealth` key. Manager Apex: health fields.
- Jest: doctor panel badges and empty state. Manager Health column.
