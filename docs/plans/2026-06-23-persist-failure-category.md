# Persist Failure Category on Failed Workflow Instances Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Persist a structured failure category (`Failure_Category__c`) on failed or rollback-incomplete workflow instances so operators can query, filter, and alert on specific categories of failures (timeouts, retry exhaustion, step exceptions, compensation failures).

**Architecture:** 
1. Create a new custom picklist field `Failure_Category__c` on `Workflow_Instance__c` with values: `STEP_EXCEPTION`, `RETRIES_EXHAUSTED`, `TIMEOUT`, `COMPENSATION_FAILED`, `EXPLICIT_FAIL`, and `UNKNOWN`.
2. Update the `WorkflowEngine` failure path (specifically `failWorkflowInstance` overloads and clearing methods) to save and reset `Failure_Category__c` appropriately.
3. Update `WorkflowTimeoutJob` to pass `TIMEOUT` when calling `failWorkflowInstance`.
4. Update `WorkflowDashboardController` to include `Failure_Category__c` in returned queries and allow filtering.
5. Update LWC `workflowDashboard` to expose the filter and display the category on the details panel.

**Tech Stack:** Salesforce DX, Apex, Lightning Web Components (LWC).

---

### Task 1: Create Custom Field Metadata

**Files:**
- Create: `force-app/main/default/objects/Workflow_Instance__c/fields/Failure_Category__c.field-meta.xml`

**Step 1: Write picklist metadata**
Create `Failure_Category__c.field-meta.xml` with:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Failure_Category__c</fullName>
    <description>Structured terminal failure cause determined by the engine.</description>
    <externalId>false</externalId>
    <label>Failure Category</label>
    <required>false</required>
    <trackTrending>false</trackTrending>
    <type>Picklist</type>
    <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value>
                <fullName>STEP_EXCEPTION</fullName>
                <default>false</default>
                <label>Step Exception</label>
            </value>
            <value>
                <fullName>RETRIES_EXHAUSTED</fullName>
                <default>false</default>
                <label>Retries Exhausted</label>
            </value>
            <value>
                <fullName>TIMEOUT</fullName>
                <default>false</default>
                <label>Timeout</label>
            </value>
            <value>
                <fullName>COMPENSATION_FAILED</fullName>
                <default>false</default>
                <label>Compensation Failed</label>
            </value>
            <value>
                <fullName>EXPLICIT_FAIL</fullName>
                <default>false</default>
                <label>Explicit Step Failure</label>
            </value>
            <value>
                <fullName>UNKNOWN</fullName>
                <default>true</default>
                <label>Unknown</label>
            </value>
        </valueSetDefinition>
    </valueSet>
</CustomField>
```

**Step 2: Deploy to scratch org**
Run: `sf project deploy start`
Expected: SUCCESS

---

### Task 2: Implement Apex failing tests for each failure category (RED Phase)

**Files:**
- Modify: `force-app/main/default/classes/WorkflowEngineTest.cls`

**Step 1: Write the failing tests**
We will add assertions to the existing tests or add new tests:
- In `WorkflowEngineTest.testStepException`, assert `Failure_Category__c` equals `'STEP_EXCEPTION'`.
- In `WorkflowEngineTest.testRetryExhausted` (or similar retry test), assert `Failure_Category__c` equals `'RETRIES_EXHAUSTED'`.
- In `WorkflowEngineTest.testCompensationFailed` (or similar compensation crash test), assert `Failure_Category__c` equals `'COMPENSATION_FAILED'`.
- In `WorkflowEngineTest.testWorkflowTimeout`, assert `Failure_Category__c` equals `'TIMEOUT'`.

**Step 2: Run tests to verify they fail**
Run: `sf apex run test -n WorkflowEngineTest -w 5`
Expected: Compilation failure or assertion failure because `Failure_Category__c` does not exist in class/SOQL or is null.

---

### Task 3: Implement minimal engine changes to pass tests (GREEN Phase)

**Files:**
- Modify: `force-app/main/default/classes/WorkflowEngine.cls`
- Modify: `force-app/main/default/classes/WorkflowTimeoutJob.cls`

**Step 1: Implement overloads and category persistence**
- In `WorkflowEngine.cls`, add `failWorkflowInstance` with `failureCategory` parameter:
```java
  public static void failWorkflowInstance(
    Id instanceId,
    String stepName,
    String errorMessage
  ) {
    failWorkflowInstance(instanceId, stepName, errorMessage, 'UNKNOWN');
  }

  public static void failWorkflowInstance(
    Id instanceId,
    String stepName,
    String errorMessage,
    String failureCategory
  ) {
    // ...
```
- In `failWorkflowInstance`:
  - Set `instance.Failure_Category__c = 'COMPENSATION_FAILED'` if `isCompensationFailure` is true.
  - Set `instance.Failure_Category__c = failureCategory` when status is set to `'Failed'`.
- In `handleCrash(Id instanceId, String stepName, Exception ex)`, pass `'STEP_EXCEPTION'` to `failWorkflowInstance`.
- In `handleStepResult`:
  - When retry attempts are exhausted, pass `'RETRIES_EXHAUSTED'` to `failWorkflowInstance`.
  - When step returns `StepResult.ActionType.FAIL`, pass `'EXPLICIT_FAIL'` to `failWorkflowInstance`.
- In `retryWorkflowInstance` and `resumeRollback`, clear `Failure_Category__c` to `null`.
- In `WorkflowTimeoutJob.cls`, pass `'TIMEOUT'` to `failWorkflowInstance`.

**Step 2: Run tests to verify they pass**
Run: `sf apex run test -n WorkflowEngineTest -w 5`
Expected: All tests PASS.

---

### Task 4: Implement Dashboard Controller filtering and tests (TDD)

**Files:**
- Modify: `force-app/main/default/classes/WorkflowDashboardController.cls`
- Modify: `force-app/main/default/classes/WorkflowDashboardControllerTest.cls`

**Step 1: Write failing test in WorkflowDashboardControllerTest**
- Assert `getFilteredInstances` with `failureCategory` filter works.
- Assert `getInstanceDetails` returns `Failure_Category__c`.

**Step 2: Implement Controller changes**
- Add `String failureCategory` parameter to `getFilteredInstances`.
- Include `Failure_Category__c` in queries.
- Update `buildWhereClause` to append category filter conditions.

**Step 3: Verify tests pass**
Run: `sf apex run test -n WorkflowDashboardControllerTest -w 5`
Expected: PASS.

---

### Task 5: Implement UI display and filter in LWC

**Files:**
- Modify: `force-app/main/default/lwc/workflowDashboard/workflowDashboard.html`
- Modify: `force-app/main/default/lwc/workflowDashboard/workflowDashboard.js`

**Step 1: Update LWC HTML and JS**
- Add Failure Category combobox filter (only shown if status is Failed/CompensationFailed or All Statuses).
- Add Failure Category label/badge to Instance Details view.
- Update JS to pass `failureCategory` when calling `getFilteredInstances`.

**Step 2: Deploy and verify LWC**
Run LWC Jest tests (if any) or check compilation/deployment.
Run: `sf project deploy start`
Expected: SUCCESS.
