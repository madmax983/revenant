# Saga Pattern (Compensations) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the Saga Pattern (compensations) within the Revenant durable workflow engine to rollback successful steps in LIFO order upon workflow failure.

**Architecture:** We will introduce a `CompensatableStep` interface for steps with rollback logic. The engine will record completed compensatable steps on a serialized `Compensation_Stack__c` field, and upon failure, pop and execute the rollbacks.

**Tech Stack:** Apex, Salesforce Custom Metadata, Queueables, Platform Events.

---

### Task 1: Status Picklist Metadata
**Files:**
- Modify: `force-app/main/default/objects/Workflow_Instance__c/fields/Status__c.field-meta.xml`
- Modify: `force-app/main/default/objects/Workflow_Step_Execution__c/fields/Status__c.field-meta.xml`

**Step 1: Add values to Workflow_Instance__c.Status__c**
Add `Compensating` and `Compensated` values to the picklist valueSet.

**Step 2: Add values to Workflow_Step_Execution__c.Status__c**
Add `Compensating` and `Compensated` values to the picklist valueSet.

**Step 3: Commit**
```bash
git add force-app/main/default/objects/Workflow_Instance__c/fields/Status__c.field-meta.xml force-app/main/default/objects/Workflow_Step_Execution__c/fields/Status__c.field-meta.xml
git commit -m "feat: add Compensating and Compensated picklist values"
```

---

### Task 2: Create Compensation_Stack__c Field
**Files:**
- Create: `force-app/main/default/objects/Workflow_Instance__c/fields/Compensation_Stack__c.field-meta.xml`

**Step 1: Create field metadata**
Create a Long Text Area field with length 131072.

**Step 2: Commit**
```bash
git add force-app/main/default/objects/Workflow_Instance__c/fields/Compensation_Stack__c.field-meta.xml
git commit -m "feat: create Compensation_Stack__c field metadata"
```

---

### Task 3: Define CompensatableStep Interface
**Files:**
- Create: `force-app/main/default/classes/CompensatableStep.cls`
- Create: `force-app/main/default/classes/CompensatableStep.cls-meta.xml`

**Step 1: Write interface**
Define the `CompensatableStep` interface with the `compensate` method.

**Step 2: Commit**
```bash
git add force-app/main/default/classes/CompensatableStep.cls force-app/main/default/classes/CompensatableStep.cls-meta.xml
git commit -m "feat: define CompensatableStep interface"
```

---

### Task 4: Modify WorkflowEngine to Track and Trigger Rollback
**Files:**
- Modify: `force-app/main/default/classes/WorkflowEngine.cls`

**Step 1: Push compensatable steps to stack**
In `completeStep`, check if the step implements `CompensatableStep` and append its class name to the `Compensation_Stack__c` field.

**Step 2: Enter Compensating state on failures**
In `failWorkflow`, if the stack is not empty, set status to `Compensating` and enqueue orchestrator.

**Step 3: Commit**
```bash
git add force-app/main/default/classes/WorkflowEngine.cls
git commit -m "feat: integrate Saga stack building and failure triggers in WorkflowEngine"
```

---

### Task 5: Modify WorkflowOrchestrator to Run Rollback Loop
**Files:**
- Modify: `force-app/main/default/classes/WorkflowOrchestrator.cls`

**Step 1: Implement rollback execution**
In the queueable `execute` method, if the status is `Compensating`, pop the last class name, re-instantiate it, rebuild its context, log a new `ClassName_Compensate` step execution, and call `compensate`.

**Step 2: Handle compensation outcomes**
Handle complete, retry, sleep, and failure outcomes.

**Step 3: Commit**
```bash
git add force-app/main/default/classes/WorkflowOrchestrator.cls
git commit -m "feat: implement compensation loop in WorkflowOrchestrator"
```

---

### Task 6: Add Example Workflow and Tests
**Files:**
- Create: `examples/main/default/classes/SagaWorkflowExample.cls`
- Create: `examples/main/default/classes/SagaWorkflowExample.cls-meta.xml`
- Create: `examples/main/default/classes/SagaWorkflowExampleTest.cls`
- Create: `examples/main/default/classes/SagaWorkflowExampleTest.cls-meta.xml`

**Step 1: Create SagaWorkflowExample**
Implement dynamic steps simulating side-effects and rolling them back.

**Step 2: Create SagaWorkflowExampleTest**
Assert automatic rollback, compensation retries, and compensation manual approvals.

**Step 3: Run all tests**
Run Apex tests and ensure 100% pass rate.

**Step 4: Commit**
```bash
git add examples/main/default/classes/SagaWorkflowExample*
git commit -m "feat: add SagaWorkflowExample and tests"
```
