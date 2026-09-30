# Workflow Topology Graph (Issue #141)

## Goal

Show the step graph of a workflow definition. Put the path of one instance
on the graph. The operator must see where the instance is and where it can
go next, without reading `getNextStep`.

## Facts About The Engine

- `WorkflowValidator.validate` reads `getSteps()` and `getInitialStep()`. It
  makes an instance of each step class. Then `WorkflowTransitionProbe` calls
  `getNextStep` with two `COMPLETE` results for each step. The probe keeps
  only the defects. It discards the edges.
- `getNextStep` can use step output. Thus the probe cannot find all edges.
- The engine writes one `Workflow_Step_Execution__c` row for each run of a
  step. A compensation row has the name `<step>_Compensate`.
- `WorkflowWaitDescriptorService.describeSignalWait` gives the awaited
  signal (#84). The detail view already loads it.
- `WorkflowDashboardSupport.checkAuthorization` is the read gate of the
  dashboard.
- A `SPLIT` result starts parallel branches. The probe does not see them.

## Brainstorming (options)

| #   | Idea                                                                      | Keep?                                                                 |
| --- | ------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| B1  | Keep the probe edges on `ValidationResult`.                               | Yes. The validator stops discarding them. One probe, one code path.   |
| B2  | Write a second probe for the graph.                                       | No. Two probes can disagree.                                          |
| B3  | New class `WorkflowTopology` builds typed DTOs (`Graph`, `Node`, `Edge`). | Yes. Typed DTOs pin the shape. A test pins the JSON keys.             |
| B4  | Mark a node `routingUnknown` when `getNextStep` throws for it.            | Yes. Never show "no path" for a throw.                                |
| B5  | Mark the graph incomplete when a declared step has no known inbound edge. | Yes. Such a step proves that the probe missed an edge.                |
| B6  | Add "observed" edges from the order of the step rows.                     | No. Parallel branches interleave. That gives false edges.             |
| B7  | Show the path as numbered visits and highlight only known edges.          | Yes. No false edge.                                                   |
| B8  | Put the awaited descriptor in the graph DTO.                              | No. It needs `Output__c` (large). The dashboard passes the #84 value. |
| B9  | Draw the graph with an external library.                                  | No. No new static resource. Plain SVG with a layered layout.          |
| B10 | Put the graph in the instance detail and in the Catalog.                  | Yes. Operators use the detail. Authors use the Catalog.               |
| B11 | Show a text summary: current step, state, possible next steps.            | Yes. This gives the answer in less than 15 s. It also helps a11y.     |
| B12 | Add a seeded example with two decision points.                            | Yes. The issue asks for it for the metric.                            |
| B13 | Export Mermaid or PNG.                                                    | No. Out of scope.                                                     |

## Reverse Brainstorming (how to make it fail)

| How to fail                                           | Counter                                                                  |
| ----------------------------------------------------- | ------------------------------------------------------------------------ |
| Show "no path" where routing depends on data.         | `routingUnknown` on throw. Graph notice when a step has no inbound edge. |
| Show a partial graph as complete.                     | `routingFullyKnown` and `incompleteReasons`. The LWC shows a notice.     |
| Write data during a read.                             | No DML. A test checks DML, queueable and event limits and row counts.    |
| Make an instance of any class that a caller names.    | Accept only a deployed `WorkflowDefinition` (ApexTypeImplementor check). |
| Read without permission.                              | `checkAuthorization` first. A test runs as a user with no grant.         |
| Read all step rows of a long loop.                    | One query with `LIMIT`. Newest rows first. `pathTruncated` flag.         |
| Show compensation rows as forward steps.              | Map `<step>_Compensate` to its step with `compensation = true`.          |
| Hide a step that the run used but `getSteps()` omits. | Add it as a node with `declared = false`.                                |
| Draw arrows that break in shadow DOM (`url(#id)`).    | Draw arrow heads as polygons. No `marker` references.                    |
| Change the validator result for current callers.      | Same defects, same order. Only new fields. Existing tests stay.          |

## Six Thinking Hats

- **White (facts):** The probe does 2 calls for each step and version. The
  graph adds 1 SOQL for the type check. The overlay adds 2 SOQL (instance,
  step rows). No DML.
- **Red (feel):** Operators want one look. The text summary above the graph
  gives the answer first.
- **Black (risk):** A step constructor with side effects runs during the
  probe. The validator has the same rule already. The docs repeat it.
  Parallel branches show in run order only.
- **Yellow (value):** No new schema, event or job. Authors see routing bugs
  (dangling or wrong successors) without a run.
- **Green (ideas):** Later: versions per edge, Mermaid export, live refresh.
- **Blue (process):** RED tests first (Apex and Jest). Then GREEN. Then
  refactor and docs. Then a review from many angles.

## Design

- `WorkflowTransitionProbe.Transitions`: successors for each step, steps
  that can end, steps where `getNextStep` threw, and a flag for
  `getLatestVersion` errors.
- `WorkflowValidator.ValidationResult` keeps `initialStep`, `declaredSteps`,
  `compensatableSteps` and `transitions`.
- `WorkflowTopology.build(name)` and `WorkflowTopology.forInstance(id)`.
- `WorkflowDashboardController.getWorkflowTopology` (cacheable) and
  `getInstanceTopology` (not cacheable, live position).
- LWC `workflowTopologyGraph`, with a pure layout module
  (`topologyLayout.js`).
- Example `BranchingOrderWorkflowExample`.

## Test Plan

- Apex: nodes and edges, initial, terminal, compensatable, unknown routing,
  unreached steps, dangling successor, unknown definition, read-only
  contract, overlay path, current state, truncation, authorization, and
  the pinned DTO keys.
- Jest: layout, notice, summary, current node, awaited signal, path,
  errors, and the dashboard wiring.
