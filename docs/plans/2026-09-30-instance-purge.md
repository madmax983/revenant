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
- **Mixed set: skip and report.** The call purges the Ids that obey the rules. It
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
| Purge deletes an instance that a Queueable still runs.            | Only terminal statuses are accepted. The read uses `FOR UPDATE`, so a concurrent redrive waits or wins.                             |
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
4. A successor of X that is not in S has a final status (terminal, not
   `Failed`). Else `REJECTED_RELATED_ACTIVE`.
5. The parent of X, when not in S, has a final status. Else
   `REJECTED_RELATED_ACTIVE`.

With `includeRelated`, the call first adds the full family of each Id: all
generations in both directions, all children and their families. It does not
add a parent. Each added instance must be terminal (`REJECTED_RELATED_ACTIVE`).

A rejected instance rejects its group. A group larger than a bound gets
`REJECTED_TOO_LARGE`. A group that does not fit the rest of this call gets
`DEFERRED`. Call again for it.

## 5. Tasks

1. RED: `WorkflowInstancePurgeTest`, a log test in `CleanupWorkflowTest`.
2. GREEN: `WorkflowInstanceTeardown`, group planning in
   `CleanupDocumentPurger`, `WorkflowInstancePurge`, sweep refactor.
3. REFACTOR: prettier, apex-ls, remove duplicate status lists.
4. Docs: `docs/instance-purge.md`, ADR 0016, README, `docs/archive.md`.
5. Review: agents for correctness, platform limits, security, tests and docs.

## 6. Review results

Four review agents (correctness, platform limits, security, tests and docs)
and the Codex PR review found issues. We fixed them:

- The teardown deleted all signal and log rows in one DML. A large log
  history went above the 10,000-row limit, and the sweep failed on the same batch
  each time. Now one run deletes at most 5000 rows and keeps the instances
  while rows remain. The sweep yields and keeps its cursor. The purge API
  gives `DEFERRED`.
- The API reported `PURGED` when the teardown kept the instances. Now it
  gives `DEFERRED`.
- A `Failed` parent or successor outside the set counted as safe. An
  operator can retry it. Now it blocks (final status rule). The call also
  locks the outside rows that it trusts and reads them again.
- A running child outside the set gave `REJECTED_RELATED` with the wrong
  advice. Now it gives `REJECTED_RELATED_ACTIVE`.
- One cut link check rejected every group in the call. Now only a group with
  a known rule break is rejected. The others get `DEFERRED`.
- The call locked all family rows. Now it locks only the groups that fit.
- A lock wait failure threw. Now the call gives `DEFERRED`.
- The family read counted known rows again, and the depth check was one
  level short. Both are fixed.
- The purgeable status set was public and could change. Now it is private.
- The file check ignored every User link. Now it ignores only the owner's
  link.
- Fire logs of a deleted schedule (`Schedule_Name__c`) now stay.
- A batch that kept its cursor could report a skipped Id twice.
- New tests: Failed parent, compensation links, link and row bounds,
  satellite pages, instance-count deferral, messages, overlapping families,
  status guard, teardown counts, group planning and the archive path.

A second review round (verification) found more issues. We fixed them:

- A partial teardown deleted the files but kept the instance. A retry or a
  rollback then had no payload. Now the files go only with the instance.
- Files did not count in the 5000-row budget. Now they do.
- A group with a non-terminal member took room in the call. Now it is
  rejected first and takes no room.
- A locked satellite threw a `DmlException`. Now a savepoint undoes the
  deletes, and the call gives `DEFERRED`.
- A lock failure reported an Id of another object type as `DEFERRED`. Now it
  gives `NOT_FOUND`.
