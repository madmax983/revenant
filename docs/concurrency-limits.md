# Concurrency Limits — capping in-flight instances per workflow

Revenant treats **concurrency** (a ceiling on simultaneously in-flight work) as a
primitive distinct from **rate/throttle** (`RateLimiter`, events per unit time) and from
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

## Monitoring

The dashboard's **System Doctor** tab shows a **Concurrency Limits** panel: per governed
workflow, the current in-flight count vs. its ceiling and the number of parked/throttled
instances.

## Scope

This slice is a per-workflow-definition ceiling only. Per-step/per-branch concurrency and
concurrency keyed on a business field value (e.g. "max 1 per AccountId") are out of scope.
`RateLimiter` (rate/throughput) and get-or-start dedup (#10) remain orthogonal primitives.
