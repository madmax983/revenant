# ADR 0014: Debounced start

- **Status:** Accepted
- **Date:** 2026-09-30
- **Issue:** #140

## Context

A debounced start existed: `WorkflowDebouncer`, `Debounce_State__c`, a
heartbeat sweep and a Flow parameter. Five problems remained:

1. It was not `global`. A subscriber org could not call it from Apex.
2. The sweep read due rows without a lock. A trigger that re-armed a row
   between the read and the delete was lost.
3. Two transactions that armed a new key at the same time both inserted.
   The second insert failed with `DUPLICATE_VALUE`, and the record save
   failed.
4. `Fire_At__c` kept milliseconds. A DateTime field can drop them, so a
   row could fire before its window ended.
5. The sweep used `startOrGet`, which also matches a terminal instance in
   the dedup window (default 24 hours). A second burst on the same day
   went to the finished run, and its input was lost.

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
5. Start with an active-only bulk `startOrGet`. Each burst after a
   terminal run is a new run.
6. Run the sweep late in the heartbeat, before the global reconcile, so
   the row locks stay held for a short time.

## Consequences

- No new schema, no new scheduled job, no change to the Queueable chain.
- The sweep does 1 more SOQL query when rows are due.
- The arm path does 1 more DML statement when a call has both new and
  existing keys. A key that a parallel transaction inserted first costs 1
  more SOQL query and 1 more DML statement.
- A trigger that re-arms a due key during its sweep waits for the lock.
  After about 10 seconds, the save fails with `UNABLE_TO_LOCK_ROW`.
- A subscriber cannot set attributes or a causation id from Apex. Flow can.
  If you add them later, use `withAttributes(Map<String, String>)`, as
  `WorkflowEngine.StartRequest` does.
- The global surface grows by 7 lines. They are permanent.

## Alternatives

- `WorkflowEngine.startDebounced(name, key, input, seconds)`. Rejected: #204
  removed positional overloads from the engine.
- A delayed Queueable for each arm. Rejected: a burst of 50 makes 50 jobs.
- Store `maxWaitSeconds` on the row. Rejected: a new field is permanent
  schema. The last call's value applies.
