# ADR 0014: Debounced start

- **Status:** Accepted
- **Date:** 2026-09-30
- **Issue:** #140

## Context

A debounced start existed: `WorkflowDebouncer`, `Debounce_State__c`, a
heartbeat sweep and a Flow parameter. Four gaps stayed:

1. It was not `global`. A subscriber org could not call it from Apex.
2. The sweep read due rows without a lock. A trigger that re-armed a row
   between the read and the delete was lost.
3. Two transactions that armed a new key at the same time both inserted.
   The second insert failed with `DUPLICATE_VALUE`, and the record save
   failed.
4. `Fire_At__c` kept milliseconds. A DateTime field can drop them, so a
   row could fire before its window ended.

## Decision

1. Make `WorkflowDebouncer` and `DebounceRequest` `global`. Expose only the
   constructor, `withDebounce`, `withMaxWait` and two `startDebounced`
   overloads. Keep the request-object shape of #204. Do not add
   `WorkflowEngine.startDebounced`.
2. Sweep in two steps: find due Ids in order, then lock them with
   `FOR UPDATE` and read them again. Skip a row that is no longer due.
3. Insert new rows with `allOrNone = false`. On `DUPLICATE_VALUE`, lock the
   other row and apply the request to it.
4. Round `Fire_At__c` up to the next whole second.

## Consequences

- No new schema, no new scheduled job, no change to the Queueable chain.
- The sweep does 1 more SOQL query when rows are due.
- The arm path does 1 more DML statement when a call has both new and
  existing keys.
- A trigger that re-arms a key during its sweep waits for the lock.
- The global surface grows by 7 lines. They are permanent.

## Alternatives

- `WorkflowEngine.startDebounced(name, key, input, seconds)`. Rejected: #204
  removed positional overloads from the engine.
- A delayed Queueable for each arm. Rejected: a burst of 50 makes 50 jobs.
- Store `maxWaitSeconds` on the row. Rejected: a new field is permanent
  schema. The last call's value applies.
