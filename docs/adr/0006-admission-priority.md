# ADR 0006: Admission priority for the concurrency ceiling

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #132

## Context

Under a full ceiling, parked instances retry on their own timers. The first timer that fires after a slot frees gets the slot. Thus a critical instance waits behind the full backlog of low-value work. The engine has no priority.

## Decision

1. Priority is an integer from 0 to 9. Higher is admitted sooner. Values out of range are clamped.
2. Config: `Concurrency_Config__mdt.Admission_Priority__c` (blank = 0) and `Priority_Aging_Minutes__c` (blank or < 1 = 60). Same name and `Default` rules as the ceiling.
3. API: `WorkflowEngine.StartRequest.priority` and `withPriority(Integer)`. Flow action input `Priority`. Continue-As-New keeps the priority.
4. The before-insert trigger writes `Workflow_Instance__c.Admission_Priority__c` and `Admission_Key__c`. Key = start ms − priority × aging minutes × 60000. All start paths use the trigger.
5. The gate reads the key order only when a slot is free: one query, `LIMIT` free slots, under the counter lock. The visitor takes a slot only if fewer rows rank ahead than slots are free. Else it parks (yields).
6. The gate wakes the rows ahead (max 5) through `WorkflowResumeEnqueue.enqueueResume`.
7. A row with a blank key ranks first. The gate writes its key on the first visit.
8. The System Doctor concurrency panel shows the count per priority class and the next five waiting instances with position and priority.

## Consequences

- Starvation bound: an instance at priority `p` is never passed by work that starts more than `(q − p) × aging` after it. Worst case `(9 − p) × aging`.
- With one priority class, admission is FIFO by start time. Before, the first timer won. This is the only change for existing orgs.
- One more SOQL on a gate visit that finds a free slot. None when the ceiling is full.
- A yield is a normal park. No new scheduled job, no new Platform Event.
- Step rows, the compensation stack and the Queueable chain do not change.
- Two new fields on `Workflow_Instance__c` and two on `Concurrency_Config__mdt`.
- Priority applies inside one definition only.

## Rejected Options

- Order by `Priority DESC, CreatedDate ASC`: no aging, low work can starve.
- Reserved admission share (each Nth slot to the oldest): a new counter field and a second sort mode.
- Formula key: a formula cannot read the aging value per definition.
- Grant the slot to the head row from the visitor's transaction: locks other instance rows while it holds the counter lock. Deadlock risk.
- Wake the head in the release trigger: async work in a trigger. Bulk terminal updates hit limits.
- A new scheduled job for priority admission: the issue forbids a new slot.
