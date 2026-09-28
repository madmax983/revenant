# Detect Divergent Step Re-Execution (Issue #102)

## Goal

Stop a step that makes a different routing decision when it runs again with the same inputs. Fail the instance with the category `STEP_NON_DETERMINISM`. Do this before the engine writes the divergent decision.

## Facts About The Engine

- Each entry into a step writes a new `Workflow_Step_Execution__c` row. A loop back to a step makes a new row.
- A step runs again on the same row only after a wait or a transient result: `SUSPEND`, `WAIT_FOR_APPROVAL`, `START_CHILD`, `START_CHILDREN`, `SLEEP`, `YIELD`, `RETRY`.
- `COMPLETE`, `SPLIT`, `FAIL` and `CONTINUE_AS_NEW` close the row. A closed row does not run again.
- A crash rolls back the full transaction. The engine records no decision from a crashed run.
- Signals carry approval, child outcome and plain signal events. A resume carries its payload in the step state (`Output__c`).
- The compensation push occurs only on `COMPLETE`. The step type sets it.

Thus, the only durable decision that a later run can contradict is a wait decision.

## Brainstorming (options)

| # | Idea | Keep? |
|---|------|-------|
| B1 | Compare each re-run with the first `COMPLETE` of the row. | No. A row has one `COMPLETE`. Nothing to compare. |
| B2 | Record the decision of each wait. Compare the next run when its inputs did not change. | Yes. Same inputs must give the same decision. |
| B3 | Compare every re-run after a wait, also after a new signal. | No. A new signal is a legal reason to change the decision. False positives. |
| B4 | Run `execute()` two times in strict mode and compare. | No. Double side effects and callouts. |
| B5 | Inputs digest: stored input, previous output and step state; attempt; timeout-resume flag; live signal counts; newest signal; child status counts. | Yes. Three SOQL in strict mode only. |
| B6 | Put captures (`once()`) in the inputs digest. | No. Captures are stable by contract. A first capture would hide every check. |
| B7 | Put step state (`stepStateJson`) in the inputs digest. | Yes (changed after review). A resume payload arrives as step state. Without it, a resume is a false positive. |
| B8 | Decision text covers routing only: action, next step hint, split targets, child targets, approval key and role, timeout route, compensation flag. Each value is JSON. | Yes. Payloads and durations are not routing (out of scope). JSON stops a delimiter collision. |
| B9 | Sort split targets and child targets in the fingerprint. | Yes. An unordered query must not give a false positive. |
| B10 | New field `Workflow_Step_Execution__c.Decision_Record__c`. | Yes. Read in the existing `FOR UPDATE` query. The wait handler saves it. No new SOQL. No new DML. |
| B11 | Store the record in a reserved capture key. | No. It couples to the capture codec and to capture persistence. |
| B12 | On divergence, use a savepoint and roll back the step DML. | No. A savepoint blocks callouts. Step side effects are out of scope. |
| B13 | On divergence, fail through `failWorkflowInstance`. | Yes. This path also applies error routing (#90) and compensation. |
| B14 | Do not publish the step's buffered events on divergence. | Yes. The events belong to the divergent decision. |
| B15 | An operator retry, a parallel re-drive, a resume with a payload and a definition-change release clear the record. | Yes. Each one accepts a new decision. |
| B16 | A thrown error, `RETRY`, `SLEEP` and `YIELD` are not decisions. Skip the check and keep the record. | Yes. |
| B18 | Digest the stored (encoded or offloaded) forms, not decoded payloads. | Yes. No plaintext digest. Less heap. |
| B17 | Config: `Revenant_Config__mdt.Strict_Determinism__c`, default off. Read in the existing static config query. | Yes. |

## Reverse Brainstorming (how can this fail?)

| Way to fail | Prevention |
|-------------|-----------|
| Strict mode off still costs SOQL or CPU. | One static Boolean check. No query. The field read uses the existing query. |
| A resume payload looks like no new input. | Step state is an input. The resume service also clears the record. |
| A step retries or sleeps on a duplicate run. | `RETRY`, `SLEEP` and `YIELD` are not decisions. |
| The signal query counts all history rows. | Count live signals only. Read the newest signal with `LIMIT 1`. |
| Two different child lists give the same text. | Each value is JSON. |
| A new signal arrives and the step moves on. The guard fails it. | The signal status counts change. The guard does not compare. |
| A signal arrives during the run. The guard records it but the step did not see it. | Take the inputs digest before `execute()`. The next run then has other inputs, so no compare. |
| A parallel branch claims signals, then suspends. | The suspend handler rolls back the claim. Counts are equal again. This is correct: nothing new arrived. |
| A sibling branch consumes a signal. | Counts change. No compare. Safe. |
| A `once()` value makes the second run differ. | Captures are not inputs. The captured value is the same, so the decision is the same. |
| Two runs list the same children in another order. | Sort targets in the fingerprint. |
| A timed wait fires its deadline. | The timeout-resume flag is an input. No compare. |
| A retry changes `ctx.attempt`. | The attempt is an input. |
| A poller sleeps until an external record changes. | `SLEEP`, `YIELD` and `RETRY` are not decisions. |
| The divergent decision reaches the audit trail or the stack. | Check in the outcome seam before dispatch. |
| An operator retry fails again forever. | Retry clears the record. |
| A stale completion is failed. | The stale guard runs first. |
| A long child list overflows the field. | Store SHA-256 digests. Keep only a short summary text. Field length 4000. |

## Six Thinking Hats

- **White (facts):** Rows are per visit. Only waits re-run with a recorded decision. Signals carry all wake events. The harness re-runs the current step at `Test.stopTest()`.
- **Red (feelings):** Authors want the engine to fail in staging, not to corrupt a saga in production. A false failure breaks trust.
- **Black (risks):** A false positive breaks trust. Put all inputs in the digest. Compare only when it is equal.
- **Yellow (benefits):** Catches the "branch on live data, then wait" error before it routes. No cost when off. No public API change.
- **Green (ideas):** Show the recorded and the new decision in the error text. Clear on operator retry.
- **Blue (process):** Plan. RED tests with stubs. GREEN code. REFACTOR. Multi-angle review. Map each AC to evidence.

## Decision Table (the spec)

`verify(record, inputs, decision)`:

| Strict | Not a decision | Record | Inputs equal | Decisions equal | New action | Result |
|--------|--------------|--------|--------------|-----------------|------------|--------|
| off | any | any | - | - | any | Pass. Clear the record in memory. |
| on | yes, or `RETRY`, `SLEEP`, `YIELD` | any | - | - | any | Pass. Keep the record. |
| on | no | none | - | - | wait | Pass. Record the new decision. |
| on | no | set | no | - | wait | Pass. Record the new decision. |
| on | no | none or set | no | - | not a wait | Pass. Clear the record. |
| on | no | set | yes | yes | any | Pass. |
| on | no | set | yes | no | any | **Divergence.** |

Invariants:

1. A divergence writes no new step row and no compensation push.
2. A divergence fails the instance with `STEP_NON_DETERMINISM`, or routes to the error step.
3. A divergence publishes no buffered step event.
4. Strict mode off adds 0 SOQL and 0 DML.

## Changes

- Schema: `Workflow_Step_Execution__c.Decision_Record__c` (Long Text 4000). `Revenant_Config__mdt.Strict_Determinism__c` (Checkbox, default off). `Failure_Category__c` value `STEP_NON_DETERMINISM`.
- `WorkflowDecisionFingerprint`: pure decision text, digest and record codec.
- `WorkflowDeterminismGuard`: inputs digest, verify, fail path.
- `WorkflowStepInvoke`, `WorkflowStepOutcome`, `WorkflowStepExecLock`, `WorkflowRetryService`, `WorkflowResumeService`, `WorkflowBulkResumeService`, `WorkflowOperatorSkipParallelResume`, `WorkflowDefinitionChangeService`: hooks.
- `WorkflowEngine`: config flag and category constant.
- Dashboard: category label and filter.
- Docs: feature doc, ADR 0003, README, ARCHITECTURE.
