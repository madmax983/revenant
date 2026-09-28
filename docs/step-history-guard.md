# Step-History Guard

Issue #112. The engine counts the step rows of an instance on each hop. It warns at a soft threshold. It fails the instance at a hard ceiling. Then a workflow without Continue-As-New fails with a clear message. It does not fail with a governor error.

## Why

Each step visit writes one `Workflow_Step_Execution__c` row. A loop or a wide fan-out adds rows to one instance. A retry uses the same row again. On each hop the engine reads step rows of that instance. At approximately 50,000 rows a hydrate query hits the query-row limit. Long text fields can fill the heap before that.

Continue-As-New starts a new instance with one step row. Use it in each loop that can run without a limit.

## What the engine does

| Rows on the instance | Result |
|----------------------|--------|
| Below the warn threshold | No change. |
| From the warn threshold to below the ceiling | The engine writes one `Workflow_Log__c` row (`Log_Type__c = StepHistoryWarning`, `Level__c = Warn`). The dashboard shows a **LONG HISTORY** badge on the list row and a message in the detail pane. Execution does not change. |
| At or above the ceiling | The engine fails the instance before the step runs. Category: `STEP_HISTORY_LIMIT`. Message: `Failed at step <step>: Step history reached <ceiling> rows (the ceiling). Change this workflow to use Continue-As-New.` |

At the ceiling:

- Error routing (#90) does not run. The error step cannot run past the guard.
- When the compensation stack is not empty, the instance goes to `Compensating`, then `Compensated`. The category stays blank, as for each other compensated failure. The error message stays. The guard does not stop compensation.
- The engine closes the open row of each active step: status `Failed`, no timeout. It aborts the scheduled jobs of the instance. Each failure path does this. Else an armed timeout can fail a compensating saga.
- The guard inserts and deletes no step row. It does not change closed rows or the compensation stack.

The count is for one instance. A Continue-As-New successor (`Previous_Instance__c`) has its own rows, so its count starts at 1.

Engine workflows (watchdog, cleanup, bulk jobs, archive) are exempt.

## Configuration

On the **Default** record of `Revenant_Config__mdt`:

| Field | Default | Rule |
|-------|---------|------|
| `Step_History_Warn_Threshold__c` | 5000 | Blank or negative: default. `0`: no warning. Max 10000. When it is not below the ceiling, the engine uses half the ceiling. Thus a ceiling of 1 gives no warning. |
| `Step_History_Ceiling__c` | 10000 | Blank or negative: default. `0`: no ceiling. Max 10000. |

When both values are `0`, the guard does no SOQL.

The Default record is in the source. A deploy of the source sets the values again.

In an Apex test, set `WorkflowEngine.stepHistoryWarnThreshold` and `WorkflowEngine.stepHistoryCeiling`.

## Why these defaults

The count is `SELECT COUNT() ... LIMIT :ceiling`. `COUNT()` uses one query row and no heap. The `LIMIT` stops the scan at the ceiling.

A hop can read the full history of one instance in max three queries: the visit count of the step, the patch index (`MIN`/`MAX` per step) and the parallel join. Below a ceiling of 10,000, they use max approximately 30,000 of the 50,000 query rows. The step keeps the remainder. These reads do not load long text fields for each row.

The gap between the thresholds is 5,000 rows. The warning comes before the ceiling when one hop adds fewer rows than the gap. A fan-out wider than the gap can go from below the warning to the ceiling in one hop.

## Cost

On each hop that continues:

- One SOQL (`COUNT()` with `LIMIT`).
- One query row. No heap for rows.
- No DML below the warn threshold.
- From the warn threshold: one insert statement (one DML statement) after the step outcome, on each hop. When no DML statement is left, the engine does not write the row. It tries again on the next hop. A second row for the same instance fails on the unique `Fire_Key__c` and is ignored. The insert occurs after `execute()`, so it does not block callouts.

A parked, paused or stale delivery does not pay: the guard runs after these gates.

## Operator actions

1. Filter the dashboard by the category **Step History Limit**. A saga that compensated has no category. Search its error message for `Step history reached`.
2. Change the workflow: call `StepResult.continueAsNew(...)` at the end of each loop cycle.
3. Start the work again. A failed instance does not resume past the ceiling.

## Known limits

- One hop that adds more rows than the gap (a wide fan-out) can go from below the warning to the ceiling.
- A saga at the ceiling ends `Compensated` with a blank category.
- The dashboard detail pane reads all step rows. It can fail on the heap for a very large history. See issue #261.
