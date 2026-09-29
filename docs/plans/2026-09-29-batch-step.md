# Batch Apex as a Durable Step (Issue #138)

## Goal

Run an existing `Database.Batchable` as one durable step. The step launches the batch one time, suspends the instance, and resumes one time when the batch ends. The `Batchable` does not know Revenant.

## Facts

- `WorkflowFlowStep` is the model. It is `public`, reads a JSON input, and uses `ctx.captures().once()`.
- `once()` keeps a value in `Captured_Values__c`. The engine writes it before each outcome. A resumed step uses the same step row, so the value is there on each re-run.
- `Database.executeBatch(Object, Integer)` returns the `AsyncApexJob` Id. The platform queues the job at commit. A rollback of the transaction removes the job.
- `AsyncApexJob` has `Status`, `TotalJobItems`, `JobItemsProcessed`, `NumberOfErrors` and `ExtendedStatus`. The counts are batches (chunks), not records. The platform does not give record counts without code in the `Batchable`.
- Terminal statuses: `Completed`, `Failed`, `Aborted`. A `Completed` job can have `NumberOfErrors > 0`.
- The platform deletes `AsyncApexJob` rows after about 7 days.
- An org has not more than 5 running batch jobs and 100 in the flex queue. Thus, few instances wait on a batch at the same time.
- The watchdog heartbeat runs fixed sections. Section 2 (`WorkflowSleepResumeSweep`) resumes a `Suspended` instance with `Sleep_Until__c <= now`. It obeys pause, hold, global park and compensation.
- `WorkflowOutcomePrepare.prepareStepOutcome` runs before each step outcome. It is one point where the engine sees each result.
- The determinism lint does not scan `produce()` of a `CaptureProducer` or helper classes.
- There is no org in this session. `apex-ls` compiles the Apex. Node runs the static tests. The Apex tests run in an org.

## Brainstorm (options)

| #   | Idea                                                                          | Keep?                                                                                  |
| --- | ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| B1  | Step sleeps and polls `AsyncApexJob` on each wake.                            | No. The AC asks for a tracked field and the watchdog.                                  |
| B2  | `finish()` sends a signal.                                                    | No. The `Batchable` must not know Revenant.                                            |
| B3  | New Platform Event from a trigger on `AsyncApexJob`.                          | No. No trigger on that object. The AC forbids a new event.                             |
| B4  | Indexed field `Awaited_Batch_Job_Id__c` on the instance. The watchdog reads it. | Yes.                                                                                   |
| B5  | Launch in a `CaptureProducer` through `once()`.                               | Yes. Launch and capture commit together. The lint does not flag it.                    |
| B6  | Sweep resumes the instance itself.                                            | No. It copies pause, hold and park rules.                                              |
| B7  | Sweep sets `Sleep_Until__c = now`. Section 2 resumes it in the same heartbeat. | Yes. It uses the existing resume path and its rules.                                   |
| B8  | Engine sets the field from a new `StepResult` directive.                      | Yes. `withAwaitedBatchJob(Id)`, `public`, not `global`.                                |
| B9  | `prepareStepOutcome` writes the field for each outcome.                       | Yes. A result without a job clears the field. No stale value stays.                    |
| B10 | Output keys use the `AsyncApexJob` names.                                     | Yes. No false "record" names.                                                          |
| B11 | `failOnError` option: a failed batch returns `StepResult.fail`.               | Yes. The shortest path to compensation.                                                |
| B12 | A virtual `bind(ctx)` hook. A subclass gives the class, scope and input.      | Yes. This is the "one binding" of the success metric.                                  |
| B13 | Abort the batch on cancel.                                                    | No. Out of scope. Document it.                                                         |
| B14 | Support parallel branches.                                                    | No. One field holds one job. The step fails before launch in a parallel branch.        |
| B15 | A missing `AsyncApexJob` row is terminal (`NotFound`).                        | Yes. A purged row must not stall the instance.                                         |
| B16 | Test seams for launch and job rows in a helper class.                         | Yes. Tests cannot insert `AsyncApexJob`.                                               |

## Reverse Brainstorm (how can this fail?)

