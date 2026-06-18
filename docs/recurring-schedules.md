# Recurring Workflow Schedules

Revenant's recurring-schedule feature lets any Salesforce admin start a workflow on a cron cadence by creating a single `Workflow_Schedule__c` record — **no Apex, no manual `System.schedule()`, and no additional scheduled-job slots**.

## How it works

The existing self-chaining `WatchdogWorkflow` (0 scheduled-job slots) already sweeps the org on every heartbeat. A new **Sweep 3** inside `WorkflowEngine.processWatchdogHeartbeat()` reads all enabled, non-dedicated `Workflow_Schedule__c` records, evaluates their cron expressions, and fires due ones through the standard `WorkflowEngine.startOrGet()` entrypoint. No new start path; the Queueable chain, Compensation Stack, and step records are all untouched.

**Firing latency** is bounded by `Watchdog_Delay_Minutes__c` (1–10 minutes, default 10). A workflow due at time T will start within one watchdog cadence of T.

## 0-slot vs dedicated-slot trade-off

| Mode | How | Slots used | Latency |
|---|---|---|---|
| **0-slot (default)** | Heartbeat Sweep 3 | 0 extra | ≤ `Watchdog_Delay_Minutes__c` |
| **Dedicated slot** | `registerDedicatedJob()` + `WorkflowScheduleJob` | 1 per schedule | Cron-exact |

For most operational schedules (hourly, nightly, weekly) the 0-slot mode is sufficient. Use a dedicated slot only when you need sub-cadence precision.

## Creating a schedule (zero-to-running in < 5 minutes)

The fastest path is the **Workflow Schedule Manager** UI (see below). You can also
create a `Workflow Schedule` record directly in Setup → Object Manager. Either way:
fill in the required fields, check **Enabled**, and save — the schedule fires on the
next watchdog heartbeat. No Apex, no deployment.

## Managing schedules from the UI

The `workflowScheduleManager` Lightning Web Component is a full management surface for
schedules. Add it to any Lightning app/home/record page in App Builder, or open it from
the **Schedules** button in the Workflow Orchestrator Dashboard (it is embedded there).

From the component you can:
- **Create / edit / delete** schedules via a guided modal — pick the workflow from a
  combobox of discovered `WorkflowDefinition` classes, enter a cron expression with a
  **live "next run" preview and validity check**, set the overlap policy, and write an
  optional input-JSON template.
- **Enable / disable** a schedule inline.
- **Run now** — fire a schedule immediately, independent of its cron cadence (uses a
  distinct `<prefix>_manual_<epochMillis>_<random>` correlation key, so repeated Run Now
  clicks always start independent runs).
- **View fire logs** — the recent `Workflow_Log__c` rows for a schedule
  (Started / Skipped / Deduped) with timestamps and correlation keys.
- **Arm / abort a dedicated-slot job** for schedules flagged `Dedicated_Slot__c`.

### Access

The UI and its Apex controller are gated on the **`Workflow_Schedule_Admin`** custom
permission, the **`Workflow_Admin`** custom permission, or Modify All Data. Two
permission sets ship:
- **`Revenant_Schedule_Admin`** — schedule-only access (manage schedules + read logs)
  for admins who should not see full engine monitoring.
- **`Revenant_Admin`** — full engine access, including schedules.

## Field reference (`Workflow_Schedule__c`)

| Field | API Name | Required | Description |
|---|---|---|---|
| Schedule Name | `Name` | ✓ | Human-readable name. |
| Workflow Name | `Workflow_Name__c` | ✓ | Fully-qualified `WorkflowDefinition` class name (e.g. `NightlyReconciliation` or `Jobs.BatchJob`). |
| Cron Expression | `Cron_Expression__c` | ✓ | 5-field cron. See syntax below. |
| Correlation Key Prefix | `Correlation_Key_Prefix__c` | ✓ | Prefix for each run's correlation key. Must be unique across schedules. |
| Enabled | `Enabled__c` | — | Gate. `false` = paused; `true` = active. |
| Overlap Policy | `Overlap_Policy__c` | — | `Skip` (default) or `Allow`. See below. |
| Dedicated Slot | `Dedicated_Slot__c` | — | `true` = opt out of 0-slot sweep; use `registerDedicatedJob()` to arm a CronTrigger. |
| Input JSON | `Input_Json__c` | — | JSON template passed as input. Tokens `{{fireTime}}` and `{{scheduleName}}` are substituted. |
| Last Fired Window | `Last_Fired_Window__c` | — | **Engine-managed.** Last fire-window DateTime. Do not edit manually. |
| Next Fire Window | `Next_Fire_Window__c` | — | **Engine-managed.** Next fire window after the last processed one. The 0-slot sweep filters on this so already-handled low-cadence schedules rotate out of the batch (no starvation). It is (re)computed when a schedule is saved with a new cron and advanced by each sweep, and the manager's **Next Run** column reads it directly (no per-row cron scan on list load). Do not edit manually. |
| Last Outcome | `Last_Outcome__c` | — | **Engine-managed.** Last outcome: `Started`, `Skipped`, `Deduped`, `Error` (malformed `Input_Json__c`), or `Invalid cron` (a syntactically valid cron that never fires, e.g. `0 0 31 2 *`). Do not edit manually. |

