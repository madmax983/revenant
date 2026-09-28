# Frozen Global API Surface (Issue #122)

## Goal

Let subscriber-org Apex and Flow use a packaged Revenant. Make a small, frozen set of types and members `global`. Keep all other engine code namespace-private. Write a manifest of the set. Add a test that fails when the code and the manifest differ.

## Facts About The Platform

- In a managed package, `public` is visible only in the package namespace. Subscriber code sees only `global`.
- A `global` member must be in a `global` type. An inner type is `global` only in a `global` outer type.
- A `global` signature can use only `global` or system types. Else the compile fails.
- A `global` interface can extend only a `global` interface. Its methods are `global`.
- An accessor can have less access than its property: `global Id x { get; private set; }` is read-only outside the class.
- After a package release, a `global` member cannot be removed or changed. A new `global` member can be added.
- `@namespaceAccessible` gives access to other packages of the same namespace only. It does not help subscribers.
- A subscriber Flow can use an `@InvocableMethod` only when the method, its class, and its `@InvocableVariable` members are `global`.

## Facts About The Engine

- Author primitives moved to accessor objects: `ctx.signals()`, `ctx.captures()`, `ctx.events()`, `ctx.logger()`, `ctx.progress()`, `ctx.retry()`. The issue names `getSignal`, `once`, `emit`. They are on `StepSignals`, `StepCaptures`, `StepEmitter` now.
- `getStatus` moved from `WorkflowEngine` to `WorkflowStatusRead` (2026-07-15). The README names `WorkflowStatusRead.getStatus` as the read contract.
- `once()` takes a `CaptureProducer`. Authors implement it.
- Definitions read `result.directive().nextStepName` and `.outputJson` in `getNextStep` (examples).
- The repo has no `global` code today. It has no Salesforce CLI in CI.
- apex-ls (offline Apex checker) finds types that are not visible across namespaces. It does not check member access.

## Brainstorming (options)

| #   | Idea                                                                                                                                              | Keep?                                                                                                                                                     |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| B1  | Make all classes `global`.                                                                                                                        | No. Every internal becomes a forever contract.                                                                                                            |
| B2  | Make only the issue's types `global`, all members.                                                                                                | No. Internal helpers (`seedPendingSignals`, `markMatched`, `Builder`) become frozen.                                                                      |
| B3  | Member-scoped `global`: only the members an author or caller must use.                                                                            | Yes. The AC asks for this.                                                                                                                                |
| B4  | Add `WorkflowEngine.getStatus` delegates.                                                                                                         | No. Two read paths. The README contract is `WorkflowStatusRead.getStatus`. Make it `global`.                                                              |
| B5  | Make `StepSignals`, `StepCaptures`, `StepEmitter`, `StepLog`, `StepProgress`, `StepRetryInfo` `global`, author members only.                      | Yes. `StepContext` accessors return them.                                                                                                                 |
| B6  | Make `CaptureProducer` `global`.                                                                                                                  | Yes. `once()` needs it.                                                                                                                                   |
| B7  | Make `directive()` `global` with read-only `nextStepName` and `outputJson`.                                                                       | Yes. Definitions route on them. Other directive data stays private.                                                                                       |
| B8  | DTO output fields (`StartResult`) as `global` read-only properties.                                                                               | Yes. A frozen mutable field cannot become read-only later.                                                                                                |
| B9  | Manifest as a table only.                                                                                                                         | No. A test cannot read it safely.                                                                                                                         |
| B10 | Manifest with one fenced block, one line for each member. A test compares it with the code.                                                       | Yes. Any change to the surface fails the test until the manifest changes.                                                                                 |
| B11 | Node test with `@apexdevtools/apex-parser`. It checks the manifest and the `global` rules.                                                        | Yes. Fast. No org.                                                                                                                                        |
| B12 | Make a "packaged view": a stub project with only the `global` members. Compile a subscriber fixture against it in another namespace with apex-ls. | Yes. This is the success metric: compile against the global API only. apex-ls then finds a member that is not `global`.                                   |
| B13 | Subscriber fixture as an `@IsTest` class. It uses only the global API. It runs start, one async hop, and a terminal state in the org.             | Yes. Same source for the compile check and the run check. No fixture code ships in the package.                                                           |
| B14 | Add `signalOrStart`, `getHistory`, `findInstances`, the signal-or-start invocable, and other opt-in interfaces now.                               | No. The issue names a minimal set. Adding later is safe. Removing is not. List them as candidates.                                                        |
| B15 | Make `StepContextTestBuilder` `global`.                                                                                                           | No. `@IsTest` code is not visible to subscribers. Candidate: a non-test builder.                                                                          |
| B16 | Make the implicit default constructor explicit and namespace-private on `global` classes that subscribers must not construct.                     | Yes (added in GREEN). A `global` class with no constructor gets a `global` default constructor. It is an accidental contract. Flow request types keep it. |

