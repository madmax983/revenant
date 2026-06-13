# Saga Pattern (Compensations) Design

This document details the architectural design for introducing the Saga Pattern (distributed compensations) into the Revenant durable workflow engine.

## Overview
When a long-running business process encounters a failure mid-way, it must clean up any side effects produced by previously completed steps. Since standard database transactions cannot span long timeframes or external system callouts, the Saga Pattern is used to roll back successful steps in reverse order (LIFO).

---

## 1. Data Model & Schema Updates

To support the Saga flow, the custom objects metadata will be updated with new picklist values and a field to track the compensation history:

1. **Picklist Values for `Status__c` on `Workflow_Instance__c`**:
   * `Compensating`: The workflow encountered a terminal error and is currently executing rollback steps in reverse order.
   * `Compensated`: A terminal state indicating all successfully executed compensatable steps have been rolled back.

2. **Picklist Values for `Status__c` on `Workflow_Step_Execution__c`**:
   * `Compensating`: The step is currently running its rollback compensation logic.
   * `Compensated`: The step's rollback compensation successfully completed.

3. **New Field `Compensation_Stack__c` on `Workflow_Instance__c`**:
   * **Type**: Long Text Area (131,072 characters).
   * **Purpose**: Stores a JSON-serialized list of strings representing the class names of successfully executed compensatable steps (e.g., `["OnboardingWorkflowExample.CreateBillingAccountStep", "OnboardingWorkflowExample.ProvisionSandboxStep"]`).

---

## 2. The `CompensatableStep` Interface & Engine Execution Flow

Forward steps that perform mutable operations must declare how to reverse their changes by implementing the new `CompensatableStep` interface:

```java
public interface CompensatableStep extends WorkflowStep {
    StepResult compensate(StepContext ctx);
}
```

### Forward Flow Stack Registration
When a step executes and returns `COMPLETE`:
1. The engine checks if the instantiated step class implements `CompensatableStep`.
2. If it does, the engine queries `Compensation_Stack__c` from the current `Workflow_Instance__c` record.
3. The engine deserializes the stack list, appends the current step's class name, serializes it, and saves it back to the database in the same transaction.

### Triggering Compensation
If a forward step fails permanently (e.g., maximum retry attempts exhausted, step timeout, or an unhandled crash caught by `WorkflowFinalizer`):
1. The engine queries `Compensation_Stack__c`.
2. If the stack is empty, the workflow transitions directly to `Failed`.
3. If the stack contains elements, the engine marks the workflow instance's status as `Compensating` and enqueues the `WorkflowOrchestrator` to begin rolling back the stack.

---

## 3. The Orchestrator Compensation Loop & Error Handling

### Rollback Execution Loop
When the `WorkflowOrchestrator` executes for an instance in `Compensating` status:
1. It reads the `Compensation_Stack__c` field.
2. If the stack list is empty, it transitions the instance to `Compensated` and terminates.
3. If the stack has elements, it pops the top step name from the stack.
4. It instantiates the step class and queries its original `Workflow_Step_Execution__c` record to reconstruct the `StepContext` (passing the original step input and output).
5. It creates a new `Workflow_Step_Execution__c` record with step name `ClassName_Compensate` and status `Compensating`.
6. It runs `step.compensate(ctx)`.

```mermaid
graph TD
    Start([Start Workflow]) --> Step1[Step1 Forward]
    Step1 -- Success: Push to Stack -- Step2[Step2 Forward]
    Step2 -- Success: Push to Stack -- Step3[Step3 Forward]
    Step3 -- Permanent Failure -- TransitionComp[Transition to Compensating]
    
    TransitionComp --> PopStack{Pop Stack}
    PopStack -- Step2 -- Step2Comp[Step2.compensate]
    Step2Comp -- Success -- PopStack
    PopStack -- Step1 -- Step1Comp[Step1.compensate]
    Step1Comp -- Success -- PopStack
    PopStack -- Empty -- CompleteComp([Transition to Compensated])
    
    Step2Comp -- Permanent Failure -- FailComp([Transition to Failed: Halt & Wait for Admin Retry])
```

### Compensation Outcomes & Retries
During the compensation phase, the engine supports the same standard outcomes:
* **`COMPLETE`**: Marks the compensation log `Compensated`, updates the `Compensation_Stack__c` to remove the popped step, and enqueues the orchestrator to process the next step.
* **`RETRY` / `SLEEP` / `SUSPEND` / `APPROVAL`**: The compensation step itself can retry on rate limits, sleep for a delay, yield, or wait for manual admin approval.

### Compensation Failures
If a compensation step fails permanently (e.g., retries exhausted or database lock collision):
1. The engine halts the rollback loop and transitions both the compensation log and the workflow instance to `Failed`.
2. The current progress remains in the `Compensation_Stack__c`.
3. An administrator can review the error on the LWC Dashboard, fix the underlying issue (e.g., correct a permission error or update external system state), and click the **"Retry / Replay"** button to resume the compensation loop from the point of failure.
