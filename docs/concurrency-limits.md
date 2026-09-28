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
slot becomes free, the gate admits the waiting instance with the lowest rank
key. Usually, this instance has the highest priority.

### Terms

- **Waiting instance:** an instance that has `Concurrency_Parked__c = true`,
  holds no slot, and has the status `Pending`, `Running` or `Suspended`. A new
  start of a bounded workflow is a waiting instance until it gets a slot.
- **Candidate:** the waiting instance that is at the gate now.
- **Yield:** the candidate parks again because other instances rank ahead.
- **Head of the queue:** the waiting instance with the lowest rank key.
- **First in, first out (FIFO):** the oldest instance goes first.
- **Starvation:** a low-priority instance waits with no limit.

### Set the priority

- **Per definition:** set **Admission Priority** (`Admission_Priority__c`) on
  the `Concurrency_Config__mdt` record. The range is 0–9. The gate admits an
  instance with a higher value sooner. Blank means 0. The name and `Default`
  rules of the ceiling also apply.
- **Per start:** set an override. It replaces the configured value.

  ```apex
  WorkflowEngine.start(
    new WorkflowEngine.StartRequest('IncidentWorkflow', key, input)
      .withPriority(9)
  );
  ```

- These start paths accept an override:
  - `WorkflowEngine.start` and `startOrGet` with a `StartRequest` (one or a
    list).
  - `WorkflowEngine.signalOrStart`.
  - The Flow actions **Start Workflow** and **Signal or Start Workflow**
    (input **Priority**).
- These start paths use the configured priority: the overloads with
  `(workflowName, correlationKey, input)`, child workflows, schedules, and
  debounced Flow starts.
- The engine changes a value below 0 to 0, and a value above 9 to 9. A start
  never fails because of priority.
- Any caller that can start a workflow can set an override. Priority is a
  hint from a trusted caller, not a security control.
- The engine sets the priority and the key at insert. A later change to
  priority or aging does not change instances that already exist.
- Continue-As-New keeps the priority. The successor gets a new key from its
  own start time, so it goes to the end of its priority class.

### Order

Each instance gets a rank key at insert:

```
key = start time (ms) − priority × agingMinutes × 60000
```

The gate admits the lowest key first, then the lowest Id.

- **Same priority:** FIFO by start time.
- **Different priority:** each level moves the instance ahead by one aging
  window.
- **One class only (no priority set):** FIFO by start time. This is the
  default for existing orgs.

### Starvation bound

Set **Priority Aging Minutes** (`Priority_Aging_Minutes__c`). Blank or less
than 1 means 60. The maximum is 525600 (one year).

Let `p` be the priority of an instance, and `q` the priority of other work.
Work that starts more than `(q − p) × agingMinutes` after the instance cannot
go before it. The worst case is `(9 − p) × agingMinutes`. With the default
(60) and `p = 0`, work that starts more than 9 hours later cannot go first.

This bound limits which work can go first. It is not a clock limit. After
the bound, the gate admits the instance when the work ahead of it is
complete. The bound uses the aging value at insert of each instance.

Select the aging window carefully. A small window gives priority less
effect. A large window lets low-priority work wait longer.

### How the gate uses the order

- The instance trigger keeps the indexed field `Admission_Queue__c` equal to
  the workflow name while an instance waits. Else the field is blank. The
  gate reads the queue through this field, not through a table scan.
- The gate holds the counter lock. When a slot is free, it reads the waiting
  instances that rank ahead of the candidate, up to the number of free
  slots. If fewer instances are ahead than slots are free, the candidate
  gets a slot. If not, the candidate yields.
- After the decision, the gate wakes the instances ahead (up to the number
  of free slots, max 10) with one admit-only Queueable
  (`ConcurrencyAdmissionWake`). The gate enqueues the wake before the
  re-drive of the candidate. The job locks its rows in Id order, then gives
  each instance a slot or parks it again. It never runs a step. When the
  Queueable budget of the transaction is spent, the gate does not wake, and
  the instances use their retry timers. The re-drives that the admission
  starts use the normal engine path: a Queueable, or a Platform Event when
  the budget is spent.
- An instance that enters `Compensating` or `Cancelling` loses the
  awaiting-admission marker. A rollback never waits in the queue.
- An admit or a park aborts the old retry timer of the candidate. Thus an
  old timer cannot re-drive an admitted instance.
- When a slot becomes free, the head of the queue gets it within one
  admission cycle. An admission cycle is the next gate visit plus one hop. A
  gate visit is a new start or a retry timer (30–45 s). Under a large burst,
  the timers fall back to the watchdog, and the cycle is longer.
- A row from before this feature has no key. It ranks first. Such rows go in
  Id order among themselves. The gate does not write a key on them.
- A waiting row from before this feature also has a blank
  `Admission_Queue__c`. The gate does not see it until the field is set. The
  watchdog heartbeat sets it on 200 rows per sweep. To set it at once after
  deploy, run `scripts/apex/backfill_admission_queue.apex` until it prints 0.
- The feature adds no scheduled job class and no Platform Event. A yield is
  a normal park: it schedules one retry timer, as a park does.
- With one priority class, a candidate can now yield to an older waiting
  instance. Before this feature, the first retry timer got the slot. The
  slot now stays free for one more hop, until the head arrives.
- Priority sets the admission order only. Step rows, the compensation stack
  and the Queueable chain do not change. A running instance is never stopped
  to free a slot.

## Monitoring

The dashboard's **System Doctor** tab shows a **Concurrency Limits** panel: per governed
workflow, the current in-flight count vs. its ceiling and the number of parked/throttled
instances. Under each workflow, the panel shows the wait queue:

- The count per priority class, for example `3 waiting · P9: 1 · P0: 2`.
- Up to five next instances in admission order, with position and priority.

The waiting count includes new starts that have no slot yet. The parked
count includes only `Suspended` instances. Thus the waiting count can be
larger.

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

This slice is a per-workflow-definition ceiling only. Priority sets the
admission order in one definition only. There is no priority across
definitions, and no priority for `RateLimiter`. Per-step/per-branch concurrency and
concurrency keyed on a business field value (e.g. "max 1 per AccountId") are out of scope.
`RateLimiter` (rate/throughput) and get-or-start dedup (#10) remain orthogonal primitives.