## Cron expression syntax (5-field)

```
minute  hour  day-of-month  month  day-of-week
```

| Field | Range | Notes |
|---|---|---|
| minute | 0–59 | |
| hour | 0–23 | UTC |
| day-of-month | 1–31 | |
| month | 1–12 | |
| day-of-week | 0–6 | 0 = Sunday |

**Operators:**

| Operator | Example | Meaning |
|---|---|---|
| `*` | `*` | Every value |
| Exact | `5` | Exactly 5 |
| List | `1,15` | 1st and 15th |
| Range | `1-5` | 1 through 5 inclusive |
| Step | `*/15` | Every 15 |
| Range+step | `0-30/10` | 0, 10, 20, 30 |

When both day-of-month and day-of-week are restricted (not `*`), they are **OR-ed** (standard cron semantics).

**Examples:**

| Cron | Description |
|---|---|
| `0 * * * *` | Every hour on the hour |
| `*/15 * * * *` | Every 15 minutes |
| `0 2 * * *` | Nightly at 02:00 UTC |
| `0 9 * * 1` | Every Monday at 09:00 UTC |
| `0 0 1 * *` | First day of every month at midnight |
| `0 0 1 1 *` | Once a year: Jan 1 midnight |

> **Timezone note:** All cron evaluation is in UTC (Salesforce `DateTime` is always UTC internally). Convert your desired local time to UTC when writing the expression.

## Overlap policies

### `Skip` (default)
If the previous run for this schedule is still active (Pending, Running, Suspended, Compensating, Cancelling, or CompensationFailed) when a new window is due, the new fire is **skipped**. A `Workflow_Log__c` record with `Outcome__c = 'Skipped'` is written. `Last_Fired_Window__c` is still advanced so the window is not retried on the next sweep.

Use for idempotent operations where a backlog of concurrent runs would be harmful (reconciliations, cleanups).

### `Allow`
A new instance is started regardless of any in-flight prior run. Instances for different fire windows have different correlation keys so they coexist without dedup collisions.

Use for operations where concurrent runs are safe (digest emails, independent batch jobs).

## Correlation key and dedup guarantee

Each run's correlation key is `prefix_yyyyMMddHHmm` (e.g. `NightlyRecon_202606170200`). Re-evaluating the same fire window within the same minute always produces the same key. The engine's `Active_Correlation_Key__c` UNIQUE constraint acts as a safety net: even if `Last_Fired_Window__c` state were lost, a duplicate start would be deduplicated.

> **Constraint:** `Dedup_Window_Minutes__c` (`Revenant_Config__mdt`) must exceed your schedule's cadence interval (e.g. for an hourly schedule, dedup window ≥ 60 minutes). The default (1440 minutes / 24 hours) satisfies all cadences from every-10-minutes to weekly.

## Fire outcomes (`Workflow_Log__c`)

