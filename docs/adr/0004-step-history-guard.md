# ADR 0004: Step-history guard

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #112

## Context

Each step visit writes a step row. A loop without Continue-As-New adds rows to one instance without a limit. The runner reads step rows of the instance on each hop. At approximately 50,000 rows a query hits the query-row limit. The author gets a governor error with no clear cause. This can occur months later.

## Decision

1. Count the rows with `SELECT COUNT() ... LIMIT :ceiling`. One SOQL, one query row, no heap.
2. Run the count in `WorkflowStepRunner` after admission and the stale-parallel check, before the first full-history read.
3. Two values in `Revenant_Config__mdt`: `Step_History_Warn_Threshold__c` (5000) and `Step_History_Ceiling__c` (10000). Max 10000. `0` turns a check off.
4. Warn: one `Workflow_Log__c` row per instance, key `StepHistoryWarn:<instanceId>` in the unique `Fire_Key__c`. Write it after the step outcome. The dashboard reads it.
5. Ceiling: fail through `failWorkflowInstance` with the new category `STEP_HISTORY_LIMIT` and `skipErrorRouting = true`. With a compensation stack, the existing path compensates and keeps the category blank.
6. Exempt engine workflows.
7. Remove `Input__c` and `Output__c` from the visit-count query in `WorkflowStepExecLock`. In `WorkflowParallelJoin`, read the latest branch payloads by Id. These reads grow with history.
8. At the ceiling, close the open rows of the active steps (`Failed`, no timeout) and abort the scheduled jobs of the instance. Each failure path closes the open row. Else an armed timeout can fail a compensating saga.

## Consequences

- One SOQL on each hop that continues. A test that drives many hops in one transaction uses one more SOQL for each hop.
- From the warn threshold: one DML statement on each hop.
- No new field on a data object. One new picklist value.
- The guard inserts and deletes no step row. It changes no closed row and not the compensation stack. It closes the open rows of the active steps.
- The parallel join does one more SOQL.
- Compensation still runs after the ceiling.
- A fan-out wider than the gap can skip the warning.

## Rejected Options

- `COUNT()` with no `LIMIT`: the scan has no limit.
- A counter field on `Workflow_Instance__c`: many insert sites, races between parallel branches, a new data field.
- A warning checkbox on `Workflow_Instance__c`: a new data field. The log row is sufficient.
- A warning write before `execute()`: it blocks callouts.
- Error routing at the ceiling: the error step cannot run past the guard, so each hop adds a row and routes again.
