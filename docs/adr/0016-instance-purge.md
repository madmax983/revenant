# ADR 0016: Orphan-free instance purge

- **Status:** Accepted
- **Date:** 2026-09-30
- **Issue:** #142

## Context

A `delete` of a `Workflow_Instance__c` removes only MasterDetail children.
Signals and logs keep a null lookup. Offloaded payload files stay, because
only a `ContentDocumentLink` joins them to the instance. `CleanupWorkflow`
deleted files and signals, but not logs. Operators had no call to delete a
set of instances that they select.

## Decision

1. `WorkflowInstanceTeardown.run(chunk)` is the one delete routine. It
   deletes engine files, signals, instance logs and instances.
   `WorkflowArchiveSweep` (`CleanupWorkflow`, `ArchiveWorkflow`) and
   `WorkflowInstancePurge` call it. The log leak closes.
2. A log row with `Schedule__c` or `Schedule_Name__c` stays. It is schedule
   fire history.
3. One teardown run deletes at most 5000 rows (signals, logs and files).
   When signal or log rows remain, it keeps the instances and their files, so
   a retry can still read them. The sweep yields and keeps its cursor. The
   purge API gives `DEFERRED`. A savepoint turns a locked satellite into
   `DEFERRED` with no delete.
4. API: `WorkflowInstancePurge.purge(Id)`, `purge(Set<Id>)` and
   `purge(Set<Id>, Boolean includeRelated)`. Not on `WorkflowEngine`: that
   class is at the PMD `ExcessivePublicCount` limit
   ([ADR 0007](0007-per-instance-hold.md)).
5. `public`, not `global`. A `global` member is permanent
   ([ADR 0006](0006-frozen-global-api.md)). Promote it when a subscriber
   needs it. The caller must check permissions.
6. Only terminal instances. Each Id gets an `Outcome`. Bad input throws.
7. Mixed set: skip and report. The call purges a group of linked instances
   as one unit.
8. Chains and children: the purge refuses to leave a dangling child or a
   predecessor with no successor. The purge accepts removal of the oldest
   generations. The age purge in `CleanupWorkflow` also removes the oldest
   generations first. `includeRelated` adds the full family.
9. A successor or parent outside the set must have a final status (terminal,
   not `Failed`). A rollback reads its target through `Previous_Instance__c`.
   An active or retried parent reads its children. The call locks these
   outside rows and reads them again.
10. Bounds: 50 Ids and 50 instances, 100 files (the existing cap), 5000
    satellite rows, 20 link levels, 2000 rows for each related read. A group
    larger than a bound gets `REJECTED_TOO_LARGE`. A group that does not fit
    the rest of this call gets `DEFERRED`.
11. `CleanupDocumentPurger.planGroups` keeps a group in one chunk. The file
    check ignores only the owner's User link.

## Consequences

- No new object, field or event. No change to `WorkflowOrchestrator` or the
  Queueable handoff.
- `CleanupWorkflow` and `ArchiveWorkflow` do 1 more SOQL and at most 1 more
  DML for each batch (the logs).
- `CleanupWorkflow` and `ArchiveWorkflow` delete instance logs, also the
  operator intervention rows. `ArchiveWorkflow` does not archive logs.
- A file that a user shares with another user stays. Before, the sweep
  deleted it.
- A purge locks the rows that it deletes and the outside rows it trusts.
- Archive copies stay. They are a deliberate copy
  ([ADR 0003](0003-archive-sink-api.md)).

## Rejected Options

- Find the instances that hold data about a person: payloads are operator
  JSON. The engine cannot know which bytes belong to a person.
- All-or-nothing for the full set: one bad Id blocks a large erasure job.
- Delete schedule fire logs too: it changes schedule health history.
- `includeRelated` also adds the parent: it deletes more than the caller
  named, in the wrong direction.
- Purge on `WorkflowEngine`: PMD `ExcessivePublicCount`.
- Unbounded satellite delete: a large log history passes the DML row limit,
  and the sweep then fails on the same batch each time.
