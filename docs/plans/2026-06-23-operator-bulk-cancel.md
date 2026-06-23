# Operator Bulk Cancel (Issue #43) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add operator-initiated bulk cancellation for active workflow instances matching the dashboard filter.

**Architecture:** Implement a new `BulkCancelWorkflow` definition that uses Revenant's engine to asynchronously query, page, and cancel active instances in chunks of 30, avoiding governor limit exhaustion. Integrate with `WorkflowDashboardController` and add a confirmation modal to the LWC dashboard frontend.

**Tech Stack:** Apex (Salesforce), LWC (Lightning Web Components)

---

### Task 1: Create failing tests in BulkCancelWorkflowTest.cls [Red Phase]

**Files:**
- Create: `force-app/main/default/classes/BulkCancelWorkflowTest.cls`

**Step 1: Write the failing tests**
Write a new test class `BulkCancelWorkflowTest` covering:
- Count of eligible instances includes only `Pending`, `Running`, `Suspended`, `Paused`, `CompensationFailed` and excludes `Completed`, `Failed`, `Compensating`, `Cancelled`, `ContinuedAsNew`.
- Excludes the bulk cancel workflow itself.
- Validates the paging query execution (fetching chunks).
- Validates that executing `BulkCancelWorkflow` transitions eligible active instances to `Cancelled`.
- Checks authorization for the controller methods.

**Step 2: Run test to verify it fails**
Run: `sf apex run test --tests BulkCancelWorkflowTest --wait 10`
Expected: Compile failure (class doesn't exist yet).

---

### Task 2: Implement core BulkCancelWorkflow [Green Phase]

**Files:**
- Create: `force-app/main/default/classes/BulkCancelWorkflow.cls`

**Step 1: Write the minimal implementation**
Implement the `BulkCancelWorkflow` class implementing `WorkflowDefinition`:
- Define `countEligible(workflowName, status, searchTerm)`: Returns the count of active instances matching the criteria, restricted to: `Pending`, `Running`, `Suspended`, `Paused`, `CompensationFailed`.
- Define `fetchEligibleChunk(workflowName, status, searchTerm, afterId, chunkSize)`: Queries the next page of eligible instance IDs.
- Define `BulkCancelStep` implementing `WorkflowStep`:
  - Page over candidate IDs using `fetchEligibleChunk`.
  - For each, invoke `WorkflowEngine.cancel(instanceId, false)`.
  - Yield if `ctx.shouldYield()` is true.

**Step 2: Run test to verify it passes**
Run: `sf apex run test --tests BulkCancelWorkflowTest --wait 10`
Expected: PASS.

---

### Task 3: Modify WorkflowPauseGate and WorkflowDashboardController [Red & Green Phase]

**Files:**
- Modify: `force-app/main/default/classes/WorkflowPauseGate.cls`
- Modify: `force-app/main/default/classes/WorkflowPauseTest.cls`
- Modify: `force-app/main/default/classes/WorkflowDashboardController.cls`
- Modify: `force-app/main/default/classes/WorkflowDashboardControllerTest.cls`

**Step 1: Add tests for pause exemption and dashboard controller methods**
Write tests verifying:
- `BulkCancelWorkflow` cannot be paused (add to `WorkflowPauseTest.cls`).
- Controller methods `getCancelEligibleCount` and `cancelMatchingInstances` return correct results, and fail with `AuraHandledException` if unauthorized.

**Step 2: Implement pause exemption and controller methods**
- Add `BulkCancelWorkflow` to `WorkflowPauseGate.RESERVED_NAMES`.
- Modify `WorkflowDashboardController.cls` to:
  - Add `@AuraEnabled` methods `getCancelEligibleCount` and `cancelMatchingInstances`.
  - Exclude `BulkCancelWorkflow` from the list of runnable definitions in source scans.

**Step 3: Run all unit tests**
Run: `sf apex run test --test-level RunLocalTests --wait 10`
Expected: PASS.

---

### Task 4: Implement Frontend Dashboard Changes & LWC Unit Tests [Red & Green Phase]

**Files:**
- Modify: `force-app/main/default/lwc/workflowDashboard/workflowDashboard.html`
- Modify: `force-app/main/default/lwc/workflowDashboard/workflowDashboard.js`
- Modify: `force-app/main/default/lwc/workflowDashboard/__tests__/workflowDashboard.test.js`

**Step 1: Add frontend Jest tests for cancel modal and button**
Write frontend tests checking that:
- "Cancel Matching Active" button is enabled/visible only when applicable.
- Confirm modal opens and shows the eligible count.
- Clicking confirm calls the cancel controller method.

**Step 2: Modify HTML and JS components**
- Add the button and modal to the HTML.
- Import Apex methods and implement UI state logic in JS.

**Step 3: Run Jest tests**
Run: `npm run test:unit`
Expected: PASS.

---

### Task 5: Refactor and Verify [Refactor Phase]

**Files:**
- Format: `force-app/main/default/classes/BulkCancelWorkflow.cls`
- Format: `force-app/main/default/classes/BulkCancelWorkflowTest.cls`
- Format: `force-app/main/default/classes/WorkflowDashboardController.cls`
- Format: `force-app/main/default/classes/WorkflowPauseGate.cls`

**Step 1: Code review and refactoring**
Review for PMD or ESLint issues, make sure `cargo fmt` equivalents or Prettier are run, check formatting.

**Step 2: Deploy and verify local tests**
Deploy all metadata to Scratch Org and run tests:
Run: `sf project deploy start`
Run: `sf apex run test --test-level RunLocalTests --wait 10`
Expected: PASS.
