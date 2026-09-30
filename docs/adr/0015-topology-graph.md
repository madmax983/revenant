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
   steps and the rollback steps on `ValidationResult`. One probe gives the
   defects and the graph.
2. `WorkflowTopology` projects the result into typed DTOs. A test pins the
   JSON keys.
3. The graph does not show a missing route as "no path". A step is
   `routingUnknown` when `getNextStep` throws for a probe or gives
   different successors for the two probes. `gapsFound` is true, with
   reason codes, when the graph finds a gap. The name `gapsFound` does not
   claim that a graph with no gap is complete.
4. The overlay adds no edge from the order of the step rows, and it marks
   no edge as used. The rows have no branch data. Parallel branches mix
   their rows, so two adjacent rows do not prove a transition. The
   numbered path and the visited steps show the run.
5. The graph makes an instance of a class only after `ApexTypeImplementor`
   shows a deployed, concrete workflow definition. The validator resolves
   the definition as the engine does at start.
6. Both endpoints are cacheable. The platform then stops DML from author
   code in the probe. The LWC sends a new cache key on each instance read.
7. The version probe reads only the newest 50 versions. A large version
   number (for example a date) does not use all the CPU time.
8. The awaited-signal descriptor comes from the instance detail (#84). The
   overlay does not read `Output__c`.
9. A new `WorkflowTopologyController` holds the endpoints.
   `WorkflowDashboardController` is at the PMD `ExcessivePublicCount` limit.

## Consequences

- No new schema, event, job or metadata type.
- The overlay uses 2 SOQL. The step query has `LIMIT 201`.
- The validator does not probe versions older than the newest 50. It
  cannot find a dangling successor that only such a version uses.
- An author can mark a data-dependent step: `getNextStep` throws for an
  unknown value. The graph then shows **?** for the step.
- The validator constructs each step class, as before.
