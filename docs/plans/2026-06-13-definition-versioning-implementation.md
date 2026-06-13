# Definition Versioning (Hot Upgrades) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement programmatic Definition Versioning within the Revenant durable workflow engine to run and route step executions based on the version captured at instance startup.

**Architecture:** We will introduce a `VersionedWorkflow` interface. At startup, the engine records `Definition_Version__c` on the instance. When routing or running steps, the engine injects this version into the `StepContext` and uses it to select the next step.

**Tech Stack:** Apex, Custom Metadata.

---

### Task 1: Create Definition_Version__c Field
**Files:**
- Create: `force-app/main/default/objects/Workflow_Instance__c/fields/Definition_Version__c.field-meta.xml`

**Step 1: Create field metadata**
Create `Definition_Version__c` field as a Number(18, 0) with a default value of 1.

**Step 2: Commit**
```bash
git add force-app/main/default/objects/Workflow_Instance__c/fields/Definition_Version__c.field-meta.xml
git commit -m "feat: create Definition_Version__c field metadata"
```

---

### Task 2: Define VersionedWorkflow Interface
**Files:**
- Create: `force-app/main/default/classes/VersionedWorkflow.cls`
- Create: `force-app/main/default/classes/VersionedWorkflow.cls-meta.xml`

**Step 1: Write interface**
Define the `VersionedWorkflow` interface with methods `getLatestVersion()` and `getNextStep` (3-argument version).

**Step 2: Commit**
```bash
git add force-app/main/default/classes/VersionedWorkflow.cls force-app/main/default/classes/VersionedWorkflow.cls-meta.xml
git commit -m "feat: define VersionedWorkflow interface"
```

---

### Task 3: Modify StepContext to Hold Version
**Files:**
- Modify: `force-app/main/default/classes/StepContext.cls`

**Step 1: Add version property**
Add `public Integer workflowVersion;` and update all constructors to assign it.

**Step 2: Commit**
```bash
git add force-app/main/default/classes/StepContext.cls
git commit -m "feat: add workflowVersion property to StepContext"
```

---

### Task 4: Modify WorkflowEngine to Handle Versioning
**Files:**
- Modify: `force-app/main/default/classes/WorkflowEngine.cls`

**Step 1: Capture version on startup**
In both `start` overloads, check if the definition is a `VersionedWorkflow`. If so, save `getLatestVersion()`, else default to 1. Do the same in `startChildWorkflow`.

**Step 2: Inject version into StepContext**
In `runStep` (and `runCompensationStep`), query `Definition_Version__c` and pass it when constructing `StepContext`.

**Step 3: Route based on version**
In `handleStepResult` (both complete step and parallel join blocks), check if the definition implements `VersionedWorkflow` and call the 3-arg `getNextStep` if yes, else 2-arg.

**Step 4: Commit**
```bash
git add force-app/main/default/classes/WorkflowEngine.cls
git commit -m "feat: integrate version-aware startup and routing in WorkflowEngine"
```

---

### Task 5: Add Example Versioned Workflow and Test Suite
**Files:**
- Create: `examples/main/default/classes/VersionedWorkflowExample.cls`
- Create: `examples/main/default/classes/VersionedWorkflowExample.cls-meta.xml`
- Create: `examples/main/default/classes/VersionedWorkflowExampleTest.cls`
- Create: `examples/main/default/classes/VersionedWorkflowExampleTest.cls-meta.xml`

**Step 1: Create VersionedWorkflowExample**
Implement a versioned workflow that behaves differently under version 1 vs 2.

**Step 2: Create VersionedWorkflowExampleTest**
Write tests confirming version 1 and 2 executions are isolated and run correct logic/routing.

**Step 3: Verify all tests pass**
Run Apex tests and ensure 100% pass rate.

**Step 4: Commit**
```bash
git add examples/main/default/classes/VersionedWorkflowExample*
git commit -m "feat: add VersionedWorkflowExample and tests"
```
