# Searchable Business Attributes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow operators to attach bounded business attributes (e.g. region=EU) to workflow instances and filter by them using an index-backed, selective equality query on the dashboard.

**Architecture:** Create a new custom child object `Workflow_Search_Attribute__c` with a Master-Detail relationship to `Workflow_Instance__c`. Store business attributes in this object, utilizing an External ID field `Key_Value__c` (containing `Key + '=' + Value`) to automatically create a standard index on the attribute key-value pair. Modify `WorkflowEngine.cls`, `WorkflowStartInvocableAction.cls`, and `WorkflowDashboardController.cls` to populate, validate, query, and return these attributes. Update `workflowDashboard` LWC component to filter by attributes and display them in the detail panel.

**Tech Stack:** Salesforce Apex, custom metadata, LWC, Jest, Git.

---

### Task 1: Create Custom Object Schema

**Files:**
- Create: `force-app/main/default/objects/Workflow_Search_Attribute__c/Workflow_Search_Attribute__c.object-meta.xml`
- Create: `force-app/main/default/objects/Workflow_Search_Attribute__c/fields/Workflow_Instance__c.field-meta.xml`
- Create: `force-app/main/default/objects/Workflow_Search_Attribute__c/fields/Key__c.field-meta.xml`
- Create: `force-app/main/default/objects/Workflow_Search_Attribute__c/fields/Value__c.field-meta.xml`
- Create: `force-app/main/default/objects/Workflow_Search_Attribute__c/fields/Key_Value__c.field-meta.xml`
- Modify: `force-app/main/default/permissionsets/Revenant_Admin.permissionset-meta.xml`

**Step 1: Write Custom Object Schema**
Create the object-meta file and the four field-meta files.
Update the `Revenant_Admin` permission set to grant access to the new object and its custom fields (`Key__c`, `Value__c`, `Key_Value__c`).

**Step 2: Deploy Schema to Scratch Org**
Run: `sf project deploy start`
Expected: Successful deploy of custom object metadata and permissions.

---

### Task 2: Implement Apex TDD - Engine Start Attribute Validation and Persistence

**Files:**
- Modify: `force-app/main/default/classes/WorkflowEngine.cls`
- Modify: `force-app/main/default/classes/WorkflowEngineTest.cls`

**Step 1: Write the failing tests in WorkflowEngineTest**
Add tests to verify:
1. Validating attributes count limits (max 10).
2. Validating attribute key length (max 100) and value length (max 150).
3. Overload of `WorkflowEngine.start(...)` persisting attributes successfully on instance creation.
4. Get-or-start dedup preserving existing instance's attributes and not overwriting them.

**Step 2: Run tests to verify they fail**
Run: `sf apex run test --class WorkflowEngineTest --synchronous`
Expected: Failures due to missing methods / parameters or validation errors not thrown.

**Step 3: Implement Engine start overloads, validation, and database persistence**
Add constants:
- `MAX_ATTRIBUTES_PER_INSTANCE = 10`
- `MAX_ATTRIBUTE_KEY_LENGTH = 100`
- `MAX_ATTRIBUTE_VALUE_LENGTH = 150`

Add `validateAttributes` and `buildAttributes` helpers.
Add overloads for `start`, `startOrGet`, and update `StartRequest` / `doStart` to handle `Map<String, String> attributes`.
Persist attributes using `insert as system` on new instances.

**Step 4: Run tests to verify they pass**
Run: `sf apex run test --class WorkflowEngineTest --synchronous`
Expected: PASS.

**Step 5: Commit**
`git add force-app/main/default/classes/WorkflowEngine*`
`git commit -m "feat: implement searchable business attributes engine validation and persistence"`

---

### Task 3: Implement Invocable Action Support

**Files:**
- Modify: `force-app/main/default/classes/WorkflowStartInvocableAction.cls`
- Modify: `force-app/main/default/classes/WorkflowInvocableActionsTest.cls`

**Step 1: Write failing tests in WorkflowInvocableActionsTest**
Add a test that passes `attributesJson` to `StartRequest` and verifies they are persisted.

