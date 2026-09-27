# ADR 0001: Auto-Retry Thrown Step Errors

- **Status:** Accepted
- **Date:** 2026-09-27
- **Issue:** #101

## Context

A step that throws fails the workflow on the first throw. A saga then rolls
back all completed steps. Retry is opt-in through `StepResult.retry(policy)`.

## Decision

1. Add the optional interface `AutoRetryConfigurable`. A `WorkflowStep` or a
   `WorkflowDefinition` can implement it.
2. The step policy overrides the definition policy. A `null` policy means
   "fail fast".
3. The engine catches a catchable exception only around `execute()`, and only
   when a policy exists. It converts the exception to
   `StepResult.retry(policy)`. The existing retry path does the rest.
4. The engine does not set a savepoint. DML that `execute()` did before the
   throw stays. This is the same as a manual `try/catch` that returns
   `retry()`.
5. When retries are exhausted, the step row gets
   `Auto-retry exhausted after N attempts: <message>` and the stack trace.
   The category is `RETRIES_EXHAUSTED`.

## Consequences

- No policy: behavior does not change.
- `LimitException` stays on the finalizer fail-fast path. Apex cannot catch it.
- A step with a policy must be safe to run again. Use `ctx.idempotencyKey`
  and `ctx.captures().once()`.
- No new field, no new picklist value, no new public API on `StepResult`.

## Rejected Options

- **Finalizer-based retry:** cannot tell a step error from an engine error.
  Loses captures.
- **Savepoint before `execute()`:** blocks callouts in plain steps.
- **Reuse `RetryConfigurable`:** changes existing step behavior.
