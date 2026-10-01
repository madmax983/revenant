# Engine Provenance for Child Outcomes (Issue #246)

## Goal

A signal can wake a parent. A signal cannot set a child outcome. The parent reads the outcome from the child record.

## Facts

- Child completion and external callers use the same ingress.
- A `Workflow_Event__e` publisher can set any field. The engine cannot mark a signal as engine-made.
- The old reader took status, error and output from the signal payload, then checked the payload again.
- The `ChildFailed` wrapper held the child output. After JSON escaping it can exceed 131,072 characters.
- The signal read resolved and decoded each payload by its shape.

## Brainstorm

| #   | Idea                                                           | Keep?                                              |
| --- | -------------------------------------------------------------- | -------------------------------------------------- |
| B1  | Read the outcome from the child record of the reading instance | Yes. Fixes all three issue comments. No new field. |
| B2  | Engine-only field on `Workflow_Signal__c`                      | No. An event cannot carry trust.                   |
| B3  | Insert the signal row from the child transaction               | No. Locks the parent row.                          |
| B4  | Send no payload on child events                                | Yes. The event stays small.                        |
| B5  | Do not read the payload of child signals                       | Yes. A forged payload is never resolved.           |

## Reverse Brainstorm

| Way to fail                                 | Prevention                                        |
| ------------------------------------------- | ------------------------------------------------- |
| Forged envelope, marker or text is decoded. | Signal read gives no payload. Tests: both codecs. |
| `ChildCompleted` for a failed child.        | Status of the record sets the type. Test.         |
| Signal for a running child.                 | No outcome. Test.                                 |
| Older finished child hides a new child.     | Newest child of the key decides first. Test.      |
| Child of another parent.                    | Query keeps `Parent_Instance__c`. Test.           |
| N keys cost N queries.                      | One query. Test.                                  |
| Unit tests need DML.                        | `childRecords` seam. 0 DML, 0 SOQL.               |
| Large child output breaks the event.        | No payload on the event. Test: both codecs.       |

## Six Hats

- White: one query, one reader, one notifier change. No new field. No `global` change.
- Red: a forged signal must never give data to a step.
- Yellow: no reader checks a name or a payload shape again.
- Black: raw `getSignal` gives no payload for child names. Authors use `getChildOutcome`.
- Green: later, an engine-only field if another reader needs one.
- Blue: RED tests, then GREEN, then REFACTOR, then review.

## Design

- `WorkflowParentNotifier` publishes the event with no payload.
- `WorkflowSignalPayloads.readPayload` gives no payload for `ChildCompleted:` and `ChildFailed:` names. All signal sources use it.
- `StepChildOutcomes` loads the children of the reading instance for the woken keys. The newest child of a key decides. A child with a final status gives the outcome. Its stored output is resolved and decoded.
- A signal for a missing, foreign or running child gives no outcome. The step still reads the signal, as before.
- `StepContext.Builder.childRecords` and `StepContextTestBuilder.childRecords` seed children for unit tests.
- Delete `WorkflowChildPayloadProvenance`.
- Add the threat model and ADR 0021. Update the codec guide.

## Out of scope

- File purge by provenance (issue comment 2). A new issue tracks it.
- Identity codec marker text (#242).
