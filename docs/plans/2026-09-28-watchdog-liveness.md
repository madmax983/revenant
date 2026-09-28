# Watchdog Liveness And Stall Alert (Issue #113)

## Goal

Show when the watchdog did its last good sweep. Show a stale state when the
sweep is late. Send one alert for each stall. Detect a stall also when the
watchdog is dead.

## Facts About The Engine

- `WatchdogWorkflow` runs heartbeat, sleep, continue-as-new. The heartbeat
  calls `WorkflowHeartbeatService.runWatchdogHeartbeat()`.
- The heartbeat runs in the orchestrator transaction of the watchdog
  instance. Other workflows do not run it.
- `WorkflowWatchdog.bootstrap()` runs on each orchestrator enqueue (start,
  step handoff, signal, resume), on pause, on the "Enqueue Watchdog" command
  and on the optional `WorkflowWatchdog` schedule. It is not in the watchdog
  chain, but it is on the orchestrator chain.
- `WorkflowStallDetector` excludes `WatchdogWorkflow`. Nothing monitors the
  watchdog today.
- `Workflow_Log__c.Fire_Key__c` is a unique external id. An insert with the
  same key fails. This gives an atomic claim.

## Brainstorming (options)

| #   | Idea                                                                                    | Keep?                                                                        |
| --- | --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| B1  | Read the last completed heartbeat step row.                                             | No. SOQL on a large table. Cleanup can purge it.                             |
| B2  | Singleton hierarchy custom setting `Watchdog_Liveness__c`: last sweep time and cadence. | Yes. Read costs 0 SOQL. Cleanup does not touch it.                           |
| B3  | Upsert a `Workflow_Log__c` row per sweep.                                               | No. Costs SOQL to read. Cleanup can purge it.                                |
| B4  | Stale threshold = 2 × cadence. Cadence = max(recorded, configured).                     | Yes. Meets "stale within 2× cadence". A cadence change gives no false alert. |
| B5  | Detect the stall in the heartbeat.                                                      | No. A dead watchdog cannot detect itself.                                    |
| B6  | Detect the stall in `WorkflowWatchdog.bootstrap()`.                                     | Yes. It runs outside the watchdog chain. Adds 0 SOQL.                        |
| B7  | Compute the state on each dashboard read.                                               | Yes. Works when all jobs are dead.                                           |
| B8  | Dedup with a log row keyed `WatchdogStall:<last sweep ms>`.                             | Yes. Unique key: one alert per stall, also under a race.                     |
| B9  | Add a new scheduled job for the detector.                                               | No. The issue forbids a new slot.                                            |
| B10 | Restart the watchdog when stale.                                                        | No. Out of scope.                                                            |

## Reverse Brainstorming (how to make it fail)

| How to fail                                         | Counter                                                              |
| --------------------------------------------------- | -------------------------------------------------------------------- |
| Put the check only in the heartbeat.                | Check in `bootstrap()` and in the dashboard read.                    |
| Page on each evaluation.                            | Unique `Fire_Key__c` claim before dispatch.                          |
| Use a fixed 20 min threshold.                       | Threshold from the cadence.                                          |
| Alert when an admin makes the cadence longer.       | Use the larger of recorded and configured cadence.                   |
| Stamp spends the last DML; the step commit fails.   | Stamp last, only when DML budget stays free. Catch errors.           |
| Alert DML breaks a start transaction.               | Budget guard. Catch all errors. Claim then dispatch.                 |
| Alert in orgs with no alert config.                 | Alert only when `Enable_Alerts__c` and a channel is set.             |
| Stale state stays after the watchdog resumes.       | The next sweep writes a new time. The state is computed, not stored. |
| Lost update: detector writes over a new sweep time. | Detector does not write the setting.                                 |

## Six Thinking Hats

- **White (facts):** Cadence field is Number(2,0), default 10. Sleep uses the
  raw value. The heartbeat already guards DML for its best-effort publish.
- **Red (feel):** Operators must trust the signal. False alerts cause
  operators to ignore alerts. Use a full cadence of slack.
- **Black (risk):** The detector is on the orchestrator chain: it must cost
  0 SOQL and 0 DML when not needed. A failed delivery must not keep the
  claim. The custom setting is new schema. An org with no stamp shows
  `Unknown`, not `Stale`. A 1 minute cadence can give a false alert.
- **Yellow (value):** A dead timer plane shows red within 2 cadences. One
  page per stall. No new job slot.
- **Green (ideas):** Operators with no traffic can schedule the existing
  `WorkflowWatchdog` class. It runs `bootstrap()`, so it also detects.
- **Blue (process):** Spec, RED, GREEN, REFACTOR. Then agent review. Then
  map each AC to evidence.

## Spec

State machine (computed on read, never stored):

| Condition                           | State     |
| ----------------------------------- | --------- |
| No row, or `Last_Sweep_At__c` blank | `UNKNOWN` |
| elapsed ≤ threshold                 | `HEALTHY` |
| elapsed > threshold                 | `STALE`   |

- threshold = 2 × max(recorded cadence, configured cadence). Cadence < 1
  becomes 1. Blank becomes 10.
- Invariant: at most one alert per `Last_Sweep_At__c` value.
- Invariant: the stamp never throws and never spends the last DML statements.
- Invariant: the detector writes only `Last_Alert_Sweep_At__c`. The stamp
  writes only `Last_Sweep_At__c` and `Cadence_Minutes__c`.
- Invariant: the detector does no DML when the state is not `STALE` or the
  stall has its alert. It keeps 10 DML statements free.
- Invariant: when no channel sends the alert, the claim is deleted.

## Design

- `Watchdog_Liveness__c` (hierarchy custom setting): `Last_Sweep_At__c`,
  `Cadence_Minutes__c`.
- `WatchdogLiveness`: `recordSweep(now, cadence)`, `evaluate(now)` returns a
  `Snapshot`, `toMap()` for the dashboard.
- `WatchdogStallDetector.detectAndAlert()`: evaluate, check config, claim the
  key, send email and `Workflow_Alert__e`. Facade:
  `WorkflowAlertManager.detectAndAlertWatchdogStall()`.
- `WorkflowHeartbeatService`: stamp after the lifecycle publish.
- `WorkflowWatchdog.bootstrap()`: call the detector first.
- System Doctor read: call the detector, for orgs with no traffic.
- `WorkflowDashboardStatusService.watchdogStatus()`: add a `liveness` key.
- `workflowDashboard` LWC: liveness row in the Watchdog panel.

## Test Plan

- `WatchdogLivenessTest`: unknown, healthy, stale at the boundary, threshold
  from config, larger cadence wins, stamp writes and updates one row, stamp
  skips when DML budget is low.
- `WatchdogStallDetectorTest`: stale gives one event and one log, second
  run gives none, healthy gives none, no config gives none, resume then a
  new stall gives a second alert, the detector does not change the setting,
  bootstrap runs the detector.
- `WatchdogLivenessTest`: heartbeat stamps the setting; a later sweep clears
  `STALE`.
- Dashboard Apex: `liveness` key present. Jest: badge and text per state.
