# Revenant: Durable Workflow Engine for Salesforce

Revenant is a native, database-backed durable execution engine for Salesforce Apex, inspired by Temporal and DBOS. By orchestrating native platform features—Queueable Apex, Platform Events, Transaction Finalizers, and Apex Cursors—Revenant allows developers to build complex, reliable, and resumable state machines that survive transaction failures, governor limit exhaustion, and platform limits.

<img width="3726" height="1832" alt="Screenshot 2026-06-24 100608" src="https://github.com/user-attachments/assets/6056cf52-6918-45bc-bf20-03590460aa7d" />

> **Upgrading from an earlier build?** The public API was reshaped around request objects, `StepContext` accessor sub-objects (`ctx.signals()`, `ctx.events()`, `ctx.captures()`, …), and a fluent `StepResult` builder. See **[MIGRATION.md](MIGRATION.md)** for the full list of breaking changes and old→new mappings.

---

## Key Features

### Core Orchestration

- **Resumable Execution (Yielding)**: Long-running processing loops or query pagination steps can call `shouldYield()` to monitor governor limits. If limits are exceeded, the step checkpoints its state to custom objects and resumes execution transparently in a fresh asynchronous transaction.
- **Scatter-Gather (Parallel Processing)**: Split execution flow across multiple parallel branches and rejoin their output payloads before moving to subsequent steps. See [ParallelSagaFanoutWorkflowExample](examples/main/default/classes/ParallelSagaFanoutWorkflowExample.cls).
- **Continue-As-New (Perpetual Loops)**: Execute perpetual poller tasks or long-lived daemons. A step can request a transition to a new successor run linked via `Previous_Instance__c` to prevent storage footprint explosion and clear heap and debug log limits. The successor's `StepContext.previousRunAt` carries the engine-set timestamp of when the predecessor completed, so incremental polling workflows can query only records modified since the last run without any manual timestamp bookkeeping. See [docs/incremental-polling.md](docs/incremental-polling.md) and [IncrementalSyncWorkflowExample](examples/main/default/classes/IncrementalSyncWorkflowExample.cls).

### Fault Tolerance & Safety

- **Distributed Transaction Rollbacks (Sagas)**: Steps implementing [CompensatableStep](force-app/main/default/classes/CompensatableStep.cls) register on a LIFO rollback stack upon successful forward completion. If a forward step fails permanently, the engine automatically executes their `compensate` methods in reverse order.
- **Recoverable Rollbacks (Rollback Incomplete)**: If a `compensate()` step itself exhausts its `RetryPolicy` or throws mid-rollback, the engine preserves the remaining LIFO stack intact and parks the saga in a distinguishable, operator-visible **`CompensationFailed`** ("Rollback Incomplete") state instead of silently abandoning the deeper compensations. The dashboard surfaces exactly how many forward effects are still un-reversed and offers a **Resume Rollback** action that replays the remaining stack from the stalled point — idempotently, append-only, and without ever re-running a successful compensation or a forward step. See [SagaStalledRollbackExample](examples/main/default/classes/SagaStalledRollbackExample.cls).
- **Watchdog Step Timeouts**: Steps can declare custom execution timeouts. A single global watchdog poller ([WorkflowWatchdog](force-app/main/default/classes/WorkflowWatchdog.cls)) sweeps the database for any timed-out steps or suspended instances, failing or resuming them cleanly without hitting Salesforce's 100 concurrent scheduled jobs limit.
- **Large Payload Offloading**: When input, output, or state serialization strings exceed 100,000 characters (approaching the 131,072-character long text area limit), the engine transparently offloads the payload to `ContentVersion` files and links them to the parent instance.
- **Effective-Once Side Effects (Idempotency Keys)**: The engine guarantees only at-least-once execution, so `execute()` (and `compensate()`) can re-run on retries, operator re-drives, and at-least-once event resumes. [StepContext](force-app/main/default/classes/StepContext.cls) exposes a read-only `idempotencyKey` that is stable across every re-execution of the same logical step yet distinct per `(instance, step)`. Forward it to an external system (e.g. as a Stripe `Idempotency-Key` header) for effective-once side effects without inventing your own dedup token. See [IdempotentChargeWorkflowExample](examples/main/default/classes/IdempotentChargeWorkflowExample.cls).
- **Capture-Once Local Values (`once()`)**: Stabilizes values generated _locally_ inside a step — generated reference numbers, Crypto-random tokens, random branch decisions, timestamps — so they do not drift across retries, yield/resume cycles, at-least-once event resumes, or operator re-drives. `ctx.captures().once(key, producer)` invokes the producer at most once per `(instance, step, key)` and returns the same durably recorded value on every subsequent re-execution. Captures are JSON-normalized for durability, so producers should return JSON-native values (capture a timestamp as epoch millis or an ISO string rather than a native `Datetime`), and a capture becomes durable once the step reaches its next checkpoint (complete/yield/sleep/suspend/graceful retry). Contrast with `idempotencyKey`: use `idempotencyKey` to make an **external API call** effective-once; use `once()` to keep a **locally generated value** stable. Capture-once lives on the `ctx.captures()` accessor. See [CaptureOnceWorkflowExample](examples/main/default/classes/CaptureOnceWorkflowExample.cls).
- **Durable Rate Limiting (`RateLimiter`)**: Throttle outbound callouts to external APIs (e.g. Stripe, Slack) across many concurrent workflow instances. A step calls `RateLimiter.acquire(integrationKey)`. When the rate limit is exceeded (`isAllowed == false`), the step returns `StepResult.sleep(sleepDurationSeconds)` to suspend and resume once tokens refill, avoiding CPU-burning busy-tries and saga-rolling exceptions. Pair with `StepContext.idempotencyKey` to keep callouts effective-once. Note: Transient callout retries (via `RetryPolicy`) or manual operator re-drives bypass the limiter but are safely throttled by the retry back-off delay. See [ThrottledCalloutWorkflowExample](examples/main/default/classes/ThrottledCalloutWorkflowExample.cls).

### Integration & Monitoring

- **Platform Event Signaling**: External integrations, webhook listeners, or human-in-the-loop approvals wake up suspended workflows by publishing `Workflow_Event__e` platform events. The resuming step reads the inbound signal name and payload directly from `StepContext` via the signals accessor (e.g. `ctx.signals().getSignal('Approve:Order')`), and the engine marks observed signals consumed at the step's `COMPLETE` transition so at-least-once redelivered duplicates are never double-processed.
- **Effectively-Once Outbound Emit (`ctx.events().emit()`)**: A step can hand the engine one or more author-owned domain Platform Events to publish mid-workflow — `ctx.events().emit(new Order_Shipped__e(...))` — instead of calling `EventBus.publish()` itself. The engine buffers them and publishes them in the **same transaction that writes the step's append-only `COMPLETE`/`SPLIT` record**, before the next step begins, so retries, yields, suspends, operator re-drives, and at-least-once resumes that re-run `execute()` before that commit publish **nothing**, and a step already durably `COMPLETE` never re-executes and so never re-emits — producer-side effectively-once with no hand-rolled dedup token. Authors keep their own `__e` (use `publishBehavior=PublishAfterCommit`); the engine imposes no envelope. Delivery to subscribers stays at-least-once, so subscribers remain idempotent. This is the mid-flight outbound complement to inbound signals and the terminal lifecycle event. See [OrderChoreographyWorkflowExample](examples/main/default/classes/OrderChoreographyWorkflowExample.cls) (workflow A emits an event that starts workflow B).
- **Outbound Lifecycle Events**: The engine publishes a `Workflow_Lifecycle__e` platform event (outcome metadata only) each time an instance reaches a terminal state (`Completed`/`Failed`/`Compensated`/`Cancelled`), so a Flow **Pause** element or an external subscriber can react event-driven instead of polling — exactly one event per logical workflow (one per `ContinuedAsNew` chain). Fire-and-forget and operator-toggleable via `Revenant_Config__mdt.Publish_Lifecycle_Events__c`. See [docs/workflow-lifecycle-event.md](docs/workflow-lifecycle-event.md).
- **Salesforce Flow Interoperability**: Launches or signals workflows using Invocable Actions from Salesforce Flow, or executes standard Autolaunched Flows as steps within a workflow using the generic `WorkflowFlowStep` wrapper.
- **Custom Metadata Alerts**: Supports operator-configurable failure notification thresholds (consecutive failures, sliding rate counts) using `Workflow_Alert_Config__mdt` custom metadata records.
- **Concurrency Limits (In-Flight Ceiling)**: Declare a maximum number of simultaneously in-flight instances per workflow definition via a `Concurrency_Config__mdt` record (same DeveloperName + `Default`-fallback convention as alerts). A bursty start is throttled to a safe ceiling — instances beyond the limit park in a throttled state and re-attempt admission automatically through the existing sleep/watchdog plumbing, with the slot released on every terminal transition and leaked slots reclaimed by the watchdog. Distinct from `RateLimiter` (rate/throughput) and get-or-start dedup. See [docs/concurrency-limits.md](docs/concurrency-limits.md).
- **Declarative Recurring Schedules (0-slot)**: Create a `Workflow_Schedule__c` record to run any workflow on a cron cadence — no Apex, and **zero additional scheduled-job slots** beyond the existing watchdog. See [docs/recurring-schedules.md](docs/recurring-schedules.md).

