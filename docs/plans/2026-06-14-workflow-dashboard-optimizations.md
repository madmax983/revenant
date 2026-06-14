# WorkflowDashboardController Optimizations Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement access control, query optimization, and search enhancements to WorkflowDashboardController and verify them via Test-Driven Development.

**Architecture:**
- Introduce a static helper `checkAuthorization()` checking `Workflow_Admin` custom permission or `System Administrator` profile.
- Bulk resolve payloads in `getInstanceDetails` by parsing/extracting attachment IDs from instance and step execution records first, doing a single query to `ContentVersion`, mapping results, and truncating to 50k characters.
- Expand search condition to include `Error_Message__c` in `buildWhereClause`.
- Directly route signal in `submitApproval` using the `instanceId`.

**Tech Stack:** Salesforce Apex, SOQL, Custom Permissions, ContentVersion

---

## Tasks

### Task 1: Write failing tests for authorization, payload resolution, and error message search

**Files:**
- Modify: `force-app/main/default/classes/WorkflowDashboardControllerTest.cls`

**Step 1: Write the failing tests**
Add the following test methods to `WorkflowDashboardControllerTest.cls`:
- `testAuthorizationCheckFailure()`: Create standard user, call each controller method under `System.runAs`, verify it throws `AuraHandledException` with the specific message.
- `testBulkPayloadResolution()`: Verify large payloads from ContentVersion are retrieved in a single query, resolved, and capped at 50,000 characters.
- `testSearchByErrorMessage()`: Search using a term that matches `Error_Message__c` and verify that the filtered results return the expected instance.

**Step 2: Deploy and run tests to verify they fail**
Run:
```powershell
sf project deploy start
sf apex run test -n WorkflowDashboardControllerTest -y -r human
```
Expected: Compilation failure or test failures (depending on whether the methods we call exist, but we are modifying existing entry points so they should compile and fail because they are not yet restricted/implemented).

---

### Task 2: Implement changes in WorkflowDashboardController

**Files:**
- Modify: `force-app/main/default/classes/WorkflowDashboardController.cls`

**Step 1: Implement checkAuthorization() and add calls to entry points**
- Add private static helper `checkAuthorization()`.
- Add `checkAuthorization();` to the top of all 8 AuraEnabled entry points.

**Step 2: Implement search by Error_Message__c**
- Modify `buildWhereClause` to include `OR Error_Message__c LIKE :likeTerm`.

**Step 3: Implement optimized submitApproval**
- Remove query on `Workflow_Instance__c` in `submitApproval` and pass `String.valueOf(instanceId)` directly to `WorkflowEngine.signal`.

**Step 4: Implement bulk payload resolution in getInstanceDetails**
- Extract attachment IDs from instance input/output and step input/output.
- Query all relevant `ContentVersion` records in a single query.
- Resolve and truncate payloads to 50k characters (adding `... (truncated)` suffix if exceeded).

---

### Task 3: Verify and Refactor

**Step 1: Deploy and run tests**
Run:
```powershell
sf project deploy start
sf apex run test -n WorkflowDashboardControllerTest -y -r human
```
Expected: PASS

**Step 2: Format and Clean Up**
Ensure code follows formatting and styling standards.
Run:
```powershell
sf project deploy start
```
Verify tests remain green.

---

### Task 4: Commit and Report

**Step 1: Commit the changes**
Run:
```powershell
git add force-app/main/default/classes/WorkflowDashboardController.cls force-app/main/default/classes/WorkflowDashboardControllerTest.cls
git commit -m "feat: implement WorkflowDashboardController gates, bulk payload resolution, search by error message, and submitApproval optimization"
```

**Step 2: Report back with git diff and test output**
- Print git diff.
- Print test execution report.
