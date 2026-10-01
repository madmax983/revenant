# ADR 0019: Breaker probe epoch

- **Status:** Accepted
- **Date:** 2026-09-30
- **Issue:** #235

## Context

A success closed any Half-Open breaker. The step did not need to be a probe.
A step admitted while Closed could finish after the breaker went Open, then
Half-Open. Its success closed the breaker by mistake.

## Options

| Option | Result |
| --- | --- |
| Boolean probe flag on the step row | A probe from an old phase still closes. |
| Phase number on the state row and the step row | Covers both cases. **Chosen.** |
| Close only when the probe budget is spent | Wrong for a budget above 1. |
| Count successes per phase | Needs more rows and more locks. |

We also checked these risks: a lost marker, a reused step row, old rows without the
field, and a race between two probes.

## Decision

1. `Circuit_Breaker_State__c.Half_Open_Epoch__c` increases by 1 each time the
   breaker enters Half-Open (`tryAdmit` and `sweepHalfOpen`), under the row lock.
2. `BreakerDecision.probeEpoch` holds the phase number for a probe, else null.
3. `WorkflowStepInvoke` writes it to `Workflow_Step_Execution__c.Breaker_Probe_Epoch__c`
   on each admission. A non-probe attempt writes null.
4. `recordSuccess` closes the breaker only if the state is Half-Open and the
   number equals `Half_Open_Epoch__c`. If not, it writes nothing.
5. Failure recording does not change. A failure in Half-Open still re-opens, also a
   failure from an old phase. This is safe: the breaker only waits longer.
   Epoch-gating failures is a possible later change.
6. No `global` API change.

## Consequences

- No false close from a Closed-admitted or old-phase step.
- Old rows have null fields. A null marker never closes. A null epoch counts as 0.
- A probe that finishes after the phase ended is dropped. The next phase probes again.
- The engine owns both fields. Admin can edit both. Operator can read only the step field.
