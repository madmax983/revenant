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
4. `StepCancellation` caches the answer. A `true` answer stays. A `false`
   answer stays for `maxAgeMillis` (default 1000). No read occurs with fewer
   than 20 SOQL queries left. The read is lazy: a step that does not call the
   flag pays nothing.
5. The engine gives a source only to `execute()`. In `compensate()`, the flag
   is `false`, so a rollback always finishes.
6. `WorkflowCooperativeCancel` runs at the seam, after the stale check, only
   when the step saw `true`. On a cancelled instance it drops the result,
   releases claimed signals and sets the step row to `Cancelled`. It skips the
   dispatch: no `Completed` row, no forward hop, no throw. `cancel()` already
   enqueued the rollback.
7. When only an ancestor is cancelled, the seam also cancels the instance, in
   the mode of the ancestor. Without this, a loop that returns early on each
   run never ends.
8. A step that did not see `true` keeps the old seam path (the throw).
9. The step result is dropped, but its DML commits. So at most one check
   interval of work commits after the cancel became visible.

## Row locks

A running step holds its step row `FOR UPDATE` for all of `execute()`.
`cancel()` locks the same row in `cancelActiveStepExecs`. A first run also
inserts the step row before `execute()`, and that insert locks the instance
(MasterDetail parent). So in an org, a `cancel()` that starts while a step
runs waits for the step transaction. After 10 seconds it fails with
`UNABLE_TO_LOCK_ROW`.

Effect: the flag sees a cancel only after the cancel commits. With the
current cancel lock order, that is mostly after the running transaction
ends. Then the next run stops at `runStep` before `execute()`. The seam
contract, the accessor and the tests are correct for each cancel that commits
while a step runs. For example, a cancel from inside the same transaction, or
a future cancel path that does not lock the running step row.

The issue puts changes to `cancel()` out of scope. A follow-up must let a
cancel commit without the lock of the running step row. Options: a cancel
request in two phases (write the status first, cancel the step rows later),
or a lock order where `cancel()` does not wait on the running row.

## Consequences

- An author gets one call and a test hook
  (`StepContextTestBuilder.requestCancellation()`,
  `requestCancellationAfter(n)`).
- The flag is not replay-safe. Use it only to return early
  ([strict-determinism.md](../strict-determinism.md)).
- A cooperative step no longer ends in a `WorkflowException` and a finalizer
  crash record.
