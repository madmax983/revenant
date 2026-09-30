# Cooperative Cancellation Implementation Plan (Issue #143)

**Goal:** A long step loop sees that an operator cancelled its instance. The
step stops at its next check. The engine then ends the step cleanly.

**Architecture:** `StepContext.isCancellationRequested()` reads the
`Status__c` of the instance and of its ancestors. `StepCancellation` caches
the answer. `WorkflowCancelProbe` does the one SOQL read.
`WorkflowCooperativeCancel` handles the step result at the outcome seam.

**Tech stack:** Apex. No new object, field or event.

---

## 1. Brainstorming

- **Accessor on the context.** `ctx.isCancellationRequested()` stays next to
  `ctx.shouldYield()`. A hot loop calls both.
- **Status is the signal.** `Cancelled` and `Cancelling` mean "cancel
  requested". `cancel(id, true)` sets `Cancelling`. `cancel(id)` sets
  `Cancelled`.
- **Ancestors in the same read.** One SOQL reads the own status and five
  parent levels (the SOQL limit for a parent path). `cancel()` marks all
  active descendants in the same transaction. So a deeper descendant sees its
  own status.
- **Cache.** A `false` answer stays valid for a short time (default 1000 ms).
  A `true` answer stays for the rest of the run. An overload
  `isCancellationRequested(Integer maxAgeMillis)` lets the author tune the
  age. `0` reads each time.
- **Lazy.** A step that never calls the accessor pays 0 SOQL.
- **Seam contract.** The step returns any result after it sees the flag. The
  engine drops that result. It marks the step row `Cancelled`. It does not
  write `Completed`. It does not enqueue a forward hop. `cancel()` already
  started the rollback when the cancel asked for it.
- **Only a step that saw the flag.** A step that did not call the accessor
  keeps the old seam behavior (issue AC 5).
- **Ancestor only.** If an ancestor is cancelled but the instance is not, the
  seam cancels the instance with the same mode as the ancestor. Without this
  step, a loop that returns early on each run never ends.
- **No flag in `compensate()`.** A rollback must finish. A compensation
  context has no source, so the accessor gives `false`.
- **Test builder.** `StepContextTestBuilder.requestCancellation()` and
  `requestCancellationAfterChecks(n)` give a unit test the flag with 0 SOQL.

## 2. Reverse brainstorming (how can it fail?)

| Failure                                                             | Mitigation                                                                                                       |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| An author calls the accessor for each record. SOQL runs out.        | Cache of 1000 ms. No read when fewer than 20 queries remain. The doc says "check every N iterations".            |
| The accessor writes data.                                           | It only reads. A test asserts 0 DML and 1 SOQL for each read.                                                    |
| The seam throws for a cooperative step and the finalizer runs.      | The new seam branch returns before `assertInstanceRunnable`. A test asserts no throw.                            |
| The seam writes `Completed` for the abandoned step.                 | The branch skips the dispatch. A test asserts no `Completed` row for the step.                                   |
| The seam enqueues a forward hop after the cancel.                   | The branch skips the dispatch. `cancel()` owns the rollback hop.                                                 |
| A step that never checks changes behavior.                          | The branch runs only when the step saw `true`. A regression test keeps the old throw.                            |
| A loop sees an ancestor cancel, returns, and runs again forever.    | The seam cancels the instance with the ancestor mode.                                                            |
| A compensation stops half way because the instance is `Cancelling`. | A compensation context has no source. The flag is `false`.                                                       |
| Claimed parallel signals stay `Processing`.                         | The branch rolls back claimed signals, as the stale path does.                                                   |
| A stale in-memory step row overwrites fields.                       | The branch writes only `Status__c` on the step row.                                                              |
| The cancel cannot commit while the step runs (row locks).           | Known platform limit. See section 3 (Black hat) and ADR 0017. The flag still works for each cancel that commits. |

## 3. Six thinking hats

- **White (facts):** `cancel()` sets `Cancelled` or `Cancelling` and marks
  active step rows `Cancelled`. It reaps active descendants in the same
  transaction. At the seam, a step that returns on a cancelled instance throws
  `WorkflowException` today. The throw rolls back the step DML and runs the
  finalizer. No org is in this session, so Apex tests cannot run here.
  apex-ls compiles the code.
- **Red (feelings):** Operators want "stop" to mean stop. Authors do not want
  a new SOQL cost on each record.
