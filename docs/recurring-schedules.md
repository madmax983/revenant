# Recurring Workflow Schedules

Revenant's recurring-schedule feature lets any Salesforce admin start a workflow on a cron cadence by creating a single `Workflow_Schedule__c` record — **no Apex, no manual `System.schedule()`, and no additional scheduled-job slots**.

## How it works

The existing self-chaining `WatchdogWorkflow` (0 scheduled-job slots) already sweeps the org on every heartbeat. A new **Sweep 3** inside `WorkflowEngine.processWatchdogHeartbeat()` reads all enabled, non-dedicated `Workflow_Schedule__c` records, evaluates their cron expressions, and fires due ones through the standard `WorkflowEngine.startOrGet()` entrypoint. No new start path; the Queueable chain, Compensation Stack, and step records are all untouched.

**Firing latency** is bounded by `Watchdog_Delay_Minutes__c` (1–10 minutes, default 10). A workflow due at time T will start within one watchdog cadence of T.

## 0-slot vs dedicated-slot trade-off

| Mode | How | Slots used | Latency |
|---|---|---|---|
| **0-slot (default)** | Heartbeat Sweep 3 | 0 extra | ≤ `Watchdog_Delay_Minutes__c` |
| **Dedicated slot** | `registerDedicatedJob()` + `WorkflowScheduler` | 1 per schedule | Cron-exact |

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
  distinct `<prefix>_manual_<timestamp>` correlation key).
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
| Last Outcome | `Last_Outcome__c` | — | **Engine-managed.** Last outcome: `Started`, `Skipped`, or `Deduped`. |

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

Log rows are upserted on `Fire_Key__c` (`corrKey:outcome`) so repeated sweeps of the same window produce at most one row per outcome.

## Disabling / deleting a schedule

- **Disable:** uncheck `Enabled__c`. The next sweep skips it. No orphaned `CronTrigger` or `AsyncApexJob` is left behind (0-slot mode never creates them).
- **Delete:** delete the record. Identical effect.

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

This arms one `CronTrigger` using the existing `WorkflowScheduler` primitive and converts the 5-field cron to Salesforce's 7-field format (`0 <min> <hour> <dom> <month> <dow> *`).

> **Note:** The `Dedicated_Slot__c` checkbox must be `true` on the record so the 0-slot sweep ignores it (preventing double-fires).

To remove it:

```apex
WorkflowScheduleSweeper.unregisterDedicatedJob(schedId);
```

This aborts the `CronTrigger`. No `AsyncApexJob` or other artifact is left behind.
