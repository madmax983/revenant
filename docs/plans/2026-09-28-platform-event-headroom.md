# Platform Event Allocation In System Doctor (Issue #120)

## Goal

Show how much of the org Platform Event allocation is used. Show a state:
Healthy, Warning or Critical. At Warning or Critical, tell the operator what
can fail.

## Facts About The Engine

- All three Revenant events (`Workflow_Event__e`, `Workflow_Lifecycle__e`,
  `Workflow_Alert__e`) are `HighVolume` and `PublishAfterCommit`.
- Each high-volume event that the engine publishes counts against
  `HourlyPublishedPlatformEvents`. Delivery to CometD, Pub/Sub API and
  empApi subscribers counts against `DailyDeliveredPlatformEvents` (and
  `MonthlyPlatformEventsUsageEntitlement` in add-on orgs). Delivery to Apex
  triggers does not count.
- Standard-volume events use `HourlyPublishedStandardVolumePlatformEvents`
  and `DailyStandardVolumePlatformEvents`. Revenant does not use them.
- The OrgLimits map of an org can contain some, all or none of these keys.
- `WorkflowDashboardStatusService.watchdogStatus()` already reads
  `System.OrgLimits.getMap()` for async Apex. It sets `hasElasticLimit` to
  false when the elastic key is not in the map.
- You cannot make a `System.OrgLimit` in an Apex test.
- The issue forbids a new object, field or scheduled job.

## Brainstorming (options)

| #   | Idea                                                                    | Keep?                                                            |
| --- | ----------------------------------------------------------------------- | ---------------------------------------------------------------- |
| B1  | Read one key only (`DailyDeliveredPlatformEvents`).                     | No. The publish key controls wake-ups.                           |
| B2  | Read all PE keys. Show one row for each key in the map.                 | Yes. Covers publish and delivery. The panel skips a missing key. |
| B3  | Add CMDT fields for the thresholds.                                     | No. The issue forbids a new field.                               |
| B4  | App Builder properties on the dashboard for the thresholds.             | Yes. No schema. The operator sets them with no code.             |
| B5  | One method classifies plain numbers. A different method reads OrgLimit. | Yes. Unit tests use fixed numbers at each boundary.              |
| B6  | Classify on the rounded percent.                                        | No. 79.996% rounds to 80% and shows Warning too early.           |
| B7  | Classify on the exact ratio (`value × 100 ≥ threshold × limit`).        | Yes. No rounding error at the boundary.                          |
| B8  | Show the worst state as a panel badge. Show a state on each row.        | Yes. One look gives the answer.                                  |
| B9  | Send an alert by email or event at Warning.                             | No. Out of scope (#42).                                          |
| B10 | Put the consequence text in the LWC.                                    | Yes. It is UI copy. One copy only.                               |
| B11 | One consequence text for all keys.                                      | No. A delivery key does not stop wake-ups. Use text per impact.  |

## Reverse Brainstorming (how to make it fail)

| How to fail                                               | Counter                                                               |
| --------------------------------------------------------- | --------------------------------------------------------------------- |
| Throw when the org has no PE key.                         | Skip a missing key or a limit of 0 or less. No rows: `UNAVAILABLE`.   |
| A PE read error stops System Doctor.                      | Catch errors in the service. Return the `UNAVAILABLE` payload.        |
| Divide by zero when the limit is 0.                       | Skip a key with a limit of 0 or less.                                 |
| Show negative headroom when use is more than the limit.   | Remaining = max(0, limit − value).                                    |
| Show "80.0%" with a Healthy badge.                        | Round the used percent down. Classify on the exact ratio.             |
| Show more remaining headroom than the org has.            | Round the remaining percent down.                                     |
| Bad App Builder values (Warning ≥ Critical, 0, over 100). | Ignore them. Use the server values. Tell the operator.                |
| The read uses DML, SOQL, async or PE budget.              | Map reads only. A test checks that the Limits counters do not change. |
| Change the payload keys that the LWC uses now.            | Add keys only. A test checks that the old keys stay.                  |
| Tell the operator that wake-ups stop for a delivery key.  | Consequence text for each impact.                                     |
| Screen readers announce the box on each refresh.          | `role="status"`, not `role="alert"`.                                  |

## Six Thinking Hats

- **White (facts):** `OrgLimits.getMap()` uses no SOQL, DML or async. A PE
  publish can fail after commit, and the engine does not see this failure.
  The async Apex card shows `value / limit` with no state.
- **Red (feel):** Operators must trust the colour. Warning at 80% and
  Critical at 95% are the usual values that operations teams use.
- **Black (risk):** The Apex and JS classifiers can become different. App
  Builder properties do not apply on a `lightning__Tab` target. All apps
  share the allocation, so a Warning can come from another app.
- **Yellow (value):** The operator sees a warning before the engine loses a
  wake-up. The change adds no schema and no job.
- **Green (ideas):** Show both "used" and "remaining" as number and percent.
  Show the key name, so the operator can find it in the REST `/limits`
  resource.
- **Blue (process):** Spec, RED, GREEN, REFACTOR. Then agent review. Then
  map each AC to evidence.

## Spec

Inputs for each key: `value` (used), `limit`. Thresholds: `warn`, `crit`
with `0 < warn < crit ≤ 100`. Defaults: 80 and 95.

| Condition                    | State         |
| ---------------------------- | ------------- |
| Key missing, or `limit ≤ 0`  | no row        |
| `value × 100 ≥ crit × limit` | `CRITICAL`    |
| `value × 100 ≥ warn × limit` | `WARNING`     |
| Not WARNING and not CRITICAL | `HEALTHY`     |
| No rows                      | `UNAVAILABLE` |

- Panel state = the worst row state (`CRITICAL` > `WARNING` > `HEALTHY`).
- `remaining = max(0, limit − value)`.
- `percentUsed` = used ÷ limit × 100, rounded down to 1 decimal place.
- `percentRemaining` = remaining ÷ limit × 100, rounded down to 1 decimal
  place.
- Impact: `PUBLISH` (high-volume publish), `DELIVERY` (delivery keys),
  `STANDARD_VOLUME` (standard-volume keys). An unknown key uses `PUBLISH`.
- Invariant: the read does no DML, SOQL, async enqueue or event publish.
- Invariant: the read does not send an exception to the dashboard.

## Design

- `PlatformEventHeadroom` (new): `classify()`, `evaluate()`,
  `fromOrgLimits()`, `unavailable()`, `limitKeys()`. No SOQL, no DML.
- `WorkflowDashboardStatusService.watchdogStatus()`: read the map one time.
  Add the headroom keys to the payload.
- `workflowDashboard` LWC: a new panel after "Platform Limits". A badge for
  each row and for the panel. Consequence text for each impact at risk. Two
  App Builder properties replace the thresholds. The component builds the
  panel model one time for each data or setting change.

## Test Plan

- `PlatformEventHeadroomTest`: boundaries 79.99 / 80 / 94.99 / 95 / 100 /
  over 100, zero use, limit 0, missing keys, custom thresholds, worst state,
  row order, labels and impacts, remaining and percent values, empty map,
  live map, no Limits counter change.
- `WorkflowDashboardControllerAuthTest`: the headroom keys are in the
  `getWatchdogStatus()` payload. The old keys stay. The state is correct at
  0 / 7999 / 8000 / 9499 / 9500 / 10000 of 10000. No key and a read error
  give `UNAVAILABLE`.
- Jest: rows and badges for each state, consequence text for each impact,
  "Not available" with no rows, refresh, App Builder values (valid, partial,
  string, blank, not valid), exact-ratio boundary with an override.
