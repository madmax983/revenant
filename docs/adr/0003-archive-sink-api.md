# ADR 0003: Pluggable archive sink before purge

- Status: Accepted
- Date: 2026-09-28
- Issue: #105

## Context

`CleanupWorkflow` deletes terminal instances and their step history. Audits
need that history for years. Primary data storage is expensive. The issue
asks for a Big Object tier. Some orgs want other cold stores, for example S3.

## Decision

1. Add a public `WorkflowArchiveSink` interface: `write`,
   `readByInstanceIds` and `readByCorrelationKey`.
2. Ship two sinks: `BigObjectArchiveSink` (default) and `CsvArchiveSink`
   (one CSV `ContentVersion` for each instance).
3. Add `Revenant_Config__mdt` fields: `Archive_Enabled__c` (off by default),
   `Archive_Sink__c` (class name, blank is the Big Object sink) and
   `Archive_After_Days__c` (default age for `ArchiveWorkflow`).
4. `WorkflowArchiveSweep` holds the sweep. For each chunk it reads (SOQL
   only), calls `sink.write`, then deletes files, signals and instances.
5. `ArchiveWorkflow` runs the sweep. With archival on, `CleanupWorkflow`
   also archives first. Both steps are `CalloutStep`s. The engine then does
   no DML before the step, so `insertImmediate` and callout sinks work.
6. Fail closed. A sink error or a config read error stops the chunk before
   any delete.
7. Offloaded payloads are dropped. The archive keeps a `$archiveDropped`
   marker and a count.
8. Bound each batch: 20 instances, 500 step rows, a quarter of the heap. An
   instance with more steps stays in primary storage, and the run output
   names it.
9. The CSV sink finds files only by two `ContentVersion` fields that no
   permission set can edit. So a user cannot plant a trusted file.

## Alternatives

| Option | Why not |
|---|---|
| Big Object only | The owner wants other stores. A sink API costs little. |
| Archive in a new custom object | It uses primary data storage. |
| Copy offloaded files into the archive | Heap risk. The purge deletes the files, and the marker records the loss. |
| Archive on the orchestrator hot path | The issue forbids it. |
| Only `ArchiveWorkflow`; leave `CleanupWorkflow` as is | A scheduled cleanup then purges unarchived history. |
| Find CSV files by title | A user can upload a file with the same title. The sink then skips the real write. |

## Consequences

- `WorkflowArchiveSink` and `WorkflowArchiveRecord` are public API. Change
  them only in an additive way.
- Tests cannot write Big Objects. The Big Object sink has a test seam, so the
  real `insertImmediate` and Big Object SOQL run only in an org.
- `CleanupWorkflow`'s step is now a `CalloutStep`. Its Running row is saved
  after `execute`, not before. It has no timeout and no auto-retry, so
  nothing else changes.
- CSV readers need file access: the `Revenant_Archive` library, or "Query
  All Files".
