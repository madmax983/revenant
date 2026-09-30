# ADR 0017: Cooperative cancellation

- **Status:** Accepted
- **Date:** 2026-09-30
- **Issue:** #143

## Context

`WorkflowEngine.cancel()` writes `Status__c = Cancelled` (or `Cancelling`
with a rollback). A running step could not see this. A long loop ran to the
end of its batch after the cancel. Then the seam rejected its result with a
`WorkflowException`, and the finalizer ran.

## Decision

1. `StepContext.isCancellationRequested()` and
   `isCancellationRequested(Integer maxAgeMillis)` are `global` (additive, see
   [ADR 0006](0006-frozen-global-api.md)). They are on the context, next to
   `shouldYield()`.
2. The signal is the existing status. `Cancelled` or `Cancelling` on the
   instance or on one of its five nearest ancestors means "cancel requested".
   No new object, field or event.
3. `WorkflowCancelProbe` reads it with one SOQL and 0 DML. Five levels is
   the SOQL limit for a parent path. `cancel()` marks all active descendants
   in the same transaction, so a deeper descendant sees its own status.
4. `StepCancellation` caches the answer. It keeps a `true` answer. It keeps
   a `false` answer for `maxAgeMillis` (default 1000; null means the default).
   It does not read when the SOQL queries left are not more than the reserve:
   20, or 20% of the limit when that is more. At 20%, `shouldYield()` also
   gives true. The read is lazy: a step that does not call the flag pays
   nothing.
5. The engine gives a source only to `execute()`. In `compensate()`, the flag
   is `false`, so a compensation always finishes.
6. `WorkflowCooperativeCancel` runs at the seam, after the stale check, only
   when the step saw `true`. On a cancelled instance it drops the result,
   releases the claimed signals and sets the step row to `Cancelled`. It skips
   the dispatch: no `Completed` row, no forward hop, no throw. `cancel()`
   already enqueued the compensations.
7. When only an ancestor is cancelled, the seam also cancels the instance, in
   the mode of the ancestor. Without this, a loop that returns early on each
   run never ends. This cancel runs in the step transaction. A lock error
   rolls back the transaction, and the engine runs the step again.
8. A step that did not see `true` keeps the old seam path (the throw).
9. The seam drops the step result, but the step DML commits. After the check
   that sees the request, the step does no more work. The engine does not
   compensate the stopped step, because it did not complete. This is the same
   as a cancel between two runs of a yielding step.

## Row locks

`cancel()` locks the instance (`lockInstances`) and then the active step rows
(`cancelActiveStepExecs`). The engine inserts the step row before each run:
`start()` and each advance insert a `Pending` row. A running step locks that
row `FOR UPDATE` (`WorkflowStepExecLock`) until its transaction ends.

| Run of the step                   | Locks during `execute()`                                                 | Cancel from another transaction                                                                                                                                         |
| --------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Each run                          | Step row (`FOR UPDATE`). The instance is not locked.                     | Locks the instance, then waits for the step row. At the seam the step waits for the instance. The two transactions take the locks in opposite order, so one side fails. |
| A timed run (not a `CalloutStep`) | Also the instance: the step row update before `execute()` (MasterDetail) | Waits at the instance: 10 seconds at most, then `UNABLE_TO_LOCK_ROW`.                                                                                                   |
| A run with a concurrency ceiling  | Also the instance (`FOR UPDATE` in admission)                            | Waits at the instance, as above.                                                                                                                                        |

Effect: in an org, a request from another transaction does not commit while
a step runs. So today the flag sees a request during `execute()` only when it
comes from the same transaction. After the running transaction ends, the
request commits, and the next run stops before `execute()`. The accessor, the
seam contract and the tests are correct for each request that commits while
a step runs. They are ready for a cancel path that does not lock the running
step row.

The lock order of `cancel()` existed before this change. This change does not
make it worse. The issue puts changes to `cancel()` and new fields out of
scope. A follow-up must let a cancel request commit without the lock of the
running step row. Options:

- A cancel request in two phases: write the status first, and cancel the step
  rows in a later transaction.
- A `cancel()` that does not lock a running step row, and a seam or a sweep
  that sets that row to `Cancelled` later.

## Consequences

- An author gets one call and a test hook
  (`StepContextTestBuilder.requestCancellation()`,
  `requestCancellationAfterChecks(n)`).
- The flag is not replay-safe. Use it only to return early
  ([strict-determinism.md](../strict-determinism.md)).
- A cooperative step no longer ends in a `WorkflowException` and a finalizer
  crash record.
- The stopped step keeps its partial work. Authors must make each batch safe
  to keep.
