# ADR 0001: Durable Patch and Upgrade Markers

## Status
Accepted

## Context
As the business logic of `WorkflowDefinition` DAGs evolves, deployed classes are updated with new step logic, routing, or database operations. However, long-running workflow instances (which can span weeks or months) may already be in-flight when a patch or class update is deployed. 

If these in-flight instances dynamically execute the new logic, it can result in:
1. **Replay Inconsistency**: If an instance has already completed a step and is rolled back or retried, executing a new code branch during replay violates the determinism requirement.
2. **State Mismatches**: Downstream steps might expect variables/records that were only created in the new branch, causing runtime exceptions.

We need a durable, safe upgrade system for long-running workflows that allows:
* Brand-new instances to immediately route down the new path (`true`).
* In-flight legacy instances to stay on the old path (`false`).
* Safety gates to verify when all legacy instances have completed, allowing safe deprecation/removal of legacy code branches.

## Decision
We implement a durable patch-marker API via the `StepContext` (`ctx`) and `WorkflowEngine` comprising the following components:

### 1. The API Surface
* `ctx.patched(String changeId, DateTime introducedAt)`: Returns `true` if the instance should use the new patched logic; `false` if it should remain on the legacy branch. The decision is durably saved in `Captured_Values__c` on the current step execution the first time it is reached.
* `ctx.deprecated(String changeId, DateTime retiredAt)`: A safety gate that throws a runtime exception if a legacy instance reaches a retired path.
* `WorkflowEngine.getPatchAdoptionCount(String changeId, DateTime introducedAt)`: Counts the number of active, in-flight instances created before `introducedAt` that have not yet reached the patch marker (i.e. those that will evaluate to `false` when they eventually reach it). Used to verify when a patch can be safely retired.

### 2. Replay & In-Flight Safety
* **Self-Seeding Decedents**: When a decision is first recorded for `changeId` in a workflow instance, it is written as `__patch:<changeId> : <boolean>`. Subsequent steps in the same instance load all historical captures and reuse this decision, ensuring the instance remains consistent across its entire execution path.
* **Predecessor Step Rule**: If a workflow first reaches `ctx.patched('changeId')` in a later step but predecessor steps have already completed, the instance is flagged as in-flight before the patch and defaults to `false`.

### 3. Salesforce Platform Optimizations (Governor Limits)
To protect against Salesforce governor limits (50,000 query rows, 6 MB heap size) in orgs with millions of historical execution records:
* **Loop Bounding via MIN/MAX Aggregates**: In `loadExecutions()`, we avoid unbounded history queries by executing a single `GROUP BY Step_Name__c` query to retrieve the `MIN(Id)` and `MAX(Id)` for every step name. Since patch decisions are durable and recorded on the first visit to a step (visit 0), this is guaranteed to load all decisions using a tiny, bounded query row footprint (at most 2 rows per unique step name).
* **Current Step visit Bounding**: The current step's execution records are queried separately with a bound of `stepVisit + 2` to verify retry visit completions without fetching millions of looping step records.
* **Synchronous Heap Chunking**: Resolving offloaded payload fields is performed in bounded batches of 40 records, allowing the garbage collector to reclaim heap space between chunks and preventing synchronous heap overflow.
* **Adoption Count Optimization**: When calculating adoption counts, we query active instances up to a limit of 45,000. In-loop JSON deserialization is only performed on records whose `Captured_Values__c` contains the exact patch string (`"__patch:<changeId>":false`), conserving CPU and memory.

## Consequences
* **Durable Safety**: Developers can safely patch live, multi-week workflows without worrying about breaking active executions.
* **Deprecation Visibility**: Operations teams can programmatically query when legacy code is safe to delete.
* **Resource Predictability**: Patch lookups remain $O(1)$ in database queries regardless of loop iterations or execution history length.
