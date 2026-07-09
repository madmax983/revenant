# Migrate Rate Limit Example to Two-Step Pattern Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate the rate-limited callout workflow example to a safe two-step pattern, clean up comparison logic, add descriptive assertions to tests, format the code using Prettier, and verify the changes by deploying and running tests.

**Architecture:** Split the single-step throttled callout into Step 1 (`AcquireTokenStep`) which calls `RateLimiter.acquire()` and sleeps if blocked, and Step 2 (`ThrottledCalloutStep`) which performs the callout using `ctx.idempotencyKey`. This avoids `System.CalloutException` due to uncommitted work pending after a DML operation within the same step/transaction.

**Tech Stack:** Salesforce Apex, Salesforce CLI (sf), Prettier (Apex plugin)

---

### Task 1: Refactor ThrottledCalloutWorkflowExample Class

**Files:**
- Modify: `examples/main/default/classes/ThrottledCalloutWorkflowExample.cls`

**Step 1: Refactor the workflow definition and steps**
Update `ThrottledCalloutWorkflowExample.cls` to:
1. Define the workflow with two steps: `ThrottledCalloutWorkflowExample.AcquireTokenStep` as initial, and then `ThrottledCalloutWorkflowExample.ThrottledCalloutStep`.
2. Implement `AcquireTokenStep` to call `RateLimiter.acquire()`, handle throttling using `!result.isAllowed` (clean boolean comparison), and transition to `ThrottledCalloutStep` on success.
3. Implement `ThrottledCalloutStep` to perform the actual callout using `ctx.idempotencyKey`.

**Step 2: Commit intermediate progress**
Commit the modified file.

---

### Task 2: Update ThrottledCalloutWorkflowExampleTest Class

**Files:**
- Modify: `examples/main/default/classes/ThrottledCalloutWorkflowExampleTest.cls`

**Step 1: Update the test logic and assertions**
Update `ThrottledCalloutWorkflowExampleTest.cls` to:
1. Adapt to the new two-step flow. When running workflow instances, the first step is `AcquireTokenStep` and the second step is `ThrottledCalloutStep`.
2. Ensure that driving instance 1 completes all steps.
3. Ensure that driving instance 2 gets blocked at `AcquireTokenStep`, is suspended/sleeping, and then successfully transitions through `ThrottledCalloutStep` and completes after time is advanced.
4. Add descriptive assertion messages to the final assertions.

**Step 2: Commit intermediate progress**
Commit the modified test file.

---

### Task 3: Format Code

**Files:**
- Modify: `examples/main/default/classes/ThrottledCalloutWorkflowExample.cls`
- Modify: `examples/main/default/classes/ThrottledCalloutWorkflowExampleTest.cls`

**Step 1: Run Prettier formatting**
Run: `npx prettier --write --plugin=prettier-plugin-apex "examples/main/default/classes/ThrottledCalloutWorkflowExample*"`
Expected: Files formatted with 2-space indentation.

**Step 2: Commit intermediate progress**
Commit the formatted files.

---

### Task 4: Deploy and Verify Tests

**Step 1: Deploy to org**
Run: `sf project deploy start --ignore-conflicts`
Expected: Successful deployment.

**Step 2: Run Apex tests**
Run: `sf apex run test -n ThrottledCalloutWorkflowExampleTest -w 5`
Expected: Test passes successfully.

**Step 3: Commit all changes**
Commit final state with the message `"refactor: migrate rate limit example to two-step pattern and format code"`.
