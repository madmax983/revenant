# Debounced Workflow Starts (Issue #140)

## Goal

Start a workflow one time after a burst of triggers stops. Use the input of
the last trigger. Add no scheduled job.

## Facts About The Engine

- `WorkflowDebouncer.startDebounced(List<DebounceRequest>)` exists. It
  writes one `Debounce_State__c` row for each `(workflowName,
correlationKey)`. Each call moves `Fire_At__c` to `now + debounceSeconds`
  and writes the new input. `maxWaitSeconds` caps `Fire_At__c` at
  `First_Triggered_At__c + maxWaitSeconds`.
- `WorkflowDebounceSweeper` runs in the watchdog heartbeat (step 3b). It
  starts each due row with `WorkflowEngine.startOrGet`, then deletes it.
  A failed start retries two times, then goes to quarantine.
- The Start Workflow invocable has `debounceSeconds` and `maxWaitSeconds`.
- `examples/` has `CaseDebounceTrigger`. It sets request fields directly.
- `WorkflowDebouncer` is not `global`. A subscriber org cannot call it. It
  is a candidate in `docs/global-api.md`.
- The sweeper reads due rows without a lock. A trigger that re-arms a row
  after the read and before the delete is lost. This is the race that the
  issue names.
- Two transactions can arm a new key at the same time. Both find no row.
  Both insert. The second insert fails with `DUPLICATE_VALUE`. The error
  goes to the caller, so the record save fails.
- `Fire_At__c` keeps milliseconds from `now`. A DateTime field can drop
  them. Then the row can fire up to 999 ms before the quiet window ends.
- SOQL does not allow `ORDER BY` with `FOR UPDATE`. The engine uses two
  queries: find the Ids in order, then lock them (`WorkflowSignalSources`).

## Brainstorming (options)

| #   | Idea                                                                   | Keep?                                                              |
| --- | ---------------------------------------------------------------------- | ------------------------------------------------------------------ |
| B1  | Add `WorkflowEngine.startDebounced` with 4 positional arguments.       | No. #204 removed positional overloads. Use the request object.     |
| B2  | Make `WorkflowDebouncer` and `DebounceRequest` `global`.               | Yes. The issue asks for a permanent Apex entry point.              |
| B3  | Add a scalar `startDebounced(DebounceRequest)` overload.               | Yes. Same shape as `WorkflowEngine.start`.                         |
| B4  | Make all `DebounceRequest` setters `global`.                           | No. Only the constructor, `withDebounce` and `withMaxWait`.        |
| B5  | Lock due rows in the sweeper. Read them again under the lock.          | Yes. A re-arm then waits, or the sweeper sees it.                  |
| B6  | Skip a locked row that is no longer due.                               | Yes. The newer trigger moved the timer.                            |
| B7  | Insert new rows with `allOrNone = false`. Update on `DUPLICATE_VALUE`. | Yes. A parallel first trigger does not fail the save.              |
| B8  | Round `Fire_At__c` up to the next whole second.                        | Yes. A row never fires before the quiet window ends.               |
| B9  | Enqueue a delayed Queueable for each arm.                              | No. A burst of 50 makes 50 jobs. The heartbeat sweep costs 0 jobs. |
| B10 | Store `maxWaitSeconds` on the row.                                     | No. New field = forever schema. The last request's value applies.  |
| B11 | Signal a running instance with the new input.                          | No. Out of scope.                                                  |
| B12 | Show `maxWaitSeconds` and the input in the example step.               | Yes. The example is copyable. Use fluent setters.                  |

## Reverse Brainstorming (how to make it fail)

| How to fail                                              | Counter                                                            |
| -------------------------------------------------------- | ------------------------------------------------------------------ |
| Lose the last input when a trigger lands during a sweep. | Lock and read again (B5). Skip rows that are not due (B6).         |
| Start two instances for one burst.                       | One row per key. `startOrGet` collapses a repeated fire.           |
| Fail a record save when two saves arm the same new key.  | Update on `DUPLICATE_VALUE` (B7).                                  |
| Fire before the quiet window ends.                       | Round up to the whole second (B8). Sweep uses `Fire_At__c <= now`. |
| Never fire a key that gets triggers all the time.        | `maxWaitSeconds` cap. Test it.                                     |
| Use a scheduled-job slot.                                | Sweep in the heartbeat. A test counts `CronTrigger` rows.          |
| Let a subscriber org call internals.                     | Only the manifest members are `global`. `test:global-api`.         |
| Spend the caller's SOQL or DML.                          | 1 SOQL and at most 3 DML for each arm call, for any batch size.    |

## Six Thinking Hats

- **White (facts):** The feature exists. Gaps: no `global` Apex entry point,
  the sweep race, the parallel-insert error, and millisecond early fire.
- **Red (feel):** Authors want "one run, last data". A lost last edit feels
  like data loss. A failed save feels like a crash.
- **Black (risk):** A `global` member is permanent. Keep the surface small.
  The sweeper lock can make a trigger wait while the sweep runs. The sweep
  is short (at most 100 rows).
- **Yellow (value):** One run for each burst. No new schema. No new job.
  Subscribers can debounce from Apex and from Flow.
- **Green (ideas):** Later: store `maxWaitSeconds`, a dashboard view of
  pending debounces, a leading-edge mode.
- **Blue (process):** Write the spec. Write failing tests. Make them pass.
  Clean up. Do an agent review. Map each acceptance criterion to evidence.

## Spec

Terms:

- Key = `(workflowName, correlationKey)`, case-insensitive.
- Window = `debounceSeconds`. Cap = `maxWaitSeconds` (blank or 0 = no cap).

Rules:

1. Arm: no row for the key → insert one. `First_Triggered_At__c = now`.
2. Re-arm: a row exists → set the input to the new input.
3. `Fire_At__c = ceil(min(now + window, First_Triggered_At__c + cap))` to
   the whole second.
4. Sweep: lock each due row. Read it again. Skip it if it is not due.
   Start it with `startOrGet`. Delete it.
5. A new-key insert that fails with `DUPLICATE_VALUE` locks the other row
   and applies rules 2 and 3.

Invariants:

- At most one `Debounce_State__c` row for each key.
- The sweeper starts the input that the row holds when it has the lock.
- A row never fires before `Fire_At__c`. `Fire_At__c` has no milliseconds.
- The arm path and the sweep add no scheduled job.

## Test Plan (RED)

`WorkflowDebounceBurstTest`:

1. 50 triggers in 5 s, window 10 s: one instance, input 50, fire at the
   first whole second at or after `last + 10 s`, not before.
2. 20 triggers 9 s apart and no cap: no start while triggers continue.
3. Cap 30 s and triggers every 5 s: start at `first + 30 s`.
4. A re-arm between the sweep read and the lock: the sweeper skips the row.
5. A re-arm that stays due: the sweeper starts the new input.
6. A parallel first insert (`DUPLICATE_VALUE`): no error, one row, new input.
7. A second fire for a settled key (redelivery) collapses to one instance.
8. Arm and sweep add 0 `CronTrigger` rows.
9. A Flow burst of 10 rows starts one instance with the last input.
10. `GlobalApiSubscriberTest` arms a debounce with only the global API.