- **Black (risks):** A running step holds its step row `FOR UPDATE` for all of
  `execute()`. `cancel()` locks the same row. In a real org, a cancel waits
  (10 seconds at most) for the running transaction to end. So the flag sees a
  cancel that commits while the step runs only when the cancel does not need a
  lock that the step holds. A lock-free cancel request needs a change to the
  cancel lock order. The issue puts that out of scope. ADR 0017 records it,
  with a follow-up.
- **Yellow (benefits):** A cooperative loop stops within one check interval
  after the cancel is visible. The seam no longer throws for it. The finalizer
  does not run. Authors get a test builder hook.
- **Green (ideas):** Later: a lock-free cancel request. A `Cancel` signal row
  that the probe also reads. A `StepResult.cancelled()` result.
- **Blue (process):** SPEC (rules below), RED (tests fail to compile in
  apex-ls), GREEN (code), REFACTOR (prettier, apex-ls), docs, then a
  multi-angle agent review.

## 4. Rules (spec)

Read rules for `isCancellationRequested(maxAgeMillis)`:

1. No source (compensation context, plain builder): `false`, 0 SOQL.
2. A `true` answer was seen before: `true`, 0 SOQL.
3. The last read is younger than `maxAgeMillis`: the cached answer, 0 SOQL.
4. Fewer than 20 SOQL queries remain: the cached answer, 0 SOQL.
5. Else: one SOQL read, 0 DML. `true` when the instance or one of its five
   nearest ancestors has `Cancelled` or `Cancelling`.

`null` or a negative `maxAgeMillis` means `0`. The no-argument call uses
1000 ms.

Seam rules, when the step saw `true`:

1. Instance is `Cancelled` or `Cancelling`: roll back claimed signals, set the
   step row to `Cancelled`, skip the dispatch.
2. Instance is runnable and an ancestor is cancelled: do rule 1, then cancel
   the instance. `Cancelling` ancestor: with compensations. `Cancelled`
   ancestor: without.
3. Else: the normal seam path.

## 5. Tasks

1. RED: `StepCancellationTest`, `WorkflowCancelProbeTest`,
   `WorkflowCooperativeCancelTest`, `CooperativeCancelWorkflowExampleTest`,
   builder tests, subscriber fixture use.
2. GREEN: `StepCancellation`, `WorkflowCancelProbe`,
   `WorkflowCooperativeCancel`, `StepContext`, `WorkflowStepContext`,
   `WorkflowOutcomePrepare`, `StepContextTestBuilder`, example.
3. REFACTOR: prettier, apex-ls, global API manifest.
4. Docs: `docs/cooperative-cancellation.md`, ADR 0017, README,
   `docs/strict-determinism.md`, `docs/step-context-test-builder.md`.
5. Review: agents for correctness, platform limits, API, tests and docs.

## 6. Review results

Four review agents (engine, platform limits, tests, docs) and the Codex PR
review found these issues. We fixed them:

- The SOQL guard read one more time when exactly the reserve was left. Now it
  reads only with more than the reserve. The reserve is 20, or 20% of the
  limit when that is more, the same point as `shouldYield()`.
- `isCancellationRequested(null)` meant 0, but the builder took null as the
  default. Now null means the default age in both.
- `requestCancellationAfter(n)` looked like a time value. It is now
  `requestCancellationAfterChecks(n)`.
- The example test with the test builder could not tell a cancel from a
  normal YIELD. It now uses `requestCancellation()` and asserts one batch.
- The example checked with the 1000 ms cache after each batch, so its second
  check was almost always cached. It now uses `isCancellationRequested(0)`.
- The abandoned step row got no telemetry. The seam now writes CPU, SOQL and
  heap with the status.
- New tests: a timed step, a non-runnable instance, an ancestor request that
  goes away before the seam, and seam unit tests (no context, no step row,
  a step row with no Id).
- The docs said the flag sees an operator cancel during a long loop. The
  engine inserts each step row before the run, and the running step locks
  it. So a cancel from another transaction does not commit while the step
  runs. The docs, the README and ADR 0017 now say this first, with a lock
  table.
- The docs did not say that the engine does not compensate the stopped step.
  They now say it.
- The docs named `WorkflowEngine.cancel(id, true)`, which is not `global`.
  They now name the Cancel Workflow action and the `Cancel` signal.

Open, for the owner: a cancel request that does not wait for the lock of the
running step row (Codex P1). The issue puts changes to `cancel()` and new
fields out of scope. ADR 0017 lists the options.
