# Keep the Park on a Wait Outcome (Issue #240)

## Goal

A step can finish after its instance parks (`DefinitionChanged`, `Paused`). A wait outcome (SUSPEND, SLEEP, START_CHILD, START_CHILDREN, WAIT_FOR_APPROVAL) must not write `Suspended` over the park. Release and resume must keep a timer that the step recorded during the park.

## Facts

- All five wait handlers get the new status from `WorkflowInstanceHoldGate.waitStatus`. It keeps only `Held`.
- `WorkflowParallelJoin` has its own inline check for the parallel SUSPEND verdict (#238).
- A gate park clears `Sleep_Until__c`. The pause park (`parkIfPaused`) does not.
- Release (`WorkflowDefinitionChangeService`), pause resume (`WorkflowPauseResumeDrainer`) and hold release set `Running` and enqueue the step.
- The sleep sweep wakes each `Suspended` instance with `Sleep_Until__c` in the past.
- A rerun of an untimed wait step suspends again. Child start is idempotent.
- The author has no org. Apex tests run in CI.

## Brainstorm

| #   | Idea                                                           | Keep?                                                      |
| --- | -------------------------------------------------------------- | ---------------------------------------------------------- |
| B1  | One shared park check. `waitStatus` and the join use it.       | Yes. One place, five handlers fixed.                       |
| B2  | Guard each handler.                                            | No. Five copies.                                           |
| B3  | Guard in `assertInstanceRunnable`. Throw on a park.            | No. The step result would be lost.                         |
| B4  | On release, a future `Sleep_Until__c` gives `Suspended`.       | Yes. The sweep wakes it. No new field.                     |
| B5  | New marker field for "wait recorded in park".                  | No. Needs permission, report and doc changes.              |
| B6  | Reschedule a sleep job on release.                             | No. The sweep is the backstop. Not needed.                 |
| B7  | Pause park clears `Sleep_Until__c`, like the other gates.      | Yes. Makes B4 safe.                                        |
| B8  | Keep untimed signal and child waits as `Suspended` on release. | No. A consumed wake looks the same. Rerun is safe instead. |

## Reverse Brainstorm (how can this fail?)

| Way to fail                                           | Prevention                                                    |
| ----------------------------------------------------- | ------------------------------------------------------------- |
| A normal wait stops to write `Suspended`.             | Test: a `Running` instance still gets `Suspended`.            |
| A stale timer keeps a released instance asleep.       | Pause park clears the timer. Test.                            |
| An elapsed timer keeps the instance asleep.           | Only a future timer gives `Suspended`. Test.                  |
| A parallel instance resumes a sleeping branch early.  | Same rule for parallel. Test.                                 |
| Parallel FAIL verdict keeps the park and strands.     | FAIL stays terminal. No open branch to drive. Test pins it.   |
| Hold release runs a step that must sleep.             | Hold release uses the same rule. Test.                        |
| Paused instance with a timer is dropped by the sweep. | Sweep only reads `Suspended`. Release sets `Suspended`. Test. |

## Six Hats

- White: five handlers, one join check, three release paths, one pause park.
- Red: an operator sees `Suspended` and no Release button. That is the pain.
- Black: a wrong rule strands an instance. Tests cover each park status.
- Yellow: small change. No new field. No schema change.
- Green: a later change can add a marker field for untimed waits.
- Blue: RED tests first. Then handlers. Then release paths. Then review.

## Decision

- FAIL from the parallel verdict ends the instance. A failed branch has no delivery. Release could not drive it. The test pins this choice.
- Hold has the same release gap. It uses the same helper.

## Steps

1. RED: `WorkflowParkedOutcomeTest`.
2. GREEN: `WorkflowOutcomePrepare.isParkedStatus`, `waitStatus`, join check.
3. GREEN: `WorkflowParkedTimer` for the three release paths. Pause park clears the timer.
4. REFACTOR: remove the inline join check. Update docs.
5. Review from several angles. Fix findings.
