# ADR 0006: Frozen global API surface

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #122

## Context

In a managed package, `public` is visible only in the package namespace. Subscriber Apex and Flow see only `global`. Before this change, Revenant had no `global` code. A subscriber could not implement a step, start a workflow, or use the invocable actions. After a package release, a `global` signature cannot be removed or changed.

## Decision

1. Make a small, member-scoped set `global`: the authoring SPI, the control facade, and three Flow actions. `docs/global-api.md` lists each member.
2. Authoring SPI: `WorkflowStep`, `WorkflowDefinition`, `CompensatableStep`, `VersionedWorkflow`, `CalloutStep`, `TimeoutConfigurable`, `CaptureProducer`, `StepContext` and its six accessor objects, `StepResult`, `RetryPolicy`. Only author members are `global`.
3. The issue names `getSignal`, `once`, and `emit` on `StepContext`. They are now on `StepSignals`, `StepCaptures`, and `StepEmitter`. Make these accessor objects `global`. Do not add delegates to `StepContext`.
4. The issue names `WorkflowEngine.getStatus`. It moved to `WorkflowStatusRead` before this change. The README names `WorkflowStatusRead.getStatus` as the read contract. Make it `global`. Do not add a second read path.
5. Definitions route on `result.directive().nextStepName` and `.outputJson`. Make `directive()` and these two properties `global`, with a `public` setter. Other directive data stays private.
6. Engine output (`StartResult.instanceId`, `isNew`) becomes a `global` property with a `private` setter. A frozen mutable field cannot become read-only later.
7. A `global` class with no explicit constructor gets a `global` default constructor. Add an explicit namespace-private constructor where subscribers must not construct the type. Keep the default constructor only on the Flow request types.
8. A test (`npm run test:global-api`) compares the `global` declarations with the manifest. It checks the platform rules, the internals, and the invocable members. With apex-ls, it compiles a subscriber fixture in namespace `acme` against a stub (namespace `rvn`) that holds only the `global` members.

## Consequences

- Each `global` member is a forever contract after the first release. A change to the surface must change the manifest. The test enforces this.
- `StartResult.instanceId` and `isNew` are properties now. Reads do not change. Code outside `StartResult` cannot write them.
- No schema change. No change to the compensation stack, the step-execution audit rows, or the Queueable handoff.
- A subscriber must still find its classes by name across namespaces. That is issue #58.
- Apex tests cannot run in this repo's CI. `GlobalApiSubscriberTest` runs in a scratch org.

## Rejected Options

- Make whole classes `global`: freezes internal helpers such as `StepContext.Builder` and `StepSignals.markMatched`.
- `@namespaceAccessible`: it works only for packages of the same namespace, not for subscribers.
- `WorkflowEngine.getStatus` delegates: two read paths for one contract.
- Add `signalOrStart`, `getHistory`, `findInstances`, and the other opt-in interfaces now: the issue asks for a minimal set. An addition later is safe. A removal is not.
