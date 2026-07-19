# Testing Revenant Workflows

## Two kinds of tests

| Kind | Tool | When |
|---|---|---|
| **Integration** — does the DAG execute correctly end-to-end? | `WorkflowTestHarness` | Happy paths, sagas, signals, fan-out, ContinueAsNew |
| **Unit** — does this step's logic work in isolation? | `StepContext` + `step.execute(ctx)` directly | CPU/SOQL-heavy steps, idempotency proofs, edge cases |

The fundamental limit to keep in mind: **governor limits do not reset between harness hops**. Every `runStep` call the harness makes happens in the same Apex transaction, so a workflow with 50 steps each issuing 3 SOQLs will hit the 101-query limit in a test even though it runs fine in production (where each Queueable gets a fresh budget). The harness is for DAG correctness, not limit coverage. Use step-level unit tests for the heavy stuff.

---

## WorkflowTestHarness API

```java
// Construct with the instance ID returned by WorkflowEngine.start().
WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

// Drive to the next stable state (terminal or genuine signal-suspend).
// Throws HarnessException if not stable within maxHops (default 100).
Result r = harness.drive();
Result r = harness.drive(50);           // custom hop budget

// Advance exactly one logical hop. Never throws if work remains.
// Useful when you need to pause between steps (e.g. to mutate DB state).
Result r = harness.step();

// Drive until the named step appears in the audit trail, then stop.
// Returns as soon as the step is recorded (whether Completed or still in-flight).
// Throws HarnessException if the step is never reached within maxHops.
Result r = harness.driveUntilStep('MyWorkflow.SomeStep');
Result r = harness.driveUntilStep('MyWorkflow.SomeStep', 20);

// Deliver an external signal and resume driving.
Result r = harness.injectSignal(correlationKey, signalName, payload);

// Fire the shipped WorkflowTimeoutJob for a specific step, then resume driving.
Result r = harness.fireTimeout('MyWorkflow.SomeStep');

// Resume a sleeping step immediately (time-skip), then resume driving.
Result r = harness.fireSleep('MyWorkflow.SomeStep');

// Resume a retrying step immediately (time-skip), then resume driving.
Result r = harness.fireRetry('MyWorkflow.SomeStep');

// Inject a fault on a step to fail forward execution or compensation indefinitely (returns `this` for chaining).
harness.failStep('MyWorkflow.SomeStep', 'Failure message');

// Inject a fault on a step that fails only the first execution (returns `this` for chaining).
harness.failStepOnce('MyWorkflow.SomeStep', 'Failure message');

// Inject a fault on a step that fails a specific number of times (returns `this` for chaining).
harness.failStep('MyWorkflow.SomeStep', 'Failure message', 3);

// Clear all registered faults (returns `this` for chaining).
harness.clearFaults();

// Snapshot current state without advancing.
Result r = harness.inspect();
```

### Result fields

```java
result.status           // Final Status__c of the root instance
result.output           // Resolved Output__c (offloaded payloads inlined)
result.executedSteps    // All step names in audit order (including retries)
result.completedSteps   // Forward steps that completed, in order
result.compensatedSteps // Compensation steps that ran, LIFO order
result.hops             // Total hops consumed across all drive()/step() calls
result.isTerminal       // Completed / Failed / Compensated / Cancelled / ContinuedAsNew
result.isSuspended      // Status == Suspended (waiting for signal)
result.isSleeping       // Status == Suspended and awaiting timer/sleep resume
result.isAwaitingRetry  // Status == Suspended and awaiting retry back-off resume

result.reachedStep('MyWorkflow.SomeStep')  // true if step appears in executedSteps
```

---

## Pattern 1 — Simple end-to-end happy path

```java
@isTest
static void testHappyPath() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start('MyWorkflow', 'key-1', inputMap);
    WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId).drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);
    System.assert(result.output.contains('"processed":true'));
    System.assert(result.reachedStep('MyWorkflow.ProcessStep'));
}
```

`Test.startTest()`/`stopTest()` wrapping is recommended. `WorkflowEngine.start()` always enqueues one Queueable; it fires at `stopTest()` but is a no-op on an already-terminal instance.

---

## Pattern 2 — Human-in-the-loop / external signal

```java
@isTest
static void testApprovalFlow() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start('OnboardingWorkflow', 'key-1', inputMap);
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

    // Drive to the approval suspend point.
    WorkflowTestHarness.Result suspended = harness.drive();
    Test.stopTest();

    System.assertEquals('Suspended', suspended.status);
    System.assert(suspended.isSuspended);

    // Inject approval and drive to completion.
    WorkflowTestHarness.Result completed = harness.injectSignal(
        'key-1',
        'Approve:VIPOrderApproval',
        '{"approved":true}'
    );
    System.assertEquals('Completed', completed.status);
}
```

---

## Pattern 3 — Saga compensation

```java
@isTest
static void testSagaRollback() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start('SagaWorkflow.SagaWorkflow', 'key-1', input);
    WorkflowTestHarness.Result result = new WorkflowTestHarness(instanceId).drive();
    Test.stopTest();

    System.assertEquals('Compensated', result.status);
    // compensatedSteps lists _Compensate records in the LIFO order they ran.
    System.assertEquals(
        new List<String>{'SagaWorkflow.StepB_Compensate', 'SagaWorkflow.StepA_Compensate'},
        result.compensatedSteps
    );
}
```

