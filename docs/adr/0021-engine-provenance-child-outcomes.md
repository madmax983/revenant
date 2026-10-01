# ADR 0021: Child outcomes come from the child record

- Status: Accepted
- Date: 2026-10-01
- Issue: #246

## Context

Child completion and external signals use one ingress. The engine cannot mark a signal as engine-made, because a `Workflow_Event__e` publisher can set any field. Each reader had to prove provenance again (`WorkflowChildPayloadProvenance`). Each review round found a new case.

## Decision

1. A `ChildCompleted:<key>` or `ChildFailed:<key>` signal only wakes the parent.
2. `StepChildOutcomes` reads status, error and output from the child record. The record must have `Parent_Instance__c` equal to the reading instance. The status must be final. One query serves all keys.
3. The status of the record gives the outcome type. The signal name does not.
4. The engine decodes only `Output__c` of a verified child. It never reads the signal payload.
5. `ChildFailed` events carry no payload. `ChildCompleted` keeps the stored output as an untrusted copy for raw readers (compatibility).
6. Delete `WorkflowChildPayloadProvenance`.
7. Unit tests seed children with `StepContext.Builder.childRecords` (0 DML, 0 SOQL).

## Consequences

- No reader infers trust from a name or a payload shape.
- The `ChildFailed` event size does not depend on the child output.
- One query when a child signal is pending. None otherwise.
- A step that reads a raw child payload gets an untrusted value. Use `getChildOutcome`.
- Option not chosen: an engine-only field on `Workflow_Signal__c`. The event path cannot carry trust.

See `docs/payload-ingress-threat-model.md`.
