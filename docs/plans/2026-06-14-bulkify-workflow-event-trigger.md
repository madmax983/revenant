# Bulkify WorkflowEventTrigger Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Bulkify WorkflowEventTrigger.trigger to eliminate SOQL queries inside the event loop and publish throttled queueable events in bulk.

**Architecture:** Collect all valid Salesforce IDs from incoming Workflow_Event__e platform events and perform a single bulk query to retrieve their correlation keys. For any events that need to be throttled due to Queueable job limits or exceptions, collect them into a list and publish them in a single bulk EventBus.publish call at the end of the trigger.

**Tech Stack:** Apex, Salesforce Platform Events, Salesforce Queueables

---

### Task 1: Bulkify WorkflowEventTrigger

**Files:**
- Modify: [WorkflowEventTrigger.trigger](file:///c:/Users/markm/revenant/force-app/main/default/triggers/WorkflowEventTrigger.trigger)
- Test: [WorkflowEngineTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/WorkflowEngineTest.cls)

**Step 1: Write/Verify tests**
Verify the baseline tests pass.
Run: `sf apex run test -n WorkflowEngineTest -r human -o durable-wflow-org --synchronous`

**Step 2: Modify WorkflowEventTrigger.trigger**
Implement the bulkified logic resolving instance IDs first and bulk-publishing throttled events.

**Step 3: Run tests to verify**
Run: `sf apex run test -n WorkflowEngineTest -r human -o durable-wflow-org --synchronous`
Expected: PASS

**Step 4: Commit**
```bash
git add force-app/main/default/triggers/WorkflowEventTrigger.trigger
git commit -m "perf: bulkify WorkflowEventTrigger"
```
