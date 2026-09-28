# ADR 0006: Per-instance hold and release

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #119

## Context

An operator can cancel one instance or pause one definition. Cancel is destructive. A definition pause stops all sibling instances. An operator needs to stop one instance at a safe point and then let it continue.

## Decision

1. API: `WorkflowInstanceHold.hold(instanceId, reason)` and `WorkflowInstanceHold.release(instanceId)`. Each returns a `HoldResult` with an `Outcome`. Expected states do not throw. `WorkflowEngine` is at the PMD `ExcessivePublicCount` limit (19 of 20). The definition pause API is also outside `WorkflowEngine`, on `WorkflowPauseGate`.
2. Schema on `Workflow_Instance__c`: `Held_At__c` (DateTime), `Hold_Reason__c` (Text 255), formula checkbox `Held__c` (`Held_At__c` is set), and the status value `Held`.
3. Hold writes only `Held_At__c` and `Hold_Reason__c`. It does not change the status.
4. `WorkflowInstanceHoldGate.parkIfHeld` runs in `WorkflowStepRunner` after the definition-change gate and before the pause gate. On a held instance it locks the row, aborts the scheduled jobs, and sets status `Held`. It writes no step row.
5. The runner loads only the formula `Held__c`. DML ignores formula fields, so an outcome update cannot overwrite a hold made during a step.
6. Release from `Held`: clear the hold, set `Running`, re-arm step timeouts, enqueue the step (or each open parallel branch). Release before the park: clear the hold only.
7. `Held` joins the park status lists of `Paused` and `DefinitionChanged`.
8. The trigger clears the hold when the status leaves the forward path.
9. Continue-As-New copies the hold to the successor.
10. Hold rejects terminal, compensating and engine-workflow instances.

## Consequences

- No SOQL and no DML on a hop that is not held.
- No scheduled job. Park aborts the scheduled jobs of the instance. Release re-arms step timeouts.
- A held instance keeps its concurrency slot, the same as `Paused`, `DefinitionChanged` and a sleep.
- Held rows keep their correlation key.
- A hold does not apply to compensation or to child instances.
- The schema change is additive: three fields and one picklist value.

## Rejected Options

- Status `Held` set at once by `hold`: an in-flight step outcome writes `Running` and loses the hold.
- Fields only, no status: a parked `Running` row looks like an orphan to the watchdog.
- A separate hold object: one more SOQL on each hop.
- An instance key in `WorkflowPauseGate`: the issue forbids it.
- `hold` and `release` on `WorkflowEngine`: the class then has 21 public members (PMD `ExcessivePublicCount`).
- Release of the concurrency slot at park: a new mid-flow admission path. Other parks keep the slot.
