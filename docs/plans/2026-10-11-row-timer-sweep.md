# Row Timer Sweep (Issue #335)

## Goal

1. The sweep finds a due parallel branch from its own `Wake_At__c`. `Sleep_Until__c` is a hint.
2. A branch that a signal woke has no stale timer.
3. No read of the full step history in a chunk of 200 instances.
4. A sleep from before the upgrade still wakes.
5. A sleeping branch has no `Timeout_At__c` before its timer ends.

## Facts before this change

- `Sleep_Until__c` is one field for all branches. The sweep selects only through it.
- `keepEarlier` treats an expired `Sleep_Until__c` as obsolete. A later wait of branch A erases the due deadline of branch B.
- Only a step start clears `Wake_At__c`. A signal wake publishes the run first. A park can stop the worker before it clears the timer.
- `WorkflowBranchTimer.load`, `WorkflowBranchResume.loadLatestBranchStatuses` and `WorkflowPauseResumeDrainer.resolveLatestBranchStatus` read every row of each branch.
- `WorkflowTimeoutReArm.reArmTimeoutsForResume` stamps `Timeout_At__c` on every Pending row.
- A SOQL semi-join cannot be in an `OR`.
- The author has no org. CI runs the Apex tests. `npm run check:apex-compile` runs here.

## Brainstorm

| #   | Idea                                                                                                                | Keep?                                                                                            |
| --- | ------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| B1  | Query the due step rows. Add their instances to the sweep query by Id.                                              | Yes. One extra query. No OR with a semi-join.                                                    |
| B2  | Limit the row query to parallel instances.                                                                          | Yes. A serial instance keeps `Sleep_Until__c`.                                                   |
| B3  | Clear `Wake_At__c` where the run is published (signal wake, release, pause resume, hold release, sweep, sleep job). | Yes. The claim and the publish share one transaction.                                            |
| B4  | Read active rows, then count the finished branches in a grouped query.                                              | Yes. The result size is the branch count, not the history.                                       |
| B5  | One shared read for release, signal wake and drain.                                                                 | Yes. It removes two copies of the history read.                                                  |
| B6  | Skip a row with a future `Wake_At__c` in the timeout re-arm.                                                        | Yes.                                                                                             |
| B7  | Stamp `Timeout_At__c` in the same update that claims the row.                                                       | Yes. Only for a timer wake (sweep, sleep job).                                                   |
| B8  | Remove `keepEarlier`.                                                                                               | No. It still feeds the stall detector. It is a hint now.                                         |
| B9  | A backfill class that stamps `Wake_At__c` from `Sleep_Until__c`.                                                    | No. It cannot tell a sleeper from an unstarted branch.                                           |
| B10 | A new field that marks a legacy job.                                                                                | No. More schema for a one-time gap.                                                              |
| B11 | Sweep fallback: run the untimed Pending branches of a due instance with no row timer.                               | Yes. A sleep from before the upgrade still wakes. A signal waiter and a lock retry are left out. |

## Reverse Brainstorm (how to fail)

| Way to fail                                                   | Prevention                                                           |
| ------------------------------------------------------------- | -------------------------------------------------------------------- |
| The row query selects a serial instance with a stale timer.   | Filter on a comma in `Current_Step__c`. Test.                        |
| The sweep and a sleep job start one branch two times.         | Both claim the row first. The second finds no due timer. Test.       |
| The claim and the publish are in different transactions.      | Claim and publish run in the same method. The instance is locked.    |
| A claimed branch stays unstarted after the publish fails.     | The publish throws. The transaction rolls back the claim.            |
| The grouped query counts a branch as done while it loops.     | A branch with an active row is open. Test.                           |
| A finished branch runs again.                                 | A branch with no active row and a finished row is skipped. Test.     |
| The history read grows with the step count.                   | Assert the query rows with a long history. Test.                     |
| The fallback runs branches that wait for a timer.             | The fallback applies only when no branch has a timer. Test.          |
| The fallback runs a signal waiter or a lock retry.            | It runs only Pending rows with no wait type and no retry mark. Test. |
| A paused definition fills the row query.                      | The instance query keeps the pause and hold filters.                 |
| The re-arm skips a branch whose timer ended.                  | Skip only a timer after now. Test.                                   |
| The woken branch has no timeout.                              | The claim stamps `Timeout_At__c` for a step with a timeout. Test.    |
| A signal wake of an instance with no timer rows reads nothing | The shared read returns the branches with no row as open. Test.      |

## Six Hats

- White (facts): see "Facts before this change". The history read costs one row for each past step visit. A grouped result costs one row for each branch.
- Red (feel): a stuck timer harms users more than a late run. A due branch must always start. An extra run harms less.
- Black (risk): the grouped query is the one new SOQL form. A rule about its row count is not testable here. CI runs it. A latest status of `Failed` with an older `Completed` row now reads as finished. That state fails the instance, so no release reaches it.
- Yellow (gain): the sweep needs no shared field. Three history reads become one bounded read. One update claims all rows of a chunk.
- Green (new ideas): see the Brainstorm table. B11 closes the upgrade gap with no new schema.
- Blue (process): tests first, then the change in small steps, then the docs, then a review from four angles.

## Decision

- `WorkflowSleepResumeSweep` runs a row query: Pending rows with `Wake_At__c <= now` on a `Suspended` parallel instance. The main query takes `Sleep_Until__c <= now OR Id IN :rowDue`.
- `WorkflowBranchTimer.load` runs one query for the active rows (Pending, Running, Retrying). It runs one grouped query for each 1,500 finished branches, because a grouped query returns at most 2,000 rows. `Branches` lists the open branches. It is the one read for release, signal wake and drain.
- `WorkflowBranchTimer.claim` clears `Wake_At__c`. Signal wake, release and drain call it for each branch they publish. The sweep and the sleep job call `woken`, which also stamps `Timeout_At__c`.
- `WorkflowTimeoutReArm.reArmTimeoutsForResume` skips a row whose `Wake_At__c` is after now.
- The sweep fallback: a parallel instance that the sweep selects by `Sleep_Until__c` and that has no row timer runs its untimed Pending branches by name. Those are the Pending rows with no wait type and no retry mark, last changed before the deadline.
- `keepEarlier` stays. `Sleep_Until__c` is a hint for the stall detector and the dashboard.

## Steps

1. RED: write failing tests for each case.
2. GREEN 1: the shared bounded read. Move release, signal wake and drain to it.
3. GREEN 2: the claim at publish.
4. GREEN 3: the row query in the sweep, and the fallback.
5. GREEN 4: the timeout re-arm and the claim stamp.
6. REFACTOR: remove the old history reads. Update the docs.
7. Review from four angles. Fix each finding.

## Dropped claims (issue #339)

The sweep claims the timers before it updates the instances. The sweep claims the timers of a whole instance or none. An instance whose claims do not all fit stays `Suspended` and keeps its timers. The next heartbeat selects it again.
