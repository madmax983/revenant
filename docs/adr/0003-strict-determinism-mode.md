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
   timeout-resume flag, the live signals (Id and status) and the child status
   counts. Two SOQL queries.
3. Build a decision text from routing data only. Each value is JSON. Sort
   split and child targets.
4. Record a wait decision and its inputs digest in the new field
   `Workflow_Step_Execution__c.Decision_Record__c`. The wait handler saves it.
5. When a run has the same inputs as the record and a different decision,
   it is a divergence. `RETRY`, `SLEEP`, `YIELD` and a thrown error are not
   decisions: keep the record. Clear the record when the inputs changed and
   the decision is not a wait.
6. Handle a divergence in the outcome seam, after the re-lock and the stale
   guard, before the dispatch. Fail the step row, write an Error log row
   (`StepNonDeterminism`) and call `failWorkflowInstance` with the new
   category `STEP_NON_DETERMINISM`.
7. Clear the record on an operator retry, a parallel re-drive, a resume with
   a payload, a definition-change release and a run with the mode off.

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