## Reverse Brainstorming (how can this fail?)

| Way to fail                                                              | Prevention                                                                                                              |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| A `global` signature uses a `public` type. The package does not compile. | The Node test checks each `global` signature type. The stub compile also fails.                                         |
| A `global` member is in a `public` type.                                 | The Node test checks the outer types.                                                                                   |
| Someone adds `global` to an internal class.                              | The manifest compare fails. A deny-list test names the internals.                                                       |
| Someone removes or changes a frozen member.                              | The manifest compare fails.                                                                                             |
| Subscribers change engine output (`StartResult.isNew`).                  | Read-only properties (`private set`).                                                                                   |
| Subscribers change `directive()` data.                                   | `public set` on the two exposed properties.                                                                             |
| The fixture uses an internal helper by mistake.                          | The stub compile has no internal types or members. apex-ls reports it.                                                  |
| A subscriber Flow cannot see an invocable input.                         | The Node test checks each `@InvocableVariable` in a `global` class.                                                     |
| The change alters behavior.                                              | Only access modifiers change, and two fields become properties. The apex-ls check of the full repo shows no new errors. |
| `getStatus` is not where the AC says.                                    | The manifest and the ADR record the move to `WorkflowStatusRead`.                                                       |

## Six Thinking Hats

- **White (facts):** 11 issue types. The author primitives moved to 6 accessor objects. `getStatus` moved. No org and no `sf` CLI here. apex-ls works offline.
- **Red (feeling):** A `global` signature is a one-way door. Keep the set small.
- **Black (risks):** An error in the Salesforce `global` rules breaks the package. A frozen mistake stays forever. Apex tests cannot run here.
- **Yellow (benefits):** ISVs can ship Revenant. The test freezes the surface. Review sees each surface change.
- **Green (ideas):** Packaged-view stub compile. Candidates list for later growth.
- **Blue (process):** RED: manifest, Node test, fixture; the test fails. GREEN: add `global`. REFACTOR: prettier, docs, ADR. Review with agents. Map each AC to evidence.

## Surface (v1)

See `docs/global-api.md`. Summary:

- Interfaces: `WorkflowStep`, `WorkflowDefinition`, `CompensatableStep`, `VersionedWorkflow`, `CalloutStep`, `TimeoutConfigurable`, `CaptureProducer`.
- Step types: `StepContext` (and `Level`, `Signal`, `ChildOutcome`), `StepSignals`, `StepCaptures`, `StepEmitter`, `StepLog`, `StepProgress`, `StepRetryInfo`, `StepResult` (and `ChildRequest`, `StepDirective`), `RetryPolicy`.
- Control: `WorkflowEngine` (`start`, `startOrGet`, `signal`, `cancel`, request and result types, `WorkflowException`), `WorkflowStatusRead.getStatus`.
- Flow: `WorkflowStartInvocableAction`, `WorkflowSignalInvocableAction`, `WorkflowStatusInvocableAction`.

## Tests

1. `scripts/global-api/global-api.test.mjs` (`npm run test:global-api`):
   - The `global` members in `force-app` equal the manifest block.
   - Each `global` member is in a `global` type chain.
   - Each `global` signature uses only `global` or system types.
   - Each `global` interface extends only `global` interfaces.
   - No internal class (orchestrator, watchdog, finalizer, jobs, controllers, sweeps) has `global`.
   - Each `@InvocableVariable` in a `global` class is `global`.
2. Packaged-view compile (same test, needs Java and apex-ls): stub namespace `rvn`, fixture namespace `acme`. Zero errors.
3. `GlobalApiSubscriberTest` (Apex): start, one async hop, terminal `Completed`. A signal path. Uses only the global API.

## Out Of Scope

`Type.forName` across namespaces (#58). Package build. CRUD and FLS (#60). Engine extension points.
