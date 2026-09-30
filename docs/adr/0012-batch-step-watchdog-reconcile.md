# ADR 0012: Batch Apex Step Resumed by the Watchdog

- **Status:** Accepted
- **Date:** 2026-09-29
- **Issue:** #138

## Context

Authors want to run a `Database.Batchable` as one durable step. The `Batchable` must not know Revenant. The issue forbids a new Platform Event type and a change to the orchestrator Queueable handoff. The determinism lint flags `Database.executeBatch` in a step body.

## Decision

1. `WorkflowBatchStep` launches the job in a `CaptureProducer` through `once()`. The launch and the captured job Id commit together. The lint does not scan `produce()`.
2. The `SUSPEND` result carries the job Id (`StepResult.withAwaitedBatchJob`, `public`). `WorkflowOutcomePrepare` writes it to the new field `Awaited_Batch_Job_Id__c` on each outcome. A result with no job clears the field. A compensation outcome, a cancel, a failure and the sweep also clear it. Thus, an old job cannot wake a later wait.
3. Heartbeat section 1c (`WorkflowBatchAwaitSweep`) reads the waiting instances without a lock, reads `AsyncApexJob`, then locks the rows whose job ended. It clears the field and sets `Sleep_Until__c` to now. Section 2 resumes them. The sweep does not copy the pause, hold and park rules.
4. A missing `AsyncApexJob` row is an ended job with status `NotFound`. A purged row cannot stall the instance.
5. Strict determinism treats a batch wait as transient, as it treats `SLEEP`.
6. The step fails before the launch in a parallel branch. One field holds one job.

## Consequences

- One new nullable, indexed field. No new event, scheduled job or Queueable.
- Resume latency is usually one heartbeat interval. Pause, hold, global park and the section 2 batch limit can make it longer.
- The output counts are batches, not records. The platform gives no record count without code in the `Batchable`.
- Cancel does not abort the job.
- We did not use these options:
  - A sleep-and-poll step, because the AC asks for the watchdog.
  - A signal from `finish()`, because the `Batchable` must not know Revenant.
  - A resume in the sweep, because it would copy the section 2 rules.
- `WorkflowBatchStep` is `public`. A subscriber uses the input JSON. The subclass hook is for the package namespace only.
- The input names the class to launch. The engine refuses a class that is not a `Batchable`. Authors must not put untrusted input in `batchClass`.
