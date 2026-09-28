# Guard Step-History Growth Per Instance (Issue #112)

## Goal

Find an instance whose step history grows too large before a hydrate query hits the 50,000 query-row limit or the heap limit. Warn at a soft threshold. Fail the instance with a clear message at a hard ceiling.

## Facts About The Engine

- Each step visit writes one `Workflow_Step_Execution__c` row. A loop back to a step writes a new row.
- The runner reads step rows for one instance on each hop. `WorkflowStepExecLock.acquireStepExecutionLog` reads all rows of the active step name with no `LIMIT`. `StepExecutionIndex` aggregates all rows of the instance.
- An aggregate query counts each row that it aggregates against the query-row limit. `COUNT()` uses no heap, but it uses query rows. A `LIMIT` stops the count, and the row cost, at the limit.
- Continue-As-New inserts a new instance. It copies no step row. The successor has one `Pending` row.
- A step can make a callout. A DML statement before the callout causes `CalloutException: uncommitted work pending`. Thus the runner must do no DML before `execute()`.
- `failWorkflowInstance` applies error routing (#90), then compensation, then `Failed`.
- `Workflow_Log__c.Fire_Key__c` is a unique external Id.

## Brainstorming (options)

| # | Idea | Keep? |
|---|------|-------|
| B1 | `SELECT COUNT()` on the instance, with no `LIMIT`. | No. It uses one query row per step row. At 50,000 rows the count itself fails. |
| B2 | `SELECT COUNT() ... LIMIT :ceiling`. | Yes. One SOQL. Max `ceiling` query rows. No heap. |
| B3 | Engine counter field on `Workflow_Instance__c`. | No. Many insert sites. Parallel branches race. A new data field. B2 is sufficient. |
| B4 | Count only every Nth hop. | No. One hop can cross the ceiling between checks. |
| B5 | Put the check after concurrency admission and the stale-parallel check, before the step-row lock. | Yes. A parked or stale delivery pays nothing. The check runs before the first full-history read. |
| B6 | Soft warning as a new checkbox on `Workflow_Instance__c`. | No. A new data field. |
| B7 | Soft warning as one `Workflow_Log__c` row, key `StepHistoryWarn:<instanceId>` in `Fire_Key__c`. Insert with `allOrNone = false`. A duplicate insert fails silently. | Yes. No new field. One row per instance. |
| B8 | Write the warning row before `execute()`. | No. It blocks callouts (see facts). |
| B9 | Write the warning row after the step outcome. | Yes. A rollback also removes the row. The next hop writes it again. |
| B10 | Dashboard: one `Fire_Key__c IN :keys` query per list page. Badge on the row. Callout in the detail pane. | Yes. Max one row per instance on the page. |
| B11 | At the ceiling, fail through `failWorkflowInstance` with a new category `STEP_HISTORY_LIMIT`. | Yes. The existing `Failed` path. Operators can filter by category. |
| B12 | Let error routing run at the ceiling. | No. The error step never runs: the guard stops it first. Each hop adds a row. That is an endless loop. Skip error routing. |
| B13 | Let compensation run at the ceiling. | Yes. A saga must undo its work. Compensation runs before the guard in the runner, so the guard does not stop it. The stack size limits it. |
| B14 | Append a marker step row at the ceiling. | No. The error message, category and alert are sufficient. The guard writes no step row. |
| B15 | Exempt engine workflows (watchdog, cleanup, bulk jobs, archive). | Yes. A failed watchdog stops the engine. They use Continue-As-New. |
| B16 | Config: `Step_History_Warn_Threshold__c` and `Step_History_Ceiling__c` in `Revenant_Config__mdt`. Read in the existing static config query. | Yes. No new SOQL. |
| B17 | Remove `Input__c` and `Output__c` from the first query in `acquireStepExecutionLog`. | Yes. The query uses `Id` and `Status__c` only. The long text fields make the heap grow with history. The lock query reads them for one row. |

## Reverse Brainstorming (how can this fail?)

| Way to fail | Prevention |
|-------------|-----------|
| The count query hits the row limit. | `LIMIT :ceiling`. Clamp the ceiling to 10,000. |
| The guard costs SOQL when off. | Both values `0`: no query. |
| A parked or stale delivery pays for the count. | Check after admission and the stale-parallel check. |
| The warning DML blocks a callout step. | Write the warning after the step outcome. |
| The warning row is written on each hop. | Unique `Fire_Key__c`. A duplicate insert fails with no exception. |
| Two parallel branches fail the instance twice. | Lock the instance `FOR UPDATE`. Fail only from `Pending`, `Running` or `Suspended`. |
| Error routing loops at the ceiling. | Skip error routing for this failure. |
| The guard changes or deletes step rows, or changes the stack. | The guard reads step rows only. The fail path writes the instance only. A test compares the rows before and after. |
| The guard stops compensation. | The compensation route runs before the guard. |
| A correct Continue-As-New loop trips the guard. | The count uses the instance Id. The successor has its own rows. |
| The warn value is not below the ceiling. The warning never shows. | Use half of the ceiling as the warn value. |
| A bad value (negative) disables the guard. | A negative value uses the default. Only `0` turns a check off. |
| One hop adds more rows than the gap (a wide fan-out). | Documented limit. Keep the gap larger than the widest fan-out. |
| A deploy resets the Default record. | Documented. Same as the other config fields. |
| The engine watchdog fails. | Engine workflows are exempt. |
| The error message is longer than 255 characters. | The fail path truncates it. The message is short. |

## Six Thinking Hats

- **White (facts):** Rows grow one per visit. `COUNT()` uses query rows, not heap. The hydrate path reads full history in up to two queries. With a ceiling of 10,000, the count and two full reads use max 30,000 of 50,000 rows.
- **Red (feelings):** Authors want an early warning, not a failure at 3 a.m. Operators do not want a false failure.
- **Black (risks):** One more SOQL on each hop. A test that drives many hops in one transaction uses one more SOQL per hop.
- **Yellow (benefits):** A clear message replaces a cryptic governor error. No new data field. No change to the append-only step model.
- **Green (ideas):** Show the count and the ceiling in the message. Show a badge on the dashboard row.
- **Blue (process):** Plan. RED tests with stubs. GREEN code. REFACTOR. Multi-angle review. Map each AC to evidence.

## Decision Table (the spec)

`resolve(warnRaw, ceilingRaw)`:

| Input | Result |
|-------|--------|
| blank or negative | Default: warn 5,000, ceiling 10,000. |
| `0` | That check is off. |
| ceiling > 10,000 | Ceiling 10,000. |
| warn > 10,000 | Warn 10,000. |
| warn and ceiling on, warn >= ceiling | Warn = ceiling / 2. |

`evaluate(count, thresholds)`:

| Ceiling on, count >= ceiling | Warn on, count >= warn | Verdict |
|------------------------------|------------------------|---------|
| yes | any | `HALT` |
| no | yes | `WARN` |
| no | no | `OK` |

Invariants:

1. The guard does max one SOQL on a hop that continues. It reads no step row into memory.
2. The guard writes no step row and does not change the compensation stack.
3. `HALT` fails the instance with `STEP_HISTORY_LIMIT` and skips error routing. With a stack, compensation starts.
4. `WARN` does not change execution. It writes max one log row per instance.
5. Both checks off: 0 SOQL, 0 DML.

## Changes

- Schema: `Revenant_Config__mdt.Step_History_Warn_Threshold__c`, `Step_History_Ceiling__c`. `Failure_Category__c` value `STEP_HISTORY_LIMIT`.
- `WorkflowStepHistoryGuard`: resolve, evaluate, count, halt, warning write, dashboard reads.
- `WorkflowStepRunner`: call the guard. Write the warning after the outcome.
- `WorkflowFailureService`: skip error routing on request.
- `WorkflowStepExecLock`: remove long text fields from the visit-count query.
- `WorkflowEngine`: config values, category constant, `skipErrorRouting` on the fail request.
- Dashboard: list badge, detail callout, category label.
- Docs: feature doc, ADR 0004, README, ARCHITECTURE.
