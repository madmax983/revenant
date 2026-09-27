# Detect Mid-Flight Definition Changes (Issue #89)

## Goal

Stop a plain `WorkflowDefinition` instance before it runs a step against a changed step list. Park the instance in `DefinitionChanged`. Let an operator release it.

## Brainstorming (options)

| # | Idea | Keep? |
|---|------|-------|
| B1 | Store a SHA-256 fingerprint of `getSteps()` on the instance at start. | Yes |
| B2 | Also store the step list (JSON) so the dashboard can show stored vs live steps. A hash cannot show the steps. | Yes |
| B3 | Fingerprint also covers `getInitialStep()`. | No. A new initial step does not affect an instance past its start. It adds false halts. |
| B4 | Probe `getNextStep()` with synthetic results to fingerprint routes. | No. Cost is high, author code can throw, and results are data-dependent. |
| B5 | Put the check in a trigger. | No. The check must run per hop, not per save. |
| B6 | Put the gate in `WorkflowStepRunner.runStepNamed`, after the compensation route, before the pause gate and concurrency admission. | Yes. Every forward hop goes through it. A stale delivery to a parked instance is not re-parked as `Paused`. |
| B7 | Stamp in a before-insert trigger as a catch-all. | No. The trigger does not have the definition object. Stamp at each creation site that already has it. |
| B8 | Prefix the fingerprint with an algorithm version (`v1:`). | Yes. A later algorithm change then gives "unknown", not a mass halt. |
| B9 | Normalize step names to lower case before the hash. | Yes. Apex type names and `==` are case-insensitive. A case-only edit does not change execution. |
| B10 | Release re-stamps the live fingerprint and shape, sets `Running`, re-arms timeouts, and enqueues. | Yes |
| B11 | Release refuses when a current step is not in the live `getSteps()`. | Yes. Release must not route into a missing step. The operator can cancel. |
| B12 | Bulk "release all" per workflow. | Service is bulk-safe. Dashboard gives a per-instance action. |

## Reverse Brainstorming (how can this fail?)

| Way to fail | Prevention |
|-------------|-----------|
| Every deploy halts all instances (false positive). | Hash only the ordered step names. Lower-case them. Skip a null or foreign-version fingerprint. |
| Old instances (null fingerprint) halt after upgrade. | Null means unknown. Unknown is advisory. |
| The gate throws and breaks the hot path. | Catch all errors in compute. Fail open. |
| The gate adds SOQL per hop. | Add one field to the existing instance query. Compute in memory. Cache the live fingerprint per transaction. |
| The halt marker row is reused as the step row. | The marker has its own step name (`Workflow_Definition_Changed`). |
| The halt marker feeds the next step input. | Marker status is `DefinitionChanged`, never `Completed`. |
| The marker is re-driven as a failed step. | Marker status is not `Failed`. |
| The watchdog times out the parked step. | Timeout sweep skips `DefinitionChanged` parents. Release re-arms timeouts. |
| Stall detection flags the parked instance. | Treat `DefinitionChanged` as a deliberate park. |
| A signal to a parked instance is lost. | Signal routing treats `DefinitionChanged` like `Paused` (hold the signal). |
| A duplicate start with the same key makes a second live run. | Add `DefinitionChanged` to the active sets. |
| The operator cannot stop a parked instance. | Cancel accepts `DefinitionChanged`. |
| Concurrency reconciler reclaims a parked slot. | Count `DefinitionChanged` as a slot holder. |
| Two parallel branches both park and write two markers. | Re-read the instance `FOR UPDATE` before park. Skip when already parked. |
| `VersionedWorkflow` instances halt. | Versioned mismatch is advisory only (debug log). |
| Compensation halts. | The compensation route runs before the gate. |

## Six Thinking Hats

- **White (facts):** `Definition_Version__c` is always `1` for plain definitions. No shape record exists. All in-repo `getSteps()` bodies are literal lists. `Paused` is the closest park pattern.
- **Red (feelings):** Operators fear silent corruption more than an extra click. A loud, clear park builds trust.
- **Black (risks):** New status values touch many status sets. A miss can strand or drop an instance. Review each set.
- **Yellow (benefits):** Safe deploys. Clear audit marker. No new SOQL in the hot path. No public API break.
- **Green (ideas):** Show stored vs live steps with added and removed steps marked. Guard release against a missing current step.
- **Blue (process):** RED tests first, then GREEN, then REFACTOR. Then a multi-angle review. Then map each AC to evidence.

## Decision Table (the spec)

`compare(stored, live, isVersioned)`:

| stored | live | same version prefix | equal | isVersioned | Verdict |
|--------|------|---------------------|-------|-------------|---------|
| blank | any | - | - | any | `UNKNOWN` (no halt) |
| any | blank | - | - | any | `UNKNOWN` (no halt) |
| set | set | no | - | any | `UNKNOWN` (no halt) |
| set | set | yes | yes | any | `MATCH` |
| set | set | yes | no | true | `ADVISORY` (log, no halt) |
| set | set | yes | no | false | `HALT` |

Invariants:

1. A `HALT` verdict runs zero steps in that delivery.
2. A park writes only one instance update and one appended marker row. It changes no prior step row and no `Compensation_Stack__c`.
3. A `DefinitionChanged` instance is not terminal. Release returns it to `Running`.

## Changes

- Schema: `Workflow_Instance__c.Definition_Fingerprint__c` (Text 80), `Definition_Shape__c` (Long Text 32768), `Status__c` value `DefinitionChanged`. `Workflow_Step_Execution__c.Status__c` value `DefinitionChanged`.
- `WorkflowDefinitionFingerprint`: pure compute, stamp, compare.
- `WorkflowDefinitionChangeGate`: hot-path check and park.
- `WorkflowDefinitionChangeService`: release and dashboard diagnosis.
- `WorkflowDefinitionChangeService.release(Id)`: public API. The 19-method `WorkflowEngine` facade stays unchanged.
- Stamp sites: start builder, child start, bulk child planner, continue-as-new, compensation instance (copy).
- Status sets: active, cancel, signal routing, stall, timeout sweep, catalog, drain, reconciler.
- Dashboard: status badge, filter, diagnosis panel, Release action.

## Verification

- Unit: fingerprint compute and the decision table (every row).
- Gate: plain mismatch parks; versioned mismatch runs; null runs; match runs; parked stale delivery is a no-op.
- AC test: mutate `getSteps()` between two hops. Assert `DefinitionChanged` and zero rows for the new step.
- Release: resumes and completes; refuses a missing current step; re-stamps the fingerprint.
- Controller and LWC jest tests for the diagnosis panel and Release action.
