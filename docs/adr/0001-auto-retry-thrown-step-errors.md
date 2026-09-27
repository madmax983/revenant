# ADR 0001: Auto-Retry Thrown Step Exceptions

- **Status:** Accepted
- **Date:** 2026-09-27
- **Issue:** #101

## Context

A step that throws an exception fails the workflow on the first throw. A saga
then rolls back all completed steps. Retry is opt-in through
`StepResult.retry(policy)`.

## Decision

1. Add the optional interface `AutoRetryConfigurable`. A `WorkflowStep` or a
   `WorkflowDefinition` can implement it.
2. A step policy has priority over a definition policy. A `null` step policy
   means "fail fast". A policy getter that throws means "no policy".
3. The engine catches a catchable exception only around `execute()`, and only
   when a policy exists. It changes the exception to
   `StepResult.retry(policy)`. The existing retry path does the rest.
4. The engine sets a savepoint before `execute()` and rolls back to it on a
   thrown exception. This undoes the step DML, as a crash does.
5. A `CalloutStep` gets no savepoint, because a savepoint prevents a callout.
   DML that a `CalloutStep` does before the throw stays. A plain step that
   makes a callout gets "uncommitted work pending". The engine then fails fast
   and tells the author to implement `CalloutStep`.
6. These exceptions do not use auto-retry:
   - A row-lock error (`UNABLE_TO_LOCK_ROW`). It keeps its own retry path.
   - An exception in a timeout fallback run. A retry loses the timeout marker.
   - `LimitException`. Apex cannot catch it.
7. Each retried attempt writes a Warn log (`Workflow_Log__c`, type
   `AutoRetry`).
8. When all attempts fail, the step row gets
   `Auto-retry exhausted after N attempts: <message>` and the stack trace.
   N is `Retry_Count__c`. The category is `RETRIES_EXHAUSTED`.

## Consequences

- No policy: no `try/catch` and no savepoint. The throw fails fast as before.
- The engine creates the definition object once for each transaction to find
  its policy.
- Every other catchable exception uses auto-retry. This includes
  `WorkflowEngine.WorkflowException` from a `StepContext` API.
- Explicit and auto retries share one `Retry_Count__c` budget.
- A thrown exception of a `CircuitBreakerGuarded` step now counts as a breaker
  failure.
- The policy does not apply to `compensate()`.
- No new field, no new picklist value, no new method on `StepResult`.

## Rejected Options

- **Finalizer-based retry:** cannot tell a step exception from an engine
  exception. Loses captures.
- **No savepoint:** partial step DML stays after the retry and after
  compensation. This is less safe than a crash.
- **Reuse `RetryConfigurable`:** changes existing step behavior.