---

## System Architecture

```mermaid
graph TD
    Start([Start Workflow]) --> Enqueue[Enqueue WorkflowOrchestrator]
    Enqueue --> Run[WorkflowOrchestrator runs runStep]
    Run --> Hydrate[Hydrate Instance & Step State]
    Hydrate --> Exec{Execute Step}

    Exec -- COMPLETE --> Next{Has Next Step?}
    Next -- Yes --> SaveStack[Append Compensatable Steps]
    SaveStack --> Run
    Next -- No --> Finish[Status: Completed]

    Exec -- YIELD / SLEEP --> Suspend[Save State & Suspend]
    Suspend --> Resume[Signal Event / Timer Fired]
    Resume --> Enqueue

    Exec -- ERROR / CRASH --> Fail{Has Compensation Stack?}
    Fail -- Yes --> TransitionComp[Status: Compensating]
    TransitionComp --> Rollback[Run Compensation Steps LIFO]
    Rollback --> CompSuccess{All Rollbacks Done?}
    CompSuccess -- Yes --> TerminalComp[Status: Compensated]
    CompSuccess -- No --> RollbackFail{Compensation Step Fails?}
    RollbackFail -- Yes --> TerminalFail[Status: Failed]
    RollbackFail -- No --> Rollback

    Fail -- No --> TerminalFail[Status: Failed]
    TerminalFail --> Alert[WorkflowAlertManager Evaluates CMDT & Sends Email]
```

---

## Developer Guide

### 1. Define a Step

To create a step, implement the [WorkflowStep](force-app/main/default/classes/WorkflowStep.cls) interface (or [CompensatableStep](force-app/main/default/classes/CompensatableStep.cls) if rollback logic is required):

```java
public class ProvisionSandboxStep implements CompensatableStep {

    /**
     * Executes forward step logic.
     */
    public StepResult execute(StepContext ctx) {
        // Business logic execution
        String sandboxId = 'sb_98765';

        // Return COMPLETE action and output payload
        return StepResult.complete(null, new Map<String, Object>{'sandboxId' => sandboxId});
    }

    /**
     * Executes rollback logic if a subsequent step in the DAG fails.
     */
    public StepResult compensate(StepContext ctx) {
        // Hydrate forward step state from the context
        Map<String, Object> state = (Map<String, Object>)JSON.deserializeUntyped(ctx.stepStateJson);
        String sandboxId = (String)state.get('sandboxId');

        // De-provision resources
        System.debug('Deprovisioning sandbox: ' + sandboxId);
        return StepResult.complete(null, 'Deprovisioned');
    }
}
```

### 2. Define the Workflow DAG

Create a class implementing [WorkflowDefinition](force-app/main/default/classes/WorkflowDefinition.cls) to model step transitions. The contract has three methods: `getSteps()` declares the complete step inventory (required — it is what [`WorkflowValidator`](force-app/main/default/classes/WorkflowValidator.cls) checks the DAG against, see §9), `getInitialStep()` names the entry point, and `getNextStep()` routes transitions:

```java
public class OnboardingWorkflow implements WorkflowDefinition {

    /**
     * Declares the complete list of steps involved in the workflow.
     */
    public List<String> getSteps() {
        return new List<String>{
            'VerifyOrderStep',
            'ProvisionSandboxStep',
            'SendWelcomeEmailStep'
        };
    }

    /**
     * Designates the starting step.
     */
    public String getInitialStep() {
        return 'VerifyOrderStep';
    }

    /**
     * Determines the next transition step based on the outcome of the active step.
     */
    public String getNextStep(String currentStepName, StepResult result) {
        if (currentStepName == 'VerifyOrderStep') {
            return 'ProvisionSandboxStep';
        }
        if (currentStepName == 'ProvisionSandboxStep') {
            return 'SendWelcomeEmailStep';
        }
        return null; // Null indicates terminal completion
    }
}
```

### 3. Initiate Execution

Execute the workflow asynchronously from any Apex context (Triggers, Controllers, or Queueables):

```java
// Parameters: WorkflowDefinition ClassName, Unique Correlation Key, JSON Input
Id instanceId = WorkflowEngine.start(
    'OnboardingWorkflow',
    'Opp_Onboarding_006As00000abcde',
    '{"accountId": "001As0000012345", "vipOnboarding": true}'
);
```

**The request-object pattern.** Every engine entry point that takes more than a name/key/payload now accepts a small **request object** instead of a long telescoping argument list — `WorkflowEngine.StartRequest`, `WorkflowEngine.SignalRequest`, `WorkflowEngine.SignalOrStartRequest`, and `WorkflowDebouncer.DebounceRequest`. Each has a constructor for its required fields and fluent `with*` setters for the optional ones, and each entry point has a `List<...>` overload for bulk calls. The three-argument `start(...)` and `signal(...)` shortcuts above still exist for the common case; reach for the request object when you need attributes, a parent link, a dedup/idempotency key, or bulk processing:

```java
// Attach searchable business attributes and a parent link at start.
Id instanceId = WorkflowEngine.start(
    new WorkflowEngine.StartRequest('OnboardingWorkflow', 'Opp_Onboarding_006As00000abcde', inputMap)
        .withAttributes(new Map<String, String>{ 'region' => 'EU' })
        .withParent(parentInstanceId)
);

// Signal with an explicit idempotency key for at-least-once event sources.
WorkflowEngine.signal(
    new WorkflowEngine.SignalRequest(correlationKey, 'Approve:Order', '{"approved":true}')
        .withIdempotencyKey(inboundEventId)
);
```

### 4. Read Inbound Signals & Approvals

A step that suspends for an approval (`StepResult.waitForApproval(...)`) or an external event (`StepResult.suspend()`) is woken by `WorkflowEngine.signal(keyOrId, name, payload)` (or a `SIGNAL:`-typed `Workflow_Event__e`). On resume, the step reads the signal that woke it directly from `StepContext` — no SOQL against engine-internal objects, and no hand-rolled "consumed" marker.

**Accessor sub-objects.** `StepContext` groups its step-facing primitives onto six accessor sub-objects rather than exposing dozens of methods on the context itself: `ctx.signals()` (read inbound signals and child outcomes), `ctx.events()` (buffer outbound Platform Events), `ctx.captures()` (capture-once / patch markers), `ctx.logger()` (step breadcrumbs), `ctx.progress()` (progress reporting), and `ctx.retry()` (attempt/failure metadata). Plain state — `ctx.workflowInputJson`, `ctx.stepStateJson`, `ctx.previousStepOutput`, `ctx.idempotencyKey`, `ctx.previousRunAt`, `ctx.attempt`, `ctx.shouldYield()` — stays directly on the context. So signal reads go through `ctx.signals()`:

