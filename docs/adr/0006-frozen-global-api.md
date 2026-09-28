# ADR 0006: Frozen global API surface

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #122

## Context

In a managed package, `public` is visible only in the package namespace. Subscriber Apex and Flow see only `global`. Before this change, Revenant had no `global` code. A subscriber could not implement a step, start a workflow, or use the invocable actions. After a package release, you cannot remove or change a `global` signature.

## Decision

1. Make a small, member-scoped set `global`: the authoring SPI, the control facade, and three Flow actions. `docs/global-api.md` lists each member.
2. Authoring SPI: `WorkflowStep`, `WorkflowDefinition`, `CompensatableStep`, `VersionedWorkflow`, `CalloutStep`, `TimeoutConfigurable`, `RetryConfigurable`, `AutoRetryConfigurable`, `CaptureProducer`, `StepContext` and its six accessor objects, `StepResult`, `RetryPolicy`. Only author members are `global`.
3. The issue names `getSignal`, `once`, and `emit` on `StepContext`. They are now on `StepSignals`, `StepCaptures`, and `StepEmitter`. Make these accessor objects `global`. Do not add delegates to `StepContext`.
4. The issue names `WorkflowEngine.getStatus`. It moved to `WorkflowStatusRead` on 2026-07-15. The README names `WorkflowStatusRead.getStatus` as the read contract. Make it `global`. Do not add a second read path.
5. Definitions route on `result.directive().nextStepName` and `.outputJson`. Make `directive()` and these two properties `global`, with a `public` setter. Other directive data stays private.
6. Output data is read-only outside the package: `StartResult.instanceId` and `isNew` become `global` properties with a `private` setter. `RetryPolicy` properties get a `public` setter. A frozen writable member cannot become read-only later. Input DTO fields (`StartRequest.causationId`, the Flow request variables) stay writable, because callers set them.
7. A `global` class with no explicit constructor gets a default constructor that subscribers can call. Add an explicit namespace-private constructor where subscribers must not construct the type. Only the Flow request types keep the default constructor. `WorkflowException` keeps the platform exception constructors.
8. `RetryConfigurable` and `AutoRetryConfigurable` are `global`. They are the only way an author returns a `RetryPolicy`. `StepContext.Signal.signalId` is `global`: authors use it to find a signal that they already processed.
9. A test (`npm run test:global-api`) compares the `global` declarations with the manifest. It checks the platform rules, the internals, the invocable members, and writes to read-only properties. With apex-ls, it compiles a subscriber fixture in namespace `acme` against a stub (namespace `rvn`) that holds only the `global` members.

## Consequences

- Each `global` member is a permanent contract after the first release. A change to the surface must change the manifest. The test enforces this.
- The `global` interfaces are closed. New author features must use new opt-in interfaces.
- Code that reads `StartResult.instanceId` and `isNew` does not change. Code outside `StartResult` cannot write them.
- No schema change. No change to the compensation stack, the step-execution audit rows, or the Queueable handoff.
- This repo has no CI. `GlobalApiSubscriberTest` runs only in a scratch org.
- A subscriber cannot unit-test a step or drive more than one async hop in a test. `docs/global-api.md` lists this as a candidate to do before the first release.

## Rejected Options

- Make each member of the named classes `global`: freezes internal helpers such as `StepContext.Builder` and `StepSignals.markMatched`.
- `@namespaceAccessible`: it works only for packages of the same namespace, not for subscribers.
- `WorkflowEngine.getStatus` delegates: two read paths for one contract.
- Add `signalOrStart`, `getHistory`, `findInstances`, and the other opt-in interfaces now: the issue asks for a minimal set. You can add a member later. You cannot remove one.
- `StartRequest.withParent`: a subscriber could make a false parent link. `StepResult.startChild` is the supported path.