| Way to fail                                                                    | Prevention                                                                                         |
| ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| A re-run launches a second batch.                                              | `once()` holds the job Id. The launch and the capture commit in one transaction. Test: re-entrant hop. |
| Auto-retry rolls back to a savepoint after the launch.                         | No code that can throw runs after the launch in `execute()`.                                      |
| The sweep wakes a sleep or a retry early because of a stale field.            | B9 clears the field. The sweep also needs `Sleep_Until__c = null`.                                 |
| The sweep resumes the instance two times.                                      | The sweep locks the rows and clears the field in the same update. Test: second sweep does nothing. |
| A paused definition resumes.                                                   | Section 2 holds it. The sweep only sets the wake time.                                             |
| A large backlog of waiting instances starves terminal ones.                    | The candidate read has no lock and a limit of 2,000. The platform limits active batches to about 105. |
| The job row is purged while the watchdog is down.                              | B15.                                                                                               |
| A malformed field value throws in the sweep and stops the heartbeat.           | The sweep wakes the row. The step reads its own capture. The heartbeat catches sweep errors.      |
| Two parallel branches overwrite one field.                                     | B14.                                                                                               |
| A `Completed` job with chunk errors routes as a success.                       | `succeeded` is true only for `Completed` and 0 errors.                                             |
| The author reads "record counts" but gets chunk counts.                        | B10. The doc says what the counts are.                                                             |
| The step reads an uncommitted job in the launch transaction.                   | The first run suspends at once. It does not read the job.                                          |

## Six Thinking Hats

- **White (facts).** See Facts. The counts are chunks. The resume latency is one heartbeat interval.
- **Red (feelings).** Authors want "call my batch and wait". A new field on a hot object feels risky. It is nullable, additive and indexed.
- **Black (risks).** Stale field, double launch, heartbeat cost, purged rows. See Reverse Brainstorm.
- **Yellow (benefits).** No new event, no new scheduled job, no orchestrator change. The `Batchable` stays as it is. The lint stays clean.
- **Green (ideas).** Later: abort on cancel, CMDT binding, record counts through an optional interface.
- **Blue (process).** RED: tests that do not compile (apex-ls) and a report-types Node test that fails. GREEN: the smallest code. REFACTOR: docs in STE100, format, lint. Then review agents.

## Design

1. `WorkflowBatchStep` (`public virtual`, `WorkflowStep`). `bind(ctx)` gives a `Binding`: class name, scope size (1 to 2,000, default 200), input, `failOnError`. The default `bind` reads the JSON input.
2. `execute`: refuse a parallel branch. `once('batch_job_id')` launches the job. First run: `suspend().withAwaitedBatchJob(jobId)`. Later run: read the outcome. Not terminal: suspend again. Terminal: `once('batch_outcome')` pins it. Complete with the outcome, or fail when `failOnError` and not `succeeded`.
3. `WorkflowBatchJobs`: launch, terminal outcomes, parallel check, test seams.
4. `StepResult.withAwaitedBatchJob(Id)`: `public`. Only on `SUSPEND`.
5. `WorkflowOutcomePrepare`: writes `Awaited_Batch_Job_Id__c` from the result on each outcome.
6. `WorkflowBatchAwaitSweep`: heartbeat section 1c, before section 2. 1 SOQL without lock, 1 SOQL on `AsyncApexJob`, 1 SOQL with lock and 1 DML only when a job ended.
7. Field `Awaited_Batch_Job_Id__c`: Text(18), External ID (indexed). Permission sets and report types show it.
8. Example: `BatchStepWorkflowExample` with `ExampleAccountTagBatch` (no Revenant code).

## Test Plan (RED first)

| Test                                   | Proves                                                   |
| -------------------------------------- | -------------------------------------------------------- |
| `WorkflowBatchStepTest`                | Launch once, suspend, re-entrant hop, outcomes, input errors, `failOnError`, binding, parallel refusal. |
| `WorkflowBatchJobsTest`                | Terminal filter, `NotFound`, outcome keys, real launch in a test. |
| `WorkflowBatchAwaitSweepTest`          | Wake on terminal job, no wake on running job, other waits, exactly once, heartbeat resume. |
| `StepResultTest`                       | `withAwaitedBatchJob` rules.                             |
| `WorkflowOutcomePrepare` (through E2E) | Field set on suspend, cleared on complete.               |
| `BatchStepWorkflowExampleTest`         | Success path with a real batch, failure path with compensation, one launch. |
| `report-types.test.mjs` (existing)     | The new field is shown or excluded on purpose.           |