```java
public StepResult execute(StepContext ctx) {
    // Most recent signal of this name; never null.
    StepContext.Signal decision = ctx.signals().getSignal('Approve:Order');

    if (!decision.isPresent()) {
        // First run (or resumed by a timer): nothing has signaled us yet.
        return StepResult.waitForApproval('Order', 'Manager');
    }

    Map<String, Object> payload =
        (Map<String, Object>) JSON.deserializeUntyped(decision.payload);
    Boolean approved = (Boolean) payload.get('approved');

    return approved
        ? StepResult.complete('ApproveStep', payload)
        : StepResult.complete('RejectStep', payload);
}
```

Accessors available inside `execute()` and `compensate()`:

| Accessor                         | Returns                                                                                                                                          |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ctx.signals().getSignals()`     | All pending signals, in arrival order (never null).                                                                                              |
| `ctx.signals().getSignals(name)` | Pending signals matching `name`, in arrival order.                                                                                               |
| `ctx.signals().getSignal(name)`  | The most recent pending signal of `name`, or a clean empty result (`isPresent() == false`, `payload == null`) when none is pending — never null. |
| `ctx.signals().hasSignal(name)`  | `true` if any pending signal matches `name`.                                                                                                     |

Consumption is engine-managed and tied to the step's successful `COMPLETE` (or `SPLIT`) transition: signals the step observes are marked consumed only once the step completes, so a step that yields or retries before completing re-observes the same pending signal, and an at-least-once redelivered duplicate cannot be reprocessed by a later step. Transitions that suspend and **re-run the same step** — `SUSPEND`, `WAIT_FOR_APPROVAL`, `SLEEP`, and `START_CHILD` — intentionally do _not_ consume, so the signal that resumes the step survives to be read. A `START_CHILD` step that also reads a kickoff signal should therefore check its child-completion signal before re-acting on the kickoff (or stash what it needs in step state). `Cancel` / `CancelWorkflow` control signals remain engine-handled and are never surfaced as readable payloads. See [`ApprovalSignalWorkflowExample`](examples/main/default/classes/ApprovalSignalWorkflowExample.cls) for a complete approve/reject example with a redelivery test.

#### Reading signals inside parallel branches

When a step reads a signal while running as one branch of a parallel (scatter-gather) fan-out, the engine **atomically claims** each signal it reads (moving it to an internal `Processing` state) so two concurrent branches can never both process the same payload; the claim is promoted to consumed when the branch completes, and rolled back if the branch yields/suspends/retries. Each branch consumes (and rolls back) only the signals it itself claimed, tracked per row, so it never disturbs a signal a sibling has claimed or merely observed. A parallel instance suspended on a signal is resumed branch-by-branch when the signal arrives, and a bulk signal to many parallel instances wakes their branches with a single platform-event publish.

Claims are bounded for governor safety. A branch that needs to inspect **many distinct signal names** should call `ctx.signals().getSignals()` once and filter in memory rather than issuing a separate `ctx.signals().getSignal(name)` / `ctx.signals().hasSignal(name)` lookup per name: each named claim is its own DML statement and lock query, so beyond an internal claim budget the overflow reads degrade to **at-least-once** (read without claiming) instead of failing. `getSignals()` claims a whole page in one statement and stays exactly-once. [`ParallelSignalFanInWorkflowExample`](examples/main/default/classes/ParallelSignalFanInWorkflowExample.cls) is the copyable reference for this fan-in pattern.

Because claiming writes uncommitted DML, a parallel-branch step that makes an **HTTP callout whose endpoint or body comes from the signal payload** must implement the [`CalloutStep`](force-app/main/default/classes/CalloutStep.cls) marker. Such a step reads signals _without_ claiming (at-least-once delivery instead of exactly-once), so the callout is legal; use distinct signal names per branch or idempotent callouts when relying on this mode. A `CalloutStep` may also be `TimeoutConfigurable`: the engine defers its pre-execution timeout write past `execute()` (and past `compensate()` for a `CalloutStep` that is also a `CompensatableStep`) so the synchronous callout is not blocked by uncommitted work (the step's timeout was already armed when it was queued, so the watchdog stays in effect).

**Recommended pattern — keep exactly-once _and_ the callout by splitting them into two steps.** The at-least-once `CalloutStep` mode above exists because a single step cannot atomically own two un-rollback-able concerns: a signal _claim_ is transactional DML, but an HTTP callout is not, and the two cannot be made to commit or roll back together. Rather than dropping the signal claim to at-least-once, give each concern its own step:

1. A **signal-wait step** reads the signal the normal (claiming) way — pure transactional DML, so consumption stays **exactly-once** — and on receipt transitions (`StepResult.complete('DoCallout', payload)`) to
2. A **callout step** that issues the HTTP callout from the payload it was handed. With no signal claim in its transaction, this is an ordinary callout the engine already makes safe (continuation + deferred timeout), so its only commit concern is the callout itself.

This decomposition removes the claim-vs-callout conflict entirely: the signal is consumed exactly once in step 1, and the callout in step 2 carries no uncommitted signal DML. Reach for the inline `CalloutStep`+signal mode only when the callout must react to the signal _in place_ — e.g. a compensating callout fired in response to a signal during unwind, where the wait and the callout cannot be pre-split — and make that callout idempotent.

#### Compensation Stack Contract for Parallel Workflows

When orchestrating parallel (scatter-gather) branches that implement `CompensatableStep`, the engine maintains a strict, durable compensation contract:

- **Push (Forward Phase)**: As each parallel branch step completes successfully, it appends its step name atomically to `Compensation_Stack__c` on the `Workflow_Instance__c` record. The push order corresponds exactly to the real-time completion order of the branches.
- **Pop (Rollback Phase)**: If one branch fails, the engine transitions the instance to `Compensating`. Sibling branches that are in-flight or pending are not compensated (only steps successfully completed and recorded in `Compensation_Stack__c` have their `compensate()` method invoked). Note that under standard compensation routing, pending sibling step execution records remain in their current state in the database and are not automatically updated to `Cancelled`. The engine then pops completed branch steps from `Compensation_Stack__c` one by one in LIFO (Last-In-First-Out) order, executing their `compensate()` methods in the exact reverse order of their forward completion.
- **Idempotency & Redelivered Signals**: Late-arriving completion signals for cancelled branches, or redelivered duplicate completion signals for completed branches during rollback, are safely ignored by the engine. They do not trigger a re-run of any `compensate()` method or forward execution.

See [ParallelSagaFanoutWorkflowExample](examples/main/default/classes/ParallelSagaFanoutWorkflowExample.cls) for a complete reference implementation and [ParallelSagaFanoutWorkflowExampleTest](examples/main/default/classes/ParallelSagaFanoutWorkflowExampleTest.cls) for the integration and redelivery tests.

### 5. Wait for a Human Approval

The suspend→signal→resume pattern combined with saga rollback on rejection is the most common enterprise durable-workflow shape — and the one that native Approval Processes cannot express, because they have no durable multi-step orchestration or compensating rollback. [`ApprovalWorkflowExample`](examples/main/default/classes/ApprovalWorkflowExample.cls) is the copyable reference. Three elements work together:

**1. A compensatable forward step** — any step that implements `CompensatableStep` and does real work before the approval gate. The engine pushes its name onto `Compensation_Stack__c` when it completes, so the work can be automatically rolled back if the workflow is later rejected.

**2. The approval gate** — a `WorkflowStep` that reads the inbound decision signal from `StepContext` and surfaces the payload as its output, leaving routing to the DAG:

```java
public StepResult execute(StepContext ctx) {
    StepContext.Signal decision = ctx.signals().getSignal('Approve:PurchaseApproval');

    if (!decision.isPresent()) {
        // First run: nothing decided yet -- suspend until an approver signals the workflow.
        // The second argument is an optional Custom Permission API name the dashboard
        // requires an approver to hold; null leaves the gate unrestricted (pass e.g.
        // 'Workflow_Admin' to restrict who may decide).
        return StepResult.waitForApproval('PurchaseApproval', null);
        // Need a deadline? Chain the fluent timeout instead of a longer arg list:
        //   return StepResult.waitForApproval('PurchaseApproval', null)
        //       .withApprovalTimeout(86400, 'PurchaseApprovalTimedOut');
    }

    // Resume: forward the decision payload; getNextStep() will route to approve or reject.
    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(decision.payload);
    return StepResult.complete(null, payload);
}
```

**3. DAG-level approve/reject routing** in `getNextStep()`:

```java
public String getNextStep(String currentStepName, StepResult result) {
    if (currentStepName == 'ApprovalWorkflowExample.RequestApprovalStep') {
        Map<String, Object> decision =
            (Map<String, Object>) JSON.deserializeUntyped(result.directive().outputJson);
        Boolean approved = (Boolean) decision.get('approved');
        return approved
            ? 'ApprovalWorkflowExample.PlaceOrderStep'
            : 'ApprovalWorkflowExample.RejectStep';
    }
    ...
}
```

**Delivering the decision.** An Admin or Flow Builder uses the **Signal Workflow** invocable action (`WorkflowSignalInvocableAction`) with:

- _Correlation Key / Instance ID_ — the workflow correlation key (or instance Id)
- _Signal Name_ — `Approve:PurchaseApproval` (i.e. `Approve:` + the approval key passed to `waitForApproval`)
- _Payload JSON_ — `{"approved":true}` or `{"approved":false,"reason":"..."}`

From Apex the equivalent call is:

```java
WorkflowEngine.signal(correlationKey, 'Approve:PurchaseApproval', '{"approved":true}');
```

**Saga rollback on rejection.** The reject step throws a `WorkflowEngine.WorkflowException`. Because the prior `CompensatableStep` is on `Compensation_Stack__c`, the engine automatically calls its `compensate()` method in LIFO order — reading the original step output from `ctx.stepStateJson` to retrieve any resource identifiers — and the instance reaches `Compensated` when the rollback is done. No additional wiring is required: the stack is maintained by the engine whenever a `CompensatableStep` completes on the forward path.

**Deliberate, terminal failures — `StepResult.fail(reason)`.** For a _planned_ business-rule failure ("order already refunded", "account closed", "KYC rejected"), return `StepResult.fail(reason)` instead of throwing. Unlike a thrown exception — which surfaces an Apex stack trace in `Error_Message__c` / on the dashboard — `fail()` records your operator-readable `reason` verbatim and stops the workflow in **zero retry hops** (it is Revenant's non-retryable / permanent-failure primitive, the terminal counterpart to opt-in `StepResult.retry(policy)`). It honors the same compensation contract: with a non-empty `Compensation_Stack__c` the instance transitions to `Compensating` and runs `compensate()` LIFO; with no stack it goes straight to `Failed`. Pass structured data with `StepResult.fail(reason, failureData)` — it is persisted on the failing step's `Error_Details__c` for downstream compensation/alerting to inspect.

```java
public StepResult execute(StepContext ctx) {
    if (orderAlreadyRefunded(ctx)) {
        return StepResult.fail(
            'Order already refunded',
            new Map<String, Object>{ 'orderId' => ctx.signals().getSignal('Order').payload }
        );
    }
    ...
}
```

### 5b. Bridging a native Approval Process (Standard Case Example)

Revenant hooks directly into Salesforce's **native Approval Process** (and the standard **Approval Requests** tab, Approvals Home page, and standard related lists) without requiring custom LWC pages or new objects. Standard SObjects (like `Case` or `Opportunity`) that already undergo approval processes can drive and resume Revenant workflows.

[`NativeApprovalWorkflowExample`](examples/main/default/classes/NativeApprovalWorkflowExample.cls) is the reference for wiring the two together using the standard `Case` object and a clean Apex-trigger bridge:

1. **Start & Submission**: When a `Case` is created, the after-insert trigger [`CaseApprovalBridgeTrigger`](examples/main/default/triggers/CaseApprovalBridgeTrigger.trigger) starts the workflow (using the `Case.Id` as the correlation key). When the workflow reaches `RequestApprovalStep`, the step automatically queries the Case and submits it into the native Salesforce Approval Process (`Case.Revenant_Trigger_Approval_Example.approvalProcess-meta.xml`).
2. **Approval Request Inbox**: The record immediately appears in the standard Salesforce **Approval Requests** tab (listing the native `ProcessInstanceWorkitem`). The designated approver reviews and approves/rejects it there.
3. **Resume Hook**: On approval/rejection, the native process performs a field update to `Case.Approval_Status__c` (e.g., setting it to `'Approved'` or `'Rejected'`).
4. **Trigger Signal**: The after-update trigger (`CaseApprovalBridgeTrigger`) detects this status change, queries the approver's comments from `ProcessInstanceStep`, and calls `WorkflowEngine.signal()` to resume the suspended workflow.

This approach keeps your implementation completely standard, bulk-safe by construction, and fully testable in Apex unit tests ([`NativeApprovalTriggerBridgeExampleTest`](examples/main/default/classes/NativeApprovalTriggerBridgeExampleTest.cls)).

Revenant still contributes what a native Approval Process cannot express on its own: durable multi-step orchestration and saga rollback on rejection (`ReserveBudgetStep` unwinds via `Compensation_Stack__c` automatically if rejected).

This is example-only wiring on the standard `Case` object: the trigger fires on every Case in the org, not just demo records, which is fine for a reference example but would need scoping (e.g. a dedicated Record Type) before adapting this for a real deployment where `Case` already carries other business processes.

### 6. Parent→Child Workflow Composition

The engine ships full parent→child orchestration: `StepResult.startChild()` suspends the parent, runs the child in its own durable Queueable chain, and resumes the parent via a `ChildCompleted:<childKey>` Platform Event when the child **successfully completes**. [`ChildWorkflowCompositionExample`](examples/main/default/classes/ChildWorkflowCompositionExample.cls) is the copyable reference — a loan-application parent that delegates credit scoring to a child and then branches on the child's score.

**Contract that authors must get exactly right**

| Concern               | Rule                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Suspend**           | Return `StepResult.startChild(childWorkflowName, childKey, input)` from the step that launches the child. The engine suspends the parent automatically — do **not** also return `StepResult.suspend()`.                                                                                                                                                                                                                                                      |
| **Child output**      | The child's final outcome (status, error message, and output) can be read with `ctx.signals().getChildOutcome(childKey)`. This is the preferred way to distinguish a successful child from a failed, compensated, or cancelled one without hand-rolled SOQL. For backward compatibility, the successful child's final output still arrives as the payload of the `ChildCompleted:<childKey>` signal (read with `ctx.signals().getSignal("ChildCompleted:" + childKey).payload`). |
| **Idempotent resume** | The step that launched the child also handles the resume: check for the child outcome first, then act on it. Return `StepResult.complete()` (not `suspend()`) on the resume path — returning COMPLETE triggers engine-managed signal consumption, so an at-least-once redelivered duplicate completion or failure event cannot double-advance the parent.                                                                                                    |
| **Idempotent launch** | The engine automatically dedupes child launches against the deterministic `(Parent_Instance__c, Correlation_Key__c)` pair. If `startChild()` is called again during a re-entrant hop or watchdog re-check, and the active child already exists, the engine resolves to an idempotent re-suspend without starting a duplicate or failing the parent.                                                                                                          |
| **Cancellation**      | `WorkflowEngine.cancel(parentId)` cancels the parent and all of its active descendants (root-first traversal over `Parent_Instance__c`), so explicitly cancelling a parent reaps its in-flight children. (Use `WorkflowCancellation.cancelWithCompensations(parentId)` — the compensating-cancel entry point lives on `WorkflowCancellation`, not the engine — to also run each cancelled instance's compensation stack.)                                                                                                                                                                                                                                              |

**Caveats (failure paths are not auto-handled).** This contract covers parent→child composition. One failure mode still needs explicit handling in a production composite:

- **A parent that _fails_ does not cascade to its children.** `failWorkflowInstance()` does not traverse `Parent_Instance__c`; only explicit `WorkflowEngine.cancel()` reaps descendants. A failing parent leaves its in-flight children running unless you cancel them.

**Minimal launcher + resume step**

```java
public class RequestCreditCheckStep implements WorkflowStep {
    public StepResult execute(StepContext ctx) {
        String childKey = 'CreditCheck_' + ctx.workflowInstanceId;
        StepContext.ChildOutcome outcome = ctx.signals().getChildOutcome(childKey);

        if (outcome.isPresent()) {
            if (outcome.isSuccess()) {
                // Resume: read the child's output.
                Map<String, Object> childResult = (Map<String, Object>) JSON.deserializeUntyped(
                    WorkflowPayloadOffload.resolvePayload(outcome.output)
                );
                // ... inspect childResult and return StepResult.complete(nextStep, output)
            } else {
                // Fallback: child failed, compensated, or was cancelled.
                // ... handle failure (e.g. route to a fallback step)
            }
        }

        // First run or re-entrant hop: start the child and suspend.
        // The engine handles re-entrancy idempotently (no duplicate is started).
        Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(ctx.workflowInputJson);
        return StepResult.startChild('MyChildWorkflow', childKey, input);
    }
}
```

The correlation key format `'<prefix>_' + ctx.workflowInstanceId` guarantees uniqueness across concurrent parent instances while remaining stable across retries of the same step.

### 7. Flow Interoperability (Start, Signal, Read)

Flow Builders interact with the engine through supported Invocable Actions (category **Revenant Workflows**) — no internal field API names required:

| Action                  | Apex Class                      | Purpose                                                        |
| ----------------------- | ------------------------------- | -------------------------------------------------------------- |
| **Start Workflow**      | `WorkflowStartInvocableAction`  | Launch a durable workflow, returning its Instance Id.          |
| **Signal Workflow**     | `WorkflowSignalInvocableAction` | Send a signal (approve, cancel, resume) to a running instance. |
| **Get Workflow Status** | `WorkflowStatusInvocableAction` | Read an instance's outcome back into Flow (read-only).         |

**Reading a workflow's outcome.** _Get Workflow Status_ accepts **either** a `Workflow_Instance__c` Id **or** a Correlation Key and returns typed outputs a Decision element can branch on:

- `found` — `false` (instead of a fault) when nothing matches the key/Id.
- `status` — the raw `Status__c` value (e.g. `Running`, `Completed`, `Failed`).
- `isTerminal` — `true` once the workflow has finished (`Completed`/`Failed`/`Compensated`/`Cancelled`).
- `isSuccess` — `true` only for `Completed`.
- `outputJson` — the workflow output, **fully rehydrated** even when it was offloaded to ContentVersion (>100k); never the raw storage pointer.
- `errorMessage` — failure detail from `Error_Message__c`.

The action is **strictly read-only** (no transition, enqueue, signal, schedule, or DML) and bulk-safe across Flow batch sizes. Lookup behavior differs by identifier, which matters for workflows that use `ContinueAsNew`:

- **By Correlation Key** — automatically follows the **`ContinuedAsNew`** chain and reports the live/terminal successor rather than a stale predecessor. **Use the correlation key for outcome polling whenever a workflow may continue-as-new.**
- **By Instance Id** — reads _that exact instance_ and deliberately does **not** follow the chain (an Id is a precise handle). The Id returned by _Start Workflow_ points at the original generation, so polling that saved Id on a continue-as-new workflow would keep reading the predecessor and miss the successor's outcome.

> Note: a single read returns the full rehydrated `outputJson` even for offloaded (>100k) payloads. A Flow batch that polls _many_ instances whose outputs are _all_ large/offloaded materializes them all at once and can approach the Apex heap limit; use smaller batch sizes for that case.

**Reference recipe** — start a workflow, then later branch on its outcome:

1. A record-triggered Flow calls **Start Workflow** (`workflowName`, a stable `correlationKey`, optional `inputJson`).
2. Later (a scheduled Flow, a screen action, or a subsequent automation) calls **Get Workflow Status**, passing that same `correlationKey` (preferred — it resolves continue-as-new chains; the saved Id only reads the original generation).
3. A **Decision** element branches: `found = false` → not found; `isSuccess = true` → success path; `status = Failed` → surface `errorMessage`; `isTerminal = false` → keep waiting; default → ended without success (e.g. Cancelled/Compensated).

The autolaunched Flow `Revenant_Read_Workflow_Status_Example` (`examples/main/default/flows/`) implements step 2–3 verbatim.

**Executing Flows as Steps.** The engine provides a bundled step class `WorkflowFlowStep` to execute standard Autolaunched Flows as steps within a workflow:

- The step's input JSON is expected to be a JSON object with:
  - `flowName` (String, required): The developer name of the Autolaunched Flow to invoke.
  - `variables` (Map, optional): Key-value pairs representing the input variables passed to the Flow.
- The step returns a `StepResult.complete` with the Flow's output parameters as its JSON output.

**At-Most-Once Flow Execution Guarantee.** Because step bodies are executed under an _at-least-once_ contract, the engine guards `WorkflowFlowStep` using its capture-once (`once()`) idempotency machinery. The first time a Flow is executed for a given step visit, its output parameters are durably recorded in the step's audit log (`Captured_Values__c`). On any subsequent sequential re-execution (due to a watchdog sweep or stray orchestrator hop), the engine retrieves the original Flow outputs directly from the audit log without re-invoking the Flow, preventing duplicate Flow-driven DML, emails, or callouts.

_Honest Boundary:_ The guard is best-effort under concurrent re-hops (mirroring the engine's general terminal-window deduplication boundary). Flow Builders whose Flows interact with external systems should still design their Flow logic to tolerate at-least-once invocation where possible.

### 8. Read a Workflow's Result (Apex)

For Apex callers — ISVs, trigger handlers, batch jobs, invocable wrappers — `WorkflowStatusRead.getStatus` is the **supported read contract** (it returns the `WorkflowEngine.WorkflowStatus` DTO). Do not query `Workflow_Instance__c` fields directly: the field names are internal, and `Output__c` silently holds a storage pointer (not the real value) when the output exceeds 100k characters.

```java
// By instance Id (precise handle — does not follow ContinuedAsNew chains)
WorkflowEngine.WorkflowStatus ws = WorkflowStatusRead.getStatus(instanceId);

