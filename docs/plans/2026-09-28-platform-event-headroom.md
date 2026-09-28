# Platform Event Headroom In System Doctor (Issue #120)

## Goal

Show how much of the org Platform Event allocation is used. Show a state:
Healthy, Warning or Critical. At Warning or Critical, tell the operator what
can fail.

## Facts About The Engine

- All three Revenant events (`Workflow_Event__e`, `Workflow_Lifecycle__e`,
  `Workflow_Alert__e`) are `HighVolume` and `PublishAfterCommit`.
- High-volume publish uses `HourlyPublishedPlatformEvents`. CometD and
  Pub/Sub delivery uses `DailyDeliveredPlatformEvents`. Legacy
  standard-volume events use `HourlyPublishedStandardVolumePlatformEvents`
  and `DailyStandardVolumePlatformEvents`. An org can show some, all or none
  of these keys.
- `WorkflowDashboardStatusService.watchdogStatus()` already reads
  `System.OrgLimits.getMap()` for async Apex. It sets `hasElasticLimit` to
  false when the elastic key is not there.
- Apex tests cannot make a `System.OrgLimit`. Logic that takes an
  `OrgLimit` is not unit-testable with fixed values.
- The issue forbids a new object, field or scheduled job.

## Brainstorming (options)

| #   | Idea                                                               | Keep?                                                           |
| --- | ------------------------------------------------------------------ | --------------------------------------------------------------- |
| B1  | Read one key only (`DailyDeliveredPlatformEvents`).                | No. Publish is the key that stops wake-ups.                     |
| B2  | Read all four PE keys. Show one row for each key that is there.    | Yes. Covers publish and delivery. Missing keys drop out.        |
| B3  | Add CMDT fields for the thresholds.                                | No. The issue forbids a new field.                              |
| B4  | App Builder design attributes on the dashboard for the thresholds. | Yes. No schema. The operator sets them with no code.            |
| B5  | Pure classifier on plain numbers; a thin adapter reads `OrgLimit`. | Yes. Unit tests use fixed numbers at each boundary.             |
| B6  | Classify on the rounded percent.                                   | No. 79.996 % rounds to 80 % and shows Warning too early.        |
| B7  | Classify on the exact ratio (`value × 100 ≥ threshold × limit`).   | Yes. No rounding error at the boundary.                         |
| B8  | Show the worst state as a panel badge. Show a state on each row.   | Yes. One glance gives the answer.                               |
| B9  | Alert by email or event at Warning.                                | No. Out of scope (#42).                                         |
| B10 | Put the consequence text in the LWC.                               | Yes. It is UI copy. One copy only.                              |
| B11 | Add the PE keys to the async `readAsyncLimits` map.                | No. Separate class keeps the status service small and testable. |

## Reverse Brainstorming (how to make it fail)

| How to fail                                               | Counter                                                                |
| --------------------------------------------------------- | ---------------------------------------------------------------------- |
| Throw when the org has no PE key.                         | Missing key or limit ≤ 0 gives no row. No rows gives `UNAVAILABLE`.    |
| A PE read error breaks the whole System Doctor.           | Catch errors in the service. Return the `UNAVAILABLE` payload.         |
| Divide by zero when the limit is 0.                       | Limit ≤ 0 gives no row.                                                |
| Show negative headroom when usage is over the limit.      | Remaining = max(0, limit − value). Percent remaining ≥ 0.              |
| Show "80.0 %" with a Healthy badge.                       | Round the used percent down. Classify on the exact ratio.              |
| Bad App Builder values (warning ≥ critical, 0, over 100). | Ignore the override. Use the server defaults.                          |
| The read spends DML, SOQL, async or PE budget.            | Map reads only. A test asserts that the Limits counters do not change. |
| Change the payload keys that the LWC already uses.        | Additive keys only. A test asserts the old keys stay.                  |
| Client and server classify in different ways.             | Same rule, same boundary tests in Apex and Jest.                       |

## Six Thinking Hats

- **White (facts):** `OrgLimits.getMap()` costs no SOQL, DML or async. The
  platform can drop PE publish without an exception to the engine. The
  async Apex card shows `value / limit` with no state.
- **Red (feel):** Operators must trust the colour. Warning at 80 % and
  Critical at 95 % match common ops practice.
- **Black (risk):** Two classifiers (Apex and JS) can drift. The design
  attributes do not work on a `lightning__Tab` target. The allocation is
  shared, so a Warning can come from another app.
- **Yellow (value):** Forewarning before the first lost wake-up. No schema,
  no job, no hot-path change.
- **Green (ideas):** Show both "used" and "remaining" as number and percent.
  Show the key name so the operator can find it in Company Information.
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
| else                         | `HEALTHY`     |
| No rows                      | `UNAVAILABLE` |

- Panel state = the worst row state (`CRITICAL` > `WARNING` > `HEALTHY`).
- `remaining = max(0, limit − value)`.
- `percentUsed` = used ÷ limit × 100, rounded down to 1 decimal place.
- `percentRemaining = max(0, 100 − percentUsed)`.
- Invariant: the read does no DML, SOQL, async enqueue or event publish.
- Invariant: the read never throws to the dashboard.

## Design

- `PlatformEventHeadroom` (new): `classify()`, `evaluate(readings, warn,
crit)`, `fromOrgLimits(map)`. Pure. No SOQL, no DML.
- `WorkflowDashboardStatusService.watchdogStatus()`: read the map one time.
  Add the headroom keys to the payload.
- `workflowDashboard` LWC: new card list in "Platform Limits". Badge per row
  and for the panel. Consequence text at Warning or Critical. Two design
  attributes override the thresholds.

## Test Plan

- `PlatformEventHeadroomTest`: boundaries 79.99 / 80 / 94.99 / 95 / 100 /
  over 100, zero use, limit 0, missing keys, custom thresholds, worst state,
  row order, remaining and percent values, empty map, live map, no Limits
  counter change.
- `WorkflowDashboardControllerAuthTest`: headroom keys are in the
  `getWatchdogStatus()` payload. The old keys stay.
- Jest: rows and badges per state, consequence text only at Warning or
  Critical, "Not available" with no rows, design-attribute override, invalid
  override ignored.
