# Install Readiness Preflight (Issue #114)

## Goal

Give the operator one read-only check list on System Doctor. Each check tells if a setup item is correct. Each `Warn` or `Fail` names the missing item and the fix.

## Facts About The Engine

- `WorkflowEngine` reads `Revenant_Config__mdt` record `Default`. When the record is missing, the engine uses built-in defaults and the operator cannot change a setting.
- `WorkflowFailureAlertEvaluator` falls back to `Workflow_Alert_Config__mdt` record `Default`. `WorkflowAlertManager` sends no alert when the config is missing, when `Enable_Alerts__c` is off, or when it has no recipients and no event.
- `WorkflowEventTrigger` on `Workflow_Event__e` delivers signals, approvals and child-completion resumes.
- System Doctor gets the watchdog health from `WorkflowDashboardStatusService` (latest watchdog instance is `Pending`, `Running` or `Suspended`). The change shares it as `watchdogRunning()`.
- `WorkflowDashboardController` is at the PMD `ExcessivePublicCount` limit. The Rate Limits panel (#61) uses its own controller for this reason.
- Custom metadata records and trigger status cannot change in an Apex test.

## Brainstorming (options)

| #   | Idea                                                                                                                 | Keep?                                                                       |
| --- | -------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| B1  | Add the method to `WorkflowDashboardController`.                                                                     | No. PMD public-member limit. Use `WorkflowReadinessController`, as #61 did. |
| B2  | New `WorkflowReadinessService` with one row per check: `key`, `name`, `status`, `finding`, `remediation`.            | Yes. Typed DTO, not a map.                                                  |
| B3  | Read config records with `getInstance('Default')`.                                                                   | Yes. No SOQL.                                                               |
| B4  | Read the trigger status from `ApexTrigger`.                                                                          | Yes. One bounded SOQL.                                                      |
| B5  | Call `getWatchdogStatus()` and read `isRunning`.                                                                     | No. It runs 5+ queries.                                                     |
| B6  | Extract `watchdogRunning()` from `WorkflowDashboardStatusService`. Both panels use the same query and the same rule. | Yes. Reuse, not a copy.                                                     |
| B7  | Check access of the user that opens the dashboard with `Schema` describe.                                            | Yes. No SOQL.                                                               |
| B8  | Check the Automated Process user through `ObjectPermissions`.                                                        | No. Out of scope. The engine writes in system mode.                         |
| B9  | Inject a `Probe` so a test can make a broken install.                                                                | Yes. The only seam for metadata and trigger status.                         |
| B10 | Make `WorkflowAlertManager.isAlertActionable` public and reuse it.                                                   | Yes. Same rule as the alert path.                                           |
| B11 | One access row per core object (instance, step, signal).                                                             | Yes. Each row names the object and fields.                                  |
| B12 | Show a "Run Checks" button and the round-trip time on the panel.                                                     | Yes. One click. Shows the < 2 s target.                                     |
| B13 | Add a button that starts the watchdog on the panel.                                                                  | No. Link to the existing **Enqueue Watchdog** button.                       |

## Reverse Brainstorming (how can this fail?)

| Way to fail                                                  | Prevention                                                                                                                      |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| The check writes data or starts a job.                       | Only getInstance, describe and two SELECTs (plus one for the view gate). Test asserts 0 DML, 0 jobs, 0 events.                  |
| A read-only operator sees `Fail` for missing create access.  | Missing read is `Fail`. Missing create is `Warn`. The engine writes in system mode, so only user-mode code needs create access. |
| The finding says "something is wrong".                       | Every `Warn` and `Fail` names the item. Test asserts a remediation on every non-`Pass` row.                                     |
| A `Default` alert config exists but alerts no one.           | Reuse `isAlertActionable`. `Warn` when not actionable.                                                                          |
| The trigger is not deployed.                                 | No `ApexTrigger` row: `Fail`, with a deploy step.                                                                               |
| A namespaced install finds the wrong trigger.                | Filter on the namespace of the service class.                                                                                   |
| The watchdog rule changes in one panel but not in the other. | One shared method.                                                                                                              |
| A slow check blocks the panel.                               | Bounded work: 2 SOQL, no loops over records. Test asserts CPU < 2000 ms.                                                        |
| An old response replaces a new one.                          | Only the newest request can change the panel.                                                                                   |
| An error looks like "all pass".                              | Error state is separate. No rows on error.                                                                                      |
| An unknown status looks healthy.                             | Unknown status shows grey "Unknown".                                                                                            |

## Six Thinking Hats

- **White (facts):** Five setup items fail silently. Metadata and trigger status are fixed in tests. System Doctor already shows the watchdog signal.
- **Red (feelings):** A new admin wants one screen that says "you are ready" or "fix this". A long list of greens gives trust.
- **Black (risks):** False `Fail` for an operator. A copy of the watchdog rule. A check that mutates. Access check for a user that the engine does not use.
- **Yellow (benefits):** Shorter time to the first run. Lower MTTR. No schema change. No engine hot-path change.
- **Green (ideas):** Show the round-trip time. Use copy-ready `code` text for each fix. Put the panel first on System Doctor.
- **Blue (process):** Plan. RED tests with stubs. GREEN code. REFACTOR. Multi-angle review. Map each AC to evidence.

## Decision Table (the spec)

| Key               | Input                                | Status | Finding (short)                                             |
| ----------------- | ------------------------------------ | ------ | ----------------------------------------------------------- |
| `engineConfig`    | `Default` present                    | Pass   | Present.                                                    |
| `engineConfig`    | `Default` absent                     | Fail   | Engine uses built-in defaults.                              |
| `alertConfig`     | `Default` present and actionable     | Pass   | Present.                                                    |
| `alertConfig`     | `Default` absent                     | Warn   | Failures will not alert anyone.                             |
| `alertConfig`     | `Default` not actionable             | Warn   | Alerts off or no channel.                                   |
| `eventTrigger`    | `Active`                             | Pass   | Active.                                                     |
| `eventTrigger`    | `Inactive`                           | Fail   | Signals, approvals and child-completion resumes never fire. |
| `eventTrigger`    | not found                            | Fail   | Not deployed.                                               |
| `watchdog`        | running                              | Pass   | Running.                                                    |
| `watchdog`        | not running                          | Fail   | Points to **Enqueue Watchdog**.                             |
| `access.<Object>` | read and create on object and fields | Pass   | Access OK.                                                  |
| `access.<Object>` | a read gap                           | Fail   | Names each object or field.                                 |
| `access.<Object>` | create gap only                      | Warn   | Names each object or field.                                 |

Invariants:

1. The check makes no DML, no `enqueueJob`, no event publish and no schema write.
2. Each `Warn` and `Fail` row has a non-blank `remediation`.
3. The row order is fixed: config, alerts, trigger, watchdog, access (instance, step, signal).

## Changes

- `WorkflowReadinessController.getReadinessChecks()` (not cacheable).
- `WorkflowReadinessService` with `ReadinessCheck` DTO and `Probe` seam.
- `WorkflowDashboardStatusService.watchdogRunning()` (shared).
- `WorkflowAlertManager.isAlertActionable` is public.
- Permission sets: class access for `WorkflowReadinessController`.
- LWC: Readiness panel at the top of System Doctor.
- Tests: `WorkflowReadinessControllerTest`, Jest panel tests.
- Docs: `docs/readiness.md`, README, ARCHITECTURE.
