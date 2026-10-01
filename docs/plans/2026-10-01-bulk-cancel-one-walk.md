# Plan: one tree walk for a mixed-mode bulk cancel

Issue: #264. Parent: #107, #260.

## Problem

`cancelOwners` calls the hard-stop entry and the rollback entry one time each.
Each call walks its own trees with one SOQL query for each level. Two roots with
49 descendants each use 100 walk queries. The batch goes over the 100-query
limit and rolls back.

## Brainstorm

| Option                                          | Result                                                            |
| ----------------------------------------------- | ----------------------------------------------------------------- |
| A. Walk all roots in one pass. Split by mode.   | Walk cost = depth, not depth x modes. No new async path.          |
| B. Bound the walk by the SOQL budget. Go async. | Needs state, a new event, and a status for a part-cancelled tree. |
| C. Raise no limit. Tell users to split batches. | Flow cannot split a batch. Rejected.                              |

Choice: A. It meets all three acceptance criteria and adds no schema.

## Reverse brainstorm: how to make it worse

- Give a node the mode of the first root that reaches it. A rollback root under
  a hard-stop root then rolls back. The old behavior was a hard stop.
- Walk one more time for each mode "to be safe". The cost returns.
- Return one merged result set. A rollback root that a hard stop cancelled then
  shows `cancelled=true`.
- Change the order of the passes. A rollback pass first starts a rollback that
  a hard stop must stop.

Guards: a node takes the hard-stop mode when it is, or sits under, a hard-stop
root. The hard-stop pass runs first. The result keeps one set for each mode.

## Six hats

- White (facts): the walk is the only part that grows with depth. Lock, step and
  status queries are constant.
- Red (feel): users fear a lost cancel more than a slow one.
- Black (risk): a wrong mode on a node starts or skips a rollback. Tests cover
  both overlap cases.
- Yellow (gain): a mixed batch costs the same walk as a single-mode batch.
- Green (new idea): option B stays as a later step for trees deeper than the
  query limit.
- Blue (process): red tests, green code, refactor, then review.

## Design

1. `collectActiveTree` keeps its output. A new walk also keeps the child edges.
2. `cancelInstancesByMode(hardStopIds, rollbackIds)` walks all roots once.
3. It marks every node under a hard-stop root as hard stop. The rest roll back.
4. It runs `cancelNodes` for the hard-stop group, then for the rollback group.
   Each group is set-based, as before.
5. It returns the Ids that each mode cancelled, in `ModeResult`.
6. `WorkflowCancelInvocableAction.cancelOwners` calls it one time.
7. `cancelInstances`, `cancelWithCompensationsInstances` and
   `WorkflowEngine.cancel` do not change.

## Tests

- Walk queries do not grow with the number of modes (same depth, two trees).
- Two disjoint 50-level trees, one for each mode, pass under the SOQL limit.
- A rollback root under a hard-stop root is hard stopped.
- A hard-stop root under a rollback root is hard stopped. The rollback root
  still rolls back.
- An empty group runs no pass. An empty call uses no SOQL.
