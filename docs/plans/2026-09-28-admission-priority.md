# Admission priority for the concurrency ceiling (issue #132)

## Goal

Under a full ceiling, admit critical instances before the parked backlog.
Keep FIFO in one priority class. Prevent starvation with a bound.

## Facts about the engine

- `WorkflowStepAdmission.admitConfiguredInstance` locks the instance, then
  `ConcurrencyGate.tryAcquire` locks the `Concurrency_State__c` row. The
  decision is "count < ceiling". It does not look at other instances.
- An instance that waits for a slot has `Concurrency_Parked__c = true` and
  `Concurrency_Slot_Held__c = false`. A bounded start sets this marker at
  insert. A park sets it again with a 30–45 s retry timer.
- Each parked instance retries on its own timer. The watchdog sleep sweep is
  the backstop. The winner of a free slot is the first timer that fires.
- All instance inserts go through `WorkflowInstanceTrigger` (before insert).
- `Concurrency_Config__mdt.getAll()` costs 0 SOQL.
- No Apex test run is possible in this container (no org). Jest runs.

## Brainstorming (options)

| #   | Idea                                                                                 | Keep?                                                                    |
| --- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| B1  | Order by `Priority DESC, CreatedDate ASC` at the gate.                               | Partly. It has no aging. Low work can starve.                            |
| B2  | Stored rank key: `startMs − priority × agingMinutes × 60000`. Order by key, then Id. | Yes. One static key. Priority and aging in one sort. FIFO in a class.    |
| B3  | Reserved share: each Nth admission takes the oldest instance.                        | No. Needs a new counter field and a second sort mode.                    |
| B4  | Formula field for the key.                                                           | No. A formula cannot read the aging value from CMDT by definition.       |
| B5  | Gate check: admit only if fewer than `free` waiting instances rank ahead.            | Yes. One bounded query (`LIMIT free`) under the counter lock.            |
| B6  | Grant the slot to the head row from the visitor's transaction.                       | No. Locks other instance rows. Deadlock risk with the counter lock.      |
| B7  | Visitor yields, re-parks, and wakes the head rows (`enqueueResume`).                 | Yes. No cross-row lock. Uses the existing resume path.                   |
| B8  | Wake the head on slot release in the trigger.                                        | No. Async work in a trigger. Bulk terminal updates hit limits.           |
| B9  | New scheduled job that admits by priority.                                           | No. The issue forbids a new slot.                                        |
| B10 | Stamp priority and key in the before-insert trigger.                                 | Yes. One chokepoint for all start paths (scalar, bulk, child, continue). |
| B11 | Backfill the key at the gate for rows from before this change.                       | Yes. Null key sorts first and heals on the first gate visit.             |
| B12 | Priority range 0–9 (like Oban), clamp other values.                                  | Yes. The clamp gives a finite starvation bound. A start never fails.     |
| B13 | Show the wait queue (priority, position) on the System Doctor concurrency panel.     | Yes. The operator sees why an instance waits.                            |

## Reverse brainstorming (how to make it fail)

| How to fail                                                     | Counter                                                                    |
| --------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Low work never runs under a high flood.                         | Aging in the key. Bound: `(9 − p) × agingMinutes`.                         |
| A dead head row blocks the definition forever.                  | Each yield wakes the head rows. The head then admits or fails.             |
| Scan the full backlog on each admission.                        | Query only when a slot is free. `LIMIT free`.                              |
| Deadlock between two admissions.                                | Lock order stays: own row, then counter. No lock on other rows.            |
| Trigger fills the ceiling cache before a test sets mock config. | Priority reads the config with no cache.                                   |
| Old parked rows have no key and get lost.                       | Null key sorts first. The gate writes the key on the first visit.          |
| A huge override starves all other work.                         | Clamp to 0–9.                                                              |
| Priority changes step rows or the compensation stack.           | Code changes only the gate and the insert stamp. Test proves it.           |
| Yield adds scheduled jobs.                                      | A yield is a normal park (one retry timer). Wake uses queue/event path.    |
| Change breaks existing callers.                                 | New `StartRequest.priority` field and `withPriority()`. Old code compiles. |

## Six thinking hats

- **White (facts):** The gate already holds the counter lock. One extra SOQL
  runs only when a slot is free. Parked rows retry each 30–45 s.
- **Red (feel):** Operators want P1 work first, but they do not trust a
  queue that can hide work forever. Show the queue and the bound.
- **Black (risk):** Strict FIFO is a small change for orgs with one class: a
  fresh start with a free slot now yields to an older waiter. The older waiter
  gets the slot one hop later. A dead head row can stall the queue; the wake on
  each yield removes this risk.
- **Yellow (value):** One static key gives priority, FIFO and aging. No new
  job, no new event, no change to the step trail.
- **Green (ideas):** Aging per definition (`Priority_Aging_Minutes__c`).
  Flow input for priority. Queue view on the dashboard.
- **Blue (process):** RED tests first (unit + integration + Jest). Then
  GREEN code. Then REFACTOR, review, and the AC evidence table.

## Decision

1. `Concurrency_Config__mdt`: `Admission_Priority__c` (0–9, default 0) and
   `Priority_Aging_Minutes__c` (default 60). Same name and `Default` rules.
2. `Workflow_Instance__c`: `Admission_Priority__c` and `Admission_Key__c`.
   The before-insert trigger sets the clamped priority. It sets the key if
   the key is blank.
3. `WorkflowEngine.StartRequest.priority` + `withPriority(Integer)`. Flow
   action gets an optional `Priority` input. Continue-As-New keeps priority.
4. Gate: with a free slot, count waiting rows that rank ahead (`LIMIT free`).
   Admit if the count is less than `free`. Else park. Wake the ahead rows
   (max 5) in both cases.
5. Dashboard: each concurrency row lists the next waiting instances with
   priority, and a count per priority class.

## Tasks

1. RED: `ConcurrencyAdmissionOrderTest`, `WorkflowAdmissionPriorityTest`,
   dashboard Apex test, Jest test.
2. GREEN: fields, permission sets, resolver, stamp, gate, start API, Flow,
   dashboard.
3. REFACTOR: format, docs (`concurrency-limits.md`, ADR 0006, README).
4. Review with agents. Fix findings. AC evidence table.

## Review changes

Four review agents (compile, concurrency, integration, docs) and Codex found
these problems. The fixes replace parts of the decision above.

| Problem                                                               | Fix                                                                       |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| Start paths write the raw override back after insert (null priority). | The builder writes the resolved priority.                                 |
| Key backfill at the gate stops a legacy backlog.                      | No backfill. Blank keys rank first, in Id order.                          |
| A plain `RUN_STEP` wake can re-run the step of an admitted instance.  | Admit-only `ConcurrencyAdmissionWake`. Abort the old timer on admit/park. |
| The ahead query scans the full table under the counter lock.          | Indexed `Admission_Queue__c`, set by the trigger only while waiting.      |
| Many free slots fill slowly (5 wakes).                                | Wake up to the free slots, max 10, in one Queueable.                      |
| Wakes fall back to Platform Events and lock the watchdog row.         | No fallback. No wake when the Queueable budget is spent.                  |
| One deep queue hides other queues on the dashboard (Codex).           | One query per governed workflow, `LIMIT 5`.                               |
| Flow Signal-or-Start has no priority input.                           | Add the `Priority` input.                                                 |
| A huge aging value overflows.                                         | Clamp aging to 1–525600.                                                  |
| Admin can edit engine fields.                                         | Read-only in both permission sets.                                        |
