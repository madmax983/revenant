# StepContextTestBuilder Developer Guide

`StepContextTestBuilder` is a test-support builder shipped with Revenant to make isolated unit testing of individual `WorkflowStep` execution and compensation logic fast and simple.

It enables unit-testing step behavior (input parsing, branching, idempotency, output shaping, signal handling) in milliseconds with **0 DML** and **0 SOQL** statements.

---

## Features

- **Fluent Chained Setters**: Easily set any property of `StepContext` (workflow name, step name, instance ID, inputs, outputs, attempt count).
- **Auto-serialization Overloads**: Set map/object inputs directly via `input(Object)`, `workflowInput(Object)`, `previousStepOutput(Object)`, and `stepState(Object)`. They are automatically serialized to JSON.
- **Auto-generated IDs**: Automatically generates valid faked Salesforce IDs for the workflow instance and signal records if they are not explicitly specified.
- **Inbound Signal Seeding**: Seed inbound signals via name and payload (or full Signal objects) without inserting `Workflow_Signal__c` database rows.
- **Pre-seeded once() Captures**: Seed stable return values for the `once()` capture-once API without running the producers. Seeded values are automatically JSON-normalized to replicate production deserialization boundaries.
- **Genuine StepContext**: Produces a real `StepContext` instance, ensuring that methods like `once()`, `getSignal()`, `idempotencyKey`, and `getPendingEmits()` behave exactly as they do in production.

---

## Basic Usage

To unit-test a `WorkflowStep` in isolation, construct a mock `StepContext` using the builder and call `execute()` or `compensate()` on your step directly:

```java
@isTest
static void testMyStepInIsolation() {
    // 1. Arrange: Build a StepContext with custom step inputs directly as Objects/Maps
    StepContext ctx = new StepContextTestBuilder()
        .workflowInput(new Map<String, Object>{'amountCents' => 5000})
        .input(new Map<String, Object>{'paymentMethod' => 'CreditCard'})
        .build();

    // 2. Act: Instantiate the step and call execute directly
    StepResult result = new MyWorkflow.ChargePaymentStep().execute(ctx);

    // 3. Assert on outputs and next step routing
    System.assertEquals(StepResult.ActionType.COMPLETE, result.action);
    System.assertEquals('MyWorkflow.SuccessStep', result.nextStepName);
    Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(result.outputJson);
    System.assertEquals('Success', (String) output.get('status'));
}
```

---

## Seeding Inbound Signals

You can simulate inbound signals on the instance by using `addSignal(name, payload)`:

```java
@isTest
static void testStepWaitingForApproval() {
    // Arrange: Seed an approval signal with a payload
    StepContext ctx = new StepContextTestBuilder()
        .addSignal('Approve:Order', '{"approved":true,"approver":"mgr@example.com"}')
        .build();

    // Act: Execute the step
    StepResult result = new MyWorkflow.ShipOrderStep().execute(ctx);

    // Assert: The step successfully consumed the signal
    System.assertEquals('MyWorkflow.DeliverStep', result.nextStepName);
}
```

---

## Seeding once() Captured Values

If a step uses the capture-once API (`ctx.once(key, producer)`) to stabilize non-deterministic values (like generated reference numbers or timestamps), you can pre-seed their values to test replay behavior. Seeded values undergo a JSON serialize/deserialize round-trip to guarantee 100% fidelity with the production database serialization:

```java
@isTest
static void testReplayBehavior() {
    // Arrange: Pre-seed the capture value for 'txId'
    StepContext ctx = new StepContextTestBuilder()
        .once('txId', 'TX-777')
        .build();

    // Act: The step will read 'TX-777' without executing its random ID producer
    StepResult result = new MyWorkflow.GenerateInvoiceStep().execute(ctx);

    // Assert
    Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(result.outputJson);
    System.assertEquals('TX-777', (String) output.get('invoiceTxId'));
}
```

---

## Testing Idempotent Replays

By sharing the same `workflowInstanceId` and defaults, you can verify that step re-executions yield the same idempotency key, allowing you to test idempotent integration endpoints:

```java
@isTest
static void testStepIdempotency() {
    MockPaymentGateway.reset();
    Id instanceId = Id.valueOf(Workflow_Instance__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001');

    // Attempt 1
    StepContext ctx1 = new StepContextTestBuilder()
        .workflowInstanceId(instanceId)
        .build();
    new MyWorkflow.ChargeStep().execute(ctx1);

    // Attempt 2 (Retry/Re-execution)
    StepContext ctx2 = new StepContextTestBuilder()
        .workflowInstanceId(instanceId)
        .build();

    System.assertEquals(ctx1.idempotencyKey, ctx2.idempotencyKey, 'Idempotency keys must be stable');

    StepResult res2 = new MyWorkflow.ChargeStep().execute(ctx2);
    // Assert that the MockPaymentGateway deduplicated and returned the same result
    System.assertEquals(1, MockPaymentGateway.chargeCount);
}
```
