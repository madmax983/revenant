# Revenant Global API

This page lists each Apex type and member that code in a different namespace can use. In a managed package, subscriber code sees only `global` declarations. All other engine code is namespace-private.

Decision record: [ADR 0006](adr/0006-frozen-global-api.md). Issue: #122.

## Stability Policy

- The surface is frozen after the first package release. Do not remove, rename, or change a member in the manifest. Do not change a parameter, a return type, or an access level.
- Add a member only when a subscriber must use it. An addition is a new, frozen contract.
- To retire a member, add `@Deprecated` and keep its behavior. Do not delete it.
- Each change to the surface changes the manifest block below in the same commit. `npm run test:global-api` fails when the code and the manifest are different.
- A property with `{ get }` is read-only outside the package.

## Scope

- **Authoring SPI:** the step and definition interfaces, `StepContext` and its accessor objects, `StepResult`, `RetryPolicy`, `CaptureProducer`.
- **Control facade:** `WorkflowEngine` (`start`, `startOrGet`, `signal`, `cancel`) and `WorkflowStatusRead.getStatus`.
- **Flow:** the Start, Signal, and Get Workflow Status invocable actions.

`getStatus` is on `WorkflowStatusRead`, not on `WorkflowEngine`. The engine moved it there before this release. The README names `WorkflowStatusRead.getStatus` as the read contract.

## Use From A Subscriber Org

Put the package namespace before each type (example namespace: `rvn`):

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

Id instanceId = rvn.WorkflowEngine.start('acme.OrderWorkflow', 'order-42', null);
rvn.WorkflowEngine.WorkflowStatus status = rvn.WorkflowStatusRead.getStatus(instanceId);
```

The engine finds definition and step classes by name with `Type.forName`. Lookup of a class in a different namespace is issue #58.

## Manifest

One line for each declaration. The test reads the block below.

- `global <kind> <Type>`: a type. `extends` shows the super types. An enum shows its values.
- `<Type>.<method>(<parameter types>): <return type>`: a method. `static` is shown.
- `new <Type>(<parameter types>)`: a constructor. `new <Type>()` is also the default constructor of a `global` class with no explicit constructor.
- `<Type>.<name>: <type> { get }` or `{ get; set }`: a property.
- `<Type>.<name>: <type>`: a field (read and write).
- `@InvocableMethod` and `@InvocableVariable` show Flow members.
- Interface methods are `global` because the interface is `global`.

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
StepContext.logger(): StepLog
StepContext.progress(): StepProgress
StepContext.events(): StepEmitter
StepContext.signals(): StepSignals
StepContext.captures(): StepCaptures
StepContext.retry(): StepRetryInfo
global enum StepContext.Level { INFO, WARN, ERROR }
global class StepContext.Signal implements Comparable
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
RetryPolicy.initialIntervalSeconds: Integer { get; set }
RetryPolicy.backoffCoefficient: Double { get; set }
RetryPolicy.maximumAttempts: Integer { get; set }
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
WorkflowEngine.StartRequest.withAttributes(Map<String, String>): WorkflowEngine.StartRequest
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

# Flow: Start Workflow
global class WorkflowStartInvocableAction
@InvocableMethod static WorkflowStartInvocableAction.startWorkflow(List<WorkflowStartInvocableAction.StartRequest>): List<WorkflowStartInvocableAction.StartResult>
global class WorkflowStartInvocableAction.StartRequest
new WorkflowStartInvocableAction.StartRequest()
@InvocableVariable WorkflowStartInvocableAction.StartRequest.workflowName: String
@InvocableVariable WorkflowStartInvocableAction.StartRequest.correlationKey: String
@InvocableVariable WorkflowStartInvocableAction.StartRequest.inputJson: String
@InvocableVariable WorkflowStartInvocableAction.StartRequest.attributesJson: String
@InvocableVariable WorkflowStartInvocableAction.StartRequest.causationId: String
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
@InvocableVariable WorkflowSignalInvocableAction.SignalRequest.targetKey: String
@InvocableVariable WorkflowSignalInvocableAction.SignalRequest.signalName: String
@InvocableVariable WorkflowSignalInvocableAction.SignalRequest.payloadJson: String
@InvocableVariable WorkflowSignalInvocableAction.SignalRequest.idempotencyKey: String

# Flow: Get Workflow Status
global class WorkflowStatusInvocableAction
@InvocableMethod static WorkflowStatusInvocableAction.getStatus(List<WorkflowStatusInvocableAction.StatusRequest>): List<WorkflowStatusInvocableAction.StatusResult>
global class WorkflowStatusInvocableAction.StatusRequest
new WorkflowStatusInvocableAction.StatusRequest()
@InvocableVariable WorkflowStatusInvocableAction.StatusRequest.workflowKeyOrId: String
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

- Engine internals: `WorkflowOrchestrator*`, `WorkflowWatchdog*`, finalizers, `*Job`, `*Controller` (dashboard), `*Sweep`, `*Sweeper`.
- All other members of the classes above. Examples: `StepContext.Builder`, `StepContext.SignalSource`, `StepSignals.markMatched`, `StepResult.ActionType`, the other `StepDirective` data, `WorkflowEngine` configuration fields, `runStep`, `handleCrash`, `failWorkflowInstance`.

## Candidates

Not global in v1. Add one only when a subscriber needs it. An addition is safe. A removal is not.

- `WorkflowEngine.signalOrStart` and the Signal-or-Start invocable action.
- `WorkflowHistoryRead.getHistory`, `WorkflowHistoryRead.getStepError`, `WorkflowInstanceQuery.findInstances`.
- `WorkflowEngine.StartRequest.withParent`, `inputJson`, `parentInstanceId`.
- Opt-in interfaces: `RetryConfigurable`, `AutoRetryConfigurable`, `ExecutionTimeoutConfigurable`, `CircuitBreakerGuarded`, `ValidatedWorkflow`, `WorkflowCatalogDescribable`, `PayloadCodec`, `WorkflowArchiveSink`.
- A non-test step-context builder for subscriber unit tests. `StepContextTestBuilder` is `@IsTest`, so subscribers cannot see it.

## Verify

```sh
npm install
npm run test:global-api
```

The test does these checks:

1. The `global` declarations in `force-app` are equal to the manifest.
2. Each `global` member is in a `global` type. Each `global` signature uses only `global` or system types. Each `global` interface extends only `global` interfaces.
3. No engine internal has `global`.
4. Each `@InvocableMethod` and `@InvocableVariable` in a `global` class is `global`.
5. Packaged view (needs Java; run `scripts/global-api/fetch-apex-ls.sh` one time): the test makes a stub project in namespace `rvn` with only the `global` members. It compiles the stub and `GlobalApiSubscriberTest` in namespace `acme` with apex-ls. The result must have zero errors.

`GlobalApiSubscriberTest` runs in the org. It uses only the global API. It starts a workflow, runs one async hop, and reads the terminal state.
