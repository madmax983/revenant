# Engine Provenance for Child Outcomes (Issue #246)

## Goal

A signal can wake a parent. A signal cannot set a child outcome. The parent reads the outcome from the verified child record.

## Facts

- Child completion uses `Workflow_Event__e`. External callers use the same ingress.
- The engine cannot mark a signal as engine-made. Any publisher can set any event field.
- `StepChildOutcomes` reads status, error and output from the signal payload. `WorkflowChildPayloadProvenance` then re-proves the payload.
- The `ChildFailed` wrapper holds the child output. JSON escaping can push it past 131 072 characters.
- A forged `ChildCompleted` signal can claim a child that failed (and the reverse).

## Brainstorm

| #   | Idea                                                           | Keep?                                                       |
| --- | -------------------------------------------------------------- | ----------------------------------------------------------- |
| B1  | Read the outcome from the child record of the reading instance | Yes. Fixes all three comments. No new field.                |
| B2  | Engine-only field on `Workflow_Signal__c`                      | No. The event path cannot carry trust. A new field to guard. |
| B3  | Insert the signal row directly from the child transaction      | No. Parent row locks. Cannot test without an org.           |
| B4  | Send only the wake-up on the event (no output, no error)       | Yes. Small event. Fixes the size bound.                     |
| B5  | Keep `trustedOnly` as a second check                           | No. Dead code once B1 is in place.                          |

## Reverse Brainstorm (how can this fail?)

| Way to fail                                      | Prevention                                                              |
| ------------------------------------------------ | ----------------------------------------------------------------------- |
| Forged envelope in a payload gets decoded.       | The reader ignores the payload. Test with identity and AES codec.       |
| Forged file marker is resolved.                  | Same. Test.                                                             |
| Plaintext forgery sets the output.               | Same. Test.                                                             |
| `ChildCompleted` for a failed child.             | Type comes from `Status__c`. Test.                                      |
| Signal for a child that still runs.              | No outcome. Signal stays unconsumed. Test.                              |
| Signal for a child of another parent.            | Query keeps `Parent_Instance__c = instance`. Test.                      |
| N children cost N queries.                       | One query for all keys. Test.                                           |
| Key case or Id key does not match.               | Same key rules as the old check (lower case, Id fallback). Test.        |
| Unit tests need DML.                             | Seam: `Builder.childRecords`. Zero DML, zero SOQL.                      |
| Large child output breaks the event.             | Event carries no output. Test.                                          |

## Six Hats

- White: one query, one reader change, one notifier change, no new field, no `global` change.
- Red: a forged signal must never give data to a step. This must not happen.
- Yellow: removes a class of bugs. Readers need no name or shape checks.
- Black: a terminal child with a codec change after completion reads with the new codec. Mitigate: same as every record read.
- Green: later, an engine-only signal field if a second reader needs it.
- Blue: RED tests first, then GREEN, then REFACTOR, then review.

## Design

- `WorkflowParentNotifier` publishes `ChildCompleted:<key>` or `ChildFailed:<key>` with no payload.
- `StepChildOutcomes` takes the key from the signal name. It loads the children of the reading instance for those keys. A child with a terminal status gives the outcome:
  - `Completed`: status `Completed`, output from `Output__c`.
  - Other terminal status: that status, `Error_Message__c`, output from `Output__c`.
- `Output__c` is resolved and decoded (offload, envelope). Only the verified record gives this value.
- A signal for a child that is missing, not a child of this instance, or not terminal gives no outcome. The step does not consume that signal.
- `StepSignals.bindChildren` sets the instance Id and an optional in-memory child list. `StepContext.Builder.childRecords` seeds it for unit tests.
- Delete `WorkflowChildPayloadProvenance`.
- Add `docs/payload-ingress-threat-model.md` and ADR 0021. Update `docs/payload-codec.md`.

## Tests

- Forged signal tests: envelope, offload marker, plaintext. Identity codec and AES codec.
- Wrong type: `ChildCompleted` for a failed child; `ChildFailed` for a completed child.
- Child still running; child of another parent; no child.
- Bulk: one query for many keys.
- Event payload is null for both outcomes, also with a large output.
- Existing outcome tests move to seeded child records.

## Out of scope

- Provenance-based file purge (issue comment 2). It is a separate subsystem. Track it as a new issue.
