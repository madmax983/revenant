# Evolve Live Workflow Code with Patches

Implement named, durably-recorded change markers (`patched`) to support safe evolution of live workflow definitions while instances are in-flight.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

## User Review Required

> [!IMPORTANT]
> The public API changes add `patched` and `deprecated` to `StepContext`.
> We will store patch decisions in `Captured_Values__c` on `Workflow_Step_Execution__c` using a prefix `__patch:`. This avoids changing the database schema or altering the Queueable chain handoff.

## Open Questions

None. The requirements from the issue are clear and self-contained.

## Proposed Changes

We will implement this in a Red-Green-Refactor TDD manner.

### Core API

#### [MODIFY] [StepContext.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepContext.cls)
- Add `private Map<String, Boolean> patchDecisionsCache = new Map<String, Boolean>();`
- Add `private Boolean hasLoadedPatchDecisions = false;`
- Add `private void loadPatchDecisions()` to query and parse all `__patch:` keys from `Captured_Values__c` of all step executions of this instance.
- Add `private Boolean hasCurrentStepCompletedInPast()` to check if this step name has already been completed in this instance.
- Implement `public Boolean patched(String changeId)`:
  - Check in `capturedValues` first.
  - If not found, call `loadPatchDecisions()` and check `patchDecisionsCache`. If found, store it in `capturedValues` (and `newCaptureKeys`) and return.
  - If still not found, determine the decision: `true` if `hasCurrentStepCompletedInPast()` is `false`, else `false`.
  - Store the decision in `capturedValues` (and `newCaptureKeys`) and return.
- Implement `public void deprecated(String changeId)`:
  - If `!patched(changeId)`, throw `new WorkflowEngine.WorkflowException('Workflow execution reached retired code path for patch: ' + changeId)`.

#### [MODIFY] [WorkflowEngine.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/WorkflowEngine.cls)
- Implement `public static Integer getPatchAdoptionCount(String changeId)`:
  - Query all `Workflow_Step_Execution__c` records for non-terminal instances where `Captured_Values__c` contains `__patch:<changeId>`.
  - Parse the JSON and count unique `Workflow_Instance__c` IDs where the decision value is `false`.

---

### Tests

#### [MODIFY] [StepContextTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepContextTest.cls)
- Add unit tests for `patched` and `deprecated` behavior:
  - Brand new instance (first run of step) returns `true` and saves it.
  - Subsequent retry/resume of that step returns the identical recorded value.
  - An instance that already completed the step in the past (re-driven/retry of completed) returns `false` and saves it.
  - `deprecated` passes if patched is true, and throws `WorkflowException` if patched is false.

#### [NEW] [PatchExampleWorkflow.cls](file:///c:/Users/markm/revenant/examples/main/default/classes/PatchExampleWorkflow.cls)
- Write a saga workflow that inserts a new step using `patched('insert-step-new')` and handles routing via `StepResult`.

#### [NEW] [PatchExampleWorkflowTest.cls](file:///c:/Users/markm/revenant/examples/main/default/classes/PatchExampleWorkflowTest.cls)
- Integration tests using `WorkflowTestHarness` to verify:
  - A brand-new instance takes the new step and completes successfully.
  - An in-flight instance that already completed the first step before the patch was introduced continues to run the old path and completes successfully.
  - Re-driving/retrying behaves correctly.
  - Querying `getPatchAdoptionCount` returns 0 for brand new instances, 1 for the old in-flight instance, and 0 after the old instance completes.

## Verification Plan

### Automated Tests
- Run Apex tests:
  ```powershell
  sf apex run test -n StepContextTest -w 5
  sf apex run test -n PatchExampleWorkflowTest -w 5
  ```
