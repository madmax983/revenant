# Revenant Global API

This page lists each Apex type and member that code in a different namespace can use. In a managed package, subscriber code sees only `global` declarations. All other engine code is namespace-private.

Decision record: [ADR 0006](adr/0006-frozen-global-api.md). Issue: #122.

## Stability Policy

- After the first package release, do not remove, rename, or change a member in the manifest. Do not change a parameter, a return type, or an access level.
- Do not add a method to a `global` interface. The platform blocks it after a release, and it breaks each subscriber class that implements the interface. Add a new opt-in interface instead, as `VersionedWorkflow` does.
- A new `@InvocableVariable` must be optional. A required variable breaks existing Flows.
- Add a member only when a subscriber must use it. Each addition is a new, permanent contract.
- To retire a member, add `@Deprecated` and keep its behavior. `@Deprecated` compiles only in the namespaced packaging org. Before the package is in the packaging org, mark the member as deprecated in this page.
- When you change the surface, change the manifest block below in the same commit. `npm run test:global-api` fails when the code and the manifest are different.
- A property with `{ get }` is read-only outside the package.

## Scope

- **Authoring SPI:** the step and definition interfaces, `RetryConfigurable`, `AutoRetryConfigurable`, `StepContext` and its accessor objects, `StepResult`, `RetryPolicy`, `CaptureProducer`.
- **Control facade:** `WorkflowEngine` (`start`, `startOrGet`, `signal`, `cancel`) and `WorkflowStatusRead.getStatus`.
- **Debounced start:** `WorkflowDebouncer.startDebounced` and `DebounceRequest` (issue #140). See [debounce.md](debounce.md).
- **Flow:** the Start, Signal, and Get Workflow Status invocable actions.

`getStatus` is on `WorkflowStatusRead`, not on `WorkflowEngine`. It moved there on 2026-07-15, before this release. The README names `WorkflowStatusRead.getStatus` as the read contract.

## Use From A Subscriber Org

Put the package namespace before each type (example namespace: `rvn`). A step class:

```apex
public class ReserveStep implements rvn.CompensatableStep {
  public rvn.StepResult execute(rvn.StepContext ctx) {
    rvn.StepContext.Signal go = ctx.signals().getSignal('Go');
    if (!go.isPresent()) {
      return rvn.StepResult.suspend();
    }
    return rvn.StepResult.complete(null, go.payload);
  }
  public rvn.StepResult compensate(rvn.StepContext ctx) {
    return rvn.StepResult.complete(null, null);
  }
}
```

Caller code (for example, Anonymous Apex):

```apex
Id instanceId = rvn.WorkflowEngine.start('acme.OrderWorkflow', 'order-42', null);
rvn.WorkflowEngine.WorkflowStatus status = rvn.WorkflowStatusRead.getStatus(instanceId);
```

Give the namespace-qualified class name, for example `acme.OrderWorkflow`. `WorkflowTypeResolver` finds the class across namespaces (issue #58).

The static type of the argument selects the `getStatus` overload. An `Id` reads by instance Id. A `String` reads by correlation key, also when the text is an Id. Declare an instance Id as `Id`.

The examples in `examples/` run in the package namespace. Some use classes that are not in this page.

## Status Values

These values are part of the contract. Do not rename them.

- `WorkflowEngine.WorkflowStatus.status` and `WorkflowStatusInvocableAction.StatusResult.status`: `Pending`, `Running`, `Suspended`, `Paused`, `Compensating`, `Cancelling`, `DefinitionChanged`, `Held`, `CompensationFailed`, `ContinuedAsNew`, `Completed`, `Failed`, `Compensated`, `Cancelled`. `isTerminal` is true for `Completed`, `Failed`, `Compensated`, and `Cancelled`.
- `StepContext.ChildOutcome.status`: `Completed`, or the status of a child that did not complete: `Failed`, `Cancelled`, `Compensated`, `ContinuedAsNew`, or `CompensationFailed`. A running child has no outcome. The status comes from the child record. Use `isSuccess()` to test for `Completed`.

## Manifest

One line for each declaration. The test reads the block below.

- `global <kind> <Type>`: a type. `extends` and `implements` show the super types. An enum shows its values.
- `<Type>.<method>(<parameter types>): <return type>`: a method. `static` is shown.
- `new <Type>(<parameter types>)`: a constructor. `new <Type>()` is also the default constructor of a `global` class with no explicit constructor.
- `<Type>.<name>: <type> { get }`, `{ set }`, or `{ get; set }`: a property. It shows the accessors that a subscriber can use.
- `<Type>.<name>: <type>`: a field (read and write).
- `@InvocableMethod` and `@InvocableVariable` show Flow members, with the arguments that change compatibility (`required`, `callout`). `@Deprecated` is shown.
- `virtual`, `abstract`, `override`, and `webservice` are shown. A `webservice` member is visible outside the package, as a `global` member.
- Interface methods are `global` because the interface is `global`.
- A `global` exception also has the platform exception constructors. The manifest does not show them.

```revenant-global-api
# Authoring interfaces
global interface WorkflowStep
WorkflowStep.execute(StepContext): StepResult
global interface CompensatableStep extends WorkflowStep
CompensatableStep.compensate(StepContext): StepResult
global interface WorkflowDefinition
WorkflowDefinition.getSteps(): List<String>
WorkflowDefinition.getInitialStep(): String
WorkflowDefinition.getNextStep(String, StepResult): String
global interface VersionedWorkflow extends WorkflowDefinition
VersionedWorkflow.getLatestVersion(): Integer
VersionedWorkflow.getNextStep(String, StepResult, Integer): String
global interface CalloutStep
global interface TimeoutConfigurable
TimeoutConfigurable.getTimeoutSeconds(): Integer
global interface CaptureProducer
CaptureProducer.produce(): Object
global interface RetryConfigurable
RetryConfigurable.getRetryPolicy(): RetryPolicy
global interface AutoRetryConfigurable
AutoRetryConfigurable.getAutoRetryPolicy(): RetryPolicy

# StepContext
global class StepContext
StepContext.workflowInstanceId: Id { get }
StepContext.workflowName: String { get }
StepContext.stepName: String { get }
StepContext.inputJson: String { get }
StepContext.previousStepOutput: String { get }
StepContext.stepStateJson: String { get }
StepContext.workflowInputJson: String { get }
StepContext.workflowVersion: Integer { get }
StepContext.attempt: Integer { get }
StepContext.previousRunAt: Datetime { get }
StepContext.idempotencyKey: String { get }
StepContext.isFinalAttempt(): Boolean
StepContext.shouldYield(): Boolean
StepContext.isCancellationRequested(): Boolean
StepContext.isCancellationRequested(Integer): Boolean
StepContext.logger(): StepLog
StepContext.progress(): StepProgress
StepContext.events(): StepEmitter
StepContext.signals(): StepSignals
StepContext.captures(): StepCaptures
StepContext.retry(): StepRetryInfo
global enum StepContext.Level { INFO, WARN, ERROR }
global class StepContext.Signal implements Comparable
StepContext.Signal.signalId: Id { get }
StepContext.Signal.name: String { get }
StepContext.Signal.payload: String { get }
StepContext.Signal.isPresent(): Boolean
global class StepContext.ChildOutcome
StepContext.ChildOutcome.status: String { get }
StepContext.ChildOutcome.errorMessage: String { get }
StepContext.ChildOutcome.output: String { get }
StepContext.ChildOutcome.isPresent(): Boolean
StepContext.ChildOutcome.isSuccess(): Boolean

# StepContext accessor objects
global class StepSignals
StepSignals.getSignals(): List<StepContext.Signal>
StepSignals.getSignals(String): List<StepContext.Signal>
StepSignals.getSignal(String): StepContext.Signal
StepSignals.hasSignal(String): Boolean
StepSignals.signalReadWasCapped(): Boolean
StepSignals.getChildOutcome(String): StepContext.ChildOutcome
StepSignals.getChildOutcomes(List<String>): List<StepContext.ChildOutcome>
global class StepCaptures
StepCaptures.once(String, CaptureProducer): Object
StepCaptures.patched(String): Boolean
StepCaptures.patched(String, DateTime): Boolean
StepCaptures.deprecated(String): void
StepCaptures.deprecated(String, DateTime): void
global class StepEmitter
StepEmitter.emit(SObject): void
global class StepLog
StepLog.log(StepContext.Level, String): void
StepLog.log(StepContext.Level, String, Map<String, Object>): void
global class StepProgress
StepProgress.reportProgress(Decimal, String): void
StepProgress.reportProgress(Object): void
global class StepRetryInfo
StepRetryInfo.maxAttempts: Integer { get }
StepRetryInfo.attemptCount: Integer { get }
StepRetryInfo.failedStepName: String { get }
StepRetryInfo.errorMessage: String { get }
StepRetryInfo.isTimeoutResume(): Boolean

# StepResult
global class StepResult
StepResult.directive(): StepResult.StepDirective
static StepResult.complete(String, Object): StepResult
static StepResult.yield(String): StepResult
static StepResult.suspend(): StepResult
static StepResult.suspend(Integer, String): StepResult
static StepResult.retry(RetryPolicy): StepResult
static StepResult.sleep(Integer): StepResult
static StepResult.sleep(Integer, String, String): StepResult
StepResult.withStepState(String): StepResult
static StepResult.startChild(String, String, Object): StepResult
static StepResult.startChildren(List<StepResult.ChildRequest>): StepResult
static StepResult.waitForApproval(String, String): StepResult
StepResult.withApprovalTimeout(Integer, String): StepResult
static StepResult.split(List<String>): StepResult
static StepResult.split(List<String>, Object): StepResult
static StepResult.continueAsNew(Object): StepResult
static StepResult.continueAsNew(Object, String): StepResult
static StepResult.fail(String): StepResult
static StepResult.fail(String, Object): StepResult
global class StepResult.StepDirective
StepResult.StepDirective.nextStepName: String { get }
StepResult.StepDirective.outputJson: String { get }
global class StepResult.ChildRequest
new StepResult.ChildRequest(String, String, Object)
StepResult.ChildRequest.workflowName: String { get }
StepResult.ChildRequest.correlationKey: String { get }
StepResult.ChildRequest.inputJson: String { get }

# RetryPolicy
global class RetryPolicy
new RetryPolicy()
new RetryPolicy(Integer, Double, Integer)
RetryPolicy.initialIntervalSeconds: Integer { get }
RetryPolicy.backoffCoefficient: Double { get }
RetryPolicy.maximumAttempts: Integer { get }
static RetryPolicy.fromConfig(): RetryPolicy

# Engine control
global class WorkflowEngine
static WorkflowEngine.start(String, String, Object): Id
static WorkflowEngine.start(WorkflowEngine.StartRequest): Id
static WorkflowEngine.start(List<WorkflowEngine.StartRequest>): List<Id>
static WorkflowEngine.startOrGet(String, String, Object): WorkflowEngine.StartResult
static WorkflowEngine.startOrGet(WorkflowEngine.StartRequest): WorkflowEngine.StartResult
static WorkflowEngine.startOrGet(List<WorkflowEngine.StartRequest>): List<WorkflowEngine.StartResult>
static WorkflowEngine.signal(String, String, String): void
static WorkflowEngine.signal(WorkflowEngine.SignalRequest): void
static WorkflowEngine.signal(List<WorkflowEngine.SignalRequest>): void
static WorkflowEngine.cancel(Id): void
global class WorkflowEngine.WorkflowException extends Exception
global class WorkflowEngine.StartRequest
new WorkflowEngine.StartRequest(String, String, Object)
WorkflowEngine.StartRequest.causationId: String
WorkflowEngine.StartRequest.priority: Integer
WorkflowEngine.StartRequest.withAttributes(Map<String, String>): WorkflowEngine.StartRequest
WorkflowEngine.StartRequest.withPriority(Integer): WorkflowEngine.StartRequest
global class WorkflowEngine.StartResult
WorkflowEngine.StartResult.instanceId: Id { get }
WorkflowEngine.StartResult.isNew: Boolean { get }
global class WorkflowEngine.SignalRequest
new WorkflowEngine.SignalRequest(String, String, String)
WorkflowEngine.SignalRequest.withDedupKey(String): WorkflowEngine.SignalRequest
WorkflowEngine.SignalRequest.withIdempotencyKey(String): WorkflowEngine.SignalRequest
global class WorkflowEngine.WorkflowStatus
WorkflowEngine.WorkflowStatus.instanceId: Id { get }
WorkflowEngine.WorkflowStatus.definitionName: String { get }
WorkflowEngine.WorkflowStatus.correlationKey: String { get }
WorkflowEngine.WorkflowStatus.status: String { get }
WorkflowEngine.WorkflowStatus.isTerminal: Boolean { get }
WorkflowEngine.WorkflowStatus.errorMessage: String { get }
WorkflowEngine.WorkflowStatus.output: String { get }
WorkflowEngine.WorkflowStatus.causationId: String { get }
global class WorkflowStatusRead
static WorkflowStatusRead.getStatus(Id): WorkflowEngine.WorkflowStatus
static WorkflowStatusRead.getStatus(String): WorkflowEngine.WorkflowStatus
static WorkflowStatusRead.getStatus(List<Id>): List<WorkflowEngine.WorkflowStatus>
static WorkflowStatusRead.getStatus(List<String>): List<WorkflowEngine.WorkflowStatus>

# Debounced start
global class WorkflowDebouncer
static WorkflowDebouncer.startDebounced(WorkflowDebouncer.DebounceRequest): void
static WorkflowDebouncer.startDebounced(List<WorkflowDebouncer.DebounceRequest>): void
global class WorkflowDebouncer.DebounceRequest
new WorkflowDebouncer.DebounceRequest(String, String, String)
WorkflowDebouncer.DebounceRequest.withDebounce(Integer): WorkflowDebouncer.DebounceRequest
WorkflowDebouncer.DebounceRequest.withMaxWait(Integer): WorkflowDebouncer.DebounceRequest

# Flow: Start Workflow
global class WorkflowStartInvocableAction
@InvocableMethod static WorkflowStartInvocableAction.startWorkflow(List<WorkflowStartInvocableAction.StartRequest>): List<WorkflowStartInvocableAction.StartResult>
global class WorkflowStartInvocableAction.StartRequest
new WorkflowStartInvocableAction.StartRequest()
@InvocableVariable(required=true) WorkflowStartInvocableAction.StartRequest.workflowName: String
@InvocableVariable(required=true) WorkflowStartInvocableAction.StartRequest.correlationKey: String
@InvocableVariable WorkflowStartInvocableAction.StartRequest.inputJson: String
@InvocableVariable WorkflowStartInvocableAction.StartRequest.attributesJson: String
@InvocableVariable WorkflowStartInvocableAction.StartRequest.causationId: String
@InvocableVariable WorkflowStartInvocableAction.StartRequest.priority: Integer
@InvocableVariable WorkflowStartInvocableAction.StartRequest.debounceSeconds: Integer
@InvocableVariable WorkflowStartInvocableAction.StartRequest.maxWaitSeconds: Integer
global class WorkflowStartInvocableAction.StartResult
@InvocableVariable WorkflowStartInvocableAction.StartResult.workflowInstanceId: Id
@InvocableVariable WorkflowStartInvocableAction.StartResult.isNew: Boolean
@InvocableVariable WorkflowStartInvocableAction.StartResult.isValid: Boolean
@InvocableVariable WorkflowStartInvocableAction.StartResult.validationError: String

# Flow: Signal Workflow
global class WorkflowSignalInvocableAction
@InvocableMethod static WorkflowSignalInvocableAction.signalWorkflow(List<WorkflowSignalInvocableAction.SignalRequest>): void
global class WorkflowSignalInvocableAction.SignalRequest
new WorkflowSignalInvocableAction.SignalRequest()
@InvocableVariable(required=true) WorkflowSignalInvocableAction.SignalRequest.targetKey: String
@InvocableVariable(required=true) WorkflowSignalInvocableAction.SignalRequest.signalName: String
@InvocableVariable WorkflowSignalInvocableAction.SignalRequest.payloadJson: String
@InvocableVariable WorkflowSignalInvocableAction.SignalRequest.idempotencyKey: String

# Flow: Get Workflow Status
global class WorkflowStatusInvocableAction
@InvocableMethod static WorkflowStatusInvocableAction.getStatus(List<WorkflowStatusInvocableAction.StatusRequest>): List<WorkflowStatusInvocableAction.StatusResult>
global class WorkflowStatusInvocableAction.StatusRequest
new WorkflowStatusInvocableAction.StatusRequest()
@InvocableVariable(required=true) WorkflowStatusInvocableAction.StatusRequest.workflowKeyOrId: String
global class WorkflowStatusInvocableAction.StatusResult
@InvocableVariable WorkflowStatusInvocableAction.StatusResult.found: Boolean
@InvocableVariable WorkflowStatusInvocableAction.StatusResult.workflowInstanceId: Id
@InvocableVariable WorkflowStatusInvocableAction.StatusResult.status: String
@InvocableVariable WorkflowStatusInvocableAction.StatusResult.isTerminal: Boolean
@InvocableVariable WorkflowStatusInvocableAction.StatusResult.isSuccess: Boolean
@InvocableVariable WorkflowStatusInvocableAction.StatusResult.outputJson: String
@InvocableVariable WorkflowStatusInvocableAction.StatusResult.errorMessage: String
@InvocableVariable WorkflowStatusInvocableAction.StatusResult.progressJson: String
@InvocableVariable WorkflowStatusInvocableAction.StatusResult.causationId: String
```

## Not Global

These stay namespace-private. The test fails if one of them gets `global`.

- Engine internals: `WorkflowOrchestrator*`, `WorkflowWatchdog*`, `Watchdog*`, finalizers, `*Job`, `*Controller` (dashboard), `*Sweep`, `*Sweeper`, `*SweepRunner`. The test also finds internals by structure: a class that implements `Queueable`, `Schedulable`, `Database.Batchable`, or `Finalizer`, and a class with `@AuraEnabled` members.
- Each member of a manifest type that is not in the manifest. Examples: `StepContext.Builder`, `StepContext.SignalSource`, `StepSignals.markMatched`, `StepResult.ActionType`, the other `StepDirective` data, `WorkflowEngine` configuration fields, `runStep`, `handleCrash`, `failWorkflowInstance`.
- `WorkflowEngine.StartRequest.withParent` and `parentInstanceId`. A subscriber could make a false parent link. Use `StepResult.startChild` or `startChildren`.

## Candidates

Not global in v1. Add one only when a subscriber needs it. You cannot remove a global member later.

- `WorkflowEngine.signalOrStart` and the Signal-or-Start invocable action.
- `WorkflowHistoryRead.getHistory`, `WorkflowHistoryRead.getStepError`, `WorkflowInstanceQuery.findInstances`.
- `RateLimiter.acquire`, `WorkflowResumeService.resumeInstance`, `WorkflowCancellation.cancelWithCompensations`.
- `WorkflowDebouncer.DebounceRequest.withAttributesJson` and `withCausationId`.
- `WorkflowEngine.StartRequest.inputJson`. `StepContext.Signal.createdDate`.
- `WorkflowBatchStep` as `global virtual`, with `bind()` and `Binding`, so a subscriber can extend it (issue #138). Today a subscriber uses the input JSON.
- Opt-in interfaces: `ExecutionTimeoutConfigurable`, `CircuitBreakerGuarded`, `ValidatedWorkflow`, `WorkflowCatalogDescribable`, `PayloadCodec`, `WorkflowArchiveSink`.
- Subscriber test support (do before the first release). `StepContextTestBuilder` and `WorkflowTestHarness` are `@IsTest`, so subscribers cannot see them. A subscriber test can run only one async hop. A subscriber needs a non-test context builder, a harness that drives more hops, and a way to read the result kind.

## Verify

```sh
npm install
npm run test:global-api
```

The test does these checks:

1. The `global` declarations in `force-app` are equal to the manifest.
2. Each `global` member is in a `global` type. Each `global` signature uses only `global` or system types. Each `global` interface extends only `global` interfaces. Each `global` class implements only `global` or system interfaces.
3. No engine internal has `global`.
4. Each `@InvocableMethod` and `@InvocableVariable` in a `global` class is `global`.
5. `GlobalApiSubscriberTest` writes no read-only `global` property. It calls no method that the stub keeps only to implement an interface (for example `compareTo`). apex-ls does not check setter access or `public` access across namespaces.
6. Packaged view: the test makes a stub project in namespace `rvn`. The stub holds only the `global` members, and the `public` methods that a class needs to implement an interface (for example `compareTo`). The test compiles the stub with apex-ls. Then it compiles `GlobalApiSubscriberTest` in namespace `acme` against the stub. The fixture must have zero errors. A probe that uses a namespace-private method and type must fail with exactly these two errors. Its call to a `global` method must pass.

Check 6 needs Java and apex-ls. Run `scripts/global-api/fetch-apex-ls.sh` one time (it needs Maven), or set `APEX_LS_CLASSPATH`. Without them, the test skips check 6. Set `REQUIRE_APEX_LS=1` to make the skip a failure.

`GlobalApiSubscriberTest` runs in the org. It uses only the global API. It starts a workflow, runs one async hop, and reads the terminal state.