// By correlation key (preferred for polling — picks the live/latest run)
WorkflowEngine.WorkflowStatus ws = WorkflowStatusRead.getStatus(correlationKey);

// Bulk variants (constant SOQL, regardless of list size)
List<WorkflowEngine.WorkflowStatus> results = WorkflowStatusRead.getStatus(idList);
List<WorkflowEngine.WorkflowStatus> results = WorkflowStatusRead.getStatus(keyList);
```

**`WorkflowStatus` fields:**

| Field            | Type      | Description                                                                                                                                                                                                                                                     |
| ---------------- | --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `instanceId`     | `Id`      | The `Workflow_Instance__c` record Id.                                                                                                                                                                                                                           |
| `definitionName` | `String`  | The workflow class name (`Workflow_Name__c`).                                                                                                                                                                                                                   |
| `correlationKey` | `String`  | The correlation key the instance was started with.                                                                                                                                                                                                              |
| `status`         | `String`  | Raw `Status__c` value (e.g. `Running`, `Completed`, `Failed`).                                                                                                                                                                                                  |
| `isTerminal`     | `Boolean` | `true` when the workflow has reached a final state (`Completed`, `Failed`, `Compensated`, or `Cancelled`).                                                                                                                                                      |
| `errorMessage`   | `String`  | Failure detail from `Error_Message__c`; `null` unless the instance failed.                                                                                                                                                                                      |
| `output`         | `String`  | The **fully rehydrated** output string for terminal instances — transparently resolved from ContentVersion when the output was offloaded (>100k chars). `null` for non-terminal instances; blank string (`""`) for a terminal instance that produced no output. |

**Key semantics:**

- `output` is `null` for in-flight instances. `isTerminal = true` with `output = ""` means the workflow completed successfully with no output — this is distinct from a still-running instance.
- The **Id** overloads cost **at most 2 SOQL queries** (one for the instance(s), at most one more for ContentVersion rehydration) and **zero DML**. The **correlation-key** overloads resolve each key's winning instance from metadata first and fetch outputs only for the winners, costing a **small constant number of SOQL queries regardless of list size** (and **zero DML**) — bounded per key, so a single hot key reused across many terminal runs can neither crowd out other requested keys nor exhaust the heap. All overloads are safe to call from any Apex context.
- By correlation key, the active/live run is preferred over a recently-terminal one when a key has been reused. Lookup is case-insensitive (matching the correlation-key fields) and follows `ContinuedAsNew` chains via the shared root key, so polling the original key — **or any intermediate successor key** — returns the live/final successor, not a stale predecessor. `null` is returned (not an exception) when nothing matches.
- **Known limitation — don't reuse a chain's correlation key for an unrelated run while that chain is live.** Chain following matches on the shared `Root_Correlation_Key__c`, which a continue-as-new chain shares with _any_ independent run that reuses the same key. If you start a separate workflow with a correlation key that is also the root of a still-live continue-as-new chain, polling an intermediate successor key of that chain may resolve to the unrelated reused run. Use distinct correlation keys per logical workflow (the normal case) to avoid this; precise disambiguation would require walking the `Previous_Instance__c` lineage, which is intentionally out of scope to keep `getStatus` bounded and constant-SOQL.

### 9. Validate a Workflow Definition (Apex)

A `WorkflowDefinition` is otherwise only exercised at runtime: the engine resolves each step class lazily via `Type.forName` as it reaches it, so a typo'd successor, an entry point missing from `getSteps()`, or a step name that doesn't resolve to a real `WorkflowStep` only surfaces **mid-execution — after earlier forward steps (and their side effects) have already committed**, triggering a real compensation rollback in production. `WorkflowValidator` moves that detection to authoring/deploy time.

Call `WorkflowValidator.validate(workflowClassName)` — typically from an Apex test that runs in CI before deploy. It is **strictly read-only**: it creates no `Workflow_Instance__c`, writes no `Workflow_Step_Execution__c`, touches no compensation state, publishes no platform events, and enqueues no jobs. A single call returns **every** structural defect found (not just the first), each naming the offending step:

```java
@isTest
static void onboardingWorkflowIsWellFormed() {
    WorkflowValidator.ValidationResult result =
        WorkflowValidator.validate('OnboardingWorkflow');

    System.assert(
        result.isValid(),
        'OnboardingWorkflow DAG is malformed: ' + result.getMessages()
    );
}
```

`validate` flags: a definition class that doesn't resolve or doesn't implement `WorkflowDefinition`; a `getInitialStep()` that is blank or not contained in `getSteps()`; any `getSteps()` entry that doesn't resolve to an instantiable `WorkflowStep`/`CompensatableStep`; and duplicate `getSteps()` entries. It additionally runs a **best-effort** transition probe that drives `getNextStep(...)` for each declared step and flags any returned successor not in `getSteps()` — best-effort because `getNextStep` is data-dependent and cannot be fully enumerated. Inspect `result.defects` (each has a `code`, `stepName`, and `message`) or `result.getMessages()` for the full list. This is why `getSteps()` is part of the `WorkflowDefinition` contract: it is the authoritative step inventory the validator checks the DAG against.

Where `WorkflowValidator` checks the _definition's shape_, the next section validates _each invocation's payload_.

---

### 10. Validate Start Input Against a Contract (opt-in)

`WorkflowEngine.start(name, key, json)` and the **Start Workflow** invocable accept an opaque payload: a missing or misspelled field (`accountId` vs `AccountId`) is invisible until the first step dereferences it deep inside an async Queueable, surfacing as a cryptic `NullPointerException` on a `Failed` instance that a Flow builder can't diagnose. A workflow can **opt in** to synchronous, field-level start-input validation by implementing **`ValidatedWorkflow`** alongside `WorkflowDefinition`:

```java
public class OnboardingWorkflow implements WorkflowDefinition, ValidatedWorkflow {
    public WorkflowInputContract getInputContract() {
        return new WorkflowInputContract()
            .require('accountId', WorkflowInputType.STRING_TYPE)
            .require('amount', WorkflowInputType.DECIMAL_TYPE)
            .optional('vipOnboarding', WorkflowInputType.BOOLEAN_TYPE)
            .optional('startDate', WorkflowInputType.DATE_TYPE);
    }
    // ... getSteps() / getInitialStep() / getNextStep() as usual
}
```

A `WorkflowInputContract` is an ordered list of field specs — `require(name, type)` (must be present and non-null) and `optional(name, type)` (type-checked only when present). The seven `WorkflowInputType` primitives, each type-checked **strictly** and **without ever mutating the payload**:

| `WorkflowInputType` | Accepts (JSON) |
| ------------------- | -------------- |
| `STRING_TYPE`            | A JSON string. |
| `INTEGER_TYPE`           | A whole-number JSON value in the 32-bit range (not a fractional number or a numeric string). |
| `LONG_TYPE`              | A whole-number JSON value (not a fractional number or a numeric string). |
| `DECIMAL_TYPE`           | Any JSON number. |
| `BOOLEAN_TYPE`           | A JSON boolean (`true`/`false`, not `"true"`). |
| `DATE_TYPE`              | An ISO-8601 date (`yyyy-MM-dd`) — as a JSON string, **or** a native Apex `Date` in a `Map` input. |
| `DATETIME_TYPE`          | An ISO-8601 datetime — as a JSON string, **or** a native Apex `Datetime` in a `Map` input. |

The issue's generic **Number** maps to **`DECIMAL_TYPE`** (any JSON numeric); reach for `INTEGER_TYPE`/`LONG_TYPE` when the field must be a whole number.

**One rule, every input form.** Validation normalizes the start payload through the same JSON round-trip the engine uses to persist it (`JSON.serialize` → `JSON.deserializeUntyped`), so a value validates identically whether the caller passes an `inputJson` string, a `Map<String, Object>`, or a typed Apex object. A native Apex `Date`/`Datetime` handed in a `Map` is checked by its ISO form (as `DATE_TYPE`/`DATETIME_TYPE`), matching the JSON-string form — so the two entry forms never disagree. (This is an additive, permissive broadening of the accepted inputs; it rejects nothing that was previously accepted.)

**Fully backward compatible and free for the simple case.** A definition that does _not_ implement `ValidatedWorkflow` is never inspected — detection is a single in-memory `instanceof` on the already-resolved definition. Validation adds **zero SOQL and zero DML** to the start path and nothing to the `WorkflowOrchestrator` Queueable hot path; it is a pure parse-and-check that runs **before any `Workflow_Instance__c` is inserted and before any job is enqueued**, so the append-only audit trail is untouched on rejection.

**Apex (scalar & bulk).** On invalid input, `start(...)` / `startOrGet(...)` throw a typed **`WorkflowInputException`** whose message enumerates **every** bad field (not just the first), with the structured list also available via `ex.getFieldErrors()` (each a `WorkflowInputFieldError` carrying `fieldName`, a `reason` of `MISSING` / `WRONG_TYPE` / `MALFORMED_JSON`, and the expected/actual type). Malformed JSON is reported as an input error, never as an uncaught `JSONException`. No instance row is created.

```java
try {
    WorkflowEngine.start('OnboardingWorkflow', key, '{"amount":"lots"}');
} catch (WorkflowInputException ex) {
    // ex.getMessage() enumerates: accountId is required but missing;
    //   amount expected DECIMAL_TYPE but was String
    for (WorkflowInputFieldError fe : ex.getFieldErrors()) { /* fe.fieldName, fe.reason ... */ }
}
```

The bulk `startOrGet(List<StartRequest>)` validates every request up front and, consistent with the pipeline's existing all-or-none semantics, throws a single `WorkflowInputException` enumerating every bad field across every offending request (tagged `request[i]`) — writing no rows for any request in the batch.

**Flow (Start Workflow invocable).** Instead of a hard Flow fault, the invocable returns a **branchable** result: on invalid input the row carries `Is Valid = false` and a `Validation Error` string enumerating the bad fields (and no instance is started), while valid rows carry `Is Valid = true`, `Validation Error = null`, and proceed. A Flow Decision routes bad input declaratively, and one invalid row never aborts its valid siblings. See [`ValidatedOnboardingWorkflowExample`](examples/main/default/classes/ValidatedOnboardingWorkflowExample.cls) for a copyable reference.

**Two-layer semantics — atomic in bulk Apex, per-row at the invocable.** The two entry points reject invalid input on deliberately different contracts, and the difference is by design:

- **Bulk Apex (`WorkflowEngine` bulk start): ATOMIC validation.** If any request's input is invalid, the whole batch is rejected with a single `WorkflowInputException` enumerating **every** bad field across **all** offending requests, and **zero** rows are written — fix all and retry. This preserves the engine's all-or-none bulk invariant: a validation-only partial-success would make bulk semantics mode-dependent (validation errors partial-succeeding while DML errors roll everything back), which is incoherent for programmatic callers.
- **Flow invocable (`WorkflowStartInvocableAction`): PER-ROW routing.** Each row is validated independently; an invalid row returns `isValid=false` + `validationError` (no Flow fault) while valid sibling rows still start. Per-row independence lives here because this is where the acceptance criterion's motivation lives — Flow can't catch Apex exceptions.

If a per-row, non-aborting **bulk Apex** API is ever needed, the additive path is a `validationError` field on `WorkflowEngine.StartResult` (deferred; not in v1).

---

## Operations & Alerting Configuration

Revenant supports Custom Metadata-driven failure alerting. Operators can configure notifications directly in Salesforce Setup without code modifications by creating **Workflow Alert Config** (`Workflow_Alert_Config__mdt`) records:

### Mapping Workflow Definitions to Alert Configurations

The engine maps a workflow's class name to a custom metadata record's `DeveloperName` (Workflow Alert Config Name) by replacing all non-alphanumeric characters (such as dots) with underscores:

- **Standard Class**: `OnboardingWorkflow` maps to `OnboardingWorkflow`
- **Inner Class / Nested Class**: `CalloutTimeoutWorkflowExample.CalloutWorkflow` maps to `CalloutTimeoutWorkflowExample_CalloutWorkflow`
- **Global Fallback**: If no specific configuration record matches a failing workflow, the engine automatically falls back to a record named **`Default`**.

### Configuration Fields

1.  **Enable Alerts** (`Enable_Alerts__c`): Checkbox to toggle alerts (both email and platform events) for this configuration.
2.  **Email Recipients** (`Email_Recipients__c`): A comma- or semicolon-separated list of target email addresses (e.g., `ops@example.com, alerts@example.com`).
3.  **Publish Alert Event** (`Publish_Alert_Event__c`): Checkbox toggle to publish a `Workflow_Alert__e` platform event when an alert is triggered. This can be used in addition to or instead of email alerting (if `Email_Recipients__c` is left blank).
4.  **Threshold Customization** (Optional - if left blank, alerts fire immediately on any failure):
    - `Consecutive_Failures_Limit__c`: Trigger alerts only after `N` consecutive executions fail.
    - `Failure_Count_Limit__c` and `Time_Window_Minutes__c`: Trigger alerts if `N` failures occur within a sliding window of `M` minutes.
    - `Stall_Threshold_Minutes__c`: Trigger stall alerts if an active workflow has been inactive for `K` minutes.

### Platform Event Routing (Workflow_Alert__e)

For modern ops routing (e.g., paging Slack, PagerDuty, Microsoft Teams, or mobile push), enable the **Publish Alert Event** toggle. The engine will publish a `Workflow_Alert__e` platform event with the following payload:

-   **Workflow Name** (`Workflow_Name__c`): The DeveloperName of the workflow.
-   **Workflow Instance Id** (`Workflow_Instance_Id__c`): The ID of the `Workflow_Instance__c` record.
-   **Correlation Key** (`Correlation_Key__c`): The external correlation key.
-   **Error Message** (`Error_Message__c`): The failure error message, stall details, or stack trace (truncated to 20k characters for safe heap handling).
-   **Alert Reason** (`Alert_Reason__c`): The trigger reason: `'Consecutive Failures'`, `'Sliding Window'`, `'Immediate'`, or `'Stall'`.
-   **Threshold Values**: Carries the triggering policy limits: `Consecutive_Failures_Limit__c`, `Failure_Count_Limit__c`, `Time_Window_Minutes__c`, and `Stall_Threshold_Minutes__c`.

#### Subscribing via Flow (No-Code Integration)

Admins can subscribe to `Workflow_Alert__e` via a standard record-triggered Flow in Setup. Under 10 minutes with zero Apex, you can:
1.  Create a **Platform Event-Triggered Flow** selecting `Workflow_Alert__e`.
2.  Add a **Decision** block to route based on `Alert_Reason__c` (e.g. route `'Sliding Window'` errors directly to PagerDuty, and `'Stall'` warnings to a Slack channel).
3.  Use the **HTTP Callout** (Flow Action) to post the payload details directly to your external webhook destination.

---

## Directory Structure

- `force-app/main/default/` - Core Engine & UI Components
  - `classes/` - Framework classes, queueables, finalizers, and scheduling utilities.
  - `objects/` - Core database schemas (`Workflow_Instance__c`, `Workflow_Step_Execution__c`), Platform Events, and Custom Metadata Types.
  - `lwc/` - Responsive visual monitoring timeline dashboard.
- `examples/main/default/` - Reference Architectures
  - `classes/` - Onboarding, Saga rollback, version upgrades, Apex Cursor parallel processing, HTTP Callout/Timeout Watchdog, and parent→child workflow composition implementations.
  - `triggers/` - Opportunity stage triggers demonstrating automated workflow instantiation.
  - `flows/` - Reference Flow demonstrating reading a workflow's outcome via the Get Workflow Status invocable action.

---

## Development & Testing

```bash
sf project deploy start          # deploy to default scratch org
sf apex run test -w 10           # run the full test suite
```

For testing patterns — `WorkflowTestHarness`, step-level unit tests, governor limit guidance, and when to use each — see **[docs/testing.md](docs/testing.md)**.

For AI and Agentforce integration — `aiplatform.ModelsAPI`, multi-turn agent conversations, sessionId threading, a ReAct tool-calling loop, testing mocks, and org setup — see **[docs/agentforce.md](docs/agentforce.md)**.

---

## Watchdog Poller Scheduling (Hybrid Model)

Revenant implements a **Hybrid Watchdog Model** for high-precision, fail-safe step timeouts, sleeps, and retries:

1. **Dynamic High-Precision Scheduling**: When a step sleeps, retries, or registers a timeout, the engine dynamically schedules a seconds-level Apex job (`WorkflowSleepJob`, `WorkflowRetryJob`, or `WorkflowTimeoutJob`) to run immediately.
2. **Delayed Queueable Optimization**: For delays that fall between 1 and 10 minutes (multiples of 60 seconds), the engine automatically routes scheduling through **Delayed Queueables** (`System.enqueueJob(job, delayMinutes)`) instead of standard scheduled Apex. This consumes **0 scheduled job slots** while still executing precisely.
3. **Graceful Degradation (Overflow Protection)**: If the system has reached Salesforce's limit of 100 concurrent scheduled jobs, any failed `System.schedule` call falls back gracefully to tracking the timeout/sleep deadlines in the database (`Sleep_Until__c` and `Timeout_At__c`).
4. **Durable Safety Poller (Watchdog Workflow)**: A native, durable workflow (`WatchdogWorkflow`) runs perpetually (using continue-as-new) to sweep the database and resume/fail any instances that were not dynamically scheduled. Because it uses the Delayed Queueable optimization, the watchdog itself consumes **0 scheduled job slots** in production.

---

## Operator Configuration (Revenant Config)

Revenant settings can be configured without code modifications by editing the **Default** record of the **Revenant Config** (`Revenant_Config__mdt`) Custom Metadata Type:

1. **Use Dynamic Scheduling** (`Use_Dynamic_Scheduling__c` - Checkbox, default `true`):
   - **`true`**: The engine attempts precise, second-level scheduling via `System.schedule` first, falling back to the database watchdog only if limits are reached.
   - **`false`**: The engine completely bypasses `System.schedule` and writes all sleep/retry/timeout states directly to the database. All operations are then processed sequentially by the watchdog poller.
2. **Watchdog Delay Minutes** (`Watchdog_Delay_Minutes__c` - Number, default `10`):
   - The delay interval (between 1 and 10 minutes) before the watchdog enqueues its next self-chaining execution.
3. **Dedup Window Minutes** (`Dedup_Window_Minutes__c` - Number, default `1440`):
   - Controls **idempotent get-or-start** dedup for at-least-once event sources. `WorkflowEngine.start(...)` returns the existing instance's Id when a start arrives with a correlation key that matches an instance that is still active, **or** that became terminal (`Completed`/`Failed`/`Compensated`/`Cancelled`/`ContinuedAsNew`) within this many minutes — rather than throwing or spawning a duplicate that re-runs side effects.
   - **`0`** (minimum) preserves active-only behavior: only in-flight instances are deduped, and a redelivery after completion starts a fresh instance.
   - Active instances are always deduped regardless of this value. A blank correlation key is never deduped (a key is required to start).
   - Use `WorkflowEngine.startOrGet(...)` (or the **Start Workflow** Invocable's `Is New` output) to observe whether a call started a new instance or returned an existing one, without a re-query.
   - **Concurrency note:** the unique `Active_Correlation_Key__c` index is the hard backstop for two simultaneous _active_ starts (the loser receives the winner's Id). Terminal-window dedup is **best-effort under concurrent redelivery**: if a sibling run both starts and reaches a terminal state in the narrow window between a redelivery's lookup and its insert, a duplicate of the just-finished (in-window) run can still be created, because the unique index no longer applies once the original is terminal. Active redelivery and sequential post-completion redelivery are fully covered; closing the concurrent terminal race would require an extra per-start query and is intentionally not done to keep the start path to a single indexed SOQL.

### Architectural Trade-offs

| Metric / Aspect         | Dynamic Precise Scheduling (Default)                                     | Watchdog-Only (`Use_Dynamic_Scheduling__c = false`)                       |
| :---------------------- | :----------------------------------------------------------------------- | :------------------------------------------------------------------------ |
| **Precision**           | High-precision (down to the second).                                     | Delayed by up to the watchdog delay (e.g., 10 minutes).                   |
| **Latency**             | Low-latency (runs immediately at target time).                           | Coarse-grained polling latency.                                           |
| **Scheduled Job Slots** | Consumes 1 slot per active sleep/retry/timeout job (max 100 concurrent). | Consumes **0** scheduled job slots.                                       |
| **Limit Vulnerability** | Vulnerable to hitting the 100 scheduled jobs limit in high-volume orgs.  | Completely immune to the 100 scheduled jobs limit.                        |
| **Use Case**            | Low-volume, time-sensitive or interactive workflows.                     | High-volume, non-interactive batch or transactional processing workflows. |

---

## System Doctor (Dashboard Monitoring)

The Workflow Dashboard includes a **System Doctor** tab to monitor limits, check configuration settings, and audit watchdog health:

- **Watchdog Health**: Indicates whether the self-chaining watchdog Queueable chain is active (`Running`) or has stalled (`Stopped`).
- **Bootstrap Action**: Includes an **Enqueue Watchdog** button to manually trigger and restart the Queueable chain if it ever halts (e.g., during major platform maintenance windows).
- **Limits Auditing**: Displays active `CronTrigger` utilization (against the 100-job limit) and pending database sweeps (sleeping instances and step timeouts).

---

## Production Scaling & Platform Event Subscriber Configuration

By default, Salesforce Platform Event triggers (like `WorkflowEventTrigger`) execute sequentially under the context of the **Automated Process** system user with a batch size of **2,000**. To scale throughput and ensure governor limit safety in high-volume environments, configure a **[PlatformEventSubscriberConfig](https://developer.salesforce.com/docs/atlas.en-us.platform_events.meta/platform_events/platform_events_ps_config.htm)** record for `WorkflowEventTrigger` via the Tooling or Metadata API.

### Key Tuning Parameters

1. **Parallel Subscriptions (Partitioning)**
   - **`NumPartitions`**: Scale throughput by setting this between `1` and `10` to process events concurrently in parallel execution streams.
   - **`PartitionKey`**: Set this to `Workflow_Instance_Id__c`. The platform hashes this key to distribute events across partitions, ensuring events for the _same_ workflow instance are processed sequentially (in-order) to prevent race conditions, while different instances run concurrently.

2. **Batch Size Tuning**
   - **`batchSize`**: Set a smaller chunk size (e.g., `50` or `100`) instead of the default `2,000`. This reduces the risk of hitting CPU time, heap, or SOQL limits within a single trigger execution block.

3. **Running User Context**
   - **`userId`**: Triggers delegate step execution to Queueable Apex (`WorkflowOrchestrator`). By default, these run under the `Automated Process` user. While `autoproc` can be assigned Named Credential/External Credential access using Anonymous Apex (`insert new PermissionSetAssignment(...)`), you can optionally specify a dedicated integration `userId` here to run the subscriber trigger and Queueables under a standard user context.

## Packaging Revenant

Revenant supports being packaged inside a Managed Package (1GP or 2GP) and installed in subscriber orgs. The engine resolves workflow and step classes dynamically across the namespace boundary.

### Class Resolution Model
- **Engine Namespace**: When Revenant is installed as a package, the engine executes in the package namespace (e.g. `revenant`).
- **Subscriber Namespace**: Subscriber workflows and steps can be defined locally (no namespace) or in their own namespace.
- **Identifier Serialization**: When starting a workflow, the engine saves the fully-qualified class name (e.g. `sub_ns.MyWorkflow` or `MyWorkflow` if unpackaged) in the database. When resolving step names, the engine automatically attempts to resolve them in the namespace of the parent workflow.

### Rules for Subscriber Workflow Names
To start a workflow defined in a subscriber org, always use its fully-qualified class name if the subscriber org has a namespace prefix:
- **Unpackaged subscriber org (no namespace)**: Start using the class name as-is: `WorkflowEngine.start('MyWorkflow', key, input);`
- **Subscriber org with a namespace (e.g. `sub`)**: Start using the namespace-qualified class name: `WorkflowEngine.start('sub.MyWorkflow', key, input);`

If the class name is not fully-qualified, the engine will search for it first in the package namespace, and then fall back to local/subscriber resolution. However, to ensure namespace-stable execution across all asynchronous boundaries, providing the fully-qualified name is highly recommended.

---

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT License ([LICENSE-MIT](LICENSE-MIT))

at your option.
