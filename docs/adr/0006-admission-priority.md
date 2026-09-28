# ADR 0006: Admission priority for the concurrency ceiling

- **Status:** Accepted
- **Date:** 2026-09-28
- **Issue:** #132

## Context

Under a full ceiling, parked instances retry on their own timers. The first timer that fires after a slot becomes free gets the slot. As a result, a critical instance waits for all the low-priority work before it. The engine has no priority.

## Decision

1. Priority is an integer from 0 to 9. The gate admits a higher value sooner. The engine changes a value below 0 to 0, and a value above 9 to 9.
2. Config: `Concurrency_Config__mdt.Admission_Priority__c` (blank = 0) and `Priority_Aging_Minutes__c` (blank or < 1 = 60, max 525600). The name and `Default` rules of the ceiling also apply.
3. API: `WorkflowEngine.StartRequest.priority` and `withPriority(Integer)`. Flow input `Priority` on **Start Workflow** and **Signal or Start Workflow**. Continue-As-New keeps the priority.
4. The start builder writes the resolved priority. The before-insert trigger sets the clamped priority and, if blank, `Admission_Key__c` = start ms − priority × aging minutes × 60000.
5. On each save, the trigger sets the indexed `Admission_Queue__c` to the workflow name while the instance waits. Else it clears the field. The gate reads the queue through this field.
6. The gate reads the order only when a slot is free: one query, up to the number of free slots, under the counter lock. The candidate gets a slot only if fewer instances rank ahead than slots are free. If not, the candidate parks again (it yields).
7. The gate wakes the instances ahead (max 10) with one admit-only Queueable, `ConcurrencyAdmissionWake`, before the re-drive of the candidate. The job locks its rows in Id order, runs the gates of a normal delivery up to admission, and never runs a step. The gate does not wake when the Queueable budget is spent. An instance that enters `Compensating` or `Cancelling` loses the awaiting-admission marker.
8. An admit or a park aborts the old retry timer of the candidate.
9. A row from before this feature has no key. It ranks first, in Id order among such rows. The gate does not write a key. The watchdog heartbeat puts waiting rows from before this feature into `Admission_Queue__c` (200 per sweep). A script does the same at once after deploy.
10. The System Doctor concurrency panel shows the count per priority class and the next five waiting instances, with position and priority. It uses one query per governed workflow.

## Consequences

- Starvation bound: work that starts more than `(q − p) × aging` after an instance at priority `p` cannot go before it. The worst case is `(9 − p) × aging`. This limits which work goes first. It is not a clock limit.
- With one priority class, admission is FIFO by start time. Before, the first timer got the slot. The slot now stays free for one more hop, until the head arrives.
- One more SOQL on a gate visit that finds a free slot. None when the ceiling is full.
- A yield is a normal park with one retry timer. No new scheduled job class and no new Platform Event.
- Step rows, the compensation stack and the Queueable chain do not change.
- Three new fields on `Workflow_Instance__c` and two on `Concurrency_Config__mdt`.
- Priority applies in one definition only. Any caller that can start a workflow can set an override.
- A Continue-As-New successor gets a new key. It goes to the end of its priority class.

## Rejected Options

- Order by `Priority DESC, CreatedDate ASC`: no aging. Low-priority work can wait forever.
- Reserved admission share (each Nth slot to the oldest): a new counter field and a second sort mode.
- Formula key: a formula cannot read the aging value of each definition.
- Grant the slot to the head from the candidate's transaction: locks other instance rows while it holds the counter lock. Deadlock risk.
- Wake with a plain `RUN_STEP`: a late wake can re-run the step of an admitted instance.
- Write a key on legacy rows at the gate: the written row ranks behind the other blank rows. A legacy backlog then stops the queue.
- Keep the old key on Continue-As-New: a perpetual workflow would always be the head, and other work would wait forever.
- Wake the head in the release trigger: async work in a trigger. Bulk terminal updates hit limits.
- A new scheduled job for priority admission: the issue forbids a new scheduled job.
