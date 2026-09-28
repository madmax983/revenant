# Step-History Guard

Issue #112. The engine counts the step rows of an instance on each hop. It warns at a soft threshold. It fails the instance at a hard ceiling. Thus a workflow that does not use Continue-As-New fails with a clear message, not a cryptic governor error.

## Why

Each step visit writes one `Workflow_Step_Execution__c` row. A loop, many retries or a wide fan-out adds rows to one instance. On each hop the engine reads step rows of that instance. At approximately 50,000 rows a hydrate query hits the query-row limit. Long text fields can fill the heap before that.

Continue-As-New starts a new instance with no step rows. Use it in each loop that can run without a limit.

## What the engine does

| Rows on the instance | Result |
|----------------------|--------|
| Below the warn threshold | No change. |
| At or above the warn threshold | The engine writes one `Workflow_Log__c` row (`Log_Type__c = StepHistoryWarning`, `Level__c = Warn`). The dashboard shows a **LONG HISTORY** badge on the list row and a message in the detail pane. Execution does not change. |
| At the ceiling | The engine fails the instance before the step runs. Category: `STEP_HISTORY_LIMIT`. Message: `Step history reached N rows (the ceiling). Refactor this workflow to use Continue-As-New.` |

At the ceiling:

- Error routing (#90) does not run. The error step cannot run past the guard.
- Compensation runs when the stack is not empty. The guard does not stop compensation.
- The guard writes no step row. It does not change the compensation stack.

The count is for one instance. A Continue-As-New successor (`Previous_Instance__c`) has its own rows, so its count starts at 1.

Engine workflows (watchdog, cleanup, bulk jobs, archive) are exempt.

## Configuration

On the **Default** record of `Revenant_Config__mdt`:

| Field | Default | Rule |
|-------|---------|------|
| `Step_History_Warn_Threshold__c` | 5000 | Blank or negative: default. `0`: no warning. Max 10000. When it is not below the ceiling, the engine uses half the ceiling. |
| `Step_History_Ceiling__c` | 10000 | Blank or negative: default. `0`: no ceiling. Max 10000. |

When both values are `0`, the guard does no SOQL.

The Default record is in the source. A deploy of the source sets the values again.

In an Apex test, set `WorkflowEngine.stepHistoryWarnThreshold` and `WorkflowEngine.stepHistoryCeiling`.

## Why these defaults

The count is `SELECT COUNT() ... LIMIT :ceiling`. `COUNT()` uses no heap, but it uses one query row for each row that it counts. The `LIMIT` stops the cost at the ceiling. With a ceiling of 10,000, the count and two full-history reads on the hop use max 30,000 of the 50,000 query rows. The step keeps the remainder.

The gap between the thresholds is 5,000 rows. The warning comes before the ceiling when one hop adds fewer rows than the gap. A fan-out wider than the gap can go from below the warning to the ceiling in one hop.

## Cost

On each hop that continues:

- One SOQL (`COUNT()` with `LIMIT`).
- Max `ceiling` query rows. No heap for rows.
- No DML below the warn threshold.
- Above the warn threshold: one insert statement after the step outcome. A second row for the same instance fails on the unique `Fire_Key__c` and is ignored. The insert occurs after `execute()`, so it does not block callouts.

A parked, paused or stale delivery does not pay: the guard runs after these gates.

## Operator actions

1. Filter the dashboard by the category **Step History Limit**.
2. Change the workflow: call `StepResult.continueAsNew(...)` at the end of each loop cycle.
3. Start the work again. A failed instance does not resume past the ceiling.
