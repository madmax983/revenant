# Incremental Polling with `ctx.previousRunAt`

A common pattern for long-running operational workflows is a perpetual poller
that wakes up on a schedule, processes only the records that changed since the
last run, then sleeps and repeats. Revenant supports this natively through
`StepContext.previousRunAt` and `StepResult.continueAsNew()`.

## How it works

When a step calls `StepResult.continueAsNew()`, the engine creates a successor
`Workflow_Instance__c` and stamps its `Previous_Run_At__c` field with the
predecessor's **`CreatedDate`** — the moment the predecessor instance was
created (i.e., when the run started), not when it finished. The successor's
`StepContext` exposes this as `previousRunAt`.

The first instance in a chain has no predecessor, so `previousRunAt` is always
`null` on the initial run. Steps must handle this cold-start case explicitly.

```
Run 1 starts at 1:00 PM
  │   queries records (1:00 PM SOQL)
  │   ... execution takes until 1:05 PM ...
  └──► ContinueAsNew ──► Previous_Run_At__c on Run 2 = 1:00 PM (Run 1 CreatedDate)

Run 2 queries WHERE LastModifiedDate >= 1:00 PM
  → catches records modified at 1:02 PM (during Run 1's execution) ✓
  → may re-process records near the 1:00 PM boundary  ← bounded overlap, not a gap
```

**Why `CreatedDate` and not `System.now()`?** Using the finish time creates a
gap: records modified *during* the predecessor's execution window would fall
between the two run windows and never be processed. Using the start time gives
you **at-least-once coverage** — the same semantic Temporal and DBOS use for
polling cursors. Near-boundary records may be processed by both runs, but
nothing is ever skipped. Polling workflows should be idempotent anyway.

## Basic pattern

```java
public class SyncChangedAccountsStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
        // Fall back to a 24-hour cold-start window on the first run.
        Datetime since = ctx.previousRunAt != null
            ? ctx.previousRunAt
            : Datetime.now().addHours(-24);

        List<Account> changed = [
            SELECT Id, Name
            FROM Account
            WHERE LastModifiedDate >= :since
            ORDER BY LastModifiedDate ASC
            LIMIT 200
        ];

        for (Account acc : changed) {
            // ... process ...
        }

        return StepResult.complete(null, changed.size());
    }
}
```

## Production workflow shape

Add a sleep step **after** the sync step to throttle the loop. The sleep is a
genuine async suspension — the Queueable slot is released and the watchdog
fires the wakeup after the configured interval.

```
SyncChangedAccountsStep  ──►  SleepStep  ──►  ContinueStep
         │                         │                 │
   queries records          StepResult.sleep()  StepResult.continueAsNew()
   since previousRunAt       (e.g. 300 s)        (clears heap/history)
```

**Keep the sync step first.** `previousRunAt` is the predecessor instance's
`CreatedDate` (its start time). When the sync step runs first, `CreatedDate` ≈
query time — overlap with the previous run is milliseconds. If you put the sleep
*before* the sync step, the overlap window grows to the full sleep duration: the
successor's cursor still points to the predecessor's start time, so it
re-queries everything from before the sleep too. Not incorrect (no gaps,
still at-least-once) but needlessly wasteful for long sleep intervals.

```java
public class SleepStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
        if (ctx.stepStateJson != null) {
            return StepResult.complete(null, 'awake');
        }
        return StepResult.sleep(300, 'sleeping'); // 5 minutes
    }
}

public class ContinueStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
        return StepResult.continueAsNew(null);
    }
}
```

`getNextStep` wires them together:

```java
public String getNextStep(String currentStepName, StepResult result) {
    if (currentStepName == 'MyPoller.SyncChangedAccountsStep') {
        return 'MyPoller.SleepStep';
    }
    if (currentStepName == 'MyPoller.SleepStep') {
        return 'MyPoller.ContinueStep';
    }
    return null; // ContinueStep returns continueAsNew, engine handles it
}
```

## Cold-start strategies

| Strategy | When to use |
|---|---|
| Fixed lookback (`addHours(-N)`) | Simple; acceptable to re-process some records on restart |
| Configurable lookback from input | When operators need to control the initial window |
| Process all records on first run | When initial sync is desired; use `LIMIT` + `OFFSET` or cursor fan-out |
| Skip first run entirely | Return `continueAsNew` immediately when `previousRunAt == null` |

## Querying `Previous_Run_At__c` directly

`previousRunAt` corresponds to the `Previous_Run_At__c` DateTime field on
`Workflow_Instance__c`. Operators can query it to audit the history of a
polling chain:

```sql
SELECT Id, Correlation_Key__c, Previous_Run_At__c, Status__c
FROM Workflow_Instance__c
WHERE Root_Correlation_Key__c = 'my-poller-key'
ORDER BY CreatedDate ASC
```

## `previousRunAt` vs. storing a timestamp in the payload

You could carry the high-water mark in `continueAsNew`'s input payload instead.
`previousRunAt` is preferable for most cases:

| | `ctx.previousRunAt` | payload timestamp |
|---|---|---|
| Source of truth | Engine-set; not forgeable | Step-set; must be correct |
| Available in | Every step of the successor run | Only if the step reads it from `workflowInputJson` |
| Visible in metadata | `Previous_Run_At__c` field | Buried in JSON payload |
| Works with sleep-then-continue | Yes — set at continue time | Yes, same behavior |

Use a payload timestamp if you need sub-run granularity (e.g. the timestamp
of the last processed record, not the run boundary).

## Full example

See [IncrementalSyncWorkflowExample](../examples/main/default/classes/IncrementalSyncWorkflowExample.cls)
and its [test class](../examples/main/default/classes/IncrementalSyncWorkflowExampleTest.cls).
