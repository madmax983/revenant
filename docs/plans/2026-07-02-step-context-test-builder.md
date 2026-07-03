# StepContextTestBuilder Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a fluent, self-documenting test builder for StepContext to enable isolated, 0-DML/0-SOQL unit tests for WorkflowSteps.

**Architecture:** Build a `StepContextTestBuilder` class in Apex with chained setters for all StepContext fields. It will internally instantiate a `StaticSignalSource` to seed signals and use `@TestVisible` `StepContext.withCapturedValuesMap` to construct the real `StepContext` with pre-seeded captures.

**Tech Stack:** Apex, Salesforce CLI (sf)

---

### Task 1: Create failing tests for StepContextTestBuilder (RED Phase)

**Files:**
- Create: `force-app/main/default/classes/StepContextTestBuilderTest.cls`
- Create: `force-app/main/default/classes/StepContextTestBuilderTest.cls-meta.xml`

**Step 1: Write the failing test**
Create a new test class with tests verifying that `StepContextTestBuilder` can build a real `StepContext` with standard fields, pre-seeded `once()` captures, and signals, without any database operations.

**Step 2: Run test to verify it fails**
Run: `sf apex run test -n StepContextTestBuilderTest -w 5`
Expected: FAIL because the class `StepContextTestBuilder` does not exist yet.

---

### Task 2: Implement StepContextTestBuilder (GREEN Phase)

**Files:**
- Create: `force-app/main/default/classes/StepContextTestBuilder.cls`
- Create: `force-app/main/default/classes/StepContextTestBuilder.cls-meta.xml`

**Step 3: Write minimal implementation**
Implement `StepContextTestBuilder` with chained setters, faked ID generation, `StaticSignalSource` inner class, and `build()` method.

**Step 4: Run test to verify it passes**
Run: `sf apex run test -n StepContextTestBuilderTest -w 5`
Expected: PASS

**Step 5: Commit**
Add files and commit.

---

### Task 3: Refactor the Builder and Tests (REFACTOR Phase)

**Files:**
- Modify: `force-app/main/default/classes/StepContextTestBuilder.cls`
- Modify: `force-app/main/default/classes/StepContextTestBuilderTest.cls`

**Step 1-4:** Format and clean up code.
Run formatting: `npx prettier --write "force-app/main/default/classes/StepContextTestBuilder*"`
Run tests to verify they still pass.
**Step 5: Commit**

---

### Task 4: Add Reference Example Unit Test

**Files:**
- Modify: `examples/main/default/classes/IdempotentChargeWorkflowExampleTest.cls`

**Step 1: Write the failing test**
Add a unit test `testChargePaymentStepWithBuilder()` to `IdempotentChargeWorkflowExampleTest` that uses `StepContextTestBuilder` to test `ChargePaymentStep` with 0 DML and 0 SOQL.
Let's verify it compiles and runs correctly.
**Step 2: Run test**
Run: `sf apex run test -n IdempotentChargeWorkflowExampleTest -w 5`
Expected: PASS
**Step 3: Commit**

---

### Task 5: Document StepContextTestBuilder

**Files:**
- Create: `docs/step-context-test-builder.md`

**Step 1-4:** Create the markdown documentation showing example usage and advantages of the builder.
**Step 5: Commit**