**Step 2: Run tests to verify they fail**
Run: `sf apex run test --class WorkflowInvocableActionsTest --synchronous`
Expected: Compilation failure or runtime failure.

**Step 3: Modify WorkflowStartInvocableAction**
Add `@InvocableVariable` `attributesJson` to `StartRequest`.
Deserialize it and pass to the engine start request.

**Step 4: Run tests to verify they pass**
Run: `sf apex run test --class WorkflowInvocableActionsTest --synchronous`
Expected: PASS.

**Step 5: Commit**
`git commit -am "feat: support attributes in WorkflowStartInvocableAction"`

---

### Task 4: Implement Dashboard Controller Attributes Query & Filter

**Files:**
- Modify: `force-app/main/default/classes/WorkflowDashboardController.cls`
- Modify: `force-app/main/default/classes/WorkflowDashboardControllerTest.cls`

**Step 1: Write failing tests in WorkflowDashboardControllerTest**
Add tests to verify:
1. `getInstanceDetails` returning attributes.
2. `getFilteredInstances` and `getWorkflowStats` filtering correctly by `attributesFilterJson` using AND logic.

**Step 2: Run tests to verify they fail**
Run: `sf apex run test --class WorkflowDashboardControllerTest --synchronous`
Expected: Failures.

**Step 3: Implement query & filter logic**
Define `matchingInstanceIds` class variable.
Implement `resolveMatchingAttributes(String attributesFilterJson)` to query `Workflow_Search_Attribute__c` and populate `matchingInstanceIds`.
Add `attributesFilterJson` parameter to `getFilteredInstances` and `getWorkflowStats`.
Update `buildWhereClause` to include `Id IN :matchingInstanceIds`.
Update `getInstanceDetails` to query and return attributes.

**Step 4: Run tests to verify they pass**
Run: `sf apex run test --class WorkflowDashboardControllerTest --synchronous`
Expected: PASS.

**Step 5: Commit**
`git commit -am "feat: support attribute querying and filtering in WorkflowDashboardController"`

---

### Task 5: Implement LWC Filter UI and Detail View

**Files:**
- Modify: `force-app/main/default/lwc/workflowDashboard/workflowDashboard.html`
- Modify: `force-app/main/default/lwc/workflowDashboard/workflowDashboard.js`
- Modify: `force-app/main/default/lwc/workflowDashboard/__tests__/workflowDashboard.test.js`

**Step 1: Update LWC JS Controller and HTML Template**
Add attributes filter inputs (Key & Value with a plus button) and active pills in `workflowDashboard.html`.
Add logic to handle adding/removing attribute filters, formatting them, and passing them to `getFilteredInstances` and `getWorkflowStats`.
Display selected instance's business attributes in the detail panel.

**Step 2: Run LWC Jest tests to verify failures/passes**
Run Jest unit tests to verify existing dashboard tests pass and add new ones for the attributes filtering and display logic.
Run: `npm run test:unit`

---

### Task 6: Add to Existing Example Workflow

**Files:**
- Modify: `examples/main/default/classes/AiSupportTriageWorkflowExampleTest.cls`

**Step 1: Write the failing test**
Modify `testBillingInquiryAutoResolves` in `AiSupportTriageWorkflowExampleTest.cls` to pass attributes map in `WorkflowEngine.start(...)` and query/assert the `Workflow_Search_Attribute__c` records.

**Step 2: Run tests to verify it fails**
Run: `sf apex run test --class AiSupportTriageWorkflowExampleTest --synchronous`
Expected: Fail (compile error because the engine doesn't have the Map overload yet, or doesn't support persisting attributes).

**Step 3: Run tests to verify it passes**
(Done after Task 2 implementation)
Run: `sf apex run test --class AiSupportTriageWorkflowExampleTest --synchronous`
Expected: PASS.

---

### Task 7: Verify Overall Dashboard Functionality

**Step 1: Verify overall dashboard functionality**
Deploy LWC code and run all Apex and LWC tests to ensure everything is green.

