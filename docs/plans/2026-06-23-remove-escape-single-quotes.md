# Remove Redundant escapeSingleQuotes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove redundant `String.escapeSingleQuotes()` on dynamic SOQL bind variables in `WorkflowDashboardController.cls` and add test coverage in `WorkflowDashboardControllerTest.cls` verifying searches with single quotes work cleanly.

**Architecture:** Bind variables in dynamic SOQL are automatically escaped by the Salesforce runtime. Calling `escapeSingleQuotes()` on the variable before binding leads to double escaping (e.g. `O'Connor` becomes `O\'Connor`), causing queries to search for literal backslashes and quotes instead of matching records. Removing `String.escapeSingleQuotes()` resolves this.

**Tech Stack:** Salesforce Apex

---

### Task 1: Write a failing test in WorkflowDashboardControllerTest.cls

**Files:**
- Modify: `force-app/main/default/classes/WorkflowDashboardControllerTest.cls`

**Step 1: Write the failing test**
Add the `testSearchWithSingleQuote` method to `WorkflowDashboardControllerTest.cls` before the class closing brace. The test will create a `Workflow_Instance__c` and a `Workflow_Signal__c` with values containing a single quote (e.g., `'O\'Connor'`), and then call `getFilteredInstances`, `getStalledInstances`, `getStalledCount`, `getUnroutedSignals`, and `getUnroutedSignalCount` using `'O\'Connor'` as the search term, asserting that they match the created records successfully.

**Step 2: Run test to verify it fails**
Run: `sf apex run test --tests WorkflowDashboardControllerTest --wait 10`
Expected: Failure / incorrect matches because the dynamic SOQL queries double-escape the single quote, looking for `O\'Connor` instead of `O'Connor`.

---

### Task 2: Remove escapeSingleQuotes in WorkflowDashboardController.cls

**Files:**
- Modify: `force-app/main/default/classes/WorkflowDashboardController.cls`

**Step 1: Modify line 231**
Remove `String.escapeSingleQuotes()` wrapper on `searchTerm`.
Before:
`likeTerm = '%' + String.escapeSingleQuotes(searchTerm) + '%';`
After:
`likeTerm = '%' + searchTerm + '%';`

**Step 2: Modify line 263**
Remove `String.escapeSingleQuotes()` wrapper on `searchTerm`.
Before:
`likeTerm = '%' + String.escapeSingleQuotes(searchTerm) + '%';`
After:
`likeTerm = '%' + searchTerm + '%';`

**Step 3: Modify line 1980**
Remove `String.escapeSingleQuotes()` wrapper on `searchTerm.trim()`.
Before:
`likeTerm = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';`
After:
`likeTerm = '%' + searchTerm.trim() + '%';`

**Step 4: Modify line 2018**
Remove `String.escapeSingleQuotes()` wrapper on `searchTerm.trim()`.
Before:
`likeTerm = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';`
After:
`likeTerm = '%' + searchTerm.trim() + '%';`

---

### Task 3: Deploy and verify tests pass

**Step 1: Deploy changed files**
Run: `sf project deploy start`
Expected: Successful deployment.

**Step 2: Run Apex tests**
Run: `sf apex run test --tests WorkflowDashboardControllerTest --wait 10`
Expected: All 60 tests (including `testSearchWithSingleQuote`) pass cleanly.
