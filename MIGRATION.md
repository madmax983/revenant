# Revenant Pre-1.0 Migration Guide

This guide consolidates every **breaking public-API change** introduced during the
pre-1.0 Salesforce Code Analyzer cleanup (PRs #193–#214). That effort drove the
full-repo Recommended (PMD) scan from 34 violations to **zero**, largely by
decomposing a handful of oversized classes — most notably a 17,187-line
`WorkflowEngine` — into ~100+ small, single-responsibility classes and by
replacing telescoping parameter lists and boolean-flag methods with request
objects and intent-named methods. These are deliberate, one-time breaks taken
before the 1.0 API freeze. Behavior is byte-identical; only the shapes external
**step authors** and **dashboard/LWC callers** compile against have changed. This
document is the old→new map for updating your code.

> Symbols and arities below are quoted verbatim from the current `main` source.
> Where the source contradicts an earlier informal description, the source wins
> and the difference is called out inline.

---

## Quick reference (old → new)

| Old (removed) | New | PR |
|---|---|---|
| `WorkflowEngine.cancel(Id, Boolean)` | `WorkflowEngine.cancel(Id)` **or** `WorkflowCancellation.cancelWithCompensations(Id)` | #204 |
| `WorkflowEngine.start(name, key, input, Map)` / `(…, Id)` / `(…, Id, Map)` | `WorkflowEngine.start(StartRequest)` | #204 |
| `WorkflowEngine.startOrGet(…)` 4/5-arg | `WorkflowEngine.startOrGet(StartRequest)` | #204 |
| `WorkflowEngine.signal(String, String, String, String)` | `WorkflowEngine.signal(SignalRequest)` | #204 |
| `WorkflowEngine.signalOrStart(StartRequest, String, String, String)` | `WorkflowEngine.signalOrStart(SignalOrStartRequest)` | #204 |
| `startDebounced(…)` 4/5/7-arg | `WorkflowDebouncer.startDebounced(List<WorkflowDebouncer.DebounceRequest>)` | #204 |
| `StepResult.sleep(Integer, String, String, String)` (4-arg) | `StepResult.sleep(Integer, String, String)` + `.withStepState(json)` | #198 |
| `StepResult.waitForApproval(String, String, Integer, String)` (4-arg) | `StepResult.waitForApproval(String, String)` + `.withApprovalTimeout(Integer, String)` | #198 |
| `StepResult.suspend(String)` / `sleep(Integer, String)` / `retry(Integer)` / `complete(String, Object, List)` | see [StepResult](#3-stepresult-fluent-api--directive-reads) | #207 |
| `result.action`, `result.nextStepName`, `result.retryPolicy`, … (direct reads) | `result.directive().action`, `.directive().retry.policy`, … | #207 |
| `ctx.log(...)`, `ctx.emit(...)`, `ctx.reportProgress(...)`, `ctx.once(...)`, `ctx.getSignal(...)`, `ctx.maxAttempts`, … | `ctx.logger()`, `ctx.events()`, `ctx.progress()`, `ctx.captures()`, `ctx.signals()`, `ctx.retry()` | #207 |
| `WorkflowLog.error(String, String, Id, String, String)` (5-arg) | `WorkflowLog.error(WorkflowLog.ErrorEntry)` | #206 |
| `WorkflowScheduleController.setEnabled(Id, Boolean)` | `enableSchedule(Id)` / `disableSchedule(Id)` | #198 |
| Dashboard command endpoints on `WorkflowDashboardController` | same names on `WorkflowDashboardCommandController` | #207 |
| `StepContextTestBuilder.timeoutResume(Boolean)` | `StepContextTestBuilder.timeoutResume()` (no-arg) | #197 |

---

## 1. `WorkflowEngine` is now a 19-method facade

**PR: #204, #208–#213** — `WorkflowEngine` was decomposed from a 17,187-line
monolith into a thin facade of 19 public methods, each delegating to one of ~100+
cohesive classes. The public method **names** are stable; what changed is that the
multi-argument overloads were collapsed onto request objects (sections below). The
19 methods are: `start` ×3, `startOrGet` ×3, `signal` ×3, `signalOrStart` ×2,
`runStep` ×2, `handleCrash` ×2, `failWorkflowInstance` ×2, `cancel`, and
`processWatchdogHeartbeat`.

The 3-arg convenience factories are **preserved**, so the most common call sites
keep compiling unchanged:

```apex
Id id = WorkflowEngine.start('OrderFulfillment', orderId, orderPayload);   // still valid
StepContext.Signal s;                                                      // unchanged
WorkflowEngine.signal(correlationKey, 'ApprovalReceived', payloadJson);    // still valid
```

> **📖 Reading an instance's step history.** The supported read contracts live on
> dedicated read classes, not the facade — `WorkflowStatusRead.getStatus` for the
> **outcome**, and **`WorkflowHistoryRead.getHistory`** for the ordered **step
> timeline** (which steps ran, in order, with attempt counts, timing, errors, and a
> compensation flag). Do **not** query `Workflow_Step_Execution__c` directly — those
> field names are internal.
>
> ```apex
> WorkflowEngine.StepHistory h = WorkflowHistoryRead.getHistory(instanceId);
> for (WorkflowEngine.StepHistoryEntry e : h.entries) { /* e.stepName, e.status, e.attempt, ... */ }
> ```
>
> See the README's "Read a Workflow's Step Timeline (Apex)" section for the full DTO shape.

---

## 2. `cancel(Id, Boolean)` split — and `cancelWithCompensations` is NOT on the engine

**PR: #204.** The boolean-flag `cancel(Id, Boolean)` was removed and split by intent.

> **Correction to the informal spec:** `cancelWithCompensations` does **not** live
> on `WorkflowEngine`. The only public cancel entry point on the engine is
> `cancel(Id)`. Compensating cancellation lives on **`WorkflowCancellation`**.

```apex
// OLD
WorkflowEngine.cancel(instanceId, false);   // cancel, no compensations
WorkflowEngine.cancel(instanceId, true);    // cancel + run compensations

// NEW
WorkflowEngine.cancel(instanceId);                          // no compensations
WorkflowCancellation.cancelWithCompensations(instanceId);  // run compensations
```

---

## 3. Start / signal / signalOrStart / startDebounced take request objects

**PR: #204.** Telescoping overloads were collapsed onto request objects built with
a 3-arg constructor plus fluent setters. `StartRequest`, `SignalRequest`, and
`SignalOrStartRequest` are **inner classes of `WorkflowEngine`**;
`DebounceRequest` is **`WorkflowDebouncer.DebounceRequest`** and there is **no**
`startDebounced` method on `WorkflowEngine`.

### start

```apex
// OLD
WorkflowEngine.start('OrderFulfillment', orderId, input, attributesMap);
WorkflowEngine.start('OrderFulfillment', orderId, input, parentInstanceId);

// NEW
WorkflowEngine.start(
  new WorkflowEngine.StartRequest('OrderFulfillment', orderId, input)
    .withAttributes(attributesMap)
    .withParent(parentInstanceId)
);
```

`StartRequest` ctor: `StartRequest(String workflowName, String correlationKey, Object input)`.
Fluent setters: `withAttributes(Map<String, String>)`, `withParent(Id)`.
`startOrGet(StartRequest)` follows the identical pattern.

### signal

```apex
// OLD
WorkflowEngine.signal(keyOrId, 'ApprovalReceived', payload, idempotencyKey);

// NEW
WorkflowEngine.signal(
  new WorkflowEngine.SignalRequest(keyOrId, 'ApprovalReceived', payload)
    .withIdempotencyKey(idempotencyKey)
);
```

`SignalRequest` ctor: `SignalRequest(String keyOrId, String signalName, String payload)`.
Fluent setters: `withDedupKey(String)`, `withIdempotencyKey(String)`.

### signalOrStart

```apex
// OLD
WorkflowEngine.signalOrStart(startRequest, 'WakeUp', payload, idempotencyKey);

// NEW
WorkflowEngine.signalOrStart(
  new WorkflowEngine.SignalOrStartRequest(startRequest, 'WakeUp', payload)
    .withIdempotencyKey(idempotencyKey)
);
```

`SignalOrStartRequest` ctor: `SignalOrStartRequest(StartRequest start, String signalName, String payload)`.
Fluent setter: `withIdempotencyKey(String)`.

### startDebounced

```apex
// OLD
WorkflowEngine.startDebounced(name, key, inputJson, debounceSeconds, maxWaitSeconds, attributesJson, causationId);

// NEW
WorkflowDebouncer.startDebounced(new List<WorkflowDebouncer.DebounceRequest>{
  new WorkflowDebouncer.DebounceRequest(name, key, inputJson)
    .withDebounce(debounceSeconds)
    .withMaxWait(maxWaitSeconds)
    .withAttributesJson(attributesJson)
    .withCausationId(causationId)
});
```

`DebounceRequest` ctor: `DebounceRequest(String workflowName, String correlationKey, String inputJson)`.
Fluent setters: `withDebounce(Integer)`, `withMaxWait(Integer)`, `withAttributesJson(String)`, `withCausationId(String)`.
The public enqueue entry point is `WorkflowDebouncer.startDebounced(List<DebounceRequest>)`
(single-request `WorkflowStartService.startDebounced(WorkflowDebouncer.DebounceRequest)` also exists).

---

## 4. `StepContext` — author primitives move onto six accessor sub-objects

**PR: #207.** The direct methods and fields that step authors used to call on
`StepContext` (logging, events, progress, captures, signals, retry info) now live
on six accessor sub-objects. The plain data members (`ctx.workflowInstanceId`,
`ctx.workflowName`, `ctx.stepName`, `ctx.inputJson`, `ctx.previousStepOutput`,
`ctx.stepStateJson`, `ctx.workflowInputJson`, `ctx.workflowVersion`,
`ctx.attempt`, `ctx.previousRunAt`, `ctx.idempotencyKey`), the methods
`ctx.isFinalAttempt()` / `ctx.shouldYield()`, the nested types, and
`StepContext.LOG_TYPE_BREADCRUMB` are **unchanged**.

| Old (on `ctx`) | New accessor → type |
|---|---|
| `ctx.log(level, msg)` / `ctx.log(level, msg, map)` / `ctx.getBreadcrumbs()` | `ctx.logger()` → `StepLog` |
| `ctx.reportProgress(pct, msg)` / `ctx.getProgressJson()` / `ctx.isProgressReported()` | `ctx.progress()` → `StepProgress` |
| `ctx.emit(evt)` / `ctx.getPendingEmits()` | `ctx.events()` → `StepEmitter` |
| `ctx.getSignal(name)` / `ctx.hasSignal(name)` / `ctx.getSignals()` / consumed & claimed id getters / `ctx.signalReadWasCapped()` / `ctx.getChildOutcome(s)(...)` | `ctx.signals()` → `StepSignals` |
| `ctx.once(key, producer)` / `ctx.patched(id[, dt])` / `ctx.deprecated(id[, dt])` / `ctx.getCapturedValuesJson()` / `ctx.hasNewCaptures()` | `ctx.captures()` → `StepCaptures` |
| `ctx.maxAttempts` / `ctx.attemptCount` / `ctx.failedStepName` / `ctx.errorMessage` / `ctx.isTimeoutResume()` | `ctx.retry()` → `StepRetryInfo` |

```apex
// OLD
ctx.log(StepContext.Level.INFO, 'processing');
ctx.reportProgress(50, 'halfway');
ctx.emit(new Order_Event__e(Status__c = 'Shipped'));
Object cached = ctx.once('rate', producer);
StepContext.Signal sig = ctx.getSignal('ApprovalReceived');
Integer attempts = ctx.maxAttempts;

// NEW
ctx.logger().log(StepContext.Level.INFO, 'processing');
ctx.progress().reportProgress(50, 'halfway');
ctx.events().emit(new Order_Event__e(Status__c = 'Shipped'));
Object cached = ctx.captures().once('rate', producer);
StepContext.Signal sig = ctx.signals().getSignal('ApprovalReceived');
Integer attempts = ctx.retry().maxAttempts;
```

Accessor return types: `logger()` → `StepLog`, `progress()` → `StepProgress`,
`events()` → `StepEmitter`, `signals()` → `StepSignals`, `captures()` →
`StepCaptures`, `retry()` → `StepRetryInfo`.

> **Construction note.** `StepContext` is assembled via `StepContext.Builder`
> (`new StepContext.Builder().instanceId(id).stepName('X')...build()`), which
> replaced the multi-arg constructors. Per PR #198 this path is **engine-internal
> and non-breaking to external users** — step authors receive `ctx` from the
> engine and do not construct it. For **unit tests**, build contexts with
> `StepContextTestBuilder` (section 8).

---

## 5. `StepResult` — fluent API and reads behind `.directive()`

**PR: #198** (fluent sleep/approval split) and **PR: #207** (reads move behind
`.directive()`, redundant factories removed). Construction via the factory methods
is otherwise unchanged.

### 5a. The 4-arg sleep / waitForApproval overloads are GONE (PR #198)

> **Confirmed against source:** `sleep` has exactly two overloads —
> `sleep(Integer seconds)` and `sleep(Integer amount, String unit, String businessHoursName)`.
> `waitForApproval` has exactly one factory — `waitForApproval(String key, String role)`.
> There is **no** 4-arg form of either. Apply step state / timeout via the fluent
> methods `withStepState(String)` and `withApprovalTimeout(Integer, String)`.

```apex
// OLD
StepResult.sleep(2, 'DAYS', 'Standard Business Hours', stepStateJson);
StepResult.waitForApproval('mgr-approval', 'Manager', 3600, 'EscalateStep');

// NEW
StepResult.sleep(2, 'DAYS', 'Standard Business Hours').withStepState(stepStateJson);
StepResult.waitForApproval('mgr-approval', 'Manager').withApprovalTimeout(3600, 'EscalateStep');
```

### 5b. Four redundant factory overloads removed (PR #207)

| Removed | Replacement |
|---|---|
| `StepResult.suspend(String state)` | `StepResult.suspend().withStepState(state)` |
| `StepResult.sleep(Integer n, String state)` | `StepResult.sleep(n).withStepState(state)` |
| `StepResult.retry(Integer n)` | `StepResult.retry(new RetryPolicy(n, (Double) 1.0, 5))` |
| `StepResult.complete(String, Object, List events)` | `ctx.events().emit(e)` then `StepResult.complete(next, output)` |

### 5c. Engine-read data moves behind `.directive()` (PR #207)

If your code (or a test) reads the data properties off a `StepResult`, they now
live on the read-only `StepDirective` returned by `result.directive()`:

```apex
// OLD
StepResult.ActionType a = result.action;
String next            = result.nextStepName;
RetryPolicy policy     = result.retryPolicy;
Integer afterSecs      = result.retryAfterSeconds;
Integer timeoutSecs    = result.timeoutSeconds;
String nextInput       = result.nextInputJson;

// NEW
StepResult.ActionType a = result.directive().action;
String next            = result.directive().nextStepName;
RetryPolicy policy     = result.directive().retry.policy;
Integer afterSecs      = result.directive().retry.afterSeconds;
Integer timeoutSecs    = result.directive().timeout.seconds;
String nextInput       = result.directive().continuation.nextInputJson;
```

The `StepDirective` groups the formerly-flat retry/timeout/continuation fields
into never-null sub-objects: `.retry` (`policy`, `afterSeconds`), `.timeout`
(`seconds`, `step`), `.continuation` (`nextInputJson`, `newCorrelationKey`). The
16 remaining scalar directive fields (`action`, `nextStepName`, `outputJson`,
`stepStateJson`, `sleepDurationSeconds`, `childWorkflowName`,
`childCorrelationKey`, `childInputJson`, `approvalKey`, `approvalRole`,
`parallelStepNames`, `parallelInputJson`, `childRequests`, `outboundEvents`,
`failureReason`, `failureDataJson`) read directly off `directive()`.

---

## 6. `WorkflowLog.error` 5-arg form → `ErrorEntry` params object

**PR: #206.** The 5-arg overload
`error(String logType, String message, Id instanceId, String correlationKey, String workflowName)`
was removed. The 2-arg `error(String, String)` and 3-arg
`error(String, String, Id)` overloads are **unchanged**.

```apex
// OLD
WorkflowLog.error(logType, message, instanceId, correlationKey, workflowName);

// NEW
WorkflowLog.error(
  new WorkflowLog.ErrorEntry(logType, message)
    .withInstanceId(instanceId)
    .withCorrelationKey(correlationKey)
    .withWorkflowName(workflowName)
);
```

`ErrorEntry` ctor: `ErrorEntry(String logType, String message)`.
Fluent setters: `withInstanceId(Id)`, `withCorrelationKey(String)`, `withWorkflowName(String)`.

---

## 7. Dashboard controller split (read vs. command)

**PR: #207.** `WorkflowDashboardController` was split into a **read** controller
(same name) and a new **command** controller,
`WorkflowDashboardCommandController`. The `@AuraEnabled` endpoint **names are
unchanged** — only the host Apex class of the 16 command endpoints moved, so LWC
callers change the **import path only**.

Command endpoints now on `WorkflowDashboardCommandController`: `startWorkflow`,
`retryWorkflowInstance`, `redriveMatchingInstances`, `cancelMatchingInstances`,
`cancelMatchingInstancesWithCompensations`, `resumeWorkflowInstance`,
`resumeCompensationInstance`, `resumePastStepInstance`, `compensateWorkflow`,
`cancelWorkflow`, `submitApproval`, `enqueueWatchdog`, `pauseDefinition`,
`resumeDefinition`, `redeliverSignal`, `injectSignal` (plus the command DTOs
`CancelRequest`, `ApprovalRequest`). Read endpoints and read DTOs
(`InstanceQuery`, `StalledQuery`, `UnroutedQuery`) stay on
`WorkflowDashboardController`.

```js
// OLD
import startWorkflow from "@salesforce/apex/WorkflowDashboardController.startWorkflow";
// NEW
import startWorkflow from "@salesforce/apex/WorkflowDashboardCommandController.startWorkflow";
```

### `WorkflowScheduleController.setEnabled` → `enableSchedule` / `disableSchedule`

**PR: #198.** The boolean-flag `setEnabled(Id, Boolean)` was replaced by two
intent-named `@AuraEnabled` methods. Both are `public static void`.

```apex
// OLD
WorkflowScheduleController.setEnabled(scheduleId, true);
WorkflowScheduleController.setEnabled(scheduleId, false);

// NEW
WorkflowScheduleController.enableSchedule(scheduleId);
WorkflowScheduleController.disableSchedule(scheduleId);
```

---

## 8. Test fixtures

**PR: #197.** The `@IsTest` fixtures were restructured alongside the production
refactor.

- **`WorkflowTestHarness`** is now a thin facade over 10 `@IsTest` helper classes;
  its **public API is unchanged** (`step()`, `drive()`, `driveUntilStep(...)`,
  `injectSignal(...)`, `fireTimeout(...)`, `failStep(...)`, etc.). No caller change
  required.
- **`StepContextTestBuilder`** is the fluent in-memory `StepContext` fixture
  (0 DML / 0 SOQL). Its one breaking change: the boolean-flag
  `timeoutResume(Boolean)` became the no-arg `timeoutResume()`.
- **`TestIdFactory`** — single public method `generate(Schema.SObjectType sot)`
  for synthetic Ids.

```apex
// OLD
StepContext ctx = new StepContextTestBuilder()
  .stepName('Charge')
  .timeoutResume(true)
  .build();

// NEW
StepContext ctx = new StepContextTestBuilder()
  .stepName('Charge')
  .timeoutResume()
  .build();
```

---

## New (additive, non-breaking): `ValidatedWorkflow` opt-in start-input validation

**Issue #51.** This is **not a breaking change** — no existing signature changes and
workflows that do not opt in behave exactly as before — but it is recorded here
because it introduces a new permanent author-facing API contract.

A workflow definition MAY now implement **`ValidatedWorkflow`** (alongside
`WorkflowDefinition`) to declare a `WorkflowInputContract` of required/optional
fields and their `WorkflowInputType` primitives (`STRING_TYPE`, `INTEGER_TYPE`, `LONG_TYPE`,
`DECIMAL_TYPE`, `BOOLEAN_TYPE`, `DATE_TYPE`, `DATETIME_TYPE`). The issue's generic **Number** maps to
**`DECIMAL_TYPE`** (any JSON numeric); use `INTEGER_TYPE`/`LONG_TYPE` for whole numbers. When
present, the contract is enforced
**synchronously at `WorkflowEngine.start(...)` / `startOrGet(...)`** — before any
`Workflow_Instance__c` is inserted or any job enqueued, adding **zero SOQL/DML** to
the start path. Bad input throws the new top-level typed **`WorkflowInputException`**
(`getFieldErrors()` → `List<WorkflowInputFieldError>`), enumerating every missing,
wrong-typed, or malformed-JSON field.

```apex
public class OnboardingWorkflow implements WorkflowDefinition, ValidatedWorkflow {
  public WorkflowInputContract getInputContract() {
    return new WorkflowInputContract()
      .require('accountId', WorkflowInputType.STRING_TYPE)
      .require('amount', WorkflowInputType.DECIMAL_TYPE);
  }
  // getSteps() / getInitialStep() / getNextStep() unchanged
}
```

The **Start Workflow** invocable gains two additive outputs — `Is Valid` (Boolean)
and `Validation Error` (String) — so a Flow can branch on invalid input instead of
catching a fault. Existing invocable outputs (`Workflow Instance ID`, `Is New`) are
unchanged. See the README's "Validate Start Input Against a Contract (opt-in)"
section for the full contract shape, type-coercion rules, and bulk/Flow behavior.

---

## New (additive, non-breaking): `DefinitionChanged` status

**Issue #89.** No signature changes. Read this if your code switches on `Status__c`.

- `Workflow_Instance__c.Status__c` has a new value: `DefinitionChanged` (label "Definition Changed"). It is not terminal. The instance waits for an operator release or a cancel.
- `Workflow_Step_Execution__c.Status__c` has the same new value. The engine uses it only on the `Workflow_Definition_Changed` marker row.
- New fields: `Workflow_Instance__c.Definition_Fingerprint__c` and `Definition_Shape__c`. Instances that started before the upgrade have blank values. The engine never parks them.
- New API: `WorkflowDefinitionChangeService.release(Id instanceId)`. It is not on the `WorkflowEngine` facade. The dashboard calls it through `WorkflowDashboardCommandController.releaseDefinitionChangedInstance`.
- If you change `getSteps()` of a plain definition while instances are in flight, those instances now park. To avoid this, implement `VersionedWorkflow`.

See [docs/definition-change-detection.md](docs/definition-change-detection.md).

## New (additive, non-breaking): `STEP_NON_DETERMINISM` category

**Issue #102.** No signature changes. Read this if your code switches on `Failure_Category__c`.

- `Workflow_Instance__c.Failure_Category__c` has a new value: `STEP_NON_DETERMINISM` (label "Step Non-Determinism").
- New field: `Workflow_Step_Execution__c.Decision_Record__c`. Strict determinism mode fills it. When the mode is off, the engine clears it.
- New config field: `Revenant_Config__mdt.Strict_Determinism__c`. Default: off. When off, nothing changes.

See [docs/strict-determinism.md](docs/strict-determinism.md).

## New (additive): step-history guard and `STEP_HISTORY_LIMIT` category

**Issue #112.** No signature changes. The guard is on by default. Read this if you run a loop without Continue-As-New, or if your code switches on `Failure_Category__c`.

- `Workflow_Instance__c.Failure_Category__c` has a new value: `STEP_HISTORY_LIMIT` (label "Step History Limit").
- New config fields: `Revenant_Config__mdt.Step_History_Warn_Threshold__c` (default 5000) and `Step_History_Ceiling__c` (default 10000). An instance with 10,000 step rows now fails. Before, it failed later with a governor error. Set a value to `0` to turn a check off.
- New additive field: `WorkflowEngine.FailInstanceRequest.skipErrorRouting` (default `false`).
- Each hop does one more SOQL. A test that drives many hops in one transaction uses one more SOQL for each hop. To turn the guard off in a test, set `WorkflowEngine.stepHistoryWarnThreshold` and `WorkflowEngine.stepHistoryCeiling` to `0`.

See [docs/step-history-guard.md](docs/step-history-guard.md).

## New (additive): approver notifications

**Issue #123.** No signature changes. Nothing changes until a step calls `withNotification`.

- New author API: `StepResult.withNotification(WorkflowNotification)` and the `WorkflowNotification` builder. New field: `StepResult.StepDirective.notification`.
- New config field: `Revenant_Config__mdt.Send_Notifications__c` (default on).
- New metadata: `CustomNotificationType` `Revenant_Workflow_Notification`.
- `Workflow_Event__e` has a new `Event_Type__c` value: `NOTIFY`. A custom subscriber to `Workflow_Event__e` must ignore it.
- `Workflow_Log__c` has new rows with `Log_Type__c = Notification`.
- `ApprovalWorkflowExample` reads the approver from the workflow input key `approverId`. With no approver, it notifies the instance owner.

See [docs/approver-notifications.md](docs/approver-notifications.md).

---

## 9. New (additive, non-breaking): `WorkflowInstanceQuery.findInstances`

**Issue #93.** This is **not a breaking change** — it adds a new supported read
contract with no change to any existing signature — but it is recorded here because
it is the sanctioned replacement for a pattern the docs already forbid: querying
`Workflow_Instance__c` fields directly to **enumerate** instances (the field and
relationship API names are internal and namespace-sensitive). Where `getStatus`
answers "what is the outcome of the instance I already hold a key/Id for?",
`findInstances` answers "which instances match this definition / status / time
window?" and pages through them.

```apex
// Enumerate + page (keyset cursor, not OFFSET) — payload-free, one SOQL per call
WorkflowEngine.InstanceCriteria criteria = new WorkflowEngine.InstanceCriteria();
criteria.definitionName = 'OnboardingWorkflow';
criteria.statuses = new Set<String>{ 'Running', 'Failed' };
criteria.pageSize = 100;                       // null -> 50; > 200 -> clamped; <= 0 -> throws

WorkflowEngine.InstancePage page = WorkflowInstanceQuery.findInstances(criteria);
for (WorkflowEngine.WorkflowInstanceSummary s : page.entries) { /* s.instanceId, s.status, ... */ }
criteria.cursor = page.nextCursor;             // pass back VERBATIM; null on the last page
```

Like `getStatus` / `getHistory`, the contract lives on a dedicated `inherited
sharing` service class (`WorkflowInstanceQuery`), while the forever-public DTOs
(`InstanceCriteria`, `WorkflowInstanceSummary`, `InstancePage`) are resident inner
classes of `WorkflowEngine`. It is strictly read-only and payload-free; see the
README's "List & Page Through Workflow Instances (Apex)" section for the full DTO
shapes, the keyset-cursor / ContinueAsNew semantics, and the honest SOQL profile.

---

## PR index

| PR | Breaking change(s) covered here |
|---|---|
| #197 | Test fixtures: `WorkflowTestHarness` facade, `StepContextTestBuilder.timeoutResume()`, `TestIdFactory` |
| #198 | `StepResult` 4-arg `sleep`/`waitForApproval` removed; `WorkflowScheduleController` enable/disable split |
| #204 | `WorkflowEngine` request-object API; `cancel(Id, Boolean)` split; `startDebounced` → `WorkflowDebouncer.DebounceRequest` |
| #206 | `WorkflowLog.error` 5-arg → `ErrorEntry` params object |
| #207 | `StepContext` accessor sub-objects; `StepResult` `.directive()` reads + factory removals; dashboard read/command split |
| #213 | `WorkflowEngine` reaches its final 19-method facade shape |
| #214 | Internal sfge null-guards (no author-facing API change) |
