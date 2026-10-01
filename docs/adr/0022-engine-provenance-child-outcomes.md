# ADR 0022: Child outcomes come from the child record

- Status: Accepted
- Date: 2026-10-01
- Issue: #246

## Context

Child completion and external signals use one ingress. The engine cannot mark a signal as engine-made. Any `Workflow_Event__e` publisher can set any field. Each reader checked the payload again. Each review found a new case.

## Decision

1. A `ChildCompleted:<key>` or `ChildFailed:<key>` signal only wakes the parent.
2. `StepChildOutcomes` reads status, error and output from the child record. The child `Parent_Instance__c` must match the reading instance. The newest child of a key decides. Its status must be final. One query serves all keys.
3. The status of the record gives the outcome type.
4. The engine decodes only `Output__c` of the verified child.
5. Child events have no payload. The signal read gives no payload for these names (`WorkflowSignalPayloads.readPayload`). A forged payload is never resolved or decoded.
6. Delete `WorkflowChildPayloadProvenance`.
7. Unit tests seed children with `childRecords` (0 DML, 0 SOQL).

## Consequences

- No reader trusts a signal because of its name or payload shape.
- The `ChildFailed` event size does not depend on the child output.
- One query when a child signal is pending. No query otherwise.
- Breaking: raw `getSignal('ChildCompleted:<key>').payload` is now null. Use `getChildOutcome`.
- Rejected: an engine-only field on `Workflow_Signal__c`. An event cannot carry trust.

See `docs/payload-ingress-threat-model.md`.
