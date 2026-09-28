# Per-Instance Hold And Release (Issue #119)

## Goal

Let an operator stop one workflow instance at its next step boundary, then let it continue from the same step. Do not cancel it. Do not pause its definition.

## Facts About The Engine

- `WorkflowStepRunner.runStepNamed` runs gates in this order: finished check, compensation route, definition-change park (#89), pause park (#36), concurrency admission. All gates run before the step row lock.
- The runner loads the instance with no lock. Many outcome paths later update that same record. Apex DML writes each field that the query loaded. A stored field in that query can overwrite a newer value from another transaction.
- Apex DML ignores formula fields and other read-only fields in a loaded record.
- `Paused` and `DefinitionChanged` are park statuses. The engine puts them in these status lists: active and dedup, key reservation, signal lookup, cancel, bulk cancel, catalog, version drain, stall, unrouted signals, timeout sweep exclusion, test harness, parallel join.
- A signal to a parked instance stays `Received`. The step reads it when it runs again.
- `WorkflowDefinitionChangeService.release` shows a safe release: lock, set `Running`, re-arm step timeouts, enqueue the serial step or each open parallel branch.
- The watchdog orphan sweep re-drives only `Running` rows. The stall scan reads only forward statuses.
- Continue-As-New marks the old instance `ContinuedAsNew` and inserts a new one.
- This container has no Salesforce org. Apex tests cannot run here. Prettier parses Apex. Jest runs the LWC tests.

## Brainstorming (options)

| # | Idea | Keep? |
|---|------|-------|
| B1 | Status `Held` only. Hold sets it at once. | No. A step can be in flight. Its outcome writes `Running` and the hold is lost. |
| B2 | Fields only. Status does not change. | No. A parked `Running` row looks like an orphan. The watchdog re-drives it each sweep. |
| B3 | Fields keep the hold. The gate sets status `Held` when the chain stops. | Yes. The fields are the request. The status is the park. |
| B4 | Separate hold object, keyed by instance Id. | No. One more SOQL on each hop. |
| B5 | Reuse `WorkflowPauseGate` with an instance key. | No. AC 1 forbids it. |
| B6 | Stored fields `Held_At__c` and `Hold_Reason__c`. Formula checkbox `Held__c` = `Held_At__c` is set. The runner loads only the formula. | Yes. No SOQL on the hot path. An outcome update cannot overwrite a hold made during the step. |
| B7 | Gate after the definition-change gate, before the pause gate. | Yes. A changed definition parks first. A hold never reads pause state. |
| B8 | Park: lock `FOR UPDATE`, check the hold again, abort scheduled jobs, set `Held`, clear sleep markers, write one log row. No step row. | Yes. Same as the #89 park, without the marker row. |
| B9 | Release of a parked instance: clear the hold, set `Running`, re-arm timeouts, enqueue. Release of a hold that did not park yet: clear the hold only. | Yes. No second driver. |
| B10 | Outcome enum, no exception for expected states. | Yes. AC 6 and AC 7. |
| B11 | Reject a hold on an engine workflow. | Yes. A held watchdog stops the engine. |
| B12 | Reject a hold on `Compensating`, `Cancelling`, `CompensationFailed`. | Yes. The gate is on the forward path only. The hold would have no effect. |
| B13 | Trigger clears the hold when the status leaves the forward path. | Yes. A cancelled or failed row never shows as held. |
| B14 | Continue-As-New copies the hold to the successor. | Yes. A loop at a Continue-As-New boundary must stay held. |
| B15 | Release the concurrency slot at park. | No. `Paused`, `DefinitionChanged` and sleeps keep the slot. A new mid-flow admission path is a risk. Documented. |
| B16 | Dashboard: status filter, badge, panel with reason and held-since, Hold and Release buttons. | Yes. AC 8. |
| B17 | Bulk hold, timed release. | No. Out of scope. |

## Reverse Brainstorming (how can this fail?)

| Way to fail | Prevention |
|-------------|-----------|
| An outcome update writes an old hold value back. | The runner loads only the formula `Held__c`. DML ignores it. |
| Release enqueues a second driver while the chain is live. | Release enqueues only from status `Held`. |
| The gate and release race. | Both lock the instance. The gate checks `Held_At__c` again under the lock. |
| The watchdog re-drives a held row as an orphan. | Status `Held` is not `Running`. |
| A stall alert fires for a held row. | `Held` is not a stall status. The scan skips `Held__c` rows. |
| A signal is lost while held. | `Held` is in the signal lookup lists. The signal stays `Received`. |
| A timeout fails a held step. | Park aborts scheduled jobs. The sweep skips `Held` parents. The timeout job and sweep keep a `Pending` step while the hold waits for the gate. Release re-arms. |
| The hold escapes through Continue-As-New. | Copy the hold to the successor. |
| A hold stops the watchdog. | Reject engine workflows. |
| A hold on a terminal row writes `Terminal_At__c`. | Reject before any DML. |
| A cancelled row still shows as held. | The trigger clears the hold. |
| Dedup starts a second run while one is held. | `Held` is an active status. The key stays reserved. |
| A parallel branch overwrites the park. | The parallel join keeps `Held`. |
| The test harness loops on a held row. | `Held` is a parked status in the harness. |
| A long reason fails the update. | Truncate to 255 characters. |
| A user with no operator permission holds a row. | The dashboard endpoint checks `Workflow_Operator_Action`. |

## Six Thinking Hats

- **White (facts):** Two park statuses exist. The #89 park is the model. No org is available, so Apex tests are compile-level only here.
- **Red (feelings):** Operators want a safe, reversible button. They fear a lost hold and a double run.
- **Black (risks):** Stale overwrite. Double enqueue. Watchdog loops. Timeouts. Schema change in deployed orgs (additive only). A held row keeps its concurrency slot.
- **Yellow (benefits):** No SOQL on the hot path. No scheduled job. No step row. Siblings do not change.
- **Green (ideas):** Carry the hold across Continue-As-New. Show "hold waiting" before the park.
- **Blue (process):** Plan. ADR. RED tests. GREEN code. REFACTOR. Multi-angle review. Map each AC to evidence.

## Spec

`hold(instanceId, reason)`:

| Instance state | Outcome | Writes |
|----------------|---------|--------|
| not found | `NOT_FOUND` | none |
| already held | `ALREADY_HELD` | none |
| terminal | `REJECTED_TERMINAL` | none |
| `Compensating`, `Cancelling`, `CompensationFailed` | `REJECTED_COMPENSATING` | none |
| engine workflow | `REJECTED_ENGINE_WORKFLOW` | none |
| other | `HELD` | `Held_At__c`, `Hold_Reason__c`, one log row |

`release(instanceId)`:

| Instance state | Outcome | Writes |
|----------------|---------|--------|
| not found | `NOT_FOUND` | none |
| not held, not `Held` | `NOT_HELD` | none |
| status `Held` | `RELEASED` | clear hold, `Running`, re-arm, enqueue, log |
| held, status not `Held` | `RELEASED` | clear hold, log |

Gate `parkIfHeld(instance)`:

| Loaded status | `Held__c` | Locked row | Result |
|---------------|-----------|------------|--------|
| `Held` | any | not read | stop |
| other | false | not read | continue |
| other | true | hold cleared | continue |
| other | true | not `Pending`, `Running`, `Suspended` | stop |
| other | true | held, parkable | park, stop |

## Tasks

1. RED: `WorkflowInstanceHoldTest` (Apex) and jest tests. Stubs compile, tests fail.
2. GREEN: fields, picklist value, gate, service, engine API, status lists, trigger, Continue-As-New, timeouts, stall, dashboard.
3. REFACTOR: shared engine-workflow check, docs, ADR 0006.
4. Review from several angles. Fix findings.
5. Map each AC to evidence.
