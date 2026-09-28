# ADR 0004: Cancel Workflow invocable action

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #107

## Context

Flow Builders could cancel a workflow only through **Signal Workflow** with the
internal signal name `Cancel` and a JSON payload. A wrong name does nothing and
shows no error.

The engine cancel is set-based per call, but the keyed-cancel batch path calls
it one time for each row. A second compensating cancel on a `Cancelling`
instance starts the rollback again.

Issue #107 says that a cancel with rollback ends `Compensated`. The engine ends
it `Cancelled`. It does this on purpose: the `Cancelled by user` marker keeps
the cancel phase through a resumed rollback.

## Decision

1. Add `WorkflowCancelInvocableAction` (label **Cancel Workflow**, category
   **Revenant Workflows**).
2. Find the instance with `WorkflowStatusInvocableAction.resolveInstances`.
   Get Workflow Status uses the same code.
3. Add the set-based entries `WorkflowCancellation.cancelInstances` and
   `cancelWithCompensationsInstances`. They use the same `collectActiveTree`
   and `cancelNodes` as `WorkflowEngine.cancel`. The rollback entry skips
   nodes in `Cancelling` or `Compensating`.
4. A keyed row writes the claim tombstone of `claimKeyedCancel` (shared
   `WorkflowSignalBatchCancel.buildCancelClaim`). All claims go in one DML.
5. Keep the engine terminal state. A cancel with rollback goes `Cancelling`,
   then `Cancelled`. Each rolled-back step row is `Compensated`. The action
   returns `isCompensating` so that a Flow can see that the rollback runs.
6. Add the public overload `WorkflowEngine.cancel(Id, Boolean)`. Null means
   `true`, the same as the action and the Cancel signal.
7. A row is a candidate when its instance is live and, for a rollback row, not
   already rolling back. The action writes the claims first. The first
   candidate row per instance whose key is not a duplicate is the owner.
8. The hard-stop call runs before the rollback call. `cancelled` is true only
   when the row's own group call cancelled its root.

## Consequences

- One declarative action. No internal signal name. No JSON.
- SOQL and DML statements do not grow with the row count. DML rows do: about
  5 per rollback row. The limit is 10,000 rows.
- A repeat with rollback does not run the rollback two times, with or without
  a key.
- A repeat without rollback on a `Cancelling` instance stops the rollback.
  This is the "hard stop" of the engine cancel.
- Idempotency keys are shared with all keyed signals, not only Cancel.
- A key follows at most 50 `ContinuedAsNew` generations (shared resolver).
- If the instance continues as new between the read and the lock, the row
  returns `cancelled=false` and status `ContinuedAsNew`. A retry finds the
  successor.
- The action runs in system mode with no custom-permission check, the same as
  Signal Workflow. Apex class access controls use.
- The invocable contract is permanent. Change it only by adding fields.
- The AC text "terminal state `Compensated`" is not met as written. The owner
  accepted this deviation.
