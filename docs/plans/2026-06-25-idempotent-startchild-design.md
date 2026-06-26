# Idempotent startChild() Launch Design

**Goal:** Make `StepResult.startChild()` idempotent across re-entrant launcher re-executions so that duplicate child launches return an idempotent re-suspend rather than throwing a duplicate key exception and failing the parent, while preserving loud failure for genuine foreign collisions.

**Architecture:** Update `WorkflowEngine.startChildWorkflow` to query for active workflows matching the correlation key. If one exists, check if its `Parent_Instance__c` matches the current `parentId`. If yes, return early (idempotent re-suspend) without spawning a child; otherwise, throw `WorkflowException`. Remove the hand-rolled SOQL from `ChildWorkflowCompositionExample.cls` and `README.md`.

**Tech Stack:** Salesforce Apex

---

## Proposed Changes

### Core Engine

#### [WorkflowEngine.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/WorkflowEngine.cls)
- Modify `startChildWorkflow` to query the parent instance of an existing active child workflow by filtering on `Active_Correlation_Key__c = :correlationKey` instead of using a hardcoded `Status__c` array. This aligns perfectly with the trigger's unique-key constraint and automatically supports all active statuses (including `'Paused'`, `'Compensating'`, and `'Cancelling'`).
- In the `DUPLICATE_VALUE` catch block, query for the winning sibling. If it belongs to the same parent, return early and resolve idempotently instead of crashing the parent transaction.

### Reference/Example Code

#### [ChildWorkflowCompositionExample.cls](file:///c:/Users/markm/revenant/examples/main/default/classes/ChildWorkflowCompositionExample.cls)
- Remove the SOQL query on `Workflow_Instance__c` in `RequestCreditCheckStep.execute`.
- Directly return `StepResult.startChild(...)` if no outcome is present.
- Update comments to reflect engine-level idempotency.

### Tests

#### [WorkflowEngineTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/WorkflowEngineTest.cls)
- Add a new test method `testParentChildWorkflowReentrancy` that executes a re-entrant launcher step (using `WorkflowEngineTest.ParentWorkflow` which has no SOQL guard) and verifies that exactly one child is launched and no exception is thrown.
- Add a test method `testParentChildWorkflowForeignCollision` to verify that a duplicate-active-key collision for a different parent still fails loudly.
- Add a test method `testParentChildWorkflowReentrancyWithPausedChild` to verify that re-entry while a child is paused cleanly resolves to an idempotent re-suspend.

### Documentation

#### [README.md](file:///c:/Users/markm/revenant/README.md)
- Update the **Idempotent launch** row in the parent→child orchestration contract table to indicate that the engine handles child deduplication idempotently.
- Update the minimal launcher snippet to remove the SOQL query on `Workflow_Instance__c`.
