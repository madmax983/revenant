# ADR 0015: Workflow topology graph

- **Status:** Accepted
- **Date:** 2026-09-30
- **Issue:** #141

## Context

The dashboard showed a run as a list of steps. No view showed the branches
of a definition. `WorkflowValidator` already probed `getNextStep` for each
step, but it discarded the edges. `getNextStep` can use step output, so a
static graph cannot be complete.

## Decision

1. The validator keeps the probe edges, the initial step, the declared
   steps and the steps with rollback on `ValidationResult`. One probe gives
   the defects and the graph.
2. `WorkflowTopology` projects the result into typed DTOs. A test pins the
   JSON keys.
3. The graph never shows a missing route as "no path". A step where
   `getNextStep` threw is `routingUnknown`. The graph sets
   `routingFullyKnown = false` with reason codes when it knows that it
   misses routes.
4. The overlay adds no edge from the order of the step rows. Parallel
   branches interleave their rows, so such an edge can be false.
5. The graph makes an instance of a class only after `ApexTypeImplementor`
   shows a deployed workflow definition. A read-only user cannot make the
   server construct any other class.
6. The awaited-signal descriptor comes from the instance detail (#84). The
   overlay does not read `Output__c`.
7. A new `WorkflowTopologyController` holds the endpoints.
   `WorkflowDashboardController` is at the PMD `ExcessivePublicCount` limit.

## Consequences

- No new schema, event, job or metadata type.
- The overlay costs 2 SOQL. The step query has `LIMIT 201`.
- Authors who want more routes in the graph can fail closed in
  `getNextStep`.
- A step constructor runs during the probe, as it did for the validator.
