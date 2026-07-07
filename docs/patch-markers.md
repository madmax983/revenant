# Patch and Upgrade Markers

This document explains how to safely patch and upgrade workflow step logic in Revenant without interrupting or breaking long-running, in-flight workflow instances.

## Overview

When you modify the logic of a step or change the transition flow of a `WorkflowDefinition` DAG, active in-flight instances created before the change was deployed may crash if they are forced down the new path (due to missing state variables, different payload schemas, or changed outcomes).

Revenant solves this using **Durable Patch Markers**. These markers allow:
1. **Brand-New Instances**: Executed after the patch was introduced to automatically take the new path.
2. **In-Flight Instances**: Executed before the patch was introduced to remain on the legacy path.
3. **Determinism**: Once a decision (`true` or `false`) is made for an instance, it is durably persisted and replayed consistently across all steps.

---

## APIs

The upgrade system provides three public APIs on `StepContext` (`ctx`) and `WorkflowEngine`.

### 1. `ctx.patched(String changeId, DateTime introducedAt)`
Use this method inside a step to branch your logic.

* **Parameters**:
  - `changeId`: A unique string identifier for the patch (e.g. `'billing-refactor-v2'`).
  - `introducedAt`: The `DateTime` when the patch was officially introduced. If omitted, the compilation timestamp (`LastModifiedDate` of the outer class) is used as a fallback.
* **Return Value**:
  - `true` if this execution should use the new logic.
  - `false` if it must run the legacy logic.

#### Example:
```java
public class MyWorkflowStep implements WorkflowStep {
  public void execute(StepContext ctx) {
    // We want to change the calculation formula
    if (ctx.patched('new-tax-calc', DateTime.newInstance(2026, 7, 7, 12, 0, 0))) {
      // New logic
      Decimal tax = calculateNewTax(ctx);
      ctx.capture('tax', tax);
    } else {
      // Legacy logic
      Decimal tax = calculateOldTax(ctx);
      ctx.capture('tax', tax);
    }
  }
}
```

### 2. `ctx.deprecated(String changeId, DateTime retiredAt)`
Once a patch has been fully adopted by all active instances, the legacy code branch can be retired. Use `ctx.deprecated` to mark the legacy path. If an instance attempts to execute this path after the retirement date, it will throw a descriptive runtime exception.

#### Example:
```java
public class MyWorkflowStep implements WorkflowStep {
  public void execute(StepContext ctx) {
    if (ctx.patched('new-tax-calc')) {
      Decimal tax = calculateNewTax(ctx);
      ctx.capture('tax', tax);
    } else {
      // Legacy path is now retired
      ctx.deprecated('new-tax-calc', DateTime.newInstance(2026, 9, 1));
      Decimal tax = calculateOldTax(ctx);
      ctx.capture('tax', tax);
    }
  }
}
```

### 3. `WorkflowEngine.getPatchAdoptionCount(String changeId, DateTime introducedAt)`
Before deleting legacy code, verify that no active in-flight instances are still relying on it.

* **Parameters**:
  - `changeId`: The unique patch identifier.
  - `introducedAt`: The `DateTime` when the patch was introduced.
* **Returns**:
  - `Integer`: The number of active instances that are still upstream of the patch and will evaluate to `false` when they reach it.
  - Returns `0` when it is 100% safe to retire the legacy code branch.

---

## Best Practices

1. **Unique Change IDs**: Always use descriptive, unique change IDs (e.g. `'stepname-description-version'`).
2. **Compile-Time Safe**: If you don't pass an `introducedAt` timestamp, Revenant will use the modified date of the class containing the step. However, it is highly recommended to pass an explicit `introducedAt` date to prevent subsequent unrelated class deployments from resetting the decision date of new instances.
3. **Zero SOQL inside loops**: The lookup mechanism uses high-performance, bulkified aggregate queries. It is safe to use `ctx.patched()` inside loops.
