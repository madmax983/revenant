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
2. A log row with `Schedule__c` stays. It is schedule fire history.
3. API: `WorkflowInstancePurge.purge(Id)`, `purge(Set<Id>)` and
   `purge(Set<Id>, Boolean includeRelated)`. Not on `WorkflowEngine`: that
   class is at the PMD `ExcessivePublicCount` limit (ADR 0007).
4. `public`, not `global`. A `global` member is permanent (ADR 0006).
   Promote it when a subscriber needs it.
5. Only terminal instances. Each Id gets an `Outcome`. Bad input throws.
6. Mixed set: skip and report. Linked instances form a group that is purged
   in full or not at all.
7. Chains and children: the purge refuses to leave a dangling child or a
   predecessor with no successor. Removal of the oldest generations passes,
   as `CleanupWorkflow` does. `includeRelated` adds the full family.
8. An active successor or parent outside the set blocks the purge. A
   rollback reads its target through `Previous_Instance__c`. An active parent
   reads its children.
9. Bounds: 50 Ids and 50 instances, 100 files (the existing cap), 20 link
   levels, 2000 related rows. Groups that do not fit get `DEFERRED`.
10. `CleanupDocumentPurger.planGroups` keeps a group in one chunk.

## Consequences

- No new object, field or event. No change to `WorkflowOrchestrator` or the
  Queueable handoff.
- `CleanupWorkflow` and `ArchiveWorkflow` do 1 more SOQL and at most 1 more
  DML for each batch (the logs).
- A purge locks the rows that it deletes.
- Archive copies stay. They are a deliberate copy (ADR 0003).

## Rejected Options

- Find the instances of a data subject: payloads are operator JSON. The
  engine cannot know which bytes belong to a person.
- All-or-nothing for the full set: one bad Id blocks a large erasure job.
- Delete schedule fire logs too: it changes schedule health history.
- `includeRelated` also adds the parent: it deletes more than the caller
  named, in the wrong direction.
- Purge on `WorkflowEngine`: PMD `ExcessivePublicCount`.
