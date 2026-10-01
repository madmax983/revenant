# ADR 0003: Strict determinism mode

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #102

## Context

The engine runs `execute()` again after each wait. A step that routes on
data that changes can make a different decision on the next run. Capture-once
(`once()`) prevents this, but only when the author uses it. The engine does
not detect this error.

Each entry into a step writes a new step row. `COMPLETE`, `SPLIT`, `FAIL` and
`CONTINUE_AS_NEW` close the row. A crash rolls back the full transaction.
Thus the only durable decision that a later run can contradict is a wait
decision.

## Decision

1. Add `Revenant_Config__mdt.Strict_Determinism__c`. Default: off. The engine
   reads it in the existing static config query.
2. When the mode is on, digest the step inputs before `execute()`: the
   stored step input, previous output and step state, the attempt, the
   timeout-resume flag, the live signals (Id, status, stored name and stored
   payload) and the child count for each status. Two SOQL queries (three over 200 live
   signals).
3. Build a decision text from routing data only. Each value is JSON. Sort
   split and child targets.
4. Record a wait decision and its inputs digest in the new field
   `Workflow_Step_Execution__c.Decision_Record__c`. The wait handler saves it.
5. When a run has the same inputs as the record and a different decision,
   it is a divergence. `RETRY`, `SLEEP`, `YIELD` and a thrown error are not
   decisions: keep the record. Clear the record when the inputs changed and
   the decision is not a wait.
6. Before a divergence, read the inputs again. An input that arrived during
   the run makes the new decision legal. Over 1,000,000 payload characters,
   the inputs are unknown: no compare, keep the record.
7. Handle a divergence in the outcome seam, after the re-lock and the stale
   guard, before the dispatch. Fail the step row, write an Error log row
   (`StepNonDeterminism`) and call `failWorkflowInstance` with the new
   category `STEP_NON_DETERMINISM`.
8. Clear the record on an operator retry, a parallel re-drive, a
   definition-change release and a run with the mode off. A resume payload
   is step state, so it changes the inputs. A resume without a payload keeps
   the record.

## Consequences

- Off: no SOQL, no DML. One Boolean check for each run.
- On: two SOQL queries for each run. No extra DML, except on a divergence.
- Error routing (#90) and compensation handle a divergence as they handle
  other failures.
- A `Compensated` instance keeps a blank category. This behavior does not
  change. The log row keeps the category.
- A waiting step must repeat the same wait until a new input arrives.
- The mode finds a divergence only when the inputs are equal. After a wait
  that writes step state, it compares from the second duplicate run.

## Rejected Options

- **Compare with the first `COMPLETE`:** a row has only one.
- **Compare after a new signal:** a new signal is a legal reason to change.
  False positives.
- **Run `execute()` two times:** double side effects and callouts.
- **Leave step state out of the inputs:** a resume payload arrives as step
  state. False positives.
- **Put captures in the inputs:** a first capture would stop every compare.
- **Digest decoded payloads:** a readable digest of plaintext defeats the
  payload codec. It also costs heap.
- **Savepoint and rollback of the step DML:** a savepoint blocks callouts.
  Side effects are out of scope.
- **Store the record in a reserved capture key:** couples to the capture
  codec and persistence.

## Hardening (issue #256)

Fixed:

- A live signal edit is a new input. The digest holds the stored name and
  payload. A trigger that blocks edits was rejected: it blocks a legal admin
  edit.
- Children use one aggregate query. No cap, no unknown inputs.
- Over 200 live signals, the digest holds the first rows (by Id) and the
  total count. `SystemModstamp` is not used: a claim changes it.
- A payload budget (1,000,000 characters) limits the digest work. The heap
  cost equals the cost of the step read.

Kept, with a reason:

| Item | Reason |
|------|--------|
| Wait bookkeeping in the inputs | A wait writes step state. To leave it out, the engine must separate it from author state. No proof of "no false positive" without an org. A false negative is cheaper than a false positive. |
| Payload codec: new ciphertext each wait | The digest uses the stored form on purpose (no plaintext digest). |
| Offloaded step state (over 100,000 characters) | The marker changes on each wait. A digest of the attachment costs one query and heap. The case is rare. |
| Blank `Failure_Category__c` after compensation | The category is not set by the compensation path (unchanged behavior). The log row records it. |
| `$timeoutResume` marker removed on the first fallback run | Engine behavior from before #102. Not a strict-mode defect. |
| `CursorFanoutWorkflowExample`, `BatchFanoutWorkflowExample` | Examples. A change needs a tested org run. Docs mark them as not replay-safe. |
| Full re-check of the live-signal set | A narrow re-check needs the matched Ids of `StepSignals`. It also needs name probes. It is a new design. File a new issue. |
| Dashboard count of log rows | A UI change. Not a determinism fix. |

An existing record has the old digest. The first run after the deploy reads
new inputs and records again. This gives no false positive.

Open (needs an org): the full Apex suite with the mode off and on, the count
of `STEP_NON_DETERMINISM` failures, and the SOQL cost per run.