| Outcome | Meaning |
|---|---|
| `Started` | A new workflow instance was created. `Workflow_Instance__c` is populated. |
| `Skipped` | Overlap=Skip and a prior run is still active. No instance was started. |
| `Deduped` | `startOrGet` resolved to an existing instance (safety net; rare). No log row is written for Deduped to avoid noise. |
| `Error` | The schedule is misconfigured — malformed `Input_Json__c`, or a `Workflow_Name__c` that does not resolve to a `WorkflowDefinition` (e.g. the record was created via Setup, bypassing the manager's validation). The bad schedule is isolated and logged with `Outcome__c = 'Error'` (in both the 0-slot and dedicated paths); other due schedules in the same heartbeat are unaffected, and the cursor advances so it does not retry every tick. No instance is started. |
| `Invalid cron` | A syntactically valid cron that never resolves to a fire window (e.g. `0 0 31 2 *`). The 0-slot sweep parks the row (advances its cursor) so it cannot starve other schedules. Re-saving with a valid cron clears it. |

Log rows are upserted on `Fire_Key__c` (`corrKey:outcome`) so repeated sweeps of the same window produce at most one row per outcome. Each log is linked to its schedule by the `Schedule__c` lookup (an immutable Id), so the audit trail stays attached even if the schedule is renamed.

## Disabling / deleting a schedule

- **Disable:** uncheck `Enabled__c`. The next sweep skips it. No orphaned `CronTrigger` or `AsyncApexJob` is left behind (0-slot mode never creates them).
- **Re-enable:** re-check `Enabled__c`. The engine recomputes `Next_Fire_Window__c` to the **next future window**, so a schedule paused past one or more windows does not immediately fire a stale window on re-enable (e.g. a nightly schedule re-enabled at 10:00 waits for the next 02:00, it does not fire that day's already-elapsed 02:00).
- **Delete:** delete the record. Identical effect.

> **Direct creation note:** schedules created directly in Setup/Object Manager (rather than through the manager UI) start with an empty cursor. On their first sweep the engine seeds the cursor to the next window and does **not** fire a window that elapsed before the record's creation minute, so creating an hourly schedule at 14:37 fires the 15:00 run, not 14:00.

## Input JSON templates

```json
{"scheduledAt":"{{fireTime}}","source":"{{scheduleName}}"}
```

Available tokens:
- `{{fireTime}}` — ISO-8601 string of the fire-window `DateTime` in UTC.
- `{{scheduleName}}` — value of the `Name` field on the schedule record.

Static JSON (no tokens) works unchanged.

## Dedicated-slot mode (1 CronTrigger)

For sub-cadence precision, opt a schedule into a dedicated `CronTrigger`:

```apex
// One-time setup (run in Anonymous Apex or a setup screen).
Id schedId = [SELECT Id FROM Workflow_Schedule__c WHERE Name = 'MyPreciseSchedule'].Id;
WorkflowScheduleSweeper.registerDedicatedJob(schedId);
```

This arms one `CronTrigger` running `WorkflowScheduleJob`, which re-reads the schedule at fire time and converts the 5-field cron to Salesforce's 7-field format (`0 <min> <hour> <dom> <month> <dow> *`). Dedicated fires go through the **same fire path as the 0-slot sweep**, so they honour `Overlap_Policy__c` (a `Skip` schedule with a prior run still in flight logs `Skipped` instead of starting a second run) and record `Last_Fired_Window__c` / `Last_Outcome__c` plus a `Workflow_Log__c` row — the manager shows identical state and audit history for dedicated and 0-slot schedules.

The job is keyed by the schedule's **immutable Id**, so renaming a schedule never orphans its `CronTrigger`. Editing only the cron of an already-armed dedicated schedule via the UI automatically aborts and re-arms the trigger with the new cadence (`System.schedule` can't be updated in place).

> **Note:** The `Dedicated_Slot__c` checkbox must be `true` on the record so the 0-slot sweep ignores it (preventing double-fires).

### Dedicated-slot caveats

Dedicated-slot mode arms a native `CronTrigger` via `System.schedule`, which behaves
differently from the 0-slot evaluator in three ways:

- **Timezone:** `System.schedule` interprets the cron in the **time zone of the user who
  arms the job**, whereas the 0-slot path evaluates in **UTC**. A dedicated `0 2 * * *`
  armed by a `America/New_York` admin fires at 02:00 Eastern, not 02:00 UTC. Arm dedicated
  jobs as a UTC user (or account for the offset) if you need them to match 0-slot timing.
- **Day-of-month + day-of-week together:** the 0-slot evaluator ORs them (standard cron),
  but Salesforce cron cannot. A cron that restricts **both** (e.g. `0 9 1 * 1`) is
  **rejected** when arming a dedicated job — use 0-slot mode for that schedule.
- **Enable/disable & input tokens:** the dedicated job re-reads the schedule at fire time,
  so disabling it stops firing on the next tick (and disabling via the UI also aborts the
  CronTrigger immediately), and `{{fireTime}}` / `{{scheduleName}}` tokens are resolved
  just like the 0-slot path (token values are JSON-escaped, so a name with a quote or
  backslash can't break the input JSON).

The dedicated job derives its fire window from the cron (via `previousFireTime`), not the
raw execution instant — so a `0 2 * * *` job that Salesforce happens to run at 02:01 still
keys and dedups on the 02:00 window, matching the 0-slot path. If the schedule row is
deleted, disabled, or un-checked out of `Dedicated_Slot__c` **outside the controller** (e.g.
via Object Manager or the API), the job **self-aborts** its own `CronTrigger` on the next
tick so it never lingers as an orphaned scheduled-job slot.

Apart from timezone and DOM+DOW handling above, dedicated mode now matches the 0-slot
path for overlap policy, state, fire logging, and misconfiguration handling (unknown
workflow / malformed input JSON record an `Error` outcome instead of failing every tick).

To remove it:

```apex
WorkflowScheduleSweeper.unregisterDedicatedJob(schedId);
```

This aborts the `CronTrigger`. No `AsyncApexJob` or other artifact is left behind.
