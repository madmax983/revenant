# Concurrency Limits — capping in-flight instances per workflow

Revenant treats **concurrency** (a ceiling on simultaneously in-flight work) as a
primitive distinct from **rate/throttle** ([`RateLimiter`](rate-limiting.md), events per unit time) and from
**get-or-start dedup** (#10). A concurrency limit caps how many instances of a workflow
definition may be *running at once*, so a bursty start — a 10k-record trigger, a Cursor
fan-out — is throttled to a safe in-flight ceiling instead of stampeding fragile
downstream systems (legacy SOAP endpoints, partner APIs with connection caps) or
exhausting org-wide callout budget.

## Configuring a ceiling (no code)

Create a **Concurrency Config** (`Concurrency_Config__mdt`) Custom Metadata record. The
engine maps a workflow's class name to a record `DeveloperName` using the **same
convention as `Workflow_Alert_Config__mdt`** — every non-alphanumeric character becomes
`_`, truncated to 40 characters:

| Workflow class                                  | Record DeveloperName                          |
| ----------------------------------------------- | --------------------------------------------- |
| `OnboardingWorkflow`                            | `OnboardingWorkflow`                          |
| `CalloutTimeoutWorkflowExample.CalloutWorkflow` | `CalloutTimeoutWorkflowExample_CalloutWorkflow` |

Set **Max Concurrent Instances** (`Max_Concurrent_Instances__c`) to the ceiling `N`. A
record named **`Default`** applies to every workflow without a specific record. A workflow
with no matching record **and** no `Default` is **unbounded** — exactly the behavior before
this feature. Engine-internal workflows (the perpetual `WatchdogWorkflow`) are always
exempt, so a `Default` ceiling can never starve the engine itself.

## How it works

- **Durable slot counter.** Each governed definition has one `Concurrency_State__c` row
  holding `In_Flight_Count__c`, mutated under `SELECT ... FOR UPDATE` so concurrent
  admissions are serialized and the ceiling is never exceeded. Admission is a single
  guarded counter check, never an unbounded SOQL scan. (CMDT config reads do not count
  against SOQL governor limits.)
- **Acquire at admission.** The first time an instance is about to execute a step, the
  engine acquires a slot. Acquisition commits the counter increment in its own transaction
  and re-drives the step in a fresh one, so a step's `execute()` — including a `CalloutStep`,
  the primary use case — never runs while the counter DML is uncommitted.
- **Park when full.** If the ceiling is reached, the instance parks: it suspends with a
  short admission-retry wake time (`Concurrency_Parked__c = true`) and re-attempts
  admission through the **existing sleep/watchdog resume plumbing** — no busy spin, no
  dropped Queueable chain. Under a large burst the per-instance scheduling degrades
  gracefully to the watchdog batch-resume (the scalable path).
- **Release on every terminal transition.** `WorkflowInstanceTrigger` releases the slot on
  the first transition into `Completed`, `Failed`, `Cancelled`, `Compensated`, or
  `ContinuedAsNew`, so a parked instance is admitted promptly afterward. A recoverable
  `CompensationFailed` ("Rollback Incomplete") is non-terminal and keeps its slot.
- **Crash-safe reclamation.** If an instance dies without releasing its slot (crash, killed
  transaction), the watchdog heartbeat reconciles each counter to the true number of
  non-terminal slot-holding instances, reclaiming any leaked slot within one sweep.

Slot accounting lives entirely outside the append-only `Workflow_Step_Execution__c` audit
trail and the `Compensation_Stack__c` LIFO ordering — neither is affected.

## Admission priority

Use priority when work of different importance shares one ceiling. When a
slot frees, the engine admits the highest-priority waiting instance first.

### Set the priority

- **Per definition:** set **Admission Priority** (`Admission_Priority__c`) on
  the `Concurrency_Config__mdt` record. Range 0–9. Higher is admitted sooner.
  Blank means 0. The same name and `Default` rules apply.
- **Per start:** set an override. It replaces the configured value.

  ```apex
  WorkflowEngine.start(
    new WorkflowEngine.StartRequest('IncidentWorkflow', key, input)
      .withPriority(9)
  );
  ```

  The Flow action **Start Workflow** has an optional **Priority** input.
  Debounced starts use the configured priority.

- Values out of range are clamped to 0–9. A start never fails because of
  priority.
- The engine writes the priority at insert. A later config change does not
  change instances that already exist. Continue-As-New keeps the priority.

### Order

Each instance gets a rank key at insert:

```
key = start time (ms) − priority × agingMinutes × 60000
```

The gate admits the lowest key first, then the lowest Id.

- **Same priority:** FIFO by start time.
- **Different priority:** each level gives a credit of one aging window.
- **One class only (no priority set):** FIFO by start time. This is the
  default for existing orgs.

### Starvation bound

Set **Priority Aging Minutes** (`Priority_Aging_Minutes__c`). Blank or less
than 1 means 60.

An instance at priority `p` is never passed by work that starts more than
`(q − p) × agingMinutes` after it, where `q` is the priority of that work.
The worst case is `(9 − p) × agingMinutes`. With the default (60) and
`p = 0`, work that starts more than 9 hours later cannot pass. After that
point, the instance admits when the finite work ahead of it drains.

Select the aging window with care. A small window gives less preemption. A
large window lets old low-priority work wait longer.

### How the gate uses the order

- A "waiting" instance has `Concurrency_Parked__c = true`, no slot, and the
  status `Pending`, `Running` or `Suspended`.
- When a slot is free, the gate reads the waiting rows that rank ahead of
  the visitor (`LIMIT` free slots, under the counter lock). If fewer rows are
  ahead than slots are free, the visitor takes a slot. Else it parks again
  (a "yield").
- The gate wakes the rows ahead (max 5) through the existing resume path.
  Thus the head of the queue visits the gate at once.
- A high-priority instance gets a slot within one admission cycle after the
  slot frees: the next gate visit (a parked retry timer, 30–45 s, or sooner
  with a deep backlog) plus one hop. The backlog depth has no effect.
- Rows from before this feature have no key. They rank first and get a key
  on their first gate visit.
- No new scheduled job. A yield is a normal park with one retry timer.
- Priority controls admission order only. Step rows, the compensation stack
  and the Queueable chain do not change. A running instance is never stopped
  to free a slot.

## Monitoring

The dashboard's **System Doctor** tab shows a **Concurrency Limits** panel: per governed
workflow, the current in-flight count vs. its ceiling and the number of parked/throttled
instances. Under each workflow, the panel shows the wait queue: the count per
priority class (for example `3 waiting · P9: 1 · P0: 2`) and the next five
instances in admission order with their position and priority.

## Known limitation — enabling a ceiling on already-running work

The slot counter is built up as instances are **admitted through the gate**. If you add
a ceiling (or a `Default` record starts applying) to a workflow that *already* has
in-flight instances started before the gate existed, those pre-existing instances do not
hold slots (`Concurrency_Slot_Held__c = false`), so the counter starts from the newly
admitted work only. Until that older work drains, the effective number of concurrent
instances can briefly exceed the configured ceiling. This matches how most engines apply
a concurrency limit to *new* work; the ceiling becomes exact once the pre-gate instances
reach a terminal state. To enforce the ceiling immediately on a busy workflow, enable the
config during a quiet window (or let the existing instances finish first).

## Scope

This slice is a per-workflow-definition ceiling only. Priority orders
admission inside one definition only. There is no priority across
definitions, and no priority for `RateLimiter`. Per-step/per-branch concurrency and
concurrency keyed on a business field value (e.g. "max 1 per AccountId") are out of scope.
`RateLimiter` (rate/throughput) and get-or-start dedup (#10) remain orthogonal primitives.
