# Instance Purge Implementation Plan (Issue #142)

**Goal:** One call deletes selected terminal instances and all their
satellites. No orphans remain.

**Architecture:** `WorkflowInstanceTeardown` is the one delete routine. It
deletes engine files, signals, instance logs and instances.
`WorkflowArchiveSweep` (used by `CleanupWorkflow` and `ArchiveWorkflow`) and
the new `WorkflowInstancePurge` API both call it. `CleanupDocumentPurger` plans
the chunk. It now keeps a group of related instances together.

**Tech stack:** Apex. No new object, field or event.

---

## 1. Brainstorming

- **Put the API on a new class.** `WorkflowEngine` is at the PMD
  `ExcessivePublicCount` limit (ADR 0007). `WorkflowInstanceHold` set the
  pattern: `WorkflowInstancePurge.purge(...)`.
- **Overloads.** `purge(Id)`, `purge(Set<Id>)` and
  `purge(Set<Id>, Boolean includeRelated)`.
- **Result, not exception, for an expected state.** Each Id gets an `Outcome`
  and a message, as `HoldResult` does. Bad input (null, too many Ids) throws
  `WorkflowEngine.WorkflowException`.
- **Mixed set: skip and report.** The call purges the Ids that pass. It
  reports each Id that it skips, with the reason.
- **Related instances go as one group.** Parent/child links and
  `Previous_Instance__c` links join instances into a group. A group is purged
  in full or not at all. So a deferred chunk cannot split a chain.
- **Log ownership.** A log row that has `Schedule__c` belongs to the schedule
  fire history. The purge keeps it. The platform clears its instance lookup.
  The purge deletes all other logs of the instance.
- **Shared routine closes the log leak.** `CleanupWorkflow` and
  `ArchiveWorkflow` call the same teardown, so they delete logs too.
- **Archive copies stay.** Big Object rows and CSV archive files are a
  deliberate copy (#105). The purge does not touch them.

## 2. Reverse brainstorming (how can it fail?)

| Failure                                                           | Mitigation                                                                                                                          |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Purge deletes an instance that a Queueable still runs.            | Only terminal statuses pass. The read uses `FOR UPDATE`, so a concurrent redrive waits or wins.                                     |
| Purge deletes a completed instance that a running rollback reads. | A compensating instance points to its target with `Previous_Instance__c`. An active successor outside the set blocks the purge.     |
| Purge deletes a terminal child that an active parent still reads. | The determinism guard reads child statuses. An active parent outside the set blocks the purge.                                      |
| Purge leaves a `ContinuedAsNew` row with no successor.            | The predecessor of each purged row must be in the set. Removal of the oldest generations (truncation) is allowed.                   |
| Purge leaves a child with no parent.                              | Each child must be in the set. With `includeRelated`, the call adds it.                                                             |
| A chunk split leaves half of a chain.                             | The planner adds whole groups only.                                                                                                 |
| Purge deletes a user file or a shared file.                       | Same title-prefix allowlist and same shared-link check as `CleanupWorkflow`.                                                        |
| Purge deletes schedule history.                                   | Logs with `Schedule__c` stay.                                                                                                       |
| A big family eats the SOQL or heap limit.                         | At most 50 Ids in, 50 instances purged, 100 files, 20 link rounds and 2000 related rows. A bigger family gets `REJECTED_TOO_LARGE`. |
| A refactor changes `CleanupWorkflow` behavior.                    | The sweep keeps its selection, bounds and cursor. Only the delete step moves. Existing tests stay.                                  |
| An Id of another object type.                                     | `NOT_FOUND`, no query error.                                                                                                        |

## 3. Six thinking hats

- **White (facts):** Step rows and search attributes cascade
  (MasterDetail). Signals, logs and relation lookups use SetNull. Files link
  only by `ContentDocumentLink`. No org is in this session, so Apex tests
  cannot run here.
- **Red (feelings):** Operators fear a delete that they cannot undo. So the
  call refuses unclear cases and reports each skip.
- **Black (risks):** A cascade to related instances deletes more than the
  caller named. So `includeRelated` is off by default, and the result lists
  each related Id that it deleted.
- **Yellow (benefits):** One routine for all purges. The log leak closes.
  Operators get an erasure step for their own DSAR process.
- **Green (ideas):** Later: a dashboard action, a `global` promotion under
  ADR 0006, a purge by correlation key.
- **Blue (process):** SPEC (outcomes and rules), RED (tests fail to compile
  in apex-ls), GREEN (code), REFACTOR, then a multi-angle agent review.

## 4. Rules (spec)

Terminal statuses: `Completed`, `Failed`, `Compensated`, `Cancelled`,
`ContinuedAsNew`.

For each instance X in the final set S:

1. X is terminal. Else `REJECTED_NOT_TERMINAL`.
2. Each child of X is in S. Else `REJECTED_RELATED`.
3. The predecessor of X (`Previous_Instance__c`) is in S. Else
   `REJECTED_RELATED`.
4. A successor of X that is not in S is terminal. Else
   `REJECTED_RELATED_ACTIVE`.
5. The parent of X, when not in S, is terminal. Else
   `REJECTED_RELATED_ACTIVE`.

With `includeRelated`, the call first adds the full family of each Id: all
generations in both directions, all children and their families. It does not
add a parent. Each added instance must be terminal (`REJECTED_RELATED_ACTIVE`).

A rejected instance rejects its group. A group that does not fit the bounds
of this call gets `DEFERRED`. Call again for it.

## 5. Tasks

1. RED: `WorkflowInstancePurgeTest`, a log test in `CleanupWorkflowTest`.
2. GREEN: `WorkflowInstanceTeardown`, group planning in
   `CleanupDocumentPurger`, `WorkflowInstancePurge`, sweep refactor.
3. REFACTOR: prettier, apex-ls, remove duplicate status lists.
4. Docs: `docs/instance-purge.md`, ADR 0016, README, `docs/archive.md`.
5. Review: agents for correctness, platform limits, security, tests and docs.