---

## Pattern 4 — Parallel fan-out (parent + child workflows)

The harness drives the entire tree automatically: parent, all spawned children, platform-event delivery, and the parent's rejoin. A single `drive()` call is sufficient.

```java
@isTest
static void testFanout() {
    Test.startTest();
    Id parentId = WorkflowEngine.start('BatchFanoutWorkflow', 'key-1', null);
    WorkflowTestHarness.Result result = new WorkflowTestHarness(parentId).drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);

    // Query spawned children from the DB after drive() — their records persist.
    List<Workflow_Instance__c> children = [
        SELECT Status__c FROM Workflow_Instance__c WHERE Parent_Instance__c = :parentId
    ];
    System.assertEquals(3, children.size());
    for (Workflow_Instance__c child : children) {
        System.assertEquals('Completed', child.Status__c);
    }
}
```

---

## Pattern 5 — Watchdog timeout simulation

```java
@isTest
static void testTimeoutFailsWorkflow() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start('MyWorkflow', 'key-1', inputMap);
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    // fireTimeout() uses the shipped WorkflowTimeoutJob — no direct DB mutation.
    WorkflowTestHarness.Result result = harness.fireTimeout('MyWorkflow.WaitingStep');
    Test.stopTest();

    System.assertEquals('Failed', result.status);
}
```

---

## Pattern 6 — Intermediate state assertions with `driveUntilStep`

Use this when you need to assert the state of the workflow after a specific step but before the workflow finishes — without knowing the exact hop count.

```java
@isTest
static void testIntermediateState() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start('MyWorkflow', 'key-1', null);
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

    // Drive until the fanout step has run, then inspect children.
    WorkflowTestHarness.Result mid = harness.driveUntilStep('MyWorkflow.FanoutStep');

    System.assert(mid.reachedStep('MyWorkflow.FanoutStep'));
    Integer childCount = [SELECT COUNT() FROM Workflow_Instance__c WHERE Parent_Instance__c = :instanceId];
    System.assertEquals(3, childCount);

    // Resume to completion.
    WorkflowTestHarness.Result final = harness.drive();
    Test.stopTest();

    System.assertEquals('Completed', final.status);
}
```

A harness instance is stateful — its hop counter, known-instance set, and `disableAutoTimeSkip` flag persist across calls. You can call `step()`, `driveUntilStep()`, and `drive()` in sequence on the same harness and they compose correctly.

---

## Pattern 7 — DB surgery between steps with `step()`

Use `step()` when you must mutate database state between specific steps — for example, overriding a version number, injecting a stale checkpoint, or forcing a status transition.

```java
@isTest
static void testVersionRouting() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start('VersionedWorkflow', 'key-1', null);

    // Override the version BEFORE the first step runs.
    Workflow_Instance__c inst = [SELECT Definition_Version__c FROM Workflow_Instance__c WHERE Id = :instanceId];
    inst.Definition_Version__c = 1;
    update inst;

    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.step(); // Run StepA under v1 routing.

    // Assert intermediate routing.
    inst = [SELECT Current_Step__c FROM Workflow_Instance__c WHERE Id = :instanceId];
    System.assertEquals('VersionedWorkflow.LegacyStepB', inst.Current_Step__c);

    // Drive rest to completion.
    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('Completed', result.status);
}
```

---

## Pattern 8 — Continue-as-new chains

`ContinuedAsNew` is a terminal state for the harness; `drive()` stops there. Each successor instance requires its own harness.

```java
@isTest
static void testPollerChain() {
    Test.startTest();
    Id run1Id = WorkflowEngine.start('PollerWorkflow', 'PollerKey', 0);
    new WorkflowTestHarness(run1Id).drive(); // → ContinuedAsNew

    Workflow_Instance__c run2 = [SELECT Id FROM Workflow_Instance__c WHERE Previous_Instance__c = :run1Id];
    new WorkflowTestHarness(run2.Id).drive(); // → ContinuedAsNew

    Workflow_Instance__c run3 = [SELECT Id FROM Workflow_Instance__c WHERE Previous_Instance__c = :run2.Id];
    WorkflowTestHarness.Result final = new WorkflowTestHarness(run3.Id).drive();
    Test.stopTest();

    System.assertEquals('Completed', final.status);
}
```

---

## Pattern 9 — Step-level unit tests (skip the harness entirely)

For CPU/SOQL-heavy steps, or when you need to prove idempotency across many re-executions, construct `StepContext` using the fluent `StepContextTestBuilder` and call `step.execute(ctx)` directly. This runs in a single lightweight unit test transaction with **0 DML** and **0 SOQL** statements, and accumulates no framework overhead.

