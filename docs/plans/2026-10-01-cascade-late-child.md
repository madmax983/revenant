# Cascade Cancel: Late Child (Issue #241)

## Goal

A child that is linked to a parent after the parent's cascade pass must still be cancelled.

## Facts

- The pass reads the active children of a failed parent in its own transaction.
- A child-start transaction can commit after that read. The parent is then `Failed`, with a live child.
- `requestCascade` runs no query and publishes one event for each failed parent.
- Two insert paths set `Parent_Instance__c`: `WorkflowChildService` and `WorkflowChildBulkPlanner`.
- The author has no org. Node tests run here. Apex tests run in CI.

## Brainstorm

| #   | Idea                                                          | Keep?                                              |
| --- | ------------------------------------------------------------- | -------------------------------------------------- |
| B1  | Trigger `after insert`: request a cascade for a failed parent | Yes. One place. Covers all insert paths.           |
| B2  | Guard in each child-insert path with a parent lock            | No. Two paths. Locks the parent. Misses new paths. |
| B3  | Timer sweep for orphan children                               | No. Late. Costs a scan.                            |
| B4  | Reuse the existing paged pass                                 | Yes. No new cancel code.                           |
| B5  | Skip the event for a child that is already terminal           | Yes. No work to do.                                |

## Reverse Brainstorm (how can this fail?)

| Way to fail                                  | Prevention                                                   |
| -------------------------------------------- | ------------------------------------------------------------ |
| Root insert pays a query.                    | Query only when a new row has a parent. Test: zero queries.  |
| Bulk insert queries once per child.          | One query for all parents. Test.                             |
| Many children make many events for a parent. | Collect parent Ids in a set. One event each. Test.           |
| Toggle off still cascades.                   | The existing toggle guard covers this path. Test.            |
| Parent was redriven before the event runs.   | The pass already drops a parent that is not failed.          |
| An error fails the child start.              | `requestCascade` catches all errors. The query is also safe. |
| `startChild` dedup changes.                  | No change to the insert paths. Existing tests stay green.    |
| Old tests insert children under failed rows. | Set up those rows with the toggle off.                       |

## Six Hats

- White: one trigger event, one handler method, one query, no new cancel code.
- Red: an operator sees a live child under a failed parent. This must not happen.
- Yellow: small change. The proven pass does the work.
- Black: an extra query on each child start. Mitigate: skip when no parent. Skip a terminal child.
- Green: later, add a guard that refuses the start under a failed parent.
- Blue: RED tests first, then GREEN, then REFACTOR, then review.

## Design

- `WorkflowInstanceTrigger` also runs `after insert`.
- `WorkflowInstanceTriggerHandler.handleAfterInsert()` collects `Parent_Instance__c` of each non-terminal new row.
- `WorkflowCascadeCancel.requestCascadeForLateChildren(parentIds)` keeps the parents still in a failure state. It then calls `requestCascade`.
- The toggle guards both methods. No global API change.

## Tests

- Late child after the pass: `Failed`, `Compensated`, `CompensationFailed` parent.
- Toggle off: no event.
- Running parent, or no parent: no event, no query for a root.
- Bulk: one query, one event for each failed parent.
- Terminal late child: no event.
