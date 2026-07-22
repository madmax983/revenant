# Circuit Breaker — fast-failing a fleet when a dependency is down

Revenant treats a **circuit breaker** (reacting to the *health* of a shared
dependency) as a primitive distinct from **rate/throttle** (`RateLimiter`, events per
unit time), **concurrency** (`Concurrency_Config__mdt`, a ceiling on simultaneously
in-flight instances per workflow), and **per-step retry** (`RetryPolicy`, backoff for
one step's own transient failures). A breaker watches how often a shared dependency —
a partner API, a legacy endpoint, a payments gateway — is failing *across the whole
fleet*, and once it is clearly down it **fast-fails** new work (parks it) instead of
letting hundreds of instances keep hammering a dead system. When the dependency
heals, the breaker admits a trial probe and, on success, restores normal traffic — no
manual intervention.

## Opting a step in (code)

A `WorkflowStep` opts in by implementing `CircuitBreakerGuarded` and naming the
dependency it calls:

```apex
public class ChargeCardStep implements WorkflowStep, CircuitBreakerGuarded {
  public String dependencyKey() {
    return 'ExternalPaymentsApi';
  }
  public StepResult execute(StepContext ctx) {
    try {
      PaymentsGateway.charge(ctx.idempotencyKey);
      return StepResult.complete(null, null);
    } catch (PaymentsGateway.OutageException e) {
      return StepResult.fail(e.getMessage()); // counted against the breaker
    }
  }
}
```

The key is a **dependency** name, shared across every workflow whose guarded steps
call it — it is deliberately **not** per workflow definition, so one breaker protects
one downstream system no matter how many workflows use it. A step that does not
implement `CircuitBreakerGuarded` is never gated: the admission hook short-circuits on
the `instanceof` check with **zero SOQL and zero DML**, so the unguarded hot path — and
the unguarded steps in a mixed batch — pay nothing.

## Configuring a breaker (no code)

Create a **Circuit Breaker Config** (`Circuit_Breaker_Config__mdt`) Custom Metadata
record. The engine maps a dependency key to a record `DeveloperName` using the **same
convention as `Concurrency_Config__mdt`** — every non-alphanumeric character becomes
`_`, truncated to 40 characters — with a `Default` record as the final fallback. A
dependency key with no matching record **and** no `Default` has **no breaker**: guarded
steps for it always admit (0 SOQL / 0 DML). The four thresholds:

| Field                        | Meaning                                                      |
| ---------------------------- | ----------------------------------------------------------- |
| `Failure_Threshold__c`       | Failures within the window that trip the breaker **Open**.  |
| `Rolling_Window_Seconds__c`  | Length of the rolling failure-count window.                 |
| `Open_Duration_Seconds__c`   | How long the breaker stays Open before trying Half-Open.    |
| `Half_Open_Probe_Count__c`   | Trial probes admitted while Half-Open.                      |

A record with a missing or non-positive threshold is treated as **unconfigured** (fails
open — no breaker), mirroring how a non-positive concurrency ceiling is treated as
unbounded.

## How it works

- **Durable state, one row per dependency.** Each configured dependency key has one
  `Circuit_Breaker_State__c` row holding the status (Closed/Open/HalfOpen), the rolling
  failure count and its window start, when it last opened, and how many half-open
  probes have been admitted — mutated under `SELECT ... FOR UPDATE` so the many
  instances that hit the same hot dependency-key row in the same window are serialized
  and the transitions are effectively-once. (CMDT config reads are governor-free.)
- **Count failures.** Every retry-triggering or explicit failure of a guarded step
  counts against its dependency's rolling window. Reaching `Failure_Threshold__c` trips
  the breaker **Open**; an elapsed window with no trip resets the count.
- **Fast-fail when Open.** A guarded step whose breaker is Open is **parked at the
  admission hook before `execute()` runs** — the dependency is never called. The park is
  a durable suspend that sleeps until the open duration is due to elapse and re-checks
  the breaker when it wakes, reusing the same sleep/watchdog resume plumbing as SLEEP
  (no busy spin, no new scheduled-job slot). It is a *distinct* park: it writes a Warn
  `Workflow_Log__c` line naming the dependency key, so an operator/dashboard can tell a
  self-healing breaker fast-fail apart from a plain durable sleep.
- **Recover through a probe.** Once the open duration elapses the breaker moves to
  **Half-Open** — on demand when live traffic hits it, or via the watchdog
  `sweepHalfOpen()` for a dependency that went completely quiet, so recovery lands
  within one heartbeat cadence with zero traffic. A bounded number of trial probes are
  admitted; a probe **success** closes the breaker (restoring normal admission and
  resetting the failure count), a probe **failure** re-opens it for another open window.

Breaker state lives entirely outside the append-only `Workflow_Step_Execution__c` audit
trail and the `Compensation_Stack__c` LIFO ordering — neither is affected.

## Distinct from the other throttles

| Primitive                    | Reacts to                          | Scope                         |
| ---------------------------- | ---------------------------------- | ----------------------------- |
| `RetryPolicy`                | one step's own transient failure   | a single step attempt         |
| `RateLimiter`                | call **rate**                      | a token bucket per integration key |
| `Concurrency_Config__mdt`    | **in-flight count**                | instances per workflow definition |
| `Circuit_Breaker_Config__mdt`| dependency **health**              | a shared dependency, fleet-wide |

They compose: a step can be rate-limited, concurrency-capped, retryable, and breaker-
guarded at once. Use a breaker when a *shared downstream system* can go down and you
want the fleet to stop calling it and auto-recover — not to smooth call rate
(`RateLimiter`) or cap in-flight work (`Concurrency_Config__mdt`).

## Scope

A breaker is keyed on a dependency name and counts failures fleet-wide. Per-instance or
per-tenant breakers (a breaker keyed on a business field value) are out of scope;
`RateLimiter`, `Concurrency_Config__mdt`, and `RetryPolicy` remain orthogonal
primitives. See [CircuitBreakerWorkflowExample](../examples/main/default/classes/CircuitBreakerWorkflowExample.cls)
for a runnable fleet fast-fail + auto-recovery reference.