```java
@isTest
static void testStepIdempotency() {
    // Construct a StepContext fluently — no DML, no SOQL, no positional constructors.
    StepContext ctx = new StepContextTestBuilder()
        .workflowName('MyWorkflow')
        .stepName('MyWorkflow.ChargeStep')
        .workflowInputJson('{"amountCents":4200}')
        .build();

    StepResult result = new MyWorkflow.ChargeStep().execute(ctx);
    System.assertEquals(StepResult.ActionType.COMPLETE, result.directive().action);

    // Re-run with the same context — side effects should be deduplicated.
    StepResult retry = new MyWorkflow.ChargeStep().execute(ctx);
    System.assert(((Map<String,Object>)JSON.deserializeUntyped(retry.directive().outputJson)).get('deduplicated') == true);
}
```

For more detailed information, see the [StepContextTestBuilder Developer Guide](./step-context-test-builder.md). See `IdempotentChargeWorkflowExampleTest.testChargePaymentStepWithBuilder` for a reference example.

---

## Pattern 10 — Fault injection

For testing saga compensation, retries, and rollback failure states on unmodified workflows, use `failStep` and `failStepOnce`. These allow you to force any step to throw an exception at runtime without changing the workflow definition or step class.

```java
@isTest
static void testSagaRollbackWithFault() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start('MyWorkflow', 'key-1', null);
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);

    // Fail the second step forward to trigger compensation of the first step
    harness.failStep('MyWorkflow.SecondStep', 'Injected forward failure');

    // Also fail the compensation of the first step to test the incomplete rollback state
    harness.failStep('MyWorkflow.FirstStep_Compensate', 'Injected compensation failure');

    WorkflowTestHarness.Result result = harness.drive();
    Test.stopTest();

    System.assertEquals('CompensationFailed', result.status);
}
```

---

## Pattern 11 — Durable timer (sleep)

By default, `drive()` automatically skips/resumes sleeps and retries. To test sleeps step-by-step, set `disableAutoTimeSkip = true` on the harness, use `step()` to execute the sleeping step, assert that the result `isSleeping` is true and status is `Suspended`, and then call `fireSleep` to resume.

```java
@isTest
static void testSleepWorkflow() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start('MySleepWorkflow', 'key-1', null);
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.disableAutoTimeSkip = true;

    // Run up to the sleep step
    WorkflowTestHarness.Result result = harness.step();
    System.assertEquals('Suspended', result.status);
    System.assertEquals(true, result.isSleeping);

    // Skip the sleep timer and resume
    WorkflowTestHarness.Result finalResult = harness.fireSleep('MySleepWorkflow.SleepStep');
    Test.stopTest();

    System.assertEquals('Completed', finalResult.status);
}
```

---

## Pattern 12 — Retry back-off

To verify how step retries behave over multiple attempts, set `disableAutoTimeSkip = true` on the harness. Each attempt will pause with `isAwaitingRetry = true` and `Suspended` status. Call `fireRetry` to execute each subsequent attempt.

```java
@isTest
static void testRetryWorkflow() {
    Test.startTest();
    Id instanceId = WorkflowEngine.start('MyRetryWorkflow', 'key-1', null);
    WorkflowTestHarness harness = new WorkflowTestHarness(instanceId);
    harness.disableAutoTimeSkip = true;

    // Run first attempt (which fails and schedules retry)
    WorkflowTestHarness.Result result = harness.step();
    System.assertEquals('Suspended', result.status);
    System.assertEquals(true, result.isAwaitingRetry);

    // Fire the retry (runs second attempt, which also fails)
    WorkflowTestHarness.Result secondResult = harness.fireRetry('MyRetryWorkflow.RetryStep');
    System.assertEquals('Suspended', secondResult.status);
    System.assertEquals(true, secondResult.isAwaitingRetry);

    // Fire the retry again (runs third attempt, which succeeds)
    WorkflowTestHarness.Result finalResult = harness.fireRetry('MyRetryWorkflow.RetryStep');
    Test.stopTest();

    System.assertEquals('Completed', finalResult.status);
}
```

---

## When not to use the harness

| Scenario | Why not harness | What to do instead |
|---|---|---|
| Step makes a `@future` callout | Harness drives synchronously; nested async isn't interceptable | Use `Test.stopTest()` to fire the Queueable, then call the `@future` helper directly |
| Testing `WorkflowEngine.processWatchdogHeartbeat()` | You're testing the sweep path, not a DAG | Inject expired `Timeout_At__c` in DB, call `processWatchdogHeartbeat()` directly |
| Step issues 50+ SOQLs on its own | All hops share one transaction's limits | Unit-test the step in isolation via Pattern 9 |
| Workflow has 100+ steps | Same limit concern as above | Test sub-segments, not the full end-to-end chain in one test |

---

## Governor limit cheat sheet

| Resource | Per-transaction limit | Implication |
|---|---|---|
| SOQL queries | 101 | Each `runStep` + `buildResult` + `collectTree` costs a few queries |
| CPU time | 10 000 ms | Heavy step logic accumulates across hops |
| Heap | 6 MB | Large payload workflows hit this fast in test |
| DML rows | 10 000 | Fanout with many children can approach this |

When a test hits a limit, the fix is not to increase the hop budget — it is to move the heavy step to a unit test and keep the harness integration test shallow.
