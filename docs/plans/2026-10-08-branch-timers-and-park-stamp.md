# Branch Timers and Park Stamp (Issue #311)

## Goal

1. A parallel branch that sleeps in a park keeps its deadline on release.
2. Only a signal that arrived in the park overrides a timer.

## Facts before this change

- `Sleep_Until__c` is one field for all branches. Each branch overwrites the value of the others.
- A park clears `Sleep_Until__c`. A wait that ends in the park sets it again.
- A park aborts the scheduled sleep job. The job does not return on release.
- `WorkflowParkedTimer` skips a parallel instance (#307). Release runs all open branches. A sleeping branch ends early.
- The sleep sweep wakes a `Suspended` instance with a due `Sleep_Until__c`. For a parallel instance it starts no branch.
- `WorkflowParkedTimer` treats any `Received` signal as a signal that arrived in the park. An old signal makes a serial instance run early.
- The author has no org. Apex tests run in CI. The apex-ls compile check runs here.

## Brainstorm

| #   | Idea                                                                          | Keep?                                               |
| --- | ----------------------------------------------------------------------------- | --------------------------------------------------- |
| B1  | `Wake_At__c` on the step row. The sleep and timed-wait handlers set it.       | Yes. One timer for each branch.                     |
| B2  | `Parked_At__c` on the instance. The three park gates set it.                  | Yes. Compared with the signal date.                 |
| B3  | Release skips a branch with a future `Wake_At__c`. The instance stays asleep. | Yes. The deadline stays.                            |
| B4  | The sweep starts each branch with a due `Wake_At__c`, by name.                | Yes. Drives the branch.                             |
| B5  | The sweep keeps the next `Wake_At__c` in `Sleep_Until__c`.                    | Yes. If not, a later branch has no wake time.       |
| B6  | Schedule a sleep job for each branch on release.                              | No. The sweep does this work. This needs less code. |
| B7  | Compare signals in SOQL with a bind.                                          | No. Each instance has its own park time.            |
| B8  | Use `MAX(CreatedDate)` for each instance. Compare in Apex.                    | Yes. One grouped query.                             |
| B9  | Reuse `Held_At__c` as the park stamp.                                         | No. It is the hold time, not the park time.         |

## Reverse Brainstorm (failure modes)

| Way to fail                                                | Prevention                                                                |
| ---------------------------------------------------------- | ------------------------------------------------------------------------- |
| An old `Wake_At__c` delays a branch that ran again.        | Clear it when the step starts. Test.                                      |
| A signal wake of a timed branch is lost.                   | Only release, resume and hold skip sleepers. Signal wake does not.        |
| A later branch has no wake after the sweep woke the first. | The sweep keeps the next `Wake_At__c`. Test.                              |
| The sweep and the sleep job start one branch two times.    | The sweep reads only branches with a due `Wake_At__c`. The run clears it. |
| A park path has no stamp.                                  | A blank stamp means: any `Received` signal wins. Same as today.           |
| A stale stamp hides a signal.                              | Release clears the stamp. Test.                                           |
| A signal in the same second as the park is lost.           | Compare with `>=`. A tie runs the step.                                   |
| All branches sleep, but release enqueues them.             | The instance waits. No worker. Test.                                      |
| Elapsed `Wake_At__c` at release is skipped.                | Only a future `Wake_At__c` sleeps. A due branch runs. Test.               |

## Risks and order of work

- Risk: a wrong rule leaves a branch with no wake time. Each rule has a test.
- Risk: an old park has no stamp. A blank stamp keeps the old rule.
- Benefit: no new job type. Both fields are optional. Old rows work.
- Later: a change can drop `Sleep_Until__c` for parallel instances.
- Order: write failing tests, add the fields, gates, handlers, release code and sweep, then update the docs, then review.

## Decision

- `Workflow_Step_Execution__c.Wake_At__c` holds the deadline of a sleep or a timed wait.
- `Workflow_Instance__c.Parked_At__c` holds the park time. Release and resume clear it.
- A serial instance: unchanged, but only a signal with `CreatedDate >= Parked_At__c` wins.
- A parallel instance:
  - A signal in the park runs all open branches.
  - If not, release skips each branch with a future `Wake_At__c`.
  - If a branch sleeps, the instance is `Suspended`, with `Sleep_Until__c` set to the first wake.
  - If all open branches sleep, no worker starts.
- The sweep starts each due sleeping branch by name. It keeps the next wake in `Sleep_Until__c`.
- A wait handler keeps an earlier future `Sleep_Until__c` of a sibling branch. The sleep job keeps the next branch deadline. It starts a branch only when its `Wake_At__c` ended.
- A timed wait of a branch gets `Wake_At__c` too. Its timeout route for a parallel branch is out of scope.

## Steps

1. Write failing tests: `WorkflowBranchTimerTest`. Park stamp tests in `WorkflowParkedOutcomeTest`.
2. Make the tests pass: fields, permission sets, report types.
3. Make the tests pass: park gates set `Parked_At__c`. `WorkflowParkedTimer` reads it.
4. Make the tests pass: handlers set `Wake_At__c`. Step start clears it.
5. Make the tests pass: release paths skip sleeping branches. The sweep drives due branches.
6. Clean up: remove `isParallel` skip. Update docs and MIGRATION.
7. Review the code. Fix each finding.
