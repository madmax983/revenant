# Revenant Architecture — Subsystem Map

This document maps the class layout that resulted from the #193–#214 Code
Analyzer cleanup. That program decomposed a ~17,000-line monolithic
`WorkflowEngine` into a thin **708-line, 19-public-method facade** delegating to
roughly 150 cohesive, single-responsibility classes. It is a navigational map,
not a tutorial: each section names its subsystem's responsibility and the real
classes that carry it. Every class named below was confirmed to exist under
`force-app/main/default/classes/`.

## The facade pattern

`WorkflowEngine` is now a pure **entry point**. Each of its 19 public methods is
a thin delegator to a differently-named target class (the "differently-named"
part matters — it is what let the analyzer stop treating the engine as one giant
recursive unit). The heavy exactly-once logic — step running, signalling, start
dedup, outcome/watchdog, crash recovery, and compensation — was progressively
lifted out across six engine sub-PRs (culminating in #213), leaving the engine
holding only its request/result DTOs and delegation glue. The decomposition was
driven by class-total PMD complexity budgets (Cyclomatic 40 / Cognitive 50 /
NcssCount / ExcessivePublicCount / TooManyFields); because extracting a method
cannot lower a *class* total, the only way to clear the debt on the largest
cohesive types was to split them into many small classes reached through thin
accessors and delegators. Behavior was preserved byte-for-byte throughout.

---

## Engine facade

The public API surface and the DTOs callers construct. `WorkflowEngine` exposes
19 static methods — `start`×3, `startOrGet`×3, `signal`×3, `signalOrStart`×2,
`runStep`×2, `handleCrash`×2, `failWorkflowInstance`×2, `cancel`, and
`processWatchdogHeartbeat` — each forwarding into the subsystem classes below.
Its request/result DTOs remain resident as inner classes. The orchestrator
classes are the async re-entry seam the engine enqueues work onto.

- `WorkflowEngine` — the facade class
- `WorkflowEngine.StartRequest`, `.SignalRequest`, `.SignalOrStartRequest`,
  `.FailInstanceRequest`, `.ResumeRequest`, `.OrchestratorRequest`,
  `.StepOutcomeContext`, `.StartResult`, `.WorkflowStatus`, `.WorkflowException`
  (inner DTO/exception types)
- `WorkflowOrchestrator`, `WorkflowOrchestratorEnqueue` — async re-entry / enqueue seam

## Step running & admission control (the `runStep` path)

Runs a single durable step: admits it against concurrency ceilings, acquires the
step-execution lock, invokes user step code, interprets the returned
`StepResult` directive, and advances or suspends the instance. Admission control
is the concurrency gate that decides whether a step may run now.

- `WorkflowStepRunner`, `WorkflowStepAdmission`, `WorkflowStepExecLock`
- `WorkflowStepInvoke`, `WorkflowStepContext`, `WorkflowStepAdvance`
- `WorkflowStepOutcome`, `WorkflowStepSuspension`, `WorkflowOutcomePrepare`
- `WorkflowStepExecStore` — `saveStepExec` / `saveStepExecAsCrash`
- `WorkflowStepTimeoutConfig`, `WorkflowTimeoutArming`, `WorkflowTimeoutReArm`
- `ConcurrencyGate` (facade) + `ConcurrencyConfigResolver`,
  `ConcurrencyReconciler`, `ConcurrencyReleaseProcessor`

## Signal claim, consume & routing

Delivers signals to waiting instances with exactly-once claim/consume semantics,
routes by correlation key, dedups, gates child signals, and captures/sweeps
signals that match no instance ("unrouted"). Batch classes carry the bulk
`signal(List)` path.

- `WorkflowSignalRouter`, `WorkflowSignalConsume`, `WorkflowSignalDedup`
- `WorkflowSignalGating`, `WorkflowSignalChildGate`, `WorkflowSignalHelpers`,
  `WorkflowSignalSources`
- `WorkflowSignalBatch`, `WorkflowSignalBatchWake`, `WorkflowSignalBatchCancel`,
  `WorkflowSignalBatchPartition`
- `WorkflowSignalReadService`, `WorkflowSignalCommandService`,
  `WorkflowSignalRedelivery`
- `WorkflowUnroutedCapture`, `WorkflowUnroutedSignals`, `WorkflowUnroutedSweep`
- Context-side claim/consume state: `StepSignals`, `StepSignalState`,
  `StepSignalLoader`, `StepChildOutcomes`

## Start deduplication (`startOrGet` / `signalOrStart` / debounce)

Idempotent instance creation: `startOrGet` returns an existing instance for a
correlation key or creates a new one; `signalOrStart` folds a signal into that
decision; the debouncer collapses a burst of starts into one. Scalar vs. bulk
start paths are separated.

- `WorkflowStartService`, `WorkflowStartDedup`, `WorkflowStartValidation`,
  `WorkflowStartInstanceBuilder`
- `WorkflowScalarStartService`, `WorkflowBulkStartService`,
  `WorkflowBulkStartActivation`, `WorkflowBulkStartFinalize`
- `WorkflowSignalOrStartService`, `WorkflowSignalOrStartPrepare`,
  `WorkflowSignalOrStartWake`, `WorkflowSignalOrStartCancel`
- `WorkflowDebouncer` (facade) + `WorkflowDebounceValidator`,
  `WorkflowDebounceSweeper` (holds `DebounceRequest`)

## Outcome recording & watchdog

The liveness plane. `processWatchdogHeartbeat` drives heartbeat recording,
detects stalled/orphaned instances, reclaims them, and raises stall alerts.

- `WorkflowWatchdog`, `WorkflowHeartbeatService`
- `WorkflowJobLiveness`, `WorkflowJobLivenessService`
- `WorkflowOrphanReclaimSweep`, `WorkflowReclaim`, `WorkflowReclaimPlanner`,
  `WorkflowDeadlineSweep`
- `WorkflowStallDetectionService`, `WorkflowStallDetector`,
  `WorkflowStallConfigResolver`
- `WorkflowAlertManager`, `WorkflowAlertEmailBuilder`,
  `WorkflowFailureAlertEvaluator`

## Crash recovery (`handleCrash` / `failWorkflowInstance`)

Turns an uncaught exception or explicit failure into durable, categorized
terminal/retry state, including transient-lock retry and backoff scheduling.

- `WorkflowCrashHandler`
- `WorkflowFailureService`, `WorkflowFailureSignatureService`
- `WorkflowTransientLockRetry`
- `WorkflowRetryService`, `WorkflowRetryScheduling`, `WorkflowRetryJob`,
  `WorkflowRetrySleepScheduler`

## Compensation & cancellation

Saga rollback and user cancellation. Cancellation optionally triggers
savepoint-free, LIFO-stack-driven compensation guarded by `FOR UPDATE` row
locks, popping the stack only on a successful compensated transition. Note the
public compensating-cancel entry point is `WorkflowCancellation.cancelWithCompensations(Id)`,
**not** a method on `WorkflowEngine` (the engine's only public cancel is `cancel(Id)`).

- `WorkflowCancellation` — `cancelWithCompensations` / `cancelWithCompensationsInstance`
- `WorkflowCompensation`, `WorkflowCompensationRunner`,
  `WorkflowCompensationStepLog`, `WorkflowCompensationContext`,
  `WorkflowCompensationInvoke`, `WorkflowCompensationOutcome`
- `BulkCancelWorkflow`, `CompensatableStep`

## Scheduling

Cron-driven workflow starts: the `WorkflowScheduleController` UI surface, the
sweeper that fires due schedules, dedicated-job registration, and cron
translation/evaluation.

- `WorkflowScheduleController` (facade) + `WorkflowScheduleReadService`,
  `WorkflowScheduleSaveService`
- `WorkflowScheduleSweeper` (facade) + `WorkflowScheduleSweepRunner`,
  `WorkflowScheduleDueClassifier`, `WorkflowScheduleFireService`,
  `WorkflowScheduleJobManager`, `SchedulePriorRunGuard`, `ScheduleFireLog`,
  `ScheduleInputResolver`, `SalesforceCronTranslator`
- `WorkflowScheduler`, `WorkflowScheduleJob`
- `WorkflowCronEvaluator`, `CronFieldParser`, `CronFieldExpander`, `CronMath`

## Dashboard services

The LWC-facing API, split into a **read** controller and a **command**
controller (endpoint names unchanged; only the host class of the 16 command
endpoints moved). Both delegate to `inherited sharing` service classes.

- Read side: `WorkflowDashboardController` (holds `InstanceQuery` / `StalledQuery`
  / `UnroutedQuery` DTOs) → `WorkflowInstanceListService`,
  `WorkflowInstanceDetailService`, `WorkflowStalledService`,
  `WorkflowTrendService`, `WorkflowVersionDrainService`,
  `WorkflowFailureBreakdownService`, `WorkflowDashboardStatusService`,
  `WorkflowDashboardQueryBuilders`, `WorkflowDashboardSupport`
- Command side: `WorkflowDashboardCommandController` (holds `CancelRequest` /
  `ApprovalRequest` DTOs) → `WorkflowInstanceCommandService`,
  `WorkflowBulkCommandService`, `WorkflowApprovalCommandService`,
  `WorkflowMaintenanceCommandService`, `WorkflowSignalCommandService`

## Authoring surface (step-author API)

What workflow authors actually write against. `StepContext` exposes durable
state directly plus six accessor sub-objects; `StepResult` factories build the
engine-facing directive; `WorkflowDefinition` / `WorkflowStep` describe the DAG.
Author-facing signatures were preserved; only the internal state moved onto
sub-objects and helper classes.

- `StepContext` (+ nested `Builder`, `Signal`, `Breadcrumb`, `ChildOutcome`,
  `SignalSource`, `Level`)
- Accessors: `StepLog` (`ctx.logger()`), `StepProgress` (`ctx.progress()`),
  `StepEmitter` (`ctx.events()`), `StepSignals` (`ctx.signals()`),
  `StepCaptures` (`ctx.captures()`), `StepRetryInfo` (`ctx.retry()`)
- Context internal helpers: `StepGovernor`, `StepSignalState`,
  `StepSignalLoader`, `StepChildOutcomes`, `StepCaptureSerde`,
  `StepExecutionIndex`, `StepExecutionParse`; `CaptureProducer` interface
- `StepResult` (+ nested `StepDirective`/`RetryDirective`/`TimeoutDirective`/
  `ContinueDirective`, `ChildRequest`) + `StepResultJson`, `StepResultValidator`,
  `BusinessSleepCalculator`, `BusinessHoursCalendar`
- `WorkflowDefinition`, `WorkflowStep`, `RetryPolicy`

---

*Test fixtures (`WorkflowTestHarness`, `StepContextTestBuilder`, `TestIdFactory`)
are the authoring surface's testing counterpart and are documented in CLAUDE.md.*
